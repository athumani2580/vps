#!/bin/bash

# Fix and complete the EDNS Proxy installation

echo "=== FIXING EDNS PROXY INSTALLATION ==="

# 1. STOP systemd-resolved FIRST (it's using port 53)
echo "Stopping systemd-resolved to free port 53..."
systemctl stop systemd-resolved
systemctl disable systemd-resolved

# 2. Disable DNSStubListener to prevent systemd-resolved from using port 53
echo "Disabling DNSStubListener..."
sed -i 's/#DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
sed -i '/^DNSStubListener=.*/d' /etc/systemd/resolved.conf
echo "DNSStubListener=no" >> /etc/systemd/resolved.conf

# 3. Create a simple EDNS proxy script
cat > /tmp/simple-edns-proxy.py << 'EOF'
#!/usr/bin/env python3
"""Simple EDNS Proxy for MTU 512"""
import socket
import struct
import time
import sys

LISTEN_HOST = "127.0.0.1"  # Change to 127.0.0.1 instead of 0.0.0.0
LISTEN_PORT = 53
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 5300
CLIENT_MTU = 512
SERVER_MTU = 1800

def patch_edns_size(data, new_size):
    """Simple EDNS size patcher"""
    if len(data) < 12:
        return data
    
    try:
        qdcount, ancount, nscount, arcount = struct.unpack("!HHHH", data[4:12])
    except:
        return data
    
    offset = 12
    
    # Skip questions
    for _ in range(qdcount):
        while offset < len(data) and data[offset] != 0:
            if data[offset] & 0xC0 == 0xC0:
                offset += 2
                break
            offset += 1 + data[offset]
        offset += 4
    
    # Skip answers and authority
    for _ in range(ancount + nscount):
        while offset < len(data) and data[offset] != 0:
            if data[offset] & 0xC0 == 0xC0:
                offset += 2
                break
            offset += 1 + data[offset]
        if offset + 10 > len(data):
            return data
        rdlen = struct.unpack("!H", data[offset+8:offset+10])[0]
        offset += 10 + rdlen
    
    # Find and patch OPT record
    for _ in range(arcount):
        if offset < len(data) and data[offset] == 0:
            if offset + 4 <= len(data):
                rtype = struct.unpack("!H", data[offset+1:offset+3])[0]
                if rtype == 41:
                    new_data = bytearray(data)
                    struct.pack_into("!H", new_data, offset+3, new_size)
                    return bytes(new_data)
        # Skip this RR
        while offset < len(data) and data[offset] != 0:
            if data[offset] & 0xC0 == 0xC0:
                offset += 2
                break
            offset += 1 + data[offset]
        if offset + 10 > len(data):
            return data
        rdlen = struct.unpack("!H", data[offset+8:offset+10])[0]
        offset += 10 + rdlen
    
    return data

def main():
    print(f"Starting EDNS Proxy on {LISTEN_HOST}:{LISTEN_PORT}")
    print(f"Upstream: {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    print(f"Client MTU: {CLIENT_MTU}, Server MTU: {SERVER_MTU}")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((LISTEN_HOST, LISTEN_PORT))
    sock.settimeout(5.0)
    
    print(f"Successfully bound to port {LISTEN_PORT}")
    
    while True:
        try:
            data, addr = sock.recvfrom(4096)
            print(f"Received query from {addr[0]}:{addr[1]}, size: {len(data)}")
            
            # Patch for upstream
            upstream_data = patch_edns_size(data, SERVER_MTU)
            
            # Send to upstream
            upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            upstream_sock.settimeout(3.0)
            upstream_sock.sendto(upstream_data, (UPSTREAM_HOST, UPSTREAM_PORT))
            
            # Get response
            response, _ = upstream_sock.recvfrom(4096)
            upstream_sock.close()
            
            # Patch for client
            client_response = patch_edns_size(response, CLIENT_MTU)
            
            # Send to client
            sock.sendto(client_response, addr)
            print(f"Sent response to {addr[0]}:{addr[1]}, size: {len(client_response)}")
            
        except socket.timeout:
            continue
        except Exception as e:
            print(f"Error: {e}")
            continue

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nShutting down...")
        sys.exit(0)
EOF

# Make it executable
chmod +x /tmp/simple-edns-proxy.py

# 4. Kill any process using port 53
echo "Killing processes using port 53..."
fuser -k 53/udp 2>/dev/null || true
fuser -k 53/tcp 2>/dev/null || true

# 5. Create systemd service
cat > /etc/systemd/system/edns-proxy.service << 'EOF'
[Unit]
Description=Simple EDNS Proxy for MTU 512
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /tmp/simple-edns-proxy.py
Restart=always
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 6. Apply sysctl optimizations
cat > /etc/sysctl.d/99-mtu512.conf << 'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=131072
net.core.wmem_default=131072
net.ipv4.udp_mem=4096 87380 16777216
net.ipv4.udp_rmem_min=4096
net.ipv4.udp_wmem_min=4096
net.core.netdev_max_backlog=100000
net.core.somaxconn=65535
EOF

sysctl -p /etc/sysctl.d/99-mtu512.conf 2>/dev/null || true

# 7. Setup TCP MSS clamping
echo "Setting up iptables rules..."
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 492 2>/dev/null || true

# 8. Reload systemd and start
systemctl daemon-reload
systemctl enable edns-proxy
systemctl restart edns-proxy

# 9. Wait and check status
sleep 5
echo ""
echo "=== CHECKING STATUS ==="
systemctl status edns-proxy --no-pager

echo ""
echo "=== CHECKING PORT 53 ==="
ss -tulpn | grep :53 || echo "No process listening on port 53"

echo ""
echo "=== TESTING DNS ==="
if command -v dig &> /dev/null; then
    echo "Testing DNS query..."
    timeout 5 dig @127.0.0.1 google.com +short +time=3 +tries=2
    if [ $? -eq 0 ]; then
        echo "✓ DNS working"
    else
        echo "✗ DNS failed"
        echo "Checking logs..."
        journalctl -u edns-proxy -n 20 --no-pager
    fi
else
    echo "dig not installed, installing dnsutils..."
    apt-get update && apt-get install -y dnsutils
    timeout 5 dig @127.0.0.1 google.com +short +time=3 +tries=2
fi

echo ""
echo "=== FIXING RESOLV.CONF ==="
# Update resolv.conf to use local proxy
echo "nameserver 127.0.0.1" > /etc/resolv.conf
echo "options edns0" >> /etc/resolv.conf

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "EDNS Proxy should be running on port 53"
echo "Client MTU: 512, Server MTU: 1800"
echo "Check status: systemctl status edns-proxy"
echo "Test: dig @127.0.0.1 google.com"
echo "View logs: journalctl -u edns-proxy -f"
