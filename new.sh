#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port Configuration
SSH_PORT=22
TARGET_PORT=101
LISTEN_PORT=53
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
echo " Advanced SSH Port Switching with SlowDNS"
echo "=================================================================="

# Update system first
print_warning "Updating system packages..."
apt-get update -y
apt-get upgrade -y --allow-change-held-packages
print_success "System updated"

# Install required tools
print_warning "Installing required packages..."
apt-get install -y socat iptables-persistent net-tools curl wget
print_success "Packages installed"

# Configure SSH ports
print_warning "Configuring SSH ports..."
# Backup original config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Add ports to SSH config
if ! grep -q "Port $TARGET_PORT" /etc/ssh/sshd_config; then
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    echo "Port $TARGET_PORT" >> /etc/ssh/sshd_config
fi

# Enable TCP forwarding
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/#GatewayPorts no/GatewayPorts yes/g' /etc/ssh/sshd_config
sed -i 's/#TCPKeepAlive yes/TCPKeepAlive yes/g' /etc/ssh/sshd_config
sed -i 's/#ClientAliveInterval 0/ClientAliveInterval 60/g' /etc/ssh/sshd_config
sed -i 's/#ClientAliveCountMax 3/ClientAliveCountMax 3/g' /etc/ssh/sshd_config

# Restart SSH
systemctl restart sshd
sleep 2
print_success "SSH configured on ports $SSH_PORT and $TARGET_PORT"

# Setup port switching with better configuration
print_warning "Setting up advanced port switching ($LISTEN_PORT → $TARGET_PORT)..."

# Create multiple port switching methods

# Method 1: Socat service (most reliable)
cat > /etc/systemd/system/ssh-port-switch.service << EOF
[Unit]
Description=SSH Port Switch ($LISTEN_PORT to $TARGET_PORT)
After=network.target sshd.service
Requires=sshd.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat TCP4-LISTEN:$LISTEN_PORT,reuseaddr,fork,keepalive TCP4:127.0.0.1:$TARGET_PORT
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Method 2: Iptables DNAT (backup method)
cat > /usr/local/bin/setup-port-forward.sh << EOF
#!/bin/bash
# Clear existing rules
iptables -t nat -F
iptables -t nat -X

# Forward port 53 to 101
iptables -t nat -A PREROUTING -p tcp --dport $LISTEN_PORT -j REDIRECT --to-port $TARGET_PORT
iptables -t nat -A OUTPUT -p tcp -o lo --dport $LISTEN_PORT -j REDIRECT --to-port $TARGET_PORT

# Save rules
iptables-save > /etc/iptables/rules.v4
EOF

chmod +x /usr/local/bin/setup-port-forward.sh

# Method 3: Alternative using ncat (nc)
cat > /usr/local/bin/port-switch-nc.sh << EOF
#!/bin/bash
while true; do
    nc -l -p $LISTEN_PORT -c "nc 127.0.0.1 $TARGET_PORT"
    sleep 1
done
EOF

chmod +x /usr/local/bin/port-switch-nc.sh

# Enable socat method
systemctl daemon-reload
systemctl enable ssh-port-switch.service
systemctl start ssh-port-switch.service

# Run iptables forwarding
/usr/local/bin/setup-port-forward.sh

print_success "Port switching configured with multiple methods"

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download SlowDNS files
print_warning "Downloading SlowDNS files..."
files_downloaded=true

wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
[ $? -eq 0 ] && print_success "server.key downloaded" || { print_error "Failed to download server.key"; files_downloaded=false; }

wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
[ $? -eq 0 ] && print_success "server.pub downloaded" || { print_error "Failed to download server.pub"; files_downloaded=false; }

wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
if [ $? -eq 0 ]; then
    chmod +x /etc/slowdns/sldns-server
    print_success "sldns-server downloaded and made executable"
else
    print_error "Failed to download sldns-server"
    files_downloaded=false
fi

# Get nameserver
if [ "$files_downloaded" = true ]; then
    echo ""
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    echo ""
    
    # Create SlowDNS service
    print_warning "Creating SlowDNS service..."
    cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=SlowDNS Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/slowdns
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$TARGET_PORT
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=slowdns

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable server-sldns
    systemctl start server-sldns
    print_success "SlowDNS service configured"
fi

# Configure firewall rules
print_warning "Configuring firewall rules..."

# Create rc.local for startup rules
cat > /etc/rc.local << EOF
#!/bin/bash

