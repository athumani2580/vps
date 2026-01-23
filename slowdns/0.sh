#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Functions
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root: sudo bash $0${NC}"
    exit 1
fi

echo "=========================================="
echo "      OpenSSH + SlowDNS Installer"
echo "=========================================="

# Get configuration
read -p "Enter SSH port (default: 22): " SSHD_PORT
SSHD_PORT=${SSHD_PORT:-22}

read -p "Enter SlowDNS port (default: 5300): " SLOWDNS_PORT
SLOWDNS_PORT=${SLOWDNS_PORT:-5300}

read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
if [ -z "$NAMESERVER" ]; then
    print_error "Nameserver is required!"
    exit 1
fi

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
echo ""
echo "Server IP: $SERVER_IP"
echo "SSH Port: $SSHD_PORT"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "Nameserver: $NAMESERVER"
echo ""

read -p "Continue installation? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo "=========================================="

# Configure SSH
print_warning "Configuring SSH..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null

cat > /etc/ssh/sshd_config << EOF
Port $SSHD_PORT
PermitRootLogin yes
PasswordAuthentication yes
UseDNS no
EOF

systemctl restart ssh
print_success "SSH configured"

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
mkdir -p /etc/slowdns
cd /etc/slowdns

# Download files
print_warning "Downloading files..."
wget -q --timeout=30 -O server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
wget -q --timeout=30 -O server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
wget -q --timeout=30 -O sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"

chmod +x sldns-server
print_success "Files downloaded"

# Create service
print_warning "Creating service..."
cat > /etc/systemd/system/slowdns.service << EOF
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Setup firewall
print_warning "Configuring firewall..."
iptables -F
iptables -A INPUT -p tcp --dport $SSHD_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -P INPUT DROP

# Disable IPv6
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null

# Start SlowDNS
print_warning "Starting SlowDNS..."
systemctl daemon-reload
systemctl enable slowdns
systemctl start slowdns

sleep 3

if systemctl is-active --quiet slowdns; then
    print_success "SlowDNS service started"
else
    print_error "SlowDNS failed to start"
    print_warning "Trying direct start..."
    pkill -f sldns-server 2>/dev/null
    cd /etc/slowdns
    ./sldns-server -udp :$SLOWDNS_PORT -privkey-file server.key $NAMESERVER 127.0.0.1:$SSHD_PORT &
    sleep 2
    if pgrep -x "sldns-server" > /dev/null; then
        print_success "SlowDNS running directly"
    fi
fi

echo ""
echo "=========================================="
print_success "        INSTALLATION COMPLETE!"
echo "=========================================="
echo ""
echo "Server IP:    $SERVER_IP"
echo "SSH Port:     $SSHD_PORT"
echo "DNS Port:     $SLOWDNS_PORT"
echo "Nameserver:   $NAMESERVER"
echo ""
echo "Management:"
echo "  systemctl status slowdns"
echo "  systemctl restart slowdns"
echo "  journalctl -u slowdns -f"
echo ""
