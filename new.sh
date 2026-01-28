#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# SSH Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300
HTTP_PORT=8080  # Additional port for HTTP facade

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

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
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
echo " OpenSSH SlowDNS Installation with HTTP 101 Switching"
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
sed -i 's/#GatewayPorts no/GatewayPorts yes/g' /etc/ssh/sshd_config
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

# Download HTTP 101 wrapper
print_warning "Downloading HTTP 101 wrapper..."
wget -q -O /etc/slowdns/http101-wrapper "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/http101-wrapper"
if [ $? -eq 0 ]; then
    chmod +x /etc/slowdns/http101-wrapper
    print_success "HTTP 101 wrapper downloaded"
else
    print_warning "HTTP 101 wrapper not found, creating local version..."
    # Create simple HTTP 101 wrapper
    cat > /etc/slowdns/http101-wrapper << 'EOF'
#!/bin/bash
# HTTP 101 Switching Protocols Wrapper for SlowDNS
# Listens on TCP port and sends HTTP 101 response before proxying to SlowDNS

TCP_PORT=${1:-8080}
UPSTREAM_HOST=${2:-127.0.0.1}
UPSTREAM_PORT=${3:-5300}

HTTP_RESPONSE="HTTP/1.1 101 Switching Protocols\r\n"
HTTP_RESPONSE+="Upgrade: websocket\r\n"
HTTP_RESPONSE+="Connection: Upgrade\r\n"
HTTP_RESPONSE+="Sec-WebSocket-Accept: Cix7H0Mq9i5Ml3Z1Z8L9JzQ=\r\n"
HTTP_RESPONSE+="Server: nginx/1.18.0\r\n"
HTTP_RESPONSE+="Date: $(date -R)\r\n"
HTTP_RESPONSE+="\r\n"

# Create named pipes for communication
TEMP_DIR=$(mktemp -d)
CLIENT_PIPE="$TEMP_DIR/client"
SERVER_PIPE="$TEMP_DIR/server"
mkfifo "$CLIENT_PIPE"
mkfifo "$SERVER_PIPE"

cleanup() {
    rm -rf "$TEMP_DIR"
    kill $(jobs -p) 2>/dev/null
    exit 0
}

trap cleanup EXIT INT TERM

# Function to handle each connection
handle_connection() {
    local client_fd=$1
    # Send HTTP 101 response
    echo -en "$HTTP_RESPONSE" >&${client_fd}
    
    # Now connect to upstream SlowDNS and relay data
    exec 3<> "/dev/tcp/$UPSTREAM_HOST/$UPSTREAM_PORT"
    
    # Relay data between client and upstream
    (
        cat <&${client_fd} | tee "$CLIENT_PIPE" >&3
    ) &
    
    (
        cat <&3 | tee "$SERVER_PIPE" >&${client_fd}
    ) &
    
    wait
}

# Main listener
echo "Starting HTTP 101 wrapper on port $TCP_PORT..."
while true; do
    # Listen for incoming connections
    exec 4<> "/dev/tcp/0.0.0.0/$TCP_PORT"
    
    while true; do
        # Accept connection
        exec 5<&4
        # Fork to handle connection
        ( handle_connection 5 ) &
        exec 5>&-
    done 2>/dev/null
    
    sleep 1
done
EOF
    chmod +x /etc/slowdns/http101-wrapper
    print_success "Local HTTP 101 wrapper created"
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Get HTTP port (optional)
read -p "Enter HTTP facade port (default 8080): " HTTP_PORT_INPUT
if [ ! -z "$HTTP_PORT_INPUT" ]; then
    HTTP_PORT=$HTTP_PORT_INPUT
fi

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

# Create HTTP 101 wrapper service
print_warning "Creating HTTP 101 wrapper service..."
cat > /etc/systemd/system/http101-wrapper.service << EOF
[Unit]
Description=HTTP 101 Switching Protocols Wrapper for SlowDNS
After=network.target server-sldns.service
Requires=server-sldns.service

[Service]
Type=simple
User=root
ExecStart=/etc/slowdns/http101-wrapper $HTTP_PORT 127.0.0.1 $SLOWDNS_PORT
Restart=always
RestartSec=3
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
print_success "HTTP 101 wrapper service created"

# Startup config with iptables
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
iptables -A INPUT -p tcp --dport $HTTP_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A OUTPUT -j ACCEPT
iptables -A INPUT -m state --state INVALID -j DROP
iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $HTTP_PORT
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port $HTTP_PORT
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

