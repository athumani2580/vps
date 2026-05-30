#!/bin/bash
# Universal SlowDNS Installer - Optimized for 3G/4G/LTE Networks
# Version: 3.0 - Universal Network Support

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Network-adaptive configurations
SSHD_PORT=22
SLOWDNS_PORT=5300
NETWORK_TYPE="unknown"
NETWORK_QUALITY="unknown"
OPTIMIZED_MTU=1500
OPTIMIZED_TIMEOUT=5
OPTIMIZED_BUFFER=16384
RETRY_COUNT=3

# Temporary directory
TEMP_DIR=$(mktemp -d)
TEMP_FILES=()
trap 'rm -rf "$TEMP_DIR"' EXIT

# Enhanced print functions
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_step() { echo -e "${CYAN}[→]${NC} $1"; }
print_network() { echo -e "${MAGENTA}[📡]${NC} $1"; }

# Register temp files
register_temp_file() { TEMP_FILES+=("$1"); }
cleanup_registered_files() {
    for file in "${TEMP_FILES[@]}"; do
        [ -f "$file" ] && rm -f "$file"
    done
}
trap cleanup_registered_files INT TERM

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

# Advanced network detection
detect_network_optimizations() {
    print_step "Analyzing network environment..."
    
    # Check network interface types
    local interfaces=$(ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}')
    
    # Detect mobile broadband interfaces
    if echo "$interfaces" | grep -qE "wwan|rmnet|usb0|cdc-wdm|qmi|mbim"; then
        NETWORK_TYPE="4G/LTE"
        NETWORK_QUALITY="cellular"
        OPTIMIZED_MTU=1400
        OPTIMIZED_TIMEOUT=3
        OPTIMIZED_BUFFER=8192
        RETRY_COUNT=4
        print_network "4G/LTE modem detected - Applying cellular optimizations"
    
    # Detect WiFi
    elif iwconfig 2>/dev/null | grep -q "ESSID"; then
        NETWORK_TYPE="WiFi"
        # Check signal strength
        local signal=$(iwconfig 2>/dev/null | grep -o "Signal level=[0-9-]*" | head -1 | cut -d= -f2)
        if [[ -n "$signal" ]] && [[ ${signal#-} -lt 70 ]]; then
            NETWORK_QUALITY="excellent"
            OPTIMIZED_MTU=1500
            OPTIMIZED_TIMEOUT=5
            print_network "Strong WiFi signal detected"
        else
            NETWORK_QUALITY="weak"
            OPTIMIZED_MTU=1450
            OPTIMIZED_TIMEOUT=4
            print_network "Weak WiFi signal - Applying optimizations"
        fi
    
    # Detect Ethernet/Fiber
    elif echo "$interfaces" | grep -qE "eth|enp|ens"; then
        NETWORK_TYPE="Wired"
        NETWORK_QUALITY="stable"
        OPTIMIZED_MTU=1500
        OPTIMIZED_TIMEOUT=5
        print_network "Wired connection detected"
    
    # Detect via latency
    else
        print_step "Testing network latency..."
        local latencies=()
        for i in {1..3}; do
            local latency=$(ping -c 1 -W 2 8.8.8.8 2>/dev/null | grep 'time=' | cut -d= -f4 | cut -d' ' -f1 | cut -d'.' -f1)
            [[ -n "$latency" ]] && latencies+=($latency)
        done
        
        local avg_latency=0
        for lat in "${latencies[@]}"; do
            avg_latency=$((avg_latency + lat))
        done
        [ ${#latencies[@]} -gt 0 ] && avg_latency=$((avg_latency / ${#latencies[@]}))
        
        if [ $avg_latency -gt 0 ]; then
            if [ $avg_latency -lt 50 ]; then
                NETWORK_TYPE="Low Latency"
                NETWORK_QUALITY="excellent"
                print_network "Low latency network (${avg_latency}ms)"
            elif [ $avg_latency -lt 150 ]; then
                NETWORK_TYPE="Medium Latency"
                NETWORK_QUALITY="good"
                OPTIMIZED_MTU=1450
                OPTIMIZED_TIMEOUT=4
                print_network "Medium latency network (${avg_latency}ms)"
            else
                NETWORK_TYPE="High Latency (3G/4G)"
                NETWORK_QUALITY="cellular"
                OPTIMIZED_MTU=1400
                OPTIMIZED_TIMEOUT=3
                OPTIMIZED_BUFFER=8192
                RETRY_COUNT=4
                print_network "High latency detected - 3G/4G optimizations enabled (${avg_latency}ms)"
            fi
        fi
    fi
    
    # Bandwidth test (lightweight)
    print_step "Testing bandwidth..."
    local start_time=$(date +%s.%N)
    timeout 3 curl -s -o /dev/null http://speedtest.tele2.net/1MB.zip 2>/dev/null || true
    local end_time=$(date +%s.%N)
    local download_time=$(echo "$end_time - $start_time" | bc 2>/dev/null | cut -d'.' -f1)
    
    if [[ -n "$download_time" ]] && [ "$download_time" -gt 0 ]; then
        local speed=$(echo "scale=0; 1 / $download_time * 8" | bc 2>/dev/null)
        if [[ -n "$speed" ]] && [ "$speed" -lt 2 ]; then
            print_network "Low bandwidth detected (<2 Mbps) - Ultra optimizations enabled"
            OPTIMIZED_MTU=1350
            OPTIMIZED_TIMEOUT=2
            OPTIMIZED_BUFFER=4096
        fi
    fi
    
    print_success "Network profile: $NETWORK_TYPE | MTU: $OPTIMIZED_MTU | Timeout: ${OPTIMIZED_TIMEOUT}s"
}

# Apply network optimizations
apply_network_optimizations() {
    print_step "Applying network optimizations..."
    
    # Backup existing sysctl
    cp /etc/sysctl.conf /etc/sysctl.conf.backup 2>/dev/null || true
    
    # Apply network-specific optimizations
    cat >> /etc/sysctl.conf << EOF

# Network-adaptive optimizations (Auto-detected: $NETWORK_TYPE)
net.core.rmem_default = $OPTIMIZED_BUFFER
net.core.wmem_default = $OPTIMIZED_BUFFER
net.core.rmem_max = $((OPTIMIZED_BUFFER * 2))
net.core.wmem_max = $((OPTIMIZED_BUFFER * 2))
net.ipv4.tcp_rmem = 4096 $OPTIMIZED_BUFFER $((OPTIMIZED_BUFFER * 2))
net.ipv4.tcp_wmem = 4096 $OPTIMIZED_BUFFER $((OPTIMIZED_BUFFER * 2))
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.core.netdev_max_backlog = 1000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fin_timeout = 15

# Congestion control for cellular networks
net.ipv4.tcp_congestion_control = cubic
net.core.default_qdisc = fq
EOF

    # Special optimizations for cellular networks
    if [[ "$NETWORK_QUALITY" == "cellular" ]]; then
        cat >> /etc/sysctl.conf << EOF

# Cellular network specific optimizations
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_sack = 0
net.ipv4.tcp_dsack = 0
EOF
    fi
    
    sysctl -p >/dev/null 2>&1
    print_success "Network optimizations applied"
}

# Enhanced download with retry and resume
download_with_retry() {
    local url="$1"
    local output="$2"
    local retries=$RETRY_COUNT
    local retry_delay=2
    
    for i in $(seq 1 $retries); do
        if wget -q --timeout=$OPTIMIZED_TIMEOUT --tries=1 --dns-timeout=2 \
            --connect-timeout=3 --read-timeout=5 -O "$output" "$url" 2>/dev/null; then
            return 0
        fi
        if [ $i -lt $retries ]; then
            print_warning "Download failed, retrying ($i/$retries)..."
            sleep $retry_delay
        fi
    done
    return 1
}

# Auto-cleanup functions (optimized for network type)
auto_delete_old_logs() {
    local days_to_keep=7
    [[ "$NETWORK_QUALITY" == "cellular" ]] && days_to_keep=3  # Keep less on cellular
    
    print_step "Cleaning logs older than $days_to_keep days..."
    
    find /var/log -name "fail2ban.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    find /var/log -name "slowdns.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    find /var/log -name "auth.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    
    # Smart log rotation
    if [ -f "/var/log/slowdns.log" ]; then
        local max_size=10485760
        [[ "$NETWORK_QUALITY" == "cellular" ]] && max_size=5242880  # 5MB on cellular
        
        local log_size=$(stat -c%s "/var/log/slowdns.log" 2>/dev/null || stat -f%z "/var/log/slowdns.log" 2>/dev/null)
        if [ "$log_size" -gt $max_size ]; then
            mv /var/log/slowdns.log "/var/log/slowdns.log.$(date +%Y%m%d_%H%M%S)"
            touch /var/log/slowdns.log
            find /var/log -name "slowdns.log.*" -type f -mtime +1 -exec gzip {} \; 2>/dev/null
            find /var/log -name "slowdns.log.*.gz" -type f -mtime +$days_to_keep -delete 2>/dev/null
        fi
    fi
    
    print_success "Log cleanup completed"
}

# Network-adaptive service creation
create_adaptive_service() {
    print_step "Creating network-adaptive SlowDNS service..."
    
    local restart_sec=5
    local watchdog_sec=30
    
    # Adaptive restart settings
    if [[ "$NETWORK_QUALITY" == "cellular" ]]; then
        restart_sec=3
        watchdog_sec=15
    elif [[ "$NETWORK_QUALITY" == "weak" ]]; then
        restart_sec=4
        watchdog_sec=20
    fi
    
    cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=SlowDNS Server (Optimized for $NETWORK_TYPE)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu $OPTIMIZED_MTU -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=$restart_sec
WatchdogSec=$watchdog_sec
StartLimitInterval=0
StartLimitBurst=5

# Logging with network awareness
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

[Install]
WantedBy=multi-user.target
EOF
}

# Connection monitor for unstable networks
setup_connection_monitor() {
    if [[ "$NETWORK_QUALITY" == "cellular" ]] || [[ "$NETWORK_QUALITY" == "weak" ]]; then
        print_step "Setting up connection monitor for unstable network..."
        
        cat > /etc/systemd/system/network-watchdog.service << 'EOF'
[Unit]
Description=Network Connection Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/network-watchdog.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

        cat > /usr/local/bin/network-watchdog.sh << 'EOF'
#!/bin/bash
# Universal network watchdog

CHECK_INTERVAL=20
FAILED=0
MAX_FAILED=3
SERVICES="server-sldns customer-service"

check_connection() {
    # Multiple test points for reliability
    curl -s -m 3 http://8.8.8.8 >/dev/null 2>&1 && return 0
    ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && return 0
    nslookup google.com 8.8.8.8 >/dev/null 2>&1 && return 0
    return 1
}

while true; do
    if check_connection; then
        FAILED=0
    else
        FAILED=$((FAILED + 1))
        if [ $FAILED -ge $MAX_FAILED ]; then
            for service in $SERVICES; do
                systemctl restart $service 2>/dev/null
            done
            sleep 10
            FAILED=0
        fi
    fi
    sleep $CHECK_INTERVAL
done
EOF
        
        chmod +x /usr/local/bin/network-watchdog.sh
        systemctl daemon-reload
        systemctl enable network-watchdog
        systemctl start network-watchdog
        print_success "Connection monitor installed"
    fi
}

# Mobile-optimized customer service
create_universal_customer_service() {
    print_step "Creating universal customer service..."
    
    mkdir -p /opt/customer-service
    
    cat > /opt/customer-service/customer_service.py << PYTHON_EOF
#!/usr/bin/env python3
"""
Universal DNS Service - Auto-adapts to network conditions
"""

import socket
import threading
import time
import logging
import signal
import sys
from typing import Tuple, Optional

# Auto-configured settings
PUBLIC_PORT = 53
UPSTREAM_PORT = 5300
BUFFER_SIZE = $OPTIMIZED_BUFFER
REQUEST_TIMEOUT = $OPTIMIZED_TIMEOUT
MAX_WORKERS = 50

class UniversalDNSService:
    def __init__(self):
        self.host = "0.0.0.0"
        self.port = PUBLIC_PORT
        self.upstream_host = "127.0.0.1"
        self.upstream_port = UPSTREAM_PORT
        
        self.stats = {'requests': 0, 'responses': 0, 'errors': 0, 'timeouts': 0}
        self.running = True
        
        logging.basicConfig(level=logging.INFO, format='%(asctime)s - DNS - %(levelname)s - %(message)s')
        self.logger = logging.getLogger('DNS')
        
        signal.signal(signal.SIGINT, lambda s,f: setattr(self, 'running', False))
        signal.signal(signal.SIGTERM, lambda s,f: setattr(self, 'running', False))
    
    def forward(self, data: bytes, addr: Tuple[str, int]) -> Optional[bytes]:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(REQUEST_TIMEOUT)
            sock.sendto(data, (self.upstream_host, self.upstream_port))
            response, _ = sock.recvfrom(BUFFER_SIZE)
            sock.close()
            return response
        except socket.timeout:
            self.stats['timeouts'] += 1
        except Exception as e:
            self.stats['errors'] += 1
        return None
    
    def handle(self, data: bytes, addr: Tuple[str, int]):
        self.stats['requests'] += 1
        response = self.forward(data, addr)
        if response:
            try:
                self.socket.sendto(response, addr)
                self.stats['responses'] += 1
            except:
                self.stats['errors'] += 1
    
    def run(self):
        self.logger.info(f"Starting DNS Service (Buffer: {BUFFER_SIZE}, Timeout: {REQUEST_TIMEOUT}s)")
        
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((self.host, self.port))
        
        while self.running:
            try:
                self.socket.settimeout(1.0)
                data, addr = self.socket.recvfrom(BUFFER_SIZE)
                threading.Thread(target=self.handle, args=(data, addr), daemon=True).start()
            except socket.timeout:
                continue
            except:
                continue
        
        self.logger.info(f"Final stats: {self.stats}")
        self.socket.close()

if __name__ == "__main__":
    UniversalDNSService().run()
PYTHON_EOF
    
    chmod +x /opt/customer-service/customer_service.py
    
    cat > /etc/systemd/system/customer-service.service << 'EOF'
[Unit]
Description=Universal DNS Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/customer-service/customer_service.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "Universal customer service created"
}

# Main installation
main() {
    echo "=================================================================="
    echo "     🌐 Universal SlowDNS Installer v3.0"
    echo "     Optimized for 3G | 4G | LTE | WiFi | Wired"
    echo "=================================================================="
    echo ""
    
    check_root
    detect_network_optimizations
    apply_network_optimizations
    
    # Get server IP
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    print_info "Server IP: $SERVER_IP"
    
    # Configure SSH
    print_step "Configuring SSH..."
    grep -q "^Port 22" /etc/ssh/sshd_config || echo "Port 22" >> /etc/ssh/sshd_config
    grep -q "^Port 69" /etc/ssh/sshd_config || echo "Port 69" >> /etc/ssh/sshd_config
    sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null
    print_success "SSH configured (ports 22, 69)"
    
    # Setup SlowDNS
    print_step "Setting up SlowDNS..."
    rm -rf /etc/slowdns
    mkdir -p /etc/slowdns
    
    # Download with network awareness
    print_step "Downloading components..."
    download_with_retry "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" "$TEMP_DIR/server.key" && \
        cp "$TEMP_DIR/server.key" /etc/slowdns/server.key && print_success "server.key downloaded"
    
    download_with_retry "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" "$TEMP_DIR/server.pub" && \
        cp "$TEMP_DIR/server.pub" /etc/slowdns/server.pub && print_success "server.pub downloaded"
    
    download_with_retry "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server" "$TEMP_DIR/sldns-server" && \
        cp "$TEMP_DIR/sldns-server" /etc/slowdns/sldns-server && chmod +x /etc/slowdns/sldns-server && print_success "sldns-server downloaded"
    
    # Get nameserver
    echo ""
    read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
    
    # Create services
    create_adaptive_service
    create_universal_customer_service
    
    # Install fail2ban
    print_step "Installing fail2ban..."
    command -v apt-get &>/dev/null && apt-get update -qq && apt-get install -y fail2ban -qq
    command -v yum &>/dev/null && yum install -y fail2ban -q
    
    # Configure fail2ban
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ssh,22,69
maxretry = 3
bantime = 3600
EOF
    
    systemctl restart fail2ban 2>/dev/null
    systemctl enable fail2ban 2>/dev/null
    
    # Setup monitoring for unstable networks
    setup_connection_monitor
    
    # Start services
    print_step "Starting services..."
    systemctl daemon-reload
    systemctl enable server-sldns customer-service
    systemctl start server-sldns customer-service
    
    # Final cleanup
    auto_delete_old_logs
    
    # Summary
    echo ""
    echo "=================================================================="
    print_success "Installation Complete!"
    echo "=================================================================="
    echo ""
    echo "📡 Network Profile: $NETWORK_TYPE"
    echo "🔧 Optimizations: MTU=$OPTIMIZED_MTU | Timeout=${OPTIMIZED_TIMEOUT}s | Buffer=$OPTIMIZED_BUFFER"
    echo ""
    echo "✅ Services Running:"
    echo "   • SlowDNS: Port $SLOWDNS_PORT (UDP) - $NETWORK_TYPE optimized"
    echo "   • DNS Service: Port 53 (UDP)"
    echo "   • SSH: Ports 22, 69"
    [[ "$NETWORK_QUALITY" == "cellular" ]] && echo "   • Network Watchdog: Active for unstable connections"
    echo ""
    echo "🛠️  Commands:"
    echo "   systemctl status server-sldns"
    echo "   systemctl status customer-service"
    [[ "$NETWORK_QUALITY" == "cellular" ]] && echo "   systemctl status network-watchdog"
    echo ""
    echo "📝 Logs: tail -f /var/log/slowdns.log"
    echo "=================================================================="
    
    # Optional token input
    echo ""
    read -p "Enter GitHub token (optional, press Enter to skip): " token
    if [[ -n "$token" ]]; then
        print_step "Downloading extras..."
        curl -s -H "Authorization: token $token" \
            "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/update4.sh" | bash 2>/dev/null || true
    fi
}

# Run
main "$@"
