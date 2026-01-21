cat > ~/vpn-full.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash

# ============================================
# COMPLETE SLOWDNS VPN SCRIPT FOR TERMUX
# ============================================
# Author: VPN Setup Script
# Version: 2.0
# ============================================

# Colors for output
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
DNS_PORT="5353"           # High port to avoid permission issues
TUNNEL_PORT="5300"        # Internal tunnel port
SOCKS_PORT="1080"         # SOCKS5 proxy port
HTTP_PORT="8080"          # HTTP proxy port (optional)
LOG_FILE="/data/data/com.termux/files/home/vpn.log"
PID_DIR="/tmp/vpn_pids"
CONFIG_FILE="/data/data/com.termux/files/home/.vpn_config"

# Banner
print_banner() {
    clear
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════╗"
    echo "║        SLOWDNS VPN FOR TERMUX            ║"
    echo "║          Complete Edition v2.0           ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${CYAN}Server: ${GREEN}$SERVER_IP${NC}"
    echo -e "${CYAN}DNS: ${GREEN}$DNS_RESOLVER${NC}"
    echo -e "${CYAN}Domain: ${GREEN}$NAMESERVER${NC}"
    echo -e "${CYAN}Public Key: ${GREEN}${PUBLIC_KEY:0:16}...${NC}"
    echo "════════════════════════════════════════════"
}

# Check and install dependencies
install_dependencies() {
    echo -e "${YELLOW}[*] Checking dependencies...${NC}"
    
    local deps=("socat" "curl" "wget" "proxychains-ng" "nmap" "net-tools")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}[*] Installing missing packages: ${missing[*]}${NC}"
        pkg update -y
        pkg install -y ${missing[*]}
        
        # Install dns2socks separately
        if ! command -v dns2socks &> /dev/null; then
            echo -e "${YELLOW}[*] Installing dns2socks...${NC}"
            pkg install dns2socks -y
        fi
    else
        echo -e "${GREEN}[✓] All dependencies installed${NC}"
    fi
}

# Install slowdns binary
install_slowdns() {
    echo -e "${YELLOW}[*] Checking SlowDNS binary...${NC}"
    
    if ! command -v slowdns &> /dev/null; then
        echo -e "${YELLOW}[*] Downloading SlowDNS...${NC}"
        
        # Try multiple sources
        if wget -q https://github.com/foomurf/slowdns/releases/latest/download/slowdns-android-arm64 -O $PREFIX/bin/slowdns; then
            echo -e "${GREEN}[✓] Downloaded from GitHub releases${NC}"
        elif wget -q https://raw.githubusercontent.com/foomurf/slowdns/main/slowdns -O $PREFIX/bin/slowdns; then
            echo -e "${GREEN}[✓] Downloaded from main branch${NC}"
        else
            echo -e "${RED}[!] Download failed, trying to build from source...${NC}"
            pkg install clang make -y
            git clone https://github.com/foomurf/slowdns /tmp/slowdns-src
            cd /tmp/slowdns-src
            gcc -o slowdns slowdns.c -static
            cp slowdns $PREFIX/bin/
            cd ~
            rm -rf /tmp/slowdns-src
        fi
        
        chmod +x $PREFIX/bin/slowdns
        echo -e "${GREEN}[✓] SlowDNS installed${NC}"
    else
        echo -e "${GREEN}[✓] SlowDNS already installed${NC}"
    fi
}

# Create directories and config
setup_environment() {
    echo -e "${YELLOW}[*] Setting up environment...${NC}"
    
    # Create directories
    mkdir -p $PID_DIR
    mkdir -p ~/.proxychains
    
    # Create config file
    cat > $CONFIG_FILE << CONFIG
# VPN Configuration
SERVER_IP=$SERVER_IP
DNS_RESOLVER=$DNS_RESOLVER
NAMESERVER=$NAMESERVER
PUBLIC_KEY=$PUBLIC_KEY
DNS_PORT=$DNS_PORT
TUNNEL_PORT=$TUNNEL_PORT
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
CONFIG
    
    # Create proxychains config
    cat > ~/.proxychains/proxychains.conf << PROXYCONF
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 127.0.0.1 $SOCKS_PORT
http 127.0.0.1 $HTTP_PORT
PROXYCONF
    
    echo -e "${GREEN}[✓] Environment setup complete${NC}"
}

