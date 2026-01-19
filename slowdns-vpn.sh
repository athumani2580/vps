#!/data/data/com.termux/files/usr/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CONFIG_FILE="$HOME/.slowdns-config"
SLOWDNS_DIR="$HOME/slowdns"
VERSION="2.0"

# Download mirrors (try in order)
DOWNLOAD_SOURCES=(
    "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-client"
    "https://github.com/athumani2580/vps/raw/main/slowdns/sldns-client"
    "https://cdn.jsdelivr.net/gh/athumani2580/vps/slowdns/sldns-client"
    "https://gitlab.com/athumani2580/vps/-/raw/main/slowdns/sldns-client"
)

PUBKEY_SOURCES=(
    "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
    "https://github.com/athumani2580/vps/raw/main/slowdns/server.pub"
    "https://cdn.jsdelivr.net/gh/athumani2580/vps/slowdns/server.pub"
    "https://gitlab.com/athumani2580/vps/-/raw/main/slowdns/server.pub"
)

# Default values
VPS_IP=""
NAMESERVER=""
SLOWDNS_PORT="5300"
LOCAL_PORT="2222"
SOCKS_PORT="1080"
MTU_SIZE="1200"

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "┌────────────────────────────────────────────┐"
    echo "│     TERMUX SLOWDNS VPN (FIXED)             │"
    echo "│           Version $VERSION                      │"
    echo "└────────────────────────────────────────────┘"
    echo -e "${NC}"
}

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

check_internet() {
    print_info "Checking internet connection..."
    if ping -c 2 8.8.8.8 &> /dev/null; then
        print_status "Internet connection OK"
        return 0
    else
        print_error "No internet connection"
        return 1
    fi
}

download_with_fallback() {
    local file_name="$1"
    local sources=("${!2}")
    local output_path="$3"
    
    print_info "Downloading $file_name..."
    
    for source in "${sources[@]}"; do
        print_info "Trying: $(echo $source | cut -d'/' -f3)"
        if wget --timeout=10 --tries=2 -q "$source" -O "$output_path"; then
            print_status "Downloaded from: $(echo $source | cut -d'/' -f3)"
            return 0
        fi
    done
    
    print_error "All download sources failed"
    return 1
}

download_files_fixed() {
    print_info "Downloading SlowDNS files (with fallback)..."
    
    mkdir -p "$SLOWDNS_DIR"
    cd "$SLOWDNS_DIR"
    
    # Check if files already exist
    if [ -f "sldns-client" ] && [ -f "server.pub" ]; then
        print_status "Files already exist, skipping download"
        chmod +x sldns-client 2>/dev/null
        return 0
    fi
    
    # Download sldns-client
    if [ ! -f "sldns-client" ]; then
        download_with_fallback "sldns-client" DOWNLOAD_SOURCES[@] "sldns-client"
        if [ $? -eq 0 ]; then
            chmod +x sldns-client
            print_status "sldns-client ready"
        else
            # Try alternative method - create from binary dump
            print_warning "Creating sldns-client from alternative source..."
            create_client_from_alternative
        fi
    fi
    
    # Download server.pub
    if [ ! -f "server.pub" ]; then
        download_with_fallback "server.pub" PUBKEY_SOURCES[@] "server.pub"
        if [ $? -ne 0 ]; then
            print_warning "Creating dummy server.pub..."
            echo "-----BEGIN PUBLIC KEY-----" > server.pub
            echo "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwU2kU7kQ7Nq7n8KzJm9X" >> server.pub
            echo "YOUR_PUBLIC_KEY_HERE" >> server.pub
            echo "-----END PUBLIC KEY-----" >> server.pub
        fi
    fi
    
    # Create a simple test client if all downloads fail
    if [ ! -f "sldns-client" ]; then
        print_warning "Creating minimal test client..."
        cat > sldns-client << 'EOF'
#!/bin/bash
echo "Test SlowDNS client - Manual setup required"
echo "Please download actual sldns-client manually:"
echo "1. Visit: https://github.com/athumani2580/vps/tree/main/slowdns"
echo "2. Download sldns-client"
echo "3. Copy to: $HOME/slowdns/"
echo "4. Run: chmod +x sldns-client"
exit 1
EOF
        chmod +x sldns-client
    fi
    
    print_status "File setup complete"
    return 0
}

create_client_from_alternative() {
    print_info "Creating client from binary data..."
    
    # Try to download from alternative repositories
    ALTERNATIVE_SOURCES=(
        "https://raw.githubusercontent.com/xchwarze/slowdns-tunnel/master/client"
        "https://raw.githubusercontent.com/bleach2077/slowdns/main/client"
    )
    
    for source in "${ALTERNATIVE_SOURCES[@]}"; do
        print_info "Trying alternative: $(echo $source | cut -d'/' -f4)"
        if wget --timeout=10 -q "$source" -O sldns-client; then
            chmod +x sldns-client
            print_status "Alternative client downloaded"
            return 0
        fi
    done
    
    return 1
}

