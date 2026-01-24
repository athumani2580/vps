#!/bin/bash
# SLDNS Guardian - Unkillable Service Wrapper
# Save as: /usr/local/bin/sldns-guardian.sh

set -e

# Configuration
SLDNS_BIN="/usr/sbin/sldns-server"
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

# Create PID file for guardian
echo $$ > "$GUARDIAN_PID_FILE"

# Make guardian process less killable (if supported)
renice -n -20 -p $$ >/dev/null 2>&1 || true

# Main loop
log "SLDNS Guardian started (PID: $$)"
while true; do
    if [ ! -f "$SLDNS_BIN" ]; then
        log "ERROR: SLDNS binary not found at $SLDNS_BIN"
        sleep 60
        continue
    fi
    
    log "Starting sldns-server..."
    "$SLDNS_BIN" $SLDNS_ARGS &
    SLDNS_PID=$!
    echo $SLDNS_PID > "$SLDNS_PID_FILE"
    
    # Make sldns process less killable
    renice -n -19 -p $SLDNS_PID >/dev/null 2>&1 || true
    
    # Wait for process to exit
    wait $SLDNS_PID
    EXIT_CODE=$?
    
    log "sldns-server exited with code $EXIT_CODE"
    log "Restarting in 2 seconds..."
    sleep 2
    
    # Clean up any zombie processes
    pkill -9 -f "$SLDNS_BIN" 2>/dev/null || true
done
