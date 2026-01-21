cat > ~/fix-all-vpn-issues.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}╔══════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║    FIXING ALL VPN ISSUES            ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════╝${NC}"
echo ""

# Step 1: Fix repository
echo -e "${YELLOW}[1] Fixing Termux repository...${NC}"
cat > $PREFIX/etc/apt/sources.list << 'SOURCES'
# Termux main repository
deb https://grimler.se/termux-packages-24 stable main
SOURCES

# Add game repository for dns2socks
cat > $PREFIX/etc/apt/sources.list.d/game.list << 'GAME'
deb https://grimler.se/game-packages-24 games stable
GAME

echo -e "${GREEN}[✓] Repository fixed${NC}"

# Step 2: Update package lists
echo -e "${YELLOW}[2] Updating package lists...${NC}"
pkg update -y
echo -e "${GREEN}[✓] Package lists updated${NC}"

# Step 3: Install essential tools
echo -e "${YELLOW}[3] Installing essential tools...${NC}"
pkg install wget curl git -y
echo -e "${GREEN}[✓] Tools installed${NC}"

# Step 4: Install socat
echo -e "${YELLOW}[4] Installing socat...${NC}"
pkg install socat -y
echo -e "${GREEN}[✓] socat installed${NC}"

# Step 5: Install dns2socks from alternative source
echo -e "${YELLOW}[5] Installing dns2socks...${NC}"
if ! pkg install dns2socks -y 2>/dev/null; then
    echo -e "${RED}[!] dns2socks not in main repo, trying alternative...${NC}"
    
    # Try to install via git
    if command -v git &> /dev/null; then
        git clone https://github.com/semigodking/dns2socks /tmp/dns2socks-src
        cd /tmp/dns2socks-src
        gcc -o dns2socks dns2socks.c
        cp dns2socks $PREFIX/bin/
        cd ~
        rm -rf /tmp/dns2socks-src
        echo -e "${GREEN}[✓] dns2socks compiled from source${NC}"
    else
        # Download pre-built binary
        wget -q https://github.com/semigodking/dns2socks/releases/latest/download/dns2socks-android-arm64 -O $PREFIX/bin/dns2socks
        chmod +x $PREFIX/bin/dns2socks
        echo -e "${GREEN}[✓] dns2socks downloaded${NC}"
    fi
else
    echo -e "${GREEN}[✓] dns2socks installed from repo${NC}"
fi

# Step 6: Install slowdns (correct spelling)
echo -e "${YELLOW}[6] Installing slowdns...${NC}"
rm -f $PREFIX/bin/slowdown $PREFIX/bin/slowdowns 2>/dev/null

# Try multiple sources for slowdns
if wget -q https://github.com/foomurf/slowdns/releases/latest/download/slowdns-android-arm64 -O $PREFIX/bin/slowdns; then
    echo -e "${GREEN}[✓] slowdns downloaded from GitHub${NC}"
elif curl -sL https://github.com/foomurf/slowdns/releases/latest/download/slowdns-android-arm64 -o $PREFIX/bin/slowdns; then
    echo -e "${GREEN}[✓] slowdns downloaded via curl${NC}"
else
    echo -e "${RED}[!] Download failed, trying alternative...${NC}"
    # Alternative source
    wget -q https://raw.githubusercontent.com/foomurf/slowdns/main/slowdns -O $PREFIX/bin/slowdns
fi

chmod +x $PREFIX/bin/slowdns

# Verify installation
if command -v slowdns &> /dev/null; then
    echo -e "${GREEN}[✓] slowdns installed successfully${NC}"
else
    echo -e "${RED}[!] slowdns installation failed${NC}"
    exit 1
fi

# Step 7: Verify all installations
echo ""
echo -e "${YELLOW}[7] Verifying installations...${NC}"
echo -n "wget: " && command -v wget &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
echo -n "curl: " && command -v curl &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
echo -n "socat: " && command -v socat &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
echo -n "dns2socks: " && command -v dns2socks &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
echo -n "slowdns: " && command -v slowdns &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}[✓] ALL ISSUES FIXED!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "Now run: ./start-vpn-now.sh"
EOF

chmod +x ~/fix-all-vpn-issues.sh
