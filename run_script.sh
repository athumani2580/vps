#!/bin/bash
# Filename: private_dns_installer.sh
# Save this as your main installer script

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration - CHANGE THESE TO YOUR PRIVATE SETTINGS
PRIVATE_INSTALL_URL="https://github.com/athumani2580/DNS/blob/main/slowdns/1.sh"  # Your private link
IMPORT_TOKEN="MY-PRIVATE-TOKEN-2024"  # Change this to your secret token
INSTALLER_NAME="Private DNS Installer"
VERSION="1.0"

# Logging
LOG_FILE="/tmp/dns_install_$(date +%Y%m%d_%H%M%S).log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Display header
show_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║    $INSTALLER_NAME - v$VERSION                    ║"
    echo "║            🔒 Token Required                      ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    log "Installer started"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}⚠ Warning: Running without root privileges${NC}"
        echo -e "Some features may require root access."
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Validate import token
validate_token() {
    show_header
    
    echo -e "${BLUE}🔐 Token Verification Required${NC}"
    echo -e "${YELLOW}This installer requires a valid import token to continue.${NC}"
    echo ""
    
    # Check if token provided as argument
    if [[ -n "$1" ]]; then
        INPUT_TOKEN="$1"
        echo -e "${CYAN}Token provided via command line${NC}"
    else
        # Ask for token
        echo -e "Please enter your import token:"
        echo -e "${YELLOW}(The token is case-sensitive)${NC}"
        read -s -p "➤ Token: " INPUT_TOKEN
        echo ""
    fi
    
    log "Token validation attempted"
    
    # Verify token
    if [[ "$INPUT_TOKEN" == "$IMPORT_TOKEN" ]]; then
        echo -e "${GREEN}✅ Token verified successfully!${NC}"
        echo -e "${GREEN}Access granted to private installer.${NC}"
        log "Token validation SUCCESS"
        return 0
    else
        echo -e "${RED}❌ Invalid token! Access denied.${NC}"
        echo -e "${YELLOW}Please obtain a valid token from the administrator.${NC}"
        log "Token validation FAILED - Invalid token: $INPUT_TOKEN"
        
        # Show hint if close
        if [[ ${#INPUT_TOKEN} == ${#IMPORT_TOKEN} ]]; then
            echo -e "${BLUE}💡 Hint: Token length is correct but characters don't match${NC}"
        fi
        
        exit 1
    fi
}

# Download and install from private URL
install_from_private_url() {
    echo ""
    echo -e "${BLUE}📥 Downloading from private repository...${NC}"
    echo -e "${CYAN}Source: $PRIVATE_INSTALL_URL${NC}"
    echo ""
    
    # Check for download tools
    if command -v curl &> /dev/null; then
        DOWNLOAD_CMD="curl -sL"
        echo -e "${GREEN}✓ Using curl for download${NC}"
    elif command -v wget &> /dev/null; then
        DOWNLOAD_CMD="wget -qO-"
        echo -e "${GREEN}✓ Using wget for download${NC}"
    else
        echo -e "${RED}❌ Error: Neither curl nor wget found${NC}"
        echo "Please install one of them:"
        echo "  Ubuntu/Debian: sudo apt install curl"
        echo "  CentOS/RHEL: sudo yum install curl"
        exit 1
    fi
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    log "Created temp directory: $TEMP_DIR"
    
    # Download the script
    echo -e "${YELLOW}⏳ Downloading installer...${NC}"
    
    # Try to download the raw content from GitHub
    RAW_URL=$(echo "$PRIVATE_INSTALL_URL" | sed 's/github\.com/raw.githubusercontent.com/' | sed 's/blob\///')
    
    if [[ $DOWNLOAD_CMD == "curl -sL" ]]; then
        curl -sL "$RAW_URL" -o "$TEMP_DIR/dns_install.sh"
    else
        wget -q "$RAW_URL" -O "$TEMP_DIR/dns_install.sh"
    fi
    
    # Check if download succeeded
    if [[ -f "$TEMP_DIR/dns_install.sh" ]] && [[ -s "$TEMP_DIR/dns_install.sh" ]]; then
        echo -e "${GREEN}✅ Download completed successfully${NC}"
        
        # Make executable
        chmod +x "$TEMP_DIR/dns_install.sh"
        
        # Show file info
        FILE_SIZE=$(wc -c < "$TEMP_DIR/dns_install.sh")
        LINE_COUNT=$(wc -l < "$TEMP_DIR/dns_install.sh")
        echo -e "${CYAN}📊 Installer details:${NC}"
        echo -e "  Size: $FILE_SIZE bytes"
        echo -e "  Lines: $LINE_COUNT"
        
        # Verify it's a shell script
        if head -1 "$TEMP_DIR/dns_install.sh" | grep -q "bash\|sh"; then
            echo -e "${GREEN}✓ Valid shell script detected${NC}"
        else
            echo -e "${YELLOW}⚠ Warning: File may not be a shell script${NC}"
        fi
        
        echo ""
        echo -e "${BLUE}🚀 Starting installation...${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
        
        # Execute the downloaded script
        cd "$TEMP_DIR"
        bash "./dns_install.sh"
        
        # Cleanup
        cd /
        rm -rf "$TEMP_DIR"
        
    else
        echo -e "${RED}❌ Download failed!${NC}"
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "1. Check your internet connection"
        echo "2. Verify the URL is accessible"
        echo "3. Try accessing: $RAW_URL"
        log "Download failed from URL: $RAW_URL"
        exit 1
    fi
}

# Display success message
show_success() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Installation completed successfully!${NC}"
    echo -e "${CYAN}Thank you for using $INSTALLER_NAME${NC}"
    echo ""
    echo -e "${YELLOW}📋 Installation log saved to: $LOG_FILE${NC}"
}

# Main execution flow
main() {
    # Check root privileges
    check_root
    
    # Check for token in arguments
    TOKEN_ARG=""
    for arg in "$@"; do
        if [[ "$arg" == "--token" ]] || [[ "$arg" == "-t" ]]; then
            TOKEN_ARG="$2"
        fi
    done
    
    # Validate token
    validate_token "$TOKEN_ARG"
    
    # Proceed with installation
    install_from_private_url
    
    # Show success message
    show_success
}

# Handle command line arguments
case "$1" in
    "--help"|"-h")
        show_header
        echo -e "${CYAN}Usage:${NC}"
        echo "  ./$(basename "$0")                    - Interactive mode"
        echo "  ./$(basename "$0") --token YOUR_TOKEN - Use token from command line"
        echo "  ./$(basename "$0") --help            - Show this help"
        echo ""
        echo -e "${CYAN}Example:${NC}"
        echo "  ./$(basename "$0") --token MY-PRIVATE-TOKEN-2024"
        echo ""
        exit 0
        ;;
    "--version"|"-v")
        echo "$INSTALLER_NAME v$VERSION"
        exit 0
        ;;
    *)
        # Run main function with all arguments
        main "$@"
        ;;
esac
