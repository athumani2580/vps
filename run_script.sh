#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TOKEN="DNS-INSTALL-2024"
SCRIPT_URL="https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh"
OUTPUT_FILE="dns_installer.sh"

# Function to display header
show_header() {
    clear
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════╗"
    echo "║   TOKEN-PROTECTED DNS INSTALLER        ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Function to generate download link
generate_download_link() {
    show_header
    echo -e "${BLUE}Generating token-protected download link...${NC}"
    echo ""
    
    # Create a unique download script with embedded token
    cat > download_script.sh << EOF
#!/bin/bash

# Auto-generated download script
TOKEN_REQUIRED="$TOKEN"
SCRIPT_URL="$SCRIPT_URL"

echo "========================================"
echo "DNS Installation Script"
echo "========================================"
echo ""

# Ask for token
read -p "Enter installation token: " USER_TOKEN

if [ "\$USER_TOKEN" != "\$TOKEN_REQUIRED" ]; then
    echo "Invalid token! Access denied."
    exit 1
fi

echo "Token accepted! Downloading installer..."
echo ""

# Download the actual script
if command -v curl > /dev/null 2>&1; then
    curl -s -L "\$SCRIPT_URL" -o dns_final_install.sh
elif command -v wget > /dev/null 2>&1; then
    wget -q "\$SCRIPT_URL" -O dns_final_install.sh
else
    echo "Error: Neither curl nor wget found. Please install one of them."
    exit 1
fi

if [ -f "dns_final_install.sh" ]; then
    chmod +x dns_final_install.sh
    echo "Download complete! Run with: ./dns_final_install.sh"
else
    echo "Download failed!"
fi
EOF

    chmod +x download_script.sh
    
    echo -e "${GREEN}✓ Download script created: download_script.sh${NC}"
    echo ""
    echo -e "${YELLOW}To share with others:${NC}"
    echo "1. Send them the 'download_script.sh' file"
    echo "2. They need to run: ./download_script.sh"
    echo "3. They must enter the token: $TOKEN"
    echo ""
    echo -e "${BLUE}Or create a one-line installer:${NC}"
    echo ""
    
    # Create one-line installer command
    cat > one_line_installer.txt << EOF
bash <(curl -s https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh?token=\$(echo "$TOKEN" | base64))
EOF
    
    echo "One-line installer saved to: one_line_installer.txt"
}

# Function to create direct download with token
create_direct_download() {
    show_header
    echo -e "${BLUE}Creating direct download with token protection...${NC}"
    echo ""
    
    # Create a wrapper script
    cat > dns_with_token.sh << EOF
#!/bin/bash

# Token-protected DNS Installer
# Generated on: $(date)

TOKEN="$TOKEN"
INSTALL_SCRIPT_URL="$SCRIPT_URL"

# Colors
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
NC='\\033[0m'

echo "========================================"
echo "Token-Protected DNS Installer"
echo "========================================"
echo ""

# Check if token provided as argument
if [ -n "\$1" ]; then
    USER_TOKEN="\$1"
else
    read -p "Enter installation token: " USER_TOKEN
fi

if [ "\$USER_TOKEN" != "\$TOKEN" ]; then
    echo -e "\${RED}✗ Invalid token! Installation aborted.\${NC}"
    echo -e "\${YELLOW}Please contact administrator for valid token.\${NC}"
    exit 1
fi

echo -e "\${GREEN}✓ Token verified! Starting installation...\${NC}"
echo ""

# Download and execute the main script
download_script() {
    echo "Downloading DNS installer..."
    
    # Try curl first, then wget
    if command -v curl > /dev/null 2>&1; then
        curl -s -L "\$INSTALL_SCRIPT_URL" -o /tmp/dns_installer.sh
    elif command -v wget > /dev/null 2>&1; then
        wget -q "\$INSTALL_SCRIPT_URL" -O /tmp/dns_installer.sh
    else
        echo -e "\${RED}Error: Need curl or wget to download installer\${NC}"
        exit 1
    fi
    
    if [ -f "/tmp/dns_installer.sh" ]; then
        chmod +x /tmp/dns_installer.sh
        echo -e "\${GREEN}Download complete! Executing installer...\${NC}"
        echo "========================================"
        bash /tmp/dns_installer.sh
    else
        echo -e "\${RED}Download failed! Please check your connection.\${NC}"
    fi
}

download_script
EOF

    chmod +x dns_with_token.sh
    
    echo -e "${GREEN}✓ Token-protected installer created: dns_with_token.sh${NC}"
    echo ""
    echo -e "${YELLOW}Usage options:${NC}"
    echo "1. Run interactively: ./dns_with_token.sh"
    echo "2. Run with token as argument: ./dns_with_token.sh $TOKEN"
    echo ""
    
    # Create download link using base64 encoding
    ENCODED_TOKEN=$(echo -n "$TOKEN" | base64)
    echo -e "${BLUE}Direct download link (with embedded token):${NC}"
    echo "curl -sL https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh | bash -s -- $TOKEN"
    echo ""
}

# Function to create web-based download
create_web_download() {
    show_header
    echo -e "${BLUE}Creating web-accessible download...${NC}"
    echo ""
    
    # Create HTML download page
    cat > download_page.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>DNS Installer Download</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 600px;
            margin: 50px auto;
            padding: 20px;
            background: #f5f5f5;
        }
        .container {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #333;
        }
        .token-input {
            width: 100%;
            padding: 10px;
            margin: 10px 0;
            border: 1px solid #ddd;
            border-radius: 5px;
        }
        .download-btn {
            background: #4CAF50;
            color: white;
            padding: 10px 20px;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-size: 16px;
        }
        .download-btn:disabled {
            background: #ccc;
            cursor: not-allowed;
        }
        .error {
            color: #f44336;
            margin-top: 10px;
        }
        .success {
            color: #4CAF50;
            margin-top: 10px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔒 DNS Installer Download</h1>
        <p>Please enter the installation token to download:</p>
        
        <input type="text" id="tokenInput" class="token-input" 
               placeholder="Enter token here..." 
               onkeyup="checkToken()">
        
        <button id="downloadBtn" class="download-btn" disabled>
            Download Installer
        </button>
        
        <div id="message"></div>
    </div>

    <script>
        const CORRECT_TOKEN = "$TOKEN";
        
        function checkToken() {
            const input = document.getElementById('tokenInput');
            const button = document.getElementById('downloadBtn');
            const message = document.getElementById('message');
            
            if (input.value === CORRECT_TOKEN) {
                button.disabled = false;
                message.innerHTML = '<p class="success">✓ Token accepted! Click download.</p>';
                button.onclick = function() {
                    // Create and trigger download
                    const link = document.createElement('a');
                    link.href = 'data:application/x-shellscript;charset=utf-8,' + 
                                encodeURIComponent(\`#!/bin/bash
# DNS Installer with Token Verification
TOKEN="$TOKEN"

echo "Verifying token..."
if [ "\\\$1" != "\\\$TOKEN" ]; then
    echo "Invalid token!"
    exit 1
fi

echo "Downloading main installer..."
curl -s $SCRIPT_URL | bash
\`);
                    link.download = 'dns_installer.sh';
                    link.click();
                };
            } else {
                button.disabled = true;
                if (input.value.length > 0) {
                    message.innerHTML = '<p class="error">✗ Invalid token</p>';
                } else {
                    message.innerHTML = '';
                }
            }
        }
    </script>
</body>
</html>
EOF

    echo -e "${GREEN}✓ Web download page created: download_page.html${NC}"
    echo ""
    echo -e "${YELLOW}To use:${NC}"
    echo "1. Host this HTML file on any web server"
    echo "2. Users access the page and enter the token"
    echo "3. Only with correct token can they download"
    echo ""
    echo "Required token: $TOKEN"
}

# Main menu
main_menu() {
    show_header
    echo -e "${YELLOW}Choose an option:${NC}"
    echo ""
    echo "1) Generate token-protected download script"
    echo "2) Create direct download with token"
    echo "3) Create web-based download page"
    echo "4) Create one-time download link"
    echo "5) Exit"
    echo ""
    read -p "Select [1-5]: " choice
    
    case $choice in
        1) generate_download_link ;;
        2) create_direct_download ;;
        3) create_web_download ;;
        4) create_one_time_link ;;
        5) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 2 ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    main_menu
}

# Function to create one-time download link
create_one_time_link() {
    show_header
    echo -e "${BLUE}Creating one-time download link...${NC}"
    echo ""
    
    # Generate unique token
    UNIQUE_TOKEN=$(date +%s | sha256sum | base64 | head -c 16)
    EXPIRY=$(date -d "+24 hours" +%Y-%m-%d\ %H:%M)
    
    cat > one_time_install.sh << EOF
#!/bin/bash

# One-time download script
# Expires: $EXPIRY
# Token: $UNIQUE_TOKEN

TOKEN="$UNIQUE_TOKEN"
EXPIRY="$EXPIRY"
MAIN_SCRIPT="$SCRIPT_URL"

# Check expiry
CURRENT_TIME=\$(date +%s)
EXPIRY_TIME=\$(date -d "$EXPIRY" +%s)

if [ \$CURRENT_TIME -gt \$EXPIRY_TIME ]; then
    echo "This download link has expired!"
    echo "Please request a new link."
    exit 1
fi

echo "One-time DNS Installer"
echo "Valid until: $EXPIRY"
echo ""

# Download and execute
curl -sL "\$MAIN_SCRIPT" | bash
EOF

    chmod +x one_time_install.sh
    
    echo -e "${GREEN}✓ One-time installer created${NC}"
    echo ""
    echo -e "${YELLOW}Link details:${NC}"
    echo "Token: $UNIQUE_TOKEN"
    echo "Expires: $EXPIRY"
    echo "File: one_time_install.sh"
    echo ""
    echo -e "${BLUE}One-line command:${NC}"
    echo "curl -sL YOUR_SERVER/one_time_install.sh | bash"
    echo ""
    echo "Note: After first download, delete or disable this script."
}

# Start
main_menu