manual_download_instructions() {
    print_warning "MANUAL DOWNLOAD REQUIRED"
    echo ""
    echo -e "${YELLOW}Follow these steps:${NC}"
    echo "1. Open browser on your phone"
    echo "2. Visit: https://github.com/athumani2580/vps"
    echo "3. Navigate to: slowdns/sldns-client"
    echo "4. Click 'Raw' button"
    echo "5. Save file as 'sldns-client'"
    echo "6. Visit: slowdns/server.pub"
    echo "7. Click 'Raw' button"
    echo "8. Save file as 'server.pub'"
    echo ""
    echo -e "${CYAN}After downloading:${NC}"
    echo "1. Copy files to: /storage/emulated/0/Download/"
    echo "2. In Termux, run:"
    echo "   cp ~/storage/downloads/sldns-client ~/slowdns/"
    echo "   cp ~/storage/downloads/server.pub ~/slowdns/"
    echo "   chmod +x ~/slowdns/sldns-client"
    echo ""
    read -p "Press Enter after downloading files..."
    
    if [ -f "$SLOWDNS_DIR/sldns-client" ] && [ -f "$SLOWDNS_DIR/server.pub" ]; then
        chmod +x "$SLOWDNS_DIR/sldns-client"
        print_status "Manual files installed successfully"
        return 0
    else
        print_error "Files not found in slowdns directory"
        return 1
    fi
}

setup_config() {
    print_banner
    echo -e "${YELLOW}=== Configuration Setup ===${NC}"
    echo ""
    
    echo -e "${CYAN}Enter your VPS details:${NC}"
    
    read -p "VPS IP Address: " VPS_IP
    while [[ -z "$VPS_IP" ]]; do
        print_error "VPS IP cannot be empty"
        read -p "VPS IP Address: " VPS_IP
    done
    
    read -p "Nameserver (e.g., dns.example.com): " NAMESERVER
    while [[ -z "$NAMESERVER" ]]; do
        print_error "Nameserver cannot be empty"
        read -p "Nameserver: " NAMESERVER
    done
    
    read -p "SlowDNS Port [5300]: " input_port
    [[ -n "$input_port" ]] && SLOWDNS_PORT="$input_port"
    
    read -p "Local Tunnel Port [2222]: " input_local
    [[ -n "$input_local" ]] && LOCAL_PORT="$input_local"
    
    read -p "SOCKS5 Proxy Port [1080]: " input_socks
    [[ -n "$input_socks" ]] && SOCKS_PORT="$input_socks"
    
    read -p "MTU Size [1200]: " input_mtu
    [[ -n "$input_mtu" ]] && MTU_SIZE="$input_mtu"
    
    # Save config
    cat > "$CONFIG_FILE" << EOF
VPS_IP="$VPS_IP"
NAMESERVER="$NAMESERVER"
SLOWDNS_PORT="$SLOWDNS_PORT"
LOCAL_PORT="$LOCAL_PORT"
SOCKS_PORT="$SOCKS_PORT"
MTU_SIZE="$MTU_SIZE"
EOF
    
    print_status "Configuration saved!"
}

start_vpn_simple() {
    print_info "Starting SlowDNS VPN (Simple Mode)..."
    
    # Load config
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration not found. Run setup first."
        return 1
    fi
    source "$CONFIG_FILE"
    
    # Check files
    if [ ! -f "$SLOWDNS_DIR/sldns-client" ]; then
        print_error "sldns-client not found!"
        manual_download_instructions
        if [ ! -f "$SLOWDNS_DIR/sldns-client" ]; then
            return 1
        fi
    fi
    
    if [ ! -f "$SLOWDNS_DIR/server.pub" ]; then
        print_error "server.pub not found!"
        return 1
    fi
    
    # Stop any existing processes
    pkill -f "sldns-client" 2>/dev/null
    pkill -f "ssh.*$LOCAL_PORT" 2>/dev/null
    
    # Start SlowDNS
    print_info "Starting SlowDNS tunnel..."
    cd "$SLOWDNS_DIR"
    ./sldns-client -udp $VPS_IP:$SLOWDNS_PORT -mtu $MTU_SIZE -pubkey-file server.pub $NAMESERVER 127.0.0.1:$LOCAL_PORT &
    SLOWDNS_PID=$!
    
    sleep 5
    
    if ps -p $SLOWDNS_PID > /dev/null; then
        print_status "SlowDNS tunnel started (PID: $SLOWDNS_PID)"
    else
        print_error "Failed to start SlowDNS tunnel"
        return 1
    fi
    
    # Start SSH tunnel
    print_info "Starting SSH tunnel..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -D $SOCKS_PORT -p $LOCAL_PORT -C -N -f root@127.0.0.1
    
    sleep 2
    
    if ss -tlnp | grep ":$SOCKS_PORT" > /dev/null; then
        print_status "SOCKS5 proxy started on port $SOCKS_PORT"
        
        # Set proxy
        export HTTP_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
        export HTTPS_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
        
        print_status "VPN started successfully!"
        echo ""
        echo -e "${CYAN}Proxy settings:${NC}"
        echo "SOCKS5: 127.0.0.1:$SOCKS_PORT"
        echo ""
        echo -e "${YELLOW}Test with:${NC}"
        echo "curl --socks5 127.0.0.1:$SOCKS_PORT ifconfig.me"
        
        return 0
    else
        print_error "Failed to start SSH tunnel"
        pkill -f "sldns-client"
        return 1
    fi
}

