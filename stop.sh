#!/bin/bash
# SLDNS Guardian - Auto-find and protect sldns-server
# Save as: /usr/local/bin/sldns-guardian.sh

set -e

# Function to find sldns-server
find_sldns() {
    local locations=(
        "/usr/sbin/sldns-server"
        "/usr/bin/sldns-server"
        "/usr/local/sbin/sldns-server"
        "/usr/local/bin/sldns-server"
        "/sbin/sldns-server"
        "/bin/sldns-server"
    )
    
    for loc in "${locations[@]}"; do
        if [ -f "$loc" ] && [ -x "$loc" ]; then
            echo "$loc"
            return 0
        fi
    done
    
    # Try to find using which/whereis
    local found_path=$(which sldns-server 2>/dev/null || whereis -b sldns-server 2>/dev/null | awk '{print $2}')
    if [ -n "$found_path" ] && [ -x "$found_path" ]; then
        echo "$found_path"
        return 0
    fi
    
    return 1
}

# Configuration
SLDNS_BIN=$(find_sldns)
if [ -z "$SLDNS_BIN" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: sldns-server not found!" >&2
    echo "Installing sldns-server..." >&2
    
    # Try to install sldns
    apt-get update && apt-get install -y sldns 2>/dev/null || \
    yum install -y sldns 2>/dev/null || \
    dnf install -y sldns 2>/dev/null || \
    zypper install -y sldns 2>/dev/null || \
    pacman -S --noconfirm sldns 2>/dev/null
    
    # Try to find again after installation
    SLDNS_BIN=$(find_sldns)
    
    if [ -z "$SLDNS_BIN" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: Cannot find or install sldns-server" >&2
        exit 1
    fi
fi

SLDNS_ARGS=""
LOG_FILE="/var/log/sldns-guardian.log"
PID_DIR="/var/run"
GUARDIAN_PID_FILE="$PID_DIR/sldns-guardian.pid"
SLDNS_PID_FILE="$PID_DIR/sldns.pid"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Trap signals
trap 'cleanup' SIGTERM SIGINT SIGQUIT
trap 'restart_service' SIGHUP

cleanup() {
    log "Received termination signal"
    if [ -f "$SLDNS_PID_FILE" ]; then
        sldns_pid=$(cat "$SLDNS_PID_FILE")
        kill -9 "$sldns_pid" 2>/dev/null || true
        rm -f "$SLDNS_PID_FILE"
    fi
    rm -f "$GUARDIAN_PID_FILE"
    exit 0
}

restart_service() {
    log "Received restart signal"
    if [ -f "$SLDNS_PID_FILE" ]; then
        sldns_pid=$(cat "$SLDNS_PID_FILE")
        kill -9 "$sldns_pid" 2>/dev/null
        sleep 1
    fi
}

# Create necessary directories
mkdir -p "$(dirname "$LOG_FILE")" "$PID_DIR"
touch "$LOG_FILE"

# Create PID file for guardian
echo $$ > "$GUARDIAN_PID_FILE"

# Make guardian process less killable
renice -n -20 -p $$ >/dev/null 2>&1 || true

log "SLDNS Guardian started (PID: $$)"
log "Using sldns-server at: $SLDNS_BIN"

# Test sldns-server
if ! "$SLDNS_BIN" --version >/dev/null 2>&1 && ! "$SLDNS_BIN" -h >/dev/null 2>&1; then
    log "WARNING: sldns-server may not be executable, fixing permissions..."
    chmod +x "$SLDNS_BIN" 2>/dev/null || true
fi

# Main loop
while true; do
    log "Starting sldns-server..."
    
    # Start sldns with error handling
    if timeout 10 "$SLDNS_BIN" $SLDNS_ARGS; then
        # sldns started successfully
        SLDNS_PID=$!
        echo $SLDNS_PID > "$SLDNS_PID_FILE"
        
        # Make process high priority
        renice -n -19 -p $SLDNS_PID >/dev/null 2>&1 || true
        ionice -c 1 -n 0 -p $SLDNS_PID >/dev/null 2>&1 || true
        
        log "sldns-server started with PID: $SLDNS_PID"
        
        # Monitor and restart if needed
        while kill -0 $SLDNS_PID 2>/dev/null; do
            sleep 5
        done
    else
        log "Failed to start sldns-server, retrying..."
    fi
    
    # Clean up zombie processes
    pkill -9 -f "sldns-server" 2>/dev/null || true
    
    log "sldns-server stopped, restarting in 1 second..."
    sleep 1
done
