#!/bin/bash

# ==============================================
# OpenSSH + SlowDNS Installation Script
# Ubuntu/Debian Compatible Version
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

check_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

install_dependencies() {
    local distro=$(check_distro)
    
    log_info "Installing dependencies for $distro..."
    
    case "$distro" in
        ubuntu|debian)
            apt-get update
            apt-get install -y \
                curl \
                wget \
                iptables \
                iptables-persistent \
                net-tools \
                netcat-openbsd \
                openssh-server \
                systemd \
                jq \
                dnsutils
            ;;
        centos|rhel|fedora|almalinux|rocky)
            yum install -y \
                curl \
                wget \
                iptables \
                iptables-services \
                net-tools \
                nmap-ncat \
                openssh-server \
                systemd \
                jq \
                bind-utils
            ;;
        *)
            log_error "Unsupported distribution: $distro" "exit"
            ;;
    esac
    
    log_success "Dependencies installed"
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
    if command -v iptables-save > /dev/null; then
        iptables-save > "$BACKUP_DIR/iptables.backup_$timestamp" 2>/dev/null || true
    fi
    
    # Backup service files
    if [ -f /etc/systemd/system/ssh.service ] || [ -f /lib/systemd/system/ssh.service ] || [ -f /usr/lib/systemd/system/ssh.service ]; then
        find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -name "*ssh*" -exec cp {} "$BACKUP_DIR/" \; 2>/dev/null || true
    fi
    
    log_success "Backup created in $BACKUP_DIR"
}

# ==============================================
# NETWORK FUNCTIONS
# ==============================================
get_server_ip() {
    local ip=""
    
    # Try multiple methods to get public IP
    ip_services=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
        "https://ipinfo.io/ip"
    )
    
    for service in "${ip_services[@]}"; do
        ip=$(curl -s --connect-timeout 3 "$service" 2>/dev/null || true)
        if validate_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    
    # Fallback to local IP
    ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    if [ -z "$ip" ]; then
        ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
    fi
    
    echo "$ip"
}

configure_firewall() {
    local ssh_port=$1
    local dns_port=$2
    local distro=$(check_distro)
    
    log_info "Configuring firewall ($distro)..."
    
    case "$distro" in
        ubuntu|debian)
            # Install iptables-persistent if not present
            if ! dpkg -l | grep -q iptables-persistent; then
                echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
                echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
                apt-get install -y iptables-persistent
            fi
            
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
            iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -j ACCEPT
            
            # Allow SlowDNS
            iptables -A INPUT -p udp --dport "$dns_port" -j ACCEPT
            iptables -A INPUT -p tcp --dport "$dns_port" -j ACCEPT
            
            # Allow ICMP (ping)
            iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
            
            # Rate limiting for SSH
            iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -m recent --set --name SSH
            iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
            
            # Save rules
            iptables-save > /etc/iptables/rules.v4
            
            # IPv6 rules
            if command -v ip6tables > /dev/null; then
                ip6tables -F
                ip6tables -X
                ip6tables -P INPUT DROP
                ip6tables -P FORWARD DROP
                ip6tables -P OUTPUT DROP
                ip6tables -A INPUT -i lo -j ACCEPT
                ip6tables -A OUTPUT -o lo -j ACCEPT
                ip6tables-save > /etc/iptables/rules.v6
            fi
            
            # Enable and restart service
            systemctl enable netfilter-persistent 2>/dev/null || systemctl enable iptables-persistent 2>/dev/null || true
            systemctl restart netfilter-persistent 2>/dev/null || systemctl restart iptables-persistent 2>/dev/null || true
            ;;
            
        centos|rhel|fedora|almalinux|rocky)
            # Stop firewalld if running
            systemctl stop firewalld 2>/dev/null || true
            systemctl disable firewalld 2>/dev/null || true
            
            # Start iptables
            systemctl start iptables 2>/dev/null || true
            systemctl enable iptables 2>/dev/null || true
            
            # Configure iptables
            iptables -F
            iptables -X
            
            iptables -P INPUT DROP
            iptables -P FORWARD DROP
            iptables -P OUTPUT ACCEPT
            
            iptables -A INPUT -i lo -j ACCEPT
            iptables -A OUTPUT -o lo -j ACCEPT
            iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -j ACCEPT
            iptables -A INPUT -p udp --dport "$dns_port" -j ACCEPT
            iptables -A INPUT -p tcp --dport "$dns_port" -j ACCEPT
            iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
            
            # Save rules
            service iptables save 2>/dev/null || iptables-save > /etc/sysconfig/iptables
            ;;
    esac
    
    log_success "Firewall configured"
}

