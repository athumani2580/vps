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

# Backup existing services first
print_warning "Backing up existing services..."
if systemctl is-active --quiet sshd; then
    systemctl stop sshd
    sleep 2
    print_success "SSH service stopped for reconfiguration"
fi

if systemctl is-active --quiet server-sldns 2>/dev/null; then
    systemctl stop server-sldns 2>/dev/null
    sleep 2
    print_success "SlowDNS service stopped for reconfiguration"
fi

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure OpenSSH WITHOUT restarting yet
print_warning "Configuring OpenSSH on port $SSHD_PORT..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null

cat > /etc/ssh/sshd_config << EOF
# OpenSSH Configuration
Port $SSHD_PORT
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

print_success "OpenSSH configuration saved"

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files WITHOUT overwriting if they exist
print_warning "Downloading SlowDNS files..."

if [ ! -f /etc/slowdns/server.key ]; then
    wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
    if [ $? -eq 0 ]; then
        print_success "server.key downloaded"
    else
        print_error "Failed to download server.key"
        # Keep existing if download fails
    fi
else
    print_success "Existing server.key preserved"
fi

if [ ! -f /etc/slowdns/server.pub ]; then
    wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
    if [ $? -eq 0 ]; then
        print_success "server.pub downloaded"
    else
        print_error "Failed to download server.pub"
    fi
else
    print_success "Existing server.pub preserved"
fi

if [ ! -f /etc/slowdns/sldns-server ]; then
    wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
    if [ $? -eq 0 ]; then
        chmod +x /etc/slowdns/sldns-server
        print_success "sldns-server downloaded and made executable"
    else
        print_error "Failed to download sldns-server"
        # Check if existing executable exists
        if [ -f /etc/slowdns/sldns-server ]; then
            chmod +x /etc/slowdns/sldns-server
            print_success "Existing sldns-server made executable"
        fi
    fi
else
    chmod +x /etc/slowdns/sldns-server
    print_success "Existing sldns-server preserved and made executable"
fi

# Get nameserver if not already configured
if [ -f /etc/slowdns/nameserver.txt ]; then
    NAMESERVER=$(cat /etc/slowdns/nameserver.txt)
    print_success "Using existing nameserver: $NAMESERVER"
else
    echo ""
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    echo ""
    echo "$NAMESERVER" > /etc/slowdns/nameserver.txt
fi

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Service]
Type=simple
ExecStart=$SLOWDNS_BINARY -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"
systemctl daemon-reload

# Startup config with iptables - DO NOT FLUSH EXISTING RULES
print_warning "Setting up iptables rules..."
cat > /tmp/rc-local-setup.sh <<-END
#!/bin/bash
# Add SSH port if not exists
iptables -C INPUT -p tcp --dport $SSHD_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $SSHD_PORT -j ACCEPT

# Add SlowDNS ports if not exists
iptables -C INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -C INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -C OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT 2>/dev/null || iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT

# Rate limiting for SSH
iptables -C INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --set 2>/dev/null || \
iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --set

iptables -C INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP 2>/dev/null || \
iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# IPv6 disable
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" > /dev/null 2>&1
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" > /dev/null 2>&1

exit 0
END

chmod +x /tmp/rc-local-setup.sh
bash /tmp/rc-local-setup.sh
print_success "Firewall rules configured"

# Create proper rc.local if not exists
if [ ! -f /etc/rc.local ]; then
    cat > /etc/rc.local <<-END
#!/bin/sh -e
# This script will be executed at boot

# Start SSH
systemctl start sshd

# Start SlowDNS
systemctl start server-sldns

# Apply firewall rules
bash /tmp/rc-local-setup.sh

exit 0
END
    chmod +x /etc/rc.local
    systemctl enable rc-local > /dev/null 2>&1 || true
fi

# Disable IPv6 gently
print_warning "Configuring IPv6..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 configuration updated"

# Configure DNS without killing systemd-resolved if it's working
print_warning "Configuring DNS settings..."
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    print_warning "systemd-resolved is active, configuring gently..."
    # Just add our DNS servers
    cat > /etc/resolv.conf << EOF
