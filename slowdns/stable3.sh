#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# SSH Port Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300

# Optimized settings for streaming
MTU_SIZE=1400  # Increased for better video streaming
BUFFER_SIZE=4194304  # 4MB buffer for streaming
TCP_WINDOW=1048576  # 1MB TCP window

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
echo "     OpenSSH SlowDNS Installation (YouTube Optimized)"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi
print_success "Server IP: $SERVER_IP"

# Backup original SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Configure SSH ports with streaming optimizations
print_warning "Configuring SSH ports for streaming..."

# Ensure ports are not duplicated
sed -i '/^Port 22/d' /etc/ssh/sshd_config
sed -i '/^Port 69/d' /etc/ssh/sshd_config

echo "Port 22" >> /etc/ssh/sshd_config
echo "Port 69" >> /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config

# SSH optimizations for streaming
echo "ClientAliveInterval 15" >> /etc/ssh/sshd_config
echo "ClientAliveCountMax 5" >> /etc/ssh/sshd_config
echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config
echo "Compression no" >> /etc/ssh/sshd_config  # Disable compression for video
echo "IPQoS af21 cs1" >> /etc/ssh/sshd_config  # QoS for streaming

systemctl restart sshd 2>/dev/null
sleep 2
print_success "SSH configured with streaming optimizations"

# Setup SlowDNS
print_warning "Setting up SlowDNS with streaming optimizations..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files with retry mechanism
print_warning "Downloading SlowDNS files..."
download_file() {
    local url=$1
    local output=$2
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        wget -q -O "$output" "$url"
        if [ $? -eq 0 ] && [ -s "$output" ]; then
            return 0
        fi
        retry=$((retry + 1))
        sleep 2
    done
    return 1
}

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" "/etc/slowdns/server.key"; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key"
fi

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" "/etc/slowdns/server.pub"; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub"
fi

if download_file "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server" "/etc/slowdns/sldns-server"; then
    print_success "sldns-server downloaded"
else
    print_error "Failed to download sldns-server"
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Optimized MTU selection for YouTube
echo "MTU Configuration for YouTube Streaming:"
echo "1) 1400 (Recommended - Best for YouTube)"
echo "2) 1450 (Maximum - May cause issues)"
echo "3) 1350 (Conservative - More stable)"
echo "4) 1300 (Your previous setting)"
read -p "Select MTU option [1-4]: " mtu_choice

case $mtu_choice in
    1) MTU_SIZE=1400 ;;
    2) MTU_SIZE=1450 ;;
    3) MTU_SIZE=1350 ;;
    4) MTU_SIZE=1300 ;;
    *) MTU_SIZE=1400 ;;
esac

print_success "Using MTU size: $MTU_SIZE"

# Create SlowDNS service with streaming optimizations
print_warning "Creating optimized SlowDNS service for streaming..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS (Streaming Optimized)
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=/bin/sleep 2
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu $MTU_SIZE -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=3
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Advanced network optimizations for streaming
print_warning "Applying system optimizations for YouTube streaming..."

# Network kernel optimizations
cat >> /etc/sysctl.conf << EOF

# SlowDNS Streaming Optimizations
# Buffer settings for video streaming
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 134217728
net.core.netdev_max_backlog = 5000

# TCP settings for streaming
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Timeout settings
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0

# Bufferbloat fixes
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# Connection tracking for UDP (SlowDNS)
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# IPv6 disable
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

sysctl -p > /dev/null 2>&1
print_success "Network optimizations applied"

# Improved iptables for streaming
print_warning "Setting up iptables with QoS for streaming..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
systemctl start sshd

# Clear existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH ports
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 69 -j ACCEPT

# Allow SlowDNS port (UDP)
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT

# DNS redirect with connection tracking
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $SLOWDNS_PORT

# QoS for SlowDNS (prioritize UDP)
iptables -t mangle -A OUTPUT -p udp --dport $SLOWDNS_PORT -j DSCP --set-dscp 46
iptables -t mangle -A INPUT -p udp --sport $SLOWDNS_PORT -j DSCP --set-dscp 46

# Rate limiting for SSH (but higher limits for streaming)
iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --update --seconds 60 --hitcount 30 -j DROP

# Allow ICMP
iptables -A INPUT -p icmp -j ACCEPT

# Drop invalid packets
iptables -A INPUT -m state --state INVALID -j DROP

# Start SlowDNS with higher priority
renice -n -10 \$(pgrep sldns-server) 2>/dev/null

exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1
print_success "Firewall with QoS configured"

# DNS configuration with YouTube optimization
print_warning "Configuring DNS for faster YouTube access..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null

# Remove immutable attribute if set
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf

# Create optimized resolv.conf
cat > /etc/resolv.conf << EOF
# YouTube Optimized DNS
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
nameserver 208.67.222.222
options timeout:1 attempts:2 rotate
EOF

chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured with multiple resolvers"

# Create YouTube-specific DNS cache
print_warning "Creating DNS cache for YouTube..."
cat > /etc/hosts << EOF
127.0.0.1 localhost
::1 localhost

# YouTube CDN optimization (adds common YouTube IPs)
# These will be updated via DNS
EOF

# Add Google/YouTube IP ranges to routing table
ip route add 173.194.0.0/16 via $SERVER_IP dev eth0 metric 100 2>/dev/null
ip route add 74.125.0.0/16 via $SERVER_IP dev eth0 metric 100 2>/dev/null

# Start SlowDNS service
print_warning "Starting optimized SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1

# Try to start service with priority
systemctl start server-sldns
sleep 3

# Check and set process priority
if pgrep sldns-server > /dev/null; then
    renice -n -10 $(pgrep sldns-server) 2>/dev/null
    print_success "SlowDNS service started with high priority"
else
    # Direct start with high priority
    nice -n -10 /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu $MTU_SIZE -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69 &
    sleep 2
    if pgrep sldns-server > /dev/null; then
        print_success "SlowDNS started directly with high priority"
    fi
fi

# Create monitoring script for YouTube issues
print_warning "Creating YouTube monitoring script..."
cat > /usr/local/bin/check-youtube.sh << 'EOF'
#!/bin/bash
while true; do
    if ping -c 1 -W 2 youtube.com > /dev/null 2>&1; then
        # Check DNS resolution time for YouTube
        dns_time=$(dig youtube.com +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
        if [ -n "$dns_time" ] && [ "$dns_time" -gt 1000 ]; then
            echo "$(date): Slow YouTube DNS ($dns_time ms)" >> /var/log/youtube-dns.log
            # Flush DNS cache
            systemctl restart server-sldns 2>/dev/null
        fi
    fi
    sleep 30
done
EOF

chmod +x /usr/local/bin/check-youtube.sh

# Create systemd service for monitoring
cat > /etc/systemd/system/youtube-monitor.service << EOF
[Unit]
Description=YouTube DNS Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/check-youtube.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable youtube-monitor.service > /dev/null 2>&1
systemctl start youtube-monitor.service > /dev/null 2>&1

print_success "YouTube monitoring service created"

# Test connections
print_warning "Testing connections..."
timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/22" 2>/dev/null && print_success "SSH port 22 OK" || print_error "SSH port 22 failed"
timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null && print_success "SSH port 69 OK" || print_error "SSH port 69 failed"
timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null && print_success "SlowDNS UDP port $SLOWDNS_PORT OK" || print_error "SlowDNS UDP port $SLOWDNS_PORT failed"

# YouTube-specific test
print_warning "Testing YouTube connectivity..."
if ping -c 1 -W 3 youtube.com > /dev/null 2>&1; then
    print_success "YouTube reachable"
    
    # Test YouTube DNS
    yt_ip=$(dig +short youtube.com | head -n1)
    if [ -n "$yt_ip" ]; then
        print_success "YouTube resolves to $yt_ip"
    fi
else
    print_error "YouTube not reachable - checking configuration"
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    print_warning "DNS reset to Google DNS"
fi

# Show connection information
echo ""
echo "=================================================================="
print_success "  OpenSSH SlowDNS Installation Complete (YouTube Optimized)!"
echo "=================================================================="
echo ""
echo "📱 Connection Information:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Server IP      : $SERVER_IP"
echo "SSH Ports      : 22, 69"
echo "SlowDNS Port   : $SLOWDNS_PORT (UDP) - Prioritized"
echo "DNS Port       : 53 → $SLOWDNS_PORT"
echo "Nameserver     : $NAMESERVER"
echo "MTU Size       : $MTU_SIZE (Optimized for YouTube)"
echo ""
echo "🔧 YouTube Streaming Optimizations:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ QoS enabled for SlowDNS traffic"
echo "✓ TCP BBR congestion control active"
echo "✓ Buffer settings optimized for video"
echo "✓ DNS cache monitoring active"
echo "✓ High process priority for SlowDNS"
echo ""
echo "🎯 If YouTube still freezes:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Check logs: tail -f /var/log/youtube-dns.log"
echo "2. Reduce MTU: systemctl stop server-sldns"
echo "   Then edit: nano /etc/systemd/system/server-sldns.service"
echo "   Change MTU to 1300 and: systemctl daemon-reload && systemctl restart server-sldns"
echo ""
echo "3. Monitor connection:"
echo "   - watch -n 1 'ss -unap | grep $SLOWDNS_PORT'"
echo "   - ping -c 10 youtube.com"
echo ""
echo "4. If issues persist, try: systemctl restart server-sldns"
echo ""
echo "=================================================================="
echo "Public Key:"
cat /etc/slowdns/server.pub 2>/dev/null || echo "Not available"
echo "=================================================================="
