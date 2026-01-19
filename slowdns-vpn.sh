#!/data/data/com.termux/files/usr/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
CONFIG_FILE="$HOME/.slowdns-config"
LOG_FILE="$HOME/slowdns.log"
SLOWDNS_DIR="$HOME/slowdns"
VERSION="1.0"

# Default values (will be loaded from config)
VPS_IP=""
NAMESERVER=""
SLOWDNS_PORT="5300"
LOCAL_PORT="2222"
SOCKS_PORT="1080"
MTU_SIZE="1200"

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║      TERMUX SLOWDNS VPN CLIENT          ║"
    echo "║             Version $VERSION               ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

check_packages() {
    print_info "Checking required packages..."
    
    packages=("wget" "curl" "proot" "git" "nano" "openssh" "screen" "net-tools")
    missing=()
    
    for pkg in "${packages[@]}"; do
        if ! command -v $pkg &> /dev/null; then
            missing+=("$pkg")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_warning "Installing missing packages: ${missing[*]}"
        pkg update -y
        pkg install -y ${missing[@]}
    else
        print_status "All required packages are installed"
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        print_status "Configuration loaded from $CONFIG_FILE"
        return 0
    else
        print_warning "Configuration file not found. Run setup first."
        return 1
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# Termux SlowDNS VPN Configuration
VPS_IP="$VPS_IP"
NAMESERVER="$NAMESERVER"
SLOWDNS_PORT="$SLOWDNS_PORT"
LOCAL_PORT="$LOCAL_PORT"
SOCKS_PORT="$SOCKS_PORT"
MTU_SIZE="$MTU_SIZE"
EOF
    print_status "Configuration saved to $CONFIG_FILE"
}

setup_config() {
    print_banner
    echo -e "${YELLOW}=== Configuration Setup ===${NC}"
    echo ""
    
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}Current configuration:${NC}"
        cat "$CONFIG_FILE"
        echo ""
        read -p "Keep existing config? (y/n): " keep
        if [[ $keep == "y" || $keep == "Y" ]]; then
            return
        fi
    fi
    
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
    if [[ -n "$input_port" ]]; then
        SLOWDNS_PORT="$input_port"
    fi
    
    read -p "Local Tunnel Port [2222]: " input_local
    if [[ -n "$input_local" ]]; then
        LOCAL_PORT="$input_local"
    fi
    
    read -p "SOCKS5 Proxy Port [1080]: " input_socks
    if [[ -n "$input_socks" ]]; then
        SOCKS_PORT="$input_socks"
    fi
    
    read -p "MTU Size [1200]: " input_mtu
    if [[ -n "$input_mtu" ]]; then
        MTU_SIZE="$input_mtu"
    fi
    
    save_config
    print_status "Configuration saved!"
    sleep 2
}

download_files() {
    print_info "Downloading SlowDNS client files..."
    
    mkdir -p "$SLOWDNS_DIR"
    cd "$SLOWDNS_DIR"
    
    # Download sldns-client
    if [ ! -f "sldns-client" ]; then
        print_info "Downloading sldns-client..."
        wget -q --show-progress "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-client"
        if [ $? -eq 0 ]; then
            chmod +x sldns-client
            print_status "sldns-client downloaded"
        else
            print_error "Failed to download sldns-client"
            return 1
        fi
    else
        print_status "sldns-client already exists"
    fi
    
    # Download server.pub
    if [ ! -f "server.pub" ]; then
        print_info "Downloading server public key..."
        wget -q --show-progress "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
        if [ $? -eq 0 ]; then
            print_status "server.pub downloaded"
        else
            print_error "Failed to download server.pub"
            return 1
        fi
    else
        print_status "server.pub already exists"
    fi
    
    # Download SSH key if not exists
    if [ ! -f "$HOME/.ssh/id_rsa" ]; then
        print_info "Generating SSH key..."
        mkdir -p "$HOME/.ssh"
        ssh-keygen -t rsa -f "$HOME/.ssh/id_rsa" -N "" -q
        print_status "SSH key generated"
    fi
    
    print_status "All files downloaded successfully"
    return 0
}

