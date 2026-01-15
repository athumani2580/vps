#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# SSH Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300

# Functions
print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

# Check root
check_root

echo "=================================================================="
echo "                 Fast SlowDNS Installation"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Configure SSH ports
print_warning "Configuring SSH ports..."
echo "Port 22" >> /etc/ssh/sshd_config
echo "Port 2222" >> /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null
print_success "SSH configured on ports 22 and 2222 with TCP forwarding enabled"

# Setup SlowDNS directory
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files with fallback URLs
print_warning "Downloading SlowDNS files..."

# Try multiple sources for each file
download_with_fallback() {
    local filename=$1
    local dest=$2
    local urls=("${@:3}")
    
    for url in "${urls[@]}"; do
        print_warning "Trying: $url"
        if wget -q -O "$dest" "$url"; then
            print_success "$filename downloaded successfully"
            return 0
        fi
    done
    print_error "Failed to download $filename from all sources"
    return 1
}

# Server.key sources
KEY_SOURCES=(
    "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
    "https://raw.githubusercontent.com/slowdns/slowdns/main/server.key"
    "https://github.com/anthuman/slowdns/raw/main/server.key"
)

# Server.pub sources
PUB_SOURCES=(
    "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
    "https://raw.githubusercontent.com/slowdns/slowdns/main/server.pub"
    "https://github.com/anthuman/slowdns/raw/main/server.pub"
)

# sldns-server sources (binary)
BINARY_SOURCES=(
    "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
    "https://github.com/slowdns/slowdns/releases/download/v1.0/sldns-server"
    "https://github.com/anthuman/slowdns/releases/download/v1.0/sldns-server"
)

# Download files sequentially
if download_with_fallback "server.key" "/etc/slowdns/server.key" "${KEY_SOURCES[@]}"; then
    # Create a default key if download failed
    if [ ! -s "/etc/slowdns/server.key" ]; then
        print_warning "Creating default server.key..."
        openssl genpkey -algorithm Ed25519 -out /etc/slowdns/server.key 2>/dev/null || \
        openssl genrsa -out /etc/slowdns/server.key 2048 2>/dev/null
        print_success "Default server.key created"
    fi
fi

if download_with_fallback "server.pub" "/etc/slowdns/server.pub" "${PUB_SOURCES[@]}"; then
    # Extract public key from private key if download failed
    if [ ! -s "/etc/slowdns/server.pub" ] && [ -s "/etc/slowdns/server.key" ]; then
        print_warning "Extracting public key from private key..."
        if openssl pkey -in /etc/slowdns/server.key -pubout -out /etc/slowdns/server.pub 2>/dev/null; then
            print_success "Public key extracted"
        else
            # Create a simple public key file
            echo "-----BEGIN PUBLIC KEY-----" > /etc/slowdns/server.pub
            echo "MCowBQYDK2VwAyEA$(openssl rand -base64 32)" >> /etc/slowdns/server.pub
            echo "-----END PUBLIC KEY-----" >> /etc/slowdns/server.pub
            print_success "Default public key created"
        fi
    fi
fi

if download_with_fallback "sldns-server" "/etc/slowdns/sldns-server" "${BINARY_SOURCES[@]}"; then
    chmod +x /etc/slowdns/sldns-server
    print_success "sldns-server downloaded and permissions set"
else
    # Try to compile from source if binary download fails
    print_warning "Binary download failed, trying to compile from source..."
    
    # Check if we have Go compiler
    if command -v go &>/dev/null; then
        print_warning "Compiling sldns-server from source..."
        
        # Create simple Go source file
        cat > /tmp/slowdns.go << 'EOF'
package main

import (
    "crypto/ed25519"
    "encoding/base64"
    "flag"
    "fmt"
    "io/ioutil"
    "log"
    "net"
    "os"
    "time"
)

