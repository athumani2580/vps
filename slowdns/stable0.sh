#!/bin/bash

# ===================================================================
# Stable OpenSSH SlowDNS Installation Script
# With Error Handling, Monitoring, and Stability Enhancements
# ===================================================================

set -e  # Exit on error
trap 'print_error "Installation failed at line $LINENO"; exit 1' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300
BACKUP_DIR="/root/backup_slowdns_$(date +%Y%m%d_%H%M%S)"

# Functions
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Create backup
create_backup() {
    print_info "Creating backup at $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null || true
    cp /etc/resolv.conf "$BACKUP_DIR/" 2>/dev/null || true
    cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
    print_success "Backup created"
}

# Check root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

# Check system resources
check_resources() {
    print_info "Checking system resources..."
    
    # Check memory (need at least 256MB)
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 256 ]; then
        print_error "Insufficient memory: ${total_mem}MB (need 256MB)"
        exit 1
    fi
    print_success "Memory: ${total_mem}MB"
    
    # Check disk space (need 1GB free)
    free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 1024 ]; then
        print_error "Low disk space: ${free_space}MB (need 1GB)"
        exit 1
    fi
    print_success "Disk space: ${free_space}MB free"
}

# Check port conflicts
check_port_conflicts() {
    print_info "Checking port availability..."
    local ports=(22 69 5300)
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            print_warning "Port $port is already in use!"
            ss -tuln | grep ":$port"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        else
            print_success "Port $port is available"
        fi
    done
}

# Configure SSH ports
configure_ssh() {
    print_info "Configuring SSH ports..."
    
    # Backup current config
    cp /etc/ssh/sshd_config "$BACKUP_DIR/"
    
    # Remove existing custom ports if any
    sed -i '/^Port 69$/d' /etc/ssh/sshd_config
    sed -i '/^Port 22$/d' /etc/ssh/sshd_config
    
    # Add ports at the beginning
    sed -i '1i Port 22\nPort 69' /etc/ssh/sshd_config
    
    # Enable TCP forwarding
    sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    
    # Validate config before restart
    if sshd -t; then
        systemctl restart sshd
        print_success "SSH configured on ports 22 and 69"
    else
        print_error "SSH config invalid - rolling back"
        cp "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config
        systemctl restart sshd
        exit 1
    fi
}

# Setup SlowDNS directory
setup_slowdns_directory() {
    print_info "Setting up SlowDNS directory..."
    rm -rf /etc/slowdns
    mkdir -p /etc/slowdns
    print_success "SlowDNS directory created"
}

# Download SlowDNS files
download_slowdns_files() {
    print_info "Downloading SlowDNS files..."
    
    local files=("server.key" "server.pub" "sldns-server")
    local urls=(
        "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
        "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
        "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
    )
    
    for i in "${!files[@]}"; do
        wget -q -O "/etc/slowdns/${files[$i]}" "${urls[$i]}"
        if [ $? -eq 0 ]; then
            print_success "${files[$i]} downloaded"
        else
            print_error "Failed to download ${files[$i]}"
            exit 1
        fi
    done
    
    chmod +x /etc/slowdns/sldns-server
    print_success "File permissions set"
}

# Create SlowDNS service
create_slowdns_service() {
    print_info "Creating SlowDNS service..."
    
    cat > /etc/systemd/system/server-sldns.service << 'EOF'
[Unit]
Description=Server SlowDNS Stable
Documentation=https://github.com/athumani2580
After=network.target nss-lookup.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :5300 -mtu 1800 -privkey-file /etc/slowdns/server.key dns.example.com 127.0.0.1:69
Restart=always
RestartSec=10
StartLimitBurst=0

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096
MemoryMax=512M
CPUQuota=60%

# Logging
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

[Install]
WantedBy=multi-user.target
EOF

    print_success "SlowDNS service file created"
}

# Setup Fail2ban
setup_fail2ban() {
    print_info "Installing and configuring Fail2ban..."
    
    # Install fail2ban
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y fail2ban -qq
    elif command -v yum &> /dev/null; then
        yum install -y fail2ban -q
    elif command -v dnf &> /dev/null; then
        dnf install -y fail2ban -q
    else
        print_error "Package manager not supported"
        return 1
    fi
    
    # Create jail.local
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ssh,22,69
logpath = %(sshd_log)s
maxretry = 3
bantime = 3600

[sshd-ddos]
enabled = true
port = ssh,22,69
logpath = %(sshd_log)s
maxretry = 5
bantime = 7200

[slowdns]
enabled = true
port = 5300
protocol = udp
filter = slowdns
logpath = /var/log/slowdns.log
maxretry = 10
bantime = 3600
EOF
    
    # Create filter
    cat > /etc/fail2ban/filter.d/slowdns.conf << 'EOF'
[Definition]
failregex = ^.*Failed authentication from <HOST>.*$
            ^.*Invalid request from <HOST>.*$
            ^.*Connection attempt from <HOST>.*$
ignoreregex =
EOF
    
    # Create log file
    touch /var/log/slowdns.log
    chmod 644 /var/log/slowdns.log
    
    # Start fail2ban
    systemctl restart fail2ban 2>/dev/null
    systemctl enable fail2ban 2>/dev/null
    
    if systemctl is-active --quiet fail2ban; then
        print_success "Fail2ban installed and running"
    else
        print_error "Fail2ban failed to start"
    fi
}

# Setup log rotation
setup_logrotate() {
    print_info "Configuring log rotation..."
    
    cat > /etc/logrotate.d/slowdns << 'EOF'
/var/log/slowdns.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl kill -s USR1 server-sldns 2>/dev/null || true
    endscript
}
EOF
    
    print_success "Log rotation configured"
}

