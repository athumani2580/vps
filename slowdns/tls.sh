#!/bin/bash

# WebSocket Proxy Setup Script
# TLS (WSS) on port 443 | Non-TLS (WS) on port 80
# HTTP/1.1 protocol switching with 101 response

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
DOMAIN=""
SSL_DIR="/etc/nginx/ssl"
NGINX_CONF_DIR="/etc/nginx"
BACKEND_WS_PORT="3000"
INSTALL_DIR="/opt/websocket-proxy"

# Print banner
echo -e "${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║     WebSocket Proxy with Port 80 (WS) and 443 (WSS)          ║
║     HTTP/1.1 Switching Protocols - 101 Response             ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Function to get domain
get_domain() {
    echo -e "${YELLOW}Configure WebSocket Proxy${NC}\n"
    
    read -p "Enter domain for WebSocket (e.g., ws.example.com): " DOMAIN
    while [ -z "$DOMAIN" ]; do
        echo -e "${RED}Domain cannot be empty${NC}"
        read -p "Enter domain: " DOMAIN
    done
    
    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    
    echo -e "\n${GREEN}Configuration:${NC}"
    echo "  Domain: $DOMAIN"
    echo "  Server IP: $SERVER_IP"
    echo "  WS (non-TLS): port 80"
    echo "  WSS (TLS): port 443"
    echo "  Backend port: $BACKEND_WS_PORT"
    
    echo -e "\n${YELLOW}DNS Records needed:${NC}"
    echo "  A record: $DOMAIN -> $SERVER_IP"
    
    read -p "Continue with setup? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
}

# Get domain
get_domain

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y \
            nginx \
            certbot \
            python3-certbot-nginx \
            nodejs \
            npm \
            openssl \
            curl \
            wget \
            net-tools
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y \
            nginx \
            certbot \
            python3-certbot-nginx \
            nodejs \
            npm \
            openssl \
            curl \
            wget \
            net-tools
    else
        echo -e "${RED}Unsupported OS${NC}"
        exit 1
    fi
    
    # Install websocat for testing
    if [ ! -f /usr/local/bin/websocat ]; then
        echo -e "${YELLOW}Installing websocat...${NC}"
        wget -q https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl -O /usr/local/bin/websocat
        chmod +x /usr/local/bin/websocat
    fi
    
    # Install wscat
    npm install -g wscat
    
    systemctl enable nginx
    systemctl start nginx
    
    echo -e "${GREEN}Dependencies installed${NC}"
}

# Function to generate SSL certificates
generate_ssl() {
    echo -e "${YELLOW}Setting up SSL certificates for port 443...${NC}"
    
    mkdir -p $SSL_DIR
    
    # Try Let's Encrypt first
    echo -e "${YELLOW}Attempting Let's Encrypt certificate...${NC}"
    if systemctl stop nginx && certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN 2>/dev/null; then
        echo -e "${GREEN}Let's Encrypt certificate obtained${NC}"
        ln -sf /etc/letsencrypt/live/$DOMAIN/fullchain.pem $SSL_DIR/cert.pem
        ln -sf /etc/letsencrypt/live/$DOMAIN/privkey.pem $SSL_DIR/key.pem
    else
        echo -e "${YELLOW}Falling back to self-signed certificate${NC}"
        # Generate self-signed certificate
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout $SSL_DIR/key.pem \
            -out $SSL_DIR/cert.pem \
            -subj "/C=US/ST=State/L=City/O=WebSocket/CN=$DOMAIN"
    fi
    
    # Generate DH parameters
    openssl dhparam -out $SSL_DIR/dhparam.pem 2048
    
    chmod 644 $SSL_DIR/cert.pem
    chmod 600 $SSL_DIR/key.pem
    
    systemctl start nginx
    
    echo -e "${GREEN}SSL certificates configured${NC}"
}

