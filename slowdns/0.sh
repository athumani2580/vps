#!/bin/bash

# ==============================================
# OpenSSH + SlowDNS Installation Script
# Enhanced Version with Better Security & Features
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
    if [ "$2" = "exit" ]; then
        exit 1
    fi
}

log_warning() {
    log_message "${YELLOW}[!]${NC} $1" "WARNING: $1"
}

log_info() {
    log_message "${BLUE}[i]${NC} $1" "INFO: $1"
}

log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        log_message "${DIM}[debug]${NC} $1" "DEBUG: $1"
    fi
}

# ==============================================
# VALIDATION FUNCTIONS
# ==============================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root. Use: sudo bash $0" "exit"
    fi
}

validate_port() {
    local port=$1
    local name=$2
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid $name port: $port. Must be 1-65535" "exit"
    fi
}

validate_ip() {
    local ip=$1
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    return 0
}

check_dependencies() {
    local missing=()
    
    for cmd in curl wget iptables systemctl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_warning "Missing dependencies: ${missing[*]}"
        log_info "Attempting to install missing packages..."
        
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y "${missing[@]}" || log_error "Failed to install packages"
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}" || log_error "Failed to install packages"
        elif command -v dnf &> /dev/null; then
            dnf install -y "${missing[@]}" || log_error "Failed to install packages"
        else
            log_error "Unsupported package manager. Install manually: ${missing[*]}" "exit"
        fi
    fi
}

# ==============================================
# BACKUP FUNCTIONS
# ==============================================
create_backup() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    log_info "Creating system backup..."
    
    # Backup SSH config
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup_$timestamp"
    fi
    
    # Backup iptables rules
    iptables-save > "$BACKUP_DIR/iptables.backup_$timestamp" 2>/dev/null || true
    
    # Backup network config
    if [ -f /etc/network/interfaces ]; then
        cp /etc/network/interfaces "$BACKUP_DIR/interfaces.backup_$timestamp"
    fi
    
    # Backup sysctl
    sysctl -a 2>/dev/null > "$BACKUP_DIR/sysctl.backup_$timestamp" || true
    
    log_success "Backup created in $BACKUP_DIR"
}

# ==============================================
# NETWORK FUNCTIONS
# ==============================================
get_server_ip() {
    local ip=""
    
    # Try multiple methods to get public IP
    log_debug "Detecting server IP address..."
    
    ip_services=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )
    
    for service in "${ip_services[@]}"; do
        ip=$(curl -s --connect-timeout 3 "$service" 2>/dev/null || true)
        if validate_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    
    # Fallback to local IP
    ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
    echo "$ip"
}

configure_firewall() {
    local ssh_port=$1
    local dns_port=$2
    
    log_info "Configuring firewall rules..."
    
    # Flush existing rules but save backup
    iptables-save > /tmp/iptables.backup
    
    # Basic iptables rules
    iptables -F
    iptables -X
    iptables -Z
    
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Allow SSH
    iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -j ACCEPT
    
    # Allow SlowDNS
    iptables -A INPUT -p udp --dport "$dns_port" -j ACCEPT
    iptables -A INPUT -p tcp --dport "$dns_port" -j ACCEPT
    
    # Allow ping (ICMP)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # Rate limiting for SSH
    iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -m recent --set
    iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    
    # Save rules for persistence
    if command -v iptables-save > /dev/null && command -v iptables-restore > /dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        
        # Install iptables-persistent if available
        if ! dpkg -l | grep -q iptables-persistent && command -v apt-get &> /dev/null; then
            debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
            debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
            apt-get install -y iptables-persistent
        fi
    fi
    
    log_success "Firewall configured"
}