configure_ipv6() {
    local disable=$1
    
    log_info "Configuring IPv6..."
    
    if [ "$disable" = "true" ]; then
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
    else
        # Enable IPv6
        sysctl -w net.ipv6.conf.all.disable_ipv6=0
        sysctl -w net.ipv6.conf.default.disable_ipv6=0
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0
        rm -f /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null || true
        log_info "IPv6 enabled"
    fi
}

configure_dns_resolver() {
    local distro=$(check_distro)
    
    log_info "Configuring DNS resolver ($distro)..."
    
    # Stop systemd-resolved if running
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        systemctl mask systemd-resolved
    fi
    
    # Remove symlink if exists
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    
    # Create static resolv.conf
    cat > /etc/resolv.conf << EOF
# Static DNS configured by SSH+SlowDNS installer
nameserver $DEFAULT_DNS1
nameserver $DEFAULT_DNS2
options timeout:2 attempts:2 rotate
EOF
    
    # Make immutable
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    log_success "DNS resolver configured"
}

# ==============================================
# SSH CONFIGURATION (UBUNTU/DEBIAN COMPATIBLE)
# ==============================================
configure_ssh_ubuntu() {
    local ssh_port=$1
    
    log_info "Configuring SSH for Ubuntu/Debian..."
    
    # Backup original config
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    fi
    
    # Check SSH service name
    SSH_SERVICE="ssh"
    if systemctl list-unit-files | grep -q "sshd.service"; then
        SSH_SERVICE="sshd"
    fi
    
    # Create new SSH config
    cat > /etc/ssh/sshd_config << EOF
# SSH Server Configuration
# Generated by SSH+SlowDNS installer

# Basic settings
Port $ssh_port
Protocol 2
AddressFamily inet
ListenAddress 0.0.0.0

# Authentication
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Security
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3
AllowTcpForwarding yes
GatewayPorts yes
Compression delayed
UseDNS no

# Performance
MaxSessions 100
MaxStartups 100:30:200
LoginGraceTime 30

# Subsystem
Subsystem sftp /usr/lib/openssh/sftp-server

# Ciphers (compatible with most clients)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
EOF
    
    # Test SSH config
    if sshd -t -f /etc/ssh/sshd_config; then
        # Restart SSH service using correct name
        systemctl restart "$SSH_SERVICE"
        
        # Enable service (avoid alias error)
        if [ "$SSH_SERVICE" = "ssh" ] && systemctl list-unit-files | grep -q "ssh.service"; then
            systemctl enable ssh.service
        elif [ "$SSH_SERVICE" = "sshd" ] && systemctl list-unit-files | grep -q "sshd.service"; then
            systemctl enable sshd.service
        else
            systemctl enable "$SSH_SERVICE" 2>/dev/null || true
        fi
        
        sleep 2
        
        # Verify SSH is running
        if ss -tlnp | grep -q ":$ssh_port "; then
            log_success "SSH configured on port $ssh_port"
            return 0
        else
            log_error "SSH failed to start on port $ssh_port"
            return 1
        fi
    else
        log_error "SSH configuration test failed"
        return 1
    fi
}

configure_ssh_centos() {
    local ssh_port=$1
    
    log_info "Configuring SSH for CentOS/RHEL..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Update SSH config
    sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    sed -i "s/^Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    
    # Enable necessary settings
    sed -i 's/^#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
    
    # Restart SSH
    systemctl restart sshd
    systemctl enable sshd
    
    sleep 2
    
    if ss -tlnp | grep -q ":$ssh_port "; then
        log_success "SSH configured on port $ssh_port"
        return 0
    else
        log_error "SSH failed to start on port $ssh_port"
        return 1
    fi
}

configure_ssh() {
    local ssh_port=$1
    local distro=$(check_distro)
    
    case "$distro" in
        ubuntu|debian)
            configure_ssh_ubuntu "$ssh_port"
            ;;
        centos|rhel|fedora|almalinux|rocky)
            configure_ssh_centos "$ssh_port"
            ;;
        *)
            log_error "Unsupported distribution for SSH configuration: $distro"
            return 1
            ;;
    esac
}

