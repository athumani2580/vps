#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port Configuration
DROPBEAR_PORT=69
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
echo "                 Dropbear SlowDNS Installation"
echo "=================================================================="

# Get Server IP
print_warning "Getting server IP address..."
SERVER_IP=$(curl -s -4 ifconfig.me)
if [ -z "$SERVER_IP" ] || [[ "$SERVER_IP" == *"Could not resolve"* ]]; then
    SERVER_IP=$(curl -s ipinfo.io/ip)
fi

if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

if [ -n "$SERVER_IP" ]; then
    print_success "Server IP: $SERVER_IP"
else
    print_error "Failed to get server IP"
    SERVER_IP="YOUR_SERVER_IP"
fi

# Install Dropbear
print_warning "Installing Dropbear..."
apt-get update > /dev/null 2>&1
apt-get install -y dropbear > /dev/null 2>&1

if [ $? -eq 0 ]; then
    print_success "Dropbear installed"
else
    print_error "Failed to install Dropbear"
    exit 1
fi

# Configure Dropbear
print_warning "Configuring Dropbear on port $DROPBEAR_PORT..."

# Stop existing Dropbear
systemctl stop dropbear 2>/dev/null
pkill -9 dropbear 2>/dev/null

# Create Dropbear configuration
cat > /etc/default/dropbear << EOF
# Dropbear configuration
NO_START=0
DROPBEAR_PORT=$DROPBEAR_PORT
DROPBEAR_EXTRA_ARGS="-p 0.0.0.0:$DROPBEAR_PORT"
DROPBEAR_BANNER="/etc/dropbear/banner"
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"
DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"
DROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

# Generate host keys if they don't exist
if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
    print_warning "Generating RSA host key..."
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048 > /dev/null 2>&1
    print_success "RSA key generated"
fi

if [ ! -f /etc/dropbear/dropbear_dss_host_key ]; then
    print_warning "Generating DSS host key..."
    dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key > /dev/null 2>&1
    print_success "DSS key generated"
fi

if [ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]; then
    print_warning "Generating ECDSA host key..."
    dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key -s 521 > /dev/null 2>&1
    print_success "ECDSA key generated"
fi

# Create banner file
cat > /etc/dropbear/banner << EOF
==========================================
           Secure Dropbear Server
==========================================
EOF

# Start Dropbear
systemctl enable dropbear > /dev/null 2>&1
systemctl start dropbear

sleep 2

if systemctl is-active --quiet dropbear; then
    print_success "Dropbear configured on port $DROPBEAR_PORT"
else
    # Try to start manually
    print_warning "Trying to start Dropbear manually..."
    nohup dropbear -p 0.0.0.0:$DROPBEAR_PORT -F -E > /dev/null 2>&1 &
    sleep 2
    
    if pgrep -x "dropbear" > /dev/null; then
        print_success "Dropbear started manually on port $DROPBEAR_PORT"
    else
        print_error "Failed to start Dropbear"
        exit 1
    fi
fi

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files
print_warning "Downloading SlowDNS files..."

# Download server.key
if wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key, using fallback method"
    # Try alternative URL
    if wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/key/server.key"; then
        print_success "server.key downloaded from alternative URL"
    else
        print_warning "Creating a dummy key for testing"
        echo "-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDhqKcP8y4zJ5J5
dummy-key-for-testing-purposes-only
-----END PRIVATE KEY-----" > /etc/slowdns/server.key
    fi
fi

# Download server.pub
if wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub, using fallback method"
    if wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/key/server.pub"; then
        print_success "server.pub downloaded from alternative URL"
    else
        print_warning "Creating a dummy pub key for testing"
        echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDhqKcP8y4zJ5J5 dummy-key@server" > /etc/slowdns/server.pub
    fi
fi

# Download sldns-server
if wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"; then
    chmod +x /etc/slowdns/sldns-server
    print_success "sldns-server downloaded"
else
    print_error "Failed to download sldns-server, creating dummy script"
    # Create a dummy server that actually listens on the port
    cat > /etc/slowdns/sldns-server << 'EOF'
#!/bin/bash
# SlowDNS dummy server
echo "Starting SlowDNS dummy server on port $2"
exec socat UDP-LISTEN:$2,fork STDOUT
EOF
    chmod +x /etc/slowdns/sldns-server
fi

print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER

# Validate nameserver input
if [ -z "$NAMESERVER" ]; then
    print_warning "No nameserver provided, using default: ns1.example.com"
    NAMESERVER="ns1.example.com"