configure_ipv6() {
    local disable=$1
    
    log_info "Configuring IPv6..."
    
    if [ "$disable" = "true" ]; then
        # Disable IPv6
        sysctl -w net.ipv6.conf.all.disable_ipv6=1
        sysctl -w net.ipv6.conf.default.disable_ipv6=1
        sysctl -w net.ipv6.conf.lo.disable_ipv6=1
        
        # Make persistent
        cat >> /etc/sysctl.conf << EOF
# Disabled by SSH+SlowDNS installer
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        
        # Block IPv6 traffic
        if command -v ip6tables &> /dev/null; then
            ip6tables -P INPUT DROP
            ip6tables -P FORWARD DROP
            ip6tables -P OUTPUT DROP
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
        
        log_success "IPv6 disabled"
    else
        # Enable IPv6 but configure properly
        sysctl -w net.ipv6.conf.all.disable_ipv6=0
        log_info "IPv6 left enabled"
    fi
    
    sysctl -p > /dev/null 2>&1
}

configure_dns_resolver() {
    log_info "Configuring DNS resolver..."
    
    # Stop and disable systemd-resolved if it exists
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        systemctl mask systemd-resolved
    fi
    
    # Remove existing resolv.conf if it's a symlink
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    
    # Create new resolv.conf
    cat > /etc/resolv.conf << EOF
# Configured by SSH+SlowDNS installer
nameserver $DEFAULT_DNS1
nameserver $DEFAULT_DNS2
options timeout:2 attempts:3 rotate
EOF
    
    # Make file immutable
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    log_success "DNS resolver configured"
}

# ==============================================
# SSH CONFIGURATION
# ==============================================
configure_ssh() {
    local ssh_port=$1
    
    log_info "Configuring OpenSSH server..."
    
    # Backup original config
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.original
    fi
    
    # Generate new SSH config with security best practices
    cat > /etc/ssh/sshd_config << EOF
# ==============================================
# OpenSSH Server Configuration
# Generated by SSH+SlowDNS Installer
# ==============================================

# Port and Protocol
Port $ssh_port
Protocol 2

# Authentication
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
GSSAPIAuthentication no
UsePAM yes

# Security
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2
AllowTcpForwarding yes
GatewayPorts yes
AllowStreamLocalForwarding no
PermitTunnel yes
Compression delayed

# Performance
MaxSessions 10
MaxStartups 10:30:100
LoginGraceTime 60

# Chroot and SFTP
Subsystem sftp internal-sftp

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# Security Restrictions
UseDNS no
StrictModes yes
IgnoreRhosts yes
HostbasedAuthentication no

# Ciphers and MACs (Modern secure defaults)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com

# Misc
DebianBanner no
Banner /etc/ssh/banner
EOF
    
    # Create SSH banner
    cat > /etc/ssh/banner << EOF
****************************************************************
Warning: Unauthorized access to this system is prohibited.
All activities are monitored and logged.
****************************************************************
EOF
    
    # Set proper permissions
    chmod 644 /etc/ssh/sshd_config
    chmod 644 /etc/ssh/banner
    chown root:root /etc/ssh/banner
    
    # Test SSH config
    if sshd -t -f /etc/ssh/sshd_config; then
        systemctl restart sshd
        systemctl enable sshd
        
        # Verify SSH is running
        sleep 2
        if ss -tlnp | grep -q ":$ssh_port "; then
            log_success "SSH configured and running on port $ssh_port"
        else
            log_error "SSH failed to start on port $ssh_port"
        fi
    else
        log_error "SSH configuration test failed. Restoring backup..."
        cp /etc/ssh/sshd_config.original /etc/ssh/sshd_config
        systemctl restart sshd
        return 1
    fi
}

