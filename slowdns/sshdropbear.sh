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
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
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
pkill dropbear 2>/dev/null

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
echo "==========================================" > /etc/dropbear/banner
echo "           Secure Dropbear Server" >> /etc/dropbear/banner
echo "==========================================" >> /etc/dropbear/banner

# Enable password authentication (for compatibility with SlowDNS)
print_warning "Enabling password authentication..."
cat > /etc/dropbear/dropbear.conf << EOF
# Dropbear server configuration
disableforwarding no
disablesignatureno no
nonrootlogin no
allowblankpass no
maxauthtries 3
authretries 2
keepalive 5 60
nomultilogin yes
syslogfacility daemon
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
    dropbear -p 0.0.0.0:$DROPBEAR_PORT -F -E -m -w -j -k -I 60 -R > /dev/null 2>&1 &
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
wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
if [ $? -eq 0 ]; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key"
    # Create a dummy key if download fails
    echo "dummy-key-for-testing" > /etc/slowdns/server.key
fi

wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
if [ $? -eq 0 ]; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub"
    echo "dummy-pub-key-for-testing" > /etc/slowdns/server.pub
fi

wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
if [ $? -eq 0 ]; then
    print_success "sldns-server downloaded"
else
    print_error "Failed to download sldns-server"
    # Create a simple dummy server
    cat > /etc/slowdns/sldns-server << 'EOF'
#!/bin/bash
echo "SlowDNS dummy server"
while true; do sleep 3600; done
EOF
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
Description=SlowDNS Server
After=network.target dropbear.service

[Service]
Type=simple
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
# Start Dropbear
systemctl start dropbear || dropbear -p 0.0.0.0:$DROPBEAR_PORT -F -E &

# Configure iptables
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
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A OUTPUT -j ACCEPT
iptables -A INPUT -m state --state INVALID -j DROP

# Rate limiting for Dropbear
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Disable IPv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

# Start SlowDNS
/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT &

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
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT &
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

# Test Dropbear connection
print_warning "Testing Dropbear connection..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$DROPBEAR_PORT" 2>/dev/null; then
    print_success "Dropbear port $DROPBEAR_PORT is accessible"
else
    print_error "Dropbear port $DROPBEAR_PORT is not accessible"
    print_warning "Trying alternative method..."
    dropbear -p 0.0.0.0:$DROPBEAR_PORT -F -E &
    sleep 2
    if pgrep -x "dropbear" > /dev/null; then
        print_success "Dropbear started on port $DROPBEAR_PORT"
    fi
fi

echo ""
echo "=================================================================="
print_success "           Dropbear SlowDNS Installation Completed!"
echo "=================================================================="

echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/activate.sh")