# Start DNS forwarder
start_dns_forwarder() {
    echo -e "${YELLOW}[*] Starting DNS forwarder on port $DNS_PORT...${NC}"
    
    # Kill existing socat processes
    pkill -9 socat 2>/dev/null
    
    # Start UDP forwarder
    socat UDP4-LISTEN:$DNS_PORT,fork TCP4:127.0.0.1:$TUNNEL_PORT >/dev/null 2>&1 &
    echo $! > $PID_DIR/socat_udp.pid
    
    # Start TCP forwarder
    socat TCP4-LISTEN:$DNS_PORT,fork,reuseaddr TCP4:127.0.0.1:$TUNNEL_PORT >/dev/null 2>&1 &
    echo $! > $PID_DIR/socat_tcp.pid
    
    echo -e "${GREEN}[✓] DNS forwarder started on port $DNS_PORT${NC}"
}

# Start SlowDNS tunnel
start_slowdns_tunnel() {
    echo -e "${YELLOW}[*] Starting SlowDNS tunnel...${NC}"
    
    # Kill existing slowdns
    pkill -9 slowdns 2>/dev/null
    sleep 1
    
    # Start SlowDNS with logging
    slowdns -udp -dns $DNS_RESOLVER:53 \
            -pubkey $PUBLIC_KEY \
            -server $SERVER_IP \
            -local 127.0.0.1:$TUNNEL_PORT \
            -ns $NAMESERVER \
            -mode client \
            -loglevel info >> $LOG_FILE 2>&1 &
    
    local pid=$!
    echo $pid > $PID_DIR/slowdns.pid
    
    # Wait for connection
    echo -e "${YELLOW}[*] Waiting for tunnel to establish...${NC}"
    sleep 3
    
    if ps -p $pid > /dev/null; then
        echo -e "${GREEN}[✓] SlowDNS tunnel started (PID: $pid)${NC}"
        return 0
    else
        echo -e "${RED}[!] Failed to start SlowDNS tunnel${NC}"
        return 1
    fi
}

# Start SOCKS5 proxy
start_socks_proxy() {
    echo -e "${YELLOW}[*] Starting SOCKS5 proxy...${NC}"
    
    pkill -9 dns2socks 2>/dev/null
    
    dns2socks 127.0.0.1:$TUNNEL_PORT 8.8.8.8:53 127.0.0.1:$SOCKS_PORT >> $LOG_FILE 2>&1 &
    local pid=$!
    echo $pid > $PID_DIR/socks.pid
    
    sleep 2
    
    if ps -p $pid > /dev/null; then
        echo -e "${GREEN}[✓] SOCKS5 proxy started on 127.0.0.1:$SOCKS_PORT${NC}"
        return 0
    else
        echo -e "${RED}[!] Failed to start SOCKS5 proxy${NC}"
        return 1
    fi
}

# Start HTTP proxy (optional)
start_http_proxy() {
    echo -e "${YELLOW}[*] Starting HTTP proxy...${NC}"
    
    if ! command -v tinyproxy &> /dev/null; then
        echo -e "${YELLOW}[*] Installing tinyproxy...${NC}"
        pkg install tinyproxy -y
    fi
    
    # Create tinyproxy config
    cat > /data/data/com.termux/files/usr/etc/tinyproxy/tinyproxy.conf << TINYPROXY
User nobody
Group nobody
Port $HTTP_PORT
Timeout 600
DefaultErrorFile "/data/data/com.termux/files/usr/share/tinyproxy/default.html"
StatFile "/data/data/com.termux/files/usr/share/tinyproxy/stats.html"
Logfile "$LOG_FILE"
LogLevel Info
PidFile "$PID_DIR/tinyproxy.pid"
MaxClients 100
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0
ViaProxyName "tinyproxy"
ConnectPort 443
ConnectPort 563
Allow 127.0.0.1
Upstream socks5 127.0.0.1:$SOCKS_PORT
TINYPROXY
    
    pkill -9 tinyproxy 2>/dev/null
    tinyproxy -c /data/data/com.termux/files/usr/etc/tinyproxy/tinyproxy.conf
    
    sleep 2
    if pgrep tinyproxy > /dev/null; then
        echo -e "${GREEN}[✓] HTTP proxy started on 127.0.0.1:$HTTP_PORT${NC}"
    else
        echo -e "${RED}[!] Failed to start HTTP proxy${NC}"
    fi
}

# Set system DNS (requires root or specific conditions)
set_system_dns() {
    echo -e "${YELLOW}[*] Attempting to set system DNS...${NC}"
    
    # Try to set DNS via setprop
    setprop net.dns1 127.0.0.1 2>/dev/null && echo -e "${GREEN}[✓] Set net.dns1 to 127.0.0.1${NC}" || echo -e "${YELLOW}[!] Could not set net.dns1${NC}"
    setprop net.dns2 127.0.0.1 2>/dev/null && echo -e "${GREEN}[✓] Set net.dns2 to 127.0.0.1${NC}" || echo -e "${YELLOW}[!] Could not set net.dns2${NC}"
    
    # Alternative method for some devices
    if [ -w /etc/resolv.conf ]; then
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        echo -e "${GREEN}[✓] Updated /etc/resolv.conf${NC}"
    fi
}

