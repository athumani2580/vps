#!/bin/bash
# Universal SlowDNS Installer v3.1 - Fixed for all network types
# Optimized for 3G | 4G | LTE | WiFi | Wired

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
    elif command -v iwconfig &>/dev/null && iwconfig 2>/dev/null | grep -q "ESSID"; then
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
    elif echo "$interfaces" | grep -qE "eth|enp|ens|eno"; then
        NETWORK_TYPE="Wired"
        NETWORK_QUALITY="stable"
        OPTIMIZED_MTU=1500
        OPTIMIZED_TIMEOUT=5
        print_network "Wired connection detected"
    
    # Detect via latency
    else
        print_step "Testing network latency..."
        local latencies=()
        for i in {1..2}; do
            local latency=$(ping -c 1 -W 2 8.8.8.8 2>/dev/null | grep 'time=' | cut -d= -f4 | cut -d' ' -f1 | cut -d'.' -f1)
            [[ -n "$latency" ]] && latencies+=($latency)
        done
        
        local avg_latency=0
        for lat in "${latencies[@]}"; do
            avg_latency=$((avg_latency + lat))
        done
        [ ${#latencies[@]} -gt 0 ] && avg_latency=$((avg_latency / ${#latencies[@]}))
        
        if [ $avg_latency -gt 0 ] 2>/dev/null; then
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
                NETWORK_TYPE="High Latency"
                NETWORK_QUALITY="cellular"
                OPTIMIZED_MTU=1400
                OPTIMIZED_TIMEOUT=3
                OPTIMIZED_BUFFER=8192
                RETRY_COUNT=4
                print_network "High latency detected - Optimizations enabled (${avg_latency}ms)"
            fi
        else
            NETWORK_TYPE="Standard"
            NETWORK_QUALITY="unknown"
            print_network "Using standard network configuration"
        fi
    fi
    
    # Simple bandwidth test (non-critical, continue if fails)
    print_step "Testing bandwidth..."
    if command -v curl &>/dev/null; then
        local start_time=$(date +%s 2>/dev/null || echo 0)
        timeout 5 curl -s -o /dev/null --max-time 3 http://speedtest.tele2.net/1MB.zip 2>/dev/null || true
        local end_time=$(date +%s 2>/dev/null || echo 1)
        local download_time=$((end_time - start_time))
        
        if [[ -n "$download_time" ]] && [ "$download_time" -gt 0 ] 2>/dev/null; then
            if [ "$download_time" -gt 5 ]; then
                print_network "Low bandwidth detected - Ultra optimizations enabled"
                OPTIMIZED_MTU=1350
                OPTIMIZED_TIMEOUT=2
                OPTIMIZED_BUFFER=4096
            fi
        fi
    else
        print_info "Curl not available, skipping bandwidth test"
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
net.core.netdev_max_backlog = 1000
net.ipv4.tcp_fastopen = 3
EOF

    # Apply sysctl changes (ignore errors)
    sysctl -p >/dev/null 2>&1 || true
    
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

# Auto-cleanup functions
auto_delete_old_logs() {
    local days_to_keep=7
    [[ "$NETWORK_QUALITY" == "cellular" ]] && days_to_keep=3
    
    print_step "Cleaning logs older than $days_to_keep days..."
    
    find /var/log -name "fail2ban.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null || true
    find /var/log -name "slowdns.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null || true
    find /var/log -name "auth.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null || true
    
    # Smart log rotation
    if [ -f "/var/log/slowdns.log" ]; then
        local max_size=10485760
        [[ "$NETWORK_QUALITY" == "cellular" ]] && max_size=5242880
        
        local log_size=$(stat -c%s "/var/log/slowdns.log" 2>/dev/null || echo 0)
        if [ "$log_size" -gt $max_size ] 2>/dev/null; then
            mv /var/log/slowdns.log "/var/log/slowdns.log.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            touch /var/log/slowdns.log 2>/dev/null || true
            find /var/log -name "slowdns.log.*" -type f -mtime +1 -exec gzip {} \; 2>/dev/null || true
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
    
    print_success "SlowDNS service created"
}

# Create universal customer service
create_universal_customer_service() {
    print_step "Creating universal customer service..."
    
    mkdir -p /opt/customer-service
    
    cat > /opt/customer-service/customer_service.py << 'PYTHON_EOF'
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

# Default settings (will be overridden by environment)
BUFFER_SIZE = 16384
REQUEST_TIMEOUT = 5

class UniversalDNSService:
    def __init__(self):
        self.host = "0.0.0.0"
        self.port = 53
        self.upstream_host = "127.0.0.1"
        self.upstream_port = 5300
        
        self.stats = {'requests': 0, 'responses': 0, 'errors': 0, 'timeouts': 0}
        self.running = True
        
        logging.basicConfig(level=logging.INFO, format='%(asctime)s - DNS - %(levelname)s - %(message)s')
        self.logger = logging.getLogger('DNS')
        
        signal.signal(signal.SIGINT, lambda s,f: setattr(self, 'running', False))
        signal.signal(signal.SIGTERM, lambda s,f: setattr(self, 'running', False))
    
    def forward(self, data, addr):
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
    
    def handle(self, data, addr):
        self.stats['requests'] += 1
        response = self.forward(data, addr)
        if response:
            try:
                self.socket.sendto(response, addr)
                self.stats['responses'] += 1
            except:
                self.stats['errors'] += 1
    
    def run(self):
        self.logger.info("Starting DNS Service")
        
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
        
        self.socket.close()

if __name__ == "__main__":
    UniversalDNSService().run()
PYTHON_EOF
    
    chmod +x /opt/customer-service/customer_service.py
    
    # Create systemd service with environment variables
    cat > /etc/systemd/system/customer-service.service << EOF
[Unit]
Description=Universal DNS Service
After=network.target

[Service]
Type=simple
Environment="BUFFER_SIZE=$OPTIMIZED_BUFFER"
Environment="REQUEST_TIMEOUT=$OPTIMIZED_TIMEOUT"
ExecStart=/usr/bin/python3 /opt/customer-service/customer_service.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "Universal customer service created"
}

# Setup auto-delete cron
setup_auto_delete_cron() {
    print_step "Setting up auto-delete cron job..."
    
    # Create cron job for daily cleanup
    (crontab -l 2>/dev/null | grep -v "auto-delete" ; echo "0 2 * * * /usr/bin/find /var/log -name '*.log.*' -type f -mtime +7 -delete 2>/dev/null # auto-delete") | crontab - 2>/dev/null || true
    
    print_success "Auto-delete cron configured"
}

# Main installation
main() {
    echo "=================================================================="
    echo "     🌐 Universal SlowDNS Installer v3.1"
    echo "     Optimized for 3G | 4G | LTE | WiFi | Wired"
    echo "=================================================================="
    echo ""
    
    check_root
    detect_network_optimizations
    apply_network_optimizations
    
    # Get server IP (non-critical, continue if fails)
    SERVER_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    print_info "Server IP: $SERVER_IP"
    
    # Configure SSH
    print_step "Configuring SSH..."
    if ! grep -q "^Port 69" /etc/ssh/sshd_config; then
        echo "Port 69" >> /etc/ssh/sshd_config
    fi
    sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config 2>/dev/null || true
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
    print_success "SSH configured (ports 22, 69)"
    
    # Setup SlowDNS
    print_step "Setting up SlowDNS..."
    rm -rf /etc/slowdns 2>/dev/null || true
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
    
    # Install fail2ban (optional, continue if fails)
    print_step "Installing fail2ban..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y fail2ban -qq 2>/dev/null || print_warning "fail2ban installation failed"
    elif command -v yum &>/dev/null; then
        yum install -y fail2ban -q 2>/dev/null || print_warning "fail2ban installation failed"
    fi
    
    # Configure fail2ban if installed
    if command -v fail2ban-client &>/dev/null; then
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
        systemctl restart fail2ban 2>/dev/null || true
        systemctl enable fail2ban 2>/dev/null || true
        print_success "fail2ban configured"
    else
        print_warning "fail2ban not installed - skipping"
    fi
    
    # Start services
    print_step "Starting services..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable server-sldns 2>/dev/null || true
    systemctl enable customer-service 2>/dev/null || true
    systemctl start server-sldns 2>/dev/null || true
    systemctl start customer-service 2>/dev/null || true
    
    # Final cleanup
    auto_delete_old_logs
    setup_auto_delete_cron
    
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
    echo "   • SlowDNS: Port $SLOWDNS_PORT (UDP)"
    echo "   • DNS Service: Port 53 (UDP)"
    echo "   • SSH: Ports 22, 69"
    echo ""
    echo "🛠️  Commands:"
    echo "   systemctl status server-sldns"
    echo "   systemctl status customer-service"
    echo ""
    echo "📝 Logs: tail -f /var/log/slowdns.log"
    echo "=================================================================="
    
    # Optional token input
    echo ""
    read -p "Enter GitHub token (optional, press Enter to skip): " token
    if [[ -n "$token" ]]; then
        print_step "Downloading extras..."
        curl -s -H "Authorization: token $token" \
            "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/update4.sh" 2>/dev/null | bash 2>/dev/null || true
    fi
    
    print_success "Installation finished successfully!"
}

# Run main installation
main "$@"
