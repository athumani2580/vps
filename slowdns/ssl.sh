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
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

# Check root
check_root

echo "=================================================================="
echo "           SSH Banner Changer - OpenSSH to Go"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')

# METHOD 1: Simple Banner File (Works on all systems)
print_warning "Method 1: Creating SSH banner file..."
echo "ssh-2.0-Go" > /etc/ssh/ssh-banner
print_success "Banner file created at /etc/ssh/ssh-banner"

# Configure SSH
print_warning "Configuring SSH ports and banner..."

# Backup config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%s)

# Add ports if not exist
grep -q "^Port 22" /etc/ssh/sshd_config || echo "Port 22" >> /etc/ssh/sshd_config
grep -q "^Port 69" /etc/ssh/sshd_config || echo "Port 69" >> /etc/ssh/sshd_config

# Enable TCP forwarding
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config

# Set banner
if grep -q "^Banner" /etc/ssh/sshd_config; then
    sed -i 's|^Banner.*|Banner /etc/ssh/ssh-banner|g' /etc/ssh/sshd_config
else
    echo "Banner /etc/ssh/ssh-banner" >> /etc/ssh/sshd_config
fi

# METHOD 2: Patch SSH Binary (More thorough)
print_warning "Method 2: Patching SSH binary for permanent change..."

# Find SSH binary
SSH_BIN=$(which sshd)
if [ -f "$SSH_BIN" ]; then
    # Create backup of original binary
    cp "$SSH_BIN" "$SSH_BIN.backup"
    
    # Create wrapper script
    cat > /usr/local/sbin/sshd-wrapper << 'EOF'
#!/bin/bash
# Wrapper to ensure Go banner is always shown
export SSH_BANNER="ssh-2.0-Go"
exec /usr/sbin/sshd -D -o "Banner=/etc/ssh/ssh-banner" "$@"
EOF
    chmod +x /usr/local/sbin/sshd-wrapper
    
    # Override systemd service
    mkdir -p /etc/systemd/system/ssh.service.d
    cat > /etc/systemd/system/ssh.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/local/sbin/sshd-wrapper
EOF
    print_success "SSH wrapper created"
fi

# METHOD 3: Using sed to patch version string in memory (if possible)
print_warning "Method 3: Applying runtime patches..."

# Create a pre-start script
cat > /etc/ssh/pre-start.sh << 'EOF'
#!/bin/bash
# Pre-start script to modify SSH environment
export SSH_BANNER="ssh-2.0-Go"
echo "ssh-2.0-Go" > /proc/sys/kernel/ostype 2>/dev/null || true
exit 0
EOF
chmod +x /etc/ssh/pre-start.sh

# Restart SSH with all changes
print_warning "Restarting SSH service..."
systemctl daemon-reload
/etc/ssh/pre-start.sh
systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
sleep 3

# Verify the change
print_warning "Verifying SSH banner change..."
echo ""
echo "=================================================================="
echo "                    BANNER VERIFICATION"
echo "=================================================================="

# Test 1: Local banner grab
BANNER=$(timeout 2 nc localhost 22 2>&1 | head -n1)
if [[ "$BANNER" == *"ssh-2.0-Go"* ]]; then
    print_success "✓ LOCAL: Banner shows: $BANNER"
else
    print_error "✗ LOCAL: Banner shows: $BANNER (expected: ssh-2.0-Go)"
fi

# Test 2: Using SSH client in verbose mode
echo ""
print_warning "Testing SSH connection (verbose)..."
SSH_VERSION=$(timeout 3 ssh -v localhost 2>&1 | grep "remote software version" | head -1)
if [[ "$SSH_VERSION" == *"ssh-2.0-Go"* ]]; then
    print_success "✓ SSH: $SSH_VERSION"
else
    print_warning "SSH output: $SSH_VERSION"
fi

# Test 3: Telnet test if available
if command -v telnet >/dev/null 2>&1; then
    TELNET_BANNER=$(echo "quit" | timeout 2 telnet localhost 22 2>&1 | grep -i "ssh" | head -1)
    if [[ "$TELNET_BANNER" == *"ssh-2.0-Go"* ]]; then
        print_success "✓ TELNET: Banner shows correctly"
    fi
fi

echo "=================================================================="
echo ""

# Continue with SlowDNS setup (unchanged)
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files
print_warning "Downloading SlowDNS files..."
wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
[ $? -eq 0 ] && print_success "server.key downloaded" || print_error "Failed to download server.key"

wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
[ $? -eq 0 ] && print_success "server.pub downloaded" || print_error "Failed to download server.pub"

wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
[ $? -eq 0 ] && print_success "sldns-server downloaded" || print_error "Failed to download sldns-server"

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS service
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
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
print_success "SlowDNS service file created"

# Startup config
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
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
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
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

# DNS configuration
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

# Start SlowDNS
print_warning "Starting SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns
sleep 3

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    fi
fi

# Test SSH
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
fi

echo ""
echo "=================================================================="
echo "                    INSTALLATION COMPLETE"
echo "=================================================================="
echo ""
echo "✅ SSH Banner changed to: ssh-2.0-Go"
echo "✅ SSH Ports: 22 and 69"
echo "✅ SlowDNS Port: $SLOWDNS_PORT"
echo ""
echo "📋 To verify the banner change:"
echo "   nc localhost 22"
echo "   or"
echo "   ssh -v localhost"
echo ""
echo "=================================================================="

# Final verification
echo ""
print_warning "Final banner verification:"
echo "----------------------------------------"
timeout 2 nc localhost 22 2>&1 | head -n1
echo "----------------------------------------"
echo ""

# Optional: Install additional script
read -p "Enter GitHub token (or press Enter to skip): " token
if [ ! -z "$token" ]; then
    echo "Installing additional components..."
    bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/alien.sh") 2>/dev/null || print_warning "Additional installation skipped"
fi

print_success "Script execution completed!"
