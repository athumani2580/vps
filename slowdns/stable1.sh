#!/bin/bash
#
# OpenSSH + SlowDNS installer
# Hardened for idempotency, speed (parallel downloads), and error handling.

set -uo pipefail  # NOT -e: this script intentionally continues past soft failures
                   # and reports them via print_error, so -e would abort too early.

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SSHD_PORT=22
SSHD_ALT_PORT=69
SLOWDNS_PORT=5300
DOWNLOAD_RETRIES=3
DOWNLOAD_TIMEOUT=15
REPO_BASE="https://raw.githubusercontent.com/athumani2580/vps/main/slowdns"

TEMP_DIR="$(mktemp -d)"

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

cleanup_temp_files() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_temp_files EXIT INT TERM

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Log / temp-file maintenance
# ---------------------------------------------------------------------------
auto_delete_old_logs() {
    local log_dir="/var/log"
    local days_to_keep=7

    print_warning "Auto-deleting log files older than ${days_to_keep} days..."

    find "$log_dir" -name "fail2ban.log*" -type f -mtime +"$days_to_keep" -delete 2>/dev/null
    find "$log_dir" -name "slowdns.log*"  -type f -mtime +"$days_to_keep" -delete 2>/dev/null
    find "$log_dir" -name "auth.log*"     -type f -mtime +"$days_to_keep" -delete 2>/dev/null
    find "$log_dir" -name "secure*"       -type f -mtime +"$days_to_keep" -delete 2>/dev/null

    if [ -f /var/log/slowdns.log ]; then
        local log_size
        log_size=$(stat -c%s /var/log/slowdns.log 2>/dev/null || stat -f%z /var/log/slowdns.log 2>/dev/null || echo 0)
        if [ "$log_size" -gt 10485760 ]; then  # 10MB
            mv /var/log/slowdns.log "/var/log/slowdns.log.$(date +%Y%m%d_%H%M%S)"
            touch /var/log/slowdns.log
            chmod 644 /var/log/slowdns.log
            find "$log_dir" -name "slowdns.log.*"    -type f -mtime +1  -exec gzip {} \; 2>/dev/null
            find "$log_dir" -name "slowdns.log.*.gz" -type f -mtime +30 -delete 2>/dev/null
        fi
    fi

    find /tmp -maxdepth 1 -name "*.tmp"  -type f -mtime +1 -delete 2>/dev/null
    find /tmp -maxdepth 1 -name "wget.*" -type f -mtime +1 -delete 2>/dev/null
    find /tmp -maxdepth 1 -name "curl.*" -type f -mtime +1 -delete 2>/dev/null

    if command -v apt-get &>/dev/null; then
        apt-get clean 2>/dev/null
        apt-get autoclean 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum clean all 2>/dev/null
    fi

    print_success "Log cleanup completed"
}

auto_delete_install_files() {
    print_warning "Cleaning up temporary installation files..."
    find /etc/slowdns -name "*.tmp"     -type f -mtime +1 -delete 2>/dev/null
    find /etc/slowdns -name "*.backup"  -type f -mtime +7 -delete 2>/dev/null
    find /etc/systemd/system -name "*.backup" -type f -mtime +7 -delete 2>/dev/null
    find /etc/fail2ban -name "*.backup" -type f -mtime +7 -delete 2>/dev/null
    print_success "Installation files cleanup completed"
}

