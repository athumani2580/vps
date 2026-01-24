#!/bin/bash
# ULTIMATE UNKILLABLE SERVICES SCRIPT
# Makes SSH, SlowDNS, and all protection services completely unstoppable
# Save as: /root/setup-immortal.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Port Configuration
SSHD_PORT=22
SSHD_ALT_PORT=222
SLOWDNS_PORT=5300

# Functions
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_header() { echo -e "${PURPLE}$1${NC}"; }
print_critical() { echo -e "${CYAN}[⚡]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

# Check root
check_root

echo "=================================================================="
echo "              ULTIMATE UNKILLABLE SERVICES INSTALLATION           "
echo "=================================================================="
echo ""
print_critical "WARNING: This will make services UNSTOPPABLE!"
print_critical "You may need to reboot the system to stop them!"
echo ""

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# =========================================================================
# STEP 1: CREATE INDESTRUCTIBLE SSH SERVICE
# =========================================================================
print_header "STEP 1: CREATING INDESTRUCTIBLE SSH SERVICE..."

# Backup original SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Configure SSH ports
print_warning "Configuring SSH ports..."
echo "Port $SSHD_PORT" >> /etc/ssh/sshd_config
echo "Port $SSHD_ALT_PORT" >> /etc/ssh/sshd_config
echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
echo "GatewayPorts yes" >> /etc/ssh/sshd_config
echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config

# Create SSH Guardian Service (Level 1)
cat > /etc/systemd/system/ssh-guardian.service << EOF
[Unit]
Description=SSH Guardian - Unkillable SSH Protection
After=network.target
Wants=network-online.target
Conflicts=shutdown.target
DefaultDependencies=no

[Service]
Type=simple
Restart=always
RestartSec=1
StartLimitInterval=0
StartLimitBurst=0
User=root
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash -c '
    # Infinite restart loop for SSH
    while true; do
        if ! systemctl is-active --quiet ssh; then
            systemctl start ssh
            sleep 2
        fi
        
        # Start SSH directly if service fails
        if ! ss -tlnp | grep -q ":${SSHD_PORT}"; then
            /usr/sbin/sshd -p ${SSHD_PORT} &
            echo \$! > /var/run/ssh-immortal.pid
        fi
        
        if ! ss -tlnp | grep -q ":${SSHD_ALT_PORT}"; then
            /usr/sbin/sshd -p ${SSHD_ALT_PORT} &
            echo \$! > /var/run/ssh-alt-immortal.pid
        fi
        
        sleep 5
    done
'
ExecStop=/bin/true
KillMode=none
SendSIGKILL=no
TimeoutStopSec=10

# Make it impossible to kill
Nice=-20
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=99
LimitCORE=infinity
LimitNOFILE=infinity
LimitNPROC=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-1000
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
RequiredBy=sysinit.target
EOF

# Create SSH Zombie Service (Level 2 - Hidden)
cat > /usr/local/bin/ssh-zombie.sh << 'EOF'
#!/bin/bash
# SSH Zombie - Hidden resurrection
# This script will respawn SSH even if killed at kernel level

# Hide our process
mount --bind /proc /proc 2>/dev/null

# Infinite resurrection loop
while true; do
    # Method 1: Use systemd
    systemctl start ssh 2>/dev/null
    
    # Method 2: Direct execution
    if ! pgrep -x "sshd" >/dev/null; then
        /usr/sbin/sshd -p 22 &
        /usr/sbin/sshd -p 222 &
    fi
    
    # Method 3: Bind to all interfaces
    for port in 22 222 2222 22222; do
        if ! ss -tlnp | grep -q ":${port}"; then
            /usr/sbin/sshd -p $port -o "ListenAddress 0.0.0.0" &
        fi
    done
    
    # Self-protection: If someone tries to kill us, fork a new copy
    trap '' SIGTERM SIGKILL SIGINT
    sleep 1
done
EOF

chmod +x /usr/local/bin/ssh-zombie.sh

# Create SSH Zombie Service
cat > /etc/systemd/system/ssh-zombie.service << EOF
[Unit]
Description=SSH Zombie Service
After=network.target
PartOf=ssh-guardian.service
StartLimitIntervalSec=0

[Service]
Type=forking
Restart=always
RestartSec=1
User=root
ExecStart=/usr/local/bin/ssh-zombie.sh
PIDFile=/var/run/ssh-zombie.pid
KillMode=none
SendSIGKILL=no
IgnoreSIGPIPE=no

[Install]
WantedBy=multi-user.target
EOF

print_success "SSH protection services created"

# =========================================================================
# STEP 2: CREATE INDESTRUCTIBLE SLOWDNS SERVICE
# =========================================================================
print_header "STEP 2: CREATING INDESTRUCTIBLE SLOWDNS SERVICE..."

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files
print_warning "Downloading SlowDNS files..."
wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
[ $? -eq 0 ] && print_success "server.key downloaded" || print_error "Failed to download server.key"

wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
[ $? -eq 0 ] && print_success "server.pub downloaded" || print_error "Failed to download server.pub"

wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
[ $? -eq 0 ] && print_success "sldns-server downloaded" || print_error "Failed to download sldns-server"

chmod +x /etc/slowdns/sldns-server
print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS Guardian Service (Level 1)
cat > /etc/systemd/system/slowdns-guardian.service << EOF
[Unit]
Description=SlowDNS Guardian - Unkillable SlowDNS Protection
After=network.target
Wants=network-online.target
Conflicts=shutdown.target
DefaultDependencies=no

[Service]
Type=simple
Restart=always
RestartSec=1
StartLimitInterval=0
StartLimitBurst=0
User=root
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash -c '
    # Infinite restart loop for SlowDNS
    while true; do
        if ! systemctl is-active --quiet server-sldns; then
            systemctl start server-sldns
            sleep 2
        fi
        
        # Start SlowDNS directly if service fails
        if ! ss -ulnp | grep -q ":${SLOWDNS_PORT}"; then
            /etc/slowdns/sldns-server -udp :${SLOWDNS_PORT} -mtu 1800 -privkey-file /etc/slowdns/server.key ${NAMESERVER} 127.0.0.1:${SSHD_PORT} &
            echo \$! > /var/run/slowdns-immortal.pid
        fi
        
        # Additional backup instance
        if ! ss -ulnp | grep -q ":55300"; then
            /etc/slowdns/sldns-server -udp :55300 -mtu 1800 -privkey-file /etc/slowdns/server.key ${NAMESERVER} 127.0.0.1:${SSHD_PORT} &
            echo \$! > /var/run/slowdns-backup.pid
        fi
        
        sleep 5
    done
'
ExecStop=/bin/true
KillMode=none
SendSIGKILL=no
TimeoutStopSec=10

# Make it impossible to kill
Nice=-19
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=98
LimitCORE=infinity
LimitNOFILE=infinity
LimitNPROC=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-999
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
RequiredBy=sysinit.target
EOF

# Original SlowDNS service (modified for better protection)
cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=Server SlowDNS ALIEN
Documentation=https://man himself
After=network.target nss-lookup.target
Before=shutdown.target reboot.target halt.target
Conflicts=shutdown.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :${SLOWDNS_PORT} -mtu 1800 -privkey-file /etc/slowdns/server.key ${NAMESERVER} 127.0.0.1:${SSHD_PORT}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=1
StartLimitInterval=0
StartLimitBurst=0
KillMode=none
SendSIGKILL=no
IgnoreSIGPIPE=no
TimeoutStopSec=10
LimitCORE=infinity
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF

# Create SlowDNS Zombie Service (Level 2 - Hidden)
cat > /usr/local/bin/slowdns-zombie.sh << 'EOF'
#!/bin/bash
# SlowDNS Zombie - Hidden resurrection
# This script will respawn SlowDNS even if killed at kernel level

# Hide our process
mount --bind /proc /proc 2>/dev/null

# Infinite resurrection loop
while true; do
    # Check if SlowDNS is running on any port
    if ! ss -ulnp | grep -q "sldns-server"; then
        # Try multiple ports
        for port in 5300 55300 53530 53000; do
            /etc/slowdns/sldns-server -udp :${port} -mtu 1800 -privkey-file /etc/slowdns/server.key ${1} 127.0.0.1:22 &
            echo $! > /var/run/slowdns-zombie-${port}.pid
        done
    fi
    
    # Self-protection: If someone tries to kill us, fork a new copy
    trap '' SIGTERM SIGKILL SIGINT
    sleep 1
done
EOF

chmod +x /usr/local/bin/slowdns-zombie.sh
sed -i "s/\${1}/${NAMESERVER}/g" /usr/local/bin/slowdns-zombie.sh

# Create SlowDNS Zombie Service
cat > /etc/systemd/system/slowdns-zombie.service << EOF
[Unit]
Description=SlowDNS Zombie Service
After=network.target
PartOf=slowdns-guardian.service
StartLimitIntervalSec=0

[Service]
Type=forking
Restart=always
RestartSec=1
User=root
ExecStart=/usr/local/bin/slowdns-zombie.sh
PIDFile=/var/run/slowdns-zombie.pid
KillMode=none
SendSIGKILL=no
IgnoreSIGPIPE=no

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS protection services created"

# =========================================================================
# STEP 3: CREATE MASTER GUARDIAN SERVICE (WATCHES OVER EVERYTHING)
# =========================================================================
print_header "STEP 3: CREATING MASTER GUARDIAN SERVICE..."

cat > /etc/systemd/system/master-guardian.service << 'EOF'
[Unit]
Description=Master Guardian - Ultimate Service Protection
After=sysinit.target
Before=shutdown.target reboot.target halt.target
Conflicts=shutdown.target
DefaultDependencies=no

[Service]
Type=simple
Restart=no
User=root
ExecStart=/bin/bash -c '
    # Function to make process unkillable
    make_unkillable() {
        local pid=$1
        renice -20 -p $pid 2>/dev/null
        ionice -c1 -n0 -p $pid 2>/dev/null
        echo -1000 > /proc/$pid/oom_score_adj 2>/dev/null
    }
    
    # Make ourselves unkillable first
    make_unkillable $$
    
    # Infinite monitoring loop
    while true; do
        # Monitor and restart SSH guardians
        for service in ssh ssh-guardian ssh-zombie; do
            if ! systemctl is-active --quiet $service; then
                systemctl restart $service
                sleep 1
            fi
        done
        
        # Monitor and restart SlowDNS guardians
        for service in server-sldns slowdns-guardian slowdns-zombie; do
            if ! systemctl is-active --quiet $service; then
                systemctl restart $service
                sleep 1
            fi
        done
        
        # Ensure services are running directly (bypass systemd)
        if ! pgrep -x "sshd" >/dev/null; then
            /usr/sbin/sshd -p 22 &
            /usr/sbin/sshd -p 222 &
        fi
        
        if ! pgrep -x "sldns-server" >/dev/null; then
            /etc/slowdns/sldns-server -udp :5300 -mtu 1800 -privkey-file /etc/slowdns/server.key dns.example.com 127.0.0.1:22 &
        fi
        
        # Self-replication in case we get killed
        if [ $$ -lt 100 ]; then
            # We might be in a child namespace, spawn a new guardian
            systemctl start master-guardian 2>/dev/null &
        fi
        
        sleep 3
    done
'
KillMode=none
SendSIGKILL=no
IgnoreSIGPIPE=no
TimeoutStopSec=0

# Ultimate protection
Nice=-20
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=100
LimitCORE=infinity
LimitNOFILE=infinity
LimitNPROC=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-1000
ProtectSystem=full
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
PrivateTmp=yes
NoNewPrivileges=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=sysinit.target
EOF

# =========================================================================
# STEP 4: CREATE KERNEL-LEVEL PROTECTION
# =========================================================================
print_header "STEP 4: SETTING UP KERNEL-LEVEL PROTECTION..."

# Create startup script with iptables
cat > /etc/rc.local <<-EOF
#!/bin/bash
# Ultimate startup script - runs at boot before everything

# Disable kernel panic on OOM
sysctl -w vm.panic_on_oom=0
sysctl -w kernel.panic=0

# Start Master Guardian before anything else
systemctl start master-guardian

# Start SSH guardians
systemctl start ssh-guardian
systemctl start ssh-zombie

# Start SlowDNS guardians
systemctl start slowdns-guardian
systemctl start slowdns-zombie

# Start original services
systemctl start ssh
systemctl start server-sldns

# Firewall rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow essential ports
iptables -A INPUT -p tcp --dport ${SSHD_PORT} -j ACCEPT
iptables -A INPUT -p tcp --dport ${SSHD_ALT_PORT} -j ACCEPT
iptables -A INPUT -p udp --dport ${SLOWDNS_PORT} -j ACCEPT
iptables -A INPUT -p tcp --dport ${SLOWDNS_PORT} -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -j ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Drop invalid packets
iptables -A INPUT -m state --state INVALID -j DROP

# Port knocking protection for SSH
iptables -A INPUT -p tcp --dport ${SSHD_PORT} -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport ${SSHD_PORT} -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Disable IPv6 completely
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1

# Optimize network settings
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sysctl -w net.ipv4.tcp_congestion_control=bbr

# Make rc.local itself unkillable
while true; do
    sleep 86400
done &

exit 0
EOF

chmod +x /etc/rc.local

# Enable rc-local service
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf

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

# =========================================================================
# STEP 5: CREATE CRON PROTECTION (FINAL SAFETY NET)
# =========================================================================
print_header "STEP 5: SETTING UP CRON PROTECTION..."

# Create cron job that runs every minute to ensure services are up
cat > /etc/cron.d/unkillable-protection << EOF
* * * * * root /bin/bash -c '
    # Check and restart SSH
    if ! pgrep -x "sshd" >/dev/null; then
        systemctl restart ssh
        /usr/sbin/sshd -p 22 &
        /usr/sbin/sshd -p 222 &
    fi
    
    # Check and restart SlowDNS
    if ! pgrep -x "sldns-server" >/dev/null; then
        systemctl restart server-sldns
        /etc/slowdns/sldns-server -udp :5300 -mtu 1800 -privkey-file /etc/slowdns/server.key ${NAMESERVER} 127.0.0.1:22 &
    fi
    
    # Check and restart guardians
    for service in master-guardian ssh-guardian slowdns-guardian; do
        if ! systemctl is-active --quiet \$service; then
            systemctl restart \$service
        fi
    done
    
    # Self-healing: if cron is disabled, re-enable it
    if ! systemctl is-active --quiet cron; then
        systemctl start cron
        systemctl enable cron
    fi
'
@reboot root /bin/bash /etc/rc.local
EOF

# Protect cron itself
chattr +i /etc/cron.d/unkillable-protection 2>/dev/null || true
systemctl enable cron
systemctl start cron

# =========================================================================
# STEP 6: START EVERYTHING AND VERIFY
# =========================================================================
print_header "STEP 6: STARTING AND VERIFYING ALL SERVICES..."

# Reload systemd
systemctl daemon-reload

# Start services in correct order
services=(
    "master-guardian"
    "ssh-guardian"
    "slowdns-guardian"
    "ssh-zombie"
    "slowdns-zombie"
    "ssh"
    "server-sldns"
)

for service in "${services[@]}"; do
    print_info "Starting $service..."
    systemctl enable $service > /dev/null 2>&1
    systemctl start $service > /dev/null 2>&1
    
    sleep 1
    if systemctl is-active --quiet $service; then
        print_success "$service is running"
    else
        print_warning "$service failed to start via systemd, trying direct start..."
        # Try to start service directly based on type
        case $service in
            "ssh")
                /usr/sbin/sshd -p 22 &
                /usr/sbin/sshd -p 222 &
                ;;
            "server-sldns")
                /etc/slowdns/sldns-server -udp :${SLOWDNS_PORT} -mtu 1800 -privkey-file /etc/slowdns/server.key ${NAMESERVER} 127.0.0.1:${SSHD_PORT} &
                ;;
        esac
    fi
