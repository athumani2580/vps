cat > ~/bypass-vpn.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# TERMUX SLOWDNS VPN - BYPASS ISP DNS
# Using ISP DNS: 169.255.187.58 as tunnel entry
# ============================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
ISP_DNS="169.255.187.58"          # Your ISP DNS (bypass point)
DNS_PORT="53"                     # Standard DNS port
VPS_IP="167.71.11.57"             # Your VPS IP
SSH_PORT="22"                     # SSH port on VPS
DOMAIN="slowdns.alienalien.top"   # Your SlowDNS domain
PUBKEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"

# Paths
VPN_DIR="$HOME/.bypass-vpn"
LOG_FILE="$VPN_DIR/vpn.log"

print_header() {
    clear
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║     TERMUX VPN - BYPASS ISP DNS                 ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║ ISP DNS: $ISP_DNS:$DNS_PORT                     ║"
    echo "║ VPS Server: $VPS_IP                             ║"
    echo "║ Domain: $DOMAIN                                 ║"
    echo "║ SSH Port: $SSH_PORT                             ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${YELLOW}Strategy: Termux → ISP DNS → SlowDNS → VPS → Internet${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Install everything
install_all() {
    print_header
    print_info "Installing everything needed..."
    
    # Update
    pkg update -y && pkg upgrade -y
    
    # Install packages
    pkg install -y python openssh curl wget nmap net-tools proot expect sshpass
    
    # Permissions
    termux-setup-storage
    termux-vpn -c 2>/dev/null || print_warning "Grant VPN permission manually if asked")
    
    # Create directory
    mkdir -p "$VPN_DIR"
    cd "$VPN_DIR"
    
    print_success "Installation complete")
}

# Method 1: Python DNS Tunnel (Works best)
start_python_tunnel() {
    print_info "Starting Python DNS tunnel..."
    
    cat > "$VPN_DIR/dns-tunnel.py" << 'PYTHON'
#!/usr/bin/env python3
import socket
import sys
import time
import threading

def dns_tunnel():
    """DNS tunnel through ISP DNS to SlowDNS"""
    
    print("╔══════════════════════════════════════════════════╗")
    print("║         DNS TUNNEL - BYPASS MODE                ║")
    print("╠══════════════════════════════════════════════════╣")
    print("║ Local: 127.0.0.1:5353                           ║")
    print("║ ISP DNS: 169.255.187.58:53                      ║")
    print("║ SlowDNS Domain: slowdns.alienalien.top          ║")
    print("╚══════════════════════════════════════════════════╝")
    print("")
    
    # Create local DNS server
    local_dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    local_dns.bind(('127.0.0.1', 5353))
    local_dns.settimeout(5)
    
    print("✅ DNS server ready: 127.0.0.1:5353")
    print("📱 Set Android DNS to 127.0.0.1")
    print("🔄 Tunneling through ISP DNS...")
    print("")
    
    packet_count = 0
    try:
        while True:
            try:
                # Receive DNS query from apps
                data, client_addr = local_dns.recvfrom(512)
                
                # Forward to ISP DNS (which forwards to SlowDNS)
                remote = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                remote.sendto(data, ('169.255.187.58', 53))
                
                # Get response
                response, _ = remote.recvfrom(1024)
                
                # Send back to client
                local_dns.sendto(response, client_addr)
                
                packet_count += 1
                if packet_count % 10 == 0:
                    sys.stdout.write(f"\r📡 Packets: {packet_count}")
                    sys.stdout.flush()
                    
            except socket.timeout:
                continue
            except Exception as e:
                print(f"\n⚠️ Error: {e}")
                time.sleep(1)
                
    except KeyboardInterrupt:
        print(f"\n\n🛑 Stopped. Total packets: {packet_count}")
    finally:
        local_dns.close()

if __name__ == "__main__":
    dns_tunnel()
PYTHON
    
    chmod +x "$VPN_DIR/dns-tunnel.py"
    python3 "$VPN_DIR/dns-tunnel.py" >> "$LOG_FILE" 2>&1 &
    
    TUNNEL_PID=$!
    echo $TUNNEL_PID > "$VPN_DIR/tunnel.pid"
    sleep 3
    
    if kill -0 $TUNNEL_PID 2>/dev/null; then
        print_success "DNS tunnel active (127.0.0.1:5353)")
        return 0
    else
        print_error "Failed to start DNS tunnel")
        return 1
    fi
}

