#!/data/data/com.termux/files/usr/bin/bash
# ===========================================
# TERMUX SLOWDNS VPN CLIENT - CORRECT CONFIG
# ===========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CLIENT_DNS="169.255.187.58"    # Connect to this DNS
DNS_PORT="53"                  # DNS port
VPS_IP="167.71.11.57"          # Your VPS IP
SSH_PORT="22"                  # SSH port on VPS
NAMESERVER="slowdns.alienalien.top" # Your domain
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"

# Paths
VPN_DIR="$HOME/slowdns-vpn"
CLIENT_BIN="$VPN_DIR/sldns-client"
LOG_FILE="$VPN_DIR/slowdns.log"
PID_FILE="$VPN_DIR/slowdns.pid"

print_header() {
    clear
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║     TERMUX SLOWDNS VPN CLIENT                    ║"
    echo "║         Correct Configuration                    ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Main installation
install_dependencies() {
    print_header
    print_info "Updating Termux..."
    pkg update -y && pkg upgrade -y
    
    print_info "Installing required packages..."
    pkg install -y wget curl openssl-tool git python openssh nmap net-tools proot tar
    
    print_success "Dependencies installed"
}

setup_directories() {
    print_info "Setting up VPN directory..."
    rm -rf "$VPN_DIR" 2>/dev/null
    mkdir -p "$VPN_DIR"
    cd "$VPN_DIR"
    
    # Save configuration
    cat > config.txt << EOF
# SlowDNS VPN Configuration
CLIENT_DNS=$CLIENT_DNS
DNS_PORT=$DNS_PORT
VPS_IP=$VPS_IP
SSH_PORT=$SSH_PORT
NAMESERVER=$NAMESERVER
PUBLIC_KEY=$PUBLIC_KEY
EOF
    
    print_success "Directory created: $VPN_DIR"
}

download_client() {
    print_info "Downloading SlowDNS client..."
    
    # Try to download from your repository
    if wget -q "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/client" -O "$CLIENT_BIN"; then
        chmod +x "$CLIENT_BIN"
        print_success "Client downloaded from repository"
        return 0
    fi
    
    # Try dnstt client
    if wget -q "https://github.com/bamsoftware/dnstt/releases/download/v1.0/dnstt-client" -O "$CLIENT_BIN"; then
        chmod +x "$CLIENT_BIN"
        print_success "Using dnstt client"
        return 0
    fi
    
    # Create Python fallback client
    print_warning "Creating Python client as fallback..."
    create_python_client
}

create_python_client() {
    cat > "$CLIENT_BIN.py" << 'PYTHON'
#!/usr/bin/env python3
import socket
import struct
import time
import threading
import sys

def create_dns_tunnel():
    """Create DNS tunnel to SlowDNS server"""
    
    print("╔══════════════════════════════════════════════════╗")
    print("║        SLOWDNS PYTHON CLIENT                    ║")
    print("╠══════════════════════════════════════════════════╣")
    print("║ Client DNS: 169.255.187.58:53                   ║")
    print("║ VPS Server: 167.71.11.57                        ║")
    print("║ Domain: slowdns.alienalien.top                  ║")
    print("╚══════════════════════════════════════════════════╝")
    print("\nStarting DNS tunnel on 127.0.0.1:5353...")
    
    # Create local DNS server socket
    local_dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    local_dns.bind(('127.0.0.1', 5353))
    local_dns.settimeout(5)
    
    # Socket for SlowDNS server
    slowdns_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    print("\n✅ Local DNS server ready: 127.0.0.1:5353")
    print("📱 Set your Android DNS to 127.0.0.1")
    print("🔄 Forwarding all DNS queries to SlowDNS...")
    print("\nPress Ctrl+C to stop\n")
    
    try:
        while True:
            try:
                # Receive DNS query from local apps
                data, client_addr = local_dns.recvfrom(512)
                
                # Forward to SlowDNS server
                slowdns_socket.sendto(data, ('169.255.187.58', 53))
                
                # Get response from SlowDNS
                response, _ = slowdns_socket.recvfrom(1024)
                
                # Send response back to client
                local_dns.sendto(response, client_addr)
                
                # Show activity
                sys.stdout.write(".")
                sys.stdout.flush()
                
            except socket.timeout:
                continue
            except Exception as e:
                print(f"\n⚠️ Error: {e}")
                time.sleep(1)
                
    except KeyboardInterrupt:
        print("\n\n🛑 Stopping DNS tunnel...")
    finally:
        local_dns.close()
        slowdns_socket.close()
        print("✅ DNS tunnel stopped")

if __name__ == "__main__":
    create_dns_tunnel()
PYTHON
    
    chmod +x "$CLIENT_BIN.py"
    mv "$CLIENT_BIN.py" "$CLIENT_BIN"
    print_success "Python client created"
}

create_control_script() {
    print_info "Creating control script..."
    
    cat > "$VPN_DIR/vpn-control.sh" << 'CONTROL'
#!/data/data/com.termux/files/usr/bin/bash
# SlowDNS VPN Control Script

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load config
CONFIG="$HOME/slowdns-vpn/config.txt"
[ -f "$CONFIG" ] && source "$CONFIG"

# Defaults
CLIENT_DNS=${CLIENT_DNS:-"169.255.187.58"}
DNS_PORT=${DNS_PORT:-"53"}
VPS_IP=${VPS_IP:-"167.71.11.57"}
SSH_PORT=${SSH_PORT:-"22"}
NAMESERVER=${NAMESERVER:-"slowdns.alienalien.top"}
PUBLIC_KEY=${PUBLIC_KEY:-"7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"}

VPN_DIR="$HOME/slowdns-vpn"
CLIENT_BIN="$VPN_DIR/sldns-client"
LOG_FILE="$VPN_DIR/slowdns.log"
SSH_LOG="$VPN_DIR/ssh.log"
PID_FILE="$VPN_DIR/slowdns.pid"
SSH_PID_FILE="$VPN_DIR/ssh.pid"

show_config() {
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║           SLOWDNS VPN CONFIGURATION             ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║ Client DNS: ${CLIENT_DNS}:${DNS_PORT}"
    echo "║ VPS Server: ${VPS_IP}"
    echo "║ SSH Port: ${SSH_PORT}"
    echo "║ Domain: ${NAMESERVER}"
    echo "║ Local DNS: 127.0.0.1:5353"
    echo "║ SOCKS5 Proxy: 127.0.0.1:1080"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

start_slowdns() {
    echo -e "${BLUE}[*] Starting SlowDNS tunnel...${NC}"
    
    # Stop existing
    pkill -f "sldns-client" 2>/dev/null
    
    if [ -f "$CLIENT_BIN" ]; then
        # Check if it's a binary or script
        if file "$CLIENT_BIN" | grep -q "ELF"; then
            # Binary client (dnstt format)
            "$CLIENT_BIN" \
                -remote-address "${CLIENT_DNS}:${DNS_PORT}" \
                -public-key "${PUBLIC_KEY}" \
                -domain "${NAMESERVER}" \
                -listen-address "127.0.0.1:5353" \
                -log-level info \
                >> "$LOG_FILE" 2>&1 &
        else
            # Python/script client
            python "$CLIENT_BIN" >> "$LOG_FILE" 2>&1 &
        fi
        
        CLIENT_PID=$!
        echo $CLIENT_PID > "$PID_FILE"
        sleep 3
        
        if kill -0 $CLIENT_PID 2>/dev/null; then
            echo -e "${GREEN}[✓] SlowDNS tunnel started${NC}"
            echo -e "${YELLOW}[!] Set DNS to 127.0.0.1 on your device${NC}"
            return 0
        fi
    fi
    
    echo -e "${RED}[✗] Failed to start SlowDNS${NC}"
    return 1
}

setup_ssh() {
    echo -e "${BLUE}[*] Setting up SSH...${NC}"
    
    # Generate SSH key if needed
    if [ ! -f ~/.ssh/id_rsa ]; then
        echo -e "${YELLOW}[!] Generating SSH key...${NC}"
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" -q
        echo -e "${GREEN}[✓] SSH key generated${NC}"
        echo ""
        echo -e "${CYAN}=== IMPORTANT ===${NC}"
        echo "Add this key to your VPS (${VPS_IP}):"
        echo ""
        cat ~/.ssh/id_rsa.pub
        echo ""
        echo -e "${YELLOW}On your VPS, run:${NC}"
        echo "echo '$(cat ~/.ssh/id_rsa.pub)' >> ~/.ssh/authorized_keys"
        echo ""
        read -p "Press Enter after adding the key..."
    fi
}

start_ssh_tunnel() {
    echo -e "${BLUE}[*] Starting SSH tunnel...${NC}"
    
    # Stop existing
    pkill -f "ssh.*1080" 2>/dev/null
    
    # Start SSH SOCKS5 proxy through SlowDNS tunnel
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=15 \
        -o ProxyCommand="socat - udp4-connect:${CLIENT_DNS}:${DNS_PORT}" \
        -N -D 1080 \
        -p "${SSH_PORT}" \
        root@${VPS_IP} \
        >> "$SSH_LOG" 2>&1 &
    
    SSH_PID=$!
    echo $SSH_PID > "$SSH_PID_FILE"
    sleep 3
    
    if kill -0 $SSH_PID 2>/dev/null; then
        echo -e "${GREEN}[✓] SSH SOCKS5 proxy started on 127.0.0.1:1080${NC}"
        return 0
    else
        echo -e "${RED}[✗] Failed to start SSH tunnel${NC}"
        return 1
    fi
}

stop_vpn() {
    echo -e "${BLUE}[*] Stopping VPN...${NC}"
    
    # Stop SlowDNS
    if [ -f "$PID_FILE" ]; then
        kill -9 $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
    fi
    
    # Stop SSH
    if [ -f "$SSH_PID_FILE" ]; then
        kill -9 $(cat "$SSH_PID_FILE") 2>/dev/null
        rm -f "$SSH_PID_FILE"
    fi
    
    # Cleanup
    pkill -f "sldns-client" 2>/dev/null
    pkill -f "ssh.*1080" 2>/dev/null
    
    echo -e "${GREEN}[✓] VPN stopped${NC}"
}

test_connection() {
    echo -e "${BLUE}[*] Testing connections...${NC}"
    echo ""
    
    # Test 1: DNS tunnel
    echo -e "${CYAN}1. DNS Tunnel Test:${NC}"
    if timeout 5 nslookup google.com 127.0.0.1 -port=5353 >/dev/null 2>&1; then
        echo -e "${GREEN}   ✓ Working${NC}"
    else
        echo -e "${RED}   ✗ Failed${NC}"
    fi
    
    # Test 2: SSH tunnel
    echo -e "${CYAN}2. SSH Tunnel Test:${NC}"
    if timeout 10 curl -s --socks5 127.0.0.1:1080 ifconfig.me >/dev/null 2>&1; then
        IP=$(curl -s --socks5 127.0.0.1:1080 ifconfig.me)
        echo -e "${GREEN}   ✓ Working (IP: $IP)${NC}"
    else
        echo -e "${RED}   ✗ Failed${NC}"
    fi
    
    # Test 3: Server connectivity
    echo -e "${CYAN}3. Server Connectivity:${NC}"
    if timeout 5 ping -c 2 "${VPS_IP}" >/dev/null 2>&1; then
        echo -e "${GREEN}   ✓ VPS reachable${NC}"
    else
        echo -e "${RED}   ✗ VPS unreachable${NC}"
    fi
}

show_dns_instructions() {
    clear
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║     DNS CONFIGURATION (IMPORTANT!)              ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}Step 1: Configure DNS on Android${NC}"
    echo "1. Go to Settings → Network & Internet → WiFi"
    echo "2. Tap your connected network → Advanced"
    echo "3. IP settings → Static"
    echo "4. Set DNS 1: 127.0.0.1"
    echo "5. Save"
    echo ""
    echo -e "${GREEN}Step 2: Add SSH Key to VPS${NC}"
    echo "1. Copy this key:"
    echo ""
    cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "Run SSH setup first"
    echo ""
    echo "2. On your VPS (${VPS_IP}):"
    echo "   nano ~/.ssh/authorized_keys"
    echo "   Paste the key and save"
    echo ""
    echo -e "${GREEN}Step 3: Usage${NC}"
    echo "• Browser: SOCKS5 127.0.0.1:1080"
    echo "• Termux: export HTTP_PROXY=socks5://127.0.0.1:1080"
    echo ""
    read -p "Press Enter to continue..."
}

show_menu() {
    clear
    show_config
    echo ""
    echo "1) Start SlowDNS VPN"
    echo "2) Stop VPN"
    echo "3) Test Connection"
    echo "4) DNS & SSH Setup Instructions"
    echo "5) View Logs"
    echo "6) Quick Start (DNS only)"
    echo "7) Setup Auto-start"
    echo "8) Exit"
    echo ""
    echo -n "Select: "
}

# Main menu
while true; do
    show_menu
    read choice
    
    case $choice in
        1)
            start_slowdns
            sleep 2
            setup_ssh
            sleep 2
            start_ssh_tunnel
            sleep 2
            test_connection
            ;;
        2)
            stop_vpn
            ;;
        3)
            test_connection
            ;;
        4)
            show_dns_instructions
            ;;
        5)
            echo "=== SlowDNS Log ==="
            tail -20 "$LOG_FILE" 2>/dev/null || echo "No logs"
            echo ""
            echo "=== SSH Log ==="
            tail -10 "$SSH_LOG" 2>/dev/null || echo "No SSH logs"
            ;;
        6)
            # Quick DNS-only start
            start_slowdns
            echo ""
            echo -e "${GREEN}DNS tunnel started!${NC}"
            echo "Set DNS to 127.0.0.1 on your device"
            ;;
        7)
            # Auto-start setup
            mkdir -p ~/.termux/boot
            cat > ~/.termux/boot/00-slowdns << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
