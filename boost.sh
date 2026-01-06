#!/bin/bash
# install_keepalive.sh - Installs the keep-alive system

set -e

# Configuration
SCRIPT_NAME="keep_vps_active.sh"
SERVICE_NAME="vps-keepalive"
INSTALL_DIR="/usr/local/bin"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME.service"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print colored message
print_message() {
    echo -e "${2}${1}${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_message "Please run as root or with sudo" "$RED"
        exit 1
    fi
}

# Download or create main script
setup_script() {
    print_message "Setting up keep-alive script..." "$YELLOW"
    
    # Create installation directory if it doesn't exist
    mkdir -p "$INSTALL_DIR"
    
    # Check if script already exists
    if [ -f "$SCRIPT_PATH" ]; then
        print_message "Script already exists, backing up..." "$YELLOW"
        cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup.$(date +%s)"
    fi
    
    # Create the script
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# keep_vps_active.sh - Prevents VPS from going inactive

# Configuration
LOG_FILE="/var/log/keepalive.log"
TIMESTAMP_FILE="/tmp/keepalive.timestamp"
CHECK_INTERVAL=300
MAX_LOG_SIZE=10485760

mkdir -p /var/log

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log_message "Log rotated"
    fi
}

perform_keepalive() {
    touch "$TIMESTAMP_FILE"
    echo "$(date)" > "$TIMESTAMP_FILE"
    ping -c 1 8.8.8.8 > /dev/null 2>&1 || true
    uptime >> "$TIMESTAMP_FILE" 2>/dev/null
    sync
}

disable_system_sleep() {
    if command -v systemctl > /dev/null 2>&1; then
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
        log_message "System sleep targets disabled"
    fi
    
    if [ -n "$TMOUT" ]; then
        unset TMOUT
        echo "unset TMOUT" >> ~/.bashrc
        echo "unset TMOUT" >> ~/.profile
        log_message "TMOUT disabled"
    fi
}

check_already_running() {
    local pid_file="/tmp/keep_vps_active.pid"
    
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            log_message "Script already running with PID $old_pid"
            exit 0
        fi
    fi
    
    echo $$ > "$pid_file"
}

main() {
    log_message "Starting VPS keep-alive script"
    log_message "Check interval: ${CHECK_INTERVAL} seconds"
    log_message "Process ID: $$"
    
    check_already_running
    disable_system_sleep
    perform_keepalive
    log_message "Initial keep-alive performed"
    
    while true; do
        rotate_log
        perform_keepalive
        log_message "Keep-alive tick performed"
        sleep "$CHECK_INTERVAL"
    done
}

trap 'log_message "Script stopped by signal"; rm -f /tmp/keep_vps_active.pid; exit 0' SIGINT SIGTERM
main
EOF
    
    # Make script executable
    chmod +x "$SCRIPT_PATH"
    print_message "Script installed to $SCRIPT_PATH" "$GREEN"
}

# Create systemd service
create_service() {
    print_message "Creating systemd service..." "$YELLOW"
    
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=VPS Keep-Alive Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=10
User=root
ExecStart=$SCRIPT_PATH
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    print_message "Systemd service created" "$GREEN"
}

# Enable and start service
enable_service() {
    print_message "Enabling and starting service..." "$YELLOW"
    
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    
    # Check status
    sleep 2
    systemctl status "$SERVICE_NAME" --no-pager -l
    
    print_message "Service enabled and started successfully" "$GREEN"
}

# Create cron fallback (in case systemd fails)
setup_cron_fallback() {
    print_message "Setting up cron fallback..." "$YELLOW"
    
    # Add to root's crontab
    (crontab -l 2>/dev/null | grep -v "keepalive"; echo "*/5 * * * * touch /tmp/keepalive.cron.timestamp") | crontab -
    
    print_message "Cron fallback installed (runs every 5 minutes)" "$GREEN"
}

# Check installation
verify_installation() {
    print_message "\nVerifying installation..." "$YELLOW"
    
    echo -e "\n1. Script location:"
    ls -la "$SCRIPT_PATH"
    
    echo -e "\n2. Service status:"
    systemctl is-active "$SERVICE_NAME"
    
    echo -e "\n3. Recent logs:"
    journalctl -u "$SERVICE_NAME" -n 5 --no-pager
    
    echo -e "\n4. Timestamp file:"
    ls -la /tmp/keepalive*
    
    echo -e "\n5. Cron job:"
    crontab -l | grep keepalive
    
    print_message "\nVerification complete!" "$GREEN"
}

# Main installation function
main_install() {
    print_message "=== VPS Keep-Alive Installation ===" "$GREEN"
    
    check_root
    setup_script
    create_service
    enable_service
    setup_cron_fallback
    verify_installation
    
    print_message "\n=== Installation Complete ===" "$GREEN"
    print_message "Service: $SERVICE_NAME" "$GREEN"
    print_message "Script: $SCRIPT_PATH" "$GREEN"
    print_message "Log file: /var/log/keepalive.log" "$GREEN"
    print_message "Check status: systemctl status $SERVICE_NAME" "$YELLOW"
    print_message "View logs: journalctl -u $SERVICE_NAME -f" "$YELLOW"
}

# Run installation
main_install
