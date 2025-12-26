#!/bin/bash
# Direct install with token prompt - copy and paste this entire block

echo "╔══════════════════════════════════════════╗"
echo "║   Private Repository Installer           ║"
echo "║   athumani2580/DNS/slowdns/install.sh    ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "NOTE: GitHub token required for private repo access"
echo "Get token from: https://github.com/settings/tokens"
echo "(Select 'repo' scope for private repositories)"
echo ""
read -sp "Enter GitHub Token: " TOKEN
echo ""
echo ""
[ -z "$TOKEN" ] && echo "Error: Token required!" && exit 1
echo "Downloading installer..."
TEMP_FILE="/tmp/install_$(date +%s).sh"
curl -s -H "Authorization: token $TOKEN" \
     -H "Accept: application/vnd.github.v3.raw" \
     -o "$TEMP_FILE" \
     "https://api.github.com/repos/athumani2580/DNS/contents/slowdns/install.sh" || \
curl -s -H "Authorization: token $TOKEN" \
     -o "$TEMP_FILE" \
     "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/install.sh"
if [ ! -s "$TEMP_FILE" ] || grep -q '"message"' "$TEMP_FILE" 2>/dev/null; then
    echo "ERROR: Download failed! Check your token."
    [ -s "$TEMP_FILE" ] && cat "$TEMP_FILE"
    rm -f "$TEMP_FILE"
    exit 1
fi
chmod +x "$TEMP_FILE"
echo "Executing installer..."
echo "══════════════════════════════════════════"
bash "$TEMP_FILE"
echo "══════════════════════════════════════════"
rm -f "$TEMP_FILE"
