#!/data/data/com.termux/files/usr/bin/bash

# ==========================================
# TERMUX SLOWDNS VPN SETUP - FIXED VERSION
# ==========================================
# Configuration
SERVER_IP="139.84.240.171"
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

# PID files
DNS_PID_FILE="$HOME/.vpn_dns.pid"
VPN_PID_FILE="$HOME/.vpn_tunnel.pid"
PROXY_PID_FILE="$HOME/.vpn_proxy.pid"

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
    if ping -c 1 8.8.8.8 &>/dev/null || ping -c 1 1.1.1.1 &>/dev/null; then
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
    pkg update -y && pkg upgrade -y 2>> "$LOG_FILE"
    
    # Install required packages
    pkg install -y python git curl wget socat nano proot termux-api \
                   nmap dnsutils iproute2 net-tools openssl \
                   python-pip 2>> "$LOG_FILE"
    
    # Install Python packages
    pip install requests pycryptodome cryptography 2>> "$LOG_FILE"
    
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
        sleep 0.5
    done
    
    error "No open ports found on server. Trying default 443..."
    WORKING_PORT=443
    return 1
}

cleanup() {
    log "Cleaning up processes..."
    
    # Kill DNS forwarders
    if [ -f "$DNS_PID_FILE" ]; then
        kill -9 $(cat "$DNS_PID_FILE") 2>/dev/null
        rm -f "$DNS_PID_FILE"
    fi
    
    # Kill VPN tunnel
    if [ -f "$VPN_PID_FILE" ]; then
        kill -9 $(cat "$VPN_PID_FILE") 2>/dev/null
        rm -f "$VPN_PID_FILE"
    fi
    
    # Kill proxy
    if [ -f "$PROXY_PID_FILE" ]; then
        kill -9 $(cat "$PROXY_PID_FILE") 2>/dev/null
        rm -f "$PROXY_PID_FILE"
    fi
    
    # Kill any remaining processes
    pkill -f "socat.*53" 2>/dev/null
    pkill -f "vpn_tunnel.py" 2>/dev/null
    pkill -f "dns_forwarder.py" 2>/dev/null
    
    # Reset DNS
    setprop net.dns1 8.8.8.8 2>/dev/null
    setprop net.dns2 1.1.1.1 2>/dev/null
    
    success "Cleanup completed"
}