# Function to create Nginx configuration
create_nginx_config() {
    echo -e "${YELLOW}Creating Nginx WebSocket proxy configuration...${NC}"
    
    # Create map for connection upgrade
    cat > /etc/nginx/conf.d/websocket-map.conf << 'EOF'
# Map for WebSocket connection upgrade
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# Map for protocol detection
map $scheme $ws_scheme {
    default $scheme;
    https wss;
    http ws;
}
EOF

    # Create upstream for WebSocket backends
    cat > /etc/nginx/conf.d/websocket-upstream.conf << EOF
# WebSocket backend servers
upstream websocket_backend {
    # Use ip_hash for sticky sessions
    ip_hash;
    
    # Backend WebSocket server
    server 127.0.0.1:$BACKEND_WS_PORT max_fails=3 fail_timeout=30s;
    
    # Keepalive connections
    keepalive 32;
    keepalive_requests 100;
    keepalive_timeout 60s;
}
EOF

    # Create main WebSocket proxy configuration
    cat > /etc/nginx/sites-available/websocket-proxy << EOF
# ============================================
# WebSocket Proxy Configuration
# Port 80: WS (non-TLS) with protocol upgrade
# Port 443: WSS (TLS) with protocol upgrade
# ============================================

# HTTP Server - Port 80 (WS - non-TLS)
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # WebSocket upgrade endpoint
    location / {
        # Handle WebSocket upgrade
        if (\$http_upgrade != "") {
            proxy_pass http://websocket_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            
            # WebSocket specific headers
            proxy_set_header Sec-WebSocket-Key \$http_sec_websocket_key;
            proxy_set_header Sec-WebSocket-Protocol \$http_sec_websocket_protocol;
            proxy_set_header Sec-WebSocket-Version \$http_sec_websocket_version;
            proxy_set_header Sec-WebSocket-Extensions \$http_sec_websocket_extensions;
            
            # Standard proxy headers
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Port \$server_port;
            
            # WebSocket optimizations
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 60s;
            
            # Important: Don't intercept 101 response
            proxy_intercept_errors off;
            
            # Return 101 Switching Protocols
            break;
        }
        
        # For non-WebSocket requests (testing/info)
        root /var/www/html;
        index index.html;
        
        # Add CORS headers for testing
        add_header Access-Control-Allow-Origin *;
    }
    
    # WebSocket health check endpoint
    location /health {
        access_log off;
        default_type text/plain;
        return 200 "WS WebSocket proxy active on port 80\n";
        add_header Content-Type text/plain;
    }
    
    # WebSocket information endpoint
    location /ws-info {
        default_type application/json;
        return 200 '{
            "status": "active",
            "protocol": "ws",
            "domain": "$DOMAIN",
            "port": 80,
            "endpoint": "ws://$DOMAIN/",
            "upgrade_endpoint": "ws://$DOMAIN/ (HTTP upgrade)",
            "supported_protocols": ["websocket"],
            "tls": false,
            "101_response": true
        }';
    }
}

# HTTPS Server - Port 443 (WSS - TLS)
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    
    # SSL configuration
    ssl_certificate $SSL_DIR/cert.pem;
    ssl_certificate_key $SSL_DIR/key.pem;
    ssl_dhparam $SSL_DIR/dhparam.pem;
    
    # Modern SSL/TLS settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
    
    # WebSocket upgrade endpoint (WSS)
    location / {
        # Handle WebSocket upgrade
        if (\$http_upgrade != "") {
            proxy_pass http://websocket_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            
            # WebSocket specific headers
            proxy_set_header Sec-WebSocket-Key \$http_sec_websocket_key;
            proxy_set_header Sec-WebSocket-Protocol \$http_sec_websocket_protocol;
            proxy_set_header Sec-WebSocket-Version \$http_sec_websocket_version;
            proxy_set_header Sec-WebSocket-Extensions \$http_sec_websocket_extensions;
            
            # Standard proxy headers
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Port \$server_port;
            proxy_set_header X-Forwarded-SSL on;
            
            # WebSocket optimizations
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 60s;
            
            # Important: Don't intercept 101 response
            proxy_intercept_errors off;
            
            # Return 101 Switching Protocols
            break;
        }
        
        # For non-WebSocket requests
        root /var/www/html;
        index index.html;
        
        # Add CORS headers
        add_header Access-Control-Allow-Origin *;
    }
    
    # WebSocket health check
    location /health {
        access_log off;
        default_type text/plain;
        return 200 "WSS WebSocket proxy active on port 443\n";
        add_header Content-Type text/plain;
    }
    
    # WebSocket information
    location /ws-info {
        default_type application/json;
        return 200 '{
            "status": "active",
            "protocol": "wss",
            "domain": "$DOMAIN",
            "port": 443,
            "endpoint": "wss://$DOMAIN/",
            "upgrade_endpoint": "wss://$DOMAIN/ (HTTPS upgrade)",
            "supported_protocols": ["websocket"],
            "tls": true,
            "101_response": true
        }';
    }
    
    # Redirect HTTP to HTTPS for non-WebSocket traffic
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}

