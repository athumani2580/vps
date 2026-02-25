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

# Check OS compatibility
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        
        if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
            print_success "Compatible OS detected: $PRETTY_NAME"
        else
            print_error "This script only supports Ubuntu and Debian"
            echo "Detected OS: $PRETTY_NAME"
            exit 1
        fi
    else
        print_error "Cannot detect OS version"
        exit 1
    fi
}

# Check root
check_root
check_os

echo "=================================================================="
echo "           OpenSSH SlowDNS Installation (Ubuntu/Debian)"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Install required packages
print_warning "Installing required packages..."
apt-get update -qq
apt-get install -y -qq wget curl iptables-persistent net-tools dnsutils
print_success "Required packages installed"

# Configure SSH ports
print_warning "Configuring SSH ports..."

# Backup original sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Check if ports already exist
if ! grep -q "^Port 22" /etc/ssh/sshd_config; then
    echo "Port 22" >> /etc/ssh/sshd_config
fi

if ! grep -q "^Port 69" /etc/ssh/sshd_config; then
    echo "Port 69" >> /etc/ssh/sshd_config
fi

# Enable TCP forwarding
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config

# Restart SSH service (different service names on Ubuntu/Debian)
if systemctl list-unit-files | grep -q ssh.service; then
    systemctl restart ssh.service 2>/dev/null
elif systemctl list-unit-files | grep -q sshd.service; then
    systemctl restart sshd.service 2>/dev/null
else
    service ssh restart 2>/dev/null
    service sshd restart 2>/dev/null
fi

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

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS ALIEN
Documentation=https://man himself
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

# Startup config with iptables (Ubuntu/Debian compatible)
print_warning "Setting up iptables and startup configuration..."

# Create iptables script
cat > /etc/iptables-rules.sh << 'EOF'
#!/bin/sh
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
EOF

chmod +x /etc/iptables-rules.sh

# Create rc.local for older systems or use systemd for newer ones
if [ -f /etc/rc.local ]; then
    cp /etc/rc.local /etc/rc.local.backup
fi

cat > /etc/rc.local << EOF
#!/bin/sh -e
/etc/iptables-rules.sh
exit 0
EOF

chmod +x /etc/rc.local

# Enable rc.local service for systems that use it
if systemctl list-unit-files | grep -q rc-local; then
    systemctl enable rc-local > /dev/null 2>&1
    systemctl start rc-local > /dev/null 2>&1
fi

# Save iptables rules for persistence
if command -v netfilter-persistent > /dev/null 2>&1; then
    /etc/iptables-rules.sh
    netfilter-persistent save > /dev/null 2>&1
    systemctl enable netfilter-persistent > /dev/null 2>&1
elif command -v iptables-save > /dev/null 2>&1; then
    /etc/iptables-rules.sh
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules
fi

print_success "Firewall rules configured"

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1

# Check if sysctl.conf entries exist
if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf; then
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
fi

sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# DNS configuration (Ubuntu/Debian specific)
print_warning "Configuring DNS settings..."

# Handle systemd-resolved differently based on OS version
if [[ "$OS" == "ubuntu" ]] && [[ "$VERSION" == "20.04" || "$VERSION" == "22.04" || "$VERSION" == "24.04" ]]; then
    # Ubuntu 20.04+ uses systemd-resolved
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    pkill -9 systemd-resolved 2>/dev/null
elif [[ "$OS" == "debian" ]] && [[ "$VERSION" == "10" || "$VERSION" == "11" || "$VERSION" == "12" ]]; then
    # Debian 10+ also uses systemd-resolved sometimes
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
fi

# Remove immutable attribute if set
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured with Google and Cloudflare DNS servers"

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
    
    if command -v nc > /dev/null 2>&1; then
        if nc -zu 127.0.0.1 $SLOWDNS_PORT 2>/dev/null; then
            print_success "SlowDNS is listening on port $SLOWDNS_PORT"
        else
            print_warning "SlowDNS port test inconclusive"
        fi
    elif timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
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

# Test SSH connection
print_warning "Testing SSH connection..."
if command -v nc > /dev/null 2>&1; then
    if nc -z 127.0.0.1 69 2>/dev/null; then
        print_success "SSH port 69 is accessible"
    else
        print_error "SSH port 69 is not accessible"
    fi
elif timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
else
    print_error "SSH port 69 is not accessible"
fi

# Show OS info
echo ""
echo "=================================================================="
print_success "   OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="
echo "OS: $PRETTY_NAME"
echo "Server IP: $SERVER_IP"
echo "SSH Ports: 22, 69"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "Nameserver: $NAMESERVER"
echo "=================================================================="

# Ask for GitHub token
echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

# Download and run the second script with token
curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/alien.sh" -o /tmp/alien.sh
if [ $? -eq 0 ]; then
    bash /tmp/alien.sh
    rm -f /tmp/alien.sh
else
    print_error "Failed to download additional script"
fi

echo ""
print_success "Installation process completed!"
echo "=================================================================="
