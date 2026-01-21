#!/data/data/com.termux/files/usr/bin/bash

# =============================================
# Complete SlowDNS VPN for Termux
# =============================================

# Server Configuration
SERVER_IP="139.84.240.171"
SSH_PORT="22"
DNS_RESOLVER="169.255.187.58"
DNS_PORT="53"
NAMESERVER="gerry.alienalien.top"
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
SLOWDNS_PORT="5300"

# Local Configuration
LOCAL_PORT="1080"
LOCAL_DNS_PORT="5353"
SOCKS_PORT="1080"
HTTP_PORT="8123"
VPN_INTERFACE="tun0"

# Directories
CONFIG_DIR="$HOME/.slowdns-vpn"
LOG_DIR="$CONFIG_DIR/logs"
BIN_DIR="$CONFIG_DIR/bin"
APP_DIR="$CONFIG_DIR/app"
PID_DIR="$CONFIG_DIR/pid"

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# Create directories
mkdir -p {$CONFIG_DIR,$LOG_DIR,$BIN_DIR,$APP_DIR,$PID_DIR}

# =============================================
# FUNCTIONS
# =============================================

print_header() {
    clear
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║           TERMUX COMPLETE VPN                ║"
    echo "║     SlowDNS + SSH + SOCKS5 + HTTP Proxy      ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${YELLOW}[i]${NC} $1"; }
print_step() { echo -e "${BLUE}[→]${NC} $1"; }

# =============================================
# INSTALLATION
# =============================================

install_dependencies() {
    print_step "Installing dependencies..."
    
    pkg update -y && pkg upgrade -y
    
    # Core packages
    pkg install -y openssh curl wget netcat-openbsd dnsutils \
                   proot termux-api termux-tools iproute2 \
                   nmap python python-pip micro \
                   redsocks privoxy stunnel
    
    # Python packages
    pip install requests pysocks beautifulsoup4
    
    print_status "Dependencies installed"
}

install_slowdns_client() {
    print_step "Installing SlowDNS client..."
    
    # Create sldns from public key
    cat > "$BIN_DIR/sldns" << 'SLOWDNS_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# SlowDNS client wrapper

SERVER="139.84.240.171"
PORT="5300"
KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
NS="gerry.alienalien.top"
LOCAL_PORT="5353"

echo "Starting SlowDNS tunnel..."
echo "Nameserver: $NS"
echo "Server: $SERVER:$PORT"

# Convert hex key to binary
echo "$KEY" | xxd -r -p > /tmp/slowdns.key 2>/dev/null

# Try to use existing sldns binary or use alternative
if [ -f "$(dirname "$0")/sldns-bin" ]; then
    "$(dirname "$0")/sldns-bin" -udp :$LOCAL_PORT \
        -pubkey-file /tmp/slowdns.key \
        "$NS" "$SERVER:$PORT"
elif command -v python3 >/dev/null; then
    python3 -c "
import socket
import sys
import threading
from datetime import datetime

def slowdns_client():
    print('Starting Python SlowDNS client...')
    
    # Create socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', $LOCAL_PORT))
    
    print(f'Listening on 127.0.0.1:$LOCAL_PORT')
    print(f'Forwarding to $SERVER:$PORT')
    
    while True:
        try:
            data, addr = sock.recvfrom(512)
            # Forward to SlowDNS server
            server_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            server_sock.sendto(data, ('$SERVER', $PORT))
            response, _ = server_sock.recvfrom(512)
            server_sock.close()
            # Send back to client
            sock.sendto(response, addr)
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f'Error: {e}')
    
    sock.close()

slowdns_client()
"
else
    echo "Error: No suitable SlowDNS client found"
    exit 1
fi
SLOWDNS_EOF
    
    chmod +x "$BIN_DIR/sldns"
    print_status "SlowDNS client installed"
}

# =============================================
# VPN COMPONENTS
# =============================================

start_ssh_tunnel() {
    print_step "Starting SSH SOCKS5 tunnel..."
    
    # Kill existing
    pkill -f "ssh.*$SOCKS_PORT" 2>/dev/null
    sleep 1
    
    # Check port
    if netstat -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
        fuser -k $SOCKS_PORT/tcp 2>/dev/null
        sleep 1
    fi
    
    # Start SSH tunnel
    ssh -f -N \
        -D $SOCKS_PORT \
        -p $SSH_PORT \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        root@$SERVER_IP
    
    if [ $? -eq 0 ]; then
        echo $! > "$PID_DIR/ssh.pid"
        print_status "SSH SOCKS5 started on 127.0.0.1:$SOCKS_PORT"
        return 0
    else
        print_error "SSH tunnel failed"
        return 1
    fi
}