# Additional HTTP server for explicit WebSocket testing
server {
    listen 8080;
    listen [::]:8080;
    server_name $DOMAIN;
    
    location / {
        proxy_pass http://websocket_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
    }
}
EOF

    # Enable the site
    ln -sf /etc/nginx/sites-available/websocket-proxy /etc/nginx/sites-enabled/
    
    # Remove default site
    rm -f /etc/nginx/sites-enabled/default
    
    # Create web root
    mkdir -p /var/www/html
    mkdir -p /var/www/certbot
    
    echo -e "${GREEN}Nginx WebSocket proxy configuration created${NC}"
}

# Function to create test WebSocket server
create_test_server() {
    echo -e "${YELLOW}Creating test WebSocket server on port $BACKEND_WS_PORT...${NC}"
    
    mkdir -p $INSTALL_DIR
    
    # Create package.json
    cat > $INSTALL_DIR/package.json << EOF
{
    "name": "websocket-server",
    "version": "1.0.0",
    "description": "WebSocket Test Server",
    "main": "server.js",
    "scripts": {
        "start": "node server.js"
    },
    "dependencies": {
        "ws": "^8.14.2",
        "express": "^4.18.2"
    }
}
EOF

    # Create WebSocket server
    cat > $INSTALL_DIR/server.js << 'EOF'
#!/usr/bin/env node

const WebSocket = require('ws');
const http = require('http');
const express = require('express');

const app = express();
const PORT = process.env.PORT || 3000;

// Track connections
let connections = 0;
const clients = new Set();

// Create HTTP server
const server = http.createServer(app);

// Create WebSocket server
const wss = new WebSocket.Server({ 
    server,
    path: '/',
    clientTracking: true
});

// Serve static files
app.use(express.static(__dirname + '/public'));

// Root endpoint
app.get('/', (req, res) => {
    res.send(`
        <!DOCTYPE html>
        <html>
        <head>
            <title>WebSocket Test - Port 80/443</title>
            <style>
                body { font-family: Arial; padding: 20px; background: #1a1a1a; color: #fff; }
                .container { max-width: 800px; margin: 0 auto; }
                .endpoint { background: #333; padding: 15px; margin: 10px 0; border-radius: 5px; }
                .endpoint h3 { margin: 0 0 10px 0; color: #4CAF50; }
                .endpoint code { background: #444; padding: 5px; display: block; margin: 5px 0; }
                .status { background: #2a2a2a; padding: 10px; border-radius: 5px; margin: 20px 0; }
                #messages { background: #000; padding: 10px; height: 200px; overflow: auto; font-family: monospace; }
                button { background: #4CAF50; color: white; border: none; padding: 10px 20px; cursor: pointer; margin: 5px; }
                input { padding: 10px; width: 300px; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>WebSocket Test Page</h1>
                <p>Server: ${req.headers.host}</p>
                
                <div class="status">
                    <h3>Available Endpoints:</h3>
                    <p><strong>WS (non-TLS):</strong> ws://${req.headers.host}/ (port 80, auto-upgrade)</p>
                    <p><strong>WSS (TLS):</strong> wss://${req.headers.host}/ (port 443, auto-upgrade)</p>
                    <p><strong>Direct WS:</strong> ws://${req.headers.host}:8080/ (direct connection)</p>
                </div>
                
                <div class="endpoint">
                    <h3>Connection Status</h3>
                    <p>Active Connections: <span id="connCount">0</span></p>
                    <p>Protocol: <span id="protocol">-</span></p>
                </div>
                
                <div>
                    <button onclick="connectWS()">Connect WS (port 80)</button>
                    <button onclick="connectWSS()">Connect WSS (port 443)</button>
                    <button onclick="disconnect()">Disconnect</button>
                </div>
                
                <div style="margin: 20px 0;">
                    <input type="text" id="message" value="Hello WebSocket!" placeholder="Message">
                    <button onclick="sendMessage()">Send</button>
                </div>
                
                <h3>Messages:</h3>
                <div id="messages"></div>
                
                <script>
                    let ws = null;
                    
                    function log(message, type = 'info') {
                        const div = document.getElementById('messages');
                        const color = type === 'error' ? '#ff0000' : '#00ff00';
                        div.innerHTML += \`<div style="color: \${color}">[\${new Date().toLocaleTimeString()}] \${message}</div>\`;
                        div.scrollTop = div.scrollHeight;
                    }
                    
                    function connectWS() {
                        connect('ws://' + location.host + '/');
                    }
                    
                    function connectWSS() {
                        connect('wss://' + location.host + '/');
                    }
                    
                    function connect(url) {
                        if (ws) ws.close();
                        
                        log('Connecting to ' + url + '...');
                        document.getElementById('protocol').textContent = url.startsWith('wss') ? 'WSS (TLS)' : 'WS (non-TLS)';
                        
                        ws = new WebSocket(url);
                        
                        ws.onopen = () => {
                            log('✅ Connected! (101 Switching Protocols)');
                            document.getElementById('connCount').textContent = '1';
                        };
                        
                        ws.onmessage = (event) => {
                            log('📨 Received: ' + event.data);
                        };
                        
                        ws.onclose = () => {
                            log('🔌 Disconnected');
                            document.getElementById('connCount').textContent = '0';
                            document.getElementById('protocol').textContent = '-';
                        };
                        
                        ws.onerror = (error) => {
                            log('❌ Error: ' + error, 'error');
                        };
                    }
                    
                    function disconnect() {
                        if (ws) {
                            ws.close();
                        }
                    }
                    
                    function sendMessage() {
                        if (ws && ws.readyState === WebSocket.OPEN) {
                            const msg = document.getElementById('message').value;
                            ws.send(msg);
                            log('📤 Sent: ' + msg);
                        } else {
                            log('❌ Not connected!', 'error');
                        }
                    }
                </script>
            </div>
        </body>
        </html>
    `);
});

// API endpoint
app.get('/api/info', (req, res) => {
    res.json({
        status: 'active',
        connections: connections,
        uptime: process.uptime(),
        timestamp: new Date().toISOString(),
        endpoints: {
            ws: 'ws://' + req.headers.host + '/ (port 80)',
            wss: 'wss://' + req.headers.host + '/ (port 443)',
            direct_ws: 'ws://' + req.headers.host + ':8080/'
        }
    });
});

// WebSocket connection handler
wss.on('connection', (ws, req) => {
    connections++;
    clients.add(ws);
    
    const clientIp = req.socket.remoteAddress;
    const protocol = req.headers['x-forwarded-proto'] || 'ws';
    const userAgent = req.headers['user-agent'] || 'unknown';
    
    console.log(`Client connected from ${clientIp} via ${protocol}. Total: ${connections}`);
    
    // Send welcome message
    ws.send(JSON.stringify({
        type: 'welcome',
        message: 'Connected to WebSocket server',
        connections: connections,
        protocol: protocol,
        ip: clientIp,
        timestamp: new Date().toISOString()
    }));
    
    // Handle messages
    ws.on('message', (message) => {
        console.log(`Received from ${clientIp}: ${message}`);
        
        try {
            // Try to parse as JSON
            const data = JSON.parse(message);
            ws.send(JSON.stringify({
                type: 'echo',
                original: data,
                timestamp: new Date().toISOString()
            }));
        } catch {
            // Plain text message
            ws.send(`Echo (${protocol}): ${message}`);
        }
    });
    
    // Handle ping/pong
    ws.on('pong', () => {
        console.log('Received pong from client');
    });
    
    // Handle close
    ws.on('close', () => {
        connections--;
        clients.delete(ws);
        console.log(`Client disconnected. Total: ${connections}`);
    });
    
    // Send ping every 30 seconds
    const interval = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
            ws.ping();
        }
    }, 30000);
    
    ws.on('close', () => clearInterval(interval));
});

