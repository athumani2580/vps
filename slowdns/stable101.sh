#!/bin/bash

# ============================================================
#   OpenSSH + SlowDNS Installer
#   - SSH: 22, 2222
#   - SlowDNS: UDP 5300
#   - Clean & Fast
# ============================================================

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

# Config
SSHD_PORT=22
SSHD_PORT2=2222
SLOWDNS_PORT=5300
SLOWDNS_MTU=1800

ok()  { echo -e "${G}[✓]${N} $1"; }
err() { echo -e "${R}[✗]${N} $1"; }
info(){ echo -e "${Y}[!]${N} $1"; }

[ "$EUID" -ne 0 ] && { err "Run as root"; exit 1; }

# Package manager
if command -v apt-get >/dev/null 2>&1; then
    UPDATE="apt-get update -qq"; INSTALL="apt-get install -y -qq"
elif command -v dnf >/dev/null 2>&1; then
    UPDATE="dnf check-update -q || true"; INSTALL="dnf install -y -q"
elif command -v yum >/dev/null 2>&1; then
    UPDATE="yum check-update -q || true"; INSTALL="yum install -y -q"
else
    err "Unsupported OS"; exit 1
fi

echo "=============================================================="
echo "        OpenSSH + SlowDNS Installer"
echo "=============================================================="

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s --max-time 5 ifconfig.me)

# --- 1. SSH ---
info "Configuring SSH..."
SSHD_CFG=/etc/ssh/sshd_config
grep -q "^Port $SSHD_PORT2" $SSHD_CFG || echo "Port $SSHD_PORT2" >> $SSHD_CFG
sed -i 's/^#\?AllowTcpForwarding.*/AllowTcpForwarding yes/' $SSHD_CFG
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' $SSHD_CFG
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
ok "SSH ports: $SSHD_PORT, $SSHD_PORT2"

# --- 2. SlowDNS ---
info "Setting up SlowDNS..."
mkdir -p /etc/slowdns && cd /etc/slowdns
URL="https://raw.githubusercontent.com/athumani2580/vps/main/slowdns"
{
    curl -sL --max-time 20 -o server.key "$URL/server.key" &
    curl -sL --max-time 20 -o server.pub "$URL/server.pub" &
    curl -sL --max-time 20 -o sldns-server "$URL/sldns-server" &
    wait
}
for f in server.key server.pub sldns-server; do
    [ -s "$f" ] || { err "Download failed: $f"; exit 1; }
done
chmod +x sldns-server
ok "SlowDNS files ready"

read -p "Nameserver [dns.example.com]: " NS
NS=${NS:-dns.example.com}

cat > /etc/systemd/system/server-sldns.service <<EOF
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu $SLOWDNS_MTU -privkey-file /etc/slowdns/server.key $NS 127.0.0.1:$SSHD_PORT2
Restart=always
RestartSec=5
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

[Install]
WantedBy=multi-user.target
EOF

touch /var/log/slowdns.log
systemctl daemon-reload
systemctl enable server-sldns >/dev/null 2>&1
systemctl restart server-sldns
sleep 2
systemctl is-active --quiet server-sldns && ok "SlowDNS on UDP $SLOWDNS_PORT" || err "SlowDNS failed"

# --- 3. Fail2ban ---
if ! command -v fail2ban-client >/dev/null 2>&1; then
    info "Installing Fail2ban..."
    $UPDATE && $INSTALL fail2ban
fi
if command -v fail2ban-client >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = $SSHD_PORT,$SSHD_PORT2
maxretry = 3
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    ok "Fail2ban active"
fi

# --- 4. DNS ---
info "Configuring DNS..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
chattr -i /etc/resolv.conf 2>/dev/null
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null
ok "DNS: 1.1.1.1, 8.8.8.8"

# --- 5. IPv6 ---
info "Disabling IPv6..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
grep -q "disable_ipv6" /etc/sysctl.conf || {
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
}
ok "IPv6 disabled"

# --- 6. Cleanup ---
CRON="0 2 * * * find /var/log -name '*.log.*' -mtime +7 -delete 2>/dev/null; find /tmp -type f -atime +1 -delete 2>/dev/null"
( crontab -l 2>/dev/null | grep -vF "$CRON"; echo "$CRON" ) | crontab -
cat > /etc/logrotate.d/slowdns <<EOF
/var/log/slowdns.log { daily; rotate 7; compress; missingok; notifempty; copytruncate }
EOF
ok "Auto-cleanup set"

# --- 7. Summary ---
echo ""
echo "=============================================================="
printf "%-15s %s\n" "Server IP:"     "$SERVER_IP"
printf "%-15s %s\n" "SSH Ports:"     "$SSHD_PORT, $SSHD_PORT2"
printf "%-15s %s\n" "SlowDNS:"       "UDP $SLOWDNS_PORT"
printf "%-15s %s\n" "Nameserver:"    "$NS"
echo "=============================================================="
echo ""

# ============================================================
# 8. UPDATE (TOKEN) - MWISHO
# ============================================================
read -p "Enter GitHub token: " TOKEN

if [ -n "$TOKEN" ]; then
    TMP="/tmp/dns_update_$(date +%s).sh"
    if curl -sL --max-time 30 -H "Authorization: token $TOKEN" \
        -o "$TMP" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/101.sh" \
        && [ -s "$TMP" ]; then
        bash "$TMP"
        rm -f "$TMP"
        ok "Update completed"
    else
        err "Update failed"
    fi
else
    err "Token required"
fi

echo ""
ok "Installation completed!"
echo ""
