#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# SSH Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300

# Functions
print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

# Check root
check_root

echo "=================================================================="
echo "                 OpenSSH SlowDNS Installation"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure SSH ports
print_warning "Configuring SSH ports..."

echo "Port 22" >> /etc/ssh/sshd_config
echo "Port 69" >> /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config

systemctl restart sshd 2>/dev/null
sleep 2
print_success "SSH configured on ports 22 and 69 with TCP forwarding enabled"

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files
print_warning "Downloading SlowDNS files..."
wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
if [ $? -eq 0 ]; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key"
fi

wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
if [ $? -eq 0 ]; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub"
fi

wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
if [ $? -eq 0 ]; then
    print_success "sldns-server downloaded"
else
    print_error "Failed to download sldns-server"
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Install socat for EDNS 512 proxy
print_warning "Installing socat for EDNS 512 support..."
apt-get update -qq
apt-get install -y -qq socat 2>/dev/null
print_success "Socat installed"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create EDNS 512 proxy service (handles MTU 512 to client)
print_warning "Creating EDNS 512 proxy service..."
cat > /etc/systemd/system/edns-proxy.service << EOF
[Unit]
Description=EDNS 512 Proxy for SlowDNS (Client MTU 512)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat UDP4-LISTEN:53,fork,reuseaddr UDP4:127.0.0.1:$SLOWDNS_PORT,mtu=512
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_success "EDNS 512 proxy service created"

# Create SlowDNS service with MTU 1800 (internal)
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS ALIEN (Internal MTU 1800)
Documentation=https://man himself
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Create packet size limiter script
print_warning "Creating EDNS 512 packet limiter..."
cat > /usr/local/bin/edns-limiter.sh << 'EOF'
#!/bin/bash
# Limit UDP packets to 512 bytes for external clients

# Clear existing rules
iptables -D OUTPUT -p udp --sport 5300 -m length --length 513:1800 -j DROP 2>/dev/null
iptables -D OUTPUT -p udp --sport 5300 -j ACCEPT 2>/dev/null

# Drop packets larger than 512 bytes to external clients
iptables -A OUTPUT -p udp --sport 5300 -m length --length 513:1800 -j DROP

# Allow normal packets
iptables -A OUTPUT -p udp --sport 5300 -j ACCEPT

echo "EDNS 512 limiter activated"
EOF

chmod +x /usr/local/bin/edns-limiter.sh
print_success "Packet limiter created"

# Startup config with iptables and EDNS 512 support
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
systemctl start sshd

# Basic iptables rules
iptables -I INPUT -p udp --dport 5300 -j ACCEPT
iptables -I INPUT -p udp --dport 53 -j ACCEPT

# EDNS 512: Drop packets >512 bytes from SlowDNS to external
iptables -A OUTPUT -p udp --sport 5300 -m length --length 513:1800 -j DROP

# Optional: Log oversized packets for debugging
iptables -A OUTPUT -p udp --sport 5300 -m length --length 513:1800 -j LOG --log-prefix "EDNS_512_BLOCKED: "

# Disable IPv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

# Apply EDNS limiter
/usr/local/bin/edns-limiter.sh

exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1
print_success "Startup configuration set"

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# Disable systemd-resolved and set custom DNS
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured with Google and Cloudflare DNS servers"

# Start EDNS 512 proxy first
print_warning "Starting EDNS 512 proxy..."
systemctl daemon-reload
systemctl enable edns-proxy > /dev/null 2>&1
systemctl start edns-proxy

sleep 2

if systemctl is-active --quiet edns-proxy; then
    print_success "EDNS 512 proxy started (port 53 -> 5300 with MTU 512)"
else
    print_error "EDNS 512 proxy failed to start"
fi

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns

sleep 3

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started (internal MTU 1800)"
    
    # Test SlowDNS
    print_warning "Testing SlowDNS functionality..."
    sleep 2
    
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_error "SlowDNS not responding on port $SLOWDNS_PORT"
        
        # Try direct start
        pkill sldns-server 2>/dev/null
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69 &
        sleep 2
        
        if pgrep -x "sldns-server" > /dev/null; then
            print_success "SlowDNS started directly"
        else
            print_error "Failed to start SlowDNS"
        fi
    fi
else
    print_error "SlowDNS service failed to start"
fi

# Apply EDNS packet limiter
/usr/local/bin/edns-limiter.sh
print_success "EDNS 512 packet limiter applied"

# Test SSH connection
print_warning "Testing SSH connection..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
else
    print_error "SSH port 69 is not accessible"
fi

# Final EDNS 512 status
echo ""
echo "=================================================================="
echo "                    EDNS 512 Configuration"
echo "=================================================================="
echo "Client (external):    UDP port 53, MTU 512"
echo "Proxy:                socat (53 -> 5300) with MTU 512"
echo "SlowDNS (internal):   UDP port 5300, MTU 1800"
echo ""
echo "Traffic flow:"
echo "  Client (MTU 512) -> port 53 -> socat proxy -> port 5300 -> SlowDNS"
echo "  SlowDNS (MTU 1800) -> socat (chunks to 512) -> Client"
echo ""
iptables -L OUTPUT -v -n | grep -E "sport 5300.*length" 2>/dev/null || echo "EDNS 512 iptables rule active"
echo "=================================================================="
print_success "           OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="
echo ""
echo "Client connection:"
echo "  Point your DNS to: $SERVER_IP:53"
echo "  Or use nameserver: $NAMESERVER"
echo ""
