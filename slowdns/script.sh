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
RESTART_CHECK_INTERVAL=60  # Check every 60 seconds

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

check_service_status() {
    local service_name=$1
    if systemctl is-active --quiet "$service_name"; then
        return 0
    else
        return 1
    fi
}

restart_service() {
    local service_name=$1
    print_warning "Restarting $service_name..."
    systemctl restart "$service_name"
    sleep 3
    if check_service_status "$service_name"; then
        print_success "$service_name restarted successfully"
        return 0
    else
        print_error "Failed to restart $service_name"
        return 1
    fi
}

setup_auto_restart_service() {
    print_warning "Setting up auto-restart monitoring service..."
    
    # Create monitoring script
    cat > /usr/local/bin/monitor-services.sh << 'EOF'
#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/service-monitor.log
}

check_and_restart() {
    local service=$1
    local port=$2
    local service_name=$3
    
    if ! systemctl is-active --quiet "$service"; then
        log_message "Service $service_name is DOWN, attempting restart..."
        systemctl restart "$service"
        sleep 5
        
        if systemctl is-active --quiet "$service"; then
            log_message "Service $service_name restarted successfully"
            # Test port connectivity
            if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
                log_message "Port $port for $service_name is now accessible"
            fi
        else
            log_message "FAILED to restart $service_name, trying direct start..."
            
            # For SlowDNS, try direct start
            if [ "$service" = "server-sldns.service" ]; then
                pkill sldns-server 2>/dev/null
                /etc/slowdns/sldns-server -udp :5300 -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:22 &
                sleep 3
                if pgrep -x "sldns-server" > /dev/null; then
                    log_message "SlowDNS started directly"
                else
                    log_message "CRITICAL: SlowDNS completely DOWN"
                fi
            fi
        fi
    fi
}

# Load environment if exists
if [ -f /etc/slowdns/env ]; then
    source /etc/slowdns/env
fi

# Main monitoring loop
while true; do
    # Check SSH service
    check_and_restart "sshd" "22" "SSH"
    
    # Check SlowDNS service if NAMESERVER is set
    if [ -n "$NAMESERVER" ]; then
        check_and_restart "server-sldns.service" "5300" "SlowDNS"
    fi
    
    # Check if monitoring script itself is still running
    if ! pgrep -f "monitor-services.sh" | grep -v $$ | grep -v grep > /dev/null; then
        log_message "Monitoring script not running, starting new instance..."
        nohup /usr/local/bin/monitor-services.sh > /dev/null 2>&1 &
    fi
    
    sleep 60
done
EOF

    chmod +x /usr/local/bin/monitor-services.sh
    
    # Create systemd service for monitoring
    cat > /etc/systemd/system/service-monitor.service << EOF
[Unit]
Description=Service Monitor for SSH and SlowDNS
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
ExecStart=/usr/local/bin/monitor-services.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=service-monitor

# Security
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
    
    # Create environment file for SlowDNS
    if [ -n "$NAMESERVER" ]; then
        echo "NAMESERVER=$NAMESERVER" > /etc/slowdns/env
    fi
    
    systemctl daemon-reload
    systemctl enable service-monitor.service > /dev/null 2>&1
    systemctl start service-monitor.service
    
    if systemctl is-active --quiet service-monitor.service; then
        print_success "Auto-restart monitoring service installed and running"
        
        # Create log rotation
        cat > /etc/logrotate.d/service-monitor << EOF
/var/log/service-monitor.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF
        
        print_success "Log rotation configured for monitoring service"
    else
        print_error "Failed to start monitoring service"
    fi
}

