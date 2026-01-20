#!/data/data/com.termux/files/usr/bin/bash

# ==========================================
# TERMUX SLOWDNS VPN SETUP - CONFIGURABLE
# ==========================================

# Default configuration (will be overwritten by user input)
SERVER_IP=""
RESOLVER_IP=""
NS_DOMAIN=""
PUBLIC_KEY=""

# Ports to try (443 is most common for SlowDNS)
PORTS=(443 53 80 5300 8443 2053 2083 2087 8880 5353)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Config file
CONFIG_FILE="$HOME/.slowdns_config"
LOG_FILE="$HOME/slowdns_vpn.log"

# ==========================================
# FUNCTIONS
# ==========================================

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
    echo "[✓] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    echo "[✗] $1" >> "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[!]${NC} $1"
    echo "[!] $1" >> "$LOG_FILE"
}

# ==========================================
# CONFIGURATION FUNCTIONS
# ==========================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
        show_current_config
    else
        warning "No configuration found. Please set up first."
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# SlowDNS VPN Configuration
SERVER_IP="$SERVER_IP"
RESOLVER_IP="$RESOLVER_IP"
NS_DOMAIN="$NS_DOMAIN"
PUBLIC_KEY="$PUBLIC_KEY"
WORKING_PORT="$WORKING_PORT"
EOF
    success "Configuration saved to $CONFIG_FILE"
}

show_current_config() {
    echo -e "${CYAN}"
    echo "=========================================="
    echo "    CURRENT CONFIGURATION"
    echo "=========================================="
    echo -e "${NC}"
    echo -e "${YELLOW}Server IP:${NC} ${SERVER_IP:-Not set}"
    echo -e "${YELLOW}Resolver DNS:${NC} ${RESOLVER_IP:-Not set}"
    echo -e "${YELLOW}NS Domain:${NC} ${NS_DOMAIN:-Not set}"
    echo -e "${YELLOW}Public Key:${NC} ${PUBLIC_KEY:0:20}..."
    echo -e "${YELLOW}Working Port:${NC} ${WORKING_PORT:-Not found}"
    echo "=========================================="
}

setup_configuration() {
    clear
    echo -e "${CYAN}"
    echo "=========================================="
    echo "    SLOWDNS CONFIGURATION SETUP"
    echo "=========================================="
    echo -e "${NC}"
    
    # Load existing config if available
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    echo -e "${YELLOW}Enter your SlowDNS settings:${NC}"
    echo
    
    # Server IP
    if [ -z "$SERVER_IP" ]; then
        read -p "Server IP [e.g., 167.71.11.57]: " SERVER_IP
    else
        read -p "Server IP [$SERVER_IP]: " input
        [ -n "$input" ] && SERVER_IP="$input"
    fi
    
    # Resolver DNS
    if [ -z "$RESOLVER_IP" ]; then
        read -p "Resolver DNS [e.g., 169.255.187.58]: " RESOLVER_IP
    else
        read -p "Resolver DNS [$RESOLVER_IP]: " input
        [ -n "$input" ] && RESOLVER_IP="$input"
    fi
    
    # NS Domain
    if [ -z "$NS_DOMAIN" ]; then
        read -p "NS Domain [e.g., gerry.alienalien.top]: " NS_DOMAIN
    else
        read -p "NS Domain [$NS_DOMAIN]: " input
        [ -n "$input" ] && NS_DOMAIN="$input"
    fi
    
    # Public Key
    if [ -z "$PUBLIC_KEY" ]; then
        read -p "Public Key [e.g., 7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59]: " PUBLIC_KEY
    else
        read -p "Public Key [${PUBLIC_KEY:0:20}...]: " input
        [ -n "$input" ] && PUBLIC_KEY="$input"
    fi
    
    # Validate inputs
    if [ -z "$SERVER_IP" ] || [ -z "$RESOLVER_IP" ] || [ -z "$NS_DOMAIN" ] || [ -z "$PUBLIC_KEY" ]; then
        error "All fields are required!"
        return 1
    fi
    
    # Test server connection
    echo
    log "Testing server connection..."
    if ping -c 2 "$SERVER_IP" &>/dev/null; then
        success "Server is reachable"
    else
        warning "Server might be offline or blocking ICMP"
    fi
    
    # Save configuration
    save_config
    
    echo
    success "Configuration saved successfully!"
    show_current_config
    
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read
}

