#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Required token (you can change this)
REQUIRED_TOKEN="DNS-INSTALL-2024"

# Function to display header
show_header() {
    clear
    echo -e "${GREEN}"
    echo "=========================================="
    echo "    DNS Installation Script"
    echo "=========================================="
    echo -e "${NC}"
}

# Function to check token
check_token() {
    show_header
    echo -e "${YELLOW}This installation requires a valid token to continue.${NC}"
    echo ""
    echo -e "Please enter the installation token:"
    read -s -p "Token: " user_token
    echo ""
    
    if [ "$user_token" == "$REQUIRED_TOKEN" ]; then
        echo -e "${GREEN}✓ Token accepted! Continuing installation...${NC}"
        sleep 2
        return 0
    else
        echo -e "${RED}✗ Invalid token! Installation aborted.${NC}"
        echo -e "${YELLOW}Please contact the administrator for a valid token.${NC}"
        exit 1
    fi
}

# Function to install from GitHub
install_from_github() {
    echo -e "\n${GREEN}Downloading and installing DNS script...${NC}"
    
    # Download the script from GitHub
    wget -q https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh -O dns_install.sh
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Script downloaded successfully${NC}"
        
        # Make it executable
        chmod +x dns_install.sh
        
        echo -e "\n${YELLOW}Starting DNS installation...${NC}"
        echo -e "=========================================="
        
        # Execute the downloaded script
        ./dns_install.sh
    else
        echo -e "${RED}✗ Failed to download script${NC}"
        echo -e "${YELLOW}Please check your internet connection and try again.${NC}"
        exit 1
    fi
}

# Main execution
main() {
    # Check for required commands
    if ! command -v wget &> /dev/null; then
        echo -e "${RED}Error: wget is not installed.${NC}"
        echo "Install it using: apt-get install wget (Debian/Ubuntu)"
        echo "or: yum install wget (CentOS/RHEL)"
        exit 1
    fi
    
    # Check token
    check_token
    
    # Install
    install_from_github
}

# Run main function
main "$@"
