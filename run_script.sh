#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

echo "╔════════════════════════════════════════════════════╗"
echo "║    Private Repository Installation with Token      ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""

# Ask for GitHub token
echo "======================================================"
echo "    GitHub Authentication Required                   "
echo "======================================================"
echo ""
read -p "Enter your GitHub Personal Access Token: " GITHUB_TOKEN

if [ -z "$GITHUB_TOKEN" ]; then
    print_error "Token cannot be empty! Exiting..."
    exit 1
fi

# Repository details
REPO_OWNER="athumani2580"
REPO_NAME="DNS"
BRANCH="main"
FILE_PATH="slowdns/install.sh"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/$FILE_PATH"

echo ""
echo "======================================================"
echo "    Downloading Installation Script                   "
echo "======================================================"

# Method 1: Using curl with token in header
print_success "Attempting download with token authentication..."

# Create a temporary header file
HEADER_FILE="/tmp/github_headers.txt"
echo "Authorization: token $GITHUB_TOKEN" > $HEADER_FILE

# Download using curl with custom headers
curl -s -H "Authorization: token $GITHUB_TOKEN" \
     -H "Accept: application/vnd.github.v3.raw" \
     -o install_private.sh \
     "$INSTALL_SCRIPT_URL"

if [ $? -eq 0 ] && [ -f "install_private.sh" ]; then
    print_success "Download successful!"
    
    # Check if file is not empty
    if [ -s "install_private.sh" ]; then
        print_success "Script downloaded successfully ($(wc -l < install_private.sh) lines)"
    else
        print_error "Downloaded file is empty!"
        exit 1
    fi
else
    print_error "Download failed with curl headers method."
    
    # Method 2: Using wget with token
    print_warning "Trying alternative method..."
    wget --header="Authorization: token $GITHUB_TOKEN" \
         --header="Accept: application/vnd.github.v3.raw" \
         -O install_private.sh \
         "$INSTALL_SCRIPT_URL"
    
    if [ $? -eq 0 ] && [ -f "install_private.sh" ] && [ -s "install_private.sh" ]; then
        print_success "Download successful with wget!"
    else
        # Method 3: Using API endpoint
        print_warning "Trying GitHub API method..."
        API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$FILE_PATH"
        
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3.raw" \
             "$API_URL" -o install_private.sh
        
        if [ $? -eq 0 ] && [ -f "install_private.sh" ] && [ -s "install_private.sh" ]; then
            print_success "Download successful via GitHub API!"
        else
            print_error "All download methods failed!"
            print_error "Please check:"
            print_error "1. Token validity and permissions"
            print_error "2. Repository access"
            print_error "3. Internet connection"
            exit 1
        fi
    fi
fi

# Make script executable
chmod +x install_private.sh

echo ""
echo "======================================================"
echo "    Verifying Script Contents                         "
echo "======================================================"

# Check if it's a valid bash script
if head -n 1 install_private.sh | grep -q "^#!/bin/bash"; then
    print_success "Valid bash script detected"
else
    print_warning "Script doesn't start with #!/bin/bash, but will continue..."
fi

# Show first few lines
echo ""
print_success "Preview of script:"
echo "------------------------------------------------------"
head -n 10 install_private.sh
echo "------------------------------------------------------"

echo ""
echo "======================================================"
echo "    Starting Installation                             "
echo "======================================================"

read -p "Do you want to proceed with installation? (y/n): " confirm

if [[ $confirm =~ ^[Yy]$ ]]; then
    print_success "Starting installation..."
    echo "------------------------------------------------------"
    
    # Run the installation script
    ./install_private.sh
    
    INSTALL_STATUS=$?
    
    if [ $INSTALL_STATUS -eq 0 ]; then
        print_success "Installation completed successfully!"
    else
        print_error "Installation script exited with code: $INSTALL_STATUS"
    fi
else
    print_warning "Installation cancelled by user."
    
    # Ask if user wants to view the script
    read -p "Do you want to view the entire script? (y/n): " view_script
    if [[ $view_script =~ ^[Yy]$ ]]; then
        echo ""
        echo "======================================================"
        echo "    Script Contents                                   "
        echo "======================================================"
        cat install_private.sh
    fi
fi

# Post-installation cleanup and setup
echo ""
echo "======================================================"
echo "    Post-Installation Setup                           "
echo "======================================================"

# Clean up sensitive files
print_success "Cleaning up sensitive data..."
rm -f $HEADER_FILE
# Clear token from environment
unset GITHUB_TOKEN
# Clear bash history
history -c
print_success "Sensitive data cleaned"

# Start systemd-resolved if available
if command -v systemctl >/dev/null 2>&1; then
    print_success "Starting systemd-resolved service..."
    systemctl start systemd-resolved 2>/dev/null || print_warning "Could not start systemd-resolved"
else
    print_warning "systemctl not found, skipping service start"
fi

# Final cleanup
print_success "Cleaning up installation files..."
rm -f install_private.sh

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║                    Installation                    ║"
echo "║                     Complete!                      ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
print_success "Thank you for using the installation script!"
echo ""
