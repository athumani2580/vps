#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
SSHD_PORT=22
SLOWDNS_PORT=5300
MAX_ATTEMPTS=3
BAN_TIME=7200  # 2 hours
FIND_TIME=600  # 10 minutes

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# Best security implementation
implement_best_security() {
    print_warning "Implementing maximum security against brute force attacks..."
    
    # 1. Install security packages
    apt-get update -qq
    apt-get install -y fail2ban iptables-persistent ufw python3-pip > /dev/null 2>&1
    
    # 2. Configure UFW with strict rules
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 69/tcp comment 'SSH Alt'
    ufw allow 5300/udp comment 'SlowDNS'
    ufw --force enable
    
    # 3. Advanced fail2ban configuration with custom SlowDNS jail
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 7200
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8 ::1
backend = auto
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port = ssh,69
logpath = %(sshd_log)s
maxretry = 3
bantime = 7200
findtime = 300

[sshd-ddos]
enabled = true
port = ssh,69
logpath = %(sshd_log)s
maxretry = 5
findtime = 120
bantime = 86400

[slowdns]
enabled = true
filter = slowdns
logpath = /var/log/slowdns.log
maxretry = 3
bantime = 86400
findtime = 300
port = 5300
protocol = udp
EOF

    # 4. Create custom filter for SlowDNS
    cat > /etc/fail2ban/filter.d/slowdns.conf << 'EOF'
[Definition]
failregex = ^.*Failed authentication from <HOST>.*$
            ^.*Invalid request from <HOST>.*$
            ^.*Attack detected from <HOST>.*$
ignoreregex =
EOF

    # 5. Optimized SSH configuration
    cat > /etc/ssh/sshd_config.d/99-security.conf << 'EOF'
# Security Hardening
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30s
ClientAliveInterval 300
ClientAliveCountMax 2
MaxStartups 10:30:60
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
# Rate limiting
MaxSessions 3
MaxAuthTries 2
# Disable weak algorithms
Ciphers aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
EOF

    systemctl restart sshd

    # 6. Advanced iptables rate limiting
    iptables -F
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j LOG --log-prefix "SSH_BRUTE: "
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
    
    iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --set --name SSHALT
    iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSHALT -j LOG --log-prefix "SSHALT_BRUTE: "
    iptables -A INPUT -p tcp --dport 69 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSHALT -j DROP
    
    iptables -A INPUT -p udp --dport 5300 -m state --state NEW -m recent --set --name SLOWDNS
    iptables -A INPUT -p udp --dport 5300 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 --name SLOWDNS -j LOG --log-prefix "SLOWDNS_FLOOD: "
    iptables -A INPUT -p udp --dport 5300 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 --name SLOWDNS -j DROP
    
    # 7. SYN flood protection
    iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
    iptables -A INPUT -p tcp --syn -j LOG --log-prefix "SYN_FLOOD: "
    iptables -A INPUT -p tcp --syn -j DROP
    
    # 8. Port scan detection
    iptables -A INPUT -m state --state NEW -m recent --name SCAN --set
    iptables -A INPUT -m state --state NEW -m recent --name SCAN --update --seconds 60 --hitcount 10 -j LOG --log-prefix "PORT_SCAN: "
    iptables -A INPUT -m state --state NEW -m recent --name SCAN --update --seconds 60 --hitcount 10 -j DROP
    
    netfilter-persistent save
    
    # 9. Configure system limits
    cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
sshd soft nproc 1024
sshd hard nproc 2048
EOF

    # 10. Add kernel hardening
    cat >> /etc/sysctl.conf << 'EOF'
# Network security
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_timestamps = 0
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 5000
EOF

    sysctl -p > /dev/null 2>&1
    
    # 11. Setup logging monitoring
    cat > /etc/logrotate.d/security << 'EOF'
/var/log/auth.log
/var/log/slowdns.log
{
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root adm
    postrotate
        systemctl restart fail2ban > /dev/null 2>&1 || true
    endscript
}
EOF

    # 12. Create monitoring script
    cat > /usr/local/bin/monitor-attacks.sh << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/attack-monitor.log"
THRESHOLD=50

ATTACKS=$(grep -c "BRUTE\|FLOOD\|SCAN" /var/log/auth.log /var/log/kern.log 2>/dev/null | awk -F: '{sum+=$2} END {print sum}')
if [ "$ATTACKS" -gt "$THRESHOLD" ]; then
    echo "[$(date)] High attack volume detected: $ATTACKS attempts" >> $LOG_FILE
    # You can add email notification here
fi
EOF

    chmod +x /usr/local/bin/monitor-attacks.sh
    
    # 13. Add cron job for monitoring
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/monitor-attacks.sh") | crontab -
    
    # 14. Restart all services
    systemctl restart fail2ban
    systemctl restart ufw
    
    print_success "Maximum security implementation completed!"
}

# Call the function
implement_best_security