# Generated by SlowDNS installer
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 127.0.0.53
options edns0 trust-ad
EOF
else
    # systemd-resolved is not running, proceed normally
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
fi
print_success "DNS configured"

# Start services in correct order
print_warning "Starting services..."
print_warning "Starting SSH service..."
systemctl start sshd
sleep 3

if systemctl is-active --quiet sshd; then
    print_success "SSH service started successfully"
else
    print_error "SSH service failed to start, attempting recovery..."
    systemctl restart sshd
    sleep 2
fi

print_warning "Starting SlowDNS service..."
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns
sleep 5

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
else
    print_error "SlowDNS service failed to start"
    print_warning "Attempting direct start..."
    cd /etc/slowdns
    nohup ./sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file server.key $NAMESERVER 127.0.0.1:$SSHD_PORT > /var/log/slowdns.log 2>&1 &
    sleep 3
    
    if pgrep -x "sldns-server" > /dev/null; then
        print_success "SlowDNS started in background"
    else
        print_error "Failed to start SlowDNS. Check logs: /var/log/slowdns.log"
    fi
fi

# Test services
echo ""
print_warning "Testing services..."

# Test SSH
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$SSHD_PORT" 2>/dev/null; then
    print_success "SSH port $SSHD_PORT is accessible"
else
    print_error "SSH port $SSHD_PORT is not accessible"
    print_warning "Trying to restart SSH..."
    systemctl restart sshd
    sleep 2
fi

# Test SlowDNS
if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
    print_success "SlowDNS is listening on port $SLOWDNS_PORT"
else
    print_warning "SlowDNS port test inconclusive, checking process..."
    if pgrep -x "sldns-server" > /dev/null || systemctl is-active --quiet server-sldns; then
        print_success "SlowDNS process is running"
    else
        print_error "SlowDNS is not running"
    fi
fi

# Create monitoring script that doesn't kill processes
print_warning "Creating safe monitoring script..."
cat > /usr/local/bin/monitor-slowdns.sh << 'EOF'
#!/bin/bash
# Safe monitoring script - never kills processes
while true; do
    # Check if SSH is running, start if not
    if ! systemctl is-active --quiet sshd; then
        systemctl start sshd
        echo "[$(date)] SSH service started" >> /var/log/slowdns-monitor.log
    fi
    
    # Check if SlowDNS is running, start if not
    if ! systemctl is-active --quiet server-sldns 2>/dev/null && ! pgrep -x "sldns-server" >/dev/null; then
        systemctl start server-sldns 2>/dev/null || {
            cd /etc/slowdns 2>/dev/null && \
            nohup ./sldns-server -udp :5300 -mtu 1800 -privkey-file server.key $(cat /etc/slowdns/nameserver.txt 2>/dev/null || echo "dns.example.com") 127.0.0.1:22 > /var/log/slowdns.log 2>&1 &
        }
        echo "[$(date)] SlowDNS service started" >> /var/log/slowdns-monitor.log
    fi
    
    sleep 30
done
EOF

chmod +x /usr/local/bin/monitor-slowdns.sh

# Start monitor in background if not already running
if ! pgrep -f "monitor-slowdns.sh" > /dev/null; then
    nohup /usr/local/bin/monitor-slowdns.sh > /dev/null 2>&1 &
    print_success "Safe monitoring script started"
fi

echo ""
echo "=================================================================="
print_success "           OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="

echo ""
echo "Server IP: $SERVER_IP"
echo "SSH Port: $SSHD_PORT"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "Nameserver: $NAMESERVER"
echo ""

# Optional: DNS Installer with token
read -p "Do you want to install DNS token script? (y/N): " install_dns
if [[ "$install_dns" =~ ^[Yy]$ ]]; then
    echo ""
    echo "🔐 DNS Installer - Token Required"
    echo ""
    read -p "Enter GitHub token: " token
    
    if [ -n "$token" ]; then
        echo "Installing..."
        bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/full.sh")
    else
        print_error "No token provided, skipping DNS installer."
    fi
fi

echo ""
print_success "Installation complete! Server should remain running."
print_warning "If you experience issues, reboot the server: reboot"
echo ""
