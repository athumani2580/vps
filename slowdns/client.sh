#!/data/data/com.termux/files/usr/bin/bash

# Configuration
SERVER_IP="139.84.240.171"
DNS_RESOLVER="169.255.187.58"
DNS_PORT="53"
PROXY_HOST="127.0.0.1"
PROXY_PORT="8080"
SOCKS_HOST="127.0.0.1"
SOCKS_PORT="9050"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}"
echo "==========================================="
echo "    VPN CONFIGURATION FOR TERMUX"
echo "==========================================="
echo -e "${NC}"

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}[*] Installing required packages...${NC}"
    
    # Update package lists
    pkg update -y && pkg upgrade -y
    
    # Install essential packages
    pkg install -y openssh python3 curl wget tor proxychains-ng nmap dnsutils \
        python3-pip git nano vim tmux htop neofetch
    
    # Install Python packages
    pip3 install pysocks requests beautifulsoup4
    
    echo -e "${GREEN}[✓] Dependencies installed successfully!${NC}"
}

# Function to setup DNS resolver
setup_dns() {
    echo -e "${YELLOW}[*] Setting up DNS resolver ($DNS_RESOLVER)...${NC}"
    
    # Set DNS via multiple methods
    echo "nameserver $DNS_RESOLVER" > $PREFIX/etc/resolv.conf
    echo "nameserver 1.1.1.1" >> $PREFIX/etc/resolv.conf
    echo "nameserver 8.8.8.8" >> $PREFIX/etc/resolv.conf
    
    # Try to set via Android properties
    if command -v setprop &> /dev/null; then
        setprop net.dns1 $DNS_RESOLVER 2>/dev/null || true
        setprop net.dns2 1.1.1.1 2>/dev/null || true
    fi
    
    # Test DNS
    echo -e "${YELLOW}[*] Testing DNS resolver...${NC}"
    nslookup google.com $DNS_RESOLVER 2>/dev/null && \
        echo -e "${GREEN}[✓] DNS resolver working!${NC}" || \
        echo -e "${RED}[✗] DNS resolver test failed${NC}"
}

# Function to start HTTP proxy (simple Python proxy)
start_http_proxy() {
    echo -e "${YELLOW}[*] Starting HTTP proxy on $PROXY_HOST:$PROXY_PORT${NC}"
    
    # Kill any existing proxy on this port
    pkill -f "proxy_server.py" 2>/dev/null
    pkill -f ":$PROXY_PORT" 2>/dev/null
    
    # Create Python HTTP proxy server
    cat > $HOME/proxy_server.py << 'EOF'
#!/data/data/com.termux/files/usr/bin/python3
import socket
import threading
import sys

PROXY_HOST = '127.0.0.1'
PROXY_PORT = 8080
BUFFER_SIZE = 4096

def handle_client(client_socket):
    try:
        # Receive client request
        request = client_socket.recv(BUFFER_SIZE)
        
        # Parse HTTP headers to get destination
        first_line = request.decode('utf-8').split('\n')[0]
        url = first_line.split(' ')[1]
        
        print(f"[+] Proxy request: {first_line}")
        
        # Find destination host and port
        http_pos = url.find("://")
        if http_pos == -1:
            temp = url
        else:
            temp = url[(http_pos+3):]
        
        port_pos = temp.find(":")
        webserver_pos = temp.find("/")
        if webserver_pos == -1:
            webserver_pos = len(temp)
        
        webserver = ""
        port = -1
        if port_pos == -1 or webserver_pos < port_pos:
            port = 80
            webserver = temp[:webserver_pos]
        else:
            port = int(temp[(port_pos+1):][:webserver_pos-port_pos-1])
            webserver = temp[:port_pos]
        
        # Create socket to destination
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect((webserver, port))
        
        # Send request to destination
        s.send(request)
        
        # Receive response
        while True:
            data = s.recv(BUFFER_SIZE)
            if len(data) > 0:
                client_socket.send(data)
            else:
                break
        
        s.close()
        client_socket.close()
        
    except Exception as e:
        print(f"[-] Error: {e}")
        try:
            client_socket.close()
        except:
            pass

def start_proxy():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((PROXY_HOST, PROXY_PORT))
    server.listen(5)
    
    print(f"[*] HTTP Proxy server started on {PROXY_HOST}:{PROXY_PORT}")
    print("[*] Waiting for connections...")
    
    while True:
        client_socket, addr = server.accept()
        print(f"[+] Connection from: {addr[0]}:{addr[1]}")
        client_handler = threading.Thread(target=handle_client, args=(client_socket,))
        client_handler.start()

if __name__ == "__main__":
    start_proxy()
EOF
    
    chmod +x $HOME/proxy_server.py
    
    # Start proxy in background
    python3 $HOME/proxy_server.py &
    sleep 2
    
    if pgrep -f "proxy_server.py" > /dev/null; then
        echo -e "${GREEN}[✓] HTTP proxy started on $PROXY_HOST:$PROXY_PORT${NC}"
    else
        echo -e "${RED}[✗] Failed to start HTTP proxy${NC}"
    fi
}

