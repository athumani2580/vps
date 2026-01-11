#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300
DOMAIN="alienalien.top"
SUBDOMAIN="dns"
FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

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
    echo -e "${CYAN}[i]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

generate_dns_config() {
    print_warning "Generating DNS configuration for $FULL_DOMAIN..."
    
    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi
    
    # Try to extract public key from downloaded file
    PUBKEY_B64=""
    if [ -f "/etc/slowdns/server.pub" ]; then
        PUBKEY_B64=$(base64 -w 0 /etc/slowdns/server.pub 2>/dev/null | tr -d '=' | tr '+/' '-_')
    fi
    
    # If no public key, show generic configuration
    if [ -z "$PUBKEY_B64" ]; then
        cat > /root/dns_config_alienalien.txt << EOF
========================================================
🌐 DNS CONFIGURATION FOR alienalien.top
========================================================

📋 DNS RECORDS TO ADD IN YOUR DOMAIN PANEL:

1. Nameserver Record (NS):
   Type: NS
   Host/Name: $SUBDOMAIN
   Value/Target: ns1.$DOMAIN
   TTL: 3600

2. A Record for Nameserver:
   Type: A
   Host/Name: ns1
   Value: $SERVER_IP
   TTL: 3600

3. TXT Record for Public Key:
   Type: TXT
   Host/Name: $SUBDOMAIN
   Value: dnstt=[YOUR_PUBLIC_KEY_BASE64]
   TTL: 3600

   Note: Get public key from: /etc/slowdns/server.pub
   Convert to base64: base64 -w 0 server.pub | tr -d '=' | tr '+/' '-_'

4. SPF Record (optional):
   Type: TXT
   Host/Name: $SUBDOMAIN
   Value: v=spf1 -all
   TTL: 3600

========================================================
🔧 SERVER INFORMATION:
Server IP: $SERVER_IP
Domain: $FULL_DOMAIN
SlowDNS Port: $SLOWDNS_PORT
SSH Port: $SSHD_PORT
========================================================

⚠️ IMPORTANT:
1. Add these records to your domain provider (GoDaddy, Namecheap, etc.)
2. Wait 5-10 minutes for DNS propagation
3. Test with: nslookup $FULL_DOMAIN
========================================================
EOF
    else
        # With public key
        cat > /root/dns_config_alienalien.txt << EOF
========================================================
🌐 DNS CONFIGURATION FOR alienalien.top
========================================================

📋 DNS RECORDS TO ADD IN YOUR DOMAIN PANEL:

1. Nameserver Record (NS):
   Type: NS
   Host/Name: $SUBDOMAIN
   Value/Target: ns1.$DOMAIN
   TTL: 3600

2. A Record for Nameserver:
   Type: A
   Host/Name: ns1
   Value: $SERVER_IP
   TTL: 3600

3. TXT Record for Public Key:
   Type: TXT
   Host/Name: $SUBDOMAIN
   Value: dnstt=$PUBKEY_B64
   TTL: 3600

4. SPF Record (optional):
   Type: TXT
   Host/Name: $SUBDOMAIN
   Value: v=spf1 -all
   TTL: 3600

========================================================
🔧 SERVER INFORMATION:
Server IP: $SERVER_IP
Domain: $FULL_DOMAIN
SlowDNS Port: $SLOWDNS_PORT
SSH Port: $SSHD_PORT
Public Key (base64): $PUBKEY_B64
========================================================

⚠️ IMPORTANT:
1. Add these records to your domain provider (GoDaddy, Namecheap, etc.)
2. Wait 5-10 minutes for DNS propagation
3. Test with: nslookup $FULL_DOMAIN
4. Client command: ./sldns-client -udp :5353 -pubkey $PUBKEY_B64 $FULL_DOMAIN 127.0.0.1:22
========================================================
EOF
    fi
    
    print_success "DNS configuration generated!"
    print_success "Configuration saved to: /root/dns_config_alienalien.txt"
    
    # Display configuration
    echo ""
    cat /root/dns_config_alienalien.txt
    echo ""
}