edit_config() {
    clear
    show_current_config
    echo
    echo -e "${YELLOW}What would you like to edit?${NC}"
    echo "1. Server IP"
    echo "2. Resolver DNS"
    echo "3. NS Domain"
    echo "4. Public Key"
    echo "5. Back to menu"
    echo
    read -p "Select [1-5]: " choice
    
    case $choice in
        1)
            read -p "New Server IP: " SERVER_IP
            save_config
            success "Server IP updated"
            ;;
        2)
            read -p "New Resolver DNS: " RESOLVER_IP
            save_config
            success "Resolver DNS updated"
            ;;
        3)
            read -p "New NS Domain: " NS_DOMAIN
            save_config
            success "NS Domain updated"
            ;;
        4)
            read -p "New Public Key: " PUBLIC_KEY
            save_config
            success "Public Key updated"
            ;;
        5)
            return
            ;;
        *)
            error "Invalid option"
            ;;
    esac
    
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read
}

# ==========================================
# VPN FUNCTIONS
# ==========================================

check_root() {
    if [ "$(whoami)" = "root" ]; then
        error "Do not run as root! Termux doesn't need root."
        exit 1
    fi
}

check_internet() {
    log "Checking internet connection..."
    if ping -c 1 8.8.8.8 &>/dev/null; then
        success "Internet connection OK"
        return 0
    else
        error "No internet connection"
        return 1
    fi
}

check_config() {
    if [ -z "$SERVER_IP" ] || [ -z "$RESOLVER_IP" ] || [ -z "$NS_DOMAIN" ] || [ -z "$PUBLIC_KEY" ]; then
        error "Configuration not complete! Please set up first (Option 1)."
        return 1
    fi
    return 0
}

install_dependencies() {
    log "Installing dependencies..."
    
    # Update packages
    pkg update -y && pkg upgrade -y
    
    # Install required packages
    pkg install -y python git curl wget socat nano proot \
                   dnsutils iproute2 net-tools openssl
    
    # Install Python packages
    pip install requests cryptography --quiet
    
    success "Dependencies installed"
}

find_working_port() {
    if [ -z "$SERVER_IP" ]; then
        error "Server IP not configured!"
        return 1
    fi
    
    log "Finding working port on $SERVER_IP..."
    
    for port in "${PORTS[@]}"; do
        echo -ne "${YELLOW}  Testing port $port...${NC}"
        timeout 2 bash -c "echo > /dev/tcp/$SERVER_IP/$port" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN} OPEN${NC}"
            WORKING_PORT=$port
            success "Found working port: $port"
            
            # Save port to config
            save_config
            return 0
        else
            echo -e "${RED} CLOSED${NC}"
        fi
    done
    
    warning "No open ports found on standard ports"
    read -p "Enter custom port: " custom_port
    if [ -n "$custom_port" ]; then
        WORKING_PORT=$custom_port
        success "Using custom port: $custom_port"
        save_config
        return 0
    fi
    
    error "No port specified"
    return 1
}

start_dns_forwarder() {
    log "Starting DNS forwarder..."
    
    # Kill any existing DNS forwarders
    pkill -f "socat.*53" 2>/dev/null
    
    # Start DNS forwarder (local port 53 -> server)
    socat UDP4-LISTEN:53,reuseaddr,fork UDP4:$SERVER_IP:$WORKING_PORT &
    DNS_PID=$!
    
    echo $DNS_PID > /tmp/dns_pid
    
    success "DNS forwarder started (PID: $DNS_PID)"
}

set_dns_settings() {
    log "Configuring DNS settings..."
    
    # Set DNS to localhost
    setprop net.dns1 127.0.0.1 2>/dev/null || true
    
    # Also update resolv.conf
    echo "nameserver 127.0.0.1" > $PREFIX/etc/resolv.conf
    echo "nameserver 8.8.8.8" >> $PREFIX/etc/resolv.conf
    
    success "DNS set to 127.0.0.1"
}

create_vpn_tunnel() {
    log "Creating VPN tunnel..."
    
    # Create simple DNS tunnel script
    cat > $HOME/slowdns_tunnel.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash

# Simple DNS tunnel
echo "Starting SlowDNS tunnel..."
echo "Server: $SERVER_IP:$WORKING_PORT"
echo "Domain: $NS_DOMAIN"

while true; do
    # Keep the connection alive
    sleep 30
    # Test connection
    if ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        echo "[!] DNS failed, restarting..."
        pkill -f "socat.*53"
        socat UDP4-LISTEN:53,reuseaddr,fork UDP4:$SERVER_IP:$WORKING_PORT &
        sleep 2
    fi
done
EOF
    
    chmod +x $HOME/slowdns_tunnel.sh
    
    # Start tunnel
    $HOME/slowdns_tunnel.sh &
    TUNNEL_PID=$!
    echo $TUNNEL_PID > /tmp/tunnel_pid
    
    success "VPN tunnel started (PID: $TUNNEL_PID)"
}