# Setup rate limiting
setup_rate_limiting() {
    print_info "Configuring rate limiting..."
    
    # Add rate limiting rules
    iptables -A INPUT -p udp --dport 5300 -m limit --limit 30/minute --limit-burst 50 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p udp --dport 5300 -j DROP 2>/dev/null || true
    
    # Save rules
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    print_success "Rate limiting added (30 connections/minute)"
}

# Setup monitoring
setup_monitoring() {
    print_info "Setting up health monitoring..."
    
    cat > /etc/cron.d/slowdns_monitor << 'EOF'
# Monitor SlowDNS every 5 minutes
*/5 * * * * root pgrep -x "sldns-server" > /dev/null || systemctl restart server-sldns
# Check service status every 10 minutes
*/10 * * * * root systemctl is-active --quiet server-sldns || systemctl start server-sldns
EOF
    
    print_success "Health monitoring configured"
}

# Configure DNS
configure_dns() {
    print_info "Configuring DNS settings..."
    
    # Stop systemd-resolved
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    systemctl mask systemd-resolved 2>/dev/null || true
    pkill -9 systemd-resolved 2>/dev/null || true
    
    # Configure resolv.conf
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
options timeout:2 attempts:3 rotate
EOF
    
    chattr +i /etc/resolv.conf 2>/dev/null || true
    print_success "DNS configured with Google and Cloudflare"
}

# Disable IPv6
disable_ipv6() {
    print_info "Disabling IPv6..."
    
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true
    
    # Add to sysctl if not exists
    if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi
    
    sysctl -p > /dev/null 2>&1
    print_success "IPv6 disabled"
}

# System tweaks
system_tweaks() {
    print_info "Applying system tweaks..."
    
    cat >> /etc/sysctl.conf << 'EOF'

# SlowDNS performance tweaks
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
EOF
    
    sysctl -p > /dev/null 2>&1
    print_success "System tweaks applied"
}

# Validate GitHub token
validate_github_token() {
    local token=$1
    if [ -z "$token" ]; then
        print_error "GitHub token required"
        return 1
    fi
    
    if curl -s -H "Authorization: token $token" "https://api.github.com/user" | grep -q "login"; then
        print_success "GitHub token validated"
        return 0
    else
        print_error "Invalid GitHub token"
        return 1
    fi
}

# Start services
start_services() {
    print_info "Starting services..."
    
    # Kill existing instances
    pkill sldns-server 2>/dev/null || true
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start SlowDNS
    systemctl enable server-sldns > /dev/null 2>&1
    systemctl start server-sldns
    
    sleep 3
    
    # Check if service is running
    if systemctl is-active --quiet server-sldns; then
        print_success "SlowDNS service started"
    else
        print_error "SlowDNS service failed to start"
        print_info "Checking logs: journalctl -u server-sldns -n 20"
        return 1
    fi
    
    # Test connectivity
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS listening on port $SLOWDNS_PORT"
    else
        print_warning "SlowDNS port test failed - check firewall"
    fi
    
    # Test SSH port
    if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
        print_success "SSH port 69 is accessible"
    else
        print_warning "SSH port 69 test failed"
    fi
}

# Display final summary
display_summary() {
    echo ""
    echo "=================================================================="
    print_success " Installation Completed Successfully!"
    echo "=================================================================="
    echo ""
    echo "📊 Service Status:"
    echo "   ├─ SSH: Running on ports 22, 69"
    echo "   ├─ SlowDNS: Running on port $SLOWDNS_PORT"
    echo "   ├─ Fail2ban: $(systemctl is-active fail2ban)"
    echo "   └─ Logging: /var/log/slowdns.log"
    echo ""
    echo "🛡️ Protection:"
    echo "   ├─ Rate Limiting: 30 conn/min"
    echo "   ├─ Fail2ban Jails: sshd, slowdns"
    echo "   ├─ Log Rotation: 7 days"
    echo "   └─ Auto-restart: Enabled (10s)"
    echo ""
    echo "📁 Backup Location: $BACKUP_DIR"
    echo ""
    echo "🔧 Useful Commands:"
    echo "   ├─ View logs: tail -f /var/log/slowdns.log"
    echo "   ├─ Restart service: systemctl restart server-sldns"
    echo "   ├─ Check status: systemctl status server-sldns"
    echo "   └─ Fail2ban status: fail2ban-client status"
    echo ""
    echo "=================================================================="
}

# Main installation
main() {
    echo "=================================================================="
    echo "     Stable OpenSSH SlowDNS Installation Script v2.0"
    echo "=================================================================="
    echo ""
    
    # Pre-flight checks
    check_root
    check_resources
    create_backup
    check_port_conflicts
    
    # Get nameserver
    echo ""
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    if [ -z "$NAMESERVER" ]; then
        print_error "Nameserver required"
        exit 1
    fi
    
    # Update service file with custom nameserver
    sed -i "s/dns.example.com/$NAMESERVER/g" /etc/systemd/system/server-sldns.service 2>/dev/null || true
    
    echo ""
    print_info "Starting installation..."
    echo ""

    # Installation steps
    configure_ssh
    setup_slowdns_directory
    download_slowdns_files
    create_slowdns_service
    setup_fail2ban
    setup_logrotate
    setup_rate_limiting
    setup_monitoring
    configure_dns
    disable_ipv6
    system_tweaks
    start_services
    
    # Final summary
    display_summary
    
    # GitHub token installation
    echo ""
    print_warning "DNS Installer - Token Required"
    echo ""
    read -p "Enter GitHub token: " token
    
    if validate_github_token "$token"; then
        print_info "Running DNS installer..."
        bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/update4.sh")
    else
        print_error "Skipping DNS installer - invalid token"
    fi
    
    echo ""
    print_success "All done! System is stable and monitored."
}

# Run main function
main
