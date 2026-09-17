#!/bin/bash
# install-slowdns.sh - SlowDNS Server with EDNS 512/1800
# Version: 1.1.0

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info()    { echo -e "${BLUE}[i]${NC} $1"; }
print_step()    { echo -e "${CYAN}[→]${NC} $1"; }

# ═══ CONFIG ═══
SLOWDNS_PORT="5301"
SSH_PORT="22"
INSTALL_DIR="/etc/slowdns"
MTU_SIZE="1800"

# ═══ Check root ═══
if [[ $EUID -ne 0 ]]; then
    print_error "Run as root: sudo bash $0"
    exit 1
fi

echo "=================================================================="
echo "         SlowDNS Server Installer (EDNS 512/1800)"
echo "=================================================================="

# ═══ 1. Create Directory ═══
print_step "Creating directory..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
print_status "Directory $INSTALL_DIR created"

# ═══ 2. Download Files ═══
print_step "Downloading SlowDNS files..."
cd "$INSTALL_DIR"

wget -q -O server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" \
    && print_status "server.key downloaded" \
    || { print_error "Failed to download server.key"; exit 1; }

wget -q -O server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" \
    && print_status "server.pub downloaded" \
    || { print_error "Failed to download server.pub"; exit 1; }

wget -q -O sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server" \
    && print_status "sldns-server downloaded" \
    || { print_error "Failed to download sldns-server"; exit 1; }

chmod +x sldns-server
print_status "Permissions set"

# ═══ 3. Get Nameserver ═══
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
if [ -z "$NAMESERVER" ]; then
    NAMESERVER="dns.example.com"
    print_warning "Using default: $NAMESERVER"
fi
echo ""

# ═══ 4. Create systemd Service ═══
# NOTE: sldns-server -mtu 1800 = EDNS internal size 1800
print_step "Creating systemd service..."

cat > /etc/systemd/system/server-sldns.service << EOF
[Unit]
Description=SlowDNS Server (EDNS 512/1800)
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${INSTALL_DIR}/sldns-server -udp :${SLOWDNS_PORT} -mtu ${MTU_SIZE} -privkey-file ${INSTALL_DIR}/server.key ${NAMESERVER} 127.0.0.1:${SSH_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

print_status "Service created (MTU ${MTU_SIZE})"

# ═══ 5. Firewall ═══
print_step "Configuring firewall..."

iptables -C INPUT -p udp --dport ${SLOWDNS_PORT} -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -p udp --dport ${SLOWDNS_PORT} -j ACCEPT
print_status "UDP ${SLOWDNS_PORT} allowed"

# ═══ 6. Start Service ═══
print_step "Starting SlowDNS service..."

systemctl daemon-reload
systemctl enable server-sldns > /dev/null 2>&1
systemctl restart server-sldns

sleep 3

if systemctl is-active --quiet server-sldns; then
    print_status "SlowDNS is running on UDP ${SLOWDNS_PORT}"
else
    print_error "SlowDNS failed to start"
    journalctl -u server-sldns -n 20 --no-pager
    exit 1
fi

# ═══ 7. Summary ═══
echo ""
echo "═══════════════════════════════════════════════════════"
print_status "SlowDNS Installation Complete"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  SlowDNS port:   UDP ${SLOWDNS_PORT}"
echo "  SSH port:       ${SSH_PORT}"
echo "  Nameserver:     ${NAMESERVER}"
echo "  MTU (internal): ${MTU_SIZE} bytes  ← EDNS internal"
echo "  EDNS external:  512 bytes          ← inawekwa na proxy"
echo ""
echo "  Commands:"
echo "    systemctl status server-sldns"
echo "    journalctl -u server-sldns -f"
echo ""
echo "  Public key:"
cat ${INSTALL_DIR}/server.pub
echo ""
echo "═══════════════════════════════════════════════════════"