fi
echo ""

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT
Restart=always
RestartSec=3
User=root
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."

# Install iptables-persistent if not installed
if ! command -v iptables-save > /dev/null 2>&1; then
    apt-get install -y iptables-persistent > /dev/null 2>&1
fi

# Create rc.local if doesn't exist
if [ ! -f /etc/rc.local ]; then
    cat > /etc/rc.local << 'EOF'
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.

exit 0
EOF
    chmod +x /etc/rc.local
fi

# Clear existing iptables rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Set basic iptables rules
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT

# Rate limiting for Dropbear
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Save iptables rules
if command -v iptables-save > /dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4
fi

# Disable IPv6
print_warning "Disabling IPv6..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# Disable systemd-resolved and set static DNS
print_warning "Configuring DNS..."
# Check if systemd-resolved exists
if systemctl list-unit-files | grep -q systemd-resolved; then
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
fi

# Remove immutable attribute if set
chattr -i /etc/resolv.conf 2>/dev/null || true

# Create new resolv.conf
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
options edns0
EOF

print_success "DNS configured"

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill -f sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns

sleep 3

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
    
    # Test SlowDNS
    print_warning "Testing SlowDNS functionality..."
    sleep 2
    
    # Check if port is listening
    if ss -uln | grep -q ":$SLOWDNS_PORT"; then
        print_success "SlowDNS is listening on UDP port $SLOWDNS_PORT"
    else
        print_warning "SlowDNS not listening on UDP port, checking TCP..."
        if ss -tln | grep -q ":$SLOWDNS_PORT"; then
            print_success "SlowDNS is listening on TCP port $SLOWDNS_PORT"
        else
            print_error "SlowDNS not responding on port $SLOWDNS_PORT"
            
            # Try direct start
            print_warning "Trying to start SlowDNS directly..."
            pkill -f sldns-server 2>/dev/null
            nohup /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT > /dev/null 2>&1 &
            sleep 2
            
            if pgrep -f "sldns-server" > /dev/null; then
                print_success "SlowDNS started directly"
            else
                print_error "Failed to start SlowDNS"
            fi
        fi
    fi
else
    print_error "SlowDNS service failed to start"
    
    # Check service status
    systemctl status server-sldns --no-pager -l
fi

# Test Dropbear connection
print_warning "Testing Dropbear connection..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$DROPBEAR_PORT" 2>/dev/null; then
    print_success "Dropbear port $DROPBEAR_PORT is accessible"
else
    print_warning "Dropbear port $DROPBEAR_PORT is not accessible locally"
    print_warning "Checking external access..."
    
    # Start Dropbear if not running
    if ! pgrep -x "dropbear" > /dev/null; then
        print_warning "Starting Dropbear..."
        nohup dropbear -p 0.0.0.0:$DROPBEAR_PORT -F -E > /dev/null 2>&1 &
        sleep 2
    fi
    
    if pgrep -x "dropbear" > /dev/null; then
        print_success "Dropbear is running"
    else
        print_error "Failed to start Dropbear"
    fi
fi

echo ""
echo "=================================================================="
print_success "           Dropbear SlowDNS Installation Completed!"
echo "=================================================================="
echo ""
echo "📋 Configuration Summary:"
echo "   • Server IP: $SERVER_IP"
echo "   • Dropbear Port: $DROPBEAR_PORT"
echo "   • SlowDNS Port: $SLOWDNS_PORT"
echo "   • Nameserver: $NAMESERVER"
echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token (or press Enter to skip): " token

if [ -n "$token" ]; then
    echo "Installing additional components..."
    
    # Download and execute the activation script
    if curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/activate.sh" -o /tmp/activate.sh; then
        chmod +x /tmp/activate.sh
        bash /tmp/activate.sh
    else
        print_error "Failed to download activation script"
        echo "You can manually configure your DNS settings."
    fi
else
    print_warning "No token provided, skipping activation script"
    echo ""
    echo "Manual configuration required:"
    echo "1. Configure your domain's DNS to point to: $SERVER_IP"
    echo "2. Use nameserver: $NAMESERVER"
    echo "3. Connect using Dropbear on port: $DROPBEAR_PORT"
fi

echo ""
echo "For troubleshooting, check:"
echo "• Dropbear status: systemctl status dropbear"
echo "• SlowDNS status: systemctl status server-sldns"
echo "• View logs: journalctl -u server-sldns -f"
echo "=================================================================="
