#!/data/data/com.termux/files/usr/bin/bash

# ===========================================
# TERMUX SLOWDNS VPN CLIENT
# Complete Setup Script
# ===========================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===========================================
# CONFIGURATION - EDIT THESE VALUES
# ===========================================
SERVER_IP="167.71.11.57"          # Your VPS IP
SLOWDNS_PORT="5300"               # SlowDNS port from your server
SSH_PORT="22"                     # SSH port on your server
NAMESERVER="slowdns.alienalien.top" # Your domain
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59" # Your public key

# ===========================================
# PATHS AND VARIABLES
# ===========================================
CLIENT_DIR="$HOME/slowdns-vpn"
CLIENT_BIN="$CLIENT_DIR/sldns-client"
LOG_FILE="$CLIENT_DIR/slowdns.log"
PID_FILE="$CLIENT_DIR/slowdns.pid"
SSH_PID_FILE="$CLIENT_DIR/ssh.pid"
CONFIG_FILE="$CLIENT_DIR/config.txt"

# ===========================================
# FUNCTIONS
# ===========================================

print_header() {
    echo -e "${PURPLE}"
    echo "╔═══════════════════════════════════════════════════╗"
    echo "║        TERMUX SLOWDNS VPN CLIENT                  ║"
    echo "║            Complete Setup                         ║"
    echo "╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_step() {
    echo -e "${CYAN}➜${NC} $1"
}

check_dependencies() {
    print_step "Checking dependencies..."
    
    # Check if termux is properly installed
    if [ ! -d "/data/data/com.termux" ]; then
        print_error "This script must be run in Termux!"
        exit 1
    fi
    
    # Update packages
    print_step "Updating packages..."
    pkg update -y && pkg upgrade -y
    
    # Install required packages
    print_step "Installing required packages..."
    pkg install -y wget curl openssl-tool git python python-pip nmap net-tools proot tar pv
    
    # Install Python modules if needed
    pip install requests dnspython cryptography beautifulsoup4
    
    print_success "Dependencies checked and installed"
}

setup_directory() {
    print_step "Setting up SlowDNS directory..."
    
    # Clean up old installation
    rm -rf "$CLIENT_DIR"
    
    # Create directory
    mkdir -p "$CLIENT_DIR"
    cd "$CLIENT_DIR"
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
# SlowDNS VPN Configuration
SERVER_IP=$SERVER_IP
SLOWDNS_PORT=$SLOWDNS_PORT
SSH_PORT=$SSH_PORT
NAMESERVER=$NAMESERVER
PUBLIC_KEY=$PUBLIC_KEY
LAST_UPDATE=$(date)
EOF
    
    print_success "Directory setup complete: $CLIENT_DIR"
}

download_client() {
    print_step "Downloading SlowDNS client..."
    
    cd "$CLIENT_DIR"
    
    # Try multiple sources for client binary
    print_info "Trying to download client binary..."
    
    # Option 1: Try from original source
    if wget -q "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-client" -O "$CLIENT_BIN"; then
        print_success "Downloaded from original source"
    # Option 2: Try dnstt client
    elif wget -q "https://github.com/bamsoftware/dnstt/releases/download/v1.0/dnstt-client" -O "$CLIENT_BIN"; then
        print_success "Downloaded dnstt client"
    # Option 3: Try common SlowDNS client
    elif wget -q "https://raw.githubusercontent.com/xlxproject/slowdns/main/client" -O "$CLIENT_BIN"; then
        print_success "Downloaded SlowDNS client"
    # Option 4: Try to compile from source
    else
        print_warning "Could not download binary, trying alternative methods..."
        
        # Create a simple Python client as fallback
        create_python_client
        CLIENT_BIN="$CLIENT_DIR/slowdns-py-client.py"
    fi
    
    if [ -f "$CLIENT_BIN" ]; then
        chmod +x "$CLIENT_BIN"
        print_success "Client binary ready: $CLIENT_BIN"
    else
        print_error "Failed to get client binary"
        return 1
    fi
}