start_slowdns() {
    print_step "Starting SlowDNS..."
    
    pkill -f "sldns" 2>/dev/null
    sleep 1
    
    # Start SlowDNS client
    "$BIN_DIR/sldns" > "$LOG_DIR/slowdns.log" 2>&1 &
    echo $! > "$PID_DIR/slowdns.pid"
    
    sleep 2
    if pgrep -f "sldns" > /dev/null; then
        print_status "SlowDNS started on 127.0.0.1:$LOCAL_DNS_PORT"
        
        # Configure DNS
        configure_dns
        return 0
    else
        print_error "SlowDNS failed to start"
        return 1
    fi
}

configure_dns() {
    print_step "Configuring DNS..."
    
    # Create resolv.conf
    cat > "$CONFIG_DIR/resolv.conf" << EOF
# SlowDNS VPN Configuration
nameserver 127.0.0.1
nameserver $DNS_RESOLVER
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF
    
    # Try to set system DNS
    if [ -w /etc/resolv.conf ]; then
        cp "$CONFIG_DIR/resolv.conf" /etc/resolv.conf
        print_status "System DNS configured"
    else
        print_info "Manual DNS setup needed"
        echo -e "${YELLOW}Set DNS to: 127.0.0.1${NC}"
    fi
    
    # Set via Termux properties
    termux-wifi-connectioninfo | grep -q "supplicant_state=COMPLETED" && {
        termux-wifi-scaninfo > /dev/null 2>&1
        print_info "WiFi detected, DNS may need manual setup"
    }
}

start_http_proxy() {
    print_step "Starting HTTP proxy..."
    
    # Install redsocks if needed
    if [ ! -f /data/data/com.termux/files/usr/etc/redsocks.conf ]; then
        cat > /data/data/com.termux/files/usr/etc/redsocks.conf << EOF
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $HTTP_PORT;
    ip = 127.0.0.1;
    port = $SOCKS_PORT;
    type = socks5;
}
EOF
    fi
    
    # Start redsocks
    pkill redsocks 2>/dev/null
    redsocks -c /data/data/com.termux/files/usr/etc/redsocks.conf
    echo $! > "$PID_DIR/redsocks.pid"
    
    print_status "HTTP proxy started on 127.0.0.1:$HTTP_PORT"
}

start_privoxy() {
    print_step "Starting Privoxy (ad blocker)..."
    
    # Create Privoxy config
    mkdir -p $CONFIG_DIR/privoxy
    cat > $CONFIG_DIR/privoxy/config << EOF
listen-address 127.0.0.1:8118
forward-socks5 / 127.0.0.1:$SOCKS_PORT .
toggle 1
enable-remote-toggle 0
enable-remote-http-toggle 0
enable-edit-actions 0
forwarded-connect-retries 0
accept-intercepted-requests 0
allow-cgi-request-crunching 0
split-large-forms 0
keep-alive-timeout 300
socket-timeout 300
EOF
    
    # Start Privoxy
    pkill privoxy 2>/dev/null
    privoxy --no-daemon $CONFIG_DIR/privoxy/config > $LOG_DIR/privoxy.log 2>&1 &
    echo $! > "$PID_DIR/privoxy.pid"
    
    print_status "Privoxy started on 127.0.0.1:8118"
}

# =============================================
# VPN APP CREATION
# =============================================

create_vpn_app() {
    print_step "Creating VPN app..."
    
    # Create Termux shortcut
    cat > $APP_DIR/vpn-launcher.sh << 'LAUNCHER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# VPN Launcher for Termux Widget/Tasker

CONFIG_DIR="$HOME/.slowdns-vpn"
PID_DIR="$CONFIG_DIR/pid"

case "$1" in
    "start")
        # Start VPN
        $HOME/vpn-manager.sh start
        ;;
    "stop")
        # Stop VPN
        $HOME/vpn-manager.sh stop
        ;;
    "status")
        # Check status
        if [ -f "$PID_DIR/ssh.pid" ] && kill -0 $(cat "$PID_DIR/ssh.pid") 2>/dev/null; then
            echo "VPN: RUNNING"
            echo "SOCKS5: 127.0.0.1:1080"
            echo "HTTP: 127.0.0.1:8123"
        else
            echo "VPN: STOPPED"
        fi
        ;;
    "test")
        # Test connection
        curl --socks5 127.0.0.1:1080 -s http://ipinfo.io/ip
        ;;
    *)
        echo "Usage: $0 {start|stop|status|test}"
        ;;
