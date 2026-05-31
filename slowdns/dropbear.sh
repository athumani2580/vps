#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port Configuration
DROPBEAR_PORT=222
SLOWDNS_PORT=5300

# Create temporary directory
TEMP_DIR=$(mktemp -d)
TEMP_FILES=()

# Cleanup function for temporary files
cleanup_temp_files() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        print_success "Temporary files cleaned up"
    fi
}

# Function to register temp files
register_temp_file() {
    local file="$1"
    TEMP_FILES+=("$file")
}

# Function to clean all registered temp files
cleanup_registered_files() {
    for file in "${TEMP_FILES[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
        fi
    done
}

# Set trap for script exit
trap cleanup_temp_files EXIT
trap cleanup_registered_files INT TERM

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

# Auto-delete function for old logs
auto_delete_old_logs() {
    local log_dir="/var/log"
    local days_to_keep=7
    
    print_warning "Auto-deleting log files older than $days_to_keep days..."
    
    # Delete old fail2ban logs
    find "$log_dir" -name "fail2ban.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    find "$log_dir" -name "slowdns.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    
    # Delete old Dropbear logs
    find "$log_dir" -name "auth.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    find "$log_dir" -name "secure*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    find "$log_dir" -name "dropbear.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    
    # Rotate and compress old logs
    if [ -f "/var/log/slowdns.log" ]; then
        local log_size=$(stat -c%s "/var/log/slowdns.log" 2>/dev/null || stat -f%z "/var/log/slowdns.log" 2>/dev/null)
        if [ "$log_size" -gt 10485760 ]; then  # 10MB
            mv /var/log/slowdns.log "/var/log/slowdns.log.$(date +%Y%m%d_%H%M%S)"
            touch /var/log/slowdns.log
            chmod 644 /var/log/slowdns.log
            
            # Compress old logs older than 1 day
            find "$log_dir" -name "slowdns.log.*" -type f -mtime +1 -exec gzip {} \; 2>/dev/null
            
            # Delete compressed logs older than 30 days
            find "$log_dir" -name "slowdns.log.*.gz" -type f -mtime +30 -delete 2>/dev/null
        fi
    fi
    
    # Clean temporary files from /tmp
    find /tmp -name "*.tmp" -type f -mtime +1 -delete 2>/dev/null
    find /tmp -name "wget.*" -type f -mtime +1 -delete 2>/dev/null
    find /tmp -name "curl.*" -type f -mtime +1 -delete 2>/dev/null
    
    # Clean package manager cache
    if command -v apt-get &> /dev/null; then
        apt-get clean 2>/dev/null
        apt-get autoclean 2>/dev/null
    elif command -v yum &> /dev/null; then
        yum clean all 2>/dev/null
    fi
    
    print_success "Auto-deletion of old logs completed"
}

# Auto-delete function for downloaded installation files
auto_delete_install_files() {
    print_warning "Cleaning up temporary installation files..."
    
    # Delete downloaded files from slowdns directory that are older than 1 day
    find /etc/slowdns -name "*.tmp" -type f -mtime +1 -delete 2>/dev/null
    find /etc/slowdns -name "*.backup" -type f -mtime +7 -delete 2>/dev/null
    
    # Clean service backup files
    find /etc/systemd/system -name "*.backup" -type f -mtime +7 -delete 2>/dev/null
    
    # Clean fail2ban backup files
    find /etc/fail2ban -name "*.backup" -type f -mtime +7 -delete 2>/dev/null
    
    print_success "Installation files cleanup completed"
}

