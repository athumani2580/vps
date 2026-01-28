#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300
SWITCH_PORT=53
TARGET_PORT=101

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
echo " OpenSSH SlowDNS Installation with Port Switching"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure SSH ports
print_warning "Configuring SSH ports..."
echo "Port 22" >> /etc/ssh/sshd_config
echo "Port $TARGET_PORT" >> /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null
sleep 2
print_success "SSH configured on ports 22 and $TARGET_PORT with TCP forwarding enabled"

# Setup port switching from 53 to 101
print_warning "Setting up port switching (53 → 101)..."
# Install socat if not present
if ! command -v socat &> /dev/null; then
    apt-get update && apt-get install -y socat
fi

# Create port switching service
cat > /etc/systemd/system/port-switch.service << EOF
[Unit]
Description=Port Switch Service (53 to 101)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat TCP-LISTEN:${SWITCH_PORT},reuseaddr,fork TCP:localhost:${TARGET_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable port-switch.service
systemctl start port-switch.service
print_success "Port switching from ${SWITCH_PORT} to ${TARGET_PORT} configured"

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

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$TARGET_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Update rc.local with port switching rules
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/sh -e

# Start services
systemctl start sshd
systemctl start port-switch

# Clear iptables
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH Ports
iptables -A INPUT -p tcp --dport $TARGET_PORT -j ACCEPT

# Port Switch (53 to 101)
iptables -A INPUT -p tcp --dport $SWITCH_PORT -j ACCEPT

# SlowDNS ports
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT

# ICMP
iptables -A INPUT -p icmp -j ACCEPT

# Output rules
iptables -A OUTPUT -j ACCEPT

# Drop invalid
iptables -A INPUT -m state --state INVALID -j DROP

# Rate limiting for SSH
iptables -A INPUT -p tcp --dport $TARGET_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $TARGET_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Disable IPv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6

# Optimize network
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

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

# Configure DNS
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured"

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns
sleep 3

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
else
    print_error "SlowDNS service failed to start"
    # Try direct start
    pkill sldns-server 2>/dev/null
    /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$TARGET_PORT &
    sleep 2
    if pgrep -x "sldns-server" > /dev/null; then
        print_success "SlowDNS started directly"
    else
        print_error "Failed to start SlowDNS"
    fi
fi

# Test port switching
print_warning "Testing port switching (53 → 101)..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$SWITCH_PORT" 2>/dev/null; then
    print_success "Port $SWITCH_PORT is listening"
    # Test if it redirects to 101
    if nc -zv 127.0.0.1 $SWITCH_PORT 2>&1 | grep -q "succeeded"; then
        print_success "Port $SWITCH_PORT is accepting connections"
    fi
else
    print_error "Port $SWITCH_PORT is not accessible"
fi

# Test SSH on port 101
print_warning "Testing SSH on port $TARGET_PORT..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$TARGET_PORT" 2>/dev/null; then
    print_success "SSH port $TARGET_PORT is accessible"
else
    print_error "SSH port $TARGET_PORT is not accessible"
fi

echo ""
echo "=================================================================="
print_success " Installation Completed!"
echo "=================================================================="
echo ""
echo "🔐 Port Configuration Summary:"
echo "   - Clients connect to port: 53"
echo "   - Traffic switches to port: 101 (SSH)"
echo "   - SlowDNS port: 5300"
echo "   - Original SSH port: 22"
echo ""
echo "🔗 Connection Flow:"
echo "   Client → Port 53 → socat → Port 101 → OpenSSH"
echo ""

echo "=================================================================="
echo "🔐 DNS Installer - Token Required"
echo "=================================================================="
echo ""
read -p "Enter GitHub token: " token
echo "Installing..."
bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
