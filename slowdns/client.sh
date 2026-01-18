# Create the main script
cat > ~/termux-vpn.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# TERMUX ISP DNS BYPASS VPN
# Bypass ISP DNS: 169.255.187.58 using SlowDNS
# ============================================

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# Your Configuration
ISP_DNS="169.255.187.58"      # ISP DNS to bypass
DNS_PORT="53"                 # DNS port
DOMAIN="slowdns.alienalien.top" # SlowDNS domain
PUBKEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59" # Public key
VPS_IP="167.71.11.57"         # Your VPS IP
SSH_PORT="22"                 # SSH port

# Paths
VPN_DIR="$HOME/.termux-vpn"
PID_FILE="$VPN_DIR/pids.txt"
LOG_FILE="$VPN_DIR/vpn.log"

# Banner
banner() {
    clear
    echo -e "${PURPLE}"
    echo '╔══════════════════════════════════════════════════╗'
    echo '║           TERMUX ISP DNS BYPASS VPN             ║'
    echo '╠══════════════════════════════════════════════════╣'
    echo '║ ██╗░██████╗██████╗░  ██████╗░██╗░░░██╗██████╗░  ║'
    echo '║ ██║██╔════╝██╔══██╗  ██╔══██╗╚██╗░██╔╝██╔══██╗  ║'
    echo '║ ██║╚█████╗░██████╔╝  ██████╦╝░╚████╔╝░██████╦╝  ║'
    echo '║ ██║░╚═══██╗██╔═══╝░  ██╔══██╗░░╚██╔╝░░██╔══██╗  ║'
    echo '║ ██║██████╔╝██║░░░░░  ██████╦╝░░░██║░░░██████╦╝  ║'
    echo '║ ╚═╝╚═════╝░╚═╝░░░░░  ╚═════╝░░░░╚═╝░░░╚═════╝░  ║'
    echo '╚══════════════════════════════════════════════════╝'
    echo -e "${NC}"
    echo -e "${YELLOW}Bypassing ISP DNS: ${GREEN}$ISP_DNS${NC}"
    echo -e "${YELLOW}SlowDNS Domain: ${GREEN}$DOMAIN${NC}"
    echo -e "${YELLOW}VPS Server: ${GREEN}$VPS_IP${NC}"
    echo ""
}

# Functions
info() { echo -e "${BLUE}[i]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# Check if running in Termux
check_termux() {
    if [ ! -d "/data/data/com.termux" ]; then
        error "This script must run in Termux!"
        exit 1
    fi
}

# Install required packages
install_packages() {
    banner
    info "Updating Termux packages..."
    pkg update -y && pkg upgrade -y
    
    info "Installing required packages..."
    pkg install -y python openssh curl wget nmap net-tools proot expect sshpass git
    
    # Request permissions
    info "Requesting permissions..."
    termux-setup-storage
    termux-vpn -c 2>/dev/null || warning "Please grant VPN permission if asked")
    
    success "Installation complete!")
}

# Setup VPN directory
setup_directory() {
    mkdir -p "$VPN_DIR"
    cd "$VPN_DIR"
    echo "" > "$PID_FILE"
    echo "" > "$LOG_FILE"
    
    # Save config
    cat > config.txt << CONFIG
ISP_DNS=$ISP_DNS
DNS_PORT=$DNS_PORT
DOMAIN=$DOMAIN
PUBKEY=$PUBKEY
VPS_IP=$VPS_IP
SSH_PORT=$SSH_PORT
CONFIG
    
    success "VPN directory created: $VPN_DIR")
}

# Get SSH credentials
get_credentials() {
    banner
    echo ""
    echo -e "${YELLOW}=== SSH CREDENTIALS REQUIRED ===${NC}"
    echo ""
    echo "Enter your VPS SSH login details:"
    echo ""
    
    read -p "Username [root]: " USER
    USER=${USER:-root}
    
    echo -n "Password: "
    read -s PASS
    echo ""
    
    # Save credentials
    echo "USER=$USER" > "$VPN_DIR/creds.txt"
    echo "PASS=$PASS" >> "$VPN_DIR/creds.txt"
    chmod 600 "$VPN_DIR/creds.txt"
    
    success "Credentials saved!")
}

