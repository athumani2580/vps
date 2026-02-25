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
echo "            OpenSSH SlowDNS Installation with Go Banner"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure SSH ports with custom Go banner
print_warning "Configuring SSH ports with SSH-2.0-Go banner..."

# Backup original config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)

# Clear existing port configurations and add new ones
sed -i '/^Port /d' /etc/ssh/sshd_config
echo "Port 22" >> /etc/ssh/sshd_config
echo "Port 69" >> /etc/ssh/sshd_config

# Enable TCP forwarding
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config

# Create custom Go banner
cat > /etc/ssh/ssh-banner.txt << 'EOF'
SSH-2.0-Go
EOF

# Configure SSH to use custom banner and hide OpenSSH version
sed -i 's/^#Banner/Banner/g' /etc/ssh/sshd_config
sed -i 's/^Banner.*/Banner \/etc\/ssh\/ssh-banner.txt/g' /etc/ssh/sshd_config

# Add DebianBanner no if not exists
if ! grep -q "^DebianBanner" /etc/ssh/sshd_config; then
    echo "DebianBanner no" >> /etc/ssh/sshd_config
else
    sed -i 's/^#DebianBanner.*/DebianBanner no/g' /etc/ssh/sshd_config
    sed -i 's/^DebianBanner.*/DebianBanner no/g' /etc/ssh/sshd_config
fi

# Add VersionAddendum
if ! grep -q "^VersionAddendum" /etc/ssh/sshd_config; then
    echo "VersionAddendum Go" >> /etc/ssh/sshd_config
else
    sed -i 's/^VersionAddendum.*/VersionAddendum Go/g' /etc/ssh/sshd_config
fi

# Restart SSH service
systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
sleep 2
print_success "SSH configured on ports 22 and 69 with SSH-2.0-Go banner"

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
Description=Server SlowDNS with SSH-2.0-Go Banner
Documentation=https://github.com/athumani2580
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local << 'EOF'
#!/bin/sh -e
systemctl start sshd

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
iptables -A INPUT -p tcp --dport 69 -j ACCEPT
iptables -A INPUT -p udp --dport 5300 -j ACCEPT
iptables -A INPUT -p tcp --dport 5300 -j ACCEPT
iptables -A OUTPUT -p udp --dport 5300 -j ACCEPT
iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A OUTPUT -j ACCEPT
iptables -A INPUT -m state --state INVALID -j DROP

iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

exit 0
EOF

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

# Verify SSH banner
print_warning "Verifying SSH banner configuration..."
sleep 2
SSH_BANNER_CHECK=$(timeout 2 ssh -v localhost -p 69 2>&1 | grep "banner" || echo "")
if [ -n "$SSH_BANNER_CHECK" ]; then
    print_success "SSH banner configured"
else
    # Additional method for some systems
    echo "SSH-2.0-Go" > /etc/issue.net
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null
    print_success "SSH banner reconfigured with alternative method"
fi

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns

sleep 3

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
    
    # Test SlowDNS
    print_warning "Testing SlowDNS functionality..."
    sleep 2
    
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_error "SlowDNS not responding on port $SLOWDNS_PORT"
        
        # Try direct start
        pkill sldns-server 2>/dev/null
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69 &
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

# Test SSH connection with Go banner
print_warning "Testing SSH connection on port 69..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
    
    # Capture banner
    BANNER_OUTPUT=$(timeout 3 nc -v 127.0.0.1 69 2>&1 | head -1 || echo "")
    if [[ "$BANNER_OUTPUT" == *"SSH-2.0-Go"* ]]; then
        print_success "SSH banner verified: SSH-2.0-Go"
    else
        print_warning "SSH banner might not be set correctly. Got: $BANNER_OUTPUT"
    fi
else
    print_error "SSH port 69 is not accessible"
fi

echo ""
echo "=================================================================="
print_success "    OpenSSH SlowDNS Installation with Go Banner Completed!"
echo "=================================================================="
echo ""
echo "📋 Installation Summary:"
echo "   • SSH Ports: 22, 69"
echo "   • SSH Banner: SSH-2.0-Go"
echo "   • SlowDNS Port: $SLOWDNS_PORT"
echo "   • Nameserver: $NAMESERVER"
echo "   • Server IP: $SERVER_IP"
echo ""
echo "🔍 Verification Commands:"
echo "   • Check SSH banner: nc -v $SERVER_IP 69"
echo "   • Check SSH: ssh -v localhost -p 69 2>&1 | grep banner"
echo "   • Check SlowDNS: netstat -ulnp | grep $SLOWDNS_PORT"
echo ""
echo "⚠️  Note: The SSH banner now shows 'SSH-2.0-Go' to match your PuTTY logs"
echo ""

echo "🔐 DNS Installer - Token Required"
echo ""
read -p "Enter GitHub token: " token

echo "Installing..."
bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/alien.sh")
