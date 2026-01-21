cat > ~/termux-vpn.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash

# ============================================
# TERMUX VPN SCRIPT
# ============================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SERVER_IP="139.84.240.171"
DNS_RESOLVER="169.255.187.58"
NAMESERVER="gerry.alienalien.top"
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
DNS_PORT="5353"           # Using high port to avoid permission issues
TUNNEL_PORT="5300"
SOCKS_PORT="1080"
LOG_FILE="/data/data/com.termux/files/home/vpn.log"
PID_DIR="/tmp/termux_vpn"

# Banner
show_banner() {
    clear
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════╗"
    echo "║         TERMUX VPN MANAGER           ║"
    echo "║         SlowDNS + SOCKS5             ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${CYAN}Server: ${GREEN}$SERVER_IP${NC}"
    echo -e "${CYAN}Domain: ${GREEN}$NAMESERVER${NC}"
    echo -e "${CYAN}SOCKS5: ${GREEN}127.0.0.1:$SOCKS_PORT${NC}"
    echo -e "${CYAN}DNS: ${GREEN}127.0.0.1:$DNS_PORT${NC}"
    echo "════════════════════════════════════════"
}

# Create PID directory
create_pid_dir() {
    mkdir -p $PID_DIR
    chmod 700 $PID_DIR
}

# Install dependencies
install_deps() {
    echo -e "${YELLOW}[*] Checking dependencies...${NC}"
    
    local missing=()
    
    # Check socat
    if ! command -v socat &> /dev/null; then
        missing+=("socat")
    fi
    
    # Check dns2socks
    if ! command -v dns2socks &> /dev/null; then
        missing+=("dns2socks")
    fi
    
    # Check curl
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}[*] Installing: ${missing[*]}${NC}"
        pkg update -y
        pkg install -y ${missing[*]}
    fi
    
    # Install slowdns if not exists
    if ! command -v slowdns &> /dev/null; then
        echo -e "${YELLOW}[*] Installing slowdns...${NC}"
        wget -q https://github.com/foomurf/slowdns/releases/latest/download/slowdns-android-arm64 -O $PREFIX/bin/slowdns
        chmod +x $PREFIX/bin/slowdns
    fi
    
    echo -e "${GREEN}[✓] Dependencies checked${NC}"
}

# Start DNS forwarder (using high port 5353)
start_dns_forwarder() {
    echo -e "${YELLOW}[*] Starting DNS forwarder...${NC}"
    
    # Kill existing socat
    pkill -9 socat 2>/dev/null
    
    # Start UDP forwarder
    socat UDP4-LISTEN:$DNS_PORT,fork TCP4:127.0.0.1:$TUNNEL_PORT >/dev/null 2>&1 &
    UDP_PID=$!
    echo $UDP_PID > $PID_DIR/dns_udp.pid
    
    # Start TCP forwarder
    socat TCP4-LISTEN:$DNS_PORT,fork,reuseaddr TCP4:127.0.0.1:$TUNNEL_PORT >/dev/null 2>&1 &
    TCP_PID=$!
    echo $TCP_PID > $PID_DIR/dns_tcp.pid
    
    echo -e "${GREEN}[✓] DNS forwarder started on port $DNS_PORT${NC}"
    echo -e "${BLUE}   UDP PID: $UDP_PID${NC}"
    echo -e "${BLUE}   TCP PID: $TCP_PID${NC}"
}

# Start SlowDNS tunnel
start_slowdns() {
    echo -e "${YELLOW}[*] Starting SlowDNS tunnel...${NC}"
    
    # Kill existing slowdns
    pkill -9 slowdns 2>/dev/null
    sleep 1
    
    # Start SlowDNS
    slowdns -udp -dns $DNS_RESOLVER:53 \
            -pubkey $PUBLIC_KEY \
            -server $SERVER_IP \
            -local 127.0.0.1:$TUNNEL_PORT \
            -ns $NAMESERVER \
            -mode client >> $LOG_FILE 2>&1 &
    
    VPN_PID=$!
    echo $VPN_PID > $PID_DIR/slowdns.pid
    
    # Wait for connection
    echo -e "${YELLOW}[*] Waiting for tunnel to establish...${NC}"
    sleep 5
    
    # Check if running
    if ps -p $VPN_PID > /dev/null; then
        echo -e "${GREEN}[✓] SlowDNS tunnel started (PID: $VPN_PID)${NC}"
        return 0
    else
        echo -e "${RED}[✗] Failed to start SlowDNS${NC}"
        return 1
    fi
}