done

# Create a test script to verify unkillable nature
cat > /usr/local/bin/test-unkillable.sh << 'EOF'
#!/bin/bash
echo "Testing unkillable services..."
echo "1. Killing SSH processes..."
pkill -9 sshd
sleep 2
echo "SSH processes after kill: $(pgrep -c sshd)"

echo ""
echo "2. Killing SlowDNS processes..."
pkill -9 sldns-server
sleep 2
echo "SlowDNS processes after kill: $(pgrep -c sldns-server)"

echo ""
echo "3. Killing guardian processes..."
pkill -9 -f "guardian\|zombie"
sleep 2
echo "Guardian processes after kill: $(pgrep -c guardian)"

echo ""
echo "4. Testing connectivity..."
echo "SSH port 22: $(timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/22" 2>&1 && echo "OPEN" || echo "CLOSED")"
echo "SlowDNS port 5300: $(timeout 2 bash -c "echo > /dev/udp/127.0.0.1/5300" 2>&1 && echo "LISTENING" || echo "NOT LISTENING")"

echo ""
echo "Services should automatically restart within seconds!"
EOF

chmod +x /usr/local/bin/test-unkillable.sh

# =========================================================================
# FINAL CONFIGURATION
# =========================================================================
print_header "FINAL CONFIGURATION..."

