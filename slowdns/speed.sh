#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SSHD_PORT=22
SLOWDNS_PORT=5300
OPTIMIZED_MTU=1400
DNS1="1.1.1.1"
DNS2="1.0.0.1"

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
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

check_internet() {
    print_info "Checking internet connection..."
    if ! timeout 3 curl -s https://raw.githubusercontent.com > /dev/null; then
        print_warning "Internet connection may be slow, continuing anyway..."
    else
        print_success "Internet connection OK"
    fi
}

optimize_system() {
    print_info "Applying system optimizations..."
    
    cat > /etc/sysctl.d/99-optimized-dns.conf << EOF
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_mem = 4096 87380 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    sysctl -p /etc/sysctl.d/99-optimized-dns.conf > /dev/null 2>&1
    
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
    sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
    sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
    
    print_success "System optimizations applied"
}

setup_dns() {
    print_info "Configuring DNS with Cloudflare..."
    
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    pkill -9 systemd-resolved 2>/dev/null
    
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << EOF
nameserver $DNS1
nameserver $DNS2
options timeout:1 attempts:2 rotate single-request-reopen
EOF
    
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    print_success "DNS configured with Cloudflare ($DNS1, $DNS2)"
}

configure_openssh_optimized() {
    print_info "Configuring optimized OpenSSH..."
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    cat > /etc/ssh/sshd_config << EOF
Port $SSHD_PORT
Protocol 2
AddressFamily inet
ListenAddress $SERVER_IP
ListenAddress 127.0.0.1

PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

LoginGraceTime 30
MaxAuthTries 3
MaxSessions 100
MaxStartups 10:30:100
AllowTcpForwarding yes
GatewayPorts yes
AllowAgentForwarding yes
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
UseDNS no

Compression delayed
Banner none
DebianBanner no

Subsystem sftp /usr/lib/openssh/sftp-server

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com

SyslogFacility AUTH
LogLevel INFO
EOF
    
    systemctl restart sshd
    sleep 2
    
    if systemctl is-active --quiet sshd; then
        print_success "OpenSSH optimized and running on port $SSHD_PORT"
    else
        print_error "Failed to restart SSH"
        systemctl status sshd --no-pager -l
    fi
}

setup_slowdns() {
    print_info "Setting up SlowDNS with MTU $OPTIMIZED_MTU..."
    
    rm -rf /etc/slowdns
    mkdir -p /etc/slowdns
    cd /etc/slowdns
    
    print_info "Downloading SlowDNS components..."
    
    files_downloaded=0
    for i in {1..3}; do
        if wget -q -O server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" &&
           wget -q -O server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" &&
           wget -q -O sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"; then
            files_downloaded=1
            break
        else
            print_warning "Download attempt $i failed, retrying in 2 seconds..."
            sleep 2
        fi
    done
    
    if [ $files_downloaded -eq 1 ]; then
        chmod +x sldns-server
        print_success "SlowDNS files downloaded and permissions set"
    else
        print_error "Failed to download SlowDNS files"
        print_warning "Please check internet connection and try again"
        exit 1
    fi
    
    echo ""
    print_info "For best results, use a subdomain like: dns.yourdomain.com"
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    
    if [ -z "$NAMESERVER" ]; then
        print_error "Nameserver is required"
        exit 1
    fi
    
    cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Optimized SlowDNS Server (MTU $OPTIMIZED_MTU)
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu $OPTIMIZED_MTU -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT
Restart=always
RestartSec=3
StartLimitInterval=0
StartLimitBurst=0
LimitNOFILE=65536
Nice=-10
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "SlowDNS service created with MTU $OPTIMIZED_MTU"
}

configure_firewall() {
    print_info "Configuring firewall..."
    
    cat > /etc/rc.local << EOF
#!/bin/sh -e

systemctl start sshd

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -j ACCEPT

iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT

iptables -A INPUT -p icmp -j ACCEPT

iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 5 -j DROP

echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

sleep 2
systemctl start server-sldns

exit 0
EOF
    
    chmod +x /etc/rc.local
    systemctl enable rc-local > /dev/null 2>&1
    systemctl start rc-local.service > /dev/null 2>&1
    
    print_success "Firewall configured"
}