# ==============================================
# SLOWDNS CONFIGURATION
# ==============================================
download_slowdns_files() {
    local slowdns_dir="/etc/slowdns"
    
    log_info "Downloading SlowDNS files..."
    
    # Create directory
    rm -rf "$slowdns_dir"
    mkdir -p "$slowdns_dir"
    
    # Base URLs
    local base_url="https://raw.githubusercontent.com/athumani2580/vps/main"
    local files=(
        "slowdns/server.key"
        "slowdns/server.pub"
        "slowdns/sldns-server"
    )
    
    # Download each file
    for file in "${files[@]}"; do
        local filename=$(basename "$file")
        local url="$base_url/$file"
        local dest="$slowdns_dir/$filename"
        
        if wget -q --timeout=10 --tries=3 -O "$dest" "$url"; then
            log_success "Downloaded $filename"
        else
            # Try alternative URL
            local alt_url="https://raw.githubusercontent.com/athumani2580/vps/main/$filename"
            if wget -q --timeout=10 --tries=3 -O "$dest" "$alt_url"; then
                log_success "Downloaded $filename (alternative)"
            else
                log_error "Failed to download $filename"
                return 1
            fi
        fi
        
        # Set executable permission for binary
        if [[ "$filename" == *"server" ]]; then
            chmod +x "$dest"
        fi
    done
    
    # Verify downloads
    if [ ! -f "$slowdns_dir/server.key" ] || [ ! -f "$slowdns_dir/server.pub" ] || [ ! -f "$slowdns_dir/sldns-server" ]; then
        log_error "Missing SlowDNS files"
        return 1
    fi
    
    log_success "SlowDNS files downloaded"
}

configure_slowdns_service() {
    local dns_port=$1
    local ssh_port=$2
    local nameserver=$3
    local mtu=${4:-$DEFAULT_MTU}
    local distro=$(check_distro)
    
    log_info "Configuring SlowDNS service ($distro)..."
    
    # Stop existing service
    pkill -f sldns-server 2>/dev/null || true
    systemctl stop slowdns 2>/dev/null || true
    systemctl disable slowdns 2>/dev/null || true
    
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
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=slowdns

# Security
NoNewPrivileges=yes
PrivateTmp=yes

# Resource limits
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start service
    systemctl enable slowdns.service
    sleep 1
    
    log_success "SlowDNS service configured"
}

start_slowdns() {
    local dns_port=$1
    
    log_info "Starting SlowDNS service..."
    
    # Stop any existing process
    pkill -f sldns-server 2>/dev/null || true
    
    # Start via systemd
    if systemctl start slowdns.service; then
        sleep 3
        
        if systemctl is-active --quiet slowdns.service; then
            log_success "SlowDNS service started"
            
            # Test if service is listening
            if timeout 2 nc -z -u 127.0.0.1 "$dns_port" 2>/dev/null || timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$dns_port" 2>/dev/null; then
                log_success "SlowDNS listening on UDP port $dns_port"
            else
                log_warning "SlowDNS may not be responding (check logs)"
                log_info "Run: journalctl -u slowdns.service -f"
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
    local distro=$(check_distro)
    
    log_info "Optimizing system ($distro)..."
    
    # Common optimizations
    cat > /etc/sysctl.d/99-optimizations.conf << EOF
# Network optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 5000

# TCP optimizations
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 5000

# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
EOF
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-optimizations.conf
    
    # Increase file descriptors
    cat >> /etc/security/limits.conf << EOF
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
    
    # Enable BBR if available
    if modprobe tcp_bbr 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
        log_success "TCP BBR enabled"
    fi
    
    log_success "System optimized"
}

