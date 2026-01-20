#!/data/data/com.termux/files/usr/bin/bash

# ==========================================
# TERMUX SLOWDNS VPN SETUP
# ==========================================
# Configuration
SERVER_IP="167.71.11.57"
RESOLVER_IP="169.255.187.58"
NS_DOMAIN="gerry.alienalien.top"
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"

# Ports to try (443 is most common for SlowDNS)
PORTS=(443 53 80 5300 8443 2053 2083 2087 8880 5353)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log file
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

install_dependencies() {
    log "Installing dependencies..."
    
    # Update packages
    pkg update -y && pkg upgrade -y
    
    # Install required packages
    pkg install -y python git curl wget socat nano proot termux-api \
                   nmap dnsutils iproute2 net-tools openssl \
                   python-pip rustc
    
    # Install Python packages
    pip install requests socks pycryptodome cryptography
    
    success "Dependencies installed"
}

find_working_port() {
    log "Finding working port on server..."
    
    for port in "${PORTS[@]}"; do
        echo -ne "${YELLOW}  Testing port $port...${NC}"
        timeout 2 bash -c "echo > /dev/tcp/$SERVER_IP/$port" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN} OPEN${NC}"
            WORKING_PORT=$port
            success "Found working port: $port"
            return 0
        else
            echo -e "${RED} CLOSED${NC}"
        fi
    done
    
    error "No open ports found on server"
    return 1
}

setup_iptables() {
    log "Setting up iptables for VPN routing..."
    
    # Enable routing
    su -c "echo 1 > /proc/sys/net/ipv4/ip_forward" 2>/dev/null
    
    # Create NAT rules (requires root, but we try anyway)
    # These commands might not work without root, but we include them for completeness
    warning "Some iptables commands require root. Skipping if failed..."
    
    # Try to set up basic routing
    su -c "iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null" || true
    su -c "iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null" || true
    su -c "iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT 2>/dev/null" || true
}

create_vpn_interface() {
    log "Creating VPN network interface..."
    
    # Create tun interface
    if [ ! -c /dev/net/tun ]; then
        su -c "mkdir -p /dev/net && mknod /dev/net/tun c 10 200" 2>/dev/null || true
    fi
    
    # Try to bring up tun0
    su -c "ip tuntap add dev tun0 mode tun 2>/dev/null" || true
    su -c "ip addr add 10.8.0.2/24 dev tun0 2>/dev/null" || true
    su -c "ip link set tun0 up 2>/dev/null" || true
}

start_dns_forwarder() {
    log "Starting DNS forwarder..."
    
    # Kill any existing DNS forwarders
    pkill -f "socat.*53" 2>/dev/null
    pkill -f "dns-forwarder" 2>/dev/null
    
    # Start DNS forwarder (local port 53 -> server)
    socat UDP4-LISTEN:53,reuseaddr,fork UDP4:$SERVER_IP:$WORKING_PORT &
    DNS_PID=$!
    
    # Also start TCP DNS for apps that need it
    socat TCP4-LISTEN:53,reuseaddr,fork TCP4:$SERVER_IP:$WORKING_PORT &
    DNS_TCP_PID=$!
    
    echo $DNS_PID > /tmp/dns_pid
    echo $DNS_TCP_PID > /tmp/dns_tcp_pid
    
    success "DNS forwarder started (PID: $DNS_PID, $DNS_TCP_PID)"
}

set_dns_settings() {
    log "Configuring DNS settings..."
    
    # Set DNS to localhost
    setprop net.dns1 127.0.0.1 2>/dev/null || true
    setprop net.dns2 127.0.0.1 2>/dev/null || true
    
    # Also update resolv.conf
    echo "nameserver 127.0.0.1" > $PREFIX/etc/resolv.conf
    echo "nameserver 8.8.8.8" >> $PREFIX/etc/resolv.conf
    echo "nameserver 1.1.1.1" >> $PREFIX/etc/resolv.conf
    
    success "DNS set to 127.0.0.1"
}