# Setup auto-delete cron job
setup_auto_delete_cron() {
    print_warning "Setting up auto-delete cron job..."
    
    # Create cron job for daily cleanup at 2 AM
    CRON_JOB="0 2 * * * /usr/bin/find /var/log -name '*.log.*' -type f -mtime +7 -delete 2>/dev/null && /usr/bin/find /tmp -type f -atime +1 -delete 2>/dev/null"
    
    # Add to crontab if not exists
    (crontab -l 2>/dev/null | grep -F "$CRON_JOB") || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
    # Create weekly cleanup script
    cat > /etc/cron.weekly/cleanup-temp-files << 'EOF'
#!/bin/bash
# Weekly cleanup script for temporary files

# Delete old logs
find /var/log -name "*.log.*" -type f -mtime +7 -delete
find /var/log -name "*.gz" -type f -mtime +30 -delete

# Clean temporary directories
rm -rf /tmp/* 2>/dev/null
rm -rf /var/tmp/* 2>/dev/null

# Clean package cache
apt-get clean 2>/dev/null || yum clean all 2>/dev/null

# Restart services to refresh logs
systemctl restart fail2ban 2>/dev/null
systemctl restart server-sldns 2>/dev/null

exit 0
EOF
    
    chmod +x /etc/cron.weekly/cleanup-temp-files
    print_success "Auto-delete cron job configured"
}

# Check root
check_root

echo "=================================================================="
echo "                 Dropbear SlowDNS Installation"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Install Dropbear
print_warning "Installing Dropbear SSH server..."
if command -v apt-get &> /dev/null; then
    apt-get update -qq
    apt-get install -y dropbear -qq
elif command -v yum &> /dev/null; then
    yum install -y dropbear -q
elif command -v dnf &> /dev/null; then
    dnf install -y dropbear -q
else
    print_error "Package manager not supported. Please install dropbear manually."
    exit 1
fi

# Configure Dropbear port
print_warning "Configuring Dropbear on port $DROPBEAR_PORT..."

# Stop existing dropbear service if running
systemctl stop dropbear 2>/dev/null
pkill dropbear 2>/dev/null

# Create custom dropbear configuration
cat > /etc/default/dropbear << EOF
# Dropbear configuration
NO_START=0
DROPBEAR_PORT=$DROPBEAR_PORT
DROPBEAR_EXTRA_ARGS="-R -W 1800"
DROPBEAR_BANNER="/etc/dropbear/banner"
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"
DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"
DROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

# Create banner file
mkdir -p /etc/dropbear
cat > /etc/dropbear/banner << 'EOF'
=======================================
    Welcome to Dropbear SSH Server
=======================================
EOF

# Generate host keys if not exists
if [ ! -f "/etc/dropbear/dropbear_rsa_host_key" ]; then
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048
fi

if [ ! -f "/etc/dropbear/dropbear_ecdsa_host_key" ]; then
    dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key -s 256
fi

# Create dropbear systemd service file
cat > /etc/systemd/system/dropbear.service << 'EOF'
[Unit]
Description=Dropbear SSH Server
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/default/dropbear
ExecStart=/usr/sbin/dropbear -F -E $DROPBEAR_EXTRA_ARGS -p ${DROPBEAR_PORT:-222}
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dropbear
systemctl start dropbear

sleep 2

if systemctl is-active --quiet dropbear; then
    print_success "Dropbear configured on port $DROPBEAR_PORT with TCP forwarding enabled"
else
    print_error "Dropbear failed to start. Trying alternative method..."
    dropbear -p $DROPBEAR_PORT -R -W 1800 -F -E &
    sleep 2
    if pgrep -x "dropbear" > /dev/null; then
        print_success "Dropbear started manually on port $DROPBEAR_PORT"
    else
        print_error "Failed to start Dropbear"
    fi
fi

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files with temp file handling
print_warning "Downloading SlowDNS files..."

# Download to temp directory first
TEMP_KEY="$TEMP_DIR/server.key"
TEMP_PUB="$TEMP_DIR/server.pub"
TEMP_BIN="$TEMP_DIR/sldns-server"

wget -q -O "$TEMP_KEY" "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
if [ $? -eq 0 ]; then
    cp "$TEMP_KEY" /etc/slowdns/server.key
    print_success "server.key downloaded"
    register_temp_file "$TEMP_KEY"
else
    print_error "Failed to download server.key"
fi

wget -q -O "$TEMP_PUB" "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
if [ $? -eq 0 ]; then
    cp "$TEMP_PUB" /etc/slowdns/server.pub
    print_success "server.pub downloaded"
    register_temp_file "$TEMP_PUB"
else
    print_error "Failed to download server.pub"
fi

wget -q -O "$TEMP_BIN" "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
if [ $? -eq 0 ]; then
    cp "$TEMP_BIN" /etc/slowdns/sldns-server
    print_success "sldns-server downloaded"
    register_temp_file "$TEMP_BIN"
else
    print_error "Failed to download sldns-server"
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Clean temp directory after download
cleanup_temp_files

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS service with MTU 1800 (pointing to Dropbear port 222)
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS for Dropbear
Documentation=https://man himself
After=network.target nss-lookup.target dropbear.service
Requires=dropbear.service

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Install and Configure Fail2ban
print_warning "Installing and configuring Fail2ban..."

# Install fail2ban
if command -v apt-get &> /dev/null; then
    apt-get update -qq
    apt-get install -y fail2ban -qq
elif command -v yum &> /dev/null; then
    yum install -y fail2ban -q
elif command -v dnf &> /dev/null; then
    dnf install -y fail2ban -q
else
    print_error "Package manager not supported. Please install fail2ban manually."
fi

# Create fail2ban local configuration for Dropbear
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport
ignoreip = 127.0.0.1/8

[dropbear]
enabled = true
port = $DROPBEAR_PORT
logpath = /var/log/auth.log
backend = %(sshd_backend)s
maxretry = 3
bantime = 3600
findtime = 600

[dropbear-ddos]
enabled = true
port = $DROPBEAR_PORT
logpath = /var/log/auth.log
backend = %(sshd_backend)s
maxretry = 5
bantime = 7200
findtime = 600

# Custom jail for slowdns attacks
[slowdns]
enabled = true
port = $SLOWDNS_PORT
protocol = udp
filter = slowdns
logpath = /var/log/slowdns.log
maxretry = 10
bantime = 3600
findtime = 600
EOF

# Create custom filter for slowdns
cat > /etc/fail2ban/filter.d/slowdns.conf << 'EOF'
[Definition]
failregex = ^.*Failed authentication from <HOST>.*$
            ^.*Invalid request from <HOST>.*$
            ^.*Connection attempt from <HOST>.*$
ignoreregex =
EOF

# Create log file for slowdns if it doesn't exist
touch /var/log/slowdns.log
chmod 644 /var/log/slowdns.log

# Configure slowdns to log to file with rotation
print_warning "Configuring SlowDNS logging..."
cat >> /etc/systemd/system/server-sldns.service << EOF

# Logging configuration
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

# Auto-restart on failure
Restart=always
RestartSec=10
EOF

# Restart fail2ban
systemctl restart fail2ban 2>/dev/null
systemctl enable fail2ban 2>/dev/null

# Check if fail2ban is running
if systemctl is-active --quiet fail2ban; then
    print_success "Fail2ban installed and configured successfully"
    
    # Display fail2ban status
    print_warning "Fail2ban jails status:"
    fail2ban-client status
else
    print_error "Fail2ban failed to start. Please check configuration."
fi

# Configure fail2ban for iptables persistence
print_warning "Configuring iptables persistence for fail2ban..."
if command -v apt-get &> /dev/null; then
    apt-get install -y iptables-persistent -qq
    netfilter-persistent save > /dev/null 2>&1
elif command -v yum &> /dev/null; then
    yum install -y iptables-services -q
    service iptables save > /dev/null 2>&1
fi

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/bash
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

# Start dropbear if not running
pkill dropbear 2>/dev/null
dropbear -p $DROPBEAR_PORT -R -W 1800 -F -E &

# Restore iptables rules for fail2ban
if command -v iptables-restore &> /dev/null; then
    iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true
fi

# Clean old temp files on boot
rm -rf /tmp/* 2>/dev/null
rm -rf /var/tmp/* 2>/dev/null

exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1
print_success "Startup configuration set"

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# Disable systemd-resolved and set custom DNS
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured with Google and Cloudflare DNS servers"

# Run auto-delete functions
auto_delete_old_logs
auto_delete_install_files
setup_auto_delete_cron

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill sldns-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1
systemctl start server-sldns

sleep 3

if systemctl is-active --quiet server-sldns; then
    print_success "SlowDNS service started"
    
    # Test SlowDNS
    print_warning "Testing SlowDNS functionality..."
    sleep 2
    
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_error "SlowDNS not responding on port $SLOWDNS_PORT"
        
        # Try direct start
        pkill sldns-server 2>/dev/null
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT &
        sleep 2
        
        if pgrep -x "sldns-server" > /dev/null; then
            print_success "SlowDNS started directly"
        else
            print_error "Failed to start SlowDNS"
        fi
    fi
else
    print_error "SlowDNS service failed to start"
fi

# Test Dropbear connection
print_warning "Testing Dropbear connection..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$DROPBEAR_PORT" 2>/dev/null; then
    print_success "Dropbear port $DROPBEAR_PORT is accessible"
else
    print_error "Dropbear port $DROPBEAR_PORT is not accessible"
fi

# Check if Dropbear is running
if pgrep -x "dropbear" > /dev/null; then
    print_success "Dropbear SSH server is running"
    dropbear_version=$(dropbear -V 2>&1 | head -1)
    echo "  Version: $dropbear_version"
    echo "  Port: $DROPBEAR_PORT"
else
    print_error "Dropbear is not running"
fi

# Display fail2ban status summary
echo ""
echo "=================================================================="
print_success "           Fail2ban Protection Summary"
echo "=================================================================="
echo ""
fail2ban-client status
echo ""

echo "=================================================================="
print_success "           Dropbear SlowDNS Installation Completed!"
echo "=================================================================="
echo ""
echo "📊 Installation Summary:"
echo "  - SSH Server: Dropbear"
echo "  - Dropbear Port: $DROPBEAR_PORT (TCP)"
echo "  - SlowDNS Port: $SLOWDNS_PORT (UDP)"
echo "  - Nameserver: $NAMESERVER"
echo "  - Server IP: $SERVER_IP"
echo ""
echo "🔐 Connection Info:"
echo "  - Direct SSH: ssh -p $DROPBEAR_PORT root@$SERVER_IP"
echo "  - Via SlowDNS: Use SlowDNS client with nameserver $NAMESERVER"
echo ""

echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

TEMP_UPDATE_SCRIPT="$TEMP_DIR/update4.sh"
bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/update4.sh")
if [ -f "$TEMP_UPDATE_SCRIPT" ]; then
    bash "$TEMP_UPDATE_SCRIPT"
    register_temp_file "$TEMP_UPDATE_SCRIPT"
else
    print_error "Failed to download update script"
fi

# Final cleanup
cleanup_temp_files
cleanup_registered_files

echo ""
print_success "Auto-delete system configured successfully!"
echo " - Old logs are deleted after 7 days"
echo " - Temporary files are cleaned daily at 2 AM"
echo " - Log rotation is enabled for slowdns logs"
echo " - Weekly complete cleanup scheduled"
echo ""
echo "=========================================="
print_success "Dropbear (Port $DROPBEAR_PORT) + SlowDNS installation complete!"
echo "=========================================="