# ==============================================
# INSTALLATION MAIN FUNCTION
# ==============================================
main_installation() {
    clear
    
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OpenSSH + SlowDNS Installation Script           ║"
    echo "║               Ubuntu/Debian Compatible                   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check root
    check_root
    
    # Detect distribution
    DISTRO=$(check_distro)
    echo ""
    log_info "Detected distribution: $DISTRO"
    
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
    echo "  Distribution:   $DISTRO"
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
    
    # Create backup first
    create_backup
    
    # Install dependencies
    install_dependencies
    
    # Configure system
    log_info "Step 1/6: Configuring firewall..."
    configure_firewall "$SSHD_PORT" "$SLOWDNS_PORT"
    
    log_info "Step 2/6: Configuring IPv6..."
    configure_ipv6 "true"
    
    log_info "Step 3/6: Configuring DNS resolver..."
    configure_dns_resolver
    
    log_info "Step 4/6: Optimizing system..."
    optimize_system
    
    log_info "Step 5/6: Configuring SSH..."
    if configure_ssh "$SSHD_PORT"; then
        log_success "SSH configuration completed"
    else
        log_error "SSH configuration failed"
        log_info "Restoring SSH backup..."
        if [ -f /etc/ssh/sshd_config.backup ]; then
            cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        fi
        exit 1
    fi
    
    log_info "Step 6/6: Configuring SlowDNS..."
    if download_slowdns_files; then
        if configure_slowdns_service "$SLOWDNS_PORT" "$SSHD_PORT" "$NAMESERVER" "$MTU_SIZE"; then
            if start_slowdns "$SLOWDNS_PORT"; then
                log_success "SlowDNS configuration completed"
            else
                log_error "Failed to start SlowDNS"
            fi
        else
            log_error "Failed to configure SlowDNS service"
        fi
    else
        log_error "Failed to download SlowDNS files"
    fi
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
# SSH+SlowDNS Configuration
DISTRO="$DISTRO"
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
    echo "Distribution:       $DISTRO"
    echo "================================================================"
    echo ""
    echo "                  MANAGEMENT COMMANDS"
    echo "================================================================"
    echo "  systemctl status slowdns     - Check SlowDNS status"
    echo "  systemctl restart slowdns    - Restart SlowDNS"
    echo "  systemctl stop slowdns       - Stop SlowDNS"
    echo "  journalctl -u slowdns -f     - View real-time logs"
    echo "  systemctl status ssh         - Check SSH status"
    echo "================================================================"
    echo ""
    echo "                  TROUBLESHOOTING"
    echo "================================================================"
    echo "If SlowDNS fails to start:"
    echo "  1. Check logs: journalctl -u slowdns.service"
    echo "  2. Test manually: /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT"
    echo "  3. Check firewall: iptables -L -n -v"
    echo "  4. Verify port: netstat -tulpn | grep $SLOWDNS_PORT"
    echo "================================================================"
    echo ""
    
    log_success "Installation completed"
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
    
    read -p "Are you sure? This will remove SlowDNS and restore original SSH config. (y/N): " confirm
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
    rm -f /usr/local/bin/check-ssh-slowdns 2>/dev/null
    rm -f /etc/logrotate.d/slowdns 2>/dev/null
    
    # Restore SSH config
    if [ -f /etc/ssh/sshd_config.backup ]; then
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        log_info "SSH configuration restored"
    fi
    
    # Restore iptables
    if [ -f "$BACKUP_DIR/iptables.backup"* ]; then
        latest_backup=$(ls -t "$BACKUP_DIR"/iptables.backup* 2>/dev/null | head -1)
        if [ -f "$latest_backup" ]; then
            iptables-restore < "$latest_backup"
            log_info "Firewall rules restored"
        fi
    fi
    
    # Remove IPv6 disable
    rm -f /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    
    # Remove resolv.conf immutable attribute
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Remove optimizations
    rm -f /etc/sysctl.d/99-optimizations.conf 2>/dev/null
    
    systemctl daemon-reload
    
    # Remove config file
    rm -f "$CONFIG_FILE"
    
    log_success "Uninstallation completed"
    echo ""
    echo "Note: Original configuration backups are kept in: $BACKUP_DIR"
}

# ==============================================
# STATUS FUNCTION
# ==============================================
show_status() {
    echo "=== SSH + SlowDNS Status ==="
    echo ""
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "Configuration:"
        cat "$CONFIG_FILE"
        echo ""
    else
        echo "No configuration found (not installed?)"
        echo ""
    fi
    
    echo "SSH Service:"
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        echo "  Status: Active"
        ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
        echo "  Port: $ssh_port"
    else
        echo "  Status: Inactive"
    fi
    echo ""
    
    echo "SlowDNS Service:"
    if systemctl is-active --quiet slowdns.service 2>/dev/null; then
        echo "  Status: Active"
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE" 2>/dev/null
            echo "  Port: ${DNS_PORT:-Unknown}"
            echo "  Nameserver: ${NAMESERVER:-Unknown}"
        fi
    else
        echo "  Status: Inactive"
    fi
    echo ""
    
    echo "Listening Ports:"
    ss -tulpn | grep -E ":(22|$ssh_port|5300)" | sort
}

# ==============================================
# MAIN SCRIPT
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
        echo "Usage: $0 [install|uninstall|status|help]"
        echo ""
        echo "Commands:"
        echo "  install    - Install SSH + SlowDNS (default)"
        echo "  uninstall  - Remove SSH + SlowDNS"
        echo "  status     - Show current status"
        echo "  help       - Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use: $0 help"
        exit 1
        ;;
esac