// Broadcast to all clients
function broadcast(message) {
    clients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            client.send(message);
        }
    });
}

// Start server
server.listen(PORT, () => {
    console.log('\n=== WebSocket Server Started ===');
    console.log(`Port: ${PORT}`);
    console.log(`WebSocket connections will be proxied through:`);
    console.log(`  • WS (non-TLS):  port 80 (auto-upgrade)`);
    console.log(`  • WSS (TLS):     port 443 (auto-upgrade)`);
    console.log(`  • Direct WS:     port 8080`);
    console.log('================================\n');
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('Shutting down...');
    wss.close();
    server.close();
});
EOF

    # Create simple test HTML page
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>WebSocket Test - Port 80/443</title>
    <meta http-equiv="refresh" content="0; url=/" />
</head>
<body>
    <p>Redirecting to WebSocket test page...</p>
</body>
</html>
EOF

    # Install dependencies
    cd $INSTALL_DIR
    npm install
    
    echo -e "${GREEN}Test WebSocket server created${NC}"
}

# Function to create systemd service
create_service() {
    echo -e "${YELLOW}Creating WebSocket service...${NC}"
    
    cat > /etc/systemd/system/websocket-server.service << EOF
[Unit]
Description=WebSocket Server (Backend)
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node $INSTALL_DIR/server.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=PORT=$BACKEND_WS_PORT

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable websocket-server
    systemctl start websocket-server
    
    echo -e "${GREEN}WebSocket service created${NC}"
}