# Method 1: Python DNS Tunnel (Most Reliable)
start_python_tunnel() {
    info "Starting Python DNS tunnel...")
    
    # Kill existing
    pkill -f "python.*5353" 2>/dev/null
    
    # Create Python DNS tunnel
    python3 -c "
import socket
import sys
import time

print('Starting DNS Tunnel...')
print(f'Local: 127.0.0.1:5353')
print(f'ISP DNS: $ISP_DNS:$DNS_PORT')
print(f'Domain: $DOMAIN')

# Create local DNS server
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('127.0.0.1', 5353))
sock.settimeout(5)

print('✓ DNS server ready on 127.0.0.1:5353')
print('Set Android DNS to 127.0.0.1')
print('')

packet_count = 0
try:
    while True:
        try:
            # Receive DNS query
            data, addr = sock.recvfrom(512)
            
            # Forward to ISP DNS (which tunnels to SlowDNS)
            remote = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            remote.sendto(data, ('$ISP_DNS', $DNS_PORT))
            response, _ = remote.recvfrom(1024)
            
            # Send response back
            sock.sendto(response, addr)
            
            packet_count += 1
            if packet_count % 20 == 0:
                sys.stdout.write(f'\r📡 Packets: {packet_count}')
                sys.stdout.flush()
                
        except socket.timeout:
            continue
        except Exception as e:
            print(f'Error: {e}')
            time.sleep(1)
            
except KeyboardInterrupt:
    print(f'\nStopped. Total packets: {packet_count}')
" >> "$LOG_FILE" 2>&1 &
    
    DNS_PID=$!
    echo "DNS:$DNS_PID" >> "$PID_FILE"
    sleep 3
    
    if kill -0 $DNS_PID 2>/dev/null; then
        success "DNS tunnel started (127.0.0.1:5353)")
        return 0
    else
        error "Failed to start DNS tunnel")
        return 1
    fi
}

# Method 2: Using dnstt client
start_dnstt_tunnel() {
    info "Trying dnstt client...")
    
    cd "$VPN_DIR"
    
    # Download dnstt client
    if wget -q "https://github.com/bamsoftware/dnstt/releases/download/v1.0/dnstt-client" -O dnstt; then
        chmod +x dnstt
        ./dnstt \
            -remote-address "$ISP_DNS:$DNS_PORT" \
            -public-key "$PUBKEY" \
            -domain "$DOMAIN" \
            -listen-address "127.0.0.1:5353" \
            -log-level info &
    else
        warning "Failed to download dnstt, using Python")
        start_python_tunnel
        return $?
    fi
    
    DNS_PID=$!
    echo "DNS:$DNS_PID" >> "$PID_FILE"
    sleep 5
    
    if kill -0 $DNS_PID 2>/dev/null; then
        success "dnstt tunnel running")
        return 0
    else
        error "dnstt failed")
        return 1
    fi
}

# Start SSH tunnel
start_ssh_tunnel() {
    info "Starting SSH tunnel...")
    
    # Load credentials
    if [ ! -f "$VPN_DIR/creds.txt" ]; then
        error "No credentials found!")
        return 1
    fi
    
    source "$VPN_DIR/creds.txt"
    
    # Kill existing SSH
    pkill -f "ssh.*1080" 2>/dev/null
    
    # Check for sshpass
    if ! command -v sshpass >/dev/null; then
        warning "Installing sshpass...")
        pkg install -y sshpass 2>/dev/null
    fi
    
    info "Connecting to SSH through DNS tunnel...")
    
    # Start SSH SOCKS5 proxy
    sshpass -p "$PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=15 \
        -N -D 127.0.0.1:1080 \
        -p "$SSH_PORT" \
        "$USER"@127.0.0.1 \
        >> "$VPN_DIR/ssh.log" 2>&1 &
    
    SSH_PID=$!
    echo "SSH:$SSH_PID" >> "$PID_FILE"
    sleep 5
    
    if kill -0 $SSH_PID 2>/dev/null; then
        success "SSH SOCKS5 proxy: 127.0.0.1:1080")
        info "Connected as: $USER")
        return 0
    else
        error "SSH connection failed")
        return 1
    fi
}

