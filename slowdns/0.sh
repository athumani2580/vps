#!/bin/bash

# ==============================================
# OpenSSH + SlowDNS Installation Script
# Ubuntu/Debian Fixed Version
# ==============================================

set -e  # Exit on any error

# ==============================================
# CONFIGURATION
# ==============================================
CONFIG_FILE="/etc/ssh_slowdns.conf"
LOG_FILE="/var/log/ssh_slowdns_install.log"
BACKUP_DIR="/etc/backup_ssh_slowdns"

# Default Values
DEFAULT_SSH_PORT=22
DEFAULT_DNS_PORT=5300
DEFAULT_MTU=1800
DEFAULT_NAMESERVER="dns.example.com"
DEFAULT_DNS1="8.8.8.8"
DEFAULT_DNS2="1.1.1.1"

# ==============================================
# COLOR DEFINITIONS
# ==============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# ==============================================
# LOGGING FUNCTIONS
# ==============================================
log_message() {
    echo -e "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $2" >> "$LOG_FILE"
}

log_success() {
    log_message "${GREEN}[✓]${NC} $1" "SUCCESS: $1"
}

log_error() {
    log_message "${RED}[✗]${NC} $1" "ERROR: $1"
}

log_warning() {
    log_message "${YELLOW}[!]${NC} $1" "WARNING: $1"
}

log_info() {
    log_message "${BLUE}[i]${NC} $1" "INFO: $1"
}

# ==============================================
# VALIDATION FUNCTIONS
# ==============================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root. Use: sudo bash $0"
        exit 1
    fi
}

validate_port() {
    local port=$1
    local name=$2
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid $name port: $port. Must be 1-65535"
        exit 1
    fi
}

# ==============================================
# UBUNTU/DEBIAN SPECIFIC FUNCTIONS
# ==============================================
configure_ubuntu_dns() {
    log_info "Configuring DNS for Ubuntu..."
    
    # Check if systemd-resolved is running
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log_warning "systemd-resolved is active. Configuring it instead of replacing..."
        
        # Create or update resolved.conf
        mkdir -p /etc/systemd/resolved.conf.d/
        cat > /etc/systemd/resolved.conf.d/99-static-dns.conf << EOF
[Resolve]
DNS=$DEFAULT_DNS1 $DEFAULT_DNS2
FallbackDNS=8.8.4.4 9.9.9.9
Domains=~.
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
Cache=yes
DNSStubListener=no
EOF
        
        # Disable DNSStubListener to free port 53
        sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf 2>/dev/null || true
        
        # Restart systemd-resolved
        systemctl restart systemd-resolved
        sleep 2
        
        # Check if resolv.conf is a symlink
        if [ -L /etc/resolv.conf ]; then
            # It's a symlink to /run/systemd/resolve/stub-resolv.conf
            # Update the target instead
            log_info "resolv.conf is a symlink to systemd-resolved"
            log_info "DNS configured via systemd-resolved"
        else
            # Create static resolv.conf
            cat > /etc/resolv.conf << EOF
# Static DNS - Managed by SSH+SlowDNS installer
nameserver $DEFAULT_DNS1
nameserver $DEFAULT_DNS2
options timeout:2 attempts:2
EOF
        fi
    else
        # systemd-resolved is not active, use static resolv.conf
        log_info "Creating static resolv.conf..."
        
        # Remove symlink if exists
        if [ -L /etc/resolv.conf ]; then
            rm -f /etc/resolv.conf
        fi
        
        # Remove immutable attribute if set
        chattr -i /etc/resolv.conf 2>/dev/null || true
        
        # Create static resolv.conf
        cat > /etc/resolv.conf << EOF
# Static DNS - Managed by SSH+SlowDNS installer
nameserver $DEFAULT_DNS1
nameserver $DEFAULT_DNS2
options timeout:2 attempts:2
EOF
        
        # Make it immutable to prevent changes
        chattr +i /etc/resolv.conf 2>/dev/null && log_info "resolv.conf made immutable" || log_warning "Could not make resolv.conf immutable"
    fi
    
    log_success "DNS configured for Ubuntu"
}