# ==============================================
# SLOWDNS CONFIGURATION
# ==============================================
download_slowdns_files() {
    local slowdns_dir="/etc/slowdns"
    local github_raw="https://raw.githubusercontent.com/athumani2580/vps/main"
    
    log_info "Downloading SlowDNS files..."
    
    mkdir -p "$slowdns_dir"
    
    # File list to download
    declare -A files=(
        ["server.key"]="$github_raw/slowdns/server.key"
        ["server.pub"]="$github_raw/slowdns/server.pub"
        ["sldns-server"]="$github_raw/slowdns/sldns-server"
    )
    
    # Alternative URLs if primary fails
    declare -A fallback_files=(
        ["server.key"]="$github_raw/server.key"
        ["server.pub"]="$github_raw/server.pub"
        ["sldns-server"]="$github_raw/slowdns/sldns-server"
    )
    
    for file in "${!files[@]}"; do
        local primary_url="${files[$file]}"
        local fallback_url="${fallback_files[$file]}"
        local dest="$slowdns_dir/$file"
        
        if curl -s --fail "$primary_url" -o "$dest"; then
            log_success "Downloaded $file"
        elif curl -s --fail "$fallback_url" -o "$dest"; then
            log_success "Downloaded $file (fallback)"
        else
            log_error "Failed to download $file"
            return 1
        fi
        
        # Set executable permission for binary
        if [[ "$file" == *"server" ]]; then
            chmod +x "$dest"
        fi
    done
    
    # Verify files exist
    for file in server.key server.pub sldns-server; do
        if [ ! -f "$slowdns_dir/$file" ]; then
            log_error "Missing file: $file"
            return 1
        fi
    done
    
    log_success "All SlowDNS files downloaded"
}

configure_slowdns_service() {
    local dns_port=$1
    local ssh_port=$2
    local nameserver=$3
    local mtu=${4:-$DEFAULT_MTU}
    
    log_info "Configuring SlowDNS service..."
    
    cat > /etc/systemd/system/slowdns.service << EOF
[Unit]
Description=SlowDNS Server Service
After=network.target
Wants=network-online.target
Requires=sshd.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/etc/slowdns
ExecStart=/etc/slowdns/sldns-server -udp :$dns_port -privkey-file /etc/slowdns/server.key $nameserver 127.0.0.1:$ssh_port
Restart=always
RestartSec=5
StartLimitInterval=0

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyDirectories=/
ReadWriteDirectories=/etc/slowdns /var/log

# Resource limits
LimitNOFILE=65536
LimitNPROC=65536
LimitCORE=infinity

# Environment
Environment="GODEBUG=netdns=go"
Environment="GOMAXPROCS=2"

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=slowdns

[Install]
WantedBy=multi-user.target
EOF
    
    # Create log directory
    mkdir -p /var/log/slowdns
    
    # Reload systemd
    systemctl daemon-reload
    systemctl enable slowdns.service
    
    log_success "SlowDNS service configured"
}

start_slowdns() {
    log_info "Starting SlowDNS service..."
    
    # Stop if already running
    pkill -f sldns-server 2>/dev/null || true
    
    # Start via systemd
    if systemctl start slowdns.service; then
        sleep 3
        
        if systemctl is-active --quiet slowdns.service; then
            log_success "SlowDNS service started successfully"
            
            # Test SlowDNS
            if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
                log_success "SlowDNS listening on UDP port $SLOWDNS_PORT"
            else
                log_warning "SlowDNS may not be responding on port $SLOWDNS_PORT"
            fi
        else
            log_error "SlowDNS service failed to start"
            journalctl -u slowdns.service --no-pager -n 20
            return 1
        fi
    else
        log_error "Failed to start SlowDNS service"
        return 1
    fi
}

# ==============================================
# SYSTEM OPTIMIZATION
# ==============================================
optimize_system() {
    log_info "Optimizing system settings..."
    
    # Kernel parameters
    cat >> /etc/sysctl.conf << EOF
# Network optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
    
    # Apply sysctl settings
    sysctl -p
    
    # Increase file descriptors
    echo "* soft nofile 65536" >> /etc/security/limits.conf
    echo "* hard nofile 65536" >> /etc/security/limits.conf
    echo "root soft nofile 65536" >> /etc/security/limits.conf
    echo "root hard nofile 65536" >> /etc/security/limits.conf
    
    log_success "System optimized"
}