setup_cron_job() {
    print_warning "Setting up cron job for service monitoring..."
    
    # Create health check script
    cat > /usr/local/bin/health-check.sh << 'EOF'
#!/bin/bash

# Health check script
LOGFILE="/var/log/health-check.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

check_port() {
    local port=$1
    local service=$2
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        echo "$TIMESTAMP - $service port $port: OK" >> $LOGFILE
        return 0
    else
        echo "$TIMESTAMP - $service port $port: FAILED" >> $LOGFILE
        return 1
    fi
}

# Check SSH
if ! check_port 22 "SSH"; then
    systemctl restart sshd
    echo "$TIMESTAMP - Restarted SSH service" >> $LOGFILE
fi

# Check SlowDNS if configured
if [ -f /etc/slowdns/server.key ] && [ -f /etc/slowdns/env ]; then
    source /etc/slowdns/env
    if [ -n "$NAMESERVER" ]; then
        if ! check_port 5300 "SlowDNS"; then
            systemctl restart server-sldns
            echo "$TIMESTAMP - Restarted SlowDNS service" >> $LOGFILE
        fi
    fi
fi

# Keep log file manageable
tail -n 1000 $LOGFILE > /tmp/health-check.tmp && mv /tmp/health-check.tmp $LOGFILE
EOF

    chmod +x /usr/local/bin/health-check.sh
    
    # Add to crontab - run every 5 minutes
    (crontab -l 2>/dev/null | grep -v "/usr/local/bin/health-check.sh"; echo "*/5 * * * * /usr/local/bin/health-check.sh > /dev/null 2>&1") | crontab -
    
    print_success "Cron job installed (runs every 5 minutes)"
}

# Check root
check_root

echo "=================================================================="
echo "                 OpenSSH SlowDNS Installation"
echo "           with Auto-Restart Functionality"
echo "=================================================================="

# ... [Previous installation code remains the same until after SlowDNS setup] ...

# After SlowDNS service setup, add auto-restart functionality
print_info "Installing auto-restart functionality..."

# Setup auto-restart monitoring service
setup_auto_restart_service

# Setup cron job as backup
setup_cron_job

# Create status check command
cat > /usr/local/bin/check-services << 'EOF'
#!/bin/bash

echo "========================================"
echo "        Service Status Check"
echo "========================================"

echo -e "\n📡 SSH Service:"
if systemctl is-active --quiet sshd; then
    echo -e "   Status: \033[0;32mACTIVE\033[0m"
else
    echo -e "   Status: \033[0;31mINACTIVE\033[0m"
fi

if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/22" 2>/dev/null; then
    echo -e "   Port 22: \033[0;32mACCESSIBLE\033[0m"
else
    echo -e "   Port 22: \033[0;31mBLOCKED\033[0m"
fi

echo -e "\n🌐 SlowDNS Service:"
if systemctl is-active --quiet server-sldns.service; then
    echo -e "   Status: \033[0;32mACTIVE\033[0m"
else
    echo -e "   Status: \033[0;31mINACTIVE\033[0m"
fi

if timeout 2 bash -c "echo > /dev/udp/127.0.0.1/5300" 2>/dev/null; then
    echo -e "   Port 5300: \033[0;32mACCESSIBLE\033[0m"
else
    echo -e "   Port 5300: \033[0;31mBLOCKED\033[0m"
fi

echo -e "\n🔍 Monitoring Service:"
if systemctl is-active --quiet service-monitor.service; then
    echo -e "   Status: \033[0;32mACTIVE\033[0m"
else
    echo -e "   Status: \033[0;31mINACTIVE\033[0m"
fi

echo -e "\n📊 Recent Logs:"
tail -n 10 /var/log/service-monitor.log 2>/dev/null || echo "   No logs found"
echo "========================================"
EOF

chmod +x /usr/local/bin/check-services

# Create restart all command
cat > /usr/local/bin/restart-all << 'EOF'
#!/bin/bash

echo "Restarting all services..."
systemctl restart sshd
systemctl restart server-sldns.service
systemctl restart service-monitor.service
echo "Services restarted. Checking status..."
sleep 3
check-services
EOF

chmod +x /usr/local/bin/restart-all

print_success "Utility commands installed:"
print_info "  check-services  - Check service status"
print_info "  restart-all     - Restart all services"

echo ""
echo "=================================================================="
print_success "    Installation Complete with Auto-Restart Feature!"
echo "=================================================================="

echo ""
print_info "Services will automatically restart if they stop"
print_info "Monitoring logs: /var/log/service-monitor.log"
print_info "Health check logs: /var/log/health-check.log"
echo ""

# Display final status
echo "📊 Current Service Status:"
/usr/local/bin/check-services

echo ""
echo "🔐 DNS Installer - Token Required"
echo ""
read -p "Enter GitHub token: " token

echo "Installing DNS configuration..."
bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
