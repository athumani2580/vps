#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# SSH Port Configuration
SSHD_PORT=22
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

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
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
    
    # Delete old SSH logs
    find "$log_dir" -name "auth.log*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    find "$log_dir" -name "secure*" -type f -mtime +$days_to_keep -delete 2>/dev/null
    
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

# Auto-generate keys if downloads fail or for new setup
generate_slowdns_keys() {
    print_warning "Generating new SlowDNS keys..."
    
    # Check if we have the sldns-server binary
    if [ ! -f "/etc/slowdns/sldns-server" ]; then
        print_error "sldns-server binary not found. Cannot generate keys."
        return 1
    fi
    
    cd /etc/slowdns
    
    # Try to generate keys using the binary
    if ./sldns-server -genkey -privkey-file server.key -pubkey-file server.pub 2>/dev/null; then
        chmod 600 server.key
        chmod 644 server.pub
        print_success "New keys generated successfully"
        return 0
    else
        # Alternative: Generate using openssl if binary method fails
        if command -v openssl &> /dev/null; then
            print_info "Using OpenSSL to generate keys..."
            openssl genrsa -out server.key 2048 2>/dev/null
            openssl rsa -in server.key -pubout -out server.pub 2>/dev/null
            chmod 600 server.key
            chmod 644 server.pub
            print_success "Keys generated with OpenSSL"
            return 0
        else
            print_error "Failed to generate keys"
            return 1
        fi
    fi
}

# Function to extract and display fingerprint
generate_and_display_fingerprint() {
    print_info "Generating server fingerprint..."
    
    if [ ! -f "/etc/slowdns/server.pub" ]; then
        print_error "Public key file not found"
        return 1
    fi
    
    local fingerprint=""
    local fingerprint_sha256=""
    local fingerprint_md5=""
    
    # Method 1: Using openssl (most reliable)
    if command -v openssl &> /dev/null; then
        fingerprint=$(openssl rsa -pubin -in /etc/slowdns/server.pub -outform DER 2>/dev/null | openssl dgst -sha256 -hex | awk '{print $2}' 2>/dev/null)
        fingerprint_sha256=$(echo "$fingerprint" | cut -c1-32)
        fingerprint_md5=$(openssl rsa -pubin -in /etc/slowdns/server.pub -outform DER 2>/dev/null | openssl dgst -md5 -hex | awk '{print $2}' 2>/dev/null | cut -c1-16)
    fi
    
    # Method 2: Using sha256sum directly on the pub key (fallback)
    if [ -z "$fingerprint_sha256" ] && command -v sha256sum &> /dev/null; then
        fingerprint_sha256=$(sha256sum /etc/slowdns/server.pub | awk '{print $1}' | cut -c1-32)
    fi
    
    # Method 3: Using shasum (macOS fallback)
    if [ -z "$fingerprint_sha256" ] && command -v shasum &> /dev/null; then
        fingerprint_sha256=$(shasum -a 256 /etc/slowdns/server.pub | awk '{print $1}' | cut -c1-32)
    fi
    
    if [ -n "$fingerprint_sha256" ]; then
        # Save fingerprints to files
        echo "$fingerprint_sha256" > /etc/slowdns/fingerprint_sha256.txt
        echo "$fingerprint_md5" > /etc/slowdns/fingerprint_md5.txt
        
        print_success "Fingerprint generated successfully"
        
        # Display fingerprint information
        echo ""
        echo "=================================================================="
        echo -e "${GREEN}🔑 SLOWDNS CONNECTION INFORMATION${NC}"
        echo "=================================================================="
        echo ""
        echo -e "${YELLOW}📌 SERVER DETAILS:${NC}"
        echo "   • Server IP: $SERVER_IP"
        echo "   • Nameserver: $NAMESERVER"
        echo "   • SSH Port: 69"
        echo "   • SlowDNS Port: $SLOWDNS_PORT"
        echo "   • MTU: 1800"
        echo ""
        echo -e "${YELLOW}🔐 PUBLIC KEY:${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        cat /etc/slowdns/server.pub
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo -e "${YELLOW}🆔 FINGERPRINTS:${NC}"
        echo "   • SHA256: $fingerprint_sha256"
        [ -n "$fingerprint_md5" ] && echo "   • MD5: $fingerprint_md5"
        echo ""
        
        return 0
    else
        print_error "Could not generate fingerprint"
        return 1
    fi
}