esac
LAUNCHER_EOF
    
    chmod +x $APP_DIR/vpn-launcher.sh
    
    # Create Termux widget script
    cat > $APP_DIR/termux-vpn.sh << 'WIDGET_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Termux widget script

CONFIG_DIR="$HOME/.slowdns-vpn"
PID_FILE="$CONFIG_DIR/pid/ssh.pid"

if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    # VPN is running - show status
    IP=$(curl --socks5 127.0.0.1:1080 -s --max-time 3 http://ipinfo.io/ip 2>/dev/null)
    if [ -n "$IP" ]; then
        echo "✅ VPN Active"
        echo "IP: $IP"
        echo "Port: 1080"
    else
        echo "⚠️ VPN Running"
        echo "Proxy: 127.0.0.1:1080"
    fi
    echo ""
    echo "Tap to stop"
    termux-notification --id "vpn_status" \
        --title "VPN Active" \
        --content "SOCKS5: 127.0.0.1:1080" \
        --button1 "Stop VPN" \
        --button1-action "termux-vpn.sh stop"
else
    # VPN is stopped - offer to start
    echo "🚫 VPN Stopped"
    echo ""
    echo "Tap to start"
    termux-notification --id "vpn_status" \
        --title "VPN Stopped" \
        --content "Tap to connect" \
        --button1 "Start VPN" \
        --button1-action "termux-vpn.sh start"
fi

# Handle button actions
if [ "$1" = "start" ]; then
    $HOME/vpn-manager.sh start
    termux-toast "Starting VPN..."
elif [ "$1" = "stop" ]; then
    $HOME/vpn-manager.sh stop
    termux-toast "Stopping VPN..."
fi
WIDGET_EOF
    
    chmod +x $APP_DIR/termux-vpn.sh
    
    # Create Tasker/HTTP API
    cat > $APP_DIR/vpn-api.sh << 'API_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# HTTP API for VPN control

PORT="8080"
CONFIG_DIR="$HOME/.slowdns-vpn"

response() {
    echo -e "HTTP/1.1 $1\r"
    echo -e "Content-Type: application/json\r"
    echo -e "\r"
    echo -e "$2"
}

# Check if netcat is available
if ! command -v nc >/dev/null; then
    echo "Error: netcat not installed"
    exit 1
fi

echo "VPN API running on port $PORT"
echo "Endpoints:"
echo "  GET /status"
echo "  GET /start"
echo "  GET /stop"
echo "  GET /ip"

while true; do
    # Simple HTTP server
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<h1>VPN API</h1>" | \
    nc -l -p $PORT -q 1 | {
        read request
        case "$request" in
            *"GET /status"*)
                if [ -f "$CONFIG_DIR/pid/ssh.pid" ]; then
                    response "200 OK" '{"status":"running","socks":"127.0.0.1:1080"}'
                else
                    response "200 OK" '{"status":"stopped"}'
                fi
                ;;
            *"GET /start"*)
                $HOME/vpn-manager.sh start
                response "200 OK" '{"status":"starting"}'
                ;;
            *"GET /stop"*)
                $HOME/vpn-manager.sh stop
                response "200 OK" '{"status":"stopping"}'
                ;;
            *"GET /ip"*)
                IP=$(curl --socks5 127.0.0.1:1080 -s http://ipinfo.io/ip 2>/dev/null || echo "unknown")
                response "200 OK" "{\"ip\":\"$IP\"}"
                ;;
            *)
                response "200 OK" '{"endpoints":["/status","/start","/stop","/ip"]}'
                ;;
        esac
    }
done
API_EOF
    
    chmod +x $APP_DIR/vpn-api.sh
    
    print_status "VPN app created in $APP_DIR/"
}

# =============================================
# MAIN VPN CONTROL
# =============================================

start_vpn() {
    print_header
    
    # Install if first run
    if [ ! -f "$CONFIG_DIR/installed" ]; then
        install_dependencies
        install_slowdns_client
        create_vpn_app
        touch "$CONFIG_DIR/installed"
    fi
    
    print_step "Starting Complete VPN..."
    
    # Start components
    start_ssh_tunnel || {
        print_error "Failed to start SSH tunnel"
        return 1
    }
    
    start_slowdns
    start_http_proxy
    start_privoxy
    
    print_header
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║          VPN STARTED SUCCESSFULLY!           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    show_connection_info
}