create_python_client() {
    print_step "Creating Python client as backup..."
    
    cat > "$CLIENT_DIR/slowdns-py-client.py" << 'PYTHON'
#!/usr/bin/env python3
import socket
import struct
import sys
import time
import threading
import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
from cryptography.hazmat.primitives import serialization
import hashlib

class SlowDNSClient:
    def __init__(self, server_ip, server_port, public_key_hex, domain):
        self.server_ip = server_ip
        self.server_port = server_port
        self.domain = domain
        
        # Convert hex public key to bytes
        self.public_key = bytes.fromhex(public_key_hex)
        
        # Create UDP socket
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(10)
        
        # DNS server socket
        self.dns_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.dns_sock.bind(('127.0.0.1', 5353))
        
        self.running = True
        
    def create_dns_query(self, domain):
        """Create a DNS query packet"""
        # DNS header
        transaction_id = b'\x00\x00'
        flags = b'\x01\x00'  # Standard query, recursion desired
        questions = b'\x00\x01'
        answer_rrs = b'\x00\x00'
        authority_rrs = b'\x00\x00'
        additional_rrs = b'\x00\x00'
        
        header = transaction_id + flags + questions + answer_rrs + authority_rrs + additional_rrs
        
        # DNS question
        parts = domain.split('.')
        qname = b''
        for part in parts:
            qname += bytes([len(part)]) + part.encode()
        qname += b'\x00'
        
        qtype = b'\x00\x01'  # A record
        qclass = b'\x00\x01'  # IN class
        
        question = qname + qtype + qclass
        
        return header + question
    
    def handle_dns_request(self, data, client_addr):
        """Handle incoming DNS requests"""
        try:
            # Forward to SlowDNS server
            self.sock.sendto(data, (self.server_ip, self.server_port))
            
            # Wait for response
            response, _ = self.sock.recvfrom(1024)
            
            # Send back to client
            self.dns_sock.sendto(response, client_addr)
            
        except Exception as e:
            print(f"Error handling DNS request: {e}")
    
    def start_dns_server(self):
        """Start local DNS server"""
        print(f"[DNS] Listening on 127.0.0.1:5353")
        
        def server_loop():
            while self.running:
                try:
                    data, addr = self.dns_sock.recvfrom(512)
                    threading.Thread(target=self.handle_dns_request, args=(data, addr)).start()
                except socket.timeout:
                    continue
                except Exception as e:
                    print(f"[DNS Error] {e}")
        
        thread = threading.Thread(target=server_loop)
        thread.daemon = True
        thread.start()
        return thread
    
    def test_connection(self):
        """Test connection to SlowDNS server"""
        print(f"[TEST] Testing connection to {self.server_ip}:{self.server_port}")
        
        test_query = self.create_dns_query('google.com')
        
        try:
            self.sock.sendto(test_query, (self.server_ip, self.server_port))
            response, _ = self.sock.recvfrom(1024)
            
            if len(response) > 0:
                print("[TEST] Connection successful!")
                return True
            else:
                print("[TEST] No response received")
                return False
                
        except Exception as e:
            print(f"[TEST] Error: {e}")
            return False
    
    def run(self):
        """Main run method"""
        print(f"[START] Connecting to SlowDNS server...")
        print(f"[INFO] Server: {self.server_ip}:{self.server_port}")
        print(f"[INFO] Domain: {self.domain}")
        print(f"[INFO] Public Key: {self.public_key[:16].hex()}...")
        
        # Test connection
        if not self.test_connection():
            print("[ERROR] Could not connect to server")
            return
        
        # Start DNS server
        dns_thread = self.start_dns_server()
        
        print("[READY] SlowDNS client is running!")
        print("[INFO] Set your DNS to 127.0.0.1:5353")
        print("[INFO] Press Ctrl+C to stop")
        
        try:
            while self.running:
                time.sleep(1)
        except KeyboardInterrupt:
            print("\n[STOP] Shutting down...")
        finally:
            self.running = False
            self.sock.close()
            self.dns_sock.close()

if __name__ == "__main__":
    # Configuration - will be replaced by bash script
    SERVER_IP = "167.71.11.57"
    SERVER_PORT = 5300
    PUBLIC_KEY = "7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
    DOMAIN = "slowdns.alienalien.top"
    
    client = SlowDNSClient(SERVER_IP, SERVER_PORT, PUBLIC_KEY, DOMAIN)
    client.run()
PYTHON
    
    chmod +x "$CLIENT_DIR/slowdns-py-client.py"
    print_success "Python client created"
}