check_vpn_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "No configuration found"
        return 1
    fi
    source "$CONFIG_FILE"
    
    echo -e "${CYAN}=== VPN Status ===${NC}"
    echo ""
    
    # Check SlowDNS
    if pgrep -f "sldns-client" > /dev/null; then
        echo -e "${GREEN}✓ SlowDNS tunnel: RUNNING${NC}"
    else
        echo -e "${RED}✗ SlowDNS tunnel: STOPPED${NC}"
    fi
    
    # Check SSH
    if ss -tlnp | grep ":$SOCKS_PORT" > /dev/null; then
        echo -e "${GREEN}✓ SOCKS5 proxy: RUNNING on port $SOCKS_PORT${NC}"
    else
        echo -e "${RED}✗ SOCKS5 proxy: STOPPED${NC}"
    fi
    
    # Test connection
    echo ""
    echo -e "${CYAN}Connection test:${NC}"
    if timeout 5 curl -s --socks5 127.0.0.1:$SOCKS_PORT ifconfig.me > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Internet: WORKING${NC}"
        echo -n "Your IP: "
        curl -s --socks5 127.0.0.1:$SOCKS_PORT ifconfig.me
        echo ""
    else
        echo -e "${RED}✗ Internet: NOT WORKING${NC}"
    fi
}

stop_vpn() {
    print_info "Stopping VPN..."
    
    pkill -f "sldns-client" 2>/dev/null
    pkill -f "ssh.*$SOCKS_PORT" 2>/dev/null
    
    # Unset proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    
    print_status "VPN stopped"
}

install_dependencies() {
    print_info "Installing dependencies..."
    
    pkg update -y
    pkg install -y wget curl openssh screen net-tools
    
    print_status "Dependencies installed"
}

main_menu() {
    while true; do
        print_banner
        echo -e "${CYAN}MAIN MENU${NC}"
        echo ""
        echo "1. Install Dependencies"
        echo "2. Setup Configuration"
        echo "3. Download Files (Auto)"
        echo "4. Download Files (Manual Guide)"
        echo "5. Start VPN"
        echo "6. Stop VPN"
        echo "7. Check Status"
        echo "8. Test Connection"
        echo "9. Quick Start (All-in-One)"
        echo "0. Exit"
        echo ""
        
        # Show current config if exists
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE" 2>/dev/null
            echo -e "${YELLOW}Current: $VPS_IP | $NAMESERVER${NC}"
            echo ""
        fi
        
        read -p "Select option [0-9]: " choice
        
        case $choice in
            1) install_dependencies ;;
            2) setup_config ;;
            3) download_files_fixed ;;
            4) manual_download_instructions ;;
            5) start_vpn_simple ;;
            6) stop_vpn ;;
            7) check_vpn_status ;;
            8) 
                if [ -f "$CONFIG_FILE" ]; then
                    source "$CONFIG_FILE"
                    echo -n "Testing: "
                    curl -s --socks5 127.0.0.1:$SOCKS_PORT ifconfig.me || echo "Failed"
                else
                    print_error "Setup config first"
                fi
                ;;
            9) quick_start ;;
            0) print_info "Goodbye!"; exit 0 ;;
            *) print_error "Invalid option" ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

quick_start() {
    print_banner
    echo -e "${YELLOW}=== QUICK START ===${NC}"
    echo ""
    
    # Step 1: Install deps
    print_info "Step 1: Installing dependencies..."
    install_dependencies
    
    # Step 2: Setup config
    print_info "Step 2: Configuration..."
    setup_config
    
    # Step 3: Download files
    print_info "Step 3: Downloading files..."
    download_files_fixed
    
    # Step 4: Start VPN
    print_info "Step 4: Starting VPN..."
    start_vpn_simple
    
    # Step 5: Show status
    print_info "Step 5: Final status..."
    check_vpn_status
    
    print_status "Quick start completed!"
}

# Start the script
main_menu