# Create management script for key operations
create_management_script() {
    cat > /usr/local/bin/slowdns-manage << 'EOF'
#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_info() {
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}           SLOWDNS SERVER INFORMATION${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ -f /etc/slowdns/server.pub ]; then
        echo -e "${YELLOW}📄 Public Key:${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        cat /etc/slowdns/server.pub
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    fi
    
    if [ -f /etc/slowdns/fingerprint_sha256.txt ]; then
        echo -e "${YELLOW}🆔 SHA256 Fingerprint:${NC} $(cat /etc/slowdns/fingerprint_sha256.txt)"
    fi
    
    if [ -f /etc/slowdns/fingerprint_md5.txt ]; then
        echo -e "${YELLOW}🆔 MD5 Fingerprint:${NC} $(cat /etc/slowdns/fingerprint_md5.txt)"
    fi
    
    if [ -f /etc/slowdns/server-ip.txt ]; then
        echo -e "${YELLOW}🌐 Server IP:${NC} $(cat /etc/slowdns/server-ip.txt)"
    fi
    
    if [ -f /etc/slowdns/nameserver.txt ]; then
        echo -e "${YELLOW}📡 Nameserver:${NC} $(cat /etc/slowdns/nameserver.txt)"
    fi
    
    echo ""
    echo -e "${YELLOW}📊 Service Status:${NC}"
    systemctl status server-sldns --no-pager -l | grep -E "Active:|Main PID:" | sed 's/^/   /'
    echo ""
}

regenerate_keys() {
    echo -e "${YELLOW}⚠️  Regenerating SlowDNS keys...${NC}"
    echo -e "${YELLOW}This will invalidate existing client connections.${NC}"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Cancelled${NC}"
        return 1
    fi
    
    cd /etc/slowdns
    
    # Backup old keys
    mkdir -p backup/old-$(date +%Y%m%d_%H%M%S)
    cp server.key backup/old-$(date +%Y%m%d_%H%M%S)/ 2>/dev/null
    cp server.pub backup/old-$(date +%Y%m%d_%H%M%S)/ 2>/dev/null
    
    # Generate new keys
    if ./sldns-server -genkey -privkey-file server.key -pubkey-file server.pub 2>/dev/null; then
        chmod 600 server.key
        chmod 644 server.pub
        echo -e "${GREEN}✓ Keys regenerated successfully${NC}"
        
        # Regenerate fingerprints
        if command -v openssl &> /dev/null; then
            fingerprint_sha256=$(openssl rsa -pubin -in server.pub -outform DER 2>/dev/null | openssl dgst -sha256 -hex | awk '{print $2}' | cut -c1-32)
            fingerprint_md5=$(openssl rsa -pubin -in server.pub -outform DER 2>/dev/null | openssl dgst -md5 -hex | awk '{print $2}' | cut -c1-16)
            echo "$fingerprint_sha256" > fingerprint_sha256.txt
            echo "$fingerprint_md5" > fingerprint_md5.txt
            echo -e "${GREEN}✓ New SHA256 fingerprint: $fingerprint_sha256${NC}"
        fi
        
        # Restart service
        systemctl restart server-sldns
        echo -e "${GREEN}✓ Service restarted${NC}"
    else
        echo -e "${RED}✗ Failed to regenerate keys${NC}"
        return 1
    fi
}

backup_keys() {
    backup_dir="/etc/slowdns/backup/backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    cp /etc/slowdns/server.key "$backup_dir/" 2>/dev/null
    cp /etc/slowdns/server.pub "$backup_dir/" 2>/dev/null
    cp /etc/slowdns/fingerprint_*.txt "$backup_dir/" 2>/dev/null
    cp /etc/slowdns/server-ip.txt "$backup_dir/" 2>/dev/null
    cp /etc/slowdns/nameserver.txt "$backup_dir/" 2>/dev/null
    
    echo -e "${GREEN}✓ Backup created at $backup_dir${NC}"
}

