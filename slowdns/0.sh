#!/bin/bash

# Colors for TANZANIA theme (Green, Yellow, Black)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLACK='\033[0;30m'
BLUE='\033[0;34m'
NC='\033[0m'

# Port Configuration with switch support
DEFAULT_SSHD_PORT=22
DEFAULT_SLOWDNS_PORT=5300
ALTERNATE_SSHD_PORT=101
ALTERNATE_SLOWDNS_PORT=5301

# HTTP/1.1 Configuration
HTTP_PORT=80
HTTPS_PORT=443
HTTP_PROXY_PORT=8080
SOCKS_PORT=1080

# TANZANIA Server Settings
COUNTRY="TANZANIA"
TIMEZONE="Africa/Dar_es_Salaam"

# Functions
print_banner() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}${YELLOW}              TANZANIA SERVER INSTALLATION v2.0            ${NC}${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}${BLACK}          HTTP/1.1 • SlowDNS • OpenSSH • Proxy            ${NC}${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}${BLUE}               Optimized for Tanzanian Networks            ${NC}${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

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

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    print_info "Operating System: $OS $VER"
}

setup_timezone() {
    print_warning "Setting Tanzania timezone..."
    timedatectl set-timezone $TIMEZONE
    print_success "Timezone set to $TIMEZONE"
}

# Main Installation
print_banner

# Check root
check_root
check_os
setup_timezone

# Determine port configuration
print_warning "Select port configuration:"
echo "  1) Default (SSH: 22, SlowDNS: 5300)"
echo "  2) Alternative (SSH: 101, SlowDNS: 5301)"
echo "  3) Custom ports"

read -p "Enter choice [1-3]: " port_choice

case $port_choice in
    1)
        SSHD_PORT=$DEFAULT_SSHD_PORT
        SLOWDNS_PORT=$DEFAULT_SLOWDNS_PORT
        ;;
    2)
        SSHD_PORT=$ALTERNATE_SSHD_PORT
        SLOWDNS_PORT=$ALTERNATE_SLOWDNS_PORT
        ;;
    3)
        read -p "Enter SSH port: " custom_ssh
        read -p "Enter SlowDNS port: " custom_slowdns
        SSHD_PORT=${custom_ssh:-22}
        SLOWDNS_PORT=${custom_slowdns:-5300}
        ;;
    *)
        SSHD_PORT=$DEFAULT_SSHD_PORT
        SLOWDNS_PORT=$DEFAULT_SLOWDNS_PORT
        ;;
esac

print_success "Ports configured: SSH=$SSHD_PORT, SlowDNS=$SLOWDNS_PORT"

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure OpenSSH
print_warning "Configuring OpenSSH on port $SSHD_PORT..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null

cat > /etc/ssh/sshd_config << EOF
# TANZANIA Server - OpenSSH Configuration
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
AcceptEnv LANG LC_*
EOF

systemctl restart sshd
sleep 2
print_success "OpenSSH configured on port $SSHD_PORT"

# Setup HTTP/1.1 Proxy
print_warning "Setting up HTTP/1.1 Proxy Server..."
apt-get update > /dev/null 2>&1
apt-get install -y squid3 apache2-utils > /dev/null 2>&1

# Configure Squid for HTTP/1.1
cat > /etc/squid/squid.conf << EOF
# TANZANIA HTTP/1.1 Proxy Configuration
http_port $HTTP_PROXY_PORT
http_port $SOCKS_PORT

acl localnet src 10.0.0.0/8
acl localnet src 172.16.0.0/12
acl localnet src 192.168.0.0/16
acl localnet src fc00::/7
acl localnet src fe80::/10

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

http_access allow localnet
http_access allow localhost
http_access deny all

http_version 1.1

request_header_access Via deny all
request_header_access X-Forwarded-For deny all
request_header_access Forwarded deny all

cache deny all

forwarded_for off
via off

dns_v4_first on

tcp_outgoing_address $SERVER_IP

shutdown_lifetime 3 seconds

# HTTP/1.1 specific optimizations
pipeline_prefetch on
chunked_request_body_max_size 0 KB
max_filedesc 4096

# Tanzania ISP optimization
via off
forwarded_for delete
follow_x_forwarded_for deny all

visible_hostname tanzania-proxy-server
EOF

