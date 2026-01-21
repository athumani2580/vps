#!/data/data/com.termux/files/usr/bin/bash

# Configuration
SERVER_IP="139.84.240.171"
DNS_RESOLVER="169.255.187.58"
DNS_PORT="53"
NS_SERVER="gerry.alienalien.top"
PUBLIC_KEY="7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59"
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

echo -e "${BLUE}Termux VPN Setup with DNS Resolver${NC}"
echo "======================================"

# Install required packages
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    pkg update -y
    pkg install -y python3 python3-pip tor proxychains-ng curl wget dnsutils ndc rinetd
    
    # Install DNS tools
    pip3 install dnspython socks pysocks
    
    echo -e "${GREEN}Dependencies installed!${NC}"
}

# Setup DNS resolver properly
setup_dns_resolver() {
    echo -e "${YELLOW}Setting up DNS resolver: $DNS_RESOLVER:$DNS_PORT${NC}"
    
    # Method 1: Using ndc (if available)
    if command -v ndc &> /dev/null; then
        echo -e "${BLUE}Setting DNS via ndc...${NC}"
        ndc resolver setnetdns "" $DNS_RESOLVER 1.1.1.1
    fi
    
    # Method 2: Create custom resolv.conf
    cat > $PREFIX/etc/resolv.conf << EOF
# Custom DNS Resolver Configuration
nameserver $DNS_RESOLVER
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3 rotate
EOF
    
    # Method 3: Set via setprop (Android properties)
    echo -e "${BLUE}Setting DNS via Android properties...${NC}"
    setprop net.dns1 $DNS_RESOLVER
    setprop net.dns2 "1.1.1.1"
    
    # Create DNS forwarding script
    cat > $HOME/dns-forwarder.py << 'EOF'
#!/data/data/com.termux/files/usr/bin/python3
import socket
import sys
import struct

DNS_RESOLVER = "169.255.187.58"
DNS_PORT = 53
LOCAL_PORT = 5353

def forward_dns():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', LOCAL_PORT))
    
    print(f"DNS Forwarder running on 127.0.0.1:{LOCAL_PORT}")
    print(f"Forwarding to {DNS_RESOLVER}:{DNS_PORT}")
    
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            # Forward to resolver
            resolver_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            resolver_sock.sendto(data, (DNS_RESOLVER, DNS_PORT))
            response, _ = resolver_sock.recvfrom(1024)
            # Send back to client
            sock.sendto(response, addr)
            resolver_sock.close()
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Error: {e}")

if __name__ == "__main__":
    forward_dns()
EOF
    
    chmod +x $HOME/dns-forwarder.py
    echo -e "${GREEN}DNS forwarder script created: ~/dns-forwarder.py${NC}"
    echo -e "${YELLOW}Run: python3 ~/dns-forwarder.py${NC}"
}

# Setup proxy server (rinetd port forwarding)
setup_proxy_forwarding() {
    echo -e "${YELLOW}Setting up proxy forwarding...${NC}"
    
    # Create rinetd config for HTTP proxy
    cat > $PREFIX/etc/rinetd.conf << EOF
# Redirect local port 8080 to server proxy
0.0.0.0 8080 $SERVER_IP 8080
0.0.0.0 1080 $SERVER_IP 1080
EOF
    
    # Start rinetd
    pkill rinetd 2>/dev/null
    rinetd -c $PREFIX/etc/rinetd.conf
    
    echo -e "${GREEN}Proxy forwarding configured!${NC}"
    echo -e "Local HTTP Proxy: $PROXY_HOST:$PROXY_PORT -> $SERVER_IP:8080"
}

# Start Tor SOCKS5 proxy
start_tor_socks() {
    echo -e "${YELLOW}Starting Tor SOCKS5 proxy...${NC}"
    
    # Create minimal torrc
    cat > $PREFIX/etc/tor/torrc << EOF
SocksPort $SOCKS_HOST:$SOCKS_PORT
SocksPolicy accept 127.0.0.1/32
SocksPolicy reject *
Log notice stdout
DataDirectory $PREFIX/var/lib/tor
RunAsDaemon 1
EOF
    
    # Start Tor
    pkill tor 2>/dev/null
    tor -f $PREFIX/etc/tor/torrc
    
    sleep 3
    
    if pgrep tor > /dev/null; then
        echo -e "${GREEN}Tor SOCKS5 proxy running on $SOCKS_HOST:$SOCKS_PORT${NC}"
    else
        echo -e "${RED}Failed to start Tor${NC}"
    fi
}