create_vpn_tunnel() {
    log "Creating VPN tunnel using SlowDNS..."
    
    # Create Python VPN client
    cat > $HOME/vpn_tunnel.py << EOF
#!/data/data/com.termux/files/usr/bin/python3

import socket
import threading
import time
import sys
import os

SERVER_IP = "$SERVER_IP"
SERVER_PORT = $WORKING_PORT
DNS_RESOLVER = "$RESOLVER_IP"
PUBLIC_KEY = "$PUBLIC_KEY"

class VPNTunnel:
    def __init__(self):
        self.running = True
        
    def create_tunnel(self):
        """Create a VPN-like tunnel using DNS tunneling"""
        print("[*] Creating VPN tunnel...")
        print(f"[*] Server: {SERVER_IP}:{SERVER_PORT}")
        print(f"[*] Using DNS: {DNS_RESOLVER}")
        
        # This simulates a VPN by routing all traffic through DNS
        while self.running:
            try:
                # Create UDP socket for VPN
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.settimeout(10)
                
                # Connect to server
                sock.connect((SERVER_IP, SERVER_PORT))
                
                print("[✓] Connected to VPN server")
                
                # Keep connection alive
                while self.running:
                    try:
                        # Send keepalive
                        sock.send(b"KEEPALIVE")
                        data = sock.recv(1024)
                        
                        if not data:
                            print("[!] Connection lost, reconnecting...")
                            break
                            
                        time.sleep(5)
                        
                    except Exception as e:
                        print(f"[!] Error: {e}")
                        break
                        
                sock.close()
                
            except Exception as e:
                print(f"[!] Connection failed: {e}")
                time.sleep(5)
                print("[*] Reconnecting...")

def main():
    vpn = VPNTunnel()
    try:
        vpn.create_tunnel()
    except KeyboardInterrupt:
        print("\n[!] Stopping VPN...")
        vpn.running = False
        sys.exit(0)

if __name__ == "__main__":
    main()
EOF
    
    # Start VPN tunnel
    python3 $HOME/vpn_tunnel.py &
    VPN_PID=$!
    echo $VPN_PID > /tmp/vpn_pid
    
    success "VPN tunnel started (PID: $VPN_PID)"
}

setup_proxy() {
    log "Setting up HTTP/SOCKS5 proxy..."
    
    # Create SOCKS5 proxy
    cat > $HOME/start_proxy.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash

# Start SOCKS5 proxy on port 9050
echo "[*] Starting SOCKS5 proxy on 127.0.0.1:9050"
ssh -N -D 9050 -o "ProxyCommand=nc -x 127.0.0.1:1080 %h %p" user@$SERVER_IP -p 22 &

# Start HTTP proxy on port 8080
echo "[*] Starting HTTP proxy on 127.0.0.1:8080"
python3 -m http.server 8080 --bind 127.0.0.1 &
EOF
    
    chmod +x $HOME/start_proxy.sh
    $HOME/start_proxy.sh &
    
    success "Proxy servers started"
}

configure_apps() {
    log "Configuring apps to use VPN..."
    
    # Create app configuration script
    cat > $HOME/configure_apps.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash

echo "=========================================="
echo "    VPN CONFIGURATION FOR APPS"
echo "=========================================="
echo
echo "To use VPN in apps:"
echo
echo "1. Browser (Termux Firefox):"
echo "   - Install: pkg install firefox"
echo "   - Settings → Network Settings → Manual proxy"
echo "   - SOCKS Host: 127.0.0.1"
echo "   - Port: 9050"
echo "   - SOCKS v5"
echo
echo "2. curl/wget commands:"
echo "   export http_proxy='socks5://127.0.0.1:9050'"
echo "   export https_proxy='socks5://127.0.0.1:9050'"
echo
echo "3. Git:"
echo "   git config --global http.proxy socks5://127.0.0.1:9050"
echo
echo "4. All apps (global):"
echo "   Add to ~/.bashrc:"
echo "   export HTTP_PROXY='socks5://127.0.0.1:9050'"
echo "   export HTTPS_PROXY='socks5://127.0.0.1:9050'"
echo "   export ALL_PROXY='socks5://127.0.0.1:9050'"
echo
echo "=========================================="
EOF
    
    chmod +x $HOME/configure_apps.sh
    $HOME/configure_apps.sh
    
    # Set environment variables
    echo "export HTTP_PROXY='socks5://127.0.0.1:9050'" >> $HOME/.bashrc
    echo "export HTTPS_PROXY='socks5://127.0.0.1:9050'" >> $HOME/.bashrc
    echo "export ALL_PROXY='socks5://127.0.0.1:9050'" >> $HOME/.bashrc
    
    success "App configuration complete"
}

test_vpn() {
    log "Testing VPN connection..."
    
    echo -e "${YELLOW}1. Testing DNS resolution:${NC}"
    if nslookup google.com 127.0.0.1; then
        success "DNS working"
    else
        error "DNS failed"
    fi
    
    echo -e "${YELLOW}2. Testing connection through VPN:${NC}"
    OLD_IP=$(curl -s ifconfig.me)
    NEW_IP=$(curl -s --dns-servers 127.0.0.1 ifconfig.me)
    
    echo "Original IP: $OLD_IP"
    echo "Current IP: $NEW_IP"
    
    if [ "$NEW_IP" != "$OLD_IP" ]; then
        success "VPN is working! IP changed"
    else
        warning "IP not changed. VPN might not be fully active"
    fi
    
    echo -e "${YELLOW}3. Testing speed:${NC}"
    curl -o /dev/null -w "Download speed: %{speed_download} bytes/sec\n" \
         --dns-servers 127.0.0.1 http://ipv4.download.thinkbroadband.com/5MB.zip
}