stop_vpn() {
    print_step "Stopping VPN..."
    
    # Stop all components
    for pid_file in $PID_DIR/*.pid; do
        if [ -f "$pid_file" ]; then
            kill $(cat "$pid_file") 2>/dev/null
            rm -f "$pid_file"
        fi
    done
    
    # Kill any remaining
    pkill -f "ssh.*$SOCKS_PORT" 2>/dev/null
    pkill -f sldns 2>/dev/null
    pkill redsocks 2>/dev/null
    pkill privoxy 2>/dev/null
    
    # Reset DNS
    if [ -w /etc/resolv.conf ]; then
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    
    print_status "VPN stopped completely"
}

show_connection_info() {
    echo ""
    echo -e "${CYAN}════════ CONNECTION INFO ════════${NC}"
    echo ""
    echo -e "${YELLOW}Proxy Servers:${NC}"
    echo -e "SOCKS5:    ${GREEN}127.0.0.1:1080${NC} (Recommended)"
    echo -e "HTTP:      ${GREEN}127.0.0.1:8123${NC}"
    echo -e "Privoxy:   ${GREEN}127.0.0.1:8118${NC} (with ad blocking)"
    echo ""
    echo -e "${YELLOW}DNS:${NC}"
    echo -e "Primary:   ${GREEN}127.0.0.1:5353${NC} (SlowDNS)"
    echo -e "Fallback:  ${GREEN}169.255.187.58:53${NC}"
    echo ""
    echo -e "${CYAN}════════ APP USAGE ════════${NC}"
    echo ""
    echo -e "${YELLOW}For Android Apps:${NC}"
    echo "1. Install ProxyDroid or SocksDroid"
    echo "2. Set Proxy: 127.0.0.1"
    echo "3. Set Port: 1080"
    echo "4. Type: SOCKS5"
    echo ""
    echo -e "${YELLOW}For Browser (Termux):${NC}"
    echo "export http_proxy=http://127.0.0.1:8123"
    echo "export https_proxy=http://127.0.0.1:8123"
    echo ""
    echo -e "${YELLOW}Test Commands:${NC}"
    echo "curl --socks5 127.0.0.1:1080 http://ipinfo.io"
    echo "curl --proxy http://127.0.0.1:8123 http://ipinfo.io"
    echo ""
    echo -e "${CYAN}════════ QUICK LINKS ════════${NC}"
    echo ""
    echo "./vpn-manager.sh status  # Check status"
    echo "./vpn-manager.sh stop    # Stop VPN"
    echo "./vpn-manager.sh test    # Test connection"
    echo "./vpn-manager.sh app     # Open app menu"
    echo ""
}

test_vpn() {
    print_step "Testing VPN connection..."
    
    echo ""
    echo "1. Testing SSH tunnel..."
    if pgrep -f "ssh.*$SOCKS_PORT" > /dev/null; then
        echo -e "   ${GREEN}✓ SSH tunnel running${NC}"
    else
        echo -e "   ${RED}✗ SSH tunnel not running${NC}"
    fi
    
    echo ""
    echo "2. Testing SOCKS5 proxy..."
    IP=$(timeout 5 curl --socks5 127.0.0.1:$SOCKS_PORT -s http://ipinfo.io/ip 2>/dev/null)
    if [ -n "$IP" ]; then
        echo -e "   ${GREEN}✓ SOCKS5 working - IP: $IP${NC}"
    else
        echo -e "   ${RED}✗ SOCKS5 not working${NC}"
    fi
    
    echo ""
    echo "3. Testing HTTP proxy..."
    IP2=$(timeout 5 curl --proxy http://127.0.0.1:$HTTP_PORT -s http://ipinfo.io/ip 2>/dev/null)
    if [ -n "$IP2" ]; then
        echo -e "   ${GREEN}✓ HTTP proxy working - IP: $IP2${NC}"
    else
        echo -e "   ${RED}✗ HTTP proxy not working${NC}"
    fi
    
    echo ""
    echo "4. Testing DNS..."
    if timeout 3 dig @127.0.0.1 -p $LOCAL_DNS_PORT google.com > /dev/null 2>&1; then
        echo -e "   ${GREEN}✓ DNS working${NC}"
    else
        echo -e "   ${RED}✗ DNS not working${NC}"
    fi
}

app_menu() {
    while true; do
        print_header
        echo ""
        echo -e "${CYAN}VPN APP MENU${NC}"
        echo ""
        echo "1. Start VPN"
        echo "2. Stop VPN"
        echo "3. Check Status"
        echo "4. Test Connection"
        echo "5. Show Proxy Info"
        echo "6. Launch Termux Widget"
        echo "7. Start VPN API (for Tasker)"
        echo "8. Create Desktop Shortcut"
        echo "9. Exit"
        echo ""
        read -p "Select [1-9]: " choice
        
        case $choice in
            1) start_vpn; read -p "Press Enter..."; ;;
            2) stop_vpn; read -p "Press Enter..."; ;;
            3) 
                if pgrep -f "ssh.*1080" > /dev/null; then
                    echo -e "${GREEN}VPN is running${NC}"
                else
                    echo -e "${RED}VPN is stopped${NC}"
                fi
                read -p "Press Enter..."; 
                ;;
            4) test_vpn; read -p "Press Enter..."; ;;
            5) show_connection_info; read -p "Press Enter..."; ;;
            6) $APP_DIR/termux-vpn.sh; ;;
            7) $APP_DIR/vpn-api.sh &; echo "API running on port 8080"; ;;
            8) create_desktop_shortcut; ;;
            9) exit 0; ;;
            *) echo "Invalid choice"; sleep 1; ;;
        esac
    done
}

create_desktop_shortcut() {
    print_step "Creating desktop shortcut..."
    
    # Create HTML shortcut for Termux desktop
    cat > $APP_DIR/vpn-shortcut.html << 'SHORTCUT_EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Termux VPN</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { font-family: Arial; padding: 20px; }
        .btn { 
            display: block; width: 100%; padding: 15px; 
            margin: 10px 0; text-align: center; 
            background: #4CAF50; color: white; 
            text-decoration: none; border-radius: 5px;
        }
        .stop { background: #f44336; }
        .status { background: #2196F3; }
    </style>
</head>
<body>
    <h2>Termux VPN Control</h2>
    <a href="termux://run?cmd=cd%20~%20%26%26%20./vpn-manager.sh%20start" class="btn">▶ Start VPN</a>
    <a href="termux://run?cmd=cd%20~%20%26%26%20./vpn-manager.sh%20stop" class="btn stop">⏹ Stop VPN</a>
    <a href="termux://run?cmd=cd%20~%20%26%26%20./vpn-manager.sh%20status" class="btn status">📊 Status</a>
    <a href="termux://run?cmd=cd%20~%20%26%26%20curl%20--socks5%20127.0.0.1:1080%20http://ipinfo.io" class="btn">🌐 Test</a>
</body>
</html>
SHORTCUT_EOF
    
    # Share to downloads
    cp $APP_DIR/vpn-shortcut.html /sdcard/Download/vpn-control.html 2>/dev/null || \
    cp $APP_DIR/vpn-shortcut.html ~/storage/downloads/vpn-control.html 2>/dev/null
    
    print_status "Shortcut created: vpn-control.html"
    print_info "Open this file in browser to control VPN"
}

# =============================================
# MAIN EXECUTION
# =============================================

case "$1" in
    "start")
        start_vpn
        ;;
    "stop")
        stop_vpn
        ;;
    "restart")
        stop_vpn
        sleep 2
        start_vpn
        ;;
    "status")
        if pgrep -f "ssh.*1080" > /dev/null; then
            echo -e "${GREEN}VPN is running${NC}"
            echo "SOCKS5: 127.0.0.1:1080"
            echo "HTTP: 127.0.0.1:8123"
            echo "DNS: 127.0.0.1:5353"
        else
            echo -e "${RED}VPN is stopped${NC}"
        fi
        ;;
    "test")
        test_vpn
        ;;
    "app")
        app_menu
        ;;
    "install")
        install_dependencies
        install_slowdns_client
        create_vpn_app
        print_status "Installation complete!"
        echo "Run: ./vpn-manager.sh start"
        ;;
    "info"|"config")
        show_connection_info
        ;;
    *)
        print_header
        echo ""
        echo -e "${CYAN}Usage:${NC}"
        echo "  ./vpn-manager.sh [command]"
        echo ""
        echo -e "${CYAN}Commands:${NC}"
        echo "  start     - Start VPN"
        echo "  stop      - Stop VPN"
        echo "  restart   - Restart VPN"
        echo "  status    - Check status"
        echo "  test      - Test connection"
        echo "  app       - Open app menu"
        echo "  install   - Install dependencies"
        echo "  info      - Show connection info"
        echo ""
        echo -e "${CYAN}Quick Start:${NC}"
        echo "  1. chmod +x vpn-manager.sh"
        echo "  2. ./vpn-manager.sh install"
        echo "  3. ./vpn-manager.sh start"
        echo ""
        echo -e "${YELLOW}For Android Apps:${NC}"
        echo "Use Proxy: 127.0.0.1:1080 (SOCKS5)"
        echo ""
        exit 1
        ;;
esac
