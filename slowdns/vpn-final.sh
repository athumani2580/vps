cat > vpn-final.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash

# =============================================
# SIMPLE TERMUX VPN - NO ERRORS
# =============================================

SERVER="139.84.240.171"
PORT="22"
PROXY_PORT="1080"
CONFIG_DIR="$HOME/.vpn"
PID_FILE="$CONFIG_DIR/vpn.pid"

# Create config directory
mkdir -p $CONFIG_DIR

# Colors
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

status() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${YELLOW}[i]${NC} $1"; }

install() {
    info "Installing..."
    pkg update -y && pkg upgrade -y
    pkg install -y openssh curl
    status "Ready to use"
}

start() {
    info "Stopping old VPN..."
    pkill -f "ssh.*$PROXY_PORT"
    sleep 2
    
    info "Starting VPN..."
    echo "Server: $SERVER:$PORT"
    echo "Proxy: 127.0.0.1:$PROXY_PORT"
    echo ""
    echo "Enter password when prompted"
    echo ""
    
    ssh -f -N -D $PROXY_PORT \
        -p $PORT \
        -o StrictHostKeyChecking=no \
        root@$SERVER
    
    if [ $? -eq 0 ]; then
        echo $! > $PID_FILE
        status "VPN started!"
        echo "Use: SOCKS5 127.0.0.1:$PROXY_PORT"
    else
        error "Background failed"
        info "Starting interactive..."
        ssh -D $PROXY_PORT -p $PORT root@$SERVER
    fi
}

stop() {
    info "Stopping VPN..."
    if [ -f $PID_FILE ]; then
        kill $(cat $PID_FILE) 2>/dev/null
        rm -f $PID_FILE
    fi
    pkill -f "ssh.*$PROXY_PORT"
    status "VPN stopped"
}

check() {
    if pgrep -f "ssh.*$PROXY_PORT" > /dev/null; then
        echo -e "${GREEN}✓ VPN running${NC}"
        echo "Proxy: 127.0.0.1:$PROXY_PORT"
        IP=$(curl --socks5 127.0.0.1:$PROXY_PORT -s http://ipinfo.io/ip 2>/dev/null)
        [ -n "$IP" ] && echo "IP: $IP"
    else
        echo -e "${RED}✗ VPN stopped${NC}"
    fi
}

test_vpn() {
    info "Testing..."
    if curl --socks5 127.0.0.1:$PROXY_PORT -s --max-time 5 http://ipinfo.io > /dev/null; then
        IP=$(curl --socks5 127.0.0.1:$PROXY_PORT -s http://ipinfo.io/ip)
        status "Working! IP: $IP"
    else
        error "Failed"
    fi
}

menu() {
    while true; do
        clear
        echo "========================="
        echo "    VPN MANAGER"
        echo "========================="
        echo ""
        echo "1. Start VPN"
        echo "2. Stop VPN"
        echo "3. Check Status"
        echo "4. Test Connection"
        echo "5. Install"
        echo "6. Exit"
        echo ""
        read -p "Choose: " opt
        
        case $opt in
            1) start ;;
            2) stop ;;
            3) check ;;
            4) test_vpn ;;
            5) install ;;
            6) exit 0 ;;
            *) echo "Invalid"; sleep 1 ;;
        esac
        echo ""
        read -p "Press Enter..."
    done
}

case "$1" in
    start) start ;;
    stop) stop ;;
    status|check) check ;;
    test) test_vpn ;;
    install) install ;;
    menu|"") menu ;;
    *)
        echo "Usage: $0 {start|stop|status|test|install|menu}"
        echo ""
        echo "One-liner: ssh -D 1080 -p 22 root@139.84.240.171"
        ;;
esac
EOF

# Make it work
chmod +x vpn-final.sh
./vpn-final.sh
