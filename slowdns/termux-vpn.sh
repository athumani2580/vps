#!/data/data/com.termux/files/usr/bin/bash

# =============================================
# COMPLETE TERMUX VPN MANAGER
# Server: 139.84.240.171:22
# DNS: 169.255.187.58:53
# Nameserver: gerry.alienalien.top
# Public Key: 7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59
# =============================================

# Configuration
SERVER_IP="139.84.240.171"
SSH_PORT="22"
DNS_SERVER="169.255.187.58"
DNS_PORT="53"
NAMESERVER="gerry.alienalien.top"
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
SLOWDNS_PORT="5300"

# Local Settings
SOCKS_PORT="1080"
HTTP_PORT="8123"
LOCAL_DNS_PORT="5353"
CONFIG_DIR="$HOME/.termux-vpn"
LOG_DIR="$CONFIG_DIR/logs"
PID_DIR="$CONFIG_DIR/pid"

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# Functions
print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${YELLOW}[i]${NC} $1"; }
print_step() { echo -e "${BLUE}[→]${NC} $1"; }

# Initialize directories
init_dirs() {
    mkdir -p {$CONFIG_DIR,$LOG_DIR,$PID_DIR}
}

# Installation
install_vpn() {
    print_step "Installing Termux VPN..."
    
    pkg update -y && pkg upgrade -y
    pkg install -y openssh curl wget netcat-openbsd \
                   dnsutils python termux-api \
                   redsocks privoxy 2>/dev/null
    
    pip install pysocks requests 2>/dev/null
    
    # Create SlowDNS client script
    cat > $CONFIG_DIR/slowdns-client.py << 'SLOWDNS_EOF'
#!/usr/bin/env python3
import socket
import sys
import threading

def dns_forwarder(local_port=5353, remote_dns="169.255.187.58", remote_port=53):
    print(f"[SlowDNS] Starting on port {local_port}")
    print(f"[SlowDNS] Forwarding to {remote_dns}:{remote_port}")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', local_port))
    
    try:
        while True:
            data, addr = sock.recvfrom(512)
            # Forward to real DNS
            remote_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            remote_sock.sendto(data, (remote_dns, remote_port))
            response, _ = remote_sock.recvfrom(512)
            remote_sock.close()
            # Send back to client
            sock.sendto(response, addr)
    except KeyboardInterrupt:
        print("\n[SlowDNS] Stopping...")
    except Exception as e:
        print(f"[SlowDNS] Error: {e}")
    finally:
        sock.close()
        print("[SlowDNS] Stopped")

if __name__ == "__main__":
    dns_forwarder()
SLOWDNS_EOF
    
    chmod +x $CONFIG_DIR/slowdns-client.py
    
    print_status "Installation complete!"
}

# SSH SOCKS5 Tunnel
start_ssh_tunnel() {
    print_step "Starting SSH SOCKS5 tunnel..."
    
    # Stop existing
    pkill -f "ssh.*$SOCKS_PORT" 2>/dev/null
    sleep 2
    
    # Check port
    if netstat -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
        print_info "Port $SOCKS_PORT is busy, freeing..."
        fuser -k $SOCKS_PORT/tcp 2>/dev/null
        sleep 2
    fi
    
    print_info "Connecting to $SERVER_IP:$SSH_PORT..."
    echo ""
    echo "Enter your server password when prompted"
    echo ""
    
    # Start SSH tunnel
    ssh -f -N \
        -D $SOCKS_PORT \
        -p $SSH_PORT \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        root@$SERVER_IP 2>$LOG_DIR/ssh-error.log
    
    if [ $? -eq 0 ]; then
        SSH_PID=$(pgrep -f "ssh.*$SOCKS_PORT")
        echo $SSH_PID > $PID_DIR/ssh.pid
        print_status "SSH SOCKS5 tunnel started on 127.0.0.1:$SOCKS_PORT"
        return 0
    else
        print_error "Failed to start SSH tunnel"
        print_info "Starting interactive mode..."
        ssh -D $SOCKS_PORT -p $SSH_PORT root@$SERVER_IP
        return $?
    fi
}

