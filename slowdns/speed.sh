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
OPTIMIZED_MTU=1400
DNS1="1.1.1.1"
DNS2="1.0.0.1"

# Functions
print_status() {
    echo -e "${CYAN}[*]${NC} $1"
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

check_internet() {
    print_status "Checking internet connection..."
    if ! curl -s --connect-timeout 5 https://raw.githubusercontent.com > /dev/null; then
        print_error "No internet connection. Please check your network."
        exit 1
    fi
    print_success "Internet connection OK"
}

install_dependencies() {
    print_status "Installing dependencies..."
    
    apt-get update > /dev/null 2>&1
    
    # Essential tools
    for pkg in curl wget net-tools iptables-persistent; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            apt-get install -y $pkg > /dev/null 2>&1
            print_success "Installed: $pkg"
        fi
    done
    
    # Performance monitoring tools
    for pkg in htop iftop sysstat dnsutils; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            apt-get install -y $pkg > /dev/null 2>&1
        fi
    done
    
    print_success "Dependencies installed"
}

optimize_kernel() {
    print_status "Applying kernel optimizations for low latency..."
    
    cat >> /etc/sysctl.conf << EOF

# ============================================
# SlowDNS Performance Optimizations
# ============================================

# TCP Optimizations
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1

# Socket Buffer Sizes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 65536

# TCP Window Scaling
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mem = 65536 131072 262144

# TCP Keepalive
net.ipv4.tcp_keepalive_time = 180
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Network Queue
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Time-Wait Handling
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000

# Connection Tracking
net.netfilter.nf_conntrack_max = 524288
net.nf_conntrack_max = 524288

# ARP Cache
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096

# IPv6 Disabled (for better performance)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    # Apply immediately
    sysctl -p > /dev/null 2>&1
    
    # Enable BBR
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    
    print_success "Kernel optimizations applied"
}

setup_dns() {
    print_status "Configuring DNS for fast resolution..."
    
    # Stop systemd-resolved
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    
    # Kill any remaining processes
    pkill -9 systemd-resolved 2>/dev/null
    
    # Create resolv.conf with fast DNS servers
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << EOF
# Optimized DNS Configuration
nameserver $DNS1
nameserver $DNS2
options timeout:1 attempts:2 rotate single-request-reopen
EOF
    
    # Make it immutable
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Flush DNS cache
    systemctl restart systemd-resolved 2>/dev/null || true
    
    # Test DNS speed
    print_status "Testing DNS response time..."
    timeout 2 dig @$DNS1 google.com | grep "Query time" | head -1
    
    print_success "DNS configured for low latency"
}

configure_openssh() {
    print_status "Configuring OpenSSH for performance..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Optimized SSH configuration
    cat > /etc/ssh/sshd_config << EOF
# ============================================
# Optimized OpenSSH Configuration
# ============================================
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
ClientAliveInterval 30
ClientAliveCountMax 3
AllowTcpForwarding yes
GatewayPorts yes
Compression delayed
Subsystem sftp /usr/lib/openssh/sftp-server

# Performance Tuning
MaxSessions 100
MaxStartups 100:30:200
LoginGraceTime 20
MaxAuthTries 3
MaxStartups 10:30:100

# Connection Optimization
UseDNS no
GSSAPIAuthentication no
AllowAgentForwarding yes
StreamLocalBindUnlink yes

# Ciphers and Algorithms (Optimized for speed)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com
EOF
    
    systemctl restart sshd
    sleep 2
    
    # Verify SSH is running
    if systemctl is-active --quiet sshd; then
        print_success "OpenSSH optimized and running on port $SSHD_PORT"
    else
        print_error "Failed to restart SSH"
        systemctl status sshd --no-pager -l
    fi
}

setup_slowdns() {
    print_status "Setting up SlowDNS with performance optimizations..."
    
    # Create directory
    rm -rf /etc/slowdns
    mkdir -p /etc/slowdns
    cd /etc/slowdns
    
    print_status "Downloading SlowDNS components..."
    
    # Download files with retry logic
    for i in {1..3}; do
        if wget -q -O server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" &&
           wget -q -O server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" &&
           wget -q -O sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"; then
            print_success "All files downloaded successfully"
            break
        else
            print_warning "Attempt $i failed, retrying..."
            sleep 2
        fi
    done
    
    # Verify downloads
    if [ ! -f "sldns-server" ]; then
        print_error "Failed to download SlowDNS files. Trying alternative source..."
        # Try alternative source
        wget -q -O sldns-server "https://github.com/athumani2580/vps/raw/main/slowdns/sldns-server" || {
            print_error "Cannot download SlowDNS binary. Please check internet connection."
            exit 1
        }
    fi
    
    chmod +x sldns-server
    
    # Get nameserver
    echo ""
    print_info "For best performance, use a subdomain like: dns.yourdomain.com"
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    
    if [ -z "$NAMESERVER" ]; then
        print_error "Nameserver is required"
        exit 1
    fi
    
    # Create optimized SlowDNS service
    print_status "Creating optimized SlowDNS service..."
    
    cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=High Performance SlowDNS Server
Documentation=https://github.com/athumani2580/vps
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
RuntimeDirectory=slowdns
RuntimeDirectoryMode=0750

# Security and Performance
NoNewPrivileges=true
RestrictRealtime=true
RestrictSUIDSGID=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
PrivateDevices=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

# Performance Tuning
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=0
CPUSchedulingPolicy=rr
CPUSchedulingPriority=10
LimitNOFILE=655360
LimitNPROC=655360
LimitCORE=infinity
OOMScoreAdjust=-1000

# Startup command with all optimizations
ExecStart=/etc/slowdns/sldns-server \\
  -udp :${SLOWDNS_PORT} \\
  -mtu ${OPTIMIZED_MTU} \\
  -rcvbuf 65536 \\
  -sndbuf 65536 \\
  -readbuf 65536 \\
  -writebuf 65536 \\
  -privkey-file /etc/slowdns/server.key \\
  ${NAMESERVER} 127.0.0.1:${SSHD_PORT}

# Restart policy
Restart=always
RestartSec=3
StartLimitInterval=0
StartLimitBurst=0

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=slowdns

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "SlowDNS service configuration created"
}

configure_firewall() {
    print_status "Configuring firewall for optimal performance..."
    
    # Flush existing rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    
    # Set default policies
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    # Basic protection
    iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow localhost
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow SSH and SlowDNS
    iptables -A INPUT -p tcp --dport ${SSHD_PORT} -j ACCEPT
    iptables -A INPUT -p udp --dport ${SLOWDNS_PORT} -j ACCEPT
    iptables -A INPUT -p tcp --dport ${SLOWDNS_PORT} -j ACCEPT
    
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
    
    # Connection rate limiting for SSH (prevents brute force)
    iptables -A INPUT -p tcp --dport ${SSHD_PORT} -m state --state NEW -m recent --set
    iptables -A INPUT -p tcp --dport ${SSHD_PORT} -m state --state NEW -m recent --update --seconds 60 --hitcount 5 -j DROP
    
    # Save rules
    if command -v iptables-save > /dev/null; then
        iptables-save > /etc/iptables/rules.v4
        print_success "Firewall rules saved"
    fi
    
    print_success "Firewall configured"
}

create_startup_script() {
    print_status "Creating optimized startup script..."
    
    cat > /etc/rc.local << EOF
#!/bin/bash
# Optimized Startup Script for SlowDNS

# Wait for network
sleep 2

# Start SSH
systemctl start sshd

# Apply performance optimizations on boot
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_sack=1 > /dev/null 2>&1

# Flush conntrack table (optional, helps on high load)
# echo 1 > /proc/sys/net/ipv4/netfilter/ip_conntrack_tcp_timeout_established

# Clear DNS cache
systemctl restart systemd-resolved 2>/dev/null || true

# Start SlowDNS with delay to ensure network is ready
sleep 3
systemctl start server-sldns

exit 0
EOF
    
    chmod +x /etc/rc.local
    systemctl enable rc-local > /dev/null 2>&1
    
    print_success "Startup script created"
}

create_monitoring_tools() {
    print_status "Creating monitoring and diagnostic tools..."
    
    # Performance monitor
    cat > /usr/local/bin/monitor-slowdns.sh << 'EOF'
#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    SlowDNS Performance Monitor${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. Service Status
echo -e "${YELLOW}1. SERVICE STATUS:${NC}"
systemctl status server-sldns --no-pager -l | head -20

# 2. Port Listening
echo -e "\n${YELLOW}2. PORT LISTENING:${NC}"
ss -tulpn | grep -E "(${SLOWDNS_PORT:-5300}|${SSHD_PORT:-22})"

# 3. Connection Count
echo -e "\n${YELLOW}3. ACTIVE CONNECTIONS:${NC}"
ss -tun | grep -c ":${SLOWDNS_PORT:-5300}" | awk '{print "SlowDNS UDP Connections: "$1}'
ss -tun | grep -c ":${SSHD_PORT:-22}" | awk '{print "SSH TCP Connections: "$1}'

# 4. Resource Usage
echo -e "\n${YELLOW}4. RESOURCE USAGE:${NC}"
ps aux --sort=-%mem | grep sldns-server | head -5

# 5. Network Statistics
echo -e "\n${YELLOW}5. NETWORK STATS:${NC}"
cat /proc/net/sockstat | head -5

# 6. Latency Test
echo -e "\n${YELLOW}6. LATENCY TEST:${NC}"
echo -n "Local UDP Test: "
timeout 2 bash -c "time (echo > /dev/udp/127.0.0.1/${SLOWDNS_PORT:-5300}) 2>&1" | grep real || echo "Failed"

# 7. DNS Resolution Time
echo -e "\n${YELLOW}7. DNS RESOLUTION:${NC}"
timeout 2 dig @1.1.1.1 google.com | grep "Query time" | head -1

# 8. System Load
echo -e "\n${YELLOW}8. SYSTEM LOAD:${NC}"
uptime | awk -F'load average:' '{print $2}'

# 9. Memory Usage
echo -e "\n${YELLOW}9. MEMORY USAGE:${NC}"
free -h | awk '/^Mem:/ {print "Used: "$3"/"$2" ("$3/$2*100"%)"}'

# 10. Recommendations
echo -e "\n${YELLOW}10. RECOMMENDATIONS:${NC}"
LOAD=$(uptime | awk -F'load average:' '{print $2}' | tr -d ',')
if [ $(echo "$LOAD > 2.0" | bc) -eq 1 ]; then
    echo "- System load is high ($LOAD)"
fi

CONNS=$(ss -tun | grep -c ":${SLOWDNS_PORT:-5300}")
if [ $CONNS -gt 1000 ]; then
    echo "- Many active connections ($CONNS)"
fi

echo ""
echo -e "${GREEN}Run 'slowdns-optimize' for performance tuning${NC}"
EOF
    
    chmod +x /usr/local/bin/monitor-slowdns.sh
    
    # Optimization script
    cat > /usr/local/bin/slowdns-optimize << 'EOF'
#!/bin/bash

echo "Applying performance optimizations..."

# Restart services with fresh config
systemctl daemon-reload
systemctl restart server-sldns
systemctl restart sshd

# Apply TCP optimizations
sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 > /dev/null 2>&1
sysctl -w net.core.netdev_max_backlog=100000 > /dev/null 2>&1

# Clear connection tracking
conntrack -F 2>/dev/null || true

# Restart DNS
systemctl restart systemd-resolved 2>/dev/null || true

echo "Optimizations applied. Restarting SlowDNS..."
sleep 2
systemctl restart server-sldns

echo "Done! Check performance with: monitor-slowdns.sh"
EOF
    
    chmod +x /usr/local/bin/slowdns-optimize
    
    # Create log viewer
    cat > /usr/local/bin/slowdns-logs << 'EOF'
#!/bin/bash
journalctl -u server-sldns -f --no-pager -n 50
EOF
    
    chmod +x /usr/local/bin/slowdns-logs
    
    print_success "Monitoring tools created"
}

start_services() {
    print_status "Starting all services..."
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start services
    for service in sshd server-sldns; do
        systemctl enable $service > /dev/null 2>&1
        systemctl restart $service
        sleep 2
        
        if systemctl is-active --quiet $service; then
            print_success "$service started successfully"
        else
            print_error "Failed to start $service"
            systemctl status $service --no-pager -l
        fi
    done
    
    # Test services
    print_status "Testing services..."
    
    # Test SSH
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$SSHD_PORT" 2>/dev/null; then
        print_success "SSH is accessible on port $SSHD_PORT"
    else
        print_error "SSH port $SSHD_PORT is not responding"
    fi
    
    # Test SlowDNS
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on UDP port $SLOWDNS_PORT"
    else
        print_warning "SlowDNS UDP test failed, checking process..."
        if pgrep -x "sldns-server" > /dev/null; then
            print_success "SlowDNS process is running"
        else
            print_error "SlowDNS process not found"
            # Try direct start
            cd /etc/slowdns
            nohup ./sldns-server -udp :$SLOWDNS_PORT -mtu $OPTIMIZED_MTU -privkey-file server.key $NAMESERVER 127.0.0.1:$SSHD_PORT > /var/log/slowdns.log 2>&1 &
            sleep 2
            if pgrep -x "sldns-server" > /dev/null; then
                print_success "SlowDNS started manually"
            fi
        fi
    fi
}

show_summary() {
    clear
    echo ""
    echo "================================================================"
    echo -e "${GREEN}          SLOWDNS INSTALLATION COMPLETED!${NC}"
    echo "================================================================"
    echo ""
    
    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
    
    echo -e "${YELLOW}SERVER INFORMATION:${NC}"
    echo "IP Address: $SERVER_IP"
    echo "SSH Port: $SSHD_PORT"
    echo "SlowDNS Port: $SLOWDNS_PORT"
    echo "Nameserver: $NAMESERVER"
    echo "Optimized MTU: $OPTIMIZED_MTU"
    echo ""
    
    echo -e "${YELLOW}AVAILABLE COMMANDS:${NC}"
    echo "  monitor-slowdns.sh  - Check performance and status"
    echo "  slowdns-optimize    - Apply performance optimizations"
    echo "  slowdns-logs        - View real-time logs"
    echo "  systemctl status server-sldns - Check service status"
    echo ""
    
    echo -e "${YELLOW}CLIENT CONFIGURATION:${NC}"
    echo "For client setup, use these parameters:"
    echo "  Server: $SERVER_IP"
    echo "  Port: $SLOWDNS_PORT"
    echo "  Nameserver: $NAMESERVER"
    echo "  Key: Use downloaded server.pub"
    echo ""
    
    echo -e "${YELLOW}PERFORMANCE TIPS:${NC}"
    echo "1. Run 'slowdns-optimize' after first connection test"
    echo "2. Monitor with 'monitor-slowdns.sh' regularly"
    echo "3. Adjust MTU if experiencing packet loss"
    echo "4. Use TCP BBR congestion control (already enabled)"
    echo ""
    
    echo "================================================================"
    echo -e "${GREEN}To test immediately:${NC} monitor-slowdns.sh"
    echo "================================================================"
}

# Main execution
main() {
    clear
    echo "================================================================"
    echo -e "${CYAN}      OPTIMIZED SLOWDNS INSTALLATION SCRIPT${NC}"
    echo -e "${CYAN}           (With Performance Optimizations)${NC}"
    echo "================================================================"
    echo ""
    
    # Check requirements
    check_root
    check_internet
    
    # Installation steps
    install_dependencies
    optimize_kernel
    setup_dns
    configure_openssh
    setup_slowdns
    configure_firewall
    create_startup_script
    create_monitoring_tools
    start_services
    
    # Show summary
    show_summary
    
    # Final test
    echo ""
    print_status "Performing final performance test..."
    /usr/local/bin/monitor-slowdns.sh | head -30
}

# Run main function
main "$@"
