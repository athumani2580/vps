#!/bin/bash
# VPS Auto-Ping Installation Script

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_header() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  VPS Auto-Ping Keepalive Installer${NC}"
    echo -e "${GREEN}========================================${NC}\n"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

install_dependencies() {
    print_status "Installing dependencies..."
    
    if command -v apt > /dev/null; then
        apt update
        apt install -y curl dnsutils iputils-ping net-tools
    elif command -v yum > /dev/null; then
        yum install -y curl bind-utils iputils net-tools
    elif command -v dnf > /dev/null; then
        dnf install -y curl bind-utils iputils net-tools
    elif command -v apk > /dev/null; then
        apk add curl bind-tools iputils net-tools
    else
        print_warning "Could not detect package manager. Please install manually:"
        print_warning "curl, dig/nslookup, ping, netstat/ss"
    fi
}

install_script() {
    print_status "Installing VPS Auto-Ping..."
    
    # Create main script
    cp vps-auto-ping.sh /usr/local/bin/vps-auto-ping.sh
    chmod +x /usr/local/bin/vps-auto-ping.sh
    
    # Create configuration file if doesn't exist
    if [[ ! -f /etc/vps-auto-ping.conf ]]; then
        cat > /etc/vps-auto-ping.conf << 'EOF'
# VPS Auto-Ping Configuration
ENABLED="true"
MODE="aggressive"
PING_INTERVAL="60"
HTTP_INTERVAL="120"
LOG_LEVEL="info"
TARGETS="8.8.8.8,1.1.1.1,google.com,cloudflare.com"
MAX_FAILURES="5"
NOTIFY_EMAIL=""
EOF
    fi
    
    # Create log directory
    mkdir -p /var/log/vps-auto-ping
}

create_systemd_service() {
    print_status "Creating systemd service..."
    
    cat > /etc/systemd/system/vps-auto-ping.service << 'EOF'
[Unit]
Description=VPS Auto-Ping Keepalive Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/vps-auto-ping.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/log/vps-auto-ping /tmp

[Install]
WantedBy=multi-user.target
EOF
}

create_monitoring_script() {
    print_status "Creating monitoring script..."
    
    cat > /usr/local/bin/vps-auto-ping-monitor.sh << 'EOF'
#!/bin/bash
# VPS Auto-Ping Monitor Script

STATUS_FILE="/tmp/vps-auto-ping.status"
LOG_FILE="/var/log/vps-auto-ping/vps-auto-ping.log"
PID_FILE="/var/run/vps-auto-ping.pid"

echo "=== VPS Auto-Ping Status ==="
echo ""

# Check if service is running
if systemctl is-active --quiet vps-auto-ping.service; then
    echo "Service Status: ${GREEN}RUNNING${NC}"
else
    echo "Service Status: ${RED}STOPPED${NC}"
fi

# Check PID file
if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Process PID: $PID (${GREEN}Active${NC})"
    else
        echo "Process PID: $PID (${RED}Dead${NC})"
    fi
fi

# Show status file
if [[ -f "$STATUS_FILE" ]]; then
    echo ""
    echo "=== Last Status ==="
    cat "$STATUS_FILE"
fi

# Show recent logs
if [[ -f "$LOG_FILE" ]]; then
    echo ""
    echo "=== Recent Logs (last 5 entries) ==="
    tail -5 "$LOG_FILE"
fi

# Show network connectivity
echo ""
echo "=== Network Tests ==="
ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && echo "Google DNS: ${GREEN}OK${NC}" || echo "Google DNS: ${RED}FAILED${NC}"
ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 && echo "Cloudflare DNS: ${GREEN}OK${NC}" || echo "Cloudflare DNS: ${RED}FAILED${NC}"
curl -s --max-time 3 https://www.google.com >/dev/null 2>&1 && echo "HTTPS Test: ${GREEN}OK${NC}" || echo "HTTPS Test: ${RED}FAILED${NC}"
EOF
    
    chmod +x /usr/local/bin/vps-auto-ping-monitor.sh
    
    # Create alias for easy monitoring
    echo "alias pingstatus='vps-auto-ping-monitor.sh'" >> /root/.bashrc
}