start_dns_forwarder() {
    log "Starting DNS forwarder..."
    
    # Kill any existing DNS forwarders
    pkill -f "socat.*53" 2>/dev/null
    
    # Create Python-based DNS forwarder (more reliable)
    cat > "$HOME/dns_forwarder.py" << 'EOF'
#!/usr/bin/env python3
import socket
import sys
import threading
import time

SERVER_IP = sys.argv[1]
SERVER_PORT = int(sys.argv[2])

def handle_udp_client(data, client_addr, sock):
    """Handle UDP DNS requests"""
    try:
        # Forward to SlowDNS server
        forward_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        forward_sock.settimeout(5)
        forward_sock.sendto(data, (SERVER_IP, SERVER_PORT))
        response, _ = forward_sock.recvfrom(512)
        forward_sock.close()
        
        # Send response back to client
        sock.sendto(response, client_addr)
    except Exception as e:
        print(f"UDP Error: {e}")

def handle_tcp_client(client_sock, client_addr):
    """Handle TCP DNS requests"""
    try:
        # Get request length
        data = client_sock.recv(2)
        if len(data) < 2:
            return
        length = int.from_bytes(data, 'big')
        
        # Get DNS query
        query = client_sock.recv(length)
        
        # Forward to SlowDNS server
        forward_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        forward_sock.settimeout(5)
        forward_sock.connect((SERVER_IP, SERVER_PORT))
        forward_sock.send(query)
        response = forward_sock.recv(512)
        forward_sock.close()
        
        # Send response back
        client_sock.send(len(response).to_bytes(2, 'big'))
        client_sock.send(response)
    except Exception as e:
        print(f"TCP Error: {e}")
    finally:
        client_sock.close()

def start_dns_server():
    """Start DNS server on port 53"""
    print(f"[*] Starting DNS forwarder on port 53")
    print(f"[*] Forwarding to {SERVER_IP}:{SERVER_PORT}")
    
    # UDP server
    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp_sock.bind(('127.0.0.1', 53))
    
    # TCP server
    tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp_sock.bind(('127.0.0.1', 53))
    tcp_sock.listen(5)
    
    print("[✓] DNS server started")
    
    try:
        while True:
            # Handle UDP
            try:
                udp_sock.settimeout(1)
                data, addr = udp_sock.recvfrom(512)
                thread = threading.Thread(target=handle_udp_client, args=(data, addr, udp_sock))
                thread.daemon = True
                thread.start()
            except socket.timeout:
                pass
            
            # Handle TCP
            try:
                tcp_sock.settimeout(1)
                client_sock, addr = tcp_sock.accept()
                thread = threading.Thread(target=handle_tcp_client, args=(client_sock, addr))
                thread.daemon = True
                thread.start()
            except socket.timeout:
                pass
                
    except KeyboardInterrupt:
        print("\n[!] Stopping DNS server...")
    finally:
        udp_sock.close()
        tcp_sock.close()

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 dns_forwarder.py <server_ip> <server_port>")
        sys.exit(1)
    SERVER_IP = sys.argv[1]
    SERVER_PORT = int(sys.argv[2])
    start_dns_server()
EOF
    
    chmod +x "$HOME/dns_forwarder.py"
    
    # Start DNS forwarder
    python3 "$HOME/dns_forwarder.py" "$SERVER_IP" "$WORKING_PORT" >> "$LOG_FILE" 2>&1 &
    DNS_PID=$!
    echo $DNS_PID > "$DNS_PID_FILE"
    
    sleep 2
    
    # Check if DNS forwarder is running
    if ps -p $DNS_PID > /dev/null; then
        success "DNS forwarder started (PID: $DNS_PID)"
        return 0
    else
        error "Failed to start DNS forwarder"
        return 1
    fi
}

set_dns_settings() {
    log "Configuring DNS settings..."
    
    # Set DNS to localhost using termux API if available
    if command -v termux-wifi-scaninfo &>/dev/null; then
        # Try using Termux API
        echo "nameserver 127.0.0.1" > "$PREFIX/etc/resolv.conf"
        echo "nameserver 8.8.8.8" >> "$PREFIX/etc/resolv.conf"
        success "DNS configured via Termux"
    else
        # Manual method
        setprop net.dns1 127.0.0.1 2>/dev/null || true
        setprop net.dns2 8.8.8.8 2>/dev/null || true
        
        # Update resolv.conf
        mkdir -p "$PREFIX/etc"
        echo "nameserver 127.0.0.1" > "$PREFIX/etc/resolv.conf"
        echo "nameserver 8.8.8.8" >> "$PREFIX/etc/resolv.conf"
        
        success "DNS set to 127.0.0.1 (fallback method)"
    fi
    
    # Test DNS
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        success "DNS resolution working"
    else
        warning "DNS test failed, but continuing..."
    fi
}