# SlowDNS Service
start_slowdns() {
    print_step "Starting SlowDNS..."
    
    pkill -f "slowdns-client.py" 2>/dev/null
    sleep 1
    
    python3 $CONFIG_DIR/slowdns-client.py > $LOG_DIR/slowdns.log 2>&1 &
    SLOWDNS_PID=$!
    echo $SLOWDNS_PID > $PID_DIR/slowdns.pid
    
    sleep 2
    if kill -0 $SLOWDNS_PID 2>/dev/null; then
        print_status "SlowDNS started on 127.0.0.1:$LOCAL_DNS_PORT"
        
        # Configure DNS
        configure_dns
        return 0
    else
        print_error "SlowDNS failed to start"
        return 1
    fi
}

configure_dns() {
    print_step "Configuring DNS..."
    
    cat > $CONFIG_DIR/resolv.conf << EOF
# Termux VPN DNS Configuration
nameserver 127.0.0.1
nameserver $DNS_SERVER
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF
    
    # Try to set DNS in Termux
    if [ -w /etc/resolv.conf ]; then
        cp $CONFIG_DIR/resolv.conf /etc/resolv.conf
        print_status "System DNS configured"
    else
        print_info "Manual DNS setup:"
        echo "Set DNS to: 127.0.0.1"
    fi
}

# HTTP Proxy (via redsocks)
start_http_proxy() {
    print_step "Setting up HTTP proxy..."
    
    # Create redsocks config
    cat > $CONFIG_DIR/redsocks.conf << EOF
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $HTTP_PORT;
    ip = 127.0.0.1;
    port = $SOCKS_PORT;
    type = socks5;
}
EOF
    
    pkill redsocks 2>/dev/null
    redsocks -c $CONFIG_DIR/redsocks.conf 2>/dev/null
    REDSOCKS_PID=$!
    echo $REDSOCKS_PID > $PID_DIR/redsocks.pid
    
    sleep 1
    if kill -0 $REDSOCKS_PID 2>/dev/null; then
        print_status "HTTP proxy started on 127.0.0.1:$HTTP_PORT"
        return 0
    else
        print_error "HTTP proxy failed to start"
        return 1
    fi
}

# Privoxy (ad blocker + HTTP proxy)
start_privoxy() {
    print_step "Starting Privoxy..."
    
    mkdir -p $CONFIG_DIR/privoxy
    cat > $CONFIG_DIR/privoxy/config << EOF
listen-address 127.0.0.1:8118
forward-socks5 / 127.0.0.1:$SOCKS_PORT .
toggle 1
enable-remote-toggle 0
enable-remote-http-toggle 0
enable-edit-actions 0
forwarded-connect-retries 0
accept-intercepted-requests 0
allow-cgi-request-crunching 0
split-large-forms 0
keep-alive-timeout 300
socket-timeout 300
EOF
    
    pkill privoxy 2>/dev/null
    privoxy $CONFIG_DIR/privoxy/config > $LOG_DIR/privoxy.log 2>&1 &
    PRIVOXY_PID=$!
    echo $PRIVOXY_PID > $PID_DIR/privoxy.pid
    
    sleep 1
    if kill -0 $PRIVOXY_PID 2>/dev/null; then
        print_status "Privoxy started on 127.0.0.1:8118"
        return 0
    else
        print_error "Privoxy failed to start"
        return 1
    fi
}

# Start all VPN services
start_all() {
    init_dirs
    
    print_step "Starting complete VPN setup..."
    
    # Start SSH tunnel
    if start_ssh_tunnel; then
        # Start SlowDNS
        start_slowdns
        
        # Start proxies
        start_http_proxy
        start_privoxy
        
        show_connection_info
    else
        print_error "VPN failed to start"
    fi
}