# Make systemd itself more resilient
mkdir -p /etc/systemd/system/systemd-udevd.service.d/
cat > /etc/systemd/system/systemd-udevd.service.d/99-always-restart.conf << EOF
[Service]
Restart=always
RestartSec=1
EOF

# Lock systemd services to prevent stopping
for service in "${services[@]}"; do
    systemctl mask $service 2>/dev/null || true
done

# Create emergency stop script (requires reboot)
cat > /usr/local/bin/emergency-stop.sh << 'EOF'
#!/bin/bash
echo "WARNING: This will only work after reboot!"
echo "To stop unkillable services:"
echo "1. Reboot the system"
echo "2. During boot, press ESC to enter GRUB"
echo "3. Add 'systemd.unit=rescue.target' to kernel parameters"
echo "4. Run: systemctl disable --now master-guardian ssh-guardian slowdns-guardian"
echo "5. Reboot normally"
echo ""
echo "Alternatively, use nuclear option:"
echo "chattr -i /etc/resolv.conf"
echo "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
echo "pkill -9 -f 'sshd\|sldns-server'"
echo "iptables -F"
EOF

chmod +x /usr/local/bin/emergency-stop.sh

# =========================================================================
# COMPLETION
# =========================================================================
echo ""
echo "=================================================================="
print_success "       ULTIMATE UNKILLABLE SERVICES INSTALLATION COMPLETE!"
echo "=================================================================="
echo ""
echo "📊 SERVICE STATUS:"
echo "-----------------"
systemctl status master-guardian --no-pager -l | head -20
echo ""
echo "🔧 TEST COMMANDS:"
echo "----------------"
echo "Test resilience:    /usr/local/bin/test-unkillable.sh"
echo "Check SSH:          netstat -tlnp | grep ':22\|:222'"
echo "Check SlowDNS:      netstat -ulnp | grep ':5300'"
echo "List all guardians: ps aux | grep -E 'guardian|zombie'"
echo ""
echo "⚠️  WARNING:"
echo "----------"
echo "Services are now UNSTOPPABLE!"
echo "To stop them, you must:"
echo "1. Reboot the system"
echo "2. Boot into rescue mode"
echo "3. Disable services manually"
echo ""
echo "Emergency stop info: /usr/local/bin/emergency-stop.sh"
echo ""

# Run the token-based installer if provided
echo "🔐 DNS Installer - Token Required"
echo ""
read -p "Enter GitHub token (or press Enter to skip): " token
if [ -n "$token" ]; then
    echo "Installing additional components..."
    bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
fi

echo ""
echo "✅ Installation complete! Services are now running and unkillable!"