# Function to start SOCKS5 proxy (using Tor)
start_socks_proxy() {
    echo -e "${YELLOW}[*] Starting SOCKS5 proxy on $SOCKS_HOST:$SOCKS_PORT${NC}"
    
    # Kill any existing Tor
    pkill tor 2>/dev/null
    
    # Create minimal Tor config
    cat > $PREFIX/etc/tor/torrc << EOF
SocksPort $SOCKS_HOST:$SOCKS_PORT
SocksPolicy accept 127.0.0.1
SocksPolicy reject *
Log notice stdout
DataDirectory $PREFIX/var/lib/tor
RunAsDaemon 1
EOF
    
    # Start Tor
    tor &
    sleep 5
    
    if pgrep tor > /dev/null; then
        echo -e "${GREEN}[✓] SOCKS5 proxy started on $SOCKS_HOST:$SOCKS_PORT${NC}"
    else
        echo -e "${RED}[✗] Failed to start SOCKS5 proxy${NC}"
        echo -e "${YELLOW}[*] Trying alternative method...${NC}"
        
        # Alternative: Simple SOCKS5 proxy in Python
        cat > $HOME/socks_proxy.py << 'EOF'
#!/data/data/com.termux/files/usr/bin/python3
import socket
import select
import struct

SOCKS_VERSION = 5
SOCKS_HOST = '127.0.0.1'
SOCKS_PORT = 9050

def handle_handshake(client):
    version = client.recv(1)
    nmethods = client.recv(1)
    methods = client.recv(ord(nmethods))
    client.sendall(struct.pack("!BB", SOCKS_VERSION, 0))
    return True

def handle_request(client):
    version = client.recv(1)
    cmd = client.recv(1)
    rsv = client.recv(1)
    atyp = client.recv(1)
    
    if atyp == b'\x01':  # IPv4
        addr = socket.inet_ntoa(client.recv(4))
    elif atyp == b'\x03':  # Domain name
        domain_length = client.recv(1)
        addr = client.recv(ord(domain_length))
    else:
        return False
    
    port = struct.unpack('!H', client.recv(2))[0]
    
    try:
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect((addr, port))
        bind_addr = remote.getsockname()
        addr_ip = socket.inet_aton(bind_addr[0])
        addr_port = struct.pack('!H', bind_addr[1])
        
        reply = struct.pack("!BBBB", SOCKS_VERSION, 0, 0, 1) + addr_ip + addr_port
        client.sendall(reply)
        
        sockets = [client, remote]
        while True:
            sread, swrite, sexc = select.select(sockets, [], [])
            if client in sread:
                data = client.recv(4096)
                if remote.send(data) <= 0:
                    break
            if remote in sread:
                data = remote.recv(4096)
                if client.send(data) <= 0:
                    break
    except:
        pass
    
    client.close()
    remote.close()
    return True

def start_socks_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((SOCKS_HOST, SOCKS_PORT))
    server.listen(5)
    
    print(f"[*] SOCKS5 Proxy server started on {SOCKS_HOST}:{SOCKS_PORT}")
    
    while True:
        client, addr = server.accept()
        print(f"[+] Connection from: {addr[0]}:{addr[1]}")
        if handle_handshake(client):
            handle_request(client)

if __name__ == "__main__":
    start_socks_server()
EOF
        
        chmod +x $HOME/socks_proxy.py
        python3 $HOME/socks_proxy.py &
        sleep 2
    fi
}

