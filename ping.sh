#!/bin/bash

set -e

DNS_SERVER="127.0.0.1"
CHECK_DOMAIN="google.com"
SERVICE_NAME="server-sldns"
PROCESS_NAME="sldns-serve"
CHECK_INTERVAL=6
LOG_FILE="/var/log/sldns-monitor.log"
SCRIPT_PATH="/usr/local/bin/sldns-monitor"
SERVICE_FILE="/etc/systemd/system/sldns-monitor.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

run_monitor() {
    echo -e "${GREEN}Starting sldns auto-monitor...${NC}"
    echo "Checking DNS every ${CHECK_INTERVAL} seconds"
    echo "Log file: ${LOG_FILE}"
    echo "Press Ctrl+C to stop"
    echo "----------------------------------------"
    
    mkdir -p /var/log/sldns
    touch "$LOG_FILE"
    
    log() {
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] $1" >> "$LOG_FILE"
    }
    
    log "=== sldns Auto-Monitor Started ==="
    log "DNS Server: $DNS_SERVER"
    log "Check Interval: ${CHECK_INTERVAL}s"
    log "Service: $SERVICE_NAME"
    log "Process: $PROCESS_NAME"
    
    local check_count=0
    local fail_count=0
    local restart_count=0
    
    while true; do
        check_count=$((check_count + 1))
        
        if dig @"$DNS_SERVER" "$CHECK_DOMAIN" +short +time=2 +tries=1 > /dev/null 2>&1; then
            if [ $((check_count % 100)) -eq 0 ]; then
                log "Check #$check_count: DNS OK (Total fails: $fail_count, Restarts: $restart_count)"
            fi
        else
            fail_count=$((fail_count + 1))
            log "Check #$check_count: DNS FAILED - Attempting restart..."
            
            if pkill -x "$PROCESS_NAME" 2>/dev/null; then
                log "Killed $PROCESS_NAME process"
            else
                log "No $PROCESS_NAME process found (already dead?)"
            fi
            
            if systemctl start "$SERVICE_NAME"; then
                restart_count=$((restart_count + 1))
                log "Service $SERVICE_NAME started successfully"
            else
                log "ERROR: Failed to start $SERVICE_NAME"
            fi
            
            sleep 10
            
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                log "Service verification: ACTIVE"
            else
                log "Service verification: INACTIVE - trying again..."
                systemctl restart "$SERVICE_NAME"
            fi
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

install_monitor() {
    echo -e "${BLUE}Installing sldns auto-monitor...${NC}"
    
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run as root: sudo $0${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Creating monitor script at $SCRIPT_PATH...${NC}"
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash

DNS_SERVER="127.0.0.1"
CHECK_DOMAIN="google.com"
SERVICE_NAME="server-sldns"
PROCESS_NAME="sldns-serve"
CHECK_INTERVAL=6
LOG_FILE="/var/log/sldns-monitor.log"

mkdir -p /var/log/sldns
touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== sldns Monitor Started ==="

while true; do
    if ! dig @"$DNS_SERVER" "$CHECK_DOMAIN" +short +time=2 +tries=1 > /dev/null 2>&1; then
        log "DNS failed - restarting service"
        
        pkill -x "$PROCESS_NAME" 2>/dev/null
        
        systemctl start "$SERVICE_NAME"
        
        log "Restart completed"
        sleep 10
    fi
    
    sleep "$CHECK_INTERVAL"
done
EOF
    
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✓ Monitor script created${NC}"
    
    echo -e "${YELLOW}Creating systemd service...${NC}"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=sldns Auto-Monitor (6-second checks)
After=network.target $SERVICE_NAME.service
Requires=$SERVICE_NAME.service

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
PrivateTmp=true

MemoryMax=50M
CPUQuota=5%

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${GREEN}✓ Systemd service created${NC}"
    
    systemctl daemon-reload
    
    systemctl enable sldns-monitor.service
    systemctl start sldns-monitor.service
    
    if systemctl is-active --quiet sldns-monitor.service; then
        echo -e "${GREEN}✓ Monitor service started successfully${NC}"
    else
        echo -e "${RED}✗ Failed to start monitor service${NC}"
        systemctl status sldns-monitor.service
        exit 1
    fi
    
    cat > /etc/logrotate.d/sldns-monitor << EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF
    echo -e "${GREEN}✓ Log rotation configured${NC}"
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}INSTALLATION COMPLETE!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Monitor is now running automatically."
    echo ""
    echo "Commands:"
    echo "  Check status:   systemctl status sldns-monitor"
    echo "  View logs:      journalctl -u sldns-monitor -f"
    echo "                  tail -f $LOG_FILE"
    echo "  Stop monitor:   systemctl stop sldns-monitor"
    echo "  Start monitor:  systemctl start sldns-monitor"
    echo "  Restart:        systemctl restart sldns-monitor"
    echo ""
    echo "Test DNS manually:"
    echo "  dig @127.0.0.1 google.com +short"
    echo ""
    echo "The monitor will:"
    echo "  1. Check DNS every 6 seconds"
    echo "  2. Kill sldns-serve if DNS fails"
    echo "  3. Start server-sldns service"
    echo "  4. Run automatically on system boot"
    echo ""
    echo "Log file: $LOG_FILE"
    echo -e "${GREEN}========================================${NC}"
}

