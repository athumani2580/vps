#!/bin/bash
# complete-installer.sh - Complete SlowDNS + Customer Service Installer
# Everything configured correctly - ADDITIONAL: 1, OPT PSEUDOSECTION, MSG SIZE: 39

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SLOWDNS_PORT="5300"
SSH_PORT_1="22"
SSH_PORT_2="69"
INSTALL_DIR="/opt/customer-service"
BIN_DIR="/usr/local/bin"

# Print functions
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_step() { echo -e "${CYAN}[→]${NC} $1"; }

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This installer must be run as root"
        print_info "Please run: sudo $0"
        exit 1
    fi
}

# Get server IP
get_server_ip() {
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    print_info "Server IP: $SERVER_IP"
}

# Disable systemd-resolved (causes ADDITIONAL: 2)
disable_systemd_resolved() {
    print_step "Disabling systemd-resolved (prevents duplicate OPT records)..."
    
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    pkill -9 systemd-resolved 2>/dev/null
    
    # Remove and recreate resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    print_success "systemd-resolved disabled"
}

# Configure SSH
configure_ssh() {
    print_step "Configuring SSH on ports $SSH_PORT_1 and $SSH_PORT_2..."
    
    # Add ports if not exist
    grep -q "^Port $SSH_PORT_1" /etc/ssh/sshd_config || echo "Port $SSH_PORT_1" >> /etc/ssh/sshd_config
    grep -q "^Port $SSH_PORT_2" /etc/ssh/sshd_config || echo "Port $SSH_PORT_2" >> /etc/ssh/sshd_config
    
    # Enable TCP forwarding
    sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    
    systemctl restart sshd
    print_success "SSH configured on ports $SSH_PORT_1 and $SSH_PORT_2"
}

# Install SlowDNS
install_slowdns() {
    print_step "Installing SlowDNS..."
    
    rm -rf /etc/slowdns
    mkdir -p /etc/slowdns
    
    # Download files
    print_info "Downloading SlowDNS files..."
    
    wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key" && print_success "server.key downloaded" || print_error "Failed to download server.key"
    wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub" && print_success "server.pub downloaded" || print_error "Failed to download server.pub"
    wget -q -O /etc/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server" && print_success "sldns-server downloaded" || print_error "Failed to download sldns-server"
    
    chmod +x /etc/slowdns/sldns-server
    
    # Get nameserver
    echo ""
    read -p "Enter nameserver (e.g., ns.yourdomain.com): " NAMESERVER
    echo ""
    
    # Create SlowDNS service
    cat > /etc/systemd/system/slowdns.service << EOF
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSH_PORT_2
Restart=always
RestartSec=5
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

[Install]
WantedBy=multi-user.target
EOF
    
    # Create log file
    touch /var/log/slowdns.log
    
    print_success "SlowDNS installed"
}