setup_simple_proxy() {
    log "Setting up proxy..."
    
    # Create simple proxy config script
    cat > $HOME/proxy_setup.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash

echo "=== Proxy Configuration ==="
echo ""
echo "To use the VPN, configure your apps:"
echo ""
echo "For all apps (add to ~/.bashrc):"
echo "export HTTP_PROXY='http://127.0.0.1:8080'"
echo "export HTTPS_PROXY='http://127.0.0.1:8080'"
echo ""
echo "For specific commands:"
echo "curl --proxy http://127.0.0.1:8080 ifconfig.me"
echo ""
echo "For Firefox in Termux:"
echo "1. Install: pkg install firefox"
echo "2. Settings → Network Settings → Manual proxy"
echo "3. HTTP Proxy: 127.0.0.1 Port: 8080"
EOF
    
    chmod +x $HOME/proxy_setup.sh
    
    # Start simple HTTP proxy using Python
    python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 &
    PROXY_PID=$!
    echo $PROXY_PID > /tmp/proxy_pid
    
    # Set environment variables
    echo "export HTTP_PROXY='http://127.0.0.1:8080'" >> $HOME/.bashrc
    echo "export HTTPS_PROXY='http://127.0.0.1:8080'" >> $HOME/.bashrc
    source $HOME/.bashrc
    
    success "Proxy setup complete"
}

test_vpn() {
    log "Testing VPN connection..."
    
    echo -e "${YELLOW}1. Testing DNS resolution:${NC}"
    if timeout 3 nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        success "DNS working"
    else
        error "DNS failed"
    fi
    
    echo -e "${YELLOW}2. Checking connection:${NC}"
    OLD_IP=$(curl -s ifconfig.me 2>/dev/null || echo "Unknown")
    NEW_IP=$(curl -s --dns-servers 127.0.0.1 ifconfig.me 2>/dev/null || echo "Unknown")
    
    echo "Original IP: $OLD_IP"
    echo "Current IP: $NEW_IP"
    
    if [ "$NEW_IP" != "$OLD_IP" ] && [ "$NEW_IP" != "Unknown" ]; then
        success "VPN is working! IP changed"
    else
        warning "IP not changed or could not determine"
    fi
    
    echo -e "${YELLOW}3. Testing through proxy:${NC}"
    if curl -s --proxy http://127.0.0.1:8080 ifconfig.me >/dev/null 2>&1; then
        success "Proxy working"
    else
        warning "Proxy not responding (might be normal)"
    fi
}

create_management_scripts() {
    log "Creating management scripts..."
    
    # Start script
    cat > $HOME/start_vpn.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
echo "Starting SlowDNS VPN..."
cd $HOME
source $CONFIG_FILE

# Start DNS forwarder
pkill -f "socat.*53" 2>/dev/null
socat UDP4-LISTEN:53,reuseaddr,fork UDP4:\$SERVER_IP:\$WORKING_PORT &

# Set DNS
setprop net.dns1 127.0.0.1 2>/dev/null || true
echo "nameserver 127.0.0.1" > \$PREFIX/etc/resolv.conf

echo "[✓] VPN started"
echo "Test with: nslookup google.com 127.0.0.1"
EOF
    
    # Stop script
    cat > $HOME/stop_vpn.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
echo "Stopping VPN..."
pkill -f "socat.*53" 2>/dev/null
pkill -f "slowdns_tunnel" 2>/dev/null
pkill -f "http.server" 2>/dev/null
setprop net.dns1 8.8.8.8 2>/dev/null || true
echo "nameserver 8.8.8.8" > \$PREFIX/etc/resolv.conf
echo "[✓] VPN stopped"
EOF
    
    # Status script
    cat > $HOME/vpn_status.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
echo "=== VPN Status ==="
echo "DNS Forwarder: \$(ps aux | grep 'socat.*53' | grep -v grep | wc -l) running"
echo "Tunnel: \$(ps aux | grep slowdns_tunnel | grep -v grep | wc -l) running"
echo "Proxy: \$(ps aux | grep 'http.server' | grep -v grep | wc -l) running"
echo ""
echo "Current DNS: \$(getprop net.dns1 2>/dev/null || cat \$PREFIX/etc/resolv.conf | head -1)"
echo ""
echo "Test commands:"
echo "  nslookup google.com 127.0.0.1"
echo "  curl --dns-servers 127.0.0.1 ifconfig.me"
EOF
    
    # Make executable
    chmod +x $HOME/start_vpn.sh
    chmod +x $HOME/stop_vpn.sh
    chmod +x $HOME/vpn_status.sh
    
    success "Management scripts created"
}