# Configure proxychains with multiple options
setup_proxychains_config() {
    echo -e "${YELLOW}Configuring proxychains...${NC}"
    
    cat > $PREFIX/etc/proxychains.conf << EOF
# Proxychains config with multiple proxy options
dynamic_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
# Choose one of the following configurations:

# Option 1: Use SOCKS5 (Tor)
socks5 $SOCKS_HOST $SOCKS_PORT

# Option 2: Use HTTP proxy (comment out if not used)
#http $PROXY_HOST $PROXY_PORT

# Option 3: Direct to your server via SOCKS
#socks5 $SERVER_IP 1080

# Option 4: Chain proxies (uncomment to use)
#socks5 $SOCKS_HOST $SOCKS_PORT
#http $PROXY_HOST $PROXY_PORT
EOF
    
    echo -e "${GREEN}Proxychains configured!${NC}"
    echo -e "${YELLOW}Edit $PREFIX/etc/proxychains.conf to choose proxy method${NC}"
}

# Create universal proxy script
create_universal_proxy() {
    cat > $HOME/proxy-wrapper.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash

# Universal proxy wrapper script
# Usage: proxy-wrapper.sh <command>

PROXY_TYPE="${1:-socks5}"
HOST="${2:-127.0.0.1}"
PORT="${3:-9050}"
COMMAND="${4:-$SHELL}"

case $PROXY_TYPE in
    "http"|"https")
        export HTTP_PROXY="http://$HOST:$PORT"
        export HTTPS_PROXY="http://$HOST:$PORT"
        export http_proxy="http://$HOST:$PORT"
        export https_proxy="http://$HOST:$PORT"
        ;;
    "socks"|"socks5")
        export SOCKS_PROXY="socks5://$HOST:$PORT"
        export ALL_PROXY="socks5://$HOST:$PORT"
        export socks_proxy="socks5://$HOST:$PORT"
        export all_proxy="socks5://$HOST:$PORT"
        ;;
    "both")
        export HTTP_PROXY="http://$HOST:8080"
        export HTTPS_PROXY="http://$HOST:8080"
        export SOCKS_PROXY="socks5://$HOST:9050"
        export ALL_PROXY="socks5://$HOST:9050"
        ;;
    *)
        echo "Usage: $0 [http|socks|both] [host] [port] [command]"
        exit 1
        ;;
esac

echo "Proxy settings applied: $PROXY_TYPE://$HOST:$PORT"
echo "Running: $COMMAND"
exec $COMMAND
EOF
    
    chmod +x $HOME/proxy-wrapper.sh
    echo -e "${GREEN}Universal proxy wrapper created: ~/proxy-wrapper.sh${NC}"
}

# Test all configurations
test_all_configs() {
    echo -e "${YELLOW}Testing configurations...${NC}"
    
    echo -e "\n${BLUE}1. Testing DNS resolver...${NC}"
    nslookup google.com $DNS_RESOLVER
    
    echo -e "\n${BLUE}2. Testing direct connection...${NC}"
    curl -s --connect-timeout 5 http://ipinfo.io/ip || echo "Direct connection failed"
    
    echo -e "\n${BLUE}3. Testing HTTP proxy...${NC}"
    curl -s --proxy http://$PROXY_HOST:$PROXY_PORT --connect-timeout 5 http://ipinfo.io/ip && echo "✓ HTTP proxy working" || echo "✗ HTTP proxy failed"
    
    echo -e "\n${BLUE}4. Testing SOCKS5 proxy...${NC}"
    curl -s --socks5 $SOCKS_HOST:$SOCKS_PORT --connect-timeout 5 http://ipinfo.io/ip && echo "✓ SOCKS5 proxy working" || echo "✗ SOCKS5 proxy failed"
    
    echo -e "\n${BLUE}5. Testing proxychains...${NC}"
    timeout 10 proxychains curl -s http://ipinfo.io/ip && echo "✓ Proxychains working" || echo "✗ Proxychains failed"
    
    echo -e "\n${BLUE}6. Testing with custom DNS...${NC}"
    dig @$DNS_RESOLVER google.com +short
}