# Test connection
test_connection() {
    echo -e "${YELLOW}[*] Testing connections...${NC}"
    echo ""
    
    # Test 1: DNS resolution
    echo -e "${BLUE}[1] Testing DNS resolution:${NC}"
    if timeout 5 nslookup google.com 127.0.0.1:$DNS_PORT >/dev/null 2>&1; then
        echo -e "   ${GREEN}✓ DNS working on port $DNS_PORT${NC}"
    else
        echo -e "   ${RED}✗ DNS failed on port $DNS_PORT${NC}"
    fi
    
    # Test 2: SOCKS5 proxy
    echo -e "${BLUE}[2] Testing SOCKS5 proxy:${NC}"
    if timeout 5 curl --socks5 127.0.0.1:$SOCKS_PORT -s ifconfig.me >/dev/null 2>&1; then
        echo -e "   ${GREEN}✓ SOCKS5 proxy working${NC}"
    else
        echo -e "   ${RED}✗ SOCKS5 proxy failed${NC}"
    fi
    
    # Test 3: HTTP proxy (if enabled)
    if pgrep tinyproxy > /dev/null; then
        echo -e "${BLUE}[3] Testing HTTP proxy:${NC}"
        if timeout 5 curl --proxy http://127.0.0.1:$HTTP_PORT -s ifconfig.me >/dev/null 2>&1; then
            echo -e "   ${GREEN}✓ HTTP proxy working${NC}"
        else
            echo -e "   ${RED}✗ HTTP proxy failed${NC}"
        fi
    fi
    
    # Test 4: Proxychains
    echo -e "${BLUE}[4] Testing Proxychains:${NC}"
    if timeout 5 proxychains curl -s ifconfig.me >/dev/null 2>&1; then
        echo -e "   ${GREEN}✓ Proxychains working${NC}"
    else
        echo -e "   ${RED}✗ Proxychains failed${NC}"
    fi
}

