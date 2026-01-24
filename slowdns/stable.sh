#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port Configuration
EXTERNAL_SSH_PORT=22      # External SSH port
INTERNAL_SSH_PORT=69      # Internal SSH port for SlowDNS
SLOWDNS_PORT=5300         # SlowDNS port

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
echo "External SSH Port: $EXTERNAL_SSH_PORT"
echo "Internal SSH Port: $INTERNAL_SSH_PORT"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure OpenSSH on multiple ports
print_warning "Configuring OpenSSH on ports $EXTERNAL_SSH_PORT and $INTERNAL_SSH_PORT..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null

cat > /etc/ssh/sshd_config << EOF
# OpenSSH Configuration
Port $EXTERNAL_SSH_PORT
Port $INTERNAL_SSH_PORT
Protocol 2
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3
AllowTcpForwarding yes
GatewayPorts yes
Compression delayed
Subsystem sftp /usr/lib/openssh/sftp-server
MaxSessions 100
MaxStartups 100:30:200
LoginGraceTime 30
UseDNS no
EOF

systemctl restart sshd
sleep 2
print_success "OpenSSH configured on ports $EXTERNAL_SSH_PORT (external) and $INTERNAL_SSH_PORT (internal)"

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
    wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/server.key"
    print_success "server.key downloaded"
fi

wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
if [ $? -eq 0 ]; then
    print_success "server.pub downloaded"
else
    wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/server.pub"
    print_success "server.pub downloaded"
fi

wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
if [ $? -eq 0 ]; then
    print_success "sldns-server downloaded"
else
    wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
    print_success "sldns-server downloaded"
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS service pointing to INTERNAL SSH port 69
print_warning "Creating SlowDNS service connecting to SSH port $INTERNAL_SSH_PORT..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$INTERNAL_SSH_PORT
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created (connected to SSH port $INTERNAL_SSH_PORT)"

# Create port forwarding from SlowDNS port to SSH port 69
print_warning "Setting up port forwarding and firewall rules..."

# Create startup script with iptables
cat > /etc/rc.local <<-END
#!/bin/sh -e
systemctl start sshd

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH on external port 22
iptables -A INPUT -p tcp --dport $EXTERNAL_SSH_PORT -j ACCEPT

# Allow SlowDNS on UDP port 5300
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT

# Allow internal SSH on port 69
iptables -A INPUT -p tcp --dport $INTERNAL_SSH_PORT -s 127.0.0.1 -j ACCEPT
iptables -A INPUT -p tcp --dport $INTERNAL_SSH_PORT -s 10.0.0.0/8 -j ACCEPT
iptables -A INPUT -p tcp --dport $INTERNAL_SSH_PORT -s 172.16.0.0/12 -j ACCEPT
iptables -A INPUT -p tcp --dport $INTERNAL_SSH_PORT -s 192.168.0.0/16 -j ACCEPT

# Allow ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT

# Drop invalid packets
iptables -A INPUT -m state --state INVALID -j DROP

# SSH brute force protection
iptables -A INPUT -p tcp --dport $EXTERNAL_SSH_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $EXTERNAL_SSH_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Port forwarding: SlowDNS port 5300 -> SSH port 69
iptables -t nat -A PREROUTING -p udp --dport $SLOWDNS_PORT -j DNAT --to-destination 127.0.0.1:$INTERNAL_SSH_PORT
iptables -t nat -A PREROUTING -p tcp --dport $SLOWDNS_PORT -j DNAT --to-destination 127.0.0.1:$INTERNAL_SSH_PORT
iptables -A FORWARD -p udp --dport $INTERNAL_SSH_PORT -d 127.0.0.1 -j ACCEPT
iptables -A FORWARD -p tcp --dport $INTERNAL_SSH_PORT -d 127.0.0.1 -j ACCEPT

# Disable IPv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6

# Optimize network buffers
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" > /dev/null 2>&1
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" > /dev/null 2>&1

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1
print_success "Startup configuration with port forwarding set"

# Apply iptables rules immediately
bash /etc/rc.local

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# Disable systemd-resolved and set static DNS
print_warning "Disabling systemd-resolved and setting static DNS..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null

rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "systemd-resolved disabled and static DNS configured"

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
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$INTERNAL_SSH_PORT &
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

# Test SSH connections
print_warning "Testing SSH connections..."
echo "Testing external SSH port $EXTERNAL_SSH_PORT..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$EXTERNAL_SSH_PORT" 2>/dev/null; then
    print_success "SSH port $EXTERNAL_SSH_PORT is accessible"
else
    print_error "SSH port $EXTERNAL_SSH_PORT is not accessible"
fi

echo "Testing internal SSH port $INTERNAL_SSH_PORT..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$INTERNAL_SSH_PORT" 2>/dev/null; then
    print_success "SSH port $INTERNAL_SSH_PORT is accessible"
else
    print_error "SSH port $INTERNAL_SSH_PORT is not accessible"
fi

# Test SlowDNS to SSH port forwarding
print_warning "Testing SlowDNS to SSH port forwarding..."
echo "Simulating SlowDNS connection to SSH port $INTERNAL_SSH_PORT..."
if nc -z -u 127.0.0.1 $SLOWDNS_PORT 2>/dev/null; then
    print_success "SlowDNS port $SLOWDNS_PORT is listening"
else
    print_error "SlowDNS port $SLOWDNS_PORT is not listening"
fi

echo ""
echo "=================================================================="
print_success "           OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="
echo ""
echo "Server IP: $SERVER_IP"
echo "External SSH Port: $EXTERNAL_SSH_PORT (direct access)"
echo "Internal SSH Port: $INTERNAL_SSH_PORT (for SlowDNS)"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "MTU: 1800"
echo "Nameserver: $NAMESERVER"
echo ""
echo "Network Flow:"
echo "  External Client → SlowDNS Port $SLOWDNS_PORT → SSH Port $INTERNAL_SSH_PORT"
echo "  Direct SSH Access → SSH Port $EXTERNAL_SSH_PORT"
echo "=================================================================="
echo ""
echo "Management Commands:"
echo "  systemctl start server-sldns      # Start SlowDNS"
echo "  systemctl stop server-sldns       # Stop SlowDNS"
echo "  systemctl status server-sldns     # Check status"
echo "  journalctl -u server-sldns -f     # View logs"
echo "  iptables -L -n -v                 # View firewall rules"
echo "  netstat -tulpn | grep -E '($EXTERNAL_SSH_PORT|$INTERNAL_SSH_PORT|$SLOWDNS_PORT)'"
echo ""

# Create a simple test script
cat > /usr/local/bin/test-ports.sh << EOF
#!/bin/bash
echo "=== Port Testing Script ==="
echo "Server IP: $SERVER_IP"
echo ""
echo "1. Testing SSH Port $EXTERNAL_SSH_PORT (external):"
timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$EXTERNAL_SSH_PORT" 2>/dev/null && echo "✓ OPEN" || echo "✗ CLOSED"
echo ""
echo "2. Testing SSH Port $INTERNAL_SSH_PORT (internal):"
timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$INTERNAL_SSH_PORT" 2>/dev/null && echo "✓ OPEN" || echo "✗ CLOSED"
echo ""
echo "3. Testing SlowDNS Port $SLOWDNS_PORT:"
timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null && echo "✓ LISTENING" || echo "✗ NOT LISTENING"
echo ""
echo "4. Checking services:"
systemctl is-active --quiet server-sldns && echo "✓ SlowDNS service: RUNNING" || echo "✗ SlowDNS service: STOPPED"
systemctl is-active --quiet sshd && echo "✓ SSH service: RUNNING" || echo "✗ SSH service: STOPPED"
EOF

chmod +x /usr/local/bin/test-ports.sh
print_success "Test script created: /usr/local/bin/test-ports.sh"

echo "🔐 DNS Installer - Token Required"
echo ""

# Get GitHub token
read -p "Enter GitHub token: " token

if [ -z "$token" ]; then
    echo "❌ Error: Token cannot be empty!"
    exit 1
fi

echo "📦 Installing..."
echo ""

# Try to download and execute directly
bash <(curl -s -H "Authorization: token $token" \
    -H "Accept: application/vnd.github.v3.raw" \
    "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
