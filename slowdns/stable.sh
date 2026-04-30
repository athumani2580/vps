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

# Install and Configure Fail2ban
print_warning "Installing and configuring Fail2ban..."

# Install fail2ban
if command -v apt-get &> /dev/null; then
    apt-get update -qq
    apt-get install -y fail2ban -qq
elif command -v yum &> /dev/null; then
    yum install -y fail2ban -q
elif command -v dnf &> /dev/null; then
    dnf install -y fail2ban -q
else
    print_error "Package manager not supported. Please install fail2ban manually."
fi

# Create fail2ban local configuration
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ssh,22,69
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 3600
findtime = 600

[sshd-ddos]
enabled = true
port = ssh,22,69
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime = 7200
findtime = 600

# Custom jail for slowdns attacks
[slowdns]
enabled = true
port = 5300
protocol = udp
filter = slowdns
logpath = /var/log/slowdns.log
maxretry = 10
bantime = 3600
findtime = 600
EOF

# Create custom filter for slowdns
cat > /etc/fail2ban/filter.d/slowdns.conf << 'EOF'
[Definition]
failregex = ^.*Failed authentication from <HOST>.*$
            ^.*Invalid request from <HOST>.*$
            ^.*Connection attempt from <HOST>.*$
ignoreregex =
EOF

# Create log file for slowdns if it doesn't exist
touch /var/log/slowdns.log
chmod 644 /var/log/slowdns.log

# Configure slowdns to log to file
print_warning "Configuring SlowDNS logging..."
cat >> /etc/systemd/system/server-sldns.service << EOF

# Logging configuration
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log
EOF

# Restart fail2ban
systemctl restart fail2ban 2>/dev/null
systemctl enable fail2ban 2>/dev/null

# Check if fail2ban is running
if systemctl is-active --quiet fail2ban; then
    print_success "Fail2ban installed and configured successfully"
    
    # Display fail2ban status
    print_warning "Fail2ban jails status:"
    fail2ban-client status
else
    print_error "Fail2ban failed to start. Please check configuration."
fi

# Configure fail2ban for iptables persistence
print_warning "Configuring iptables persistence for fail2ban..."
if command -v apt-get &> /dev/null; then
    apt-get install -y iptables-persistent -qq
    netfilter-persistent save > /dev/null 2>&1
elif command -v yum &> /dev/null; then
    yum install -y iptables-services -q
    service iptables save > /dev/null 2>&1
fi

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/bash
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

# Restore iptables rules for fail2ban
if command -v iptables-restore &> /dev/null; then
    iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true
fi

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

# Test SSH connection
print_warning "Testing SSH connection..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
else
    print_error "SSH port 69 is not accessible"
fi

# Display fail2ban status summary
echo ""
echo "=================================================================="
print_success "           Fail2ban Protection Summary"
echo "=================================================================="
echo ""
fail2ban-client status
echo ""

echo "=================================================================="
print_success "           OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="

echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/man.sh")