setup_auto_delete_cron() {
    print_warning "Setting up auto-delete cron job..."

    local cron_job="0 2 * * * /usr/bin/find /var/log -name '*.log.*' -type f -mtime +7 -delete 2>/dev/null && /usr/bin/find /tmp -type f -atime +1 -delete 2>/dev/null"

    # Idempotent: only add if not already present
    if ! crontab -l 2>/dev/null | grep -qF "$cron_job"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    fi

    cat > /etc/cron.weekly/cleanup-temp-files << 'EOF'
#!/bin/bash
find /var/log -name "*.log.*" -type f -mtime +7 -delete
find /var/log -name "*.gz" -type f -mtime +30 -delete
rm -rf /tmp/* 2>/dev/null
rm -rf /var/tmp/* 2>/dev/null
apt-get clean 2>/dev/null || yum clean all 2>/dev/null
systemctl restart fail2ban 2>/dev/null
systemctl restart server-sldns 2>/dev/null
exit 0
EOF
    chmod +x /etc/cron.weekly/cleanup-temp-files
    print_success "Auto-delete cron job configured"
}

# ---------------------------------------------------------------------------
# Downloads (parallelized, retried, verified)
# ---------------------------------------------------------------------------
download_with_retry() {
    # download_with_retry <url> <dest>
    local url="$1" dest="$2" attempt=1
    while [ "$attempt" -le "$DOWNLOAD_RETRIES" ]; do
        if wget -q --timeout="$DOWNLOAD_TIMEOUT" -O "$dest" "$url"; then
            if [ -s "$dest" ]; then
                return 0
            fi
        fi
        print_warning "Download attempt $attempt/$DOWNLOAD_RETRIES failed for $(basename "$dest"), retrying..."
        attempt=$((attempt + 1))
        sleep 1
    done
    return 1
}

download_slowdns_files() {
    print_warning "Downloading SlowDNS files (parallel)..."

    local pids=()
    download_with_retry "$REPO_BASE/server.key"    "$TEMP_DIR/server.key"    & pids+=($!)
    download_with_retry "$REPO_BASE/server.pub"    "$TEMP_DIR/server.pub"    & pids+=($!)
    download_with_retry "$REPO_BASE/sldns-server"  "$TEMP_DIR/sldns-server"  & pids+=($!)

    local ok=true
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            ok=false
        fi
    done

    if [ ! -s "$TEMP_DIR/server.key" ]; then
        print_error "Failed to download server.key"; ok=false
    else
        print_success "server.key downloaded"
    fi
    if [ ! -s "$TEMP_DIR/server.pub" ]; then
        print_error "Failed to download server.pub"; ok=false
    else
        print_success "server.pub downloaded"
    fi
    if [ ! -s "$TEMP_DIR/sldns-server" ]; then
        print_error "Failed to download sldns-server"; ok=false
    else
        print_success "sldns-server downloaded"
    fi

    if [ "$ok" != true ]; then
        print_error "One or more downloads failed. Aborting before touching /etc/slowdns."
        exit 1
    fi

    mkdir -p /etc/slowdns
    cp "$TEMP_DIR/server.key"   /etc/slowdns/server.key
    cp "$TEMP_DIR/server.pub"   /etc/slowdns/server.pub
    cp "$TEMP_DIR/sldns-server" /etc/slowdns/sldns-server
    chmod 600 /etc/slowdns/server.key
    chmod 644 /etc/slowdns/server.pub
    chmod +x  /etc/slowdns/sldns-server
    print_success "SlowDNS files installed"
}

# ---------------------------------------------------------------------------
# SSH configuration (idempotent)
# ---------------------------------------------------------------------------
configure_ssh() {
    print_warning "Configuring SSH ports..."

    local sshd_config="/etc/ssh/sshd_config"
    cp "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d_%H%M%S)"

    grep -qE "^Port ${SSHD_PORT}$"     "$sshd_config" || echo "Port ${SSHD_PORT}"     >> "$sshd_config"
    grep -qE "^Port ${SSHD_ALT_PORT}$" "$sshd_config" || echo "Port ${SSHD_ALT_PORT}" >> "$sshd_config"

    if grep -q "^#AllowTcpForwarding yes" "$sshd_config"; then
        sed -i 's/^#AllowTcpForwarding yes/AllowTcpForwarding yes/' "$sshd_config"
    elif ! grep -q "^AllowTcpForwarding yes" "$sshd_config"; then
        echo "AllowTcpForwarding yes" >> "$sshd_config"
    fi

    # Validate config BEFORE restarting — avoids locking yourself out on a typo
    if sshd -t 2>/tmp/sshd_test_err; then
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null
        print_success "SSH configured on ports ${SSHD_PORT} and ${SSHD_ALT_PORT} with TCP forwarding enabled"
    else
        print_error "sshd config test failed, reverting to backup:"
        cat /tmp/sshd_test_err
        cp "${sshd_config}.bak."* "$sshd_config" 2>/dev/null
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# systemd service for SlowDNS
# ---------------------------------------------------------------------------
create_slowdns_service() {
    print_warning "Creating SlowDNS service..."
    cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :${SLOWDNS_PORT} -mtu 1800 -privkey-file /etc/slowdns/server.key ${NAMESERVER} 127.0.0.1:${SSHD_ALT_PORT}
Restart=always
RestartSec=5
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

[Install]
WantedBy=multi-user.target
EOF
    print_success "SlowDNS service file created"
}

# ---------------------------------------------------------------------------
# fail2ban
# ---------------------------------------------------------------------------
install_fail2ban() {
    print_warning "Installing and configuring Fail2ban..."

    if command -v fail2ban-client &>/dev/null; then
        print_success "fail2ban already installed, skipping install"
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y fail2ban -qq
    elif command -v dnf &>/dev/null; then
        dnf install -y fail2ban -q
    elif command -v yum &>/dev/null; then
        yum install -y fail2ban -q
    else
        print_error "Package manager not supported. Please install fail2ban manually."
        return 1
    fi

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ssh,${SSHD_PORT},${SSHD_ALT_PORT}
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 3600
findtime = 600

[sshd-ddos]
enabled = true
port = ssh,${SSHD_PORT},${SSHD_ALT_PORT}
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime = 7200
findtime = 600

[slowdns]
enabled = true
port = ${SLOWDNS_PORT}
protocol = udp
filter = slowdns
logpath = /var/log/slowdns.log
maxretry = 10
bantime = 3600
findtime = 600
EOF

    cat > /etc/fail2ban/filter.d/slowdns.conf << 'EOF'
[Definition]
failregex = ^.*Failed authentication from <HOST>.*$
            ^.*Invalid request from <HOST>.*$
            ^.*Connection attempt from <HOST>.*$
ignoreregex =
EOF

    touch /var/log/slowdns.log
    chmod 644 /var/log/slowdns.log

    systemctl restart fail2ban 2>/dev/null
    systemctl enable fail2ban 2>/dev/null

    if systemctl is-active --quiet fail2ban; then
        print_success "Fail2ban installed and configured successfully"
        fail2ban-client status
    else
        print_error "Fail2ban failed to start. Please check configuration."
    fi

    print_warning "Configuring iptables persistence for fail2ban..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y iptables-persistent -qq
        netfilter-persistent save >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y iptables-services -q
        service iptables save >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# Startup / sysctl / DNS
# ---------------------------------------------------------------------------
configure_startup() {
    print_warning "Setting up iptables and startup configuration..."
    cat > /etc/rc.local << 'EOF'
#!/bin/bash
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

if command -v iptables-restore &> /dev/null; then
    iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true
fi

rm -rf /tmp/* 2>/dev/null
rm -rf /var/tmp/* 2>/dev/null

exit 0
EOF
    chmod +x /etc/rc.local
    systemctl enable rc-local >/dev/null 2>&1
    systemctl start rc-local.service >/dev/null 2>&1
    print_success "Startup configuration set"
}

disable_ipv6() {
    print_warning "Disabling IPv6..."
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1

    grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || \
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    grep -q "^net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || \
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1
    print_success "IPv6 disabled"
}

configure_dns() {
    print_warning "Configuring DNS settings..."
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    pkill -9 systemd-resolved 2>/dev/null

    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    { echo "nameserver 8.8.8.8"; echo "nameserver 1.1.1.1"; } > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    print_success "DNS configured with Google and Cloudflare DNS servers"
}

# ---------------------------------------------------------------------------
# Service start + verification (poll instead of fixed sleeps where possible)
# ---------------------------------------------------------------------------
wait_for_condition() {
    # wait_for_condition <max_seconds> <command...>
    local max_seconds="$1"; shift
    local waited=0
    while [ "$waited" -lt "$max_seconds" ]; do
        if "$@"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

start_slowdns() {
    print_warning "Starting SlowDNS service..."
    pkill sldns-server 2>/dev/null
    systemctl daemon-reload
    systemctl enable server-sldns >/dev/null 2>&1
    systemctl start server-sldns

    if wait_for_condition 10 systemctl is-active --quiet server-sldns; then
        print_success "SlowDNS service started"
    else
        print_error "SlowDNS service failed to start"
        return 1
    fi

    if wait_for_condition 5 bash -c "timeout 2 bash -c 'echo > /dev/udp/127.0.0.1/${SLOWDNS_PORT}'" 2>/dev/null; then
        print_success "SlowDNS is listening on port ${SLOWDNS_PORT}"
    else
        print_warning "SlowDNS not confirmed on UDP port ${SLOWDNS_PORT} via systemd unit, trying direct start..."
        pkill sldns-server 2>/dev/null
        /etc/slowdns/sldns-server -udp :"${SLOWDNS_PORT}" -mtu 1800 -privkey-file /etc/slowdns/server.key "${NAMESERVER}" 127.0.0.1:"${SSHD_ALT_PORT}" &
        if wait_for_condition 5 pgrep -x sldns-server >/dev/null; then
            print_success "SlowDNS started directly"
        else
            print_error "Failed to start SlowDNS"
        fi
    fi
}

verify_ssh_alt_port() {
    print_warning "Testing SSH connection on alt port..."
    if wait_for_condition 5 bash -c "timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/${SSHD_ALT_PORT}'" 2>/dev/null; then
        print_success "SSH port ${SSHD_ALT_PORT} is accessible"
    else
        print_error "SSH port ${SSHD_ALT_PORT} is not accessible"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_root

echo "=================================================================="
echo "                 OpenSSH SlowDNS Installation"
echo "=================================================================="

SERVER_IP=$(curl -s --max-time 5 ifconfig.me || true)
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
read -rp "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

configure_ssh
download_slowdns_files
create_slowdns_service
install_fail2ban
configure_startup
disable_ipv6
configure_dns

auto_delete_old_logs
auto_delete_install_files
setup_auto_delete_cron

start_slowdns
verify_ssh_alt_port

echo ""
echo "=================================================================="
print_success "           Fail2ban Protection Summary"
echo "=================================================================="
fail2ban-client status
echo ""
echo "=================================================================="
print_success "           OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="
echo ""
echo "Server IP: ${SERVER_IP}"
echo ""

# ---------------------------------------------------------------------------
# Optional extra module (manual review strongly recommended before running
# any third-party script fetched with a personal access token)
# ---------------------------------------------------------------------------
read -rp "Run additional update script? Requires GitHub token [y/N]: " run_extra
if [[ "$run_extra" =~ ^[Yy]$ ]]; then
    read -rp "Enter GitHub token: " token
    UPDATE_SCRIPT="$TEMP_DIR/update4.sh"
    if download_with_retry "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/update10.sh" "$UPDATE_SCRIPT"; then
        echo "Downloaded to $UPDATE_SCRIPT — review it before running:"
        echo "  cat $UPDATE_SCRIPT"
        read -rp "Proceed with execution? [y/N]: " confirm_run
        if [[ "$confirm_run" =~ ^[Yy]$ ]]; then
            bash "$UPDATE_SCRIPT"
        else
            print_warning "Skipped running update script."
        fi
    else
        print_error "Failed to download update script"
    fi
fi

echo ""
print_success "Auto-delete system configured successfully!"
echo " - Old logs are deleted after 7 days"
echo " - Temporary files are cleaned daily at 2 AM"
echo " - Log rotation is enabled for slowdns logs"
echo " - Weekly complete cleanup scheduled"
echo ""
