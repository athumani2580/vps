#!/data/data/com.termux/files/usr/bin/bash

# =============================================
# Termux SlowDNS VPN Client
# Server: 139.84.240.171
# DNS: 169.255.187.58:53
# Nameserver: gerry.alienalien.top
# Public Key: 7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59
# =============================================

# Configuration
SERVER_IP="139.84.240.171"
SSH_PORT="2222"
DNS_SERVER="169.255.187.58"
DNS_PORT="53"
NAMESERVER="gerry.alienalien.top"
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
SLOWDNS_PORT="5300"
LOCAL_PORT="1080"
LOCAL_DNS_PORT="5353"

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

# Directories
CONFIG_DIR="$HOME/.slowdns-vpn"
LOG_FILE="$CONFIG_DIR/vpn.log"
PID_FILE="$CONFIG_DIR/vpn.pid"

# Functions
print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║          TERMUX SLOWDNS VPN              ║"
    echo "║        Encrypted DNS Tunneling           ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[i]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[→]${NC} $1"
}

check_requirements() {
    print_step "Checking requirements..."
    
    if ! command -v pkg &> /dev/null; then
        print_error "Termux pkg not found. Are you in Termux?"
        exit 1
    fi
    
    # Check if running as root (optional for VPN)
    if [ "$(whoami)" = "root" ]; then
        print_info "Running as root - better for VPN"
    fi
    
    # Create config directory
    mkdir -p "$CONFIG_DIR"
}

install_dependencies() {
    print_step "Installing dependencies..."
    
    pkg update -y && pkg upgrade -y
    
    # Required packages
    pkg install -y openssh curl wget netcat-openbsd dnsutils \
                   proot termux-api termux-tools iproute2 \
                   nmap python python-pip
    
    # Python packages for advanced features
    pip install requests pysocks
    
    print_status "Dependencies installed"
}