# Create application-specific scripts
create_app_scripts() {
    # For wget
    cat > $HOME/.wgetrc << EOF
use_proxy = on
http_proxy = http://$PROXY_HOST:$PROXY_PORT
https_proxy = http://$PROXY_HOST:$PROXY_PORT
EOF
    
    # For git
    cat > $HOME/.gitconfig-proxy << EOF
[http]
    proxy = http://$PROXY_HOST:$PROXY_PORT
[https]
    proxy = http://$PROXY_HOST:$PROXY_PORT
EOF
    
    # For apt (if using proot-distro)
    cat > $HOME/apt-proxy.sh << EOF
#!/bin/bash
echo "Acquire::http::Proxy \"http://$PROXY_HOST:$PROXY_PORT\";" | sudo tee /etc/apt/apt.conf.d/proxy.conf
echo "Acquire::https::Proxy \"http://$PROXY_HOST:$PROXY_PORT\";" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf
EOF
    
    chmod +x $HOME/apt-proxy.sh
    
    echo -e "${GREEN}Application proxy configs created!${NC}"
}

# Main installation
full_installation() {
    echo -e "${BLUE}Starting full VPN setup...${NC}"
    
    install_dependencies
    setup_dns_resolver
    setup_proxy_forwarding
    start_tor_socks
    setup_proxychains_config
    create_universal_proxy
    create_app_scripts
    
    echo -e "\n${GREEN}=== Setup Complete! ===${NC}"
    echo -e "Available proxies:"
    echo -e "  HTTP:  $PROXY_HOST:$PROXY_PORT"
    echo -e "  SOCKS5: $SOCKS_HOST:$SOCKS_PORT"
    echo -e "\nCommands:"
    echo -e "  Test DNS: nslookup google.com $DNS_RESOLVER"
    echo -e "  Test HTTP: curl --proxy http://$PROXY_HOST:$PROXY_PORT http://ipinfo.io/ip"
    echo -e "  Test SOCKS: curl --socks5 $SOCKS_HOST:$SOCKS_PORT http://ipinfo.io/ip"
    echo -e "  Use proxychains: proxychains <command>"
    echo -e "  Use wrapper: ~/proxy-wrapper.sh http/socks <command>"
}

# Interactive menu
interactive_menu() {
    while true; do
        echo -e "\n${BLUE}=== VPN Setup Menu ===${NC}"
        echo "1. Full Installation"
        echo "2. Setup DNS Resolver Only"
        echo "3. Start SOCKS5 Proxy (Tor)"
        echo "4. Configure Proxychains"
        echo "5. Test All Configurations"
        echo "6. Create Proxy Wrapper"
        echo "7. Set Environment Variables"
        echo "8. Start DNS Forwarder"
        echo "9. Stop All Services"
        echo "0. Exit"
        
        read -p "Select option: " choice
        
        case $choice in
            1) full_installation ;;
            2) setup_dns_resolver ;;
            3) start_tor_socks ;;
            4) setup_proxychains_config ;;
            5) test_all_configs ;;
            6) create_universal_proxy ;;
            7) 
                export HTTP_PROXY="http://$PROXY_HOST:$PROXY_PORT"
                export HTTPS_PROXY="http://$PROXY_HOST:$PROXY_PORT"
                export ALL_PROXY="socks5://$SOCKS_HOST:$SOCKS_PORT"
                echo "Environment variables set!"
            ;;
            8) python3 $HOME/dns-forwarder.py & ;;
            9)
                pkill tor
                pkill rinetd
                pkill -f dns-forwarder.py
                echo "All services stopped"
            ;;
            0) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Check if running in Termux
if [ ! -d "/data/data/com.termux" ]; then
    echo -e "${RED}This script must be run in Termux!${NC}"
    exit 1
fi

# Start interactive menu
interactive_menu