# Function to configure proxychains
setup_proxychains() {
    echo -e "${YELLOW}[*] Configuring proxychains...${NC}"
    
    # Backup original config
    if [ -f $PREFIX/etc/proxychains.conf ]; then
        cp $PREFIX/etc/proxychains.conf $PREFIX/etc/proxychains.conf.backup
    fi
    
    # Create new config
    cat > $PREFIX/etc/proxychains.conf << EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
# HTTP Proxy
http $PROXY_HOST $PROXY_PORT

# SOCKS5 Proxy
socks5 $SOCKS_HOST $SOCKS_PORT

# Alternative: Use only one
#socks5 $SOCKS_HOST $SOCKS_PORT
EOF
    
    echo -e "${GREEN}[✓] Proxychains configured!${NC}"
}

# Function to set environment variables
set_env_vars() {
    echo -e "${YELLOW}[*] Setting environment variables...${NC}"
    
    export HTTP_PROXY="http://$PROXY_HOST:$PROXY_PORT"
    export HTTPS_PROXY="http://$PROXY_HOST:$PROXY_PORT"
    export SOCKS_PROXY="socks5://$SOCKS_HOST:$SOCKS_PORT"
    export ALL_PROXY="socks5://$SOCKS_HOST:$SOCKS_PORT"
    export http_proxy="http://$PROXY_HOST:$PROXY_PORT"
    export https_proxy="http://$PROXY_HOST:$PROXY_PORT"
    export socks_proxy="socks5://$SOCKS_HOST:$SOCKS_PORT"
    export all_proxy="socks5://$SOCKS_HOST:$SOCKS_PORT"
    
    # Add to bashrc for persistence
    cat >> $HOME/.bashrc << EOF

# Proxy settings
export HTTP_PROXY="http://$PROXY_HOST:$PROXY_PORT"
export HTTPS_PROXY="http://$PROXY_HOST:$PROXY_PORT"
export SOCKS_PROXY="socks5://$SOCKS_HOST:$SOCKS_PORT"
export ALL_PROXY="socks5://$SOCKS_HOST:$SOCKS_PORT"
alias use-proxy='source $HOME/.bashrc'
EOF
    
    echo -e "${GREEN}[✓] Environment variables set!${NC}"
}

# Function to test connections
test_connections() {
    echo -e "${YELLOW}[*] Testing connections...${NC}"
    
    echo -e "\n${BLUE}1. Testing direct connection:${NC}"
    curl -s --connect-timeout 5 http://ipinfo.io/ip && echo "✓ Direct connection OK" || echo "✗ Direct connection failed"
    
    echo -e "\n${BLUE}2. Testing HTTP proxy:${NC}"
    curl -s --proxy http://$PROXY_HOST:$PROXY_PORT --connect-timeout 5 http://ipinfo.io/ip && echo "✓ HTTP proxy OK" || echo "✗ HTTP proxy failed"
    
    echo -e "\n${BLUE}3. Testing SOCKS5 proxy:${NC}"
    curl -s --socks5 $SOCKS_HOST:$SOCKS_PORT --connect-timeout 5 http://ipinfo.io/ip && echo "✓ SOCKS5 proxy OK" || echo "✗ SOCKS5 proxy failed"
    
    echo -e "\n${BLUE}4. Testing proxychains:${NC}"
    timeout 10 proxychains curl -s http://ipinfo.io/ip && echo "✓ Proxychains OK" || echo "✗ Proxychains failed"
    
    echo -e "\n${BLUE}5. Testing DNS resolution:${NC}"
    nslookup google.com $DNS_RESOLVER 2>/dev/null && echo "✓ DNS resolution OK" || echo "✗ DNS resolution failed"
}