# Show status
show_status() {
    echo ""
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           VPN STATUS${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    
    # Process status
    echo -e "${YELLOW}Processes:${NC}"
    if [ -f $PID_DIR/slowdns.pid ] && ps -p $(cat $PID_DIR/slowdns.pid) >/dev/null; then
        echo -e "  SlowDNS:   ${GREEN}RUNNING${NC} (PID: $(cat $PID_DIR/slowdns.pid))"
    else
        echo -e "  SlowDNS:   ${RED}STOPPED${NC}"
    fi
    
    if [ -f $PID_DIR/socks.pid ] && ps -p $(cat $PID_DIR/socks.pid) >/dev/null; then
        echo -e "  SOCKS5:    ${GREEN}RUNNING${NC} (127.0.0.1:$SOCKS_PORT)"
    else
        echo -e "  SOCKS5:    ${RED}STOPPED${NC}"
    fi
    
    if pgrep socat >/dev/null; then
        echo -e "  DNS Forward: ${GREEN}RUNNING${NC} (port $DNS_PORT)"
    else
        echo -e "  DNS Forward: ${RED}STOPPED${NC}"
    fi
    
    if pgrep tinyproxy >/dev/null; then
        echo -e "  HTTP Proxy:  ${GREEN}RUNNING${NC} (127.0.0.1:$HTTP_PORT)"
    else
        echo -e "  HTTP Proxy:  ${RED}STOPPED${NC}"
    fi
    
    # Connection info
    echo ""
    echo -e "${YELLOW}Connection Info:${NC}"
    echo -e "  External IP: $(curl --socks5 127.0.0.1:$SOCKS_PORT -s ifconfig.me 2>/dev/null || echo 'Unknown')"
    
    # Port listening
    echo ""
    echo -e "${YELLOW}Listening Ports:${NC}"
    netstat -tulpn 2>/dev/null | grep -E "($DNS_PORT|$SOCKS_PORT|$HTTP_PORT|$TUNNEL_PORT)" || echo "  No VPN ports listening"
}

# Show usage instructions
show_instructions() {
    echo ""
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           USAGE INSTRUCTIONS${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    
    echo -e "${YELLOW}For Termux Apps:${NC}"
    echo "  export http_proxy=socks5://127.0.0.1:$SOCKS_PORT"
    echo "  export https_proxy=socks5://127.0.0.1:$SOCKS_PORT"
    echo ""
    echo -e "${YELLOW}For Android Apps:${NC}"
    echo "  1. WiFi Settings → Modify Network → Advanced"
    echo "  2. Proxy: Manual"
    echo "  3. Hostname: 127.0.0.1"
    echo "  4. Port: $SOCKS_PORT (SOCKS5) or $HTTP_PORT (HTTP)"
    echo ""
    echo -e "${YELLOW}Browser Settings:${NC}"
    echo "  Firefox: Settings → Network Settings → Configure Proxy"
    echo "  Chrome: Use SwitchyOmega extension"
    echo ""
    echo -e "${YELLOW}Test Commands:${NC}"
    echo "  curl --socks5 127.0.0.1:$SOCKS_PORT ifconfig.me"
    echo "  proxychains curl ifconfig.me"
    echo "  nslookup google.com 127.0.0.1:$DNS_PORT"
}

# Stop all services
stop_services() {
    echo -e "${YELLOW}[*] Stopping all VPN services...${NC}"
    
    pkill -9 slowdns 2>/dev/null
    pkill -9 socat 2>/dev/null
    pkill -9 dns2socks 2>/dev/null
    pkill -9 tinyproxy 2>/dev/null
    
    rm -rf $PID_DIR/*.pid 2>/dev/null
    
    # Reset DNS
    setprop net.dns1 "" 2>/dev/null
    setprop net.dns2 "" 2>/dev/null
    
    echo -e "${GREEN}[✓] All services stopped${NC}"
}

# Log viewer
show_logs() {
    echo -e "${YELLOW}[*] Showing last 20 lines of log:${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    tail -20 $LOG_FILE 2>/dev/null || echo "No log file found"
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
}

# Main menu
show_menu() {
    while true; do
        clear
        print_banner
        
        echo -e "${CYAN}Main Menu:${NC}"
        echo -e "  ${GREEN}1${NC}. Start VPN Tunnel"
        echo -e "  ${GREEN}2${NC}. Stop VPN Tunnel"
        echo -e "  ${GREEN}3${NC}. Check Status"
        echo -e "  ${GREEN}4${NC}. Test Connection"
        echo -e "  ${GREEN}5${NC}. Show Logs"
        echo -e "  ${GREEN}6${NC}. Install/Update"
        echo -e "  ${GREEN}7${NC}. Show Instructions"
        echo -e "  ${GREEN}8${NC}. Exit"
        echo ""
        echo -e "${PURPLE}════════════════════════════════════════════${NC}"
        
        read -p "Select option [1-8]: " choice
        
        case $choice in
            1)
                echo ""
                start_vpn
                echo ""
                read -p "Press Enter to continue..."
                ;;
            2)
                echo ""
                stop_services
                echo ""
                read -p "Press Enter to continue..."
                ;;
            3)
                echo ""
                show_status
                echo ""
                read -p "Press Enter to continue..."
                ;;
            4)
                echo ""
                test_connection
                echo ""
                read -p "Press Enter to continue..."
                ;;
            5)
                echo ""
                show_logs
                echo ""
                read -p "Press Enter to continue..."
                ;;
            6)
                echo ""
                install_dependencies
                install_slowdns
                setup_environment
                echo ""
                read -p "Press Enter to continue..."
                ;;
            7)
                echo ""
                show_instructions
                echo ""
                read -p "Press Enter to continue..."
                ;;
            8)
                echo -e "${GREEN}[*] Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Start VPN (main function)
start_vpn() {
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           STARTING VPN TUNNEL${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════${NC}"
    
    # Stop existing services first
    stop_services
    sleep 2
    
    # Setup
    install_dependencies
    install_slowdns
    setup_environment
    
    # Start services
    start_dns_forwarder
    if ! start_slowdns_tunnel; then
        echo -e "${RED}[!] Failed to establish tunnel. Check logs.${NC}"
        return 1
    fi
    
    if ! start_socks_proxy; then
        echo -e "${RED}[!] Failed to start SOCKS proxy${NC}"
    fi
    
    start_http_proxy
    set_system_dns
    
    # Test
    echo ""
    test_connection
    show_status
    show_instructions
}

# Auto-start if no arguments
if [ $# -eq 0 ]; then
    show_menu
else
    case $1 in
        start)
            start_vpn
            ;;
        stop)
            stop_services
            ;;
        status)
            show_status
            ;;
        test)
            test_connection
            ;;
        logs)
            show_logs
            ;;
        install)
            install_dependencies
            install_slowdns
            setup_environment
            ;;
        menu)
            show_menu
            ;;
        *)
            echo "Usage: $0 {start|stop|status|test|logs|install|menu}"
            echo ""
            echo "Commands:"
            echo "  start   - Start VPN tunnel"
            echo "  stop    - Stop all services"
            echo "  status  - Show status"
            echo "  test    - Test connection"
            echo "  logs    - Show logs"
            echo "  install - Install dependencies"
            echo "  menu    - Show interactive menu"
            ;;
    esac
fi
EOF

chmod +x ~/vpn-full.sh
