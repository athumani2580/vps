#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# SSH Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300

# MTU Configuration - Adjusted for better stability
MTU_SIZE=1200  # More conservative MTU for better compatibility

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
echo "           OpenSSH SlowDNS Installation (Stable Version)"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi
print_success "Server IP: $SERVER_IP"

# Backup original SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Configure SSH ports
print_warning "Configuring SSH ports..."

# Ensure ports are not duplicated
sed -i '/^Port 22/d' /etc/ssh/sshd_config
sed -i '/^Port 69/d' /etc/ssh/sshd_config

echo "Port 22" >> /etc/ssh/sshd_config
echo "Port 69" >> /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config

# Additional SSH hardening for SlowDNS
echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config
echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config

systemctl restart sshd 2>/dev/null
sleep 2
print_success "SSH configured on ports 22 and 69 with TCP forwarding enabled"

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files with retry mechanism
print_warning "Downloading SlowDNS files..."
download_file() {
    local url=$1
    local output=$2
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        wget -q -O "$output" "$url"
        if [ $? -eq 0 ] && [ -s "$output" ]; then
            return 0
        fi
        retry=$((retry + 1))
        sleep 2
    done
    return 1
}

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" "/etc/slowdns/server.key"; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key"
fi

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" "/etc/slowdns/server.pub"; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub"
fi

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server" "/etc/slowdns/sldns-server"; then
    print_success "sldns-server downloaded"
else
    print_error "Failed to download sldns-server"
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Ask for MTU size with recommendation
echo "MTU Configuration:"
echo "1) 1200 (Recommended - Most Stable)"
echo "2) 1300 (Your current setting)"
echo "3) 1400 (Faster but less stable)"
echo "4) Custom"
read -p "Select MTU option [1-4]: " mtu_choice

case $mtu_choice in
    1) MTU_SIZE=1200 ;;
    2) MTU_SIZE=1300 ;;
    3) MTU_SIZE=1400 ;;
    4) read -p "Enter custom MTU size: " MTU_SIZE ;;
    *) MTU_SIZE=1200 ;;
esac

print_success "Using MTU size: $MTU_SIZE"

# Create SlowDNS service with dynamic MTU
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS ALIEN (Stable)
Documentation=https://man himself
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=/bin/sleep 5
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu $MTU_SIZE -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=10
StartLimitInterval=200
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Improved iptables configuration
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
systemctl start sshd

# Clear existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH ports
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 69 -j ACCEPT

# Allow SlowDNS port (UDP and TCP)
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT

# DNS redirect (for port 53 to SlowDNS port)
iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $SLOWDNS_PORT

# Rate limiting for SSH port 69 (prevent brute force)
iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP

# Allow ICMP
iptables -A INPUT -p icmp -j ACCEPT

# Drop invalid packets
iptables -A INPUT -m state --state INVALID -j DROP

# System optimizations
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

# TCP optimizations for SlowDNS
sysctl -w net.ipv4.tcp_rmem='4096 87380 134217728' > /dev/null 2>&1
sysctl -w net.ipv4.tcp_wmem='4096 65536 134217728' > /dev/null 2>&1
sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1

exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1
print_success "Startup configuration set"

# Disable IPv6 properly
print_warning "Disabling IPv6..."
cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# DNS configuration with fallback
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null

# Remove immutable attribute if set
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf

# Create new resolv.conf with multiple DNS servers
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
options timeout:1 attempts:3
EOF

chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured with multiple resolvers"

# Start SlowDNS service with retry mechanism
print_warning "Starting SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1

# Try to start service with retry
max_attempts=3
attempt=1
while [ $attempt -le $max_attempts ]; do
    systemctl start server-sldns
    sleep 5
    
    if systemctl is-active --quiet server-sldns; then
        print_success "SlowDNS service started (attempt $attempt)"
        break
    else
        print_warning "Start attempt $attempt failed, retrying..."
        attempt=$((attempt + 1))
    fi
done

# Final check and diagnostics
sleep 5

# Check SlowDNS service
if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service is running"
    
    # Test SlowDNS
    print_warning "Testing SlowDNS functionality..."
    
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_error "SlowDNS not responding on port $SLOWDNS_PORT"
    fi
else
    print_error "SlowDNS service failed to start"
    
    # Try direct start as fallback
    print_warning "Attempting direct start..."
    pkill sldns-server 2>/dev/null
    /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu $MTU_SIZE -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69 &
    sleep 3
    
    if pgrep -x "sldns-server" > /dev/null; then
        print_success "SlowDNS started directly"
    else
        print_error "Failed to start SlowDNS even directly"
    fi
fi

# Test SSH connections
print_warning "Testing SSH connections..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/22" 2>/dev/null; then
    print_success "SSH port 22 is accessible"
else
    print_error "SSH port 22 is not accessible"
fi

if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
else
    print_error "SSH port 69 is not accessible"
fi

# Show connection information
echo ""
echo "=================================================================="
print_success "     OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="
echo ""
echo "Connection Information:"
echo "━━━━━━━━━━━━━━━━━━━━━━━"
echo "Server IP      : $SERVER_IP"
echo "SSH Ports      : 22, 69"
echo "SlowDNS Port   : $SLOWDNS_PORT (UDP)"
echo "DNS Port       : 53 (redirected to $SLOWDNS_PORT)"
echo "Nameserver     : $NAMESERVER"
echo "MTU Size       : $MTU_SIZE"
echo ""
echo "SlowDNS Public Key:"
cat /etc/slowdns/server.pub 2>/dev/null || echo "Not available"
echo ""
echo "Configuration Commands:"
echo "━━━━━━━━━━━━━━━━━━━━━━"
echo "Check service: systemctl status server-sldns"
echo "View logs: journalctl -u server-sldns -f"
echo "Restart service: systemctl restart server-sldns"
echo ""
echo "Client Configuration:"
echo "━━━━━━━━━━━━━━━━━━━━"
echo "Nameserver: $NAMESERVER"
echo "Public Key: $(cat /etc/slowdns/server.pub 2>/dev/null | head -n1)"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "SSH Port: 69"
echo ""
echo "=================================================================="