uninstall_monitor() {
    echo -e "${YELLOW}Uninstalling sldns monitor...${NC}"
    
    systemctl stop sldns-monitor.service 2>/dev/null || true
    systemctl disable sldns-monitor.service 2>/dev/null || true
    
    rm -f "$SCRIPT_PATH"
    rm -f "$SERVICE_FILE"
    rm -f /etc/logrotate.d/sldns-monitor
    
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ sldns monitor uninstalled${NC}"
    echo "Note: Log file at $LOG_FILE was not removed"
}

check_status() {
    echo -e "${BLUE}Checking sldns monitor status...${NC}"
    echo ""
    
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${GREEN}✓ Monitor service installed${NC}"
    else
        echo -e "${RED}✗ Monitor service not installed${NC}"
    fi
    
    if systemctl is-active --quiet sldns-monitor.service 2>/dev/null; then
        echo -e "${GREEN}✓ Monitor service is RUNNING${NC}"
    else
        echo -e "${YELLOW}⚠ Monitor service is STOPPED${NC}"
    fi
    
    if [ -f "$LOG_FILE" ]; then
        echo -e "${GREEN}✓ Log file exists: $LOG_FILE${NC}"
        echo "Recent log entries:"
        tail -5 "$LOG_FILE" 2>/dev/null || echo "  (log file empty)"
    fi
    
    echo ""
    echo -e "${BLUE}Testing DNS connection...${NC}"
    if dig @"$DNS_SERVER" "$CHECK_DOMAIN" +short +time=2 2>/dev/null | head -1; then
        echo -e "${GREEN}✓ DNS is working${NC}"
    else
        echo -e "${RED}✗ DNS is NOT working${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Checking sldns service...${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}✓ $SERVICE_NAME is running${NC}"
    else
        echo -e "${RED}✗ $SERVICE_NAME is NOT running${NC}"
    fi
    
    if pgrep -x "$PROCESS_NAME" > /dev/null; then
        echo -e "${GREEN}✓ $PROCESS_NAME process exists${NC}"
    else
        echo -e "${RED}✗ $PROCESS_NAME process NOT found${NC}"
    fi
}

quick_run() {
    echo -e "${YELLOW}Running monitor directly (not as service)...${NC}"
    echo "Press Ctrl+C to stop"
    echo ""
    run_monitor
}

show_help() {
    echo -e "${GREEN}sldns Auto-Monitor Script${NC}"
    echo "Checks DNS every 6 seconds, auto-restarts sldns on failure"
    echo ""
    echo "Usage:"
    echo "  $0 install    - Install as auto-start service"
    echo "  $0 run        - Run monitor directly (for testing)"
    echo "  $0 status     - Check monitor and DNS status"
    echo "  $0 uninstall  - Remove monitor service"
    echo "  $0 help       - Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo $0 install   # Install and auto-start"
    echo "  sudo $0 run       # Test run manually"
    echo "  sudo $0 status    # Check if working"
    echo ""
    echo "Once installed, the monitor will:"
    echo "  • Check DNS @127.0.0.1 every 6 seconds"
    echo "  • Kill 'sldns-serve' if DNS fails"
    echo "  • Start 'server-sldns' service"
    echo "  • Run automatically on system boot"
}

case "${1:-}" in
    "install")
        install_monitor
        ;;
    "run"|"start")
        quick_run
        ;;
    "status"|"check")
        check_status
        ;;
    "uninstall"|"remove")
        uninstall_monitor
        ;;
    "help"|"--help"|-h)
        show_help
        ;;
    "")
        echo -e "${YELLOW}No command specified.${NC}"
        show_help
        echo ""
        echo -e "${YELLOW}Quick install:${NC}"
        echo "  sudo $0 install"
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        exit 1
        ;;
esac