case "$1" in
    show|status)
        show_info
        ;;
    regenerate)
        regenerate_keys
        ;;
    backup)
        backup_keys
        ;;
    restart)
        systemctl restart server-sldns
        echo -e "${GREEN}✓ SlowDNS service restarted${NC}"
        ;;
    *)
        echo "SlowDNS Management Script"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Usage: $0 {show|regenerate|backup|restart}"
        echo ""
        echo "  show       - Display current keys, fingerprints and status"
        echo "  regenerate - Generate new key pair (breaks existing connections)"
        echo "  backup     - Backup current keys and configuration"
        echo "  restart    - Restart SlowDNS service"
        echo ""
        echo "Example:"
        echo "  $0 show        # View current configuration"
        echo "  $0 regenerate  # Generate new keys"
        echo "  $0 backup      # Create backup"
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/slowdns-manage
    print_success "Management script created: slowdns-manage"
}

# Check root
check_root

echo "=================================================================="
echo -e "${GREEN}                 OpenSSH SlowDNS Installation${NC}"
echo "=================================================================="
echo ""

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Configure SSH ports
print_warning "Configuring SSH ports..."

# Backup original sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d)

# Check if ports already exist
if ! grep -q "^Port 22" /etc/ssh/sshd_config; then
    echo "Port 22" >> /etc/ssh/sshd_config
fi

if ! grep -q "^Port 69" /etc/ssh/sshd_config; then
    echo "Port 69" >> /etc/ssh/sshd_config
fi

sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config

systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
sleep 2
print_success "SSH configured on ports 22 and 69 with TCP forwarding enabled"

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

wget -q --timeout=10 --tries=2 -O "$TEMP_KEY" "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
if [ $? -eq 0 ] && [ -s "$TEMP_KEY" ]; then
    cp "$TEMP_KEY" /etc/slowdns/server.key
    print_success "server.key downloaded"
    register_temp_file "$TEMP_KEY"
else
    print_warning "Failed to download server.key, will generate new one"
fi

wget -q --timeout=10 --tries=2 -O "$TEMP_PUB" "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
if [ $? -eq 0 ] && [ -s "$TEMP_PUB" ]; then
    cp "$TEMP_PUB" /etc/slowdns/server.pub
    print_success "server.pub downloaded"
    register_temp_file "$TEMP_PUB"
else
    print_warning "Failed to download server.pub, will generate new one"
fi

wget -q --timeout=10 --tries=2 -O "$TEMP_BIN" "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
if [ $? -eq 0 ] && [ -s "$TEMP_BIN" ]; then
    cp "$TEMP_BIN" /etc/slowdns/sldns-server
    print_success "sldns-server downloaded"
    register_temp_file "$TEMP_BIN"
else
    print_error "Failed to download sldns-server binary"
    exit 1
fi

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Generate keys if needed
print_info "Checking SlowDNS keys..."

if [ ! -f "/etc/slowdns/server.key" ] || [ ! -f "/etc/slowdns/server.pub" ] || \
   [ ! -s "/etc/slowdns/server.key" ] || [ ! -s "/etc/slowdns/server.pub" ]; then
    print_warning "Keys missing or empty. Generating new keys..."
    generate_slowdns_keys
else
    # Validate existing keys
    if head -n 1 /etc/slowdns/server.key | grep -q "BEGIN"; then
        print_success "Valid keys found"
    else
        print_warning "Invalid keys found. Regenerating..."
        generate_slowdns_keys
    fi
fi

# Clean temp directory after download
cleanup_temp_files

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Save server info
echo "$SERVER_IP" > /etc/slowdns/server-ip.txt
echo "$NAMESERVER" > /etc/slowdns/nameserver.txt

# Create SlowDNS service with MTU 1800
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS Service
Documentation=https://github.com/ambrop72/badvpn
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69
Restart=always
RestartSec=5
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

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

# Create fail2ban local configuration
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ssh,22,69
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 3600
findtime = 600

[sshd-ddos]
enabled = true
port = ssh,22,69
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime = 7200
findtime = 600

# Custom jail for slowdns attacks
[slowdns]
enabled = true
port = 5300
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

# Restart fail2ban
systemctl restart fail2ban 2>/dev/null
systemctl enable fail2ban 2>/dev/null