# ==============================================
# MONITORING AND MANAGEMENT
# ==============================================
install_monitoring() {
    log_info "Installing monitoring tools..."
    
    # Create status script
    cat > /usr/local/bin/check-ssh-slowdns << 'EOF'
#!/bin/bash

echo "=== SSH & SlowDNS Status ==="
echo "Timestamp: $(date)"
echo ""

# SSH Status
echo "SSH Service:"
systemctl status sshd --no-pager | grep -E "(Active|Main PID|CGroup|Listen)"
echo ""

# SlowDNS Status
echo "SlowDNS Service:"
systemctl status slowdns.service --no-pager | grep -E "(Active|Main PID|CGroup)"
echo ""

# Port Listening
echo "Listening Ports:"
ss -tulpn | grep -E ":$SSHD_PORT|:$SLOWDNS_PORT" | sort
echo ""

# Connections
echo "Active Connections:"
netstat -an | grep -E ":$SSHD_PORT|:$SLOWDNS_PORT" | wc -l | xargs echo "Total: "
echo ""

# Resource Usage
echo "Resource Usage:"
ps aux | grep -E "(sshd|sldns-server)" | grep -v grep
EOF
    
    chmod +x /usr/local/bin/check-ssh-slowdns
    
    # Create log rotation
    cat > /etc/logrotate.d/slowdns << EOF
/var/log/slowdns/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        systemctl reload slowdns.service > /dev/null 2>&1 || true
    endscript
}
EOF
    
    log_success "Monitoring installed"
}

# ==============================================
# MAIN INSTALLATION FUNCTION
# ==============================================
main_installation() {
    clear
    
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OpenSSH + SlowDNS Installation Script           ║"
    echo "║                  Enhanced Version                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check prerequisites
    check_root
    check_dependencies
    
    # Get configuration
    echo ""
    read -p "Enter SSH port [$DEFAULT_SSH_PORT]: " SSHD_PORT
    SSHD_PORT=${SSHD_PORT:-$DEFAULT_SSH_PORT}
    validate_port "$SSHD_PORT" "SSH"
    
    read -p "Enter SlowDNS port [$DEFAULT_DNS_PORT]: " SLOWDNS_PORT
    SLOWDNS_PORT=${SLOWDNS_PORT:-$DEFAULT_DNS_PORT}
    validate_port "$SLOWDNS_PORT" "SlowDNS"
    
    read -p "Enter MTU size [$DEFAULT_MTU]: " MTU_SIZE
    MTU_SIZE=${MTU_SIZE:-$DEFAULT_MTU}
    
    read -p "Enter nameserver [$DEFAULT_NAMESERVER]: " NAMESERVER
    NAMESERVER=${NAMESERVER:-$DEFAULT_NAMESERVER}
    
    # Get server IP
    SERVER_IP=$(get_server_ip)
    
    echo ""
    echo "================================================================"
    echo "Configuration Summary:"
    echo "  Server IP:      $SERVER_IP"
    echo "  SSH Port:       $SSHD_PORT"
    echo "  SlowDNS Port:   $SLOWDNS_PORT"
    echo "  MTU:            $MTU_SIZE"
    echo "  Nameserver:     $NAMESERVER"
    echo "================================================================"
    echo ""
    
    read -p "Proceed with installation? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    # Start installation
    log_info "Starting installation..."
    
    # Create backup
    create_backup
    
    # Configure system
    configure_firewall "$SSHD_PORT" "$SLOWDNS_PORT"
    configure_ipv6 "true"
    configure_dns_resolver
    optimize_system
    
    # Configure SSH
    configure_ssh "$SSHD_PORT"
    
    # Configure SlowDNS
    download_slowdns_files
    configure_slowdns_service "$SLOWDNS_PORT" "$SSHD_PORT" "$NAMESERVER" "$MTU_SIZE"
    start_slowdns
    
    # Install monitoring
    install_monitoring
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
# SSH+SlowDNS Configuration
SERVER_IP="$SERVER_IP"
SSH_PORT="$SSHD_PORT"
DNS_PORT="$SLOWDNS_PORT"
NAMESERVER="$NAMESERVER"
MTU="$MTU_SIZE"
INSTALL_DATE="$(date)"
EOF
    
    chmod 600 "$CONFIG_FILE"
    
    # Final output
    echo ""
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               INSTALLATION COMPLETED!                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo "================================================================"
    echo "                     CONNECTION DETAILS"
    echo "================================================================"
    echo "Server IP Address:  $SERVER_IP"
    echo "SSH Port:           $SSHD_PORT"
    echo "SlowDNS Port:       $SLOWDNS_PORT"
    echo "Nameserver:         $NAMESERVER"
    echo "MTU Size:           $MTU_SIZE"
    echo "================================================================"
    echo ""
    echo "                  MANAGEMENT COMMANDS"
    echo "================================================================"
    echo "  check-ssh-slowdns          - Check service status"
    echo "  systemctl status slowdns   - SlowDNS service status"
    echo "  systemctl restart slowdns  - Restart SlowDNS"
    echo "  journalctl -u slowdns -f   - View logs in real-time"
    echo "  systemctl status sshd      - SSH service status"
    echo "================================================================"
    echo ""
    echo "                  SECURITY RECOMMENDATIONS"
    echo "================================================================"
    echo "1. Configure SSH keys for authentication"
    echo "2. Change SSH port if necessary"
    echo "3. Monitor /var/log/auth.log for suspicious activity"
    echo "4. Keep system updated regularly"
    echo "5. Consider using fail2ban for additional protection"
    echo "================================================================"
    echo ""
    
    log_success "Installation completed successfully"
    log_info "Log file: $LOG_FILE"
    log_info "Backup directory: $BACKUP_DIR"
    log_info "Configuration file: $CONFIG_FILE"
}