# Function to create test script
create_test_script() {
    echo -e "${YELLOW}Creating test script...${NC}"
    
    cat > $INSTALL_DIR/test.sh << EOF
#!/bin/bash

# Test script for WebSocket proxy
DOMAIN="\$1"
if [ -z "\$DOMAIN" ]; then
    DOMAIN="$DOMAIN"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\${YELLOW}Testing WebSocket Proxy on \$DOMAIN\${NC}"
echo "=================================="

# Test 1: Check if ports are open
echo -e "\n\${YELLOW}Test 1: Port Check\${NC}"
nc -zv \$DOMAIN 80 2>&1 && echo -e "\${GREEN}✓ Port 80 (WS) is open\${NC}" || echo -e "\${RED}✗ Port 80 is closed\${NC}"
nc -zv \$DOMAIN 443 2>&1 && echo -e "\${GREEN}✓ Port 443 (WSS) is open\${NC}" || echo -e "\${RED}✗ Port 443 is closed\${NC}"

# Test 2: HTTP Upgrade (101 Switching Protocols)
echo -e "\n\${YELLOW}Test 2: HTTP Protocol Upgrade (Port 80)\${NC}"
RESPONSE=\$(curl -s -i -H "Connection: Upgrade" \\
                 -H "Upgrade: websocket" \\
                 -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \\
                 -H "Sec-WebSocket-Version: 13" \\
                 http://\$DOMAIN/ 2>/dev/null | head -n 1)

if [[ \$RESPONSE == *"101"* ]]; then
    echo -e "\${GREEN}✓ 101 Switching Protocols received\${NC}"
else
    echo -e "\${RED}✗ No 101 response\${NC}"
fi

# Test 3: HTTPS Upgrade (Port 443)
echo -e "\n\${YELLOW}Test 3: HTTPS Protocol Upgrade (Port 443)\${NC}"
RESPONSE=\$(curl -k -s -i -H "Connection: Upgrade" \\
                  -H "Upgrade: websocket" \\
                  -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \\
                  -H "Sec-WebSocket-Version: 13" \\
                  https://\$DOMAIN/ 2>/dev/null | head -n 1)

if [[ \$RESPONSE == *"101"* ]]; then
    echo -e "\${GREEN}✓ 101 Switching Protocols received\${NC}"
else
    echo -e "\${RED}✗ No 101 response\${NC}"
fi

# Test 4: WebSocket Connection (using websocat)
echo -e "\n\${YELLOW}Test 4: WebSocket Connection Test\${NC}"
if command -v websocat &> /dev/null; then
    echo "Testing WS (port 80)..."
    echo "test" | websocat -n1 ws://\$DOMAIN/ 2>/dev/null && echo -e "\${GREEN}✓ WS connection successful\${NC}" || echo -e "\${RED}✗ WS connection failed\${NC}"
    
    echo "Testing WSS (port 443)..."
    echo "test" | websocat -n1 -k wss://\$DOMAIN/ 2>/dev/null && echo -e "\${GREEN}✓ WSS connection successful\${NC}" || echo -e "\${RED}✗ WSS connection failed\${NC}"
else
    echo -e "\${YELLOW}websocat not installed, skipping\${NC}"
fi

# Test 5: Info Endpoints
echo -e "\n\${YELLOW}Test 5: Info Endpoints\${NC}"
curl -s http://\$DOMAIN/ws-info | grep -q "active" && echo -e "\${GREEN}✓ WS info endpoint working\${NC}" || echo -e "\${RED}✗ WS info endpoint failed\${NC}"
curl -sk https://\$DOMAIN/ws-info | grep -q "active" && echo -e "\${GREEN}✓ WSS info endpoint working\${NC}" || echo -e "\${RED}✗ WSS info endpoint failed\${NC}"

# Test 6: Health Check
echo -e "\n\${YELLOW}Test 6: Health Check\${NC}"
curl -s http://\$DOMAIN/health | grep -q "active" && echo -e "\${GREEN}✓ Health check passed\${NC}" || echo -e "\${RED}✗ Health check failed\${NC}"

echo -e "\n\${GREEN}Tests completed!\${NC}"
EOF

    chmod +x $INSTALL_DIR/test.sh
    
    echo -e "${GREEN}Test script created${NC}"
}

# Function to configure firewall
configure_firewall() {
    echo -e "${YELLOW}Configuring firewall for ports 80 and 443...${NC}"
    
    # For UFW
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp comment 'HTTP - WebSocket WS'
        ufw allow 443/tcp comment 'HTTPS - WebSocket WSS'
        ufw allow 22/tcp comment 'SSH'
        ufw --force enable
        echo -e "${GREEN}UFW configured${NC}"
    fi
    
    # For firewalld
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=22/tcp
        firewall-cmd --reload
        echo -e "${GREEN}Firewalld configured${NC}"
    fi
    
    # For iptables
    if command -v iptables &> /dev/null; then
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        echo -e "${GREEN}Iptables configured${NC}"
    fi
}

# Function to show summary
show_summary() {
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           WebSocket Proxy Setup Complete!                   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}WebSocket Endpoints:${NC}"
    echo ""
    echo -e "${CYAN}Non-TLS (WS) - Port 80:${NC}"
    echo "  • Endpoint:        ws://$DOMAIN/"
    echo "  • HTTP Upgrade:    http://$DOMAIN/ (returns 101)"
    echo ""
    echo -e "${CYAN}TLS (WSS) - Port 443:${NC}"
    echo "  • Endpoint:        wss://$DOMAIN/"
    echo "  • HTTPS Upgrade:   https://$DOMAIN/ (returns 101)"
    echo ""
    echo -e "${YELLOW}Test Commands:${NC}"
    echo ""
    echo "  # Test 101 Switching Protocols:"
    echo "  curl -i -H \"Connection: Upgrade\" -H \"Upgrade: websocket\" http://$DOMAIN/"
    echo "  curl -k -i -H \"Connection: Upgrade\" -H \"Upgrade: websocket\" https://$DOMAIN/"
    echo ""
    echo "  # Connect with websocat:"
    echo "  websocat ws://$DOMAIN/"
    echo "  websocat wss://$DOMAIN/ -k"
    echo ""
    echo "  # Connect with wscat:"
    echo "  wscat -c ws://$DOMAIN/"
    echo "  wscat -c wss://$DOMAIN/ --rejectUnauthorized false"
    echo ""
    echo "  # Run test suite:"
    echo "  $INSTALL_DIR/test.sh $DOMAIN"
    echo ""
    echo -e "${YELLOW}Info Endpoints:${NC}"
    echo "  • WS Info:  http://$DOMAIN/ws-info"
    echo "  • WSS Info: https://$DOMAIN/ws-info"
    echo "  • Health:   http://$DOMAIN/health"
    echo ""
    echo -e "${YELLOW}Web Interface:${NC}"
    echo "  http://$DOMAIN/"
    echo "  https://$DOMAIN/"
    echo ""
    echo -e "${YELLOW}Service Management:${NC}"
    echo "  • Nginx:           systemctl status nginx"
    echo "  • WebSocket:       systemctl status websocket-server"
    echo "  • Logs:            tail -f /var/log/nginx/access.log"
    echo ""
    echo -e "${GREEN}Setup complete!${NC}"
}

# Main execution
main() {
    echo -e "${GREEN}Starting WebSocket proxy setup...${NC}"
    
    # Install dependencies
    install_dependencies
    
    # Generate SSL
    generate_ssl
    
    # Create Nginx config
    create_nginx_config
    
    # Create test server
    create_test_server
    
    # Create service
    create_service
    
    # Create test script
    create_test_script
    
    # Configure firewall
    configure_firewall
    
    # Test Nginx config
    echo -e "${YELLOW}Testing Nginx configuration...${NC}"
    nginx -t
    
    if [ $? -eq 0 ]; then
        systemctl reload nginx
        echo -e "${GREEN}Nginx reloaded${NC}"
    else
        echo -e "${RED}Nginx configuration error${NC}"
        exit 1
    fi
    
    # Wait for services
    sleep 3
    
    # Show summary
    show_summary
}

# Run main function
main
