#!/bin/bash

# ==============================================
# Simple OpenSSH + SlowDNS Installer for Ubuntu
# ==============================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
SSH_PORT=22
DNS_PORT=5300
NAMESERVER=""
SERVER_IP=""

# Log functions
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

# Get server IP
get_ip() {
    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}')
    echo "Detected IP: $SERVER_IP"
}

# Install dependencies
install_deps() {
    log_info "Updating system and installing dependencies..."
    apt-get update
    apt-get install -y curl wget iptables iptables-persistent net-tools openssh-server
    log_success "Dependencies installed"
}

# Configure firewall
setup_firewall() {
    log_info "Configuring firewall..."
    
    # Flush existing rules
    iptables -F
    iptables -X
    
    # Set default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Allow SSH
    iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
    
    # Allow SlowDNS
    iptables -A INPUT -p udp --dport $DNS_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $DNS_PORT -j ACCEPT
    
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # Save rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    
    log_success "Firewall configured"
}

# Disable IPv6
disable_ipv6() {
    log_info "Disabling IPv6..."
    
    # Temporary disable
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    
    # Permanent disable
    cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    
    sysctl -p
    log_success "IPv6 disabled"
}

# Configure SSH
setup_ssh() {
    log_info "Configuring SSH..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Create new config
    cat > /etc/ssh/sshd_config << EOF
Port $SSH_PORT
Protocol 2
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3
AllowTcpForwarding yes
GatewayPorts yes
Compression delayed
UseDNS no
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
    
    # Restart SSH
    systemctl restart ssh
    log_success "SSH configured on port $SSH_PORT"
}

# Download SlowDNS files
download_slowdns() {
    log_info "Downloading SlowDNS files..."
    
    # Create directory
    rm -rf /etc/slowdns
    mkdir -p /etc/slowdns
    cd /etc/slowdns
    
    # Download files with retry
    for file in server.key server.pub sldns-server; do
        log_info "Downloading $file..."
        
        # Try multiple sources
        if ! wget -q --timeout=30 --tries=3 -O $file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/$file"; then
            log_warning "Failed first source, trying alternative..."
            wget -q --timeout=30 --tries=3 -O $file "https://raw.githubusercontent.com/athumani2580/vps/main/$file"
        fi
        
        if [ -f $file ]; then
            log_success "Downloaded $file"
        else
            log_error "Failed to download $file"
            return 1
        fi
    done
    
    # Make binary executable
    chmod +x sldns-server
    log_success "SlowDNS files downloaded"
}

# Create startup script (simpler than systemd)
create_startup_script() {
    log_info "Creating startup script..."
    
    # Kill any existing slowdns process
    pkill -f sldns-server 2>/dev/null || true
    
    # Create simple startup script
    cat > /etc/slowdns/start.sh << EOF
#!/bin/bash
cd /etc/slowdns
./sldns-server -udp :$DNS_PORT -privkey-file server.key $NAMESERVER 127.0.0.1:$SSH_PORT
EOF
    
    chmod +x /etc/slowdns/start.sh
    
    # Create systemd service the safe way
    cat > /etc/systemd/system/slowdns.service << EOF
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/slowdns
ExecStart=/etc/slowdns/sldns-server -udp :$DNS_PORT -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSH_PORT
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=slowdns

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start
    systemctl daemon-reload
    systemctl enable slowdns.service
    sleep 2
    
    log_success "Startup script created"
}

# Test SlowDNS
test_slowdns() {
    log_info "Testing SlowDNS..."
    
    # Start service
    systemctl start slowdns.service
    sleep 3
    
    # Check if running
    if pgrep -x "sldns-server" > /dev/null; then
        log_success "SlowDNS is running"
        
        # Test port
        if timeout 2 nc -z -u 127.0.0.1 $DNS_PORT 2>/dev/null; then
            log_success "SlowDNS listening on UDP port $DNS_PORT"
        else
            log_warning "SlowDNS running but port test failed"
        fi
    else
        log_error "SlowDNS failed to start"
        
        # Try direct start for debugging
        log_info "Trying direct start..."
        cd /etc/slowdns
        nohup ./sldns-server -udp :$DNS_PORT -privkey-file server.key $NAMESERVER 127.0.0.1:$SSH_PORT > /var/log/slowdns.log 2>&1 &
        sleep 2
        
        if pgrep -x "sldns-server" > /dev/null; then
            log_success "SlowDNS started directly"
        else
            log_error "Check /var/log/slowdns.log for errors"
            return 1
        fi
    fi
}

