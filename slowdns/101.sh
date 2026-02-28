#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300
WS_NON_TLS_PORT=80
WS_TLS_PORT=443

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
echo "      OpenSSH SlowDNS with WebSocket SSL/TLS Installation"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Get domain for SSL
echo ""
read -p "Enter your domain for SSL (e.g., ssh.yourdomain.com): " SSL_DOMAIN
read -p "Enter nameserver for SlowDNS (e.g., dns.yourdomain.com): " NAMESERVER
echo ""

# Install dependencies
print_warning "Installing dependencies..."
apt update
apt install -y nginx python3 python3-pip certbot python3-certbot-nginx stunnel4 dropbear
pip3 install websockify
print_success "Dependencies installed"

# Configure SSH ports
print_warning "Configuring SSH ports..."
echo "Port 22" >> /etc/ssh/sshd_config
echo "Port 69" >> /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/#GatewayPorts yes/GatewayPorts yes/g' /etc/ssh/sshd_config

systemctl restart sshd 2>/dev/null
sleep 2
print_success "SSH configured on ports 22 and 69 with TCP forwarding enabled"

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download SlowDNS files
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

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Create SlowDNS service
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS ALIEN
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Setup WebSocket SSH (Non-TLS on port 80)
print_warning "Setting up WebSocket SSH (Non-TLS) on port $WS_NON_TLS_PORT..."

# Create WebSocket service for port 80
cat > /etc/systemd/system/ws-non-tls.service << EOF
[Unit]
Description=WebSocket Non-TLS SSH
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/websockify --web /var/www/html $WS_NON_TLS_PORT 127.0.0.1:69
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Create web directory
mkdir -p /var/www/html
echo "<h1>SSH WebSocket Server</h1>" > /var/www/html/index.html

print_success "WebSocket Non-TLS service created"

# Setup SSL Certificate
print_warning "Setting up SSL certificate for $SSL_DOMAIN..."

# Install SSL certificate using certbot
certbot --nginx -d $SSL_DOMAIN --non-interactive --agree-tos --email admin@$SSL_DOMAIN --redirect

if [ $? -eq 0 ]; then
    print_success "SSL certificate installed successfully"
else
    print_warning "Certbot failed, trying alternative method..."
    
    # Alternative: Generate self-signed certificate
    mkdir -p /etc/ssl/$SSL_DOMAIN
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/$SSL_DOMAIN/privkey.pem \
        -out /etc/ssl/$SSL_DOMAIN/fullchain.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=$SSL_DOMAIN"
    
    print_success "Self-signed certificate created"
fi

# Setup WebSocket SSH with SSL (port 443)
print_warning "Setting up WebSocket SSH with SSL on port $WS_TLS_PORT..."