# Method 2: Using dnstt client
start_dnstt_tunnel() {
    print_info "Starting dnstt tunnel...")
    
    # Download dnstt client
    cd "$VPN_DIR"
    if wget -q "https://github.com/bamsoftware/dnstt/releases/download/v1.0/dnstt-client" -O dnstt; then
        chmod +x dnstt
        ./dnstt \
            -remote-address "$ISP_DNS:$DNS_PORT" \
            -public-key "$PUBKEY" \
            -domain "$DOMAIN" \
            -listen-address "127.0.0.1:5353" \
            -log-level info \
            >> "$LOG_FILE" 2>&1 &
    else
        print_warning "dnstt download failed, using Python method")
        start_python_tunnel
        return $?
    fi
    
    TUNNEL_PID=$!
    echo $TUNNEL_PID > "$VPN_DIR/tunnel.pid"
    sleep 5
    
    if kill -0 $TUNNEL_PID 2>/dev/null; then
        print_success "dnstt tunnel running")
        return 0
    else
        print_error "dnstt failed, trying Python...")
        start_python_tunnel
    fi
}

# SSH connection with password
start_ssh_tunnel() {
    print_info "Setting up SSH tunnel...")
    
    # Get credentials
    if [ ! -f "$VPN_DIR/credentials.txt" ]; then
        print_header
        echo ""
        echo -e "${YELLOW}=== ENTER VPS SSH CREDENTIALS ===${NC}"
        echo ""
        read -p "SSH Username [root]: " ssh_user
        ssh_user=${ssh_user:-root}
        echo -n "SSH Password: "
        read -s ssh_pass
        echo ""
        
        echo "USER=$ssh_user" > "$VPN_DIR/credentials.txt"
        echo "PASS=$ssh_pass" >> "$VPN_DIR/credentials.txt"
        chmod 600 "$VPN_DIR/credentials.txt"
    fi
    
    source "$VPN_DIR/credentials.txt"
    
    # Kill existing SSH
    pkill -f "ssh.*1080" 2>/dev/null
    
    print_info "Connecting SSH through DNS tunnel...")
    
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
    echo $SSH_PID > "$VPN_DIR/ssh.pid"
    sleep 5
    
    if kill -0 $SSH_PID 2>/dev/null; then
        print_success "SSH SOCKS5 proxy: 127.0.0.1:1080")
        print_info "Connected as: $USER")
        return 0
    else
        print_error "SSH connection failed")
        return 1
    fi
}

# Test everything
test_connection() {
    echo ""
    echo -e "${CYAN}=== CONNECTION TEST ===${NC}"
    echo ""
    
    # Test 1: DNS tunnel
    print_info "1. DNS Tunnel (ISP Bypass):"
    if timeout 5 nslookup google.com 127.0.0.1 -port=5353 >/dev/null 2>&1; then
        print_success "   ✓ Working - Bypassing ISP DNS")
    else
        print_error "   ✗ Failed")
    fi
    
    # Test 2: SSH tunnel
    print_info "2. SSH Tunnel:"
    if timeout 10 curl -s --socks5 127.0.0.1:1080 ifconfig.me >/dev/null 2>&1; then
        IP=$(curl -s --socks5 127.0.0.1:1080 ifconfig.me)
        print_success "   ✓ Working - Your IP: $IP")
        
        # Check if it's your VPS IP
        if [ "$IP" = "$VPS_IP" ] || curl -s ifconfig.me | grep -q "$VPS_IP"; then
            print_success "   ✓ Successfully routing through VPS")
        else
            print_warning "   ⚠️ Not routing through VPS - check setup")
        fi
    else
        print_error "   ✗ Failed")
    fi
    
    # Test 3: ISP DNS test
    print_info "3. ISP DNS Test:")
    if timeout 5 nslookup google.com "$ISP_DNS" >/dev/null 2>&1; then
        print_success "   ✓ ISP DNS accessible")
    else
        print_error "   ✗ ISP DNS blocked")
    fi
}