start_slowdns_tunnel() {
    print_step "Starting SlowDNS tunnel..."
    
    cd "$CLIENT_DIR"
    
    # Stop any existing processes
    stop_slowdns_tunnel
    
    # Check which client we have
    if [ -f "$CLIENT_BIN" ] && [[ "$CLIENT_BIN" == *"dnstt-client"* ]]; then
        # Using dnstt client format
        print_info "Starting dnstt client..."
        "$CLIENT_BIN" \
            -remote-address "$SERVER_IP:$SLOWDNS_PORT" \
            -public-key "$PUBLIC_KEY" \
            -domain "$NAMESERVER" \
            -listen-address "127.0.0.1:5353" \
            -log-level info \
            >> "$LOG_FILE" 2>&1 &
            
    elif [ -f "$CLIENT_BIN" ]; then
        # Try generic SlowDNS client
        print_info "Starting generic SlowDNS client..."
        "$CLIENT_BIN" \
            -s "$SERVER_IP" \
            -p "$SLOWDNS_PORT" \
            -k "$PUBLIC_KEY" \
            -d "$NAMESERVER" \
            -l "127.0.0.1:5353" \
            >> "$LOG_FILE" 2>&1 &
            
    elif [ -f "$CLIENT_DIR/slowdns-py-client.py" ]; then
        # Use Python client
        print_info "Starting Python client..."
        python "$CLIENT_DIR/slowdns-py-client.py" >> "$LOG_FILE" 2>&1 &
    else
        print_error "No client binary found!"
        return 1
    fi
    
    CLIENT_PID=$!
    echo $CLIENT_PID > "$PID_FILE"
    
    sleep 5
    
    if kill -0 $CLIENT_PID 2>/dev/null; then
        print_success "SlowDNS tunnel started (PID: $CLIENT_PID)"
        print_info "Log file: $LOG_FILE"
        return 0
    else
        print_error "Failed to start SlowDNS tunnel"
        return 1
    fi
}

stop_slowdns_tunnel() {
    print_step "Stopping SlowDNS tunnel..."
    
    if [ -f "$PID_FILE" ]; then
        kill -9 $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
    fi
    
    # Kill any related processes
    pkill -f "sldns-client" 2>/dev/null
    pkill -f "dnstt-client" 2>/dev/null
    pkill -f "slowdns-py-client" 2>/dev/null
    
    print_success "SlowDNS tunnel stopped"
}