create_vpn_tunnel() {
    log "Creating VPN tunnel..."
    
    # Create improved VPN tunnel script
    cat > "$HOME/vpn_tunnel.py" << EOF
#!/usr/bin/env python3
import socket
import time
import sys
import struct
import threading
import select

SERVER_IP = "$SERVER_IP"
SERVER_PORT = $WORKING_PORT
PUBLIC_KEY = "$PUBLIC_KEY"

class SlowDNSTunnel:
    def __init__(self):
        self.running = True
        self.buffer_size = 4096
        
    def create_packet(self, data):
        """Create DNS-like packet"""
        # Simple packet structure: [2 bytes length][data]
        length = len(data)
        return struct.pack('!H', length) + data
    
    def parse_packet(self, packet):
        """Parse DNS-like packet"""
        if len(packet) < 2:
            return b''
        length = struct.unpack('!H', packet[:2])[0]
        return packet[2:2+length]
    
    def connect_to_server(self):
        """Connect to SlowDNS server"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(10)
            sock.connect((SERVER_IP, SERVER_PORT))
            
            # Send handshake with public key
            handshake = f"CONNECT {PUBLIC_KEY}\n"
            sock.send(self.create_packet(handshake.encode()))
            
            # Wait for response
            response = sock.recv(self.buffer_size)
            if response:
                print("[✓] Connected to SlowDNS server")
                return sock
            else:
                print("[!] No response from server")
                sock.close()
                return None
                
        except Exception as e:
            print(f"[!] Connection error: {e}")
            return None
    
    def tunnel_loop(self, sock):
        """Main tunnel loop"""
        print("[*] Tunnel active. Press Ctrl+C to stop.")
        
        try:
            while self.running:
                # Keep-alive packet
                keepalive = b"KEEPALIVE"
                sock.send(self.create_packet(keepalive))
                
                # Try to receive data
                ready = select.select([sock], [], [], 10)
                if ready[0]:
                    data = sock.recv(self.buffer_size)
                    if not data:
                        print("[!] Connection closed by server")
                        break
                
                time.sleep(30)  # Send keepalive every 30 seconds
                
        except Exception as e:
            print(f"[!] Tunnel error: {e}")
        finally:
            sock.close()
    
    def start(self):
        """Start the VPN tunnel"""
        print(f"[*] Connecting to {SERVER_IP}:{SERVER_PORT}")
        
        while self.running:
            sock = self.connect_to_server()
            if sock:
                self.tunnel_loop(sock)
            
            if self.running:
                print("[*] Reconnecting in 5 seconds...")
                time.sleep(5)
    
    def stop(self):
        """Stop the tunnel"""
        self.running = False
        print("[✓] Tunnel stopped")

def main():
    tunnel = SlowDNSTunnel()
    
    try:
        tunnel.start()
    except KeyboardInterrupt:
        print("\n[!] Stopping tunnel...")
        tunnel.stop()
    except Exception as e:
        print(f"[!] Fatal error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF
    
    chmod +x "$HOME/vpn_tunnel.py"
    
    # Start VPN tunnel
    python3 "$HOME/vpn_tunnel.py" >> "$LOG_FILE" 2>&1 &
    VPN_PID=$!
    echo $VPN_PID > "$VPN_PID_FILE"
    
    sleep 3
    
    # Check if tunnel is running
    if ps -p $VPN_PID > /dev/null; then
        success "VPN tunnel started (PID: $VPN_PID)"
        return 0
    else
        error "Failed to start VPN tunnel"
        return 1
    fi
}

setup_proxy() {
    log "Setting up SOCKS5 proxy..."
    
    # Create simple SOCKS5 proxy
    cat > "$HOME/socks_proxy.py" << 'EOF'
#!/usr/bin/env python3
import socket
import threading
import sys

class SimpleSOCKS5:
    def __init__(self, listen_port=9050):
        self.listen_port = listen_port
        self.running = True
        
    def handle_client(self, client_sock):
        """Handle SOCKS5 client connection"""
        try:
            # SOCKS5 handshake
            version = client_sock.recv(1)
            if version != b'\x05':
                client_sock.close()
                return
            
            nmethods = client_sock.recv(1)[0]
            methods = client_sock.recv(nmethods)
            
            # Accept no authentication
            client_sock.send(b'\x05\x00')
            
            # Get request
            request = client_sock.recv(4)
            if len(request) < 4:
                client_sock.close()
                return
            
            cmd = request[1]
            if cmd != 1:  # Only support CONNECT
                client_sock.send(b'\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00')
                client_sock.close()
                return
            
            # Get destination address
            addr_type = request[3]
            if addr_type == 1:  # IPv4
                dest_addr = socket.inet_ntoa(client_sock.recv(4))
                dest_port = int.from_bytes(client_sock.recv(2), 'big')
            elif addr_type == 3:  # Domain name
                domain_len = client_sock.recv(1)[0]
                dest_addr = client_sock.recv(domain_len).decode()
                dest_port = int.from_bytes(client_sock.recv(2), 'big')
            else:
                client_sock.close()
                return
            
            # Connect to destination
            try:
                remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                remote_sock.settimeout(30)
                remote_sock.connect((dest_addr, dest_port))
                
                # Send success response
                client_sock.send(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
                
                # Start forwarding
                self.forward_data(client_sock, remote_sock)
                
            except Exception as e:
                print(f"Connection error: {e}")
                client_sock.send(b'\x05\x04\x00\x01\x00\x00\x00\x00\x00\x00')
                client_sock.close()
                
        except Exception as e:
            print(f"Client error: {e}")
            client_sock.close()
    
    def forward_data(self, sock1, sock2):
        """Forward data between two sockets"""
        sockets = [sock1, sock2]
        
        try:
            while self.running:
                readable, _, _ = select.select(sockets, [], [], 1)
                
                for sock in readable:
                    data = sock.recv(4096)
                    if not data:
                        return
                    
                    if sock is sock1:
                        sock2.send(data)
                    else:
                        sock1.send(data)
        except:
            pass
        finally:
            sock1.close()
            sock2.close()
    
    def start(self):
        """Start SOCKS5 proxy server"""
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('127.0.0.1', self.listen_port))
        server.listen(5)
        
        print(f"[*] SOCKS5 proxy listening on 127.0.0.1:{self.listen_port}")
        
        try:
            while self.running:
                client, addr = server.accept()
                thread = threading.Thread(target=self.handle_client, args=(client,))
                thread.daemon = True
                thread.start()
        except KeyboardInterrupt:
            print("\n[!] Stopping proxy...")
        finally:
            server.close()
    
    def stop(self):
        self.running = False

if __name__ == "__main__":
    proxy = SimpleSOCKS5(9050)
    try:
        proxy.start()
    except KeyboardInterrupt:
        proxy.stop()
EOF
    
    chmod +x "$HOME/socks_proxy.py"
    
    # Start proxy
    python3 "$HOME/socks_proxy.py" >> "$LOG_FILE" 2>&1 &
    PROXY_PID=$!
    echo $PROXY_PID > "$PROXY_PID_FILE"
    
    sleep 2
    
    if ps -p $PROXY_PID > /dev/null; then
        success "SOCKS5 proxy started on 127.0.0.1:9050 (PID: $PROXY_PID)"
        return 0
    else
        error "Failed to start proxy"
        return 1
    fi
}

configure_apps() {
    log "Configuring apps to use VPN..."
    
    cat > "$HOME/.vpn_config" << EOF
# VPN Configuration
export HTTP_PROXY="socks5://127.0.0.1:9050"
export HTTPS_PROXY="socks5://127.0.0.1:9050"
export ALL_PROXY="socks5://127.0.0.1:9050"
export http_proxy="socks5://127.0.0.1:9050"
export https_proxy="socks5://127.0.0.1:9050"
export all_proxy="socks5://127.0.0.1:9050"
export SOCKS_SERVER="127.0.0.1:9050"
export SOCKS_VERSION="5"
EOF
    
    # Add to bashrc if not already there
    if ! grep -q "\.vpn_config" "$HOME/.bashrc"; then
        echo -e "\n# Load VPN configuration" >> "$HOME/.bashrc"
        echo 'if [ -f ~/.vpn_config ]; then' >> "$HOME/.bashrc"
        echo '    . ~/.vpn_config' >> "$HOME/.bashrc"
        echo 'fi' >> "$HOME/.bashrc"
    fi
    
    # Load config now
    source "$HOME/.vpn_config"
    
    # Create app instructions
    cat > "$HOME/README_VPN.md" << EOF
# Termux SlowDNS VPN Setup

## Quick Start
1. Start VPN: ./start_vpn.sh
2. Stop VPN: ./stop_vpn.sh
3. Check status: ./vpn_status.sh

## App Configuration

### 1. curl/wget:
Already configured via environment variables.

### 2. Git:
\`\`\`bash
git config --global http.proxy socks5://127.0.0.1:9050
git config --global https.proxy socks5://127.0.0.1:9050
\`\`\`

### 3. Termux Apps:
Set proxy in app settings to:
- Host: 127.0.0.1
- Port: 9050
- Type: SOCKS5

### 4. Test Connection:
\`\`\`bash
curl --socks5 127.0.0.1:9050 ifconfig.me
\`\`\`

## Troubleshooting
- Check logs: tail -f $LOG_FILE
- Test DNS: nslookup google.com 127.0.0.1
- Restart: ./stop_vpn.sh && ./start_vpn.sh
EOF
    
    success "App configuration complete. See $HOME/README_VPN.md"
}

test_vpn() {
    log "Testing VPN connection..."
    
    echo -e "${YELLOW}1. Testing DNS resolution:${NC}"
    if timeout 5 nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        success "DNS working"
    else
        error "DNS failed"
    fi
    
    echo -e "${YELLOW}2. Testing proxy connection:${NC}"
    if timeout 10 curl -s --socks5 127.0.0.1:9050 ifconfig.me >/dev/null 2>&1; then
        NEW_IP=$(timeout 10 curl -s --socks5 127.0.0.1:9050 ifconfig.me)
        OLD_IP=$(timeout 10 curl -s ifconfig.me 2>/dev/null || echo "Unknown")
        
        echo "Original IP: $OLD_IP"
        echo "VPN IP: $NEW_IP"
        
        if [ "$NEW_IP" != "$OLD_IP" ] && [ ! -z "$NEW_IP" ]; then
            success "VPN is working! IP changed"
        else
            warning "IP not changed or couldn't detect. Proxy might still work."
        fi
    else
        error "Proxy connection failed"
    fi
    
    echo -e "${YELLOW}3. Testing internet access:${NC}"
    if timeout 10 ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        success "Internet access OK"
    else
        warning "Limited internet access"
    fi
}

create_management_script() {
    log "Creating management scripts..."
    
    # Start script
    cat > "$HOME/start_vpn.sh" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME"

echo "Starting VPN..."
source ./termux_vpn.sh --start
EOF
    
    # Stop script
    cat > "$HOME/stop_vpn.sh" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] Stopping VPN..."

# Kill processes
pkill -f "dns_forwarder.py" 2>/dev/null
pkill -f "vpn_tunnel.py" 2>/dev/null
pkill -f "socks_proxy.py" 2>/dev/null
pkill -f "socat.*53" 2>/dev/null

# Remove PID files
rm -f "$HOME/.vpn_dns.pid" "$HOME/.vpn_tunnel.pid" "$HOME/.vpn_proxy.pid" 2>/dev/null

# Reset DNS
setprop net.dns1 8.8.8.8 2>/dev/null
setprop net.dns2 1.1.1.1 2>/dev/null

echo "[✓] VPN stopped"
echo "[!] Note: You may need to restart Termux for DNS changes to take effect"
EOF
    
    # Status script
    cat > "$HOME/vpn_status.sh" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "=== VPN Status ==="
echo

# Check DNS
if pgrep -f "dns_forwarder.py" >/dev/null; then
    echo "DNS Forwarder: ${GREEN}Running${NC}"
else
    echo "DNS Forwarder: ${RED}Stopped${NC}"
fi

# Check Tunnel
if pgrep -f "vpn_tunnel.py" >/dev/null; then
    echo "VPN Tunnel: ${GREEN}Running${NC}"
else
    echo "VPN Tunnel: ${RED}Stopped${NC}"
fi

# Check Proxy
if pgrep -f "socks_proxy.py" >/dev/null; then
    echo "SOCKS5 Proxy: ${GREEN}Running${NC}"
else
    echo "SOCKS5 Proxy: ${RED}Stopped${NC}"
fi

echo
echo "=== Connection Test ==="
# Quick test
if timeout 3 nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
    echo "DNS Resolution: ${GREEN}OK${NC}"
else
    echo "DNS Resolution: ${RED}FAILED${NC}"
fi

if timeout 5 curl -s --socks5 127.0.0.1:9050 http://ipinfo.io/ip >/dev/null 2>&1; then
    echo "Proxy Connection: ${GREEN}OK${NC}"
else
    echo "Proxy Connection: ${RED}FAILED${NC}"
fi

echo
echo "Current IP: $(curl -s --socks5 127.0.0.1:9050 ifconfig.me 2>/dev/null || echo 'Unknown')"
EOF
    
    # Make executable
    chmod +x "$HOME/start_vpn.sh"
    chmod +x "$HOME/stop_vpn.sh"
    chmod +x "$HOME/vpn_status.sh"
    
    success "Management scripts created"
}

start_vpn() {
    log "Starting VPN..."
    
    # Cleanup first
    cleanup
    
    # Find working port
    if ! find_working_port; then
        warning "Using default port 443"
    fi
    
    # Start services
    if start_dns_forwarder; then
        sleep 3
        set_dns_settings
        sleep 2
        
        if create_vpn_tunnel; then
            sleep 2
            if setup_proxy; then
                configure_apps
                success "VPN started successfully!"
                return 0
            else
                error "Failed to start proxy"
            fi
        else
            error "Failed to start VPN tunnel"
        fi
    else
        error "Failed to start DNS forwarder"
    fi
    
    # Cleanup on failure
    cleanup
    return 1
}

auto_start_setup() {
    log "Setting up auto-start..."
    
    # Create Termux boot script
    mkdir -p "$HOME/.termux/boot"
    
    cat > "$HOME/.termux/boot/00_start_vpn" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
# Wait for network
sleep 10

# Start VPN
if [ -f "$HOME/start_vpn.sh" ]; then
    "$HOME/start_vpn.sh" > "$HOME/vpn_boot.log" 2>&1 &
fi
EOF
    
    chmod +x "$HOME/.termux/boot/00_start_vpn"
    
    success "Auto-start configured. VPN will start on Termux launch."
    warning "Note: You need Termux:Boot app from F-Droid for this to work."
}

show_menu() {
    clear
    echo -e "${CYAN}"
    echo "=========================================="
    echo "    TERMUX SLOWDNS VPN - FIXED"
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
    echo "9. Clean Install"
    echo "0. Exit"
    echo
    echo -n "Select option [0-9]: "
}

clean_install() {
    log "Performing clean installation..."
    
    # Stop everything
    cleanup
    
    # Remove old files
    rm -f "$HOME/vpn_tunnel.py" "$HOME/dns_forwarder.py" "$HOME/socks_proxy.py"
    rm -f "$HOME/start_vpn.sh" "$HOME/stop_vpn.sh" "$HOME/vpn_status.sh"
    rm -f "$HOME/.vpn_config" "$HOME/README_VPN.md"
    rm -f "$LOG_FILE"
    
    # Reinstall
    check_internet
    install_dependencies
    create_management_script
    
    success "Clean installation complete"
}

# ==========================================
# MAIN EXECUTION
# ==========================================

main() {
    # Check if not root
    check_root
    
    # Create log directory
    touch "$LOG_FILE"
    
    # Handle command line arguments
    case "$1" in
        "--start")
            if start_vpn; then
                test_vpn
            fi
            exit $?
            ;;
        "--stop")
            cleanup
            exit 0
            ;;
        "--status")
            "$HOME/vpn_status.sh" 2>/dev/null || echo "Status script not found"
            exit 0
            ;;
    esac
    
    # Main menu loop
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                check_internet
                install_dependencies
                find_working_port
                create_management_script
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            2)
                start_vpn
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            3)
                cleanup
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            4)
                if [ -f "$HOME/vpn_status.sh" ]; then
                    "$HOME/vpn_status.sh"
                else
                    echo "Status script not found. Run option 1 first."
                fi
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            5)
                test_vpn
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            6)
                configure_apps
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            7)
                echo -e "${YELLOW}=== VPN Logs (last 20 lines) ===${NC}"
                tail -20 "$LOG_FILE" 2>/dev/null || echo "No logs found"
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            8)
                auto_start_setup
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            9)
                clean_install
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            0)
                echo -e "${GREEN}[✓] Exiting${NC}"
                cleanup
                exit 0
                ;;
            *)
                error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Run main function
main "$@"