check_connection() {
    print_info "Testing connection to VPS..."
    
    if ! ping -c 2 "$VPS_IP" &> /dev/null; then
        print_error "Cannot ping $VPS_IP"
        return 1
    fi
    
    if ! timeout 5 nc -z "$VPS_IP" "$SLOWDNS_PORT"; then
        print_error "Port $SLOWDNS_PORT is not open on $VPS_IP"
        return 1
    fi
    
    print_status "Connection test successful"
    return 0
}

start_slowdns() {
    print_info "Starting SlowDNS tunnel..."
    
    # Kill existing processes
    stop_slowdns_silent
    
    cd "$SLOWDNS_DIR"
    
    # Start SlowDNS client
    screen -dmS slowdns ./sldns-client -udp $VPS_IP:$SLOWDNS_PORT -mtu $MTU_SIZE -pubkey-file server.pub $NAMESERVER 127.0.0.1:$LOCAL_PORT
    
    sleep 5
    
    if pgrep -f "sldns-client" > /dev/null; then
        print_status "SlowDNS tunnel started on port $LOCAL_PORT"
        return 0
    else
        print_error "Failed to start SlowDNS tunnel"
        return 1
    fi
}

start_ssh_tunnel() {
    print_info "Starting SSH SOCKS5 proxy..."
    
    # Kill existing SSH tunnel
    pkill -f "ssh.*$LOCAL_PORT" 2>/dev/null
    
    # Copy SSH key to VPS (first time only)
    if [ ! -f "$SLOWDNS_DIR/ssh_key_copied" ]; then
        print_warning "First time setup: Copy SSH key to VPS"
        print_warning "You need to connect to your VPS via SSH normally first"
        print_warning "Run: ssh-copy-id -p 22 root@$VPS_IP"
        print_warning "After that, press Enter to continue..."
        read
        touch "$SLOWDNS_DIR/ssh_key_copied"
    fi
    
    # Start SSH tunnel with SOCKS5 proxy
    screen -dmS sshtunnel ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 -o ServerAliveInterval=60 \
        -D $SOCKS_PORT -p $LOCAL_PORT -C -N -f root@127.0.0.1
    
    sleep 3
    
    if ss -tlnp | grep ":$SOCKS_PORT" > /dev/null; then
        print_status "SOCKS5 proxy started on port $SOCKS_PORT"
        
        # Set proxy environment variables
        export HTTP_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
        export HTTPS_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
        export ALL_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
        
        # Save to .bashrc for persistence
        if ! grep -q "export HTTP_PROXY" ~/.bashrc; then
            echo "export HTTP_PROXY=\"socks5://127.0.0.1:$SOCKS_PORT\"" >> ~/.bashrc
            echo "export HTTPS_PROXY=\"socks5://127.0.0.1:$SOCKS_PORT\"" >> ~/.bashrc
            echo "export ALL_PROXY=\"socks5://127.0.0.1:$SOCKS_PORT\"" >> ~/.bashrc
        fi
        
        return 0
    else
        print_error "Failed to start SOCKS5 proxy"
        return 1
    fi
}

stop_slowdns() {
    print_info "Stopping SlowDNS VPN..."
    
    pkill -f "sldns-client" 2>/dev/null
    pkill -f "ssh.*$LOCAL_PORT" 2>/dev/null
    screen -S slowdns -X quit 2>/dev/null
    screen -S sshtunnel -X quit 2>/dev/null
    
    # Unset proxy variables
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset ALL_PROXY
    
    # Remove from .bashrc
    sed -i '/export HTTP_PROXY/d' ~/.bashrc
    sed -i '/export HTTPS_PROXY/d' ~/.bashrc
    sed -i '/export ALL_PROXY/d' ~/.bashrc
    
    print_status "SlowDNS VPN stopped"
}