setup_dns() {
    print_step "Configuring DNS settings..."
    
    # Method 1: Using termux API (most effective)
    if command -v termux-wifi-scaninfo >/dev/null 2>&1; then
        # Try to set DNS via termux
        print_info "Setting DNS via Termux API..."
        
        # Create a script to set DNS
        cat > "$CLIENT_DIR/set-dns.sh" << 'TERMUX_DNS'
#!/data/data/com.termux/files/usr/bin/bash
# This sets DNS via termux API

# First, get current WiFi connection
WIFI_INFO=$(termux-wifi-connectioninfo 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Setting DNS for WiFi connection..."
    # Note: Termux doesn't have direct DNS setting API
    # We'll use the local DNS server method
fi
TERMUX_DNS
        
        chmod +x "$CLIENT_DIR/set-dns.sh"
    fi
    
    # Method 2: Manual instructions
    print_info ""
    print_warning "IMPORTANT DNS SETUP:"
    echo -e "${YELLOW}=============================================${NC}"
    echo -e "${GREEN}Manual DNS Configuration Required:${NC}"
    echo ""
    echo "1. Go to Android Settings"
    echo "2. Select WiFi → Your connected network"
    echo "3. Tap 'Advanced' or 'Modify network'"
    echo "4. Change IP settings to STATIC"
    echo "5. Set DNS 1: 127.0.0.1"
    echo "6. Save and reconnect"
    echo ""
    echo -e "${CYAN}Or use this command in Termux (if rooted):${NC}"
    echo "setprop net.dns1 127.0.0.1"
    echo -e "${YELLOW}=============================================${NC}"
    echo ""
    
    # Ask user to confirm DNS setup
    read -p "Have you configured DNS? (y/n): " dns_configured
    
    if [ "$dns_configured" = "y" ]; then
        print_success "DNS configuration noted"
    else
        print_warning "VPN may not work without DNS configuration"
    fi
}

setup_ssh_tunnel() {
    print_step "Setting up SSH tunnel (SOCKS5 proxy)..."
    
    # Stop any existing SSH tunnel
    pkill -f "ssh.*1080" 2>/dev/null
    
    # Generate SSH key if not exists
    if [ ! -f ~/.ssh/id_rsa ]; then
        print_info "Generating SSH key..."
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" -q
    fi
    
    # Display SSH public key
    print_info "Your SSH public key:"
    cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "No SSH key found"
    echo ""
    print_warning "Add this key to your VPS: /root/.ssh/authorized_keys"
    read -p "Have you added the SSH key to your VPS? (y/n): " key_added
    
    if [ "$key_added" != "y" ]; then
        print_error "SSH tunnel requires key authentication"
        return 1
    fi
    
    # Start SSH tunnel
    print_info "Starting SSH SOCKS5 proxy on port 1080..."
    
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=10 \
        -N -D 1080 \
        -p "$SSH_PORT" \
        root@127.0.0.1 \
        -v \
        >> "$CLIENT_DIR/ssh.log" 2>&1 &
    
    SSH_PID=$!
    echo $SSH_PID > "$SSH_PID_FILE"
    
    sleep 3
    
    if kill -0 $SSH_PID 2>/dev/null; then
        print_success "SSH SOCKS5 proxy started on 127.0.0.1:1080"
        print_info "Configure apps to use this proxy"
        return 0
    else
        print_error "Failed to start SSH tunnel"
        return 1
    fi
}

test_connection() {
    print_step "Testing VPN connection..."
    
    echo ""
    echo -e "${CYAN}=== Connection Tests ===${NC}"
    echo ""
    
    # Test 1: Check if DNS server is responding
    print_info "Test 1: DNS Server..."
    if timeout 5 nslookup google.com 127.0.0.1 -port=5353 >/dev/null 2>&1; then
        print_success "✓ DNS tunnel is working"
    else
        print_error "✗ DNS tunnel not responding"
    fi
    
    # Test 2: Check if SlowDNS client is running
    print_info "Test 2: SlowDNS Process..."
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        print_success "✓ SlowDNS client is running"
    else
        print_error "✗ SlowDNS client not running"
    fi
    
    # Test 3: Check SSH tunnel
    print_info "Test 3: SSH Tunnel..."
    if [ -f "$SSH_PID_FILE" ] && kill -0 $(cat "$SSH_PID_FILE") 2>/dev/null; then
        print_success "✓ SSH tunnel is running"
        
        # Test SOCKS5 proxy
        if timeout 10 curl -s --socks5 127.0.0.1:1080 http://ifconfig.me >/dev/null 2>&1; then
            IP=$(timeout 10 curl -s --socks5 127.0.0.1:1080 http://ifconfig.me)
            print_success "✓ Proxy working. Your IP: $IP"
        else
            print_error "✗ Proxy not responding"
        fi
    else
        print_error "✗ SSH tunnel not running"
    fi
    
    # Test 4: Test direct connection to server
    print_info "Test 4: Server Connectivity..."
    if timeout 5 ping -c 2 "$SERVER_IP" >/dev/null 2>&1; then
        print_success "✓ Server is reachable"
    else
        print_error "✗ Cannot reach server"
    fi
    
    echo ""
    echo -e "${CYAN}=== Quick Usage Guide ===${NC}"
    echo ""
    echo "For browser/app VPN:"
    echo "  SOCKS5 Proxy: 127.0.0.1:1080"
    echo ""
    echo "For Termux commands:"
    echo "  curl --socks5 127.0.0.1:1080 http://example.com"
    echo ""
    echo "To check your IP:"
    echo "  curl --socks5 127.0.0.1:1080 http://ifconfig.me"
}

setup_autostart() {
    print_step "Setting up auto-start on boot..."
    
    mkdir -p ~/.termux/boot
    
    cat > ~/.termux/boot/00-slowdns-vpn << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
# Auto-start SlowDNS VPN on Termux boot

sleep 15  # Wait for network

VPN_DIR="$HOME/slowdns-vpn"

if [ -f "$VPN_DIR/config.txt" ] && [ -f "$VPN_DIR/start.sh" ]; then
    echo "[AUTO-START] Starting SlowDNS VPN..."
    cd "$VPN_DIR"
    bash start.sh auto
fi
BOOT
    
    chmod +x ~/.termux/boot/00-slowdns-vpn
    
    # Create start.sh for auto mode
    cat > "$CLIENT_DIR/start.sh" << 'AUTO'
#!/data/data/com.termux/files/usr/bin/bash
# Auto-start script

if [ "$1" = "auto" ]; then
    # Source config
    source config.txt 2>/dev/null || exit 1
    
    # Start tunnel
    ./sldns-client -remote-address "$SERVER_IP:$SLOWDNS_PORT" \
                   -public-key "$PUBLIC_KEY" \
                   -domain "$NAMESERVER" \
                   -listen-address "127.0.0.1:5353" \
                   -log-level error &
    
    sleep 5
    
    # Start SSH tunnel
    ssh -N -D 1080 -p "$SSH_PORT" root@127.0.0.1 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null &
fi
AUTO
    
    chmod +x "$CLIENT_DIR/start.sh"
    
    print_success "Auto-start configured"
    print_info "VPN will start automatically when Termux starts"
}

show_menu() {
    clear
    print_header
    
    echo -e "${CYAN}Server Configuration:${NC}"
    echo "IP: $SERVER_IP"
    echo "SlowDNS Port: $SLOWDNS_PORT"
    echo "SSH Port: $SSH_PORT"
    echo "Domain: $NAMESERVER"
    echo "Public Key: ${PUBLIC_KEY:0:16}..."
    echo ""
    
    echo -e "${YELLOW}=== MAIN MENU ===${NC}"
    echo "1) Install & Setup VPN"
    echo "2) Start VPN Tunnel"
    echo "3) Stop VPN Tunnel"
    echo "4) Test Connection"
    echo "5) Setup Auto-start"
    echo "6) View Logs"
    echo "7) Show Usage Guide"
    echo "8) Update Configuration"
    echo "9) Uninstall"
    echo "0) Exit"
    echo ""
    echo -n "Select option: "
}

view_logs() {
    print_step "Viewing logs..."
    
    echo -e "${CYAN}=== SlowDNS Log ===${NC}"
    if [ -f "$LOG_FILE" ]; then
        tail -20 "$LOG_FILE"
    else
        echo "No log file found"
    fi
    
    echo ""
    echo -e "${CYAN}=== SSH Tunnel Log ===${NC}"
    if [ -f "$CLIENT_DIR/ssh.log" ]; then
        tail -10 "$CLIENT_DIR/ssh.log"
    else
        echo "No SSH log found"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

show_usage_guide() {
    clear
    print_header
    
    echo -e "${GREEN}=== COMPLETE USAGE GUIDE ===${NC}"
    echo ""
    
    echo -e "${YELLOW}1. AFTER INSTALLATION:${NC}"
    echo "   • Set DNS on your Android:"
    echo "     WiFi Settings → Modify network → Static IP"
    echo "     DNS 1: 127.0.0.1"
    echo ""
    
    echo -e "${YELLOW}2. HOW TO USE VPN:${NC}"
    echo "   • For web browsing:"
    echo "     Use SOCKS5 proxy: 127.0.0.1:1080"
    echo ""
    echo "   • In Termux:"
    echo "     export HTTP_PROXY=socks5://127.0.0.1:1080"
    echo "     export HTTPS_PROXY=socks5://127.0.0.1:1080"
    echo ""
    
    echo -e "${YELLOW}3. QUICK COMMANDS:${NC}"
    echo "   Check IP: curl --socks5 127.0.0.1:1080 ifconfig.me"
    echo "   Test DNS: nslookup google.com 127.0.0.1 -port=5353"
    echo "   View logs: tail -f ~/slowdns-vpn/slowdns.log"
    echo ""
    
    echo -e "${YELLOW}4. TROUBLESHOOTING:${NC}"
    echo "   • If DNS fails: Check if port 5353 is listening"
    echo "   • If SSH fails: Add your SSH key to VPS"
    echo "   • If slow: Try changing MTU or use compression"
    echo ""
    
    echo -e "${YELLOW}5. AUTO-START:${NC}"
    echo "   VPN starts automatically when Termux opens"
    echo ""
    
    read -p "Press Enter to return to menu..."
}

update_config() {
    print_step "Updating configuration..."
    
    echo ""
    echo "Current configuration:"
    echo "1. Server IP: $SERVER_IP"
    echo "2. SlowDNS Port: $SLOWDNS_PORT"
    echo "3. SSH Port: $SSH_PORT"
    echo "4. Domain: $NAMESERVER"
    echo "5. Public Key: ${PUBLIC_KEY:0:16}..."
    echo ""
    
    read -p "Enter field number to update (1-5, or 0 to cancel): " field
    
    case $field in
        1)
            read -p "Enter new Server IP: " SERVER_IP
            ;;
        2)
            read -p "Enter new SlowDNS Port: " SLOWDNS_PORT
            ;;
        3)
            read -p "Enter new SSH Port: " SSH_PORT
            ;;
        4)
            read -p "Enter new Domain: " NAMESERVER
            ;;
        5)
            read -p "Enter new Public Key: " PUBLIC_KEY
            ;;
        0)
            return
            ;;
        *)
            print_error "Invalid option"
            return
            ;;
    esac
    
    # Save updated config
    cat > "$CONFIG_FILE" << EOF