download_slowdns_client() {
    print_step "Downloading SlowDNS client..."
    
    # Try multiple sources for the client
    CLIENT_URLS=(
        "https://github.com/athumani2580/vps/raw/main/slowdns/sldns"
        "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns"
        "https://cdn.jsdelivr.net/gh/athumani2580/vps@main/slowdns/sldns"
    )
    
    for url in "${CLIENT_URLS[@]}"; do
        print_info "Trying: $url"
        if wget -q "$url" -O "$CONFIG_DIR/sldns-client"; then
            chmod +x "$CONFIG_DIR/sldns-client"
            print_status "SlowDNS client downloaded"
            return 0
        fi
    done
    
    # If download fails, create a simple DNS client script
    print_info "Creating alternative DNS client..."
    
    cat > "$CONFIG_DIR/dns-client.py" << 'EOF'
#!/data/data/com.termux/files/usr/bin/python3
import socket
import sys
import threading

def dns_tunnel_client(local_port=5353, dns_server="169.255.187.58", dns_port=53):
    """Simple DNS tunnel client"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', local_port))
    
    print(f"[*] DNS Client listening on 127.0.0.1:{local_port}")
    print(f"[*] Forwarding to {dns_server}:{dns_port}")
    
    while True:
        try:
            data, addr = sock.recvfrom(512)
            # Forward to DNS server
            dns_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            dns_sock.sendto(data, (dns_server, dns_port))
            response, _ = dns_sock.recvfrom(512)
            dns_sock.close()
            # Send response back
            sock.sendto(response, addr)
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"[!] Error: {e}")
    
    sock.close()

if __name__ == "__main__":
    dns_tunnel_client()
EOF
    
    chmod +x "$CONFIG_DIR/dns-client.py"
    print_status "Alternative DNS client created"
    return 1
}

setup_ssh_tunnel() {
    print_step "Setting up SSH SOCKS tunnel..."
    
    # Check if SSH key exists, generate if not
    if [ ! -f "$HOME/.ssh/id_rsa" ]; then
        print_info "Generating SSH key..."
        ssh-keygen -t rsa -b 2048 -N "" -f "$HOME/.ssh/id_rsa" > /dev/null 2>&1
        
        # Display public key for server setup
        echo ""
        print_info "Your SSH Public Key:"
        cat "$HOME/.ssh/id_rsa.pub"
        echo ""
        print_info "Add this key to /root/.ssh/authorized_keys on your server"
        read -p "Press Enter after adding the key to server..."
    fi
    
    # Kill existing SSH tunnel
    pkill -f "ssh.*$LOCAL_PORT" 2>/dev/null
    
    # Start SSH SOCKS proxy
    print_info "Starting SSH SOCKS5 proxy on port $LOCAL_PORT..."
    ssh -f -N -D "$LOCAL_PORT" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        root@"$SERVER_IP" \
        > "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        print_status "SSH SOCKS5 proxy started on 127.0.0.1:$LOCAL_PORT"
        echo "$!" > "$PID_FILE.ssh"
        return 0
    else
        print_error "Failed to start SSH tunnel"
        return 1
    fi
}

setup_dns() {
    print_step "Configuring DNS..."
    
    # Create custom resolv.conf
    cat > "$CONFIG_DIR/resolv.conf" << EOF
# SlowDNS VPN Configuration
nameserver 127.0.0.1
nameserver $DNS_SERVER
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    
    # Try to set DNS (requires root or special permissions)
    if [ -w /etc/resolv.conf ]; then
        cp "$CONFIG_DIR/resolv.conf" /etc/resolv.conf
        print_status "System DNS configured"
    else
        print_info "Manual DNS configuration required"
        echo -e "${YELLOW}Please set DNS to: 127.0.0.1 or $DNS_SERVER${NC}"
    fi
    
    # Start DNS client if available
    if [ -f "$CONFIG_DIR/sldns-client" ]; then
        print_info "Starting SlowDNS client..."
        "$CONFIG_DIR/sldns-client" -udp ":$LOCAL_DNS_PORT" \
            -pubkey-file <(echo "$PUBLIC_KEY" | xxd -r -p) \
            "$NAMESERVER" "$SERVER_IP:$SLOWDNS_PORT" \
            >> "$LOG_FILE" 2>&1 &
        echo "$!" > "$PID_FILE.dns"
        print_status "SlowDNS client started on port $LOCAL_DNS_PORT"
    elif [ -f "$CONFIG_DIR/dns-client.py" ]; then
        print_info "Starting Python DNS client..."
        python3 "$CONFIG_DIR/dns-client.py" >> "$LOG_FILE" 2>&1 &
        echo "$!" > "$PID_FILE.dns"
        print_status "DNS client started"
    fi
}

setup_iptables() {
    print_step "Setting up routing rules..."
    
    # Note: iptables requires root in Termux
    if [ "$(whoami)" != "root" ]; then
        print_info "Run as root for full VPN routing: su -c './termux-slowdns-vpn.sh'"
        return
    fi
    
    # Basic routing (if rooted)
    print_info "Setting up proxy rules..."
    
    # Create routing script
    cat > "$CONFIG_DIR/routing.sh" << 'EOF'
#!/system/bin/sh
# Routing script for rooted devices

# Set DNS
iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5353
iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5353

# Redirect HTTP traffic through SOCKS (requires redsocks)
# iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-port 8123

echo "[*] Routing rules applied"
EOF
    
    chmod +x "$CONFIG_DIR/routing.sh"
    print_info "Routing script created at: $CONFIG_DIR/routing.sh"
}

start_vpn() {
    print_header
    
    check_requirements
    
    # Install if first run
    if [ ! -f "$CONFIG_DIR/installed" ]; then
        install_dependencies
        download_slowdns_client
        touch "$CONFIG_DIR/installed"
    fi
    
    print_step "Starting SlowDNS VPN..."
    
    # 1. Start SSH tunnel
    if setup_ssh_tunnel; then
        # 2. Setup DNS
        setup_dns
        # 3. Setup routing if root
        setup_iptables
        
        print_header
        echo -e "${GREEN}"
        echo "╔══════════════════════════════════════════╗"
        echo "║        VPN STARTED SUCCESSFULLY!         ║"
        echo "╚══════════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        echo -e "${CYAN}════════ CONNECTION DETAILS ════════${NC}"
        echo -e "SOCKS5 Proxy: ${GREEN}127.0.0.1:$LOCAL_PORT${NC}"
        echo -e "DNS Server:   ${GREEN}127.0.0.1:$LOCAL_DNS_PORT${NC}"
        echo -e "SSH Server:   ${GREEN}$SERVER_IP:$SSH_PORT${NC}"
        echo -e "Public DNS:   ${GREEN}$DNS_SERVER:$DNS_PORT${NC}"
        echo ""
        echo -e "${CYAN}════════ USAGE INSTRUCTIONS ════════${NC}"
        echo -e "For Apps/Proxy:"
        echo -e "  Type: SOCKS5"
        echo -e "  Host: 127.0.0.1"
        echo -e "  Port: $LOCAL_PORT"
        echo ""
        echo -e "Test with curl:"
        echo -e "  ${YELLOW}curl --socks5 127.0.0.1:$LOCAL_PORT http://ipinfo.io${NC}"
        echo ""
        echo -e "Check status:"
        echo -e "  ${YELLOW}./termux-slowdns-vpn.sh status${NC}"
        echo ""
        echo -e "${GREEN}Press Ctrl+C to stop VPN${NC}"
        
        # Keep script running
        tail -f "$LOG_FILE"
    else
        print_error "Failed to start VPN"
        exit 1
    fi
}

stop_vpn() {
    print_step "Stopping VPN..."
    
    # Kill processes
    if [ -f "$PID_FILE.ssh" ]; then
        kill $(cat "$PID_FILE.ssh") 2>/dev/null
        rm -f "$PID_FILE.ssh"
    fi
    
    if [ -f "$PID_FILE.dns" ]; then
        kill $(cat "$PID_FILE.dns") 2>/dev/null
        rm -f "$PID_FILE.dns"
    fi
    
    # Kill any related processes
    pkill -f "ssh.*$LOCAL_PORT" 2>/dev/null
    pkill -f "sldns-client" 2>/dev/null
    pkill -f "dns-client.py" 2>/dev/null
    
    # Reset DNS if possible
    if [ -w /etc/resolv.conf ]; then
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    
    print_status "VPN stopped"
    rm -f "$PID_FILE"
}

show_status() {
    print_header
    
    echo -e "${CYAN}════════ VPN STATUS ════════${NC}"
    echo ""
    
    # Check SSH tunnel
    if pgrep -f "ssh.*$LOCAL_PORT" > /dev/null; then
        echo -e "SOCKS Proxy: ${GREEN}RUNNING${NC} (127.0.0.1:$LOCAL_PORT)"
    else
        echo -e "SOCKS Proxy: ${RED}STOPPED${NC}"
    fi
    
    # Check DNS client
    if pgrep -f "sldns-client" > /dev/null || pgrep -f "dns-client.py" > /dev/null; then
        echo -e "DNS Client:  ${GREEN}RUNNING${NC}"
    else
        echo -e "DNS Client:  ${RED}STOPPED${NC}"
    fi
    
    # Test connection to server
    echo ""
    echo -e "${CYAN}════════ SERVER TEST ════════${NC}"
    
    if timeout 3 nc -z "$SERVER_IP" "$SSH_PORT" 2>/dev/null; then
        echo -e "SSH ($SSH_PORT):   ${GREEN}ACCESSIBLE${NC}"
    else
        echo -e "SSH ($SSH_PORT):   ${RED}BLOCKED${NC}"
    fi
    
    if timeout 3 nc -zu "$SERVER_IP" "$SLOWDNS_PORT" 2>/dev/null; then
        echo -e "SlowDNS ($SLOWDNS_PORT): ${GREEN}ACCESSIBLE${NC}"
    else
        echo -e "SlowDNS ($SLOWDNS_PORT): ${RED}BLOCKED${NC}"
    fi
    
    # Test proxy
    echo ""
    echo -e "${CYAN}════════ PROXY TEST ════════${NC}"
    
    if curl --socks5 "127.0.0.1:$LOCAL_PORT" -s --max-time 5 http://ipinfo.io/ip > /dev/null 2>&1; then
        IP=$(curl --socks5 "127.0.0.1:$LOCAL_PORT" -s http://ipinfo.io/ip)
        echo -e "Proxy IP: ${GREEN}$IP${NC}"
    else
        echo -e "Proxy: ${RED}NOT WORKING${NC}"
    fi
    
    # Show config
    echo ""
    echo -e "${CYAN}════════ CONFIGURATION ════════${NC}"
    echo -e "Server:     $SERVER_IP"
    echo -e "SSH Port:   $SSH_PORT"
    echo -e "SlowDNS:    $SLOWDNS_PORT"
    echo -e "DNS:        $DNS_SERVER:$DNS_PORT"
    echo -e "Config Dir: $CONFIG_DIR"
}

show_help() {
    print_header
    
    echo -e "${CYAN}Usage:${NC}"
    echo -e "  ./termux-slowdns-vpn.sh [command]"
    echo ""
    echo -e "${CYAN}Commands:${NC}"
    echo -e "  ${GREEN}start${NC}     - Start the VPN"
    echo -e "  ${GREEN}stop${NC}      - Stop the VPN"
    echo -e "  ${GREEN}restart${NC}   - Restart the VPN"
    echo -e "  ${GREEN}status${NC}    - Show VPN status"
    echo -e "  ${GREEN}install${NC}   - Install dependencies"
    echo -e "  ${GREEN}config${NC}    - Show configuration"
    echo -e "  ${GREEN}test${NC}      - Test server connections"
    echo -e "  ${GREEN}log${NC}       - Show VPN log"
    echo -e "  ${GREEN}help${NC}      - Show this help"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo -e "  Start VPN:          ${YELLOW}./termux-slowdns-vpn.sh start${NC}"
    echo -e "  Check status:       ${YELLOW}./termux-slowdns-vpn.sh status${NC}"
    echo -e "  Test connection:    ${YELLOW}./termux-slowdns-vpn.sh test${NC}"
    echo ""
    echo -e "${CYAN}Quick Start:${NC}"
    echo -e "  1. chmod +x termux-slowdns-vpn.sh"
    echo -e "  2. ./termux-slowdns-vpn.sh install"
    echo -e "  3. ./termux-slowdns-vpn.sh start"
}

test_connection() {
    print_header
    echo -e "${CYAN}════════ CONNECTION TESTS ════════${NC}"
    echo ""
    
    # Test DNS
    print_step "Testing DNS ($DNS_SERVER:$DNS_PORT)..."
    if timeout 5 dig @$DNS_SERVER -p $DNS_PORT google.com | grep -q "ANSWER SECTION"; then
        print_status "DNS working"
    else
        print_error "DNS failed"
    fi
    
    # Test SSH
    print_step "Testing SSH ($SERVER_IP:$SSH_PORT)..."
    if timeout 5 nc -z $SERVER_IP $SSH_PORT 2>/dev/null; then
        print_status "SSH port open"
    else
        print_error "SSH port closed"
    fi
    
    # Test SlowDNS
    print_step "Testing SlowDNS ($SERVER_IP:$SLOWDNS_PORT)..."
    if timeout 5 nc -zu $SERVER_IP $SLOWDNS_PORT 2>/dev/null; then
        print_status "SlowDNS port open"
    else
        print_error "SlowDNS port closed"
    fi
    
    echo ""
}

show_config() {
    print_header
    echo -e "${CYAN}════════ VPN CONFIGURATION ════════${NC}"
    echo ""
    echo -e "${YELLOW}Server Configuration:${NC}"
    echo -e "  IP Address:    $SERVER_IP"
    echo -e "  SSH Port:      $SSH_PORT"
    echo -e "  SlowDNS Port:  $SLOWDNS_PORT"
    echo ""
    echo -e "${YELLOW}DNS Configuration:${NC}"
    echo -e "  DNS Server:    $DNS_SERVER"
    echo -e "  DNS Port:      $DNS_PORT"
    echo -e "  Nameserver:    $NAMESERVER"
    echo ""
    echo -e "${YELLOW}Local Configuration:${NC}"
    echo -e "  SOCKS Port:    $LOCAL_PORT"
    echo -e "  Local DNS:     $LOCAL_DNS_PORT"
    echo -e "  Config Dir:    $CONFIG_DIR"
    echo -e "  Log File:      $LOG_FILE"
    echo ""
    echo -e "${YELLOW}Public Key (first 16 chars):${NC}"
    echo -e "  ${PUBLIC_KEY:0:16}..."
}

show_log() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${CYAN}════════ VPN LOG (last 50 lines) ════════${NC}"
        echo ""
        tail -n 50 "$LOG_FILE"
    else
        print_error "Log file not found"
    fi
}

# Main execution
case "$1" in
    "start")
        start_vpn
        ;;
    "stop")
        stop_vpn
        ;;
    "restart")
        stop_vpn
        sleep 2
        start_vpn
        ;;
    "status")
        show_status
        ;;
    "install")
        check_requirements
        install_dependencies
        download_slowdns_client
        print_status "Installation complete"
        ;;
    "test")
        test_connection
        ;;
    "config")
        show_config
        ;;
    "log")
        show_log
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        if [ $# -eq 0 ]; then
            start_vpn
        else
            show_help
        fi
        ;;
esac