# Check root
check_root

echo "=================================================================="
echo "                 OpenSSH SlowDNS Installation"
echo "=================================================================="

# Generate DNS configuration first
generate_dns_config

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure OpenSSH
print_warning "Configuring OpenSSH on port $SSHD_PORT..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null

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

systemctl restart sshd
sleep 2
print_success "OpenSSH configured on port $SSHD_PORT"

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

# Get nameserver with default suggestion
echo ""
echo "================================================================"
print_info "Using domain: $FULL_DOMAIN"
print_info "Server IP: $SERVER_IP"
echo "================================================================"
echo ""
read -p "Enter nameserver [default: $FULL_DOMAIN]: " NAMESERVER
if [ -z "$NAMESERVER" ]; then
    NAMESERVER="$FULL_DOMAIN"
fi
echo ""

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS for $NAMESERVER
Documentation=https://github.com/athumani2580/vps
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT
Restart=on-failure
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
iptables -A INPUT -p tcp --dport $SSHD_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A OUTPUT -j ACCEPT
iptables -A INPUT -m state --state INVALID -j DROP

iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

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
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT &
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
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$SSHD_PORT" 2>/dev/null; then
    print_success "SSH port $SSHD_PORT is accessible"
else
    print_error "SSH port $SSHD_PORT is not accessible"
fi

echo ""
echo "=================================================================="
print_success "           OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="

# Generate final client configuration
print_warning "Generating final client configuration..."
if [ -f "/etc/slowdns/server.pub" ]; then
    PUBKEY_B64=$(base64 -w 0 /etc/slowdns/server.pub 2>/dev/null | tr -d '=' | tr '+/' '-_')
    
    cat > /root/client_setup.txt << EOF
========================================================
🔧 CLIENT SETUP FOR SlowDNS SSH
========================================================

📋 CONNECTION DETAILS:
Domain: $NAMESERVER
Server IP: $SERVER_IP
SlowDNS Port: $SLOWDNS_PORT
SSH Port: $SSHD_PORT

🔑 PUBLIC KEY (for client):
$PUBKEY_B64

🚀 CLIENT COMMAND:
./sldns-client -udp :5353 -pubkey $PUBKEY_B64 $NAMESERVER 127.0.0.1:$SSHD_PORT

📁 DOWNLOAD CLIENT:
wget https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-client
chmod +x sldns-client

🔍 TEST CONNECTION:
1. Add DNS records from /root/dns_config_alienalien.txt
2. Wait 5-10 minutes for DNS propagation
3. Test: nslookup $NAMESERVER
4. Run client command above

========================================================
EOF
    
    print_success "Client setup saved to: /root/client_setup.txt"
fi

echo ""
echo "🎯 NEXT STEPS:"
echo "1. Add DNS records from: /root/dns_config_alienalien.txt"
echo "2. Wait 5-10 minutes for DNS propagation"
echo "3. Test DNS: nslookup $NAMESERVER"
echo "4. Use client config from: /root/client_setup.txt"
echo ""

# Optional: Ask if user wants to add DNS automatically
echo "🔐 DNS Installer - Optional GitHub Token"
echo ""
read -p "Do you want to use GitHub token for DNS setup? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter GitHub token: " token
    if [ ! -z "$token" ]; then
        echo "Installing additional DNS components..."
        bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/full.sh")
    fi
else
    echo ""
    echo "📝 Manual DNS setup required:"
    echo "   Please add the records from /root/dns_config_alienalien.txt"
    echo "   to your domain provider (alienalien.top)"
fi

echo ""
echo "=================================================================="
echo "📁 Configuration files saved:"
echo "   • DNS Records: /root/dns_config_alienalien.txt"
echo "   • Client Setup: /root/client_setup.txt"
echo "   • Server Keys: /etc/slowdns/server.key /etc/slowdns/server.pub"
echo "=================================================================="