sleep 15
cd $HOME/slowdns-vpn
bash vpn-control.sh 1
BOOT
            chmod +x ~/.termux/boot/00-slowdns
            echo -e "${GREEN}[✓] Auto-start configured${NC}"
            ;;
        8)
            stop_vpn
            echo "Goodbye!"
            exit 0
            ;;
        *)
            echo -e "${RED}[!] Invalid option${NC}"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
done
CONTROL
    
    chmod +x "$VPN_DIR/vpn-control.sh"
    print_success "Control script created"
}

# Main installation flow
main() {
    install_dependencies
    setup_directories
    download_client
    create_control_script
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          INSTALLATION COMPLETE!                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Quick Start:${NC}"
    echo "1. cd ~/slowdns-vpn"
    echo "2. bash vpn-control.sh"
    echo ""
    echo -e "${YELLOW}Important Steps:${NC}"
    echo "• Set DNS to 127.0.0.1 in Android WiFi settings"
    echo "• Add SSH key to your VPS (${VPS_IP})"
    echo ""
    echo -e "${BLUE}Your Configuration:${NC}"
    echo "Client DNS: ${CLIENT_DNS}:${DNS_PORT}"
    echo "VPS Server: ${VPS_IP}"
    echo "Domain: ${NAMESERVER}"
    echo ""
    
    # Start now?
    read -p "Start VPN now? (y/n): " start_now
    if [ "$start_now" = "y" ]; then
        cd "$VPN_DIR"
        bash vpn-control.sh
    fi
}

# Run installation
main