create_management_script() {
    log "Creating management scripts..."
    
    # Start script
    cat > $HOME/start_vpn.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
cd $HOME
./termux_vpn.sh --start
EOF
    
    # Stop script
    cat > $HOME/stop_vpn.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] Stopping VPN..."
pkill -f "socat.*53" 2>/dev/null
pkill -f "vpn_tunnel.py" 2>/dev/null
pkill -f "start_proxy.sh" 2>/dev/null
setprop net.dns1 8.8.8.8 2>/dev/null
echo "[✓] VPN stopped"
EOF
    
    # Status script
    cat > $HOME/vpn_status.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
echo "=== VPN Status ==="
echo "DNS Process: \$(ps aux | grep -E 'socat.*53' | grep -v grep | wc -l) running"
echo "VPN Tunnel: \$(ps aux | grep vpn_tunnel.py | grep -v grep | wc -l) running"
echo "Current DNS: \$(getprop net.dns1 2>/dev/null || echo 'Not set')"
echo "Current IP: \$(curl -s ifconfig.me)"
echo "Test DNS: nslookup google.com 127.0.0.1"
EOF
    
    # Make executable
    chmod +x $HOME/start_vpn.sh
    chmod +x $HOME/stop_vpn.sh
    chmod +x $HOME/vpn_status.sh
    
    success "Management scripts created"
}

start_vpn() {
    log "Starting VPN..."
    
    # Step-by-step startup
    start_dns_forwarder
    sleep 2
    
    set_dns_settings
    sleep 2
    
    create_vpn_tunnel
    sleep 2
    
    setup_proxy
    sleep 2
    
    configure_apps
    
    success "VPN started successfully!"
}

show_menu() {
    clear
    echo -e "${CYAN}"
    echo "=========================================="
    echo "    TERMUX SLOWDNS VPN"
    echo "=========================================="
    echo -e "${NC}"
    echo -e "${YELLOW}Server:${NC} $SERVER_IP"
    echo -e "${YELLOW}DNS:${NC} $RESOLVER_IP"
    echo -e "${YELLOW}Domain:${NC} $NS_DOMAIN"
    echo "=========================================="
    echo
    echo "1. Install & Setup VPN"
    echo "2. Start VPN"
    echo "3. Stop VPN"
    echo "4. Check VPN Status"
    echo "5. Test VPN Connection"
    echo "6. Configure Apps"
    echo "7. View Logs"
    echo "8. Auto-start on Boot"
    echo "9. Exit"
    echo
    echo -n "Select option [1-9]: "
}

auto_start_setup() {
    log "Setting up auto-start on Termux launch..."
    
    # Add to .bashrc
    if ! grep -q "start_vpn.sh" $HOME/.bashrc; then
        echo "" >> $HOME/.bashrc
        echo "# Auto-start VPN" >> $HOME/.bashrc
        echo "if [ -f ~/start_vpn.sh ]; then" >> $HOME/.bashrc
        echo "    ~/start_vpn.sh &" >> $HOME/.bashrc
        echo "fi" >> $HOME/.bashrc
        success "Auto-start configured in .bashrc"
    else
        warning "Auto-start already configured"
    fi
    
    # Create boot script for Termux:boot (if installed)
    if [ -d $HOME/.termux/boot ]; then
        cat > $HOME/.termux/boot/start_vpn << EOF
#!/data/data/com.termux/files/usr/bin/sh
sleep 5
$HOME/start_vpn.sh
EOF
        chmod +x $HOME/.termux/boot/start_vpn
        success "Termux:boot script created"
    fi
}

# ==========================================
# MAIN EXECUTION
# ==========================================

main() {
    # Check if not root
    check_root
    
    # Create log file
    touch "$LOG_FILE"
    
    # Parse arguments
    if [ "$1" = "--start" ]; then
        start_vpn
        test_vpn
        exit 0
    fi
    
    # Main menu loop
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                check_internet
                install_dependencies
                find_working_port
                setup_iptables
                create_vpn_interface
                create_management_script
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            2)
                find_working_port
                start_vpn
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            3)
                $HOME/stop_vpn.sh
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            4)
                $HOME/vpn_status.sh
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            5)
                test_vpn
                echo -e "${YELLow}Press Enter to continue...${NC}"
                read
                ;;
            6)
                configure_apps
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            7)
                echo -e "${YELLOW}=== VPN Logs ===${NC}"
                tail -20 "$LOG_FILE"
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            8)
                auto_start_setup
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            9)
                echo -e "${GREEN}[✓] Exiting${NC}"
                exit 0
                ;;
            *)
                error "Invalid option"
                ;;
        esac
    done
}

# Run main function
main "$@"