# Show bypass instructions
show_bypass_info() {
    clear
    print_header
    echo ""
    echo -e "${GREEN}=== HOW THIS BYPASS WORKS ===${NC}"
    echo ""
    echo "1. Termux creates local DNS on port 5353"
    echo "2. You set Android DNS to 127.0.0.1"
    echo "3. All DNS queries go through ISP DNS: $ISP_DNS"
    echo "4. ISP DNS forwards to SlowDNS on your VPS"
    echo "5. SSH tunnel creates SOCKS5 proxy on port 1080"
    echo "6. All internet traffic routes through VPS"
    echo ""
    echo -e "${YELLOW}=== REQUIRED SETUP ===${NC}"
    echo ""
    echo "📱 Android DNS Setting (MUST DO):"
    echo "   Settings → WiFi → Your network → Modify"
    echo "   Advanced → IP settings → Static"
    echo "   DNS 1: 127.0.0.1"
    echo "   Save and reconnect"
    echo ""
    echo "🔧 Usage:"
    echo "   • Apps: SOCKS5 proxy 127.0.0.1:1080"
    echo "   • Browser: Set proxy to 127.0.0.1:1080"
    echo "   • Termux: export HTTP_PROXY=socks5://127.0.0.1:1080"
    echo ""
    echo "🔍 Test: curl --socks5 127.0.0.1:1080 ifconfig.me"
    echo ""
}

# Stop everything
stop_vpn() {
    print_info "Stopping VPN...")
    
    # Kill processes
    if [ -f "$VPN_DIR/tunnel.pid" ]; then
        kill -9 $(cat "$VPN_DIR/tunnel.pid") 2>/dev/null
        rm -f "$VPN_DIR/tunnel.pid"
    fi
    
    if [ -f "$VPN_DIR/ssh.pid" ]; then
        kill -9 $(cat "$VPN_DIR/ssh.pid") 2>/dev/null
        rm -f "$VPN_DIR/ssh.pid"
    fi
    
    # Cleanup
    pkill -f "python.*5353" 2>/dev/null
    pkill -f "dnstt" 2>/dev/null
    pkill -f "ssh.*1080" 2>/dev/null
    pkill -f "sshpass" 2>/dev/null
    
    print_success "VPN stopped")
}

# Quick start function
quick_start() {
    print_header
    print_info "Starting VPN bypass...")
    
    # Install if needed
    if ! command -v sshpass >/dev/null; then
        install_all
    fi
    
    # Start DNS tunnel
    start_python_tunnel
    sleep 3
    
    # Start SSH tunnel
    start_ssh_tunnel
    sleep 2
    
    # Test
    test_connection
    show_bypass_info
}

# Main menu
main_menu() {
    while true; do
        clear
        print_header
        echo ""
        echo "1) Quick Start VPN"
        echo "2) Stop VPN"
        echo "3) Test Connection"
        echo "4) View Logs"
        echo "5) Change SSH Credentials"
        echo "6) Setup Auto-start"
        echo "7) Exit"
        echo ""
        echo -n "Select: "
        read choice
        
        case $choice in
            1)
                quick_start
                ;;
            2)
                stop_vpn
                ;;
            3)
                test_connection
                ;;
            4)
                echo -e "${CYAN}=== VPN LOG ===${NC}"
                tail -20 "$LOG_FILE" 2>/dev/null || echo "No log"
                echo ""
                echo -e "${CYAN}=== SSH LOG ===${NC}"
                tail -10 "$VPN_DIR/ssh.log" 2>/dev/null || echo "No SSH log"
                ;;
            5)
                rm -f "$VPN_DIR/credentials.txt"
                print_success "Credentials reset. Will ask on next start.")
                ;;
            6)
                mkdir -p ~/.termux/boot
                cat > ~/.termux/boot/00-bypass << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
sleep 20
cd $HOME
bash bypass-vpn.sh auto
BOOT
                chmod +x ~/.termux/boot/00-bypass
                print_success "Auto-start configured")
                ;;
            7)
                stop_vpn
                echo "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid option")
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Auto-start mode
if [ "$1" = "auto" ]; then
    mkdir -p "$VPN_DIR"
    if [ -f "$VPN_DIR/credentials.txt" ]; then
        start_python_tunnel
        sleep 5
        start_ssh_tunnel
    fi
    exit 0
fi

# Run main menu
mkdir -p "$VPN_DIR"
main_menu
EOF

chmod +x ~/bypass-vpn.sh