setup_cron_backup() {
    print_status "Setting up cron backup..."
    
    # Create a cron job that ensures service is always running
    CRON_JOB="*/5 * * * * root /usr/local/bin/vps-auto-ping-cron-check.sh"
    
    cat > /usr/local/bin/vps-auto-ping-cron-check.sh << 'EOF'
#!/bin/bash
# Cron backup check script

SERVICE="vps-auto-ping.service"

if ! systemctl is-active --quiet "$SERVICE"; then
    logger -t vps-auto-ping "Service $SERVICE is not running, attempting restart"
    systemctl restart "$SERVICE"
    
    # If still not running, run directly
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE"; then
        /usr/local/bin/vps-auto-ping.sh &
        logger -t vps-auto-ping "Started vps-auto-ping.sh directly"
    fi
fi
EOF
    
    chmod +x /usr/local/bin/vps-auto-ping-cron-check.sh
    
    # Add to crontab
    echo "$CRON_JOB" > /etc/cron.d/vps-auto-ping
}

start_service() {
    print_status "Starting VPS Auto-Ping service..."
    
    systemctl daemon-reload
    systemctl enable vps-auto-ping.service
    systemctl start vps-auto-ping.service
    
    sleep 2
    
    if systemctl is-active --quiet vps-auto-ping.service; then
        print_status "Service started successfully!"
    else
        print_error "Failed to start service"
        journalctl -u vps-auto-ping.service -n 20 --no-pager
    fi
}

show_usage() {
    cat << 'EOF'
Usage: ./vps-auto-ping-install.sh [OPTIONS]

Options:
  install    - Install and configure VPS Auto-Ping
  uninstall  - Remove VPS Auto-Ping
  status     - Show service status
  start      - Start the service
  stop       - Stop the service
  restart    - Restart the service
  logs       - Show service logs
  monitor    - Run monitoring script
  config     - Edit configuration file

Examples:
  ./vps-auto-ping-install.sh install
  ./vps-auto-ping-install.sh status
  ./vps-auto-ping-install.sh logs
EOF
}

case "$1" in
    "install")
        print_header
        check_root
        install_dependencies
        install_script
        create_systemd_service
        create_monitoring_script
        setup_cron_backup
        start_service
        
        echo ""
        print_status "Installation complete!"
        echo ""
        echo "Configuration file: /etc/vps-auto-ping.conf"
        echo "Log directory: /var/log/vps-auto-ping/"
        echo "Main script: /usr/local/bin/vps-auto-ping.sh"
        echo "Monitor script: /usr/local/bin/vps-auto-ping-monitor.sh"
        echo ""
        echo "Useful commands:"
        echo "  systemctl status vps-auto-ping"
        echo "  vps-auto-ping-monitor.sh"
        echo "  journalctl -u vps-auto-ping -f"
        ;;
    
    "uninstall")
        print_header
        check_root
        
        print_status "Stopping service..."
        systemctl stop vps-auto-ping.service 2>/dev/null || true
        systemctl disable vps-auto-ping.service 2>/dev/null || true
        
        print_status "Removing files..."
        rm -f /usr/local/bin/vps-auto-ping.sh
        rm -f /usr/local/bin/vps-auto-ping-monitor.sh
        rm -f /usr/local/bin/vps-auto-ping-cron-check.sh
        rm -f /etc/systemd/system/vps-auto-ping.service
        rm -f /etc/cron.d/vps-auto-ping
        
        print_status "Reloading systemd..."
        systemctl daemon-reload
        
        print_status "VPS Auto-Ping has been uninstalled"
        print_warning "Note: Configuration and log files were NOT removed:"
        print_warning "  /etc/vps-auto-ping.conf"
        print_warning "  /var/log/vps-auto-ping/"
        ;;
    
    "status")
        systemctl status vps-auto-ping.service
        ;;
    
    "start")
        systemctl start vps-auto-ping.service
        systemctl status vps-auto-ping.service
        ;;
    
    "stop")
        systemctl stop vps-auto-ping.service
        systemctl status vps-auto-ping.service
        ;;
    
    "restart")
        systemctl restart vps-auto-ping.service
        systemctl status vps-auto-ping.service
        ;;
    
    "logs")
        journalctl -u vps-auto-ping.service -f
        ;;
    
    "monitor")
        /usr/local/bin/vps-auto-ping-monitor.sh
        ;;
    
    "config")
        nano /etc/vps-auto-ping.conf
        ;;
    
    *)
        show_usage
        ;;
esac