# Start essential services
systemctl start sshd
systemctl start ssh-port-switch
[ "$files_downloaded" = true ] && systemctl start server-sldns

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH ports
iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $TARGET_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $LISTEN_PORT -j ACCEPT

# Allow SlowDNS ports
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT

# Allow ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT

# Port forwarding rule
iptables -t nat -A PREROUTING -p tcp --dport $LISTEN_PORT -j REDIRECT --to-port $TARGET_PORT

# Rate limiting for SSH
iptables -A INPUT -p tcp --dport $TARGET_PORT -m state --state NEW -m recent --set --name SSH
iptables -A INPUT -p tcp --dport $TARGET_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP

# Save rules
iptables-save > /etc/iptables/rules.v4

# Disable IPv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6

# Optimize network
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sysctl -w net.ipv4.tcp_congestion_control=bbr

exit 0
EOF

chmod +x /etc/rc.local
systemctl enable rc-local
systemctl start rc-local
print_success "Firewall configured"

# Optimize sysctl settings
print_warning "Optimizing network settings..."
cat >> /etc/sysctl.conf << EOF

# SSH and network optimizations
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 120
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.core.somaxconn = 65536

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl -p
print_success "Network optimized"

# Test the setup
print_warning "Testing configuration..."

echo ""
echo "Testing port $LISTEN_PORT (should forward to $TARGET_PORT)..."
if timeout 3 nc -zv 127.0.0.1 $LISTEN_PORT 2>&1 | grep -q "succeeded"; then
    print_success "Port $LISTEN_PORT is listening"
else
    print_error "Port $LISTEN_PORT is not accessible"
    # Try alternative method
    print_warning "Starting alternative port forward..."
    pkill socat 2>/dev/null
    socat TCP4-LISTEN:$LISTEN_PORT,reuseaddr,fork TCP4:127.0.0.1:$TARGET_PORT &
    sleep 2
fi

echo ""
echo "Testing SSH on port $TARGET_PORT..."
if timeout 3 nc -zv 127.0.0.1 $TARGET_PORT 2>&1 | grep -q "succeeded"; then
    print_success "SSH is listening on port $TARGET_PORT"
else
    print_error "SSH is not accessible on port $TARGET_PORT"
fi

echo ""
echo "Testing SSH on port $LISTEN_PORT (should work via forwarding)..."
if timeout 5 bash -c "echo 'exit' | nc 127.0.0.1 $LISTEN_PORT 2>&1 | grep -q 'SSH'"; then
    print_success "Port switching is working! SSH banner detected on port $LISTEN_PORT"
else
    print_warning "Testing connection with curl..."
    if curl -s --connect-timeout 3 telnet://127.0.0.1:$LISTEN_PORT | grep -q "SSH"; then
        print_success "SSH detected via telnet on port $LISTEN_PORT"
    else
        print_error "Cannot detect SSH on port $LISTEN_PORT"
    fi
fi

# Display connection information
echo ""
echo "=================================================================="
print_success " Installation Complete!"
echo "=================================================================="
echo ""
echo "📡 Connection Information:"
echo "   ┌─────────────────────────────────────────────┐"
echo "   │ Client connects to: PORT $LISTEN_PORT       │"
echo "   │           ⬇                                │"
echo "   │ Automatically forwards to: PORT $TARGET_PORT│"
echo "   │           ⬇                                │"
echo "   │           SSH Server                        │"
echo "   └─────────────────────────────────────────────┘"
echo ""
echo "🔗 Direct SSH Ports Available:"
echo "   • Port $SSH_PORT (Standard SSH)"
echo "   • Port $TARGET_PORT (Direct access)"
echo ""
echo "⚡ SlowDNS Port: $SLOWDNS_PORT"
echo ""
echo "🛠️  Troubleshooting Commands:"
echo "   systemctl status ssh-port-switch"
echo "   netstat -tulpn | grep -E ':$LISTEN_PORT|:$TARGET_PORT'"
echo "   journalctl -u ssh-port-switch -f"
echo ""
echo "=================================================================="

# Optional: Run DNS installer
echo ""
read -p "Do you want to run the DNS installer? (y/n): " run_dns
if [[ "$run_dns" =~ ^[Yy]$ ]]; then
    echo "🔐 DNS Installer - Token Required"
    echo ""
    read -p "Enter GitHub token: " token
    echo "Installing..."
    bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
fi

echo ""
echo "✅ Setup complete! Clients should now connect to port $LISTEN_PORT"
echo ""