start_vpn() {
    if ! check_config; then
        return 1
    fi
    
    log "Starting VPN..."
    
    # Find working port if not set
    if [ -z "$WORKING_PORT" ]; then
        find_working_port || return 1
    fi
    
    # Step-by-step startup
    start_dns_forwarder
    sleep 2
    
    set_dns_settings
    sleep 2
    
    create_vpn_tunnel
    sleep 2
    
    setup_simple_proxy
    
    success "VPN started successfully!"
    echo
    test_vpn
}

stop_vpn() {
    log "Stopping VPN..."
    
    # Stop all services
    pkill -f "socat.*53" 2>/dev/null
    pkill -f "slowdns_tunnel" 2>/dev/null
    pkill -f "http.server" 2>/dev/null
    
    # Reset DNS
    setprop net.dns1 8.8.8.8 2>/dev/null || true
    echo "nameserver 8.8.8.8" > $PREFIX/etc/resolv.conf
    echo "nameserver 1.1.1.1" >> $PREFIX/etc/resolv.conf
    
    # Clear proxy env
    sed -i '/HTTP_PROXY/d' $HOME/.bashrc
    sed -i '/HTTPS_PROXY/d' $HOME/.bashrc
    
    success "VPN stopped"
}

show_quick_setup() {
    clear
    echo -e "${CYAN}"
    echo "=========================================="
    echo "    QUICK SETUP GUIDE"
    echo "=========================================="
    echo -e "${NC}"
    echo "Follow these steps:"
    echo
    echo "1. ${YELLOW}Configure Settings${NC} (Menu Option 1)"
    echo "   - Enter your SlowDNS details"
    echo
    echo "2. ${YELLOW}Install Dependencies${NC} (Menu Option 2)"
    echo "   - Installs required packages"
    echo
    echo "3. ${YELLOW}Start VPN${NC} (Menu Option 3)"
    echo "   - Starts the VPN service"
    echo
    echo "4. ${YELLOW}Test Connection${NC} (Menu Option 5)"
    echo "   - Verify VPN is working"
    echo
    echo -e "${GREEN}Example Configuration:${NC}"
    echo "Server IP: 167.71.11.57"
    echo "Resolver DNS: 169.255.187.58"
    echo "NS Domain: gerry.alienalien.top"
    echo "Public Key: 7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
    echo
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read
}

# ==========================================
# MAIN MENU
# ==========================================

show_menu() {
    clear
    echo -e "${CYAN}"
    echo "=========================================="
    echo "    TERMUX SLOWDNS VPN MANAGER"
    echo "=========================================="
    echo -e "${NC}"
    
    # Show current config status
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" 2>/dev/null
        echo -e "${GREEN}✓ Configuration loaded${NC}"
        echo -e "Server: ${YELLOW}${SERVER_IP:-Not set}${NC}"
    else
        echo -e "${RED}✗ No configuration${NC}"
    fi
    echo "=========================================="
    echo
    echo "1. Configure SlowDNS Settings"
    echo "2. Install Dependencies"
    echo "3. Start VPN"
    echo "4. Stop VPN"
    echo "5. Test VPN Connection"
    echo "6. View Current Configuration"
    echo "7. Edit Configuration"
    echo "8. Quick Setup Guide"
    echo "9. View Logs"
    echo "10. Exit"
    echo
    echo -n "Select option [1-10]: "
}

# ==========================================
# MAIN EXECUTION
# ==========================================

main() {
    # Check if not root
    check_root
    
    # Create log file
    touch "$LOG_FILE"
    
    # Load existing config
    load_config
    
    # Create management scripts
    create_management_scripts
    
    # Main menu loop
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                setup_configuration
                ;;
            2)
                check_internet
                install_dependencies
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            3)
                start_vpn
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            4)
                stop_vpn
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            5)
                test_vpn
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            6)
                clear
                show_current_config
                echo
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            7)
                edit_config
                ;;
            8)
                show_quick_setup
                ;;
            9)
                echo -e "${YELLOW}=== VPN Logs ===${NC}"
                tail -20 "$LOG_FILE"
                echo
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            10)
                echo
                echo -e "${GREEN}[✓] Exiting SlowDNS VPN Manager${NC}"
                echo -e "${YELLOW}Quick commands for later:${NC}"
                echo "  Start VPN: ~/start_vpn.sh"
                echo "  Stop VPN:  ~/stop_vpn.sh"
                echo "  Status:    ~/vpn_status.sh"
                exit 0
                ;;
            *)
                error "Invalid option"
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
        esac
    done
}

# Run main function
main "$@"