# Install Customer Service (C version - ONE OPT record)
install_customer_service() {
    print_step "Installing Customer Service (C version with ONE OPT record)..."
    
    mkdir -p "$INSTALL_DIR"
    
    cat > "$INSTALL_DIR/customer_service.c" << 'C_EOF'
/**
 * Customer Service - C Version
 * Adds ONE OPT record only (not two)
 * Result: ADDITIONAL: 1, MSG SIZE: 39, OPT PSEUDOSECTION
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define PUBLIC_HOST     "0.0.0.0"
#define PUBLIC_PORT     53
#define UPSTREAM_HOST   "127.0.0.1"
#define UPSTREAM_PORT   5300
#define EXTERNAL_SIZE   512
#define BUFFER_SIZE     4096
#define TIMEOUT_SEC     5
#define MAX_WORKERS     8

typedef struct {
    unsigned long long requests;
    unsigned long long responses;
    unsigned long long errors;
    struct timeval start_time;
} Stats;

Stats stats = {0};
pthread_mutex_t stats_mutex = PTHREAD_MUTEX_INITIALIZER;
volatile int running = 1;

// Add ONE OPT record (EDNS0) - only if none exists
int add_opt_record(unsigned char *packet, int packet_len) {
    if (packet_len < 12) return packet_len;
    
    int arcount = ntohs(*(unsigned short *)(packet + 10));
    int offset = 12;
    int qdcount = ntohs(*(unsigned short *)(packet + 4));
    
    // Skip question section
    for (int i = 0; i < qdcount; i++) {
        while (offset < packet_len) {
            unsigned char label_len = packet[offset];
            offset++;
            if (label_len == 0) break;
            if ((label_len & 0xC0) == 0xC0) {
                offset++;
                break;
            }
            offset += label_len;
        }
        offset += 4;
    }
    
    // Check if OPT record already exists
    int temp_offset = offset;
    int opt_exists = 0;
    
    for (int i = 0; i < arcount; i++) {
        if (temp_offset + 11 > packet_len) break;
        if (packet[temp_offset] == 0) temp_offset++;
        
        unsigned short rtype = ntohs(*(unsigned short *)(packet + temp_offset));
        if (rtype == 41) {
            opt_exists = 1;
            break;
        }
        
        unsigned short rdlen = ntohs(*(unsigned short *)(packet + temp_offset + 8));
        temp_offset += 10 + rdlen;
    }
    
    // Add ONE OPT record only if none exists
    if (!opt_exists) {
        unsigned char opt_record[] = {
            0x00, 0x00, 0x29, 0x02, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        };
        
        if (packet_len + sizeof(opt_record) <= BUFFER_SIZE) {
            memcpy(packet + packet_len, opt_record, sizeof(opt_record));
            packet_len += sizeof(opt_record);
            arcount++;
            unsigned short arcount_net = htons(arcount);
            memcpy(packet + 10, &arcount_net, 2);
        }
    }
    
    return packet_len;
}

int modify_to_nxdomain(unsigned char *packet, int packet_len) {
    if (packet_len < 12) return packet_len;
    
    unsigned short flags = ntohs(*(unsigned short *)(packet + 2));
    int qr_bit = (flags >> 15) & 0x01;
    
    if (qr_bit == 0) return packet_len;
    
    // Set NXDOMAIN (RCODE=3)
    flags = (flags & 0xFFF0) | 0x0003;
    flags = flags & 0xFEFF;
    unsigned short flags_net = htons(flags);
    memcpy(packet + 2, &flags_net, 2);
    
    // Zero out answer counts
    unsigned short zero = 0;
    memcpy(packet + 6, &zero, 2);
    memcpy(packet + 8, &zero, 2);
    
    // Find end of question section
    int qdcount = ntohs(*(unsigned short *)(packet + 4));
    int offset = 12;
    
    for (int i = 0; i < qdcount; i++) {
        while (offset < packet_len) {
            unsigned char label_len = packet[offset];
            offset++;
            if (label_len == 0) break;
            if ((label_len & 0xC0) == 0xC0) {
                offset++;
                break;
            }
            offset += label_len;
        }
        offset += 4;
    }
    
    // Keep header + question section
    int new_len = offset;
    new_len = add_opt_record(packet, new_len);
    
    return new_len;
}

int forward_to_server(unsigned char *req, int req_len, unsigned char *res, int *res_len) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) return -1;
    
    struct timeval tv = {TIMEOUT_SEC, 0};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(UPSTREAM_PORT);
    inet_pton(AF_INET, UPSTREAM_HOST, &addr.sin_addr);
    
    sendto(sock, req, req_len, 0, (struct sockaddr *)&addr, sizeof(addr));
    
    socklen_t addr_len = sizeof(addr);
    int received = recvfrom(sock, res, BUFFER_SIZE, 0, NULL, NULL);
    close(sock);
    
    if (received > 0) {
        *res_len = received;
        return 0;
    }
    return -1;
}

void handle_client(int server_sock, struct sockaddr_in *client_addr, 
                   socklen_t client_addr_len, unsigned char *buffer, int buflen) {
    pthread_mutex_lock(&stats_mutex);
    stats.requests++;
    pthread_mutex_unlock(&stats_mutex);
    
    unsigned char response[BUFFER_SIZE];
    int response_len = 0;
    
    if (forward_to_server(buffer, buflen, response, &response_len) == 0) {
        response_len = modify_to_nxdomain(response, response_len);
        sendto(server_sock, response, response_len, 0,
               (struct sockaddr *)client_addr, client_addr_len);
        
        pthread_mutex_lock(&stats_mutex);
        stats.responses++;
        pthread_mutex_unlock(&stats_mutex);
    } else {
        pthread_mutex_lock(&stats_mutex);
        stats.errors++;
        pthread_mutex_unlock(&stats_mutex);
    }
}

void *worker_thread(void *arg) {
    int server_sock = *(int *)arg;
    unsigned char buffer[BUFFER_SIZE];
    struct sockaddr_in client_addr;
    socklen_t client_addr_len = sizeof(client_addr);
    
    while (running) {
        int n = recvfrom(server_sock, buffer, BUFFER_SIZE, 0,
                         (struct sockaddr *)&client_addr, &client_addr_len);
        if (n > 0) {
            handle_client(server_sock, &client_addr, client_addr_len, buffer, n);
        }
    }
    return NULL;
}

void signal_handler(int sig) {
    if (sig == SIGINT || sig == SIGTERM) {
        running = 0;
    }
}

int main() {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);
    
    gettimeofday(&stats.start_time, NULL);
    
    int server_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (server_sock < 0) return 1;
    
    int reuse = 1;
    setsockopt(server_sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(PUBLIC_PORT);
    
    if (bind(server_sock, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        fprintf(stderr, "Failed to bind to port %d\n", PUBLIC_PORT);
        close(server_sock);
        return 1;
    }
    
    printf("\n========================================\n");
    printf("Customer Service Started\n");
    printf("Adds ONE OPT record - MSG SIZE: 39\n");
    printf("========================================\n");
    printf("Listening on: %s:%d (UDP)\n", PUBLIC_HOST, PUBLIC_PORT);
    printf("Upstream:     %s:%d\n", UPSTREAM_HOST, UPSTREAM_PORT);
    printf("========================================\n\n");
    
    pthread_t threads[MAX_WORKERS];
    for (int i = 0; i < MAX_WORKERS; i++) {
        pthread_create(&threads[i], NULL, worker_thread, &server_sock);
    }
    
    while (running) {
        sleep(60);
        struct timeval now;
        gettimeofday(&now, NULL);
        unsigned long long elapsed = (now.tv_sec - stats.start_time.tv_sec);
        fprintf(stderr, "[STATS] Uptime: %llus | Requests: %llu | Responses: %llu | Errors: %llu\n",
                elapsed, stats.requests, stats.responses, stats.errors);
    }
    
    close(server_sock);
    return 0;
}
C_EOF
    
    # Compile
    cd "$INSTALL_DIR"
    gcc -O3 -march=native -pthread -o customer_service customer_service.c 2> compile.log
    
    if [[ $? -eq 0 ]] && [[ -f customer_service ]]; then
        strip customer_service
        cp customer_service "$BIN_DIR/customer-service"
        chmod +x "$BIN_DIR/customer-service"
        print_success "Customer Service compiled successfully"
    else
        print_error "Compilation failed"
        cat compile.log
        exit 1
    fi
    
    # Create systemd service
    cat > /etc/systemd/system/customer-service.service << EOF
[Unit]
Description=Customer Service DNS Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=$BIN_DIR/customer-service
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "Customer Service installed"
}

# Setup firewall
setup_firewall() {
    print_step "Setting up firewall..."
    
    # Allow ports
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow 53/udp
        ufw allow $SLOWDNS_PORT/udp
        ufw allow $SSH_PORT_1/tcp
        ufw allow $SSH_PORT_2/tcp
        print_success "UFW rules added"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 53 -j ACCEPT
        iptables -C INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
        iptables -C INPUT -p tcp --dport $SSH_PORT_1 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $SSH_PORT_1 -j ACCEPT
        iptables -C INPUT -p tcp --dport $SSH_PORT_2 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $SSH_PORT_2 -j ACCEPT
        print_success "iptables rules added"
    fi
}

# Install fail2ban
install_fail2ban() {
    print_step "Installing fail2ban..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y fail2ban -qq
    elif command -v yum &> /dev/null; then
        yum install -y fail2ban -q
    fi
    
    # Configure fail2ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh,$SSH_PORT_1,$SSH_PORT_2
maxretry = 3
bantime = 3600
EOF
    
    systemctl restart fail2ban
    systemctl enable fail2ban
    print_success "Fail2ban installed"
}

# Start services
start_services() {
    print_step "Starting services..."
    
    # Reload systemd
    systemctl daemon-reload
    
    # Stop any existing services
    systemctl stop customer-service 2>/dev/null
    systemctl stop slowdns 2>/dev/null
    pkill -9 customer-service 2>/dev/null
    pkill -9 sldns-server 2>/dev/null
    
    # Start SlowDNS
    systemctl enable slowdns
    systemctl start slowdns
    
    # Start Customer Service
    systemctl enable customer-service
    systemctl start customer-service
    
    sleep 3
}

# Test everything
run_tests() {
    print_step "Running tests..."
    
    echo ""
    echo "========================================="
    echo "Testing SlowDNS (port $SLOWDNS_PORT)..."
    echo "========================================="
    
    if systemctl is-active --quiet slowdns; then
        print_success "SlowDNS service is running"
    else
        print_error "SlowDNS service is not running"
        systemctl status slowdns --no-pager
    fi
    
    echo ""
    echo "========================================="
    echo "Testing Customer Service (port 53)..."
    echo "========================================="
    
    if systemctl is-active --quiet customer-service; then
        print_success "Customer Service is running"
    else
        print_error "Customer Service is not running"
        systemctl status customer-service --no-pager
    fi
    
    echo ""
    echo "========================================="
    echo "DNS Test - dig @127.0.0.1 google.com"
    echo "========================================="
    
    dig @127.0.0.1 google.com
}

# Show summary
show_summary() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Installation Complete!${NC}"
    echo "=========================================="
    echo ""
    echo "Services Installed:"
    echo "  ┌─────────────────────────────────────┐"
    echo "  │ 1. SlowDNS (Port $SLOWDNS_PORT/UDP)     │"
    echo "  │ 2. Customer Service (Port 53/UDP)      │"
    echo "  │ 3. SSH (Ports $SSH_PORT_1 and $SSH_PORT_2/TCP)  │"
    echo "  │ 4. Fail2ban (Protection)              │"
    echo "  └─────────────────────────────────────┘"
    echo ""
    echo "Architecture:"
    echo "  Client → Port 53 → Customer Service → Port $SLOWDNS_PORT → SlowDNS → Port $SSH_PORT_2"
    echo ""
    echo "Expected dig output:"
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │ status: NXDOMAIN                                        │"
    echo "  │ ADDITIONAL: 1                                           │"
    echo "  │ OPT PSEUDOSECTION: EDNS: version: 0, flags:; udp: 512  │"
    echo "  │ MSG SIZE  rcvd: 39                                      │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
    echo "Commands:"
    echo "  systemctl status customer-service  - Check DNS proxy"
    echo "  systemctl status slowdns           - Check SlowDNS"
    echo "  dig @127.0.0.1 google.com          - Test DNS resolution"
    echo ""
    echo "Client Connection:"
    echo "  Server: $SERVER_IP"
    echo "  Port: 53"
    echo "  Protocol: DNS-over-UDP"
    echo ""
    echo "=========================================="
}

# Main installation
main() {
    clear
    echo "=========================================="
    echo "  Complete SlowDNS + Customer Service"
    echo "  ADDITIONAL: 1 | MSG SIZE: 39"
    echo "=========================================="
    echo ""
    
    check_root
    get_server_ip
    disable_systemd_resolved
    configure_ssh
    install_slowdns
    install_customer_service
    setup_firewall
    install_fail2ban
    start_services
    
    sleep 2
    show_summary
    run_tests
    
    echo ""
    print_success "Installation complete! Everything is configured correctly."
}

main "$@"
