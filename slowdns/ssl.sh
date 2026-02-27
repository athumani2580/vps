#!/bin/bash

# ==============================================
# Go SSH + Proxy Protocol + SlowDNS Installer
# Author: System Admin
# Version: 3.0
# ==============================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
OPENSSH_PORT=2222  # OpenSSH will run on this port (internal)
GOSSH_PORT=22      # Go SSH will listen on port 22 (external)
SLOWDNS_PORT=5300
WORK_DIR="/etc/gossh"
SSLH_PORT=443      # For HTTPS/SSLH multiplexing

# Functions
print_status() { echo -e "${BLUE}[•]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

install_dependencies() {
    print_status "Installing dependencies..."
    
    apt-get update -qq
    apt-get install -y -qq wget curl git iptables net-tools dnsutils golang-go build-essential
    
    # Install sslh for protocol multiplexing
    apt-get install -y -qq sslh
    
    if [ $? -eq 0 ]; then
        print_success "Dependencies installed"
    else
        print_error "Failed to install dependencies"
        exit 1
    fi
}

# Create Go SSH server with Proxy Protocol support
create_go_ssh_server() {
    print_status "Creating Go SSH server with Proxy Protocol..."
    
    mkdir -p $WORK_DIR/src
    cd $WORK_DIR/src
    
    # Create go.mod
    cat > go.mod << EOF
module gossh-server

go 1.19

require (
    github.com/gliderlabs/ssh v0.3.5
    github.com/pires/go-proxyproto v0.7.0
    golang.org/x/crypto v0.17.0
)
EOF

    # Create main.go with Proxy Protocol support
    cat > main.go << 'EOF'
package main

import (
    "fmt"
    "log"
    "net"
    "os"
    "time"
    "io"
    "github.com/gliderlabs/ssh"
    "github.com/pires/go-proxyproto"
    "golang.org/x/crypto/ssh/terminal"
)

func main() {
    // Configure SSH server
    ssh.Handle(func(s ssh.Session) {
        term := terminal.NewTerminal(s, "> ")
        
        // Welcome banner with Go identification
        io.WriteString(s, "\r\n\x1b[32m====================================\x1b[0m\r\n")
        io.WriteString(s, "\x1b[36m   Go SSH Server with Proxy Protocol\x1b[0m\r\n")
        io.WriteString(s, "\x1b[33m   Version: 1.0.0\x1b[0m\r\n")
        io.WriteString(s, "\x1b[32m====================================\x1b[0m\r\n\r\n")
        
        // Get client info from context
        remoteAddr := s.RemoteAddr().String()
        if proxyInfo, ok := s.Context().Value("proxy-info").(*proxyproto.Header); ok {
            io.WriteString(s, fmt.Sprintf("\x1b[34m[Proxy Protocol]\x1b[0m\r\n"))
            io.WriteString(s, fmt.Sprintf("  Original Client: %s\r\n", proxyInfo.SourceAddr.String()))
            io.WriteString(s, fmt.Sprintf("  Proxy Server: %s\r\n\r\n", proxyInfo.DestinationAddr.String()))
        }
        
        io.WriteString(s, fmt.Sprintf("\x1b[34m[Connection Info]\x1b[0m\r\n"))
        io.WriteString(s, fmt.Sprintf("  Connected from: %s\r\n", remoteAddr))
        io.WriteString(s, fmt.Sprintf("  Protocol: SSH-2.0-Go\r\n"))
        io.WriteString(s, fmt.Sprintf("  Time: %s\r\n\r\n", time.Now().Format(time.RFC1123)))
        
        io.WriteString(s, "Available commands:\r\n")
        io.WriteString(s, "  help     - Show this help\r\n")
        io.WriteString(s, "  info     - Show connection info\r\n")
        io.WriteString(s, "  exit     - Exit session\r\n")
        io.WriteString(s, "  df       - Show disk usage\r\n")
        io.WriteString(s, "  free     - Show memory usage\r\n")
        io.WriteString(s, "  uptime   - Show system uptime\r\n\r\n")
        
        for {
            line, err := term.ReadLine()
            if err != nil {
                break
            }
            
            switch line {
            case "exit", "quit":
                io.WriteString(s, "Goodbye!\r\n")
                return
            case "help":
                io.WriteString(s, "Commands: help, info, exit, df, free, uptime\r\n")
            case "info":
                io.WriteString(s, fmt.Sprintf("Client: %s\r\n", remoteAddr))
                io.WriteString(s, fmt.Sprintf("Server: %s\r\n", s.LocalAddr()))
            case "df":
                output, err := os.ReadFile("/proc/mounts")
                if err == nil {
                    io.WriteString(s, string(output))
                }
            case "free":
                output, err := os.ReadFile("/proc/meminfo")
                if err == nil {
                    io.WriteString(s, string(output))
                }
            case "uptime":
                output, err := os.ReadFile("/proc/uptime")
                if err == nil {
                    io.WriteString(s, fmt.Sprintf("Uptime: %s seconds\r\n", output))
                }
            default:
                if line != "" {
                    io.WriteString(s, fmt.Sprintf("Unknown command: %s\r\n", line))
                }
            }
        }
    })

    // Custom password authentication
    ssh.PasswordAuth(func(ctx ssh.Context, password string) bool {
        log.Printf("Auth attempt from %s", ctx.RemoteAddr())
        // Accept any password for testing - you should implement proper auth
        return true
    })

    // Create listener with Proxy Protocol support
    listener, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%s", os.Getenv("GOSSH_PORT")))
    if err != nil {
        log.Fatalf("Failed to listen: %v", err)
    }

    // Wrap listener with Proxy Protocol
    proxyListener := &proxyproto.Listener{
        Listener: listener,
        ProxyHeaderTimeout: 10 * time.Second,
    }

    log.Printf("Go SSH server starting on port %s", os.Getenv("GOSSH_PORT"))
    log.Printf("Proxy Protocol enabled - waiting for PROXY headers")
    log.Printf("Server banner: SSH-2.0-Go")

    // Start server with proxy protocol context
    server := &ssh.Server{
        Addr:    fmt.Sprintf(":%s", os.Getenv("GOSSH_PORT")),
        Handler: ssh.Handler(func(s ssh.Session) {
            // Get proxy info from context
            if conn, ok := s.Context().Value("proxy-conn").(*proxyproto.Conn); ok {
                ctx := s.Context()
                ctx = context.WithValue(ctx, "proxy-info", conn.ProxyHeader())
                s = &sessionWithContext{s, ctx}
            }
            ssh.DefaultHandler(s)
        }),
    }

    // Wrap connections to store proxy info in context
    server.ConnCallback = func(ctx ssh.Context, conn net.Conn) net.Conn {
        if proxyConn, ok := conn.(*proxyproto.Conn); ok {
            ctx.SetValue("proxy-conn", proxyConn)
            log.Printf("New connection with PROXY header - client: %s via %s", 
                proxyConn.ProxyHeader().SourceAddr, 
                proxyConn.ProxyHeader().DestinationAddr)
        }
        return conn
    }

    log.Fatal(server.Serve(proxyListener))
}

// Helper to create session with context
type sessionWithContext struct {
    ssh.Session
    ctx ssh.Context
}

func (s *sessionWithContext) Context() ssh.Context {
    return s.ctx
}
EOF

    # Download dependencies and build
    cd $WORK_DIR/src
    go mod tidy
    go build -o $WORK_DIR/gossh-server
    
    if [ $? -eq 0 ] && [ -f "$WORK_DIR/gossh-server" ]; then
        print_success "Go SSH server compiled successfully"
        chmod +x $WORK_DIR/gossh-server
    else
        print_error "Failed to compile Go SSH server"
        exit 1
    fi
}

configure_openssh() {
    print_status "Configuring OpenSSH on internal port $OPENSSH_PORT..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Change OpenSSH to internal port
    sed -i "s/^Port 22/Port $OPENSSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/^#Port 22/Port $OPENSSH_PORT/" /etc/ssh/sshd_config
    
    # Ensure TCP forwarding is enabled
    sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    
    # Restart OpenSSH
    systemctl restart sshd
    
    if [ $? -eq 0 ]; then
        print_success "OpenSSH configured on port $OPENSSH_PORT"
    else
        print_error "OpenSSH configuration failed"
    fi
}

create_gossh_service() {
    print_status "Creating Go SSH service..."
    
    cat > /etc/systemd/system/gossh.service << EOF
[Unit]
Description=Go SSH Server with Proxy Protocol
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
Environment="GOSSH_PORT=$GOSSH_PORT"
ExecStart=$WORK_DIR/gossh-server
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "Go SSH service created"
}

setup_slowdns() {
    print_status "Setting up SlowDNS for Go SSH..."
    
    mkdir -p $WORK_DIR/slowdns
    
    # Download SlowDNS files
    wget -q -O $WORK_DIR/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.key"
    wget -q -O $WORK_DIR/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/server.pub"
    wget -q -O $WORK_DIR/slowdns/sldns-server "https://raw.githubusercontent.com/athumani2580/vps/main/slowdns/sldns-server"
    
    chmod +x $WORK_DIR/slowdns/sldns-server
    chmod 600 $WORK_DIR/slowdns/server.key
    
    print_success "SlowDNS files downloaded"
}

configure_sslh() {
    print_status "Configuring SSLH for protocol multiplexing..."
    
    cat > /etc/default/sslh << EOF
# Default options for sslh
RUN=yes

DAEMON=/usr/sbin/sslh
DAEMON_OPTS="--user sslh --listen 0.0.0.0:$SSLH_PORT --ssh 127.0.0.1:$GOSSH_PORT --ssl 127.0.0.1:443 --http 127.0.0.1:80 --pidfile /var/run/sslh/sslh.pid"
EOF

    systemctl enable sslh 2>/dev/null
    systemctl restart sslh
    
    print_success "SSLH configured on port $SSLH_PORT"
}

configure_proxy_protocol() {
    print_status "Setting up HAProxy with Proxy Protocol (optional)..."
    
    # Install HAProxy
    apt-get install -y -qq haproxy
    
    # Configure HAProxy with Proxy Protocol
    cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000

frontend ssh_in
    bind *:22
    bind *:$GOSSH_PORT
    mode tcp
    option tcplog
    
    # Send PROXY protocol to Go SSH
    default_backend gossh_servers

backend gossh_servers
    mode tcp
    option tcplog
    server gossh1 127.0.0.1:$GOSSH_PORT send-proxy-v2

frontend slowdns_in
    bind *:$SLOWDNS_PORT udp
    mode tcp
    use_backend slowdns_servers

backend slowdns_servers
    mode tcp
    server slowdns1 127.0.0.1:$SLOWDNS_PORT
EOF

    systemctl enable haproxy 2>/dev/null
    systemctl restart haproxy
    
    print_success "HAProxy configured with Proxy Protocol"
}

get_nameserver() {
    echo ""
    print_warning "Enter your nameserver/domain for SlowDNS (e.g., dns.yourdomain.com):"
    read -p "Nameserver: " NAMESERVER
    
    if [ -z "$NAMESERVER" ]; then
        print_error "Nameserver cannot be empty"
        get_nameserver
    fi
}

create_slowdns_service() {
    print_status "Creating SlowDNS service for Go SSH..."
    
    cat > /etc/systemd/system/slowdns-gossh.service << EOF
[Unit]
Description=SlowDNS for Go SSH
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR/slowdns
ExecStart=$WORK_DIR/slowdns/sldns-server -udp :$SLOWDNS_PORT -privkey-file $WORK_DIR/slowdns/server.key $NAMESERVER 127.0.0.1:$GOSSH_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "SlowDNS service created"
}

configure_firewall() {
    print_status "Configuring firewall..."
    
    # Clear existing rules
    iptables -F
    iptables -t nat -F
    
    # Set default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH ports
    iptables -A INPUT -p tcp --dport $GOSSH_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $OPENSSH_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $SSLH_PORT -j ACCEPT
    
    # Allow SlowDNS UDP
    iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    
    # NAT for DNS
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $SLOWDNS_PORT
    
    # Save rules
    apt-get install -y -qq iptables-persistent
    netfilter-persistent save 2>/dev/null
    
    print_success "Firewall configured"
}

start_services() {
    print_status "Starting services..."
    
    # Start Go SSH
    systemctl enable gossh 2>/dev/null
    systemctl start gossh
    
    # Start SlowDNS
    systemctl enable slowdns-gossh 2>/dev/null
    systemctl start slowdns-gossh
    
    sleep 3
    
    # Check Go SSH
    if systemctl is-active gossh &>/dev/null; then
        print_success "Go SSH service started"
    else
        print_error "Go SSH service failed to start"
        journalctl -u gossh --no-pager -n 20
    fi
    
    # Check SlowDNS
    if systemctl is-active slowdns-gossh &>/dev/null; then
        print_success "SlowDNS service started"
    else
        print_error "SlowDNS service failed to start"
    fi
}

test_services() {
    print_status "Testing services..."
    
    # Test Go SSH
    if nc -zv 127.0.0.1 $GOSSH_PORT 2>/dev/null; then
        print_success "Go SSH is listening on port $GOSSH_PORT"
        
        # Test SSH banner
        BANNER=$(timeout 2 nc 127.0.0.1 $GOSSH_PORT < /dev/null 2>&1 | head -1)
        if [[ $BANNER == *"SSH-2.0-Go"* ]]; then
            print_success "Go SSH banner detected: $BANNER"
        else
            print_warning "Unexpected banner: $BANNER"
        fi
    else
        print_error "Go SSH not responding on port $GOSSH_PORT"
    fi
    
    # Test SlowDNS
    if nc -zu 127.0.0.1 $SLOWDNS_PORT 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_error "SlowDNS not responding on port $SLOWDNS_PORT"
    fi
    
    # Test OpenSSH
    if nc -zv 127.0.0.1 $OPENSSH_PORT 2>/dev/null; then
        print_success "OpenSSH is listening on port $OPENSSH_PORT"
    else
        print_error "OpenSSH not responding on port $OPENSSH_PORT"
    fi
}

show_info() {
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    PUBLIC_KEY=$(cat $WORK_DIR/slowdns/server.pub 2>/dev/null)
    
    clear
    echo "=================================================================="
    echo -e "${GREEN}     Go SSH + Proxy Protocol + SlowDNS Installation Complete!${NC}"
    echo "=================================================================="
    echo ""
    echo -e "${YELLOW}Server Information:${NC}"
    echo "──────────────────────────────────"
    echo -e "IP Address      : $SERVER_IP"
    echo -e "Go SSH Port     : $GOSSH_PORT (with Proxy Protocol)"
    echo -e "OpenSSH Port    : $OPENSSH_PORT (internal)"
    echo -e "SSLH Port       : $SSLH_PORT"
    echo -e "SlowDNS Port    : $SLOWDNS_PORT (UDP)"
    echo -e "Nameserver      : $NAMESERVER"
    echo ""
    echo -e "${YELLOW}Go SSH Information:${NC}"
    echo "──────────────────────────────────"
    echo -e "Banner          : SSH-2.0-Go"
    echo -e "Proxy Protocol  : Enabled (v2)"
    echo -e "Public Key      : ${PUBLIC_KEY:0:50}..."
    echo ""
    echo -e "${YELLOW}Connection Methods:${NC}"
    echo "──────────────────────────────────"
    echo -e "${CYAN}1. Direct Go SSH:${NC}"
    echo "   ssh -p $GOSSH_PORT user@$SERVER_IP"
    echo ""
    echo -e "${CYAN}2. Via SlowDNS:${NC}"
    echo "   - DNS Server: $SERVER_IP:$SLOWDNS_PORT"
    echo "   - Public Key: $PUBLIC_KEY"
    echo "   - Nameserver: $NAMESERVER"
    echo "   - Target: 127.0.0.1:$GOSSH_PORT"
    echo ""
    echo -e "${CYAN}3. Via SSLH Multiplexer:${NC}"
    echo "   ssh -p $SSLH_PORT user@$SERVER_IP"
    echo ""
    echo -e "${YELLOW}Service Commands:${NC}"
    echo "──────────────────────────────────"
    echo -e "Go SSH    : systemctl {start|stop|status|restart} gossh"
    echo -e "SlowDNS   : systemctl {start|stop|status|restart} slowdns-gossh"
    echo -e "OpenSSH   : systemctl {start|stop|status|restart} sshd"
    echo -e "HAProxy   : systemctl {start|stop|status|restart} haproxy"
    echo -e "SSLH      : systemctl {start|stop|status|restart} sslh"
    echo ""
    echo -e "${YELLOW}Logs:${NC}"
    echo "──────────────────────────────────"
    echo -e "Go SSH    : journalctl -u gossh -f"
    echo -e "SlowDNS   : journalctl -u slowdns-gossh -f"
    echo -e "HAProxy   : journalctl -u haproxy -f"
    echo ""
    echo -e "${GREEN}Test connection: ssh -p $GOSSH_PORT root@$SERVER_IP${NC}"
    echo "=================================================================="
}

# Main installation
main() {
    clear
    echo "=================================================================="
    echo -e "${CYAN}       Go SSH + Proxy Protocol + SlowDNS Installer v3.0${NC}"
    echo "=================================================================="
    echo ""
    
    check_root
    install_dependencies
    configure_openssh
    create_go_ssh_server
    create_gossh_service
    configure_sslh
    configure_proxy_protocol
    setup_slowdns
    get_nameserver
    create_slowdns_service
    configure_firewall
    start_services
    test_services
    show_info
}

# Run main function
main
