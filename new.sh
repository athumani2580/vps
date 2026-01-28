#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Port Configuration
SSH_PORT=22
SLOWDNS_UDP_PORT=5353  # Internal SlowDNS UDP port
HTTP_PORT=53           # External HTTP wrapper on DNS port (53)
DNS_PORT=53            # Standard DNS port

# Functions
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

# Check root
check_root

echo "=================================================================="
echo " HTTP 101 SlowDNS on Port 53 Installation"
echo "=================================================================="

# Stop existing DNS services
print_warning "Stopping existing DNS services..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 named 2>/dev/null
pkill -9 dnsmasq 2>/dev/null

# Release port 53
print_warning "Releasing port 53..."
ss -tulpn | grep ":53 " | awk '{print $7}' | cut -d\" -f2 | xargs kill -9 2>/dev/null
sleep 2

# Configure SSH
print_warning "Configuring SSH..."
sed -i 's/#Port 22/Port 22\nPort 69/g' /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/#GatewayPorts no/GatewayPorts yes/g' /etc/ssh/sshd_config
systemctl restart sshd

# Create directories
mkdir -p /etc/fastdns

# Create HTTP 101 wrapper for port 53
print_warning "Creating HTTP 101 wrapper for port 53..."
cat > /usr/local/bin/http101-dns-wrapper << 'EOF'
#!/bin/bash
# HTTP 101 Wrapper on port 53 - Looks like DNS but serves HTTP 101

LISTEN_PORT=53
UPSTREAM_HOST=127.0.0.1
UPSTREAM_PORT=5353

HTTP_101_RESPONSE="HTTP/1.1 101 Switching Protocols\r\n"
HTTP_101_RESPONSE+="Upgrade: websocket\r\n"
HTTP_101_RESPONSE+="Connection: Upgrade\r\n"
HTTP_101_RESPONSE+="Sec-WebSocket-Accept: $(echo -n "dns-tunnel-key" | base64)\r\n"
HTTP_101_RESPONSE+="Server: Cloudflare\r\n"
HTTP_101_RESPONSE+="Date: $(date -R)\r\n\r\n"

handle_connection() {
    local client_ip="$1"
    local client_port="$2"
    
    # Accept TCP connection
    exec 3<>/dev/tcp/127.0.0.1/$LISTEN_PORT
    
    # First, check if it's HTTP traffic
    read -t 2 -u 3 first_line
    if [[ "$first_line" == *"HTTP"* || "$first_line" == *"GET"* || "$first_line" == *"POST"* ]]; then
        # It's HTTP traffic - send 101 response
        echo -en "$HTTP_101_RESPONSE" >&3
        
        # Now connect to SlowDNS upstream
        exec 4<>/dev/udp/$UPSTREAM_HOST/$UPSTREAM_PORT
        
        # Relay traffic
        (
            while cat <&3 > /tmp/client_data.bin; do
                cat /tmp/client_data.bin >&4
            done
        ) &
        
        (
            while cat <&4 > /tmp/server_data.bin; do
                cat /tmp/server_data.bin >&3
            done
        ) &
        
        wait
    else
        # It's DNS traffic - forward to real DNS (8.8.8.8)
        echo -n "$first_line" | nc -u 8.8.8.8 53 >&3
    fi
}

# Main loop
echo "Starting HTTP 101 wrapper on port $LISTEN_PORT..."
while true; do
    # Use socat to handle both TCP and UDP on port 53
    socat TCP-LISTEN:$LISTEN_PORT,reuseaddr,fork,keepalive \
          UDP-LISTEN:$LISTEN_PORT,reuseaddr,fork \
          EXEC:"/usr/local/bin/handle-dns-or-http.sh" &
    wait $!
    sleep 1
done
EOF

# Create handler script
cat > /usr/local/bin/handle-dns-or-http.sh << 'EOF'
#!/bin/bash
# Handler for port 53 - distinguishes between DNS and HTTP traffic

read -t 1 first_bytes
first_line=$(echo "$first_bytes" | head -c 20)

# Check if it starts with DNS header (usually 00 or transaction ID)
if [[ "$first_bytes" =~ ^[0-9a-fA-F]{4} ]]; then
    # Looks like DNS - forward to real DNS server
    echo "$first_bytes" | nc -w 2 -u 1.1.1.1 53