configure_ubuntu_ssh() {
    local ssh_port=$1
    
    log_info "Configuring SSH for Ubuntu..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Create minimal SSH config
    cat > /etc/ssh/sshd_config << EOF
# SSH Configuration for SlowDNS
Port $ssh_port
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
    
    # Test and restart SSH
    if sshd -t; then
        # On Ubuntu, SSH service is usually called 'ssh' not 'sshd'
        systemctl restart ssh
        systemctl enable ssh
        
        sleep 2
        
        if ss -tlnp | grep -q ":$ssh_port "; then
            log_success "SSH configured on port $ssh_port"
            return 0
        else
            log_error "SSH failed to start"
            return 1
        fi
    else
        log_error "SSH configuration test failed"
        return 1
    fi
}

configure_ubuntu_firewall() {
    local ssh_port=$1
    local dns_port=$2
    
    log_info "Configuring firewall for Ubuntu..."
    
    # Install iptables-persistent non-interactively
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y iptables-persistent
    
    # Flush existing rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    
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
    iptables -A INPUT -p tcp --dport $ssh_port -m state --state NEW -j ACCEPT
    
    # Allow SlowDNS
    iptables -A INPUT -p udp --dport $dns_port -j ACCEPT
    iptables -A INPUT -p tcp --dport $dns_port -j ACCEPT
    
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # Save rules
    iptables-save > /etc/iptables/rules.v4
    
    # Save IPv6 rules (disable IPv6 traffic)
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables-save > /etc/iptables/rules.v6
    
    log_success "Firewall configured"
}

configure_ubuntu_ipv6() {
    log_info "Disabling IPv6 for Ubuntu..."
    
    # Disable IPv6 temporarily
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1
    
    # Make persistent
    cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
    
    log_success "IPv6 disabled"
}

# ==============================================
# SLOWDNS FUNCTIONS
# ==============================================
download_slowdns() {
    log_info "Downloading SlowDNS files..."
    
    # Create directory
    mkdir -p /etc/slowdns
    cd /etc/slowdns
    
    # Download files with retry
    for file in server.key server.pub sldns-server; do
        for url in \
            "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/$file" \
            "https://raw.githubusercontent.com/athumani2580/vps/main/$file"; do
            
            if wget -q --timeout=10 -O "$file" "$url"; then
                log_success "Downloaded $file"
                break
            fi
        done
        
        if [ ! -f "$file" ]; then
            log_error "Failed to download $file"
            return 1
        fi
    done
    
    # Make binary executable
    chmod +x sldns-server
    
    log_success "SlowDNS files downloaded"
}

configure_slowdns_service() {
    local dns_port=$1
    local ssh_port=$2
    local nameserver=$3
    
    log_info "Configuring SlowDNS service..."
    
    # Stop any existing instance
    pkill -f sldns-server 2>/dev/null || true
    systemctl stop slowdns 2>/dev/null || true
    
    # Create service file
    cat > /etc/systemd/system/slowdns.service << EOF
[Unit]
Description=SlowDNS Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/slowdns
ExecStart=/etc/slowdns/sldns-server -udp :$dns_port -privkey-file /etc/slowdns/server.key $nameserver 127.0.0.1:$ssh_port
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=slowdns

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable slowdns.service
    systemctl start slowdns.service
    
    sleep 3
    
    if systemctl is-active --quiet slowdns.service; then
        log_success "SlowDNS service started"
        
        # Test connection
        if timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$dns_port" 2>/dev/null; then
            log_success "SlowDNS listening on port $dns_port"
        else
            log_warning "SlowDNS port test failed (service is running)"
        fi
    else
        log_error "Failed to start SlowDNS service"
        journalctl -u slowdns.service --no-pager -n 20
        return 1
    fi
}