# Optimize system
optimize_system() {
    log_info "Optimizing system..."
    
    # Kernel optimizations
    cat >> /etc/sysctl.conf << EOF
# Network optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_fastopen = 3
EOF
    
    sysctl -p
    log_success "System optimized"
}

# Main installation
main_install() {
    clear
    echo "========================================="
    echo "  OpenSSH + SlowDNS Installer for Ubuntu"
    echo "========================================="
    echo ""
    
    check_root
    get_ip
    
    # Get configuration
    read -p "Enter SSH port (default: $SSH_PORT): " input
    [ ! -z "$input" ] && SSH_PORT=$input
    
    read -p "Enter SlowDNS port (default: $DNS_PORT): " input
    [ ! -z "$input" ] && DNS_PORT=$input
    
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    if [ -z "$NAMESERVER" ]; then
        log_error "Nameserver is required!"
        exit 1
    fi
    
    echo ""
    echo "Configuration:"
    echo "  SSH Port: $SSH_PORT"
    echo "  SlowDNS Port: $DNS_PORT"
    echo "  Nameserver: $NAMESERVER"
    echo "  Server IP: $SERVER_IP"
    echo ""
    
    read -p "Continue? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
    
    # Installation steps
    install_deps
    setup_firewall
    disable_ipv6
    setup_ssh
    
    if ! download_slowdns; then
        log_error "Failed to download SlowDNS files"
        exit 1
    fi
    
    create_startup_script
    optimize_system
    
    if test_slowdns; then
        echo ""
        echo "========================================="
        log_success "     INSTALLATION COMPLETED!"
        echo "========================================="
        echo ""
        echo "Server IP: $SERVER_IP"
        echo "SSH Port: $SSH_PORT"
        echo "SlowDNS Port: $DNS_PORT"
        echo "Nameserver: $NAMESERVER"
        echo ""
        echo "Commands:"
        echo "  systemctl status slowdns"
        echo "  systemctl restart slowdns"
        echo "  journalctl -u slowdns -f"
        echo ""
    else
        log_error "Installation had issues. Check above for errors."
    fi
}

# Uninstall
uninstall() {
    echo "========================================="
    echo "  Uninstall SlowDNS"
    echo "========================================="
    echo ""
    
    read -p "Are you sure? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
    
    log_info "Stopping services..."
    systemctl stop slowdns.service 2>/dev/null || true
    systemctl disable slowdns.service 2>/dev/null || true
    pkill -f sldns-server 2>/dev/null || true
    
    log_info "Removing files..."
    rm -rf /etc/slowdns
    rm -f /etc/systemd/system/slowdns.service
    systemctl daemon-reload
    
    log_info "Restoring SSH config..."
    if [ -f /etc/ssh/sshd_config.backup ]; then
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        systemctl restart ssh
    fi
    
    log_success "Uninstallation complete!"
}

# Status check
check_status() {
    echo "========================================="
    echo "  Service Status"
    echo "========================================="
    echo ""
    
    echo "SSH Status:"
    systemctl status ssh --no-pager | grep -E "(Active|Port)" || echo "  Not configured"
    echo ""
    
    echo "SlowDNS Status:"
    if systemctl is-active slowdns.service 2>/dev/null; then
        echo "  Active"
        systemctl status slowdns.service --no-pager | grep -E "(Active|PID)" || true
    else
        echo "  Inactive"
    fi
    echo ""
    
    echo "Ports listening:"
    echo "  SSH ($SSH_PORT): $(ss -tlnp | grep -c ":$SSH_PORT " || echo 0) connections"
    echo "  SlowDNS ($DNS_PORT): $(ss -ulnp | grep -c ":$DNS_PORT " || echo 0) connections"
}

# Menu
case "${1:-install}" in
    install)
        main_install
        ;;
    uninstall)
        uninstall
        ;;
    status)
        check_status
        ;;
    help)
        echo "Usage: $0 [install|uninstall|status|help]"
        echo ""
        echo "Commands:"
        echo "  install    - Install SSH + SlowDNS"
        echo "  uninstall  - Remove installation"
        echo "  status     - Check service status"
        echo "  help       - Show this help"
        ;;
    *)
        echo "Unknown command. Use: $0 help"
        ;;
esac