start_slowdns_service() {
    print_info "Starting SlowDNS service..."
    
    pkill sldns-server 2>/dev/null
    systemctl daemon-reload
    systemctl enable server-sldns > /dev/null 2>&1
    
    for i in {1..3}; do
        systemctl restart server-sldns
        sleep 2
        
        if systemctl is-active --quiet server-sldns; then
            print_success "SlowDNS service started successfully"
            
            print_info "Testing SlowDNS on port $SLOWDNS_PORT..."
            if timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
                print_success "SlowDNS is responsive"
            else
                print_warning "SlowDNS port test failed, but service is running"
            fi
            return 0
        else
            print_warning "Attempt $i to start SlowDNS failed"
            sleep 1
        fi
    done
    
    print_warning "Trying manual start..."
    pkill sldns-server 2>/dev/null
    cd /etc/slowdns
    nohup ./sldns-server -udp :$SLOWDNS_PORT -mtu $OPTIMIZED_MTU -privkey-file server.key $NAMESERVER 127.0.0.1:$SSHD_PORT > /var/log/slowdns.log 2>&1 &
    sleep 2
    
    if pgrep -x "sldns-server" > /dev/null; then
        print_success "SlowDNS started manually"
        return 0
    else
        print_error "Failed to start SlowDNS"
        return 1
    fi
}

run_tests() {
    print_info "Running installation tests..."
    
    echo ""
    
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$SSHD_PORT" 2>/dev/null; then
        print_success "SSH port $SSHD_PORT is accessible"
    else
        print_error "SSH port $SSHD_PORT is not accessible"
    fi
    
    if pgrep -x "sldns-server" > /dev/null; then
        print_success "SlowDNS process is running"
    else
        print_error "SlowDNS process not found"
    fi
    
    if timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS listening on port $SLOWDNS_PORT"
    else
        print_warning "SlowDNS port test inconclusive"
    fi
    
    if timeout 3 ping -c 1 $DNS1 > /dev/null 2>&1; then
        print_success "Internet connectivity OK"
    else
        print_warning "Internet connectivity test failed"
    fi
}

show_summary() {
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo ""
    echo "Server IP:      $SERVER_IP"
    echo "SSH Port:       $SSHD_PORT"
    echo "SlowDNS Port:   $SLOWDNS_PORT"
    echo "Nameserver:     $NAMESERVER"
    echo "Optimized MTU:  $OPTIMIZED_MTU"
    echo "DNS Servers:    $DNS1, $DNS2"
    echo ""
    echo "OpenSSH Config:    /etc/ssh/sshd_config"
    echo "SSH Backup:        /etc/ssh/sshd_config.backup.*"
    echo "SlowDNS Directory: /etc/slowdns/"
    echo "SlowDNS Service:   /etc/systemd/system/server-sldns.service"
    echo "DNS Config:        /etc/resolv.conf"
    echo "Startup Script:    /etc/rc.local"
    echo ""
    echo "Check SSH:        systemctl status sshd"
    echo "Check SlowDNS:    systemctl status server-sldns"
    echo "Restart SlowDNS:  systemctl restart server-sldns"
    echo "View Logs:        journalctl -u server-sldns -f"
    echo "Test Connection:  timeout 2 bash -c \"echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT\""
    echo ""
}

install_customer_optional() {
    echo ""
    print_warning "Optional: Install Customer proxy for DNS?"
    read -p "Install Customer? (y/N): " install_customer
    
    if [[ "$install_customer" =~ ^[Yy]$ ]]; then
        echo ""
        print_info "Installing Customer proxy..."
        
        CUSTOMER_SCRIPT="/tmp/install_customer.sh"
        
        if wget -q -O $CUSTOMER_SCRIPT "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/full.sh"; then
            chmod +x $CUSTOMER_SCRIPT
            
            if grep -q "token" $CUSTOMER_SCRIPT; then
                echo ""
                print_warning "Customer script requires GitHub token"
                read -p "Enter GitHub token (or press Enter to skip): " token
                
                if [ -n "$token" ]; then
                    bash $CUSTOMER_SCRIPT <<< "$token"
                else
                    print_warning "Skipping Customer installation (no token provided)"
                fi
            else
                bash $CUSTOMER_SCRIPT
            fi
            
            rm -f $CUSTOMER_SCRIPT
        else
            print_error "Failed to download Customer installer"
        fi
    else
        print_info "Skipping Customer installation"
    fi
}

main() {
    check_root
    check_internet
    
    optimize_system
    setup_dns
    configure_openssh_optimized
    setup_slowdns
    configure_firewall
    
    start_slowdns_service
    
    run_tests
    
    show_summary
    
    install_customer_optional
    
    echo ""
    print_success "Installation completed successfully!"
    echo ""
}

main "$@"