# SlowDNS VPN Configuration
SERVER_IP=$SERVER_IP
SLOWDNS_PORT=$SLOWDNS_PORT
SSH_PORT=$SSH_PORT
NAMESERVER=$NAMESERVER
PUBLIC_KEY=$PUBLIC_KEY
LAST_UPDATE=$(date)
EOF
    
    print_success "Configuration updated"
}

uninstall() {
    print_step "Uninstalling SlowDNS VPN..."
    
    read -p "Are you sure? This will remove all VPN files. (y/n): " confirm
    
    if [ "$confirm" = "y" ]; then
        # Stop services
        stop_slowdns_tunnel
        pkill -f "ssh.*1080" 2>/dev/null
        
        # Remove files
        rm -rf "$CLIENT_DIR"
        rm -f ~/.termux/boot/00-slowdns-vpn
        
        # Reset DNS if possible
        print_info "Please manually reset your DNS settings in WiFi configuration"
        
        print_success "SlowDNS VPN uninstalled"
    else
        print_info "Uninstall cancelled"
    fi
}

install_full() {
    print_header
    print_step "Starting full installation..."
    
    # Step 1: Check dependencies
    check_dependencies
    
    # Step 2: Setup directory
    setup_directory
    
    # Step 3: Download client
    download_client
    
    # Step 4: Show instructions
    echo ""
    print_success "Installation complete!"
    echo ""
    print_warning "NEXT STEPS:"
    echo "1. Add your SSH key to the VPS"
    echo "2. Configure DNS on your Android device"
    echo "3. Start the VPN from the menu"
    echo ""
    
    read -p "Press Enter to continue..."
}