# Stop all VPN services
stop_all() {
    print_step "Stopping VPN services..."
    
    # Kill all processes
    for pid_file in $PID_DIR/*.pid 2>/dev/null; do
        if [ -f "$pid_file" ]; then
            kill $(cat "$pid_file") 2>/dev/null
            rm -f "$pid_file"
        fi
    done
    
    # Force kill any remaining
    pkill -f "ssh.*$SOCKS_PORT" 2>/dev/null
    pkill -f "slowdns-client.py" 2>/dev/null
    pkill redsocks 2>/dev/null
    pkill privoxy 2>/dev/null
    
    # Reset DNS
    if [ -w /etc/resolv.conf ]; then
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    
    print_status "All VPN services stopped"
}

# Check VPN status
check_status() {
    clear
    echo "========================================"
    echo "           VPN STATUS"
    echo "========================================"
    echo ""
    
    # SSH Tunnel
    if [ -f "$PID_DIR/ssh.pid" ] && kill -0 $(cat "$PID_DIR/ssh.pid") 2>/dev/null; then
        echo -e "${GREEN}✓ SSH Tunnel: RUNNING${NC}"
        echo "   SOCKS5: 127.0.0.1:$SOCKS_PORT"
    else
        echo -e "${RED}✗ SSH Tunnel: STOPPED${NC}"
    fi
    
    # SlowDNS
    if [ -f "$PID_DIR/slowdns.pid" ] && kill -0 $(cat "$PID_DIR/slowdns.pid") 2>/dev/null; then
        echo -e "${GREEN}✓ SlowDNS: RUNNING${NC}"
        echo "   DNS: 127.0.0.1:$LOCAL_DNS_PORT"
    else
        echo -e "${RED}✗ SlowDNS: STOPPED${NC}"
    fi
    
    # HTTP Proxy
    if [ -f "$PID_DIR/redsocks.pid" ] && kill -0 $(cat "$PID_DIR/redsocks.pid") 2>/dev/null; then
        echo -e "${GREEN}✓ HTTP Proxy: RUNNING${NC}"
        echo "   HTTP: 127.0.0.1:$HTTP_PORT"
    else
        echo -e "${RED}✗ HTTP Proxy: STOPPED${NC}"
    fi
    
    # Privoxy
    if [ -f "$PID_DIR/privoxy.pid" ] && kill -0 $(cat "$PID_DIR/privoxy.pid") 2>/dev/null; then
        echo -e "${GREEN}✓ Privoxy: RUNNING${NC}"
        echo "   HTTP+Adblock: 127.0.0.1:8118"
    else
        echo -e "${RED}✗ Privoxy: STOPPED${NC}"
    fi
    
    echo ""
    
    # Test connection
    if [ -f "$PID_DIR/ssh.pid" ]; then
        print_info "Testing connection..."
        IP=$(timeout 3 curl --socks5 127.0.0.1:$SOCKS_PORT -s http://ipinfo.io/ip 2>/dev/null)
        if [ -n "$IP" ]; then
            echo -e "${GREEN}✓ VPN Connection: WORKING${NC}"
            echo "   Your IP: $IP"
        else
            echo -e "${RED}✗ VPN Connection: FAILED${NC}"
        fi
    fi
    
    echo ""
}

# Test VPN connection
test_connection() {
    print_step "Testing VPN connection..."
    
    if [ ! -f "$PID_DIR/ssh.pid" ]; then
        print_error "VPN is not running"
        return 1
    fi
    
    echo ""
    echo "1. Testing SOCKS5 proxy..."
    IP=$(timeout 5 curl --socks5 127.0.0.1:$SOCKS_PORT -s http://ipinfo.io/ip 2>/dev/null)
    if [ -n "$IP" ]; then
        echo -e "   ${GREEN}✓ Working - IP: $IP${NC}"
    else
        echo -e "   ${RED}✗ Failed${NC}"
    fi
    
    echo ""
    echo "2. Testing HTTP proxy..."
    IP2=$(timeout 5 curl --proxy http://127.0.0.1:$HTTP_PORT -s http://ipinfo.io/ip 2>/dev/null)
    if [ -n "$IP2" ]; then
        echo -e "   ${GREEN}✓ Working - IP: $IP2${NC}"
    else
        echo -e "   ${RED}✗ Failed${NC}"
    fi
    
    echo ""
    echo "3. Testing Privoxy..."
    IP3=$(timeout 5 curl --proxy http://127.0.0.1:8118 -s http://ipinfo.io/ip 2>/dev/null)
    if [ -n "$IP3" ]; then
        echo -e "   ${GREEN}✓ Working - IP: $IP3${NC}"
    else
        echo -e "   ${RED}✗ Failed${NC}"
    fi
    
    echo ""
    echo "4. Testing DNS..."
    if timeout 3 dig @127.0.0.1 -p $LOCAL_DNS_PORT google.com > /dev/null 2>&1; then
        echo -e "   ${GREEN}✓ DNS Working${NC}"
    else
        echo -e "   ${RED}✗ DNS Failed${NC}"
    fi
    
    echo ""
}

# Show connection info
show_connection_info() {
    clear
    echo "========================================"
    echo "     VPN CONNECTION INFORMATION"
    echo "========================================"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PROXY SETTINGS FOR APPS:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}1. SOCKS5 Proxy (Recommended)${NC}"
    echo "   Type: SOCKS5"
    echo "   Host: 127.0.0.1"
    echo "   Port: $SOCKS_PORT"
    echo ""
    echo -e "${GREEN}2. HTTP Proxy${NC}"
    echo "   Type: HTTP"
    echo "   Host: 127.0.0.1"
    echo "   Port: $HTTP_PORT"
    echo ""
    echo -e "${GREEN}3. HTTP Proxy with Ad Blocking${NC}"
    echo "   Type: HTTP"
    echo "   Host: 127.0.0.1"
    echo "   Port: 8118"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}TERMUX COMMANDS:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Test SOCKS5:"
    echo "  curl --socks5 127.0.0.1:$SOCKS_PORT http://ipinfo.io"
    echo ""
    echo "Test HTTP:"
    echo "  curl --proxy http://127.0.0.1:$HTTP_PORT http://ipinfo.io"
    echo ""
    echo "Set proxy for all commands:"
    echo "  export http_proxy=http://127.0.0.1:$HTTP_PORT"
    echo "  export https_proxy=http://127.0.0.1:$HTTP_PORT"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}ANDROID APPS:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "1. Install ProxyDroid or SocksDroid"
    echo "2. Set proxy to 127.0.0.1"
    echo "3. Set port to $SOCKS_PORT"
    echo "4. Set type to SOCKS5"
    echo ""
}

# Menu system
show_menu() {
    while true; do
        clear
        echo "========================================"
        echo "       TERMUX VPN MANAGER"
        echo "========================================"
        echo ""
        echo "1. Start Complete VPN"
        echo "2. Stop All VPN Services"
        echo "3. Check VPN Status"
        echo "4. Test VPN Connection"
        echo "5. Show Connection Info"
        echo "6. Install/Update VPN"
        echo "7. Quick Start (SSH Only)"
        echo "8. Exit"
        echo ""
        read -p "Choose [1-8]: " choice
        
        case $choice in
            1)
                start_all
                read -p "Press Enter to continue..."
                ;;
            2)
                stop_all
                read -p "Press Enter to continue..."
                ;;
            3)
                check_status
                read -p "Press Enter to continue..."
                ;;
            4)
                test_connection
                read -p "Press Enter to continue..."
                ;;
            5)
                show_connection_info
                read -p "Press Enter to continue..."
                ;;
            6)
                install_vpn
                read -p "Press Enter to continue..."
                ;;
            7)
                start_ssh_tunnel
                read -p "Press Enter to continue..."
                ;;
            8)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                echo "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

# Create desktop shortcut
create_shortcut() {
    cat > $CONFIG_DIR/vpn-shortcut.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Termux VPN Control</title>
    <style>
        body { font-family: Arial; padding: 20px; }
        .btn { display: block; padding: 15px; margin: 10px 0; 
               background: #4CAF50; color: white; text-align: center;
               text-decoration: none; border-radius: 5px; }
        .stop { background: #f44336; }
        .status { background: #2196F3; }
    </style>
</head>
<body>
    <h2>Termux VPN Control</h2>
    <a href="termux://run?cmd=./termux-vpn.sh%20start" class="btn">▶ Start VPN</a>
    <a href="termux://run?cmd=./termux-vpn.sh%20stop" class="btn stop">⏹ Stop VPN</a>
    <a href="termux://run?cmd=./termux-vpn.sh%20status" class="btn status">📊 Status</a>
</body>
</html>
EOF
    
    print_status "Shortcut created: $CONFIG_DIR/vpn-shortcut.html"
}

# Main execution
init_dirs

case "$1" in
    start)
        start_all
        ;;
    stop)
        stop_all
        ;;
    status)
        check_status
        ;;
    test)
        test_connection
        ;;
    install)
        install_vpn
        ;;
    info)
        show_connection_info
        ;;
    ssh)
        start_ssh_tunnel
        ;;
    menu|"")
        show_menu
        ;;
    shortcut)
        create_shortcut
        ;;
    *)
        echo "Usage: $0 {start|stop|status|test|install|info|ssh|menu|shortcut}"
        echo ""
        echo "Examples:"
        echo "  $0 start     # Start complete VPN"
        echo "  $0 stop      # Stop all VPN services"
        echo "  $0 status    # Check VPN status"
        echo "  $0 menu      # Interactive menu"
        echo "  $0 ssh       # SSH tunnel only"
        echo ""
        echo "Quick manual start:"
        echo "  ssh -D 1080 -p 22 root@139.84.240.171"
        ;;
esac
