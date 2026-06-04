#!/bin/bash
# force-clean.sh - Force remove everything

sudo bash << 'EOF'
# Stop all services
systemctl stop customer-service 2>/dev/null
systemctl disable customer-service 2>/dev/null

# Kill all processes using port 53 or customer-service
pkill -9 -f customer-service 2>/dev/null
pkill -9 -f customer_service 2>/dev/null
pkill -9 -f dns-proxy 2>/dev/null
fuser -k 53/udp 2>/dev/null

# Remove all binaries
rm -f /usr/local/bin/customer-service
rm -f /usr/local/bin/customer_service
rm -f /usr/local/bin/customer-ctl
rm -f /opt/customer-service/customer_service

# Remove directories
rm -rf /opt/customer-service
rm -rf /etc/customer-service

# Remove systemd service
rm -f /etc/systemd/system/customer-service.service

# Reload systemd
systemctl daemon-reload

echo "Complete clean finished"
sleep 2

# Verify port 53 is free
if ss -uln | grep -q ':53 '; then
    echo "WARNING: Port 53 still in use by:"
    ss -ulnp | grep ':53'
else
    echo "Port 53 is free"
fi
EOF