# Create Nginx configuration for WebSocket SSL
cat > /etc/nginx/sites-available/ws-ssh << EOF
server {
    listen $WS_TLS_PORT ssl http2;
    server_name $SSL_DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SSL_DOMAIN/privkey.pem;
    
    # If using self-signed certificate
    # ssl_certificate /etc/ssl/$SSL_DOMAIN/fullchain.pem;
    # ssl_certificate_key /etc/ssl/$SSL_DOMAIN/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    location / {
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/ws-ssh /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create WebSocket SSL backend service
cat > /etc/systemd/system/ws-tls.service << EOF
[Unit]
Description=WebSocket TLS Backend
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/websockify 2082 127.0.0.1:69
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Configure Dropbear for additional SSH access
print_warning "Configuring Dropbear..."
cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=550
DROPBEAR_EXTRA_ARGS="-p 69"
DROPBEAR_BANNER=""
EOF

systemctl restart dropbear 2>/dev/null
print_success "Dropbear configured on port 550"

# Create Python WebSocket server as alternative
print_warning "Creating Python WebSocket server as backup..."
cat > /etc/systemd/system/ws-python.service << EOF
[Unit]
Description=Python WebSocket SSH
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 -m websockify --web /var/www/html 2083 127.0.0.1:69
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
systemctl start sshd
systemctl start dropbear

# Open ports
iptables -I INPUT -p udp --dport 5300 -j ACCEPT
iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300

# TCP ports
for port in 22 69 80 443 550 2082 2083; do
    iptables -I INPUT -p tcp --dport \$port -j ACCEPT
done

echo 1 > /proc/sys/net/ipv4/ip_forward
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

# Configure DNS
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

# Start all services
print_warning "Starting all services..."

# Start SlowDNS
systemctl daemon-reload
systemctl enable server-sldns ws-non-tls ws-tls ws-python nginx > /dev/null 2>&1
systemctl start server-sldns ws-non-tls ws-tls ws-python nginx

sleep 3

# Test services
print_warning "Testing services..."

# Test SlowDNS
if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started on UDP $SLOWDNS_PORT"
else
    print_error "SlowDNS service failed"
fi

# Test WebSocket Non-TLS
if systemctl is-active --quiet ws-non-tls; then
    print_success "WebSocket Non-TLS service started on port $WS_NON_TLS_PORT"
else
    print_error "WebSocket Non-TLS service failed"
fi

# Test Nginx/SSL
if systemctl is-active --quiet nginx; then
    print_success "Nginx/SSL service started on port $WS_TLS_PORT"
else
    print_error "Nginx/SSL service failed"
fi

# Test WebSocket TLS backend
if systemctl is-active --quiet ws-tls; then
    print_success "WebSocket TLS backend started on port 2082"
else
    print_error "WebSocket TLS backend failed"
fi

# Test SSH ports
for port in 69 550; do
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        print_success "SSH port $port is accessible"
    else
        print_error "SSH port $port is not accessible"
    fi
done

# Create comprehensive info file
cat > /root/connection-info.txt << EOF
==================================================================
              CONNECTION INFORMATION
==================================================================

Server IP        : $SERVER_IP
SSL Domain       : $SSL_DOMAIN
Nameserver       : $NAMESERVER

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PROTOCOLS AND PORTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. SSH Direct:
   └─ Port 22, 69 (Standard SSH)

2. SlowDNS (UDP):
   └─ Port 5300 (SlowDNS)
   └─ Nameserver: $NAMESERVER

3. WebSocket SSH (Non-TLS):
   └─ Port 80 (HTTP WebSocket)
   └─ Payload: GET / HTTP/1.1[crlf]Host: $SSL_DOMAIN[crlf]Upgrade: websocket[crlf][crlf]

4. WebSocket SSH (SSL/TLS):
   └─ Port 443 (HTTPS WebSocket)
   └─ Domain: $SSL_DOMAIN
   └─ Payload: GET / HTTP/1.1[crlf]Host: $SSL_DOMAIN[crlf]Upgrade: websocket[crlf][crlf]

5. Dropbear SSH:
   └─ Port 550 (Alternative SSH)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CONNECTION EXAMPLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SSH WebSocket (Non-TLS):
━━━━━━━━━━━━━━━━━━━━━━━━
Host: $SERVER_IP
Port: 80
Payload: GET / HTTP/1.1[crlf]Host: $SSL_DOMAIN[crlf]Upgrade: websocket[crlf][crlf]

SSH WebSocket (SSL/TLS):
━━━━━━━━━━━━━━━━━━━━━━━━
Host: $SSL_DOMAIN
Port: 443
Payload: GET / HTTP/1.1[crlf]Host: $SSL_DOMAIN[crlf]Upgrade: websocket[crlf][crlf]

SlowDNS:
━━━━━━━━
Nameserver: $NAMESERVER
Port: 5300 (UDP)
SSH Port: 69

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SSL Certificate Information
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Domain: $SSL_DOMAIN
Type: Let's Encrypt/Self-signed
Expiry: 90 days (auto-renewable)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Service Management Commands
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Check Status:   systemctl status server-sldns ws-non-tls ws-tls nginx
Restart All:    systemctl restart server-sldns ws-non-tls ws-tls nginx
View Logs:      journalctl -fu server-sldns
                journalctl -fu ws-non-tls
                journalctl -fu ws-tls

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Installation completed on: $(date)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

echo ""
echo "=================================================================="
print_success " Installation Completed Successfully!"
echo "=================================================================="
echo ""
echo "Connection information saved to: /root/connection-info.txt"
echo ""
cat /root/connection-info.txt