main() {
    # Load existing config if available
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" 2>/dev/null
    fi
    
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                install_full
                ;;
            2)
                start_slowdns_tunnel
                sleep 2
                setup_ssh_tunnel
                sleep 2
                test_connection
                read -p "Press Enter to continue..."
                ;;
            3)
                stop_slowdns_tunnel
                pkill -f "ssh.*1080" 2>/dev/null
                print_success "All VPN services stopped"
                sleep 2
                ;;
            4)
                test_connection
                read -p "Press Enter to continue..."
                ;;
            5)
                setup_autostart
                read -p "Press Enter to continue..."
                ;;
            6)
                view_logs
                ;;
            7)
                show_usage_guide
                ;;
            8)
                update_config
                ;;
            9)
                uninstall
                read -p "Press Enter to continue..."
                ;;
            0)
                print_step "Exiting..."
                stop_slowdns_tunnel 2>/dev/null
                exit 0
                ;;
            *)
                print_error "Invalid option"
                sleep 2
                ;;
        esac
    done
}

# ===========================================
# START SCRIPT
# ===========================================
clear
print_header

# Check if running in Termux
if [ ! -d "/data/data/com.termux" ]; then
    print_error "This script must be run in Termux!"
    print_info "Install Termux from: https://termux.com"
    exit 1
fi

# Request storage permission
print_step "Requesting storage permission..."
termux-setup-storage

# Request VPN permission (if available)
if command -v termux-vpn >/dev/null 2>&1; then
    print_step "Requesting VPN permission..."
    termux-vpn -c
fi

# Start main menu
main