# Test connection
test_connection() {
    echo ""
    echo -e "${CYAN}=== CONNECTION TEST ===${NC}"
    echo ""
    
    # Test DNS
    info "1. DNS Tunnel:"
    if timeout 5 nslookup google.com 127.0.0.1 -port=5353 >/dev/null 2>&1; then
        success "   ✓ Working - ISP DNS bypassed")
    else
        error "   ✗ Failed")
    fi
    
    # Test SSH Tunnel
    info "2. SSH Tunnel:"
    if timeout 10 curl -s --socks5 127.0.0.1:1080 ifconfig.me >/dev/null 2>&1; then
        IP=$(curl -s --socks5 127.0.0.1:1080 ifconfig.me)
        success "   ✓ Working - Your IP: $IP")
        
        # Check if it's VPS IP
        if [ "$IP" = "$VPS_IP" ]; then
            success "   ✓ Successfully routing through VPS")
        fi
    else
        error "   ✗ Failed")
    fi
    
    # Test ISP DNS
    info "3. ISP DNS Test:"
    if timeout 5 nslookup google.com "$ISP_DNS" >/dev/null 2>&1; then
        success "   ✓ ISP DNS accessible")
    else
        warning "   ⚠️ ISP DNS might be blocked")
    fi
}

# Show Android setup instructions
show_android_setup() {
    banner
    echo ""
    echo -e "${RED}=== MUST DO: SET ANDROID DNS ===${NC}"
    echo ""
    echo -e "${GREEN}Step-by-Step Instructions:${NC}"
    echo ""
    echo "1. Go to Android Settings"
    echo "2. Select 'Network & Internet' or 'Connections'"
    echo "3. Tap 'WiFi'"
    echo "4. Long press your connected network → 'Modify network'"
    echo "5. Tap 'Advanced options'"
    echo "6. Change 'IP settings' from DHCP to STATIC"
    echo "7. Set 'DNS 1' to: ${YELLOW}127.0.0.1${NC}"
    echo "8. Leave all other fields as they are"
    echo "9. Tap 'Save'"
    echo "10. Reconnect to WiFi"
    echo ""
    echo -e "${RED}Without this step, VPN will NOT work!${NC}"
    echo ""
    read -p "Press Enter after setting DNS..."
}

# Show usage instructions
show_usage() {
    banner
    echo ""
    echo -e "${GREEN}=== VPN IS RUNNING ===${NC}"
    echo ""
    echo "Local Services:"
    echo -e "  • ${CYAN}DNS Server:${NC} 127.0.0.1:5353"
    echo -e "  • ${CYAN}SOCKS5 Proxy:${NC} 127.0.0.1:1080"
    echo ""
    echo -e "${YELLOW}=== HOW TO USE ===${NC}"
    echo ""
    echo "For Android Apps/Browsers:"
    echo "  • Set proxy to: SOCKS5 127.0.0.1:1080"
    echo ""
    echo "In Termux:"
    echo "  export HTTP_PROXY=socks5://127.0.0.1:1080"
    echo "  export HTTPS_PROXY=socks5://127.0.0.1:1080"
    echo ""
    echo "Test Commands:"
    echo "  curl --socks5 127.0.0.1:1080 ifconfig.me"
    echo "  curl --socks5 127.0.0.1:1080 http://ip-api.com/json"
    echo ""
    echo -e "${RED}=== TO STOP VPN ===${NC}"
    echo "  pkill -f 'python|ssh|dnstt'"
    echo "  Or use option 2 in menu"
}

