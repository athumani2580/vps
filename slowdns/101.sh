#!/bin/bash

# Domain and Nameserver Setup for SlowDNS
# HTTP/1.1 101 Switching Protocols

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
SLOWDNS_PORT=5300
SSH_PORT=69
HTTP_PORT=8080

print_banner() {
    clear
    echo "=================================================================="
    echo "     HTTP/1.1 101 Switching Protocols - Domain & NS Setup"
    echo "=================================================================="
    echo ""
}

print_header() {
    echo -e "${BLUE}[HTTP 101]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[i]${NC} $1"
}

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

print_banner

# Install required packages
print_header "Installing required packages..."
apt-get update -qq
apt-get install -y bind9 dnsutils netcat-openbsd socat openssh-server apache2 certbot python3-certbot-apache -qq
print_success "Packages installed"

# Get domain information
echo ""
print_info "Enter your domain name (e.g., tunnel.example.com):"
read -p "Domain: " DOMAIN

print_info "Enter your nameserver (e.g., ns1.example.com):"
read -p "Nameserver: " NAMESERVER

print_info "Enter admin email (e.g., admin@example.com):"
read -p "Email: " EMAIL

echo ""
print_header "X-Domain: $DOMAIN"
print_header "X-Nameserver: $NAMESERVER"
print_header "X-Email: $EMAIL"
echo ""

# Create DNS zone file
print_header "Creating DNS zone for $DOMAIN..."
cat > /etc/bind/db.$DOMAIN << EOF
\$TTL    604800
@       IN      SOA     $NAMESERVER. $EMAIL. (
                  2026022801  ; Serial
                  604800      ; Refresh
                  86400       ; Retry
                  2419200     ; Expire
                  604800 )    ; Negative Cache TTL

; Nameservers
@       IN      NS      $NAMESERVER.
@       IN      NS      ns2.$DOMAIN.

; A Records
$NAMESERVER.    IN      A       $SERVER_IP
ns2.$DOMAIN.    IN      A       $SERVER_IP
@               IN      A       $SERVER_IP

; SlowDNS Records
slowdns.$DOMAIN.    IN      A       $SERVER_IP
dns.$DOMAIN.        IN      A       $SERVER_IP
tunnel.$DOMAIN.     IN      A       $SERVER_IP

; CNAME Records
www         IN      CNAME   @
ftp         IN      CNAME   @
mail        IN      CNAME   @

; TXT Records for verification
@           IN      TXT     "slowdns-server-v1"
_slowdns     IN      TXT     "udp-port=$SLOWDNS_PORT"
_ssh         IN      TXT     "tcp-port=$SSH_PORT"
_http101     IN      TXT     "upgrade-protocol=slowdns/1.0"

; SlowDNS Service Discovery
_slowdns._udp.$DOMAIN.    IN      SRV     10 10 $SLOWDNS_PORT slowdns.$DOMAIN.
_ssh._tcp.$DOMAIN.        IN      SRV     10 10 $SSH_PORT tunnel.$DOMAIN.
_http._tcp.$DOMAIN.       IN      SRV     10 10 $HTTP_PORT www.$DOMAIN.

; DNS Forwarding
slowdns.$DOMAIN.    IN      A       $SERVER_IP
EOF

print_success "DNS zone created"

# Configure named.conf
print_header "Configuring BIND nameserver..."
cat >> /etc/bind/named.conf.local << EOF

zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
    allow-query { any; };
    allow-transfer { none; };
};

EOF

# Update named.conf options
cat > /etc/bind/named.conf.options << EOF
options {
    directory "/var/cache/bind";
    
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    
    allow-query { any; };
    allow-query-cache { any; };
    allow-recursion { any; };
    
    forwarders {
        8.8.8.8;
        1.1.1.1;
    };
    
    recursion yes;
    dnssec-validation auto;
    
    // SlowDNS optimization
    max-cache-size 256M;
    max-ncache-ttl 3600;
    max-cache-ttl 3600;
};

