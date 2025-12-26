#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
EXTERNAL_EDNS_SIZE=512
INTERNAL_EDNS_SIZE=1800
EDNS_PROXY_PORT=53
SLOWDNS_PORT=5300

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

# Check root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

# Check if SlowDNS is running
check_slowdns() {
    print_warning "Checking if SlowDNS is running on port $SLOWDNS_PORT..."
    if ss -ulpn | grep -q ":$SLOWDNS_PORT"; then
        print_success "SlowDNS found running on port $SLOWDNS_PORT"
        return 0
    else
        print_error "SlowDNS not found on port $SLOWDNS_PORT"
        echo ""
        echo -e "${YELLOW}Note: This EDNS Proxy requires SlowDNS to be running first.${NC}"
        echo -e "${YELLOW}Please install and start SlowDNS before running this script.${NC}"
        echo ""
        exit 1
    fi
}

# SAFE: Stop DNS services and completely free port 53
safe_stop_dns() {
    print_warning "Stopping and disabling systemd-resolved..."
    
    # First disable and stop systemd-resolved completely
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    
    # Disable DNSStubListener permanently
    mkdir -p /etc/systemd/resolved.conf.d/
    cat > /etc/systemd/resolved.conf.d/99-disable-dnsstub.conf << EOF
[Resolve]
DNSStubListener=no
EOF
    
    # Kill ANY process on port 53 (both UDP and TCP)
    print_warning "Freeing port 53..."
    fuser -k 53/udp 2>/dev/null || true
    fuser -k 53/tcp 2>/dev/null || true
    sleep 2
    
    # Double-check port is free
    if ss -tulpn | grep -q ":53 "; then
        print_error "Port 53 is still occupied!"
        ss -tulpn | grep ":53 "
        print_warning "Force killing processes on port 53..."
        lsof -ti:53 | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
    
    print_success "Port 53 is now free"
}

# Check prerequisites
check_root
check_slowdns

# Install Python3 if not present
print_warning "Checking for Python3..."
if ! command -v python3 &> /dev/null; then
    print_warning "Python3 not found, installing..."
    apt-get update > /dev/null 2>&1
    apt-get install -y python3 > /dev/null 2>&1
    print_success "Python3 installed"
else
    print_success "Python3 already installed"
fi

# Ensure necessary Python packages are installed
print_warning "Checking Python dependencies..."
apt-get install -y python3-pip python3-dev > /dev/null 2>&1
pip3 install --upgrade pip > /dev/null 2>&1

# Create EDNS Proxy Python script with epoll
print_warning "Creating EDNS Proxy Python script with epoll..."
cat > /usr/local/bin/edns-proxy.py << 'EOF'
#!/usr/bin/env python3
import socket
import select
import struct
import errno
import time
import sys
import os

# Configuration
LISTEN_HOST = "127.0.0.1"  # Only listen locally for security
LISTEN_PORT = 53
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 5300
EXTERNAL_EDNS_SIZE = 512
INTERNAL_EDNS_SIZE = 1800
BUFFER_SIZE = 4096
MAX_EVENTS = 1000
SOCKET_TIMEOUT = 1.0

class DNSRequest:
    def __init__(self, client_addr, data, timestamp):
        self.client_addr = client_addr
        self.data = data
        self.timestamp = timestamp

class DNSCache:
    def __init__(self, max_size=1000, ttl=30):
        self.cache = {}
        self.max_size = max_size
        self.ttl = ttl
    
    def get(self, key):
        if key in self.cache:
            entry = self.cache[key]
            if time.time() - entry['timestamp'] < self.ttl:
                return entry['data']
            else:
                del self.cache[key]
        return None
    
    def set(self, key, data):
        if len(self.cache) >= self.max_size:
            # Remove oldest entry
            oldest_key = min(self.cache.keys(), key=lambda k: self.cache[k]['timestamp'])
            del self.cache[oldest_key]
        self.cache[key] = {
            'data': data,
            'timestamp': time.time()
        }