# Start services
print_warning "Starting services..."
pkill sldns-server 2>/dev/null
pkill http101-wrapper 2>/dev/null

systemctl daemon-reload

# Start SlowDNS service
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns
sleep 3

# Start HTTP 101 wrapper
systemctl enable http101-wrapper > /dev/null 2>&1
systemctl start http101-wrapper
sleep 2

# Check services
print_warning "Checking service status..."

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service is running"
else
    print_error "SlowDNS service failed to start"
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

if systemctl is-active --quiet http101-wrapper; then
    print_success "HTTP 101 wrapper service is running"
else
    print_error "HTTP 101 wrapper service failed to start"
    # Try direct start
    pkill http101-wrapper 2>/dev/null
    /etc/slowdns/http101-wrapper $HTTP_PORT 127.0.0.1 $SLOWDNS_PORT &
    sleep 2
    if pgrep -f "http101-wrapper" > /dev/null; then
        print_success "HTTP 101 wrapper started directly"
    else
        print_error "Failed to start HTTP 101 wrapper"
    fi
fi

# Test connections
print_warning "Testing connections..."

# Test SSH
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
else
    print_error "SSH port 69 is not accessible"
fi

# Test SlowDNS UDP
if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
    print_success "SlowDNS UDP port $SLOWDNS_PORT is listening"
else
    print_error "SlowDNS UDP port $SLOWDNS_PORT is not responding"
fi

# Test HTTP wrapper TCP
if timeout 5 bash -c "echo -e 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n' | nc 127.0.0.1 $HTTP_PORT | head -5 | grep -q '101'" 2>/dev/null; then
    print_success "HTTP 101 wrapper on port $HTTP_PORT is responding with Switching Protocols"
else
    print_warning "Testing HTTP wrapper with curl..."
    if timeout 5 curl -s -i http://127.0.0.1:$HTTP_PORT | grep -q "101"; then
        print_success "HTTP 101 wrapper is working correctly"
    else
        print_error "HTTP 101 wrapper is not responding correctly"
    fi
fi

echo ""
echo "=================================================================="
print_success " OpenSSH SlowDNS with HTTP 101 Switching Installation Completed!"
echo "=================================================================="
echo ""
echo "📊 Summary:"
echo "  • SSH Port: 69 (for direct tunneling)"
echo "  • SlowDNS UDP Port: $SLOWDNS_PORT"
echo "  • HTTP 101 Facade Port: $HTTP_PORT"
echo "  • Nameserver: $NAMESERVER"
echo ""
echo "🔗 Clients can connect in two ways:"
echo "  1. Direct SlowDNS: Connect to UDP port $SLOWDNS_PORT"
echo "  2. HTTP 101 Mode: Connect to TCP port $HTTP_PORT (shows HTTP 101 switching)"
echo ""
echo "📱 For Android/Desktop clients using HTTP 101 mode, they should:"
echo "  - Connect to: $SERVER_IP:$HTTP_PORT"
echo "  - Expect HTTP 101 Switching Protocols response"
echo "  - Then tunnel SSH/SlowDNS through that connection"
echo ""

# Display config for clients
cat > /tmp/slowdns-client-config.txt << EOF
# SlowDNS Client Configuration
# ============================
# Method 1: Direct SlowDNS
# -------------------------
# Connect to UDP port $SLOWDNS_PORT
# Server: $SERVER_IP
# Port: $SLOWDNS_PORT
# Nameserver: $NAMESERVER

# Method 2: HTTP 101 Switching Protocols
# ---------------------------------------
# Connect to TCP port $HTTP_PORT
# Server: $SERVER_IP
# Port: $HTTP_PORT
# Protocol: HTTP/1.1 with WebSocket upgrade
# Expected response: HTTP/1.1 101 Switching Protocols

# SSH Tunneling Port
# ------------------
# SSH Port: 69 (after HTTP 101 handshake)

# Keys
# ----
# Public Key: $(cat /etc/slowdns/server.pub 2>/dev/null || echo "Not available")
EOF

print_info "Client configuration saved to /tmp/slowdns-client-config.txt"
echo ""

# Continue with the token installation
echo "🔐 DNS Installer - Token Required"
echo ""
read -p "Enter GitHub token: " token
echo "Installing..."
bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