stop_slowdns_silent() {
    pkill -f "sldns-client" 2>/dev/null
    pkill -f "ssh.*$LOCAL_PORT" 2>/dev/null
    screen -S slowdns -X quit 2>/dev/null
    screen -S sshtunnel -X quit 2>/dev/null
}

check_status() {
    echo -e "${CYAN}=== SlowDNS VPN Status ===${NC}"
    echo ""
    
    # Check SlowDNS process
    if pgrep -f "sldns-client" > /dev/null; then
        echo -e "${GREEN}✓ SlowDNS tunnel: RUNNING${NC}"
    else
        echo -e "${RED}✗ SlowDNS tunnel: STOPPED${NC}"
    fi
    
    # Check SSH tunnel
    if ss -tlnp | grep ":$SOCKS_PORT" > /dev/null; then
        echo -e "${GREEN}✓ SOCKS5 proxy: RUNNING on port $SOCKS_PORT${NC}"
    else
        echo -e "${RED}✗ SOCKS5 proxy: STOPPED${NC}"
    fi
    
    # Check screen sessions
    echo -e "${CYAN}Screen sessions:${NC}"
    screen -ls | grep -E "(slowdns|sshtunnel)" || echo "No active sessions"
    
    echo ""
    echo -e "${CYAN}Network information:${NC}"
    echo "VPS IP: $VPS_IP"
    echo "Nameserver: $NAMESERVER"
    echo "Tunnel port: $LOCAL_PORT"
    echo "Proxy port: $SOCKS_PORT"
    echo "MTU: $MTU_SIZE"
    
    echo ""
    echo -e "${CYAN}Connection test:${NC}"
    if timeout 5 curl -s --socks5 "127.0.0.1:$SOCKS_PORT" ifconfig.me > /dev/null; then
        echo -e "${GREEN}✓ Internet connection: WORKING${NC}"
        echo -n "Your IP: "
        curl -s --socks5 "127.0.0.1:$SOCKS_PORT" ifconfig.me
        echo ""
    else
        echo -e "${RED}✗ Internet connection: FAILED${NC}"
    fi
}