# ==============================================
# UNINSTALL FUNCTION
# ==============================================
uninstall() {
    echo -e "${YELLOW}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               UNINSTALL SSH + SlowDNS                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    read -p "Are you sure you want to uninstall? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        exit 0
    fi
    
    log_info "Starting uninstallation..."
    
    # Stop services
    systemctl stop slowdns.service 2>/dev/null || true
    systemctl disable slowdns.service 2>/dev/null || true
    
    # Remove SlowDNS files
    rm -rf /etc/slowdns
    rm -f /etc/systemd/system/slowdns.service
    rm -f /usr/local/bin/check-ssh-slowdns
    rm -f /etc/logrotate.d/slowdns
    
    # Restore SSH config if backup exists
    if [ -f /etc/ssh/sshd_config.original ]; then
        cp /etc/ssh/sshd_config.original /etc/ssh/sshd_config
        systemctl restart sshd
        log_info "SSH configuration restored"
    fi
    
    # Restore iptables if backup exists
    if [ -f /tmp/iptables.backup ]; then
        iptables-restore < /tmp/iptables.backup
        log_info "Firewall rules restored"
    fi
    
    # Remove configuration files
    rm -f "$CONFIG_FILE"
    
    # Remove IPv6 restrictions
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sed -i '/disable_ipv6/d' /etc/sysctl.conf
    sysctl -p
    
    # Remove immutable attribute from resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    systemctl daemon-reload
    
    log_success "Uninstallation completed"
    echo "Note: Some configuration files may remain in $BACKUP_DIR"
}

# ==============================================
# USAGE INFORMATION
# ==============================================
show_usage() {
    echo -e "${CYAN}"
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  install     Install SSH + SlowDNS (default)"
    echo "  uninstall   Remove SSH + SlowDNS"
    echo "  status      Check service status"
    echo "  help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo bash $0 install"
    echo "  sudo bash $0 uninstall"
    echo "  sudo bash $0 status"
    echo -e "${NC}"
}

show_status() {
    echo "=== SSH + SlowDNS Status ==="
    echo ""
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "Configuration:"
        cat "$CONFIG_FILE"
        echo ""
    fi
    
    echo "Service Status:"
    systemctl status sshd --no-pager --lines=5
    echo ""
    
    if systemctl list-unit-files | grep -q slowdns.service; then
        systemctl status slowdns.service --no-pager --lines=5
    else
        echo "SlowDNS service not installed"
    fi
    
    echo ""
    echo "Listening Ports:"
    ss -tulpn | grep -E ":$DEFAULT_SSH_PORT|:$DEFAULT_DNS_PORT" || true
}

# ==============================================
# MAIN SCRIPT ENTRY POINT
# ==============================================
case "${1:-install}" in
    "install")
        main_installation
        ;;
    "uninstall")
        uninstall
        ;;
    "status")
        show_status
        ;;
    "help"|"--help"|"-h")
        show_usage
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
