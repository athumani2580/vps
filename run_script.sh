#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
echo -e "${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║   Private Repository Installer           ║"
echo "║   Repository: athumani2580/DNS           ║"
echo "║   Script: slowdns/install.sh             ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# Function to print colored messages
print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Check for required commands
check_requirements() {
    if ! command -v curl &> /dev/null; then
        print_error "curl is not installed!"
        print_info "Installing curl..."
        
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y curl
        elif command -v yum &> /dev/null; then
            yum install -y curl
        elif command -v dnf &> /dev/null; then
            dnf install -y curl
        else
            print_error "Cannot install curl automatically. Please install it manually."
            exit 1
        fi
    fi
    print_success "curl is available"
}

# Ask for GitHub token
get_token() {
    echo ""
    print_info "GitHub Personal Access Token is required for private repository access"
    echo ""
    echo -e "${YELLOW}How to get a token:${NC}"
    echo "1. Go to: https://github.com/settings/tokens"
    echo "2. Click 'Generate new token' (classic)"
    echo "3. Select 'repo' scope (full control of private repositories)"
    echo "4. Generate token and copy it"
    echo ""
    
    # Ask for token
    read -sp "Enter GitHub Token: " TOKEN
    echo ""
    
    if [ -z "$TOKEN" ]; then
        print_error "Token cannot be empty!"
        exit 1
    fi
    
    # Verify token format (basic check)
    if [[ ${#TOKEN} -lt 20 ]]; then
        print_error "Token appears too short. GitHub tokens are usually 40+ characters."
        print_warning "Continue anyway? (y/N): "
        read -r CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo "$TOKEN"
}

# Download script from private repository
download_script() {
    local token="$1"
    local temp_file="/tmp/private_install_$(date +%s).sh"
    
    print_info "Downloading installer from private repository..."
    
    # Try GitHub API method first
    print_info "Trying GitHub API method..."
    API_RESPONSE=$(curl -s -w "%{http_code}" \
        -H "Authorization: token $token" \
        -H "Accept: application/vnd.github.v3.raw" \
        -o "$temp_file" \
        "https://api.github.com/repos/athumani2580/DNS/contents/slowdns/install.sh")
    
    HTTP_CODE=$(echo "$API_RESPONSE" | tail -n1)
    
    # Check if API call succeeded
    if [ "$HTTP_CODE" = "200" ] && [ -s "$temp_file" ]; then
        print_success "Downloaded via GitHub API"
        echo "$temp_file"
        return 0
    fi
    
    # Try raw URL with token
    print_info "Trying raw URL method..."
    rm -f "$temp_file"
    
    RAW_RESPONSE=$(curl -s -w "%{http_code}" \
        -H "Authorization: token $token" \
        -o "$temp_file" \
        "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/install.sh")
    
    RAW_HTTP_CODE=$(echo "$RAW_RESPONSE" | tail -n1)
    
    if [ "$RAW_HTTP_CODE" = "200" ] && [ -s "$temp_file" ]; then
        print_success "Downloaded via raw URL"
        echo "$temp_file"
        return 0
    fi
    
    # Both methods failed
    print_error "Failed to download script!"
    
    # Show error details if available
    if [ -s "$temp_file" ]; then
        print_info "Error details:"
        cat "$temp_file"
        echo ""
    fi
    
    print_info "HTTP Status Codes:"
    echo "  GitHub API: $HTTP_CODE"
    echo "  Raw URL: $RAW_HTTP_CODE"
    
    rm -f "$temp_file"
    return 1
}

# Validate downloaded script
validate_script() {
    local script_file="$1"
    
    # Check if file exists and has content
    if [ ! -s "$script_file" ]; then
        print_error "Downloaded file is empty!"
        return 1
    fi
    
    # Check if it's a JSON error message
    if grep -q '"message"' "$script_file" 2>/dev/null || 
       grep -q '"documentation_url"' "$script_file" 2>/dev/null; then
        print_error "Downloaded file contains GitHub error message:"
        head -n 5 "$script_file"
        return 1
    fi
    
    # Check if it's HTML (404 page)
    if grep -q "<!DOCTYPE html>" "$script_file" 2>/dev/null || 
       grep -q "404" "$script_file" 2>/dev/null; then
        print_error "Downloaded file appears to be an HTML error page"
        return 1
    fi
    
    # Check if it looks like a bash script
    if ! head -n1 "$script_file" | grep -q "^#!"; then
        print_warning "File doesn't start with shebang (#!). Checking content..."
        
        # Check for common bash script indicators
        if grep -q -E "(bash|sh|echo|curl|wget|apt|yum|dnf|function|if \[|then|fi)" "$script_file"; then
            print_info "Adding bash shebang..."
            sed -i '1i#!/bin/bash' "$script_file"
        else
            print_error "File doesn't appear to be a valid shell script"
            print_info "First 3 lines:"
            head -n 3 "$script_file"
            return 1
        fi
    fi
    
    print_success "Script validation passed"
    return 0
}

# Execute the downloaded script
execute_script() {
    local script_file="$1"
    
    # Make executable
    chmod +x "$script_file"
    
    print_info "Script details:"
    echo "  Location: $script_file"
    echo "  Size: $(wc -l < "$script_file") lines"
    echo "  First line: $(head -n1 "$script_file")"
    
    echo ""
    print_warning "About to execute the downloaded script"
    print_warning "Make sure you trust the source: athumani2580/DNS"
    echo ""
    
    # Ask for confirmation
    read -p "Proceed with installation? (y/N): " -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled"
        rm -f "$script_file"
        exit 0
    fi
    
    echo ""
    print_info "Starting installation..."
    echo "══════════════════════════════════════════"
    
    # Execute the script
    bash "$script_file"
    EXIT_CODE=$?
    
    echo "══════════════════════════════════════════"
    
    if [ $EXIT_CODE -eq 0 ]; then
        print_success "Installation completed successfully!"
    else
        print_error "Installation failed with exit code: $EXIT_CODE"
    fi
    
    # Clean up
    rm -f "$script_file"
    print_info "Temporary file cleaned up"
}

# Main execution
main() {
    # Check requirements
    check_requirements
    
    # Get token
    TOKEN=$(get_token)
    
    # Download script
    SCRIPT_FILE=$(download_script "$TOKEN")
    if [ $? -ne 0 ]; then
        print_error "Failed to download installation script"
        exit 1
    fi
    
    # Validate script
    if ! validate_script "$SCRIPT_FILE"; then
        print_error "Script validation failed"
        rm -f "$SCRIPT_FILE"
        exit 1
    fi
    
    # Execute script
    execute_script "$SCRIPT_FILE"
}

# Run main function
main "$@"