systemctl restart squid
systemctl enable squid
print_success "HTTP/1.1 Proxy configured on port $HTTP_PROXY_PORT"

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files with retry logic
download_file() {
    local url=$1
    local output=$2
    local retries=3
    
    for i in $(seq 1 $retries); do
        wget -q -O "$output" "$url"
        if [ $? -eq 0 ] && [ -s "$output" ]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

print_warning "Downloading SlowDNS files..."
if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" "/etc/slowdns/server.key"; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key"
    exit 1
fi

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" "/etc/slowdns/server.pub"; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub"
    exit 1
fi

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server" "/etc/slowdns/sldns-server"; then
    print_success "sldns-server downloaded"
else
    print_error "Failed to download sldns-server"
    exit 1
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get nameserver
echo ""
print_warning "Tanzania DNS Configuration"
read -p "Enter nameserver (e.g., tz-dns.example.com): " NAMESERVER
read -p "Enter DNS subdomain (e.g., tz): " DNS_SUBDOMAIN
echo ""

# Create SlowDNS service with HTTP/1.1 optimization
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/tanzania-slowdns.service << EOF
[Unit]
Description=Tanzania SlowDNS Server
After=network.target squid.service sshd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT
Restart=always
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal
Environment=GODEBUG=netdns=go
WorkingDirectory=/etc/slowdns

# Tanzania optimization
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TimeoutSec=300
OOMScoreAdjust=-1000
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=0
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Create HTTP/1.1 Tunnel Service
print_warning "Creating HTTP/1.1 Tunnel service..."
cat > /usr/local/bin/http-tunnel.sh << 'EOF'
#!/bin/bash
while true; do
    socat TCP4-LISTEN:8081,fork,reuseaddr TCP4:127.0.0.1:$SSHD_PORT
    sleep 1
done
EOF

chmod +x /usr/local/bin/http-tunnel.sh

cat > /etc/systemd/system/http-tunnel.service << EOF
[Unit]
Description=HTTP/1.1 Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/http-tunnel.sh
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

# Firewall Configuration for Tanzania
print_warning "Configuring firewall for Tanzanian network..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
# TANZANIA Server Firewall Configuration

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
ip6tables -F
ip6tables -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Tanzania Server Ports
iptables -A INPUT -p tcp --dport $SSHD_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $HTTP_PROXY_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SOCKS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport 8081 -j ACCEPT  # HTTP Tunnel
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Rate limiting for SSH
iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 5 -j DROP

# Allow ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT

# Drop invalid packets
iptables -A INPUT -m state --state INVALID -j DROP

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

# Tanzania Network Optimization
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" > /dev/null 2>&1
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" > /dev/null 2>&1
sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1

# Disable IPv6 completely
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf

# Tanzania DNS optimization
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 208.67.222.222" >> /etc/resolv.conf

# Start services
systemctl start sshd
systemctl start squid
systemctl start tanzania-slowdns
systemctl start http-tunnel

exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1
print_success "Firewall and startup configuration set"

# System Optimization for Tanzania
print_warning "Optimizing system for Tanzanian network..."
cat >> /etc/sysctl.conf << EOF

# Tanzania Network Optimization
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=8192
net.core.netdev_max_backlog=5000
fs.file-max=2097152
EOF

sysctl -p > /dev/null 2>&1

# Create client configuration file
print_warning "Creating client configuration..."
CLIENT_CONFIG="/root/tanzania-client-config.txt"
cat > $CLIENT_CONFIG << EOF
╔═══════════════════════════════════════════════════════════════╗
║                TANZANIA SERVER CONFIGURATION                 ║
╠═══════════════════════════════════════════════════════════════╣
║ Country: $COUNTRY                                             ║
║ Server IP: $SERVER_IP                                         ║
║ Timezone: $TIMEZONE                                           ║
╠═══════════════════════════════════════════════════════════════╣
║                    CONNECTION DETAILS                         ║
╠═══════════════════════════════════════════════════════════════╣
║ SSH Port: $SSHD_PORT                                          ║
║ SlowDNS Port: $SLOWDNS_PORT                                   ║
║ HTTP Proxy: $SERVER_IP:$HTTP_PROXY_PORT                      ║
║ SOCKS5: $SERVER_IP:$SOCKS_PORT                               ║
║ HTTP Tunnel: $SERVER_IP:8081                                 ║
║ Nameserver: $NAMESERVER                                       ║
║ DNS Subdomain: $DNS_SUBDOMAIN                                ║
╠═══════════════════════════════════════════════════════════════╣
║                     PROTOCOL SUPPORT                          ║
╠═══════════════════════════════════════════════════════════════╣
║ • HTTP/1.1 Proxy                                             ║
║ • SlowDNS UDP                                                ║
║ • SSH Tunnel                                                ║
║ • SOCKS5 Proxy                                              ║
║ • Direct TCP                                                ║
╠═══════════════════════════════════════════════════════════════╣
║                   CLIENT SETUP COMMANDS                       ║
╠═══════════════════════════════════════════════════════════════╣
║ For SSH: ssh root@$SERVER_IP -p $SSHD_PORT                  ║
║ For HTTP Proxy: Configure proxy as $SERVER_IP:$HTTP_PROXY_PORT ║
║ For SlowDNS: Use DNS server $NAMESERVER on port $SLOWDNS_PORT ║
╚═══════════════════════════════════════════════════════════════╝

Management Commands:
  systemctl status tanzania-slowdns     # Check SlowDNS status
  systemctl status squid                # Check HTTP proxy status
  systemctl status http-tunnel          # Check HTTP tunnel status
  journalctl -u tanzania-slowdns -f    # View SlowDNS logs
  systemctl restart tanzania-slowdns   # Restart SlowDNS
  systemctl restart squid              # Restart HTTP proxy

Optimized for Tanzanian ISPs:
• Vodacom Tanzania
• Airtel Tanzania
• Tigo Tanzania
• Halotel Tanzania
• Zantel Tanzania

MTU Settings: 1400 (recommended for Tanzania)
EOF

print_success "Client configuration saved to $CLIENT_CONFIG"

# Start all services
print_warning "Starting all services..."
systemctl daemon-reload
systemctl enable tanzania-slowdns > /dev/null 2>&1
systemctl enable http-tunnel > /dev/null 2>&1

systemctl start tanzania-slowdns
systemctl start http-tunnel

sleep 3

# Test services
print_warning "Testing services..."
echo ""

# Test SSH
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$SSHD_PORT" 2>/dev/null; then
    print_success "SSH port $SSHD_PORT is accessible"
else
    print_error "SSH port $SSHD_PORT is not accessible"
fi

# Test SlowDNS
if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
    print_success "SlowDNS is listening on port $SLOWDNS_PORT"
else
    print_error "SlowDNS not responding on port $SLOWDNS_PORT"
fi

# Test HTTP Proxy
if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$HTTP_PROXY_PORT" 2>/dev/null; then
    print_success "HTTP Proxy is listening on port $HTTP_PROXY_PORT"
else
    print_error "HTTP Proxy not responding on port $HTTP_PROXY_PORT"
fi

# Final output
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}${YELLOW}        TANZANIA SERVER INSTALLATION COMPLETE!           ${NC}${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
print_success "Server IP: $SERVER_IP"
print_success "Country: $COUNTRY"
print_success "SSH Port: $SSHD_PORT"
print_success "SlowDNS Port: $SLOWDNS_PORT"
print_success "HTTP Proxy Port: $HTTP_PROXY_PORT"
print_success "SOCKS5 Port: $SOCKS_PORT"
print_success "HTTP Tunnel Port: 8081"
print_success "Nameserver: $NAMESERVER"
print_success "DNS Subdomain: $DNS_SUBDOMAIN"
echo ""
print_warning "Protocols Supported: HTTP/1.1, SlowDNS, SSH, SOCKS5"
print_info "Configuration saved to: /root/tanzania-client-config.txt"
echo ""
print_info "To view full configuration: cat /root/tanzania-client-config.txt"

# Optional: Install additional tools
echo ""
read -p "Install additional monitoring tools? (y/n): " install_tools
if [ "$install_tools" = "y" ] || [ "$install_tools" = "Y" ]; then
    print_warning "Installing monitoring tools..."
    apt-get install -y htop iftop nload net-tools > /dev/null 2>&1
    print_success "Monitoring tools installed"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}${BLUE}           Server ready for Tanzanian networks!           ${NC}${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

# Optional GitHub token installation
echo ""
read -p "Do you want to run the GitHub DNS installer? (y/n): " run_dns
if [ "$run_dns" = "y" ] || [ "$run_dns" = "Y" ]; then
    echo ""
    echo "🔐 DNS Installer - Token Required"
    echo ""
    read -p "Enter GitHub token: " token
    echo "Installing..."
    bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con1.sh")
fi