class EDNSProxy:
    def __init__(self):
        # Create server socket
        self.server_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        
        # Try to bind to port
        try:
            self.server_sock.bind((LISTEN_HOST, LISTEN_PORT))
        except OSError as e:
            print(f"FATAL ERROR: Cannot bind to {LISTEN_HOST}:{LISTEN_PORT}")
            print(f"Error: {e}")
            print("Make sure no other service is using port 53")
            sys.exit(1)
        
        self.server_sock.setblocking(False)
        
        # Setup epoll
        self.epoll = select.epoll()
        self.epoll.register(self.server_sock.fileno(), select.EPOLLIN)
        
        self.upstream_sockets = {}
        self.pending_requests = {}
        self.cache = DNSCache()
        
        print(f"EDNS Proxy started successfully on {LISTEN_HOST}:{LISTEN_PORT}")
        print(f"Upstream: {UPSTREAM_HOST}:{UPSTREAM_PORT}")
        print(f"External EDNS: {EXTERNAL_EDNS_SIZE}, Internal EDNS: {INTERNAL_EDNS_SIZE}")
        print(f"Process ID: {os.getpid()}")
    
    def patch_edns_udp_size(self, data: bytes, new_size: int) -> bytes:
        if len(data) < 12:
            return data
        
        try:
            qdcount, ancount, nscount, arcount = struct.unpack("!HHHH", data[4:12])
        except struct.error:
            return data
        
        offset = 12
        
        def skip_name(buf, off):
            while True:
                if off >= len(buf):
                    return len(buf)
                l = buf[off]
                off += 1
                if l == 0:
                    break
                if l & 0xC0 == 0xC0:
                    if off >= len(buf):
                        return len(buf)
                    off += 1
                    break
                off += l
            return off
        
        # Skip questions
        for _ in range(qdcount):
            offset = skip_name(data, offset)
            if offset + 4 > len(data):
                return data
            offset += 4
        
        def skip_rrs(count, buf, off):
            for _ in range(count):
                off = skip_name(buf, off)
                if off + 10 > len(buf):
                    return len(buf)
                rtype, rclass, ttl, rdlen = struct.unpack("!HHIH", buf[off:off+10])
                off += 10
                if off + rdlen > len(buf):
                    return len(buf)
                off += rdlen
            return off
        
        # Skip answers and authority sections
        offset = skip_rrs(ancount, data, offset)
        offset = skip_rrs(nscount, data, offset)
        
        # Look for OPT record in additional section
        new_data = bytearray(data)
        for _ in range(arcount):
            rr_name_start = offset
            offset = skip_name(data, offset)
            if offset + 10 > len(data):
                return data
            rtype = struct.unpack("!H", data[offset:offset+2])[0]
            if rtype == 41:  # OPT record
                size_bytes = struct.pack("!H", new_size)
                new_data[offset+2:offset+4] = size_bytes
                return bytes(new_data)
            _, _, rdlen = struct.unpack("!H I H", data[offset+2:offset+10])
            offset += 10 + rdlen
        
        return data
    
    def create_upstream_socket(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setblocking(False)
        return sock
    
    def handle_client_request(self):
        try:
            data, client_addr = self.server_sock.recvfrom(BUFFER_SIZE)
            if not data:
                return
            
            # Log request
            # print(f"Request from {client_addr}, size: {len(data)}")
            
            # Try cache first
            cache_key = hash((client_addr, data))
            cached_response = self.cache.get(cache_key)
            if cached_response:
                self.server_sock.sendto(cached_response, client_addr)
                return
            
            # Create upstream socket for this request
            upstream_sock = self.create_upstream_socket()
            fileno = upstream_sock.fileno()
            
            # Patch EDNS size and send upstream
            patched_data = self.patch_edns_udp_size(data, INTERNAL_EDNS_SIZE)
            upstream_sock.sendto(patched_data, (UPSTREAM_HOST, UPSTREAM_PORT))
            
            # Register for response
            self.epoll.register(fileno, select.EPOLLIN)
            self.upstream_sockets[fileno] = upstream_sock
            self.pending_requests[fileno] = DNSRequest(client_addr, data, time.time())
            
        except socket.error as e:
            if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                print(f"Server socket error: {e}")
    
    def handle_upstream_response(self, fileno):
        if fileno not in self.upstream_sockets:
            return
        
        upstream_sock = self.upstream_sockets[fileno]
        request = self.pending_requests.get(fileno)
        
        if not request:
            self.cleanup_socket(fileno)
            return
        
        try:
            data, _ = upstream_sock.recvfrom(BUFFER_SIZE)
            
            # Patch response EDNS size
            patched_response = self.patch_edns_udp_size(data, EXTERNAL_EDNS_SIZE)
            
            # Send to client
            self.server_sock.sendto(patched_response, request.client_addr)
            
            # Cache the response
            cache_key = hash((request.client_addr, request.data))
            self.cache.set(cache_key, patched_response)
            
            # Cleanup
            self.cleanup_socket(fileno)
            
        except socket.error as e:
            if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                print(f"Upstream socket error: {e}")
                self.cleanup_socket(fileno)
    
    def cleanup_socket(self, fileno):
        if fileno in self.upstream_sockets:
            try:
                self.epoll.unregister(fileno)
                self.upstream_sockets[fileno].close()
            except:
                pass
            del self.upstream_sockets[fileno]
        
        if fileno in self.pending_requests:
            del self.pending_requests[fileno]
    
    def cleanup_timeout_requests(self):
        current_time = time.time()
        timeout_fds = []
        
        for fileno, request in list(self.pending_requests.items()):
            if current_time - request.timestamp > 10.0:  # 10 second timeout
                timeout_fds.append(fileno)
        
        for fileno in timeout_fds:
            self.cleanup_socket(fileno)
    
    def run(self):
        last_cleanup = time.time()
        print("EDNS Proxy is now running...")
        
        try:
            while True:
                events = self.epoll.poll(timeout=SOCKET_TIMEOUT)
                
                for fileno, event in events:
                    if fileno == self.server_sock.fileno():
                        if event & select.EPOLLIN:
                            self.handle_client_request()
                    else:
                        if event & select.EPOLLIN:
                            self.handle_upstream_response(fileno)
                        if event & select.EPOLLHUP or event & select.EPOLLERR:
                            self.cleanup_socket(fileno)
                
                # Periodic cleanup
                if time.time() - last_cleanup > 5.0:
                    self.cleanup_timeout_requests()
                    last_cleanup = time.time()
                    
        except KeyboardInterrupt:
            print("\nShutting down EDNS Proxy...")
        except Exception as e:
            print(f"Unexpected error: {e}")
        finally:
            self.shutdown()
    
    def shutdown(self):
        print("Cleaning up resources...")
        try:
            self.epoll.unregister(self.server_sock.fileno())
        except:
            pass
        
        self.server_sock.close()
        
        for fileno in list(self.upstream_sockets.keys()):
            self.cleanup_socket(fileno)
        
        try:
            self.epoll.close()
        except:
            pass
        
        print("EDNS Proxy stopped")

def main():
    print("Starting EDNS Proxy with epoll...")
    proxy = EDNSProxy()
    proxy.run()

if __name__ == "__main__":
    main()
EOF

chmod +x /usr/local/bin/edns-proxy.py
print_success "EDNS Proxy Python script with epoll created"

# Create systemd service for EDNS Proxy
print_warning "Creating EDNS Proxy service..."
cat > /etc/systemd/system/edns-proxy.service << EOF
[Unit]
Description=EDNS Proxy with epoll for MTU optimization
After=network.target
Wants=network-online.target
Conflicts=systemd-resolved.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/edns-proxy.py
Restart=always
RestartSec=3
User=root
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

# Security enhancements
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/run /tmp
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

print_success "EDNS Proxy service created"

# Update systemd resolved config to disable DNSStubListener
print_warning "Configuring systemd-resolved to not use port 53..."
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/99-disable-dnsstub.conf << EOF
[Resolve]
DNSStubListener=no
EOF

# SAFELY stop DNS services and free port 53
safe_stop_dns

# Start EDNS Proxy service
print_warning "Starting EDNS Proxy service..."
systemctl daemon-reload
systemctl enable edns-proxy.service > /dev/null 2>&1

# Ensure port is free before starting
sleep 2
fuser -k 53/udp 2>/dev/null || true
fuser -k 53/tcp 2>/dev/null || true
sleep 1

systemctl restart edns-proxy
sleep 3

# Check if service is running
print_warning "Checking EDNS Proxy status..."
if systemctl is-active --quiet edns-proxy; then
    print_success "EDNS Proxy service is running"
else
    print_error "EDNS Proxy failed to start"
    print_warning "Checking logs..."
    journalctl -u edns-proxy -n 20 --no-pager
    exit 1
fi

# Test EDNS Proxy
print_warning "Testing EDNS Proxy on port $EDNS_PROXY_PORT..."
if ss -ulpn | grep -q ":$EDNS_PROXY_PORT"; then
    print_success "EDNS Proxy listening on port $EDNS_PROXY_PORT"
    echo "Current listeners on port 53:"
    ss -tulpn | grep ":53"
else
    print_error "EDNS Proxy failed to bind to port 53"
    exit 1
fi

# Update resolv.conf to use local proxy
print_warning "Configuring /etc/resolv.conf..."
echo "# Generated by EDNS Proxy installer" > /etc/resolv.conf
echo "nameserver 127.0.0.1" >> /etc/resolv.conf
echo "options edns0" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true

# Test DNS query
print_warning "Testing DNS query through proxy..."
if command -v dig &> /dev/null; then
    if timeout 5 dig @127.0.0.1 google.com +short +time=3 +tries=2 > /dev/null 2>&1; then
        print_success "DNS query successful through EDNS Proxy"
        echo "Test query: dig @127.0.0.1 google.com"
    else
        print_error "DNS query failed"
        print_warning "Running diagnostic..."
        systemctl status edns-proxy --no-pager
    fi
else
    print_warning "dig not found, installing dnsutils..."
    apt-get install -y dnsutils > /dev/null 2>&1
    if timeout 5 dig @127.0.0.1 google.com +short +time=3 +tries=2 > /dev/null 2>&1; then
        print_success "DNS query successful through EDNS Proxy"
    else
        print_error "DNS query failed"
    fi
fi

# Apply kernel optimizations for stability
print_warning "Applying kernel optimizations for stability..."
cat > /etc/sysctl.d/99-edns-optimize.conf << EOF
# Network optimizations for EDNS Proxy
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=131072
net.core.wmem_default=131072
net.ipv4.udp_mem=4096 87380 16777216
net.ipv4.udp_rmem_min=4096
net.ipv4.udp_wmem_min=4096
net.core.netdev_max_backlog=100000
net.core.somaxconn=65535
net.core.optmem_max=4194304
EOF

sysctl -p /etc/sysctl.d/99-edns-optimize.conf > /dev/null 2>&1

echo ""
print_success "=========================================="
print_success "EDNS Proxy with epoll Installation Completed"
print_success "=========================================="
echo ""
echo -e "${GREEN}Service Status:${NC} systemctl status edns-proxy"
echo -e "${GREEN}View Logs:${NC} journalctl -u edns-proxy -f"
echo -e "${GREEN}Test DNS:${NC} dig @127.0.0.1 google.com"
echo -e "${GREEN}Check Port:${NC} ss -tulpn | grep :53"
echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo -e "  External EDNS: $EXTERNAL_EDNS_SIZE bytes"
echo -e "  Internal EDNS: $INTERNAL_EDNS_SIZE bytes"
echo -e "  Proxy Port: $EDNS_PROXY_PORT"
echo -e "  Upstream: 127.0.0.1:$SLOWDNS_PORT"
echo ""