# Check if fail2ban is running
if systemctl is-active --quiet fail2ban; then
    print_success "Fail2ban installed and configured successfully"
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

# Generate fingerprint and display info
generate_and_display_fingerprint

# Create management script
create_management_script

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
    print_info "Testing SlowDNS functionality..."
    sleep 2
    
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_error "SlowDNS not responding on port $SLOWDNS_PORT"
        
        # Try direct start
        pkill sldns-server 2>/dev/null
        /etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:69 &
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

# Test SSH connection
print_info "Testing SSH connection on port 69..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/69" 2>/dev/null; then
    print_success "SSH port 69 is accessible"
else
    print_warning "SSH port 69 is not accessible (might be blocked by firewall)"
fi

# Display fail2ban status summary
echo ""
echo "=================================================================="
print_success "           Fail2ban Protection Summary"
echo "=================================================================="
echo ""
fail2ban-client status
echo ""

# Final installation summary
echo "=================================================================="
print_success "           OpenSSH SlowDNS Installation Completed!"
echo "=================================================================="
echo ""

# Display connection information again at the end
if [ -f "/etc/slowdns/fingerprint_sha256.txt" ]; then
    FINGERPRINT_SHA256=$(cat /etc/slowdns/fingerprint_sha256.txt)
    echo -e "${GREEN}✅ SLOWDNS IS READY!${NC}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}              CONNECTION INFORMATION${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}📋 Connection Details:${NC}"
    echo "   • Server IP: $SERVER_IP"
    echo "   • Nameserver: $NAMESERVER"
    echo "   • SSH Port: 69"
    echo "   • SlowDNS Port: $SLOWDNS_PORT"
    echo "   • MTU: 1800"
    echo "   • Fingerprint (SHA256): $FINGERPRINT_SHA256"
    echo ""
    echo -e "${YELLOW}🔑 Key Files Location:${NC}"
    echo "   • Public key: /etc/slowdns/server.pub"
    echo "   • Private key: /etc/slowdns/server.key"
    echo "   • Fingerprint: /etc/slowdns/fingerprint_sha256.txt"
    echo ""
    echo -e "${YELLOW}📝 Management Commands:${NC}"
    echo "   • Show info:     slowdns-manage show"
    echo "   • Regenerate:    slowdns-manage regenerate"
    echo "   • Backup:        slowdns-manage backup"
    echo "   • Restart:       slowdns-manage restart"
    echo ""
    echo -e "${YELLOW}📊 Service Status:${NC}"
    echo "   • Check status:  systemctl status server-sldns"
    echo "   • View logs:     tail -f /var/log/slowdns.log"
    echo "   • Restart:       systemctl restart server-sldns"
    echo ""
else
    print_error "Could not generate fingerprint information"
fi

# GitHub token section
echo ""
echo "=================================================================="
print_info "           DNS Installer - Token Required"
echo "=================================================================="
echo ""

read -p "Enter GitHub token: " token

echo "Installing update script..."

TEMP_UPDATE_SCRIPT="$TEMP_DIR/update4.sh"
wget -q --timeout=10 --tries=2 -O "$TEMP_UPDATE_SCRIPT" -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/update4.sh"

if [ -f "$TEMP_UPDATE_SCRIPT" ] && [ -s "$TEMP_UPDATE_SCRIPT" ]; then
    bash "$TEMP_UPDATE_SCRIPT"
    register_temp_file "$TEMP_UPDATE_SCRIPT"
    print_success "Update script executed successfully"
else
    print_error "Failed to download update script"
fi

# Final cleanup
cleanup_temp_files
cleanup_registered_files

echo ""
echo "=================================================================="
print_success "           AUTO-DELETE SYSTEM CONFIGURED"
echo "=================================================================="
echo ""
echo "✅ Configuration Summary:"
echo "   • Old logs are deleted after 7 days"
echo "   • Temporary files are cleaned daily at 2 AM"
echo "   • Log rotation is enabled for slowdns logs"
echo "   • Weekly complete cleanup scheduled"
echo "   • Keys and fingerprints auto-generated"
echo ""
echo -e "${GREEN}Installation completed successfully!${NC}"
echo ""