# ==============================================
# MAIN INSTALLATION
# ==============================================
install_ssh_slowdns() {
    clear
    
    echo -e "${CYAN}"
    echo "========================================================"
    echo "           OpenSSH + SlowDNS Installer"
    echo "               Ubuntu/Debian Version"
    echo "========================================================"
    echo -e "${NC}"
    
    # Check root
    check_root
    
    # Get configuration
    echo ""
    read -p "Enter SSH port (default: $DEFAULT_SSH_PORT): " SSHD_PORT
    SSHD_PORT=${SSHD_PORT:-$DEFAULT_SSH_PORT}
    validate_port "$SSHD_PORT" "SSH"
    
    read -p "Enter SlowDNS port (default: $DEFAULT_DNS_PORT): " SLOWDNS_PORT
    SLOWDNS_PORT=${SLOWDNS_PORT:-$DEFAULT_DNS_PORT}
    validate_port "$SLOWDNS_PORT" "SlowDNS"
    
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    if [ -z "$NAMESERVER" ]; then
        NAMESERVER="$DEFAULT_NAMESERVER"
    fi
    
    # Get server IP
    SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
    
    echo ""
    echo "========================================================"
    echo "Installation Summary:"
    echo "  Server IP:      $SERVER_IP"
    echo "  SSH Port:       $SSHD_PORT"
    echo "  SlowDNS Port:   $SLOWDNS_PORT"
    echo "  Nameserver:     $NAMESERVER"
    echo "========================================================"
    echo ""
    
    read -p "Continue with installation? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    
    # Create log file
    echo "Installation started at $(date)" > "$LOG_FILE"
    
    # Update system first
    log_info "Updating system packages..."
    apt-get update && apt-get upgrade -y
    
    # Step 1: Configure firewall
    log_info "Step 1/6: Configuring firewall..."
    configure_ubuntu_firewall "$SSHD_PORT" "$SLOWDNS_PORT"
    
    # Step 2: Disable IPv6
    log_info "Step 2/6: Disabling IPv6..."
    configure_ubuntu_ipv6
    
    # Step 3: Configure DNS
    log_info "Step 3/6: Configuring DNS..."
    configure_ubuntu_dns
    
    # Step 4: Configure SSH
    log_info "Step 4/6: Configuring SSH..."
    if ! configure_ubuntu_ssh "$SSHD_PORT"; then
        log_error "SSH configuration failed. Attempting to restore backup..."
        if ls /etc/ssh/sshd_config.backup.* 2>/dev/null; then
            cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
            systemctl restart ssh
            log_info "SSH configuration restored"
        fi
        exit 1
    fi
    
    # Step 5: Download and configure SlowDNS
    log_info "Step 5/6: Setting up SlowDNS..."
    if ! download_slowdns; then
        log_error "Failed to download SlowDNS files"
        exit 1
    fi
    
    if ! configure_slowdns_service "$SLOWDNS_PORT" "$SSHD_PORT" "$NAMESERVER"; then
        log_error "Failed to configure SlowDNS service"
        exit 1
    fi
    
    # Step 6: System optimization
    log_info "Step 6/6: Optimizing system..."
    
    # Optimize kernel parameters
    cat > /etc/sysctl.d/99-optimize.conf << EOF
# Network optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
    
    sysctl -p /etc/sysctl.d/99-optimize.conf
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
SERVER_IP="$SERVER_IP"
SSH_PORT="$SSHD_PORT"
DNS_PORT="$SLOWDNS_PORT"
NAMESERVER="$NAMESERVER"
INSTALL_DATE="$(date)"
EOF
    
    # Final output
    echo ""
    echo -e "${GREEN}"
    echo "========================================================"
    echo "           INSTALLATION COMPLETED SUCCESSFULLY!"
    echo "========================================================"
    echo -e "${NC}"
    echo ""
    echo "Configuration:"
    echo "  Server IP:      $SERVER_IP"
    echo "  SSH Port:       $SSHD_PORT"
    echo "  SlowDNS Port:   $SLOWDNS_PORT"
    echo "  Nameserver:     $NAMESERVER"
    echo ""
    echo "Management Commands:"
    echo "  systemctl status slowdns      # Check SlowDNS status"
    echo "  systemctl restart slowdns     # Restart SlowDNS"
    echo "  systemctl stop slowdns        # Stop SlowDNS"
    echo "  journalctl -u slowdns -f      # View logs"
    echo "  systemctl status ssh          # Check SSH status"
    echo ""
    echo "Troubleshooting:"
    echo "  If SlowDNS fails, check: journalctl -u slowdns"
    echo "  Test SSH: ssh -p $SSHD_PORT root@$SERVER_IP"
    echo ""
    echo "Configuration saved to: $CONFIG_FILE"
    echo "Installation log: $LOG_FILE"
    echo ""
}