test_connection() {
    print_info "Testing VPN connection..."
    
    echo ""
    echo -e "${CYAN}1. Testing SlowDNS tunnel...${NC}"
    if pgrep -f "sldns-client" > /dev/null; then
        echo -e "${GREEN}✓ Tunnel is running${NC}"
    else
        echo -e "${RED}✗ Tunnel is not running${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}2. Testing SOCKS5 proxy...${NC}"
    if ss -tlnp | grep ":$SOCKS_PORT" > /dev/null; then
        echo -e "${GREEN}✓ Proxy is listening${NC}"
    else
        echo -e "${RED}✗ Proxy is not listening${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}3. Testing internet connection...${NC}"
    echo -n "Public IP: "
    if timeout 10 curl -s --socks5 "127.0.0.1:$SOCKS_PORT" ifconfig.me; then
        echo -e "\n${GREEN}✓ Internet is accessible${NC}"
    else
        echo -e "\n${RED}✗ Cannot access internet${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}4. Testing DNS resolution...${NC}"
    if timeout 10 curl -s --socks5 "127.0.0.1:$SOCKS_PORT" http://google.com > /dev/null; then
        echo -e "${GREEN}✓ DNS is working${NC}"
    else
        echo -e "${RED}✗ DNS is not working${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

setup_autostart() {
    print_info "Setting up autostart with Termux:Boot..."
    
    if [ ! -d ~/.termux/boot ]; then
        mkdir -p ~/.termux/boot
    fi
    
    cat > ~/.termux/boot/start-slowdns.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
# Auto-start SlowDNS VPN on Termux boot

sleep 10  # Wait for network

CONFIG_FILE="\$HOME/.slowdns-config"
SLOWDNS_DIR="\$HOME/slowdns"

if [ -f "\$CONFIG_FILE" ]; then
    source "\$CONFIG_FILE"
    
    cd "\$SLOWDNS_DIR"
    
    # Start SlowDNS tunnel
    ./sldns-client -udp \$VPS_IP:\$SLOWDNS_PORT -mtu \$MTU_SIZE -pubkey-file server.pub \$NAMESERVER 127.0.0.1:\$LOCAL_PORT &
    sleep 5
    
    # Start SSH tunnel
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\
        -D \$SOCKS_PORT -p \$LOCAL_PORT -C -N -f root@127.0.0.1 &
    
    # Set proxy environment
    export HTTP_PROXY="socks5://127.0.0.1:\$SOCKS_PORT"
    export HTTPS_PROXY="socks5://127.0.0.1:\$SOCKS_PORT"
    export ALL_PROXY="socks5://127.0.0.1:\$SOCKS_PORT"
    
    echo "\$(date): SlowDNS VPN started" >> "\$HOME/slowdns-autostart.log"
fi
EOF
    
    chmod +x ~/.termux/boot/start-slowdns.sh
    
    cat > ~/.termux/boot/stop-slowdns.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
# Stop SlowDNS VPN

pkill -f "sldns-client"
pkill -f "ssh.*$LOCAL_PORT"

unset HTTP_PROXY
unset HTTPS_PROXY
unset ALL_PROXY

echo "\$(date): SlowDNS VPN stopped" >> "\$HOME/slowdns-autostart.log"
EOF
    
    chmod +x ~/.termux/boot/stop-slowdns.sh
    
    print_status "Autostart scripts created in ~/.termux/boot/"
    print_warning "Install Termux:Boot app from F-Droid for autostart to work"
}

create_shortcuts() {
    print_info "Creating shortcut commands..."
    
    # Create start script
    cat > "$SLOWDNS_DIR/start-vpn.sh" << EOF
#!/data/data/com.termux/files/usr/bin/bash
cd "\$HOME/slowdns"
bash "\$HOME/slowdns-vpn.sh" --start
EOF
    
    # Create stop script
    cat > "$SLOWDNS_DIR/stop-vpn.sh" << EOF
#!/data/data/com.termux/files/usr/bin/bash
cd "\$HOME/slowdns"
bash "\$HOME/slowdns-vpn.sh" --stop
EOF
    
    # Create status script
    cat > "$SLOWDNS_DIR/status-vpn.sh" << EOF
#!/data/data/com.termux/files/usr/bin/bash
cd "\$HOME/slowdns"
bash "\$HOME/slowdns-vpn.sh" --status
EOF
    
    chmod +x "$SLOWDNS_DIR"/*.sh
    
    # Add aliases to .bashrc
    if ! grep -q "alias vpn-start" ~/.bashrc; then
        echo "alias vpn-start='bash ~/slowdns/start-vpn.sh'" >> ~/.bashrc
        echo "alias vpn-stop='bash ~/slowdns/stop-vpn.sh'" >> ~/.bashrc
        echo "alias vpn-status='bash ~/slowdns/status-vpn.sh'" >> ~/.bashrc
        echo "alias vpn-test='bash ~/slowdns-vpn.sh --test'" >> ~/.bashrc
    fi
    
    print_status "Shortcuts created:"
    echo -e "${CYAN}vpn-start${NC}    - Start SlowDNS VPN"
    echo -e "${CYAN}vpn-stop${NC}     - Stop SlowDNS VPN"
    echo -e "${CYAN}vpn-status${NC}   - Check VPN status"
    echo -e "${CYAN}vpn-test${NC}     - Test VPN connection"
    
    print_warning "Run 'source ~/.bashrc' or restart Termux to use aliases"
}

view_logs() {
    print_info "Viewing logs..."
    
    if [ -f "$LOG_FILE" ]; then
        echo -e "${CYAN}=== Last 20 log entries ===${NC}"
        tail -20 "$LOG_FILE"
    else
        print_warning "No log file found"
    fi
    
    echo ""
    echo -e "${CYAN}=== Screen sessions logs ===${NC}"
    if screen -ls | grep -q "slowdns"; then
        echo "SlowDNS tunnel log:"
        screen -S slowdns -X hardcopy "$SLOWDNS_DIR/slowdns.log"
        tail -10 "$SLOWDNS_DIR/slowdns.log"
    fi
    
    if screen -ls | grep -q "sshtunnel"; then
        echo ""
        echo "SSH tunnel log:"
        screen -S sshtunnel -X hardcopy "$SLOWDNS_DIR/sshtunnel.log"
        tail -10 "$SLOWDNS_DIR/sshtunnel.log"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

main_menu() {
    while true; do
        print_banner
        echo -e "${CYAN}Main Menu${NC}"
        echo ""
        echo "1.  Initial Setup & Configuration"
        echo "2.  Download Files"
        echo "3.  Start VPN"
        echo "4.  Stop VPN"
        echo "5.  Check Status"
        echo "6.  Test Connection"
        echo "7.  Setup Autostart"
        echo "8.  Create Shortcuts"
        echo "9.  View Logs"
        echo "10. Update Script"
        echo "11. Exit"
        echo ""
        
        # Show current config
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "${YELLOW}Current config:${NC}"
            echo "VPS: $VPS_IP | NS: $NAMESERVER"
            echo ""
        fi
        
        read -p "Select option [1-11]: " choice
        
        case $choice in
            1)
                setup_config
                ;;
            2)
                load_config || setup_config
                check_packages
                download_files
                read -p "Press Enter to continue..."
                ;;
            3)
                load_config || { setup_config; continue; }
                check_packages
                download_files
                check_connection
                start_slowdns
                start_ssh_tunnel
                check_status
                read -p "Press Enter to continue..."
                ;;
            4)
                stop_slowdns
                read -p "Press Enter to continue..."
                ;;
            5)
                load_config || { setup_config; continue; }
                check_status
                read -p "Press Enter to continue..."
                ;;
            6)
                load_config || { setup_config; continue; }
                test_connection
                ;;
            7)
                load_config || { setup_config; continue; }
                setup_autostart
                read -p "Press Enter to continue..."
                ;;
            8)
                create_shortcuts
                read -p "Press Enter to continue..."
                ;;
            9)
                view_logs
                ;;
            10)
                update_script
                ;;
            11)
                print_info "Exiting..."
                exit 0
                ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

update_script() {
    print_info "Checking for updates..."
    
    SCRIPT_URL="https://raw.githubusercontent.com/athumani2580/vps/main/termux-slowdns.sh"
    
    if curl -s -I "$SCRIPT_URL" | head -n 1 | grep -q "200"; then
        print_warning "Update available! Downloading..."
        if curl -s "$SCRIPT_URL" -o "/tmp/slowdns-vpn-new.sh"; then
            if ! diff "$0" "/tmp/slowdns-vpn-new.sh" > /dev/null; then
                mv "/tmp/slowdns-vpn-new.sh" "$0"
                chmod +x "$0"
                print_status "Script updated successfully!"
                print_warning "Please restart the script"
                exit 0
            else
                print_status "Script is already up to date"
                rm "/tmp/slowdns-vpn-new.sh"
            fi
        else
            print_error "Failed to download update"
        fi
    else
        print_error "Cannot check for updates"
    fi
    
    read -p "Press Enter to continue..."
}

# Handle command line arguments
case "$1" in
    --start)
        load_config || exit 1
        check_packages
        download_files
        start_slowdns
        start_ssh_tunnel
        check_status
        ;;
    --stop)
        stop_slowdns
        ;;
    --status)
        load_config || exit 1
        check_status
        ;;
    --test)
        load_config || exit 1
        test_connection
        ;;
    --config)
        setup_config
        ;;
    --setup)
        setup_config
        check_packages
        download_files
        create_shortcuts
        ;;
    *)
        # Start interactive menu
        main_menu
        ;;
esac