// SlowDNS specific logging
logging {
    channel slowdns_log {
        file "/var/log/named/slowdns.log" versions 3 size 5m;
        print-time yes;
        print-category yes;
        print-severity yes;
        severity info;
    };
    
    category queries { slowdns_log; };
};
EOF

# Create log directory
mkdir -p /var/log/named
chown bind:bind /var/log/named

# Restart BIND
systemctl restart bind9
print_success "BIND nameserver configured and restarted"

# Create HTTP 101 response with domain info
print_header "Creating HTTP 101 response page..."
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>HTTP 101 Switching Protocols - SlowDNS</title>
    <style>
        body { font-family: Arial; padding: 40px; background: #1a1a1a; color: #fff; }
        .container { max-width: 800px; margin: 0 auto; }
        .header { background: #00ff00; color: #000; padding: 20px; border-radius: 10px; }
        .info { background: #333; padding: 20px; margin: 20px 0; border-radius: 10px; }
        .code { background: #000; padding: 15px; border-radius: 5px; font-family: monospace; }
        .green { color: #00ff00; }
        .blue { color: #00ffff; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>HTTP/1.1 101 Switching Protocols</h1>
            <p>Upgrade: slowdns/1.0, ssh/2.0</p>
            <p>Connection: Upgrade</p>
        </div>
        
        <div class="info">
            <h2 class="green">Server Information</h2>
            <p><strong>Domain:</strong> $DOMAIN</p>
            <p><strong>Nameserver:</strong> $NAMESERVER</p>
            <p><strong>Server IP:</strong> $SERVER_IP</p>
            <p><strong>SlowDNS Port:</strong> $SLOWDNS_PORT (UDP)</p>
            <p><strong>SSH Port:</strong> $SSH_PORT (TCP)</p>
            <p><strong>HTTP Port:</strong> $HTTP_PORT (TCP)</p>
        </div>
        
        <div class="info">
            <h2 class="blue">DNS Records</h2>
            <div class="code">
                $NAMESERVER.    IN  A   $SERVER_IP<br>
                slowdns.$DOMAIN.    IN  A   $SERVER_IP<br>
                _slowdns._udp.$DOMAIN.  IN  SRV 10 10 $SLOWDNS_PORT slowdns.$DOMAIN.<br>
                _slowdns    IN  TXT "udp-port=$SLOWDNS_PORT"
            </div>
        </div>
        
        <div class="info">
            <h2 class="green">Connection Methods</h2>
            <div class="code">
                # HTTP 101 Upgrade Request<br>
                curl -H "Connection: Upgrade" -H "Upgrade: slowdns/1.0" http://$DOMAIN:$HTTP_PORT<br><br>
                
                # SSH via SlowDNS<br>
                ssh -p $SSH_PORT -o "ProxyCommand nc -u slowdns.$DOMAIN $SLOWDNS_PORT" root@$DOMAIN<br><br>
                
                # DNS Query<br>
                dig @$NAMESERVER slowdns.$DOMAIN
            </div>
        </div>
        
        <div class="info">
            <h2 class="blue">Nameserver Setup for Domain Registrars</h2>
            <div class="code">
                Nameserver 1: $NAMESERVER → $SERVER_IP<br>
                Nameserver 2: ns2.$DOMAIN → $SERVER_IP
            </div>
        </div>
    </div>
</body>
</html>
EOF

print_success "HTTP 101 page created"

# Configure Apache for HTTP 101
cat > /etc/apache2/sites-available/000-default.conf << EOF
<VirtualHost *:$HTTP_PORT>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    
    DocumentRoot /var/www/html
    
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
    
    # HTTP 101 Upgrade header
    Header always set Upgrade "slowdns/1.0, ssh/2.0"
    Header always set Connection "Upgrade"
    Header always set X-SlowDNS-Port "$SLOWDNS_PORT"
    Header always set X-SSH-Port "$SSH_PORT"
    Header always set X-Nameserver "$NAMESERVER"
</VirtualHost>
EOF

a2enmod headers
systemctl restart apache2
print_success "Apache configured with HTTP 101 headers"

# Create NS record for domain
print_header "Setting up nameserver records..."
cat > /etc/bind/db.ns.$DOMAIN << EOF
\$TTL    3600
@       IN      SOA     $NAMESERVER. $EMAIL. (
                  2026022802
                  3600
                  900
                  1209600
                  3600 )
                  
@       IN      NS      $NAMESERVER.
@       IN      NS      ns2.$DOMAIN.

$NAMESERVER.    IN      A       $SERVER_IP
ns2.$DOMAIN.    IN      A       $SERVER_IP
EOF

print_success "Nameserver records created"

# Display SSL certificate option
print_info "Do you want to install SSL certificate? (y/n)"
read -p "SSL: " SSL_CHOICE

if [[ "$SSL_CHOICE" == "y" ]]; then
    print_header "Installing SSL certificate..."
    certbot --apache -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email $EMAIL
    print_success "SSL certificate installed"
    HTTP_PORT=443
fi

# Test DNS resolution
print_header "Testing DNS resolution..."
sleep 5

if dig @localhost $DOMAIN +short | grep -q "$SERVER_IP"; then
    print_success "DNS resolution working for $DOMAIN"
else
    print_error "DNS resolution failed"
fi

# Display final HTTP 101 response
clear
echo "=================================================================="
echo "            HTTP/1.1 101 Switching Protocols"
echo "=================================================================="
echo ""
echo "HTTP/1.1 101 Switching Protocols"
echo "Upgrade: slowdns/1.0, ssh/2.0"
echo "Connection: Upgrade"
echo "X-Domain: $DOMAIN"
echo "X-Nameserver: $NAMESERVER"
echo "X-Server-IP: $SERVER_IP"
echo "X-SlowDNS-Port: $SLOWDNS_PORT (UDP)"
echo "X-SSH-Port: $SSH_PORT (TCP)"
echo "X-HTTP-Port: $HTTP_PORT (TCP)"
echo "X-DNS-Servers: $NAMESERVER, ns2.$DOMAIN"
echo ""
echo "=================================================================="
print_success "Domain and Nameserver configured successfully!"
echo "=================================================================="
echo ""
echo "DNS ZONE INFORMATION:"
echo "---------------------"
echo "Domain: $DOMAIN"
echo "Nameserver 1: $NAMESERVER -> $SERVER_IP"
echo "Nameserver 2: ns2.$DOMAIN -> $SERVER_IP"
echo ""
echo "IMPORTANT: At your domain registrar, set:"
echo "----------------------------------------"
echo "Nameserver 1: $NAMESERVER"
echo "Nameserver 2: ns2.$DOMAIN"
echo "Glue Record 1: $NAMESERVER -> $SERVER_IP"
echo "Glue Record 2: ns2.$DOMAIN -> $SERVER_IP"
echo ""
echo "TEST COMMANDS:"
echo "-------------"
echo "dig @$NAMESERVER $DOMAIN"
echo "nslookup $DOMAIN $NAMESERVER"
echo "curl -H \"Connection: Upgrade\" -H \"Upgrade: slowdns/1.0\" http://$DOMAIN:$HTTP_PORT"
echo ""
echo "=================================================================="

# Save configuration
cat > /root/slowdns-domain.conf << EOF
# SlowDNS Domain Configuration
DOMAIN=$DOMAIN
NAMESERVER=$NAMESERVER
SERVER_IP=$SERVER_IP
SLOWDNS_PORT=$SLOWDNS_PORT
SSH_PORT=$SSH_PORT
HTTP_PORT=$HTTP_PORT
EMAIL=$EMAIL
EOF

chmod 600 /root/slowdns-domain.conf
print_success "Configuration saved to /root/slowdns-domain.conf"

# Keep script running
echo ""
print_info "Press Ctrl+C to exit (services will continue running)"
echo ""

tail -f /var/log/apache2/access.log
