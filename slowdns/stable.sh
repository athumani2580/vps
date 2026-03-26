#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_step() { echo -e "${CYAN}[→]${NC} $1"; }

# Check root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

# ============================================
# SECURE SSH CONFIGURATION
# ============================================
configure_ssh() {
    print_step "Configuring secure SSH settings..."
    
    # Backup existing SSH config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    print_success "SSH config backed up"
    
    # Create secure SSH configuration
    cat > /etc/ssh/sshd_config.d/99-security.conf << 'EOF'
# ============================================
# SSH Security Hardening
# ============================================

# Authentication Limits
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
MaxStartups 10:30:100

# Connection Settings
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive yes

# Security Options
PermitRootLogin prohibit-password
StrictModes yes
PubkeyAuthentication yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no

# Session Settings
X11Forwarding no
PrintMotd no
PrintLastLog yes
PermitUserEnvironment no

# Encryption Algorithms (Strong only)
Ciphers aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Disable empty passwords
PermitEmptyPasswords no

# Compression
Compression delayed
EOF

    # Make sure port 69 is enabled (if you want it)
    if ! grep -q "^Port 69" /etc/ssh/sshd_config; then
        echo "Port 69" >> /etc/ssh/sshd_config
        print_success "Added SSH port 69"
    fi
    
    # Test SSH configuration
    if sshd -t; then
        systemctl restart sshd
        print_success "SSH security configuration applied"
    else
        print_error "SSH configuration test failed! Restoring backup..."
        cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config 2>/dev/null
        systemctl restart sshd
        exit 1
    fi
}

# ============================================
# FAIL2BAN CONFIGURATION
# ============================================
configure_fail2ban() {
    print_step "Configuring fail2ban..."
    
    # Install fail2ban if not present
    if ! command -v fail2ban-server &> /dev/null; then
        print_warning "Installing fail2ban..."
        apt-get update -qq
        apt-get install -y fail2ban > /dev/null 2>&1
    fi
    
    # Backup existing configuration
    if [ -f /etc/fail2ban/jail.local ]; then
        cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Create comprehensive fail2ban configuration
    cat > /etc/fail2ban/jail.local << 'EOF'
# ============================================
# Fail2Ban Configuration
# ============================================

[DEFAULT]
# Ban time: 2 hours
bantime = 7200
# Find time: 10 minutes
findtime = 600
# Max retries before ban
maxretry = 3
# Ignore local IPs
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
# Backend
backend = auto
# Ban action
banaction = iptables-multiport
banaction_allports = iptables-allports

# ============================================
# SSH JAILS
# ============================================

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

# Recidive jail for persistent offenders
[sshd-recidive]
enabled = true
logpath = %(sshd_log)s
filter = recidive
maxretry = 5
findtime = 86400
bantime = 604800
action = iptables-allports[name=recidive]

# ============================================
# SLOWDNS JAIL (if you have SlowDNS)
# ============================================

[slowdns]
enabled = true
filter = slowdns
logpath = /var/log/slowdns.log
maxretry = 3
bantime = 86400
findtime = 300
port = 5300
protocol = udp
action = iptables-multiport[name=slowdns, port="5300", protocol=udp]
EOF

    # Create SlowDNS filter
    cat > /etc/fail2ban/filter.d/slowdns.conf << 'EOF'
[Definition]
failregex = ^.*Failed authentication from <HOST>.*$
            ^.*Invalid request from <HOST>.*$
            ^.*Attack detected from <HOST>.*$
            ^.*Unauthorized access from <HOST>.*$
            ^.*Connection flood from <HOST>.*$
ignoreregex =

[Init]
maxretry = 3
findtime = 300
EOF

    # Create recidive filter
    cat > /etc/fail2ban/filter.d/recidive.conf << 'EOF'
[Definition]
failregex = ^.*Ban <HOST>.*$
ignoreregex =
EOF

    # Restart fail2ban
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    print_success "Fail2ban configured with SSH and SlowDNS protection"
}

# ============================================
# SHOW SUMMARY
# ============================================
show_summary() {
    echo ""
    echo "=========================================="
    print_success "Security Configuration Complete!"
    echo "=========================================="
    echo ""
    echo "✅ Installed Components:"
    echo "   ✓ Secure SSH configuration (MaxAuthTries=3)"
    echo "   ✓ Fail2ban with multiple jails"
    echo "   ✓ Custom SlowDNS protection"
    echo "   ✓ Recidive jail for persistent offenders"
    echo ""
    echo "📋 Useful Commands:"
    echo "   fail2ban-client status          - Check all jails"
    echo "   fail2ban-client status sshd     - Check SSH bans"
    echo "   fail2ban-client status slowdns  - Check SlowDNS bans"
    echo "   tail -f /var/log/fail2ban.log   - Monitor bans in real-time"
    echo "   tail -f /var/log/auth.log       - Monitor SSH logs"
    echo ""
    echo "🔧 Configuration Files:"
    echo "   SSH: /etc/ssh/sshd_config.d/99-security.conf"
    echo "   Fail2ban: /etc/fail2ban/jail.local"
    echo "   SlowDNS Filter: /etc/fail2ban/filter.d/slowdns.conf"
    echo ""
    echo "⚠️  Notes:"
    echo "   • SSH backup saved in /etc/ssh/sshd_config.backup.*"
    echo "   • Test SSH config: sshd -t"
    echo "   • Review fail2ban logs: journalctl -u fail2ban -f"
    echo ""
    
    # Show current status
    print_info "Current Status:"
    systemctl is-active --quiet sshd && print_success "✓ SSH running" || print_error "✗ SSH not running"
    systemctl is-active --quiet fail2ban && print_success "✓ Fail2ban running" || print_error "✗ Fail2ban not running"
    
    echo ""
    print_success "Your server is now protected against brute force attacks!"
    echo "=========================================="
}

# ============================================
# MAIN EXECUTION
# ============================================

main() {
    echo "=========================================="
    echo "  SSH & Fail2ban Security Installer"
    echo "=========================================="
    echo ""
    
    check_root
    
    # Run configurations
    configure_ssh
    configure_fail2ban
    
    # Show summary
    show_summary
}

# Run main
main

echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/update4.sh")
