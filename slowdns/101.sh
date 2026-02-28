#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300
SSL_PORT=443
NON_TLS_PORTS="80,8080"

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
echo "          OpenSSH SlowDNS with SSL/TLS Installation"
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

systemctl restart sshd 2>/dev/null
sleep 2
print_success "SSH configured on ports 22 and 69 with TCP forwarding enabled"

# Install dependencies
print_warning "Installing dependencies..."
apt update
apt install -y stunnel4 dropbear openssl haproxy nginx
print_success "Dependencies installed"

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

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get domain information
echo ""
read -p "Enter nameserver domain (e.g., dns.example.com): " NAMESERVER
read -p "Enter SSL/TLS domain (e.g., cloudflare.example.com): " SSL_DOMAIN
echo ""

# Create SSL certificate with Cloudflare
print_warning "Creating SSL certificate for $SSL_DOMAIN..."

# Install acme.sh for SSL certificate
curl https://get.acme.sh | sh -s email=admin@$SSL_DOMAIN
source ~/.bashrc

# Issue SSL certificate
~/.acme.sh/acme.sh --issue --standalone -d $SSL_DOMAIN --force
~/.acme.sh/acme.sh --installcert -d $SSL_DOMAIN --key-file /etc/ssl/$SSL_DOMAIN.key --fullchain-file /etc/ssl/$SSL_DOMAIN.crt

print_success "SSL certificate created"

# Configure Stunnel (for SSL/TLS)
print_warning "Configuring Stunnel for SSL/TLS..."
cat > /etc/stunnel/stunnel.conf << EOF
pid = /var/run/stunnel.pid
cert = /etc/ssl/$SSL_DOMAIN.crt
key = /etc/ssl/$SSL_DOMAIN.key
sslVersion = all
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
client = no
foreground = no

[openssh]
accept = $SSL_PORT
connect = 127.0.0.1:69
TIMEOUTclose = 0

[dropbear]
accept = 444
connect = 127.0.0.1:69

[slowdns]
accept = 2083
connect = 127.0.0.1:69
EOF

sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
systemctl restart stunnel4
print_success "Stunnel configured on port $SSL_PORT (SSL/TLS)"

# Configure Dropbear (for additional SSH)
print_warning "Configuring Dropbear..."
cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=550
DROPBEAR_EXTRA_ARGS="-p 69"
DROPBEAR_BANNER="/etc/banner.net"
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"
DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"
DROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"
EOF

systemctl restart dropbear
print_success "Dropbear configured on port 550"

# Configure Nginx for port 80 and 8080 (non-TLS)
print_warning "Configuring Nginx for non-TLS ports ($NON_TLS_PORTS)..."
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 8080 default_server;
    listen [::]:8080 default_server;
    
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
    
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:69;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location /ssh {
        proxy_pass http://127.0.0.1:69;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

systemctl restart nginx
print_success "Nginx configured on ports $NON_TLS_PORTS"

# Configure HAProxy (load balancing)
print_warning "Configuring HAProxy..."
cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000

frontend ssh_non_tls
    bind *:80
    bind *:8080
    mode tcp
    default_backend ssh_servers

frontend ssh_tls
    bind *:443 ssl crt /etc/ssl/$SSL_DOMAIN.crt
    mode tcp
    default_backend ssh_servers

backend ssh_servers
    mode tcp
    server ssh1 127.0.0.1:69
    server ssh2 127.0.0.1:550
EOF

systemctl restart haproxy
print_success "HAProxy configured"

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
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
systemctl start sshd
systemctl start stunnel4
systemctl start dropbear
systemctl start nginx
systemctl start haproxy

# Open ports
iptables -I INPUT -p udp --dport 5300 -j ACCEPT
iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300

# Open TCP ports
for port in 22 69 80 443 550 8080 2083 444; do
    iptables -I INPUT -p tcp --dport \$port -j ACCEPT
done

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
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69 &
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

# Test SSH connection
print_warning "Testing SSH connection..."
for port in 69 550 443 80 8080; do
    if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        print_success "Port $port is accessible"
    else
        print_error "Port $port is not accessible"
    fi
done

# Create info file
cat > /root/connection-info.txt << EOF
==================================================================
                    CONNECTION INFORMATION
==================================================================

Server IP: $SERVER_IP
Domain SSL: $SSL_DOMAIN
Nameserver: $NAMESERVER

PROTOCOLS AND PORTS:
-------------------
1. SSH Direct:
   - Port 22 (standard SSH)
   - Port 69 (alternative SSH)

2. SSL/TLS (with Cloudflare certificate):
   - Port 443 (SSL/TLS via Stunnel)
   - Domain: $SSL_DOMAIN

3. Non-TLS (HTTP ports):
   - Port 80 (HTTP)
   - Port 8080 (HTTP alternate)

4. SlowDNS:
   - UDP Port 5300 (SlowDNS service)
   - Nameserver: $NAMESERVER

5. Additional Ports:
   - Port 550 (Dropbear SSH)
   - Port 444 (Stunnel alternative)
   - Port 2083 (Stunnel SlowDNS)

PAYLOAD CONFIGURATION:
--------------------
For SSL/TLS (Port 443):
GET / SSH HTTP/1.1[crlf]Host: $SSL_DOMAIN[crlf]Upgrade: websocket[crlf][crlf]

For Non-TLS (Port 80/8080):
GET wss://$SSL_DOMAIN/ HTTP/1.1[crlf]Host: $SSL_DOMAIN[crlf]Upgrade: websocket[crlf][crlf]

SSL/TLS Certificate Information:
------------------------------
Certificate Path: /etc/ssl/$SSL_DOMAIN.crt
Key Path: /etc/ssl/$SSL_DOMAIN.key
Issuer: Cloudflare

==================================================================
EOF

echo ""
echo "=================================================================="
print_success "     OpenSSH SlowDNS with SSL/TLS Installation Completed!"
echo "=================================================================="
echo ""
echo "Connection information saved to: /root/connection-info.txt"
echo ""
cat /root/connection-info.txt