# Stop VPN
stop_vpn() {
    info "Stopping VPN...")
    
    # Read PIDs and kill
    if [ -f "$PID_FILE" ]; then
        while IFS=':' read -r service pid; do
            if [ -n "$pid" ]; then
                kill -9 "$pid" 2>/dev/null
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi
    
    # Cleanup
    pkill -f "python.*5353" 2>/dev/null
    pkill -f "ssh.*1080" 2>/dev/null
    pkill -f "dnstt" 2>/dev/null
    pkill -f "sshpass" 2>/dev/null
    
    success "VPN stopped")
}

# Check VPN status
check_status() {
    echo ""
    echo -e "${CYAN}=== VPN STATUS ===${NC}"
    echo ""
    
    # Check DNS
    if netstat -tulpn 2>/dev/null | grep -q ":5353"; then
        echo -e "DNS Tunnel: ${GREEN}Running${NC}"
    else
        echo -e "DNS Tunnel: ${RED}Stopped${NC}"
    fi
    
    # Check SSH
    if netstat -tulpn 2>/dev/null | grep -q ":1080"; then
        echo -e "SSH Proxy: ${GREEN}Running${NC}"
    else
        echo -e "SSH Proxy: ${RED}Stopped${NC}"
    fi
    
    # Show active processes
    echo ""
    echo "Active Processes:"
    ps aux | grep -E "python.*5353|ssh.*1080|dnstt" | grep -v grep || echo "None"
}

# Main menu
main_menu() {
    while true; do
        banner
        echo ""
        echo "1) Start VPN"
        echo "2) Stop VPN"
        echo "3) Test Connection"
        echo "4) Check Status"
        echo "5) Android DNS Setup"
        echo "6) Change Credentials"
        echo "7) View Logs"
        echo "8) Auto-start Setup"
        echo "9) Exit"
        echo ""
        echo -n "Select option: "
        read choice
        
        case $choice in
            1)
                # First time setup
                if ! command -v sshpass >/dev/null; then
                    install_packages
                fi
                
                setup_directory
                
                # Get credentials if needed
                if [ ! -f "$VPN_DIR/creds.txt" ]; then
                    get_credentials
                fi
                
                # Start services
                start_python_tunnel
                sleep 3
                start_ssh_tunnel
                sleep 2
                test_connection
                show_android_setup
                show_usage
                ;;
            2)
                stop_vpn
                ;;
            3)
                test_connection
                ;;
            4)
                check_status
                ;;
            5)
                show_android_setup
                ;;
            6)
                get_credentials
                ;;
            7)
                echo -e "${CYAN}=== VPN LOG ===${NC}"
                tail -20 "$LOG_FILE" 2>/dev/null || echo "No log"
                echo ""
                echo -e "${CYAN}=== SSH LOG ===${NC}"
                tail -10 "$VPN_DIR/ssh.log" 2>/dev/null || echo "No SSH log"
                ;;
            8)
                # Auto-start setup
                mkdir -p ~/.termux/boot
                cat > ~/.termux/boot/00-vpn << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
sleep 20
cd $HOME
bash termux-vpn.sh auto
BOOT
                chmod +x ~/.termux/boot/00-vpn
                success "Auto-start configured")
                ;;
            9)
                stop_vpn
                echo "Goodbye!"
                exit 0
                ;;
            *)
                error "Invalid option!")
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Auto-start mode
if [ "$1" = "auto" ]; then
    setup_directory
    if [ -f "$VPN_DIR/creds.txt" ]; then
        start_python_tunnel
        sleep 5
        start_ssh_tunnel
    fi
    exit 0
fi

# Start main menu
check_termux
main_menu
EOF

# Make it executable
chmod +x ~/termux-vpn.sh
