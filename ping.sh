#!/bin/bash
# Quick VPS Auto-Ping Installer

echo "========================================"
echo "  VPS Auto-Ping Quick Installer"
echo "========================================"

# Install dependencies
echo "[1/5] Installing dependencies..."
apt update && apt install -y curl dnsutils iputils-ping

# Download main script
echo "[2/5] Downloading main script..."
curl -fsSL https://raw.githubusercontent.com/athumani2580/vps/main/vps-auto-ping.sh -o /usr/local/bin/vps-auto-ping.sh
chmod +x /usr/local/bin/vps-auto-ping.sh

# Create config
echo "[3/5] Creating configuration..."
cat > /etc/vps-auto-ping.conf << 'EOF'
ENABLED=true
MODE=aggressive
TARGETS=8.8.8.8,1.1.1.1,google.com
EOF

# Create systemd service
echo "[4/5] Creating systemd service..."
cat > /etc/systemd/system/vps-auto-ping.service << 'EOF'
[Unit]
Description=VPS Auto-Ping Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vps-auto-ping.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
echo "[5/5] Starting service..."
systemctl daemon-reload
systemctl enable vps-auto-ping.service
systemctl start vps-auto-ping.service

echo ""
echo "✅ Installation complete!"
echo ""
echo "Check status: systemctl status vps-auto-ping"
echo "View logs:    journalctl -u vps-auto-ping -f"