# Function to create app configurations
create_app_configs() {
    echo -e "${YELLOW}[*] Creating application configurations...${NC}"
    
    # For wget
    cat > $HOME/.wgetrc << EOF
use_proxy = on
http_proxy = http://$PROXY_HOST:$PROXY_PORT
https_proxy = http://$PROXY_HOST:$PROXY_PORT
EOF
    
    # For curl (alternative config)
    cat > $HOME/.curlrc << EOF
proxy = http://$PROXY_HOST:$PROXY_PORT
socks5 = $SOCKS_HOST:$SOCKS_PORT
EOF
    
    # Create simple test script
    cat > $HOME/test-vpn.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
echo "Testing VPN connections..."
echo "1. Direct: \$(curl -s --connect-timeout 3 http://ipinfo.io/ip || echo 'Failed')"
echo "2. HTTP Proxy: \$(curl -s --proxy http://$PROXY_HOST:$PROXY_PORT --connect-timeout 3 http://ipinfo.io/ip || echo 'Failed')"
echo "3. SOCKS5: \$(curl -s --socks5 $SOCKS_HOST:$SOCKS_PORT --connect-timeout 3 http://ipinfo.io/ip || echo 'Failed')"
echo "4. DNS: \$(nslookup google.com $DNS_RESOLVER 2>/dev/null | grep Address | tail -1 || echo 'Failed')"
EOF
    chmod +x $HOME/test-vpn.sh
    
    echo -e "${GREEN}[✓] Application configs created!${NC}"
    echo -e "${YELLOW}[*] Test with: ./test-vpn.sh${NC}"
}

# Function to show usage
show_usage() {
    echo -e "${GREEN}"
    echo "==========================================="
    echo "           VPN READY TO USE!"
    echo "==========================================="
    echo -e "${NC}"
    echo "Available proxies:"
    echo "  HTTP Proxy:  $PROXY_HOST:$PROXY_PORT"
    echo "  SOCKS5 Proxy: $SOCKS_HOST:$SOCKS_PORT"
    echo ""
    echo "Usage commands:"
    echo "  Test HTTP:    curl --proxy http://$PROXY_HOST:$PROXY_PORT http://ipinfo.io/ip"
    echo "  Test SOCKS5:  curl --socks5 $SOCKS_HOST:$SOCKS_PORT http://ipinfo.io/ip"
    echo "  Use proxychains: proxychains curl http://ipinfo.io/ip"
    echo "  Test all:     ./test-vpn.sh"
    echo ""
    echo "To make proxy permanent in current session:"
    echo "  source ~/.bashrc"
    echo "  or run: use-proxy"
    echo ""
    echo "Application configs created in:"
    echo "  ~/.wgetrc, ~/.curlrc"
}

# Main execution
main() {
    echo -e "${BLUE}[*] Starting VPN setup...${NC}"
    
    # Install dependencies first
    install_dependencies
    
    # Setup DNS
    setup_dns
    
    # Start proxies
    start_http_proxy
    start_socks_proxy
    
    # Configure system
    setup_proxychains
    set_env_vars
    create_app_configs
    
    # Test everything
    test_connections
    
    # Show usage
    show_usage
    
    echo -e "\n${GREEN}[✓] VPN setup completed!${NC}"
}

# Run main function
main