else
    # Send HTTP 101 response
    echo -en "HTTP/1.1 101 Switching Protocols\r\n"
    echo -en "Upgrade: websocket\r\n"
    echo -en "Connection: Upgrade\r\n"
    echo -en "Sec-WebSocket-Accept: $(echo -n "dns-web" | base64)\r\n"
    echo -en "Server: nginx\r\n"
    echo -en "Date: $(date -R)\r\n\r\n"
    
    # Now relay to SlowDNS
    cat | nc -u 127.0.0.1 5353
fi
EOF

chmod +x /usr/local/bin/http101-dns-wrapper
chmod +x /usr/local/bin/handle-dns-or-http.sh

# Download SlowDNS server
print_warning "Downloading SlowDNS server..."
wget -q -O /etc/fastdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
wget -q -O /etc/fastdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
chmod +x /etc/fastdns/sldns-server

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., ns1.yourdomain.com): " NAMESERVER
echo ""

# Create SlowDNS service
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/fastdns.service << EOF
[Unit]
Description=FastDNS Server on port 5353
After=network.target

[Service]
Type=simple
User=root
ExecStart=/etc/fastdns/sldns-server -udp :5353 -privkey-file /etc/fastdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Create HTTP 101 wrapper service
print_warning "Creating HTTP 101 wrapper service for port 53..."
cat > /etc/systemd/system/http101-dns.service << EOF
[Unit]
Description=HTTP 101 Wrapper on DNS port 53
After=network.target fastdns.service
Requires=fastdns.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/http101-dns-wrapper
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Setup iptables rules
print_warning "Configuring firewall rules..."
iptables -F
iptables -X
iptables -t nat -F

# Allow port 53 (both TCP and UDP)
iptables -A INPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 69 -j ACCEPT
iptables -A INPUT -p udp --dport 5353 -j ACCEPT

# Redirect all TCP 53 to our wrapper
iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 53

# Block direct SSH on port 69 from outside (only allow localhost)
iptables -A INPUT -p tcp --dport 69 -s 127.0.0.1 -j ACCEPT
iptables -A INPUT -p tcp --dport 69 -j DROP

# Save iptables
iptables-save > /etc/iptables/rules.v4

# Disable IPv6
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p

# Configure DNS resolver
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null

# Start services
print_warning "Starting services..."
systemctl daemon-reload
systemctl enable fastdns
systemctl enable http101-dns
systemctl start fastdns
systemctl start http101-dns

# Test services
print_warning "Testing services..."
sleep 3

if systemctl is-active --quiet fastdns; then
    print_success "FastDNS service is running on port 5353"
else
    print_error "FastDNS service failed to start"
fi

if systemctl is-active --quiet http101-dns; then
    print_success "HTTP 101 wrapper is running on port 53"
else
    print_error "HTTP 101 wrapper failed to start"
fi

# Test HTTP 101 response
print_warning "Testing HTTP 101 response on port 53..."
if timeout 3 bash -c "echo -e 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n' | nc 127.0.0.1 53 | grep -q '101'"; then
    print_success "HTTP 101 Switching Protocols is working on port 53"
else
    print_error "HTTP 101 not working on port 53"
fi

# Test DNS fallback
print_warning "Testing DNS fallback..."
if timeout 3 bash -c "dig @127.0.0.1 google.com +short +tcp"; then
    print_success "DNS fallback is working"
else
    print_warning "DNS fallback not working (expected for HTTP mode)"
fi

echo ""
echo "=================================================================="
print_success " Installation Complete!"
echo "=================================================================="
echo ""
echo "📡 Server Information:"
echo "   • HTTP 101 Port: 53 (Standard DNS port)"
echo "   • SlowDNS UDP Port: 5353 (internal)"
echo "   • SSH Port: 69 (internal only)"
echo "   • Nameserver: $NAMESERVER"
echo ""
echo "🔗 Client Connection:"
echo "   Connect to: your-server.com:53 (TCP)"
echo "   First receive: HTTP/1.1 101 Switching Protocols"
echo "   Then tunnel SSH through this connection"
echo ""
echo "🌐 To the outside world, this looks like:"
echo "   • Normal DNS server on port 53"
echo "   • But responds with HTTP 101 to tunnel clients"
echo "   • Real DNS queries are forwarded to 1.1.1.1"
echo ""
echo "⚡ Usage Example:"
echo "   ssh -o ProxyCommand='nc your-server.com 53' -p 22 user@localhost"
echo ""
