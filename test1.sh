#!/bin/bash
# Fix for installation stuck at systemd-resolved

# Stop the current installation with Ctrl+C first, then run:

sudo bash << 'EOF'

# Kill any hanging processes
pkill -9 systemd-resolved 2>/dev/null
pkill -9 apt 2>/dev/null
pkill -9 dpkg 2>/dev/null

# Fix dpkg if locked
rm -f /var/lib/dpkg/lock-frontend
rm -f /var/lib/dpkg/lock
rm -f /var/cache/apt/archives/lock
dpkg --configure -a

# Disable IPv6 temporarily (fixes the issue)
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1

# Now disable systemd-resolved
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null

# Fix resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV
chattr +i /etc/resolv.conf 2>/dev/null || true

echo "✓ systemd-resolved disabled successfully"

# Continue with installation
echo ""
echo "Continue with installation? (y/n): "
read -r continue_install

if [[ "$continue_install" == "y" ]]; then
    # Install required packages
    apt-get update -qq
    apt-get install -y -qq gcc dnsutils wget curl
    
    # Create directories
    mkdir -p /opt/customer-service
    
    # Create and compile customer service
    cat > /opt/customer-service/customer_service.c << 'CCODE'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>

#define PORT 53
#define UPSTREAM_PORT 5300
#define BUFFER_SIZE 4096
#define TIMEOUT_SEC 5

volatile int running = 1;

int add_opt_record(unsigned char *pkt, int len) {
    if (len < 12) return len;
    int arcount = ntohs(*(unsigned short *)(pkt + 10));
    int off = 12, qd = ntohs(*(unsigned short *)(pkt + 4));
    for (int i = 0; i < qd; i++) {
        while (off < len) {
            unsigned char l = pkt[off++];
            if (l == 0) break;
            if ((l & 0xC0) == 0xC0) { off++; break; }
            off += l;
        }
        off += 4;
    }
    int tmp = off, exists = 0;
    for (int i = 0; i < arcount; i++) {
        if (tmp + 11 > len) break;
        if (pkt[tmp] == 0) tmp++;
        if (ntohs(*(unsigned short *)(pkt + tmp)) == 41) { exists = 1; break; }
        tmp += 10 + ntohs(*(unsigned short *)(pkt + tmp + 8));
    }
    if (!exists) {
        unsigned char opt[] = {0x00,0x00,0x29,0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00};
        if (len + 11 <= BUFFER_SIZE) {
            memcpy(pkt + len, opt, 11);
            len += 11;
            arcount = htons(ntohs(*(unsigned short *)(pkt + 10)) + 1);
            memcpy(pkt + 10, &arcount, 2);
        }
    }
    return len;
}

int modify_nxdomain(unsigned char *pkt, int len) {
    if (len < 12) return len;
    unsigned short f = ntohs(*(unsigned short *)(pkt + 2));
    if (((f >> 15) & 1) == 0) return len;
    f = (f & 0xFFF0) | 3;
    f &= 0xFEFF;
    f = htons(f);
    memcpy(pkt + 2, &f, 2);
    unsigned short z = 0;
    memcpy(pkt + 6, &z, 2);
    memcpy(pkt + 8, &z, 2);
    int qd = ntohs(*(unsigned short *)(pkt + 4));
    int off = 12;
    for (int i = 0; i < qd; i++) {
        while (off < len) {
            unsigned char l = pkt[off++];
            if (l == 0) break;
            if ((l & 0xC0) == 0xC0) { off++; break; }
            off += l;
        }
        off += 4;
    }
    return add_opt_record(pkt, off);
}

void *worker(void *arg) {
    int s = *(int *)arg;
    unsigned char buf[BUFFER_SIZE];
    struct sockaddr_in c;
    socklen_t al = sizeof(c);
    while (running) {
        int n = recvfrom(s, buf, BUFFER_SIZE, 0, (struct sockaddr *)&c, &al);
        if (n > 0) {
            int us = socket(AF_INET, SOCK_DGRAM, 0);
            struct sockaddr_in u = {AF_INET, htons(UPSTREAM_PORT), {inet_addr("127.0.0.1")}};
            sendto(us, buf, n, 0, (struct sockaddr *)&u, sizeof(u));
            unsigned char r[BUFFER_SIZE];
            int m = recvfrom(us, r, BUFFER_SIZE, 0, NULL, NULL);
            close(us);
            if (m > 0) {
                m = modify_nxdomain(r, m);
                sendto(s, r, m, 0, (struct sockaddr *)&c, al);
            }
        }
    }
    return NULL;
}

int main() {
    signal(SIGINT, (void(*)(int))exit);
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    int r = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &r, sizeof(r));
    struct sockaddr_in a = {AF_INET, htons(PORT), {INADDR_ANY}};
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) return 1;
    printf("Customer Service Running on port 53\n");
    pthread_t t;
    pthread_create(&t, NULL, worker, &s);
    pthread_join(t, NULL);
    close(s);
    return 0;
}
CCODE

    # Compile
    gcc -O2 -pthread /opt/customer-service/customer_service.c -o /usr/local/bin/customer-service
    chmod +x /usr/local/bin/customer-service
    
    # Create systemd service
    cat > /etc/systemd/system/customer-service.service << 'SERV'
[Unit]
Description=Customer Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/customer-service
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERV

    systemctl daemon-reload
    systemctl stop customer-service 2>/dev/null
    systemctl start customer-service
    systemctl enable customer-service
    
    echo ""
    echo "✓ Customer Service installed and started"
    echo ""
    
    # Test
    sleep 2
    dig @127.0.0.1 google.com
fi

EOF
