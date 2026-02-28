#!/bin/bash

# HTTP 101 Switching Protocols - SlowDNS Server
# This script implements a real HTTP 101 response for SlowDNS tunneling

# Configuration
HTTP_PORT=8080
SLOWDNS_PORT=5300
SSH_PORT=69
NAMESERVER="tunnel.local"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}[HTTP 101]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Install dependencies
apt-get update
apt-get install -y netcat-openbsd socat openssh-server

# Create HTTP 101 responder
cat > /usr/local/bin/http101-switch <<'EOF'
#!/bin/bash

echo "HTTP/1.1 101 Switching Protocols"
echo "Upgrade: slowdns/1.0, ssh/2.0"
echo "Connection: Upgrade"
echo "X-SlowDNS-Port: 5300"
echo "X-SSH-Port: 69"
echo "X-Nameserver: tunnel.local"
echo "X-Server-Key: $(cat /etc/slowdns/server.pub 2>/dev/null || echo 'pending')"
echo ""
echo "Switching to SlowDNS protocol..."
echo "Use: ssh -p 69 -o ProxyCommand='nc -u %h 5300' root@$SERVER_IP"
EOF

chmod +x /usr/local/bin/http101-switch

# Create HTTP server that responds with 101
cat > /etc/systemd/system/http101.service <<EOF
[Unit]
Description=HTTP 101 Switching Protocols Server
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/bin/bash -c 'while true; do echo -e "HTTP/1.1 101 Switching Protocols\nUpgrade: slowdns/1.0\nConnection: Upgrade\n\nSwitching to SlowDNS" | nc -l -p $HTTP_PORT -q 1; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Setup SlowDNS
mkdir -p /etc/slowdns

# Generate keys if not exist
if [ ! -f /etc/slowdns/server.key ]; then
    openssl genrsa -out /etc/slowdns/server.key 2048
    openssl rsa -in /etc/slowdns/server.key -pubout -out /etc/slowdns/server.pub
    print_success "Generated SlowDNS keys"
fi

# Configure SSH
echo "Port 22" >> /etc/ssh/sshd_config
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
echo "PermitTunnel yes" >> /etc/ssh/sshd_config

systemctl restart sshd

# Create SlowDNS wrapper that handles HTTP 101
cat > /usr/local/bin/slowdns-http101 <<'EOF'
#!/bin/bash

handle_connection() {
    # Read HTTP request
    read -r request
    
    if [[ $request == *"Upgrade: slowdns"* ]]; then
        # Send 101 Switching Protocols
        echo "HTTP/1.1 101 Switching Protocols"
        echo "Upgrade: slowdns/1.0"
        echo "Connection: Upgrade"
        echo "X-SlowDNS-Port: 5300"
        echo "X-SSH-Port: 69"
        echo ""
        echo "=== SlowDNS Tunnel Established ==="
        
        # Switch to SlowDNS mode
        exec /etc/slowdns/sldns-server -udp :5300 -privkey-file /etc/slowdns/server.key tunnel.local 127.0.0.1:69
    else
        echo "HTTP/1.1 400 Bad Request"
        echo "Connection: close"
        echo ""
        echo "This server requires Upgrade: slowdns header"
    fi
}

export -f handle_connection

# Listen for HTTP connections and handle protocol switch
while true; do
    nc -l -p 8080 -c 'handle_connection' 2>/dev/null
done
EOF

chmod +x /usr/local/bin/slowdns-http101

# Create systemd service for SlowDNS HTTP 101 handler
cat > /etc/systemd/system/slowdns-http101.service <<EOF
[Unit]
Description=SlowDNS HTTP 101 Switching Protocols Handler
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/slowdns-http101
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Setup iptables
iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
iptables -I INPUT -p udp --dport 5300 -j ACCEPT
iptables -I INPUT -p tcp --dport 69 -j ACCEPT
iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300

# Save iptables
iptables-save > /etc/iptables.rules

# Start services
systemctl daemon-reload
systemctl enable ssh
systemctl enable http101
systemctl enable slowdns-http101
systemctl start http101
systemctl start slowdns-http101

# Get server IP
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

# Clear screen
clear

# Display HTTP 101 response
echo "=================================================================="
echo "            HTTP/1.1 101 Switching Protocols"
echo "=================================================================="
echo ""
echo "HTTP/1.1 101 Switching Protocols"
echo "Upgrade: slowdns/1.0, ssh/2.0"
echo "Connection: Upgrade"
echo "X-Server-IP: $SERVER_IP"
echo "X-SlowDNS-Port: $SLOWDNS_PORT"
echo "X-SSH-Port: $SSH_PORT"
echo "X-Nameserver: $NAMESERVER"
echo "X-Public-Key: $(cat /etc/slowdns/server.pub | tr -d '\n')"
echo ""
echo "=================================================================="
print_success "Protocol switch ready!"
echo "=================================================================="
echo ""
echo "CLIENT CONNECTION EXAMPLES:"
echo "---------------------------"
echo ""
echo "1. HTTP Request with Upgrade:"
echo "   curl -H \"Connection: Upgrade\" -H \"Upgrade: slowdns/1.0\" http://$SERVER_IP:8080"
echo ""
echo "2. SSH via SlowDNS:"
echo "   ssh -p $SSH_PORT -o \"ProxyCommand nc -u $SERVER_IP $SLOWDNS_PORT\" root@$SERVER_IP"
echo ""
echo "3. Using socat for HTTP 101:"
echo "   echo -e \"GET / HTTP/1.1\\nHost: $SERVER_IP\\nUpgrade: slowdns/1.0\\nConnection: Upgrade\\n\\n\" | socat - TCP:$SERVER_IP:8080"
echo ""
echo "4. Netcat manual upgrade:"
echo "   printf \"GET / HTTP/1.1\\r\\nHost: $SERVER_IP\\r\\nUpgrade: slowdns/1.0\\r\\nConnection: Upgrade\\r\\n\\r\\n\" | nc $SERVER_IP 8080"
echo ""
echo "=================================================================="
print_success "Server is now responding with HTTP 101 Switching Protocols"
echo "=================================================================="

# Test the HTTP 101 response
echo ""
print_header "Testing HTTP 101 response..."
sleep 2

# Send test request
RESPONSE=$(echo -e "GET / HTTP/1.1\nHost: localhost\nUpgrade: slowdns/1.0\nConnection: Upgrade\n\n" | nc localhost 8080 2>/dev/null | head -n 1)

if [[ "$RESPONSE" == *"101 Switching"* ]]; then
    print_success "HTTP 101 response verified!"
else
    print_error "HTTP 101 test failed"
fi

echo ""
echo "Server is running! Press Ctrl+C to stop"
echo ""

# Keep script running
tail -f /dev/null