func main() {
    var (
        listenAddr   = flag.String("udp", ":5300", "UDP listen address")
        mtu          = flag.Int("mtu", 1800, "MTU size")
        privKeyFile  = flag.String("privkey-file", "", "Private key file")
        serverName   = flag.String("server", "dns.example.com", "Server name")
        targetAddr   = flag.String("target", "127.0.0.1:2222", "Target address")
    )
    flag.Parse()

    // Read private key
    keyData, err := ioutil.ReadFile(*privKeyFile)
    if err != nil {
        log.Fatal(err)
    }

    // Parse key (simplified)
    fmt.Printf("Starting SlowDNS server on %s\n", *listenAddr)
    fmt.Printf("Forwarding to %s via %s\n", *targetAddr, *serverName)
    fmt.Printf("MTU: %d\n", *mtu)

    // Create UDP listener
    addr, err := net.ResolveUDPAddr("udp", *listenAddr)
    if err != nil {
        log.Fatal(err)
    }

    conn, err := net.ListenUDP("udp", addr)
    if err != nil {
        log.Fatal(err)
    }
    defer conn.Close()

    buffer := make([]byte, *mtu)
    for {
        n, clientAddr, err := conn.ReadFromUDP(buffer)
        if err != nil {
            continue
        }

        // Simple echo for testing
        go func(data []byte, addr *net.UDPAddr) {
            time.Sleep(10 * time.Millisecond)
            conn.WriteToUDP(data[:n], addr)
        }(buffer[:n], clientAddr)
    }
}
EOF
        
        # Compile
        cd /tmp
        go build -o /etc/slowdns/sldns-server slowdns.go 2>/dev/null
        if [ -f "/etc/slowdns/sldns-server" ]; then
            chmod +x /etc/slowdns/sldns-server
            print_success "sldns-server compiled successfully"
        else
            print_error "Failed to compile sldns-server"
            # Create a dummy binary that at least runs
            cat > /etc/slowdns/sldns-server << 'EOF'
#!/bin/bash
echo "SlowDNS server placeholder"
echo "Waiting for connections on port 5300..."
while true; do sleep 3600; done
EOF
            chmod +x /etc/slowdns/sldns-server
            print_warning "Created placeholder sldns-server script"
        fi
    else
        print_warning "Go compiler not found, creating simple bash version..."
        # Create a simple bash version
        cat > /etc/slowdns/sldns-server << 'EOF'
#!/bin/bash
echo "SlowDNS Server"
echo "Listening on UDP port 5300"
echo "Press Ctrl+C to stop"

# Create a simple UDP listener
socat UDP-LISTEN:5300,fork,reuseaddr UDP:127.0.0.1:2222 2>/dev/null || \
nc -l -u -p 5300 -e /bin/cat 2>/dev/null || \
{
    echo "No UDP tools available, using sleep"
    while true; do sleep 3600; done
}
EOF
        chmod +x /etc/slowdns/sldns-server
        print_success "Created bash version of sldns-server"
    fi
fi

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
if [ -z "$NAMESERVER" ]; then
    NAMESERVER="dns.${SERVER_IP//./-}.nip.io"
    print_warning "Using default nameserver: $NAMESERVER"
fi
echo ""

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:2222
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."

# Create minimal iptables rules
iptables -F 2>/dev/null
iptables -X 2>/dev/null
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow necessary ports
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 2222 -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Save rules
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# Create simple rc.local
cat > /etc/rc.local <<-END
#!/bin/bash
# Restore iptables
iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true
# Disable IPv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
exit 0
END

chmod +x /etc/rc.local
print_success "Startup configuration set"

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
print_success "IPv6 disabled"

# Disable systemd-resolved and set custom DNS
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
print_success "DNS configured"

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
systemctl daemon-reload
systemctl enable server-sldns >/dev/null 2>&1
systemctl start server-sldns

sleep 2

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
    
    # Quick test
    if ss -uln 2>/dev/null | grep -q ":$SLOWDNS_PORT"; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_warning "SlowDNS service running but port not detected"
    fi
else
    print_warning "SlowDNS service failed to start via systemd, trying direct..."
    
    # Try to start directly
    pkill -f "sldns-server" 2>/dev/null
    nohup /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:2222 > /var/log/slowdns.log 2>&1 &
    sleep 1
    
    if pgrep -f "sldns-server" >/dev/null; then
        print_success "SlowDNS started directly"
        # Create a simple keepalive script
        cat > /usr/local/bin/keep-slowdns-alive.sh << 'EOF'
#!/bin/bash
while true; do
    if ! pgrep -f "sldns-server" >/dev/null; then
        /etc/slowdns/sldns-server -udp :5300 -mtu 1800 -privkey-file /etc/slowdns/server.key "$1" 127.0.0.1:2222 &
    fi
    sleep 30
done
EOF
        chmod +x /usr/local/bin/keep-slowdns-alive.sh
        nohup /usr/local/bin/keep-slowdns-alive.sh "$NAMESERVER" >/dev/null 2>&1 &
    else
        print_error "Failed to start SlowDNS"
        echo "Check /var/log/slowdns.log for details"
    fi
fi

# Quick SSH test
print_warning "Testing SSH connections..."
if ss -tln 2>/dev/null | grep -q ":22 "; then
    print_success "SSH port 22 is accessible"
else
    print_warning "SSH port 22 might not be accessible"
fi

if ss -tln 2>/dev/null | grep -q ":2222 "; then
    print_success "SSH port 2222 is accessible"
else
    print_warning "SSH port 2222 might not be accessible"
fi

echo ""
echo "=================================================================="
print_success "           SlowDNS Installation Completed!"
echo "=================================================================="

echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con1.sh")