# Start SOCKS5 proxy
start_socks_proxy() {
    echo -e "${YELLOW}[*] Starting SOCKS5 proxy...${NC}"
    
    # Kill existing dns2socks
    pkill -9 dns2socks 2>/dev/null
    
    # Start dns2socks
    dns2socks 127.0.0.1:$TUNNEL_PORT 8.8.8.8:53 127.0.0.1:$SOCKS_PORT >> $LOG_FILE 2>&1 &
    
    SOCKS_PID=$!
    echo $SOCKS_PID > $PID_DIR/socks.pid
    
    sleep 2
    
    if ps -p $SOCKS_PID > /dev/null; then
        echo -e "${GREEN}[✓] SOCKS5 proxy started on 127.0.0.1:$SOCKS_PORT (PID: $SOCKS_PID)${NC}"
        return 0
    else
        echo -e "${RED}[✗] Failed to start SOCKS5 proxy${NC}"
        return 1
    fi
}

# Stop all services
stop_all() {
    echo -e "${YELLOW}[*] Stopping all VPN services...${NC}"
    
    pkill -9 slowdns 2>/dev/null
    pkill -9 socat 2>/dev/null
    pkill -9 dns2socks 2>/dev/null
    
    rm -rf $PID_DIR/* 2>/dev/null
    
    echo -e "${GREEN}[✓] All services stopped${NC}"
}

# Check status
check_status() {
    echo -e "${YELLOW}[*] Checking VPN status...${NC}"
    echo ""
    
    echo -e "${CYAN}Process Status:${NC}"
    
    # Check SlowDNS
    if [ -f $PID_DIR/slowdns.pid ] && ps -p $(cat $PID_DIR/slowdns.pid) >/dev/null; then
        echo -e "  SlowDNS:   ${GREEN}RUNNING${NC} (PID: $(cat $PID_DIR/slowdns.pid))"
    else
        echo -e "  SlowDNS:   ${RED}STOPPED${NC}"
    fi
    
    # Check socat
    if pgrep socat >/dev/null; then
        echo -e "  DNS Forward: ${GREEN}RUNNING${NC} (port $DNS_PORT)"
    else
        echo -e "  DNS Forward: ${RED}STOPPED${NC}"
    fi
    
    # Check dns2socks
    if [ -f $PID_DIR/socks.pid ] && ps -p $(cat $PID_DIR/socks.pid) >/dev/null; then
        echo -e "  SOCKS5:    ${GREEN}RUNNING${NC} (127.0.0.1:$SOCKS_PORT)"
    else
        echo -e "  SOCKS5:    ${RED}STOPPED${NC}"
    fi
    
    # Check ports
    echo ""
    echo -e "${CYAN}Port Status:${NC}"
    for port in $DNS_PORT $TUNNEL_PORT $SOCKS_PORT; do
        if netstat -tulpn 2>/dev/null | grep -q ":$port"; then
            echo -e "  Port $port: ${GREEN}LISTENING${NC}"
        else
            echo -e "  Port $port: ${RED}NOT LISTENING${NC}"
        fi
    done
    
    echo ""
}

# Test connection
test_connection() {
    echo -e "${YELLOW}[*] Testing connections...${NC}"
    echo ""
    
    # Get original IP
    ORIGINAL_IP=$(curl -s ifconfig.me 2>/dev/null || echo "Unknown")
    echo -e "${BLUE}Original IP:${NC} $ORIGINAL_IP"
    echo ""
    
    # Test DNS
    echo -e "${CYAN}[1] Testing DNS (port $DNS_PORT):${NC}"
    if timeout 5 nslookup google.com 127.0.0.1:$DNS_PORT >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ DNS working${NC}"
    else
        echo -e "  ${RED}✗ DNS failed${NC}"
    fi
    
    echo ""
    
    # Test SOCKS5
    echo -e "${CYAN}[2] Testing SOCKS5 proxy:${NC}"
    VPN_IP=$(timeout 10 curl --socks5 127.0.0.1:$SOCKS_PORT -s ifconfig.me 2>/dev/null)
    if [ -n "$VPN_IP" ] && [ "$VPN_IP" != "$ORIGINAL_IP" ]; then
        echo -e "  ${GREEN}✓ SOCKS5 working${NC}"
        echo -e "  ${BLUE}VPN IP:${NC} $VPN_IP"
    elif [ -n "$VPN_IP" ]; then
        echo -e "  ${YELLOW}⚠ SOCKS5 working but IP unchanged${NC}"
        echo -e "  ${BLUE}IP:${NC} $VPN_IP"
    else
        echo -e "  ${RED}✗ SOCKS5 failed${NC}"
    fi
    
    echo ""
}

# Setup for Android proxy
setup_android_proxy() {
    echo -e "${YELLOW}[*] Android Proxy Setup Instructions:${NC}"
    echo ""
    echo "Method 1: WiFi Proxy Settings"
    echo "  1. Go to WiFi Settings"
    echo "  2. Long press your network → Modify"
    echo "  3. Advanced → Proxy → Manual"
    echo "  4. Set:"
    echo "     - Hostname: 127.0.0.1"
    echo "     - Port: $SOCKS_PORT"
    echo "     - Bypass: (leave empty)"
    echo ""
    echo "Method 2: ProxyDroid App (root)"
    echo "  - Install ProxyDroid from Play Store"
    echo "  - Set: SOCKS5, 127.0.0.1, Port: $SOCKS_PORT"
    echo ""
    echo "Method 3: Per-app proxy"
    echo "  - Firefox: Settings → Network Settings"
    echo "  - Chrome: Install Proxy extension"
    echo ""
}

# Start all services
start_vpn() {
    show_banner
    create_pid_dir
    install_deps
    
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    echo -e "${CYAN}          STARTING VPN SERVICES${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    
    # Stop existing first
    stop_all
    sleep 2
    
    # Start services
    if ! start_slowdns; then
        echo -e "${RED}[!] Failed to start tunnel. Check credentials.${NC}"
        exit 1
    fi
    
    start_dns_forwarder
    start_socks_proxy
    
    echo ""
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[✓] VPN SERVICES STARTED${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    
    # Wait a bit
    sleep 3
    
    # Test
    check_status
    test_connection
    
    echo ""
    echo -e "${CYAN}Usage Instructions:${NC}"
    echo "  DNS Server: 127.0.0.1:$DNS_PORT"
    echo "  SOCKS5 Proxy: 127.0.0.1:$SOCKS_PORT"
    echo ""
    echo "Test commands:"
    echo "  nslookup google.com 127.0.0.1:$DNS_PORT"
    echo "  curl --socks5 127.0.0.1:$SOCKS_PORT ifconfig.me"
    echo ""
    
    # Show Android setup
    setup_android_proxy
    
    # Keep script running
    echo -e "${YELLOW}[*] VPN is running. Press Ctrl+C to stop.${NC}"
    echo -e "${YELLOW}[*] Logs: tail -f $LOG_FILE${NC}"
    echo ""
    
    # Show logs in background
    tail -f $LOG_FILE &
    TAIL_PID=$!
    
    # Wait for interrupt
    trap "stop_all; kill $TAIL_PID 2>/dev/null; echo ''; echo 'VPN stopped.'; exit 0" INT TERM
    wait $TAIL_PID
}

# Main menu
show_menu() {
    while true; do
        clear
        show_banner
        
        echo -e "${CYAN}Main Menu:${NC}"
        echo -e "  ${GREEN}1${NC}. Start VPN"
        echo -e "  ${GREEN}2${NC}. Stop VPN"
        echo -e "  ${GREEN}3${NC}. Check Status"
        echo -e "  ${GREEN}4${NC}. Test Connection"
        echo -e "  ${GREEN}5${NC}. View Logs"
        echo -e "  ${GREEN}6${NC}. Install Dependencies"
        echo -e "  ${GREEN}7${NC}. Setup Android Proxy"
        echo -e "  ${GREEN}8${NC}. Exit"
        echo ""
        echo -e "${PURPLE}════════════════════════════════════════════${NC}"
        
        read -p "Select option [1-8]: " choice
        
        case $choice in
            1)
                start_vpn
                ;;
            2)
                stop_all
                read -p "Press Enter to continue..."
                ;;
            3)
                check_status
                read -p "Press Enter to continue..."
                ;;
            4)
                test_connection
                read -p "Press Enter to continue..."
                ;;
            5)
                echo ""
                tail -20 $LOG_FILE 2>/dev/null || echo "No log file found"
                echo ""
                read -p "Press Enter to continue..."
                ;;
            6)
                install_deps
                read -p "Press Enter to continue..."
                ;;
            7)
                setup_android_proxy
                read -p "Press Enter to continue..."
                ;;
            8)
                stop_all
                echo -e "${GREEN}[*] Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Auto-start on boot script
create_boot_script() {
    mkdir -p ~/.termux/boot
    
    cat > ~/.termux/boot/start-vpn << 'BOOTSCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Wait for system to be ready
sleep 30

# Start VPN
/data/data/com.termux/files/home/termux-vpn.sh --start > /data/data/com.termux/files/home/vpn-boot.log 2>&1
BOOTSCRIPT

    chmod +x ~/.termux/boot/start-vpn
    echo -e "${GREEN}[✓] Boot script created${NC}"
}

# Command line arguments
case "$1" in
    start)
        start_vpn
        ;;
    stop)
        stop_all
        ;;
    status)
        check_status
        ;;
    test)
        test_connection
        ;;
    logs)
        tail -f $LOG_FILE
        ;;
    install)
        install_deps
        ;;
    boot)
        create_boot_script
        ;;
    menu)
        show_menu
        ;;
    *)
        # If no arguments, show menu
        show_menu
        ;;
esac
EOF

# Make it executable
chmod +x ~/termux-vpn.sh
