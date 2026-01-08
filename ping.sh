#!/bin/bash
# ============================================
# VPS Auto-Ping Keepalive Script
# Version: 2.0
# Author: VPS Maintainer
# ============================================

# Configuration
CONFIG_FILE="/etc/vps-auto-ping.conf"
LOG_DIR="/var/log/vps-auto-ping"
LOG_FILE="$LOG_DIR/vps-auto-ping.log"
PID_FILE="/var/run/vps-auto-ping.pid"
STATUS_FILE="/tmp/vps-auto-ping.status"

# Default settings
MODE="aggressive"           # aggressive, normal, quiet
PING_INTERVAL=60           # seconds between ping cycles
HTTP_INTERVAL=120          # seconds between HTTP checks
LOG_LEVEL="info"           # debug, info, warning, error
TARGETS=("8.8.8.8" "1.1.1.1" "google.com" "cloudflare.com")
HTTP_TARGETS=("https://www.google.com" "https://www.cloudflare.com")
MAX_FAILURES=5

# Initialize
init() {
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Create PID file
    echo $$ > "$PID_FILE"
    
    # Create status file
    echo "STATUS=STARTED" > "$STATUS_FILE"
    echo "TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATUS_FILE"
    echo "PID=$$" >> "$STATUS_FILE"
    echo "MODE=$MODE" >> "$STATUS_FILE"
    
    log "info" "========================================"
    log "info" "VPS Auto-Ping Keepalive Started"
    log "info" "PID: $$ | Mode: $MODE"
    log "info" "========================================"
}

# Cleanup
cleanup() {
    log "info" "Shutting down VPS Auto-Ping"
    echo "STATUS=STOPPED" >> "$STATUS_FILE"
    echo "STOP_TIME=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATUS_FILE"
    rm -f "$PID_FILE"
    exit 0
}

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Test network connectivity
test_ping() {
    local target="$1"
    local count="${2:-2}"
    local timeout="${3:-2}"
    
    if ping -c "$count" -W "$timeout" "$target" > /dev/null 2>&1; then
        log "debug" "Ping ✓ $target"
        return 0
    else
        log "warning" "Ping ✗ $target"
        return 1
    fi
}

# Test HTTP connectivity
test_http() {
    local url="$1"
    local timeout="${2:-5}"
    
    if curl -s --max-time "$timeout" "$url" > /dev/null 2>&1; then
        log "debug" "HTTP ✓ $url"
        return 0
    else
        log "warning" "HTTP ✗ $url"
        return 1
    fi
}

# Test DNS resolution
test_dns() {
    local domain="$1"
    
    if dig +short "$domain" @8.8.8.8 > /dev/null 2>&1; then
        log "debug" "DNS ✓ $domain"
        return 0
    else
        log "warning" "DNS ✗ $domain"
        return 1
    fi
}

# Generate system activity
generate_activity() {
    # File system activity
    touch "/tmp/.vps_keepalive_$(date +%s)"
    
    # Small CPU activity
    timeout 0.1 dd if=/dev/urandom of=/dev/null bs=1K count=10 2>/dev/null
    
    # Memory activity
    local temp_array=()
    for i in {1..50}; do
        temp_array[$i]=$i
    done
    
    log "debug" "Generated system activity"
}

# Aggressive mode - maximum activity
aggressive_mode() {
    log "info" "Running in AGGRESSIVE mode"
    
    while true; do
        local cycle_start=$(date +%s)
        
        # Ping all targets
        for target in "${TARGETS[@]}"; do
            test_ping "$target" 2 1 &
        done
        wait
        
        # HTTP tests
        for url in "${HTTP_TARGETS[@]}"; do
            test_http "$url" &
        done
        wait
        
        # DNS tests
        test_dns "google.com" &
        test_dns "cloudflare.com" &
        wait
        
        # Generate system activity
        generate_activity
        
        # Update status
        update_status
        
        # Wait for next cycle
        sleep 30
    done
}

# Normal mode - balanced activity
normal_mode() {
    log "info" "Running in NORMAL mode"
    
    while true; do
        # Ping primary targets
        test_ping "8.8.8.8"
        test_ping "1.1.1.1"
        
        # HTTP test
        test_http "https://www.google.com"
        
        # Generate activity
        generate_activity
        
        # Update status
        update_status
        
        # Wait 2 minutes
        sleep 120
    done
}

# Quiet mode - minimal activity
quiet_mode() {
    log "info" "Running in QUIET mode"
    
    while true; do
        # Single ping
        test_ping "8.8.8.8"
        
        # Update status
        update_status
        
        # Wait 5 minutes
        sleep 300
    done
}

# Update status file
update_status() {
    cat > "$STATUS_FILE" << EOF
STATUS=RUNNING
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
PID=$$
MODE=$MODE
UPTIME=$(uptime -p)
LOAD=$(cat /proc/loadavg | awk '{print $1,$2,$3}')
LAST_ACTIVITY=$(date '+%Y-%m-%d %H:%M:%S')
EOF
}

# Trap signals
trap cleanup SIGINT SIGTERM

# Main execution
main() {
    # Initialize
    init
    
    # Run based on mode
    case "$MODE" in
        "aggressive")
            aggressive_mode
            ;;
        "normal")
            normal_mode
            ;;
        "quiet")
            quiet_mode
            ;;
        *)
            log "error" "Unknown mode: $MODE. Using normal mode."
            normal_mode
            ;;
    esac
}

# Start main function
main "$@"