# ==============================================
# UNINSTALL
# ==============================================
uninstall_ssh_slowdns() {
    echo -e "${YELLOW}"
    echo "========================================================"
    echo "           Uninstall SSH + SlowDNS"
    echo "========================================================"
    echo -e "${NC}"
    
    read -p "Are you sure you want to uninstall? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi
    
    echo "Starting uninstallation..."
    
    # Stop and disable SlowDNS
    systemctl stop slowdns.service 2>/dev/null || true
    systemctl disable slowdns.service 2>/dev/null || true
    rm -f /etc/systemd/system/slowdns.service
    systemctl daemon-reload
    
    # Remove SlowDNS files
    rm -rf /etc/slowdns
    
    # Restore SSH config from backup
    if ls /etc/ssh/sshd_config.backup.* 2>/dev/null; then
        latest_backup=$(ls -t /etc/ssh/sshd_config.backup.* | head -1)
        cp "$latest_backup" /etc/ssh/sshd_config
        systemctl restart ssh
        echo "SSH configuration restored from backup"
    fi
    
    # Remove IPv6 disable
    rm -f /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    
    # Remove DNS configuration
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    # Remove optimization config
    rm -f /etc/sysctl.d/99-optimize.conf 2>/dev/null
    
    # Remove config file
    rm -f "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}Uninstallation completed!${NC}"
    echo "Note: Firewall rules and iptables configuration remain unchanged."
    echo "To reset firewall: iptables -F"
}

# ==============================================
# STATUS CHECK
# ==============================================
check_status() {
    echo "=== SSH + SlowDNS Status ==="
    echo ""
    
    # Check SSH
    echo "SSH Service:"
    if systemctl is-active --quiet ssh; then
        echo "  Status: Active"
        ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
        echo "  Port: $ssh_port"
    else
        echo "  Status: Inactive"
    fi
    echo ""
    
    # Check SlowDNS
    echo "SlowDNS Service:"
    if systemctl is-active --quiet slowdns.service 2>/dev/null; then
        echo "  Status: Active"
        if [ -f "$CONFIG_FILE" ]; then
            . "$CONFIG_FILE" 2>/dev/null || true
            echo "  Port: ${DNS_PORT:-Unknown}"
            echo "  Nameserver: ${NAMESERVER:-Unknown}"
        fi
    else
        echo "  Status: Not installed or inactive"
    fi
    echo ""
    
    # Check ports
    echo "Listening Ports:"
    echo "  SSH ($ssh_port):"
    ss -tlnp | grep ":$ssh_port " || echo "    Not listening"
    echo ""
    echo "  SlowDNS (5300):"
    ss -ulnp | grep ":5300 " || echo "    Not listening"
}

# ==============================================
# MAIN SCRIPT
# ==============================================
case "${1:-install}" in
    "install")
        install_ssh_slowdns
        ;;
    "uninstall")
        uninstall_ssh_slowdns
        ;;
    "status")
        check_status
        ;;
    "help")
        echo "Usage: $0 [install|uninstall|status|help]"
        echo ""
        echo "Commands:"
        echo "  install     - Install SSH + SlowDNS (default)"
        echo "  uninstall   - Remove SSH + SlowDNS"
        echo "  status      - Check current status"
        echo "  help        - Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use: $0 help"
        exit 1
        ;;
esac
