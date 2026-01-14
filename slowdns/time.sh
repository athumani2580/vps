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
echo "                 Fast SlowDNS Installation"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Configure SSH ports
{
print_warning "Configuring SSH ports..."
echo "Port 22" >> /etc/ssh/sshd_config
echo "Port 2222" >> /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null &
print_success "SSH configured on ports 22 and 2222 with TCP forwarding enabled"
} &

# Setup SlowDNS directory
{
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"
} &

# Download files in parallel
print_warning "Downloading SlowDNS files..."
{
wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" && \
print_success "server.key downloaded" || \
print_error "Failed to download server.key"
} &

{
wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" && \
print_success "server.pub downloaded" || \
print_error "Failed to download server.pub"
} &

{
wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server" && \
chmod +x /etc/slowdns/sldns-server && \
print_success "sldns-server downloaded and permissions set" || \
print_error "Failed to download sldns-server"
} &

wait

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS ALIEN
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:2222
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
{
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport $SSHD_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport 2222 -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A OUTPUT -j ACCEPT
iptables -A INPUT -m state --state INVALID -j DROP

iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

iptables -A INPUT -p tcp --dport 2222 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 2222 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Save iptables rules
iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.up.rules 2>/dev/null

# Create rc.local
cat > /etc/rc.local <<-END
#!/bin/sh -e
iptables-restore < /etc/iptables/rules.v4 2>/dev/null || iptables-restore < /etc/iptables.up.rules 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1 || true
systemctl start rc-local.service > /dev/null 2>&1 || true
print_success "Startup configuration set"
} &

# Disable IPv6
{
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"
} &

# Disable systemd-resolved and set custom DNS to Google DNS
{
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured with Google DNS servers (8.8.8.8 and 8.8.4.4)"
} &

wait

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns

sleep 2

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
    
    # Quick test
    if ss -uln | grep -q ":$SLOWDNS_PORT"; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_warning "Starting SlowDNS directly..."
        pkill sldns-server 2>/dev/null
        nohup /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT > /dev/null 2>&1 &
        sleep 1
        if pgrep -x "sldns-server" > /dev/null; then
            print_success "SlowDNS started directly"
        else
            print_error "Failed to start SlowDNS"
        fi
    fi
else
    print_error "SlowDNS service failed to start"
fi

# Quick SSH test
print_warning "Testing SSH connections..."
if ss -tln | grep -q ":22 "; then
    print_success "SSH port 22 is accessible"
else
    print_error "SSH port 22 is not accessible"
fi

if ss -tln | grep -q ":2222 "; then
    print_success "SSH port 2222 is accessible"
else
    print_error "SSH port 2222 is not accessible"
fi

echo ""
echo "=================================================================="
print_success "           SlowDNS Installation Completed!"
echo "=================================================================="

echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

# Remove resolv.conf lock
chattr -i /etc/resolv.conf 2>/dev/null || true

# Run the next script
if [ -n "$token" ]; then
    curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/full.sh" | bash
else
    print_error "No token provided, skipping additional installation"
fi

echo ""
echo "=================================================================="
print_success "              Installation Fully Completed!"
echo "=================================================================="
echo ""
echo "📋 Summary:"
echo "• SSH Ports: 22, 2222"
echo "• SlowDNS Port: $SLOWDNS_PORT"
echo "• Nameserver: $NAMESERVER"
echo "• DNS Servers: 8.8.8.8, 8.8.4.4"
echo "• Server IP: $SERVER_IP"
echo "=================================================================="
