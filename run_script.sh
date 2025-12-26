#!/bin/bash

# Configuration
TOKEN="your_github_personal_access_token"
REPO_OWNER="athumani2580"
REPO_NAME="DNS"
BRANCH="main"
SCRIPT_PATH="slowdns/setup.sh"
OUTPUT_FILE="setup.sh"

# Create the script
cat > private_repo_setup.sh << 'EOF'
#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - EDIT THESE VALUES
TOKEN=""
REPO_OWNER="athumani2580"
REPO_NAME="DNS"
BRANCH="main"
SCRIPT_PATH="slowdns/setup.sh"
OUTPUT_FILE="setup.sh"

# Function to print colored messages
print_message() {
    echo -e "${2}${1}${NC}"
}

# Check if token is set
if [ -z "$TOKEN" ]; then
    print_message "Error: GitHub token is not set!" "$RED"
    print_message "Please create a GitHub Personal Access Token and add it to the script." "$YELLOW"
    print_message "Go to: GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)" "$YELLOW"
    print_message "Required scope: repo (for private repositories)" "$YELLOW"
    exit 1
fi

# Download script from private repository
print_message "Downloading script from private repository..." "$GREEN"

# Try using curl first
if command -v curl &> /dev/null; then
    print_message "Using curl to download..." "$YELLOW"
    curl -s -H "Authorization: token $TOKEN" \
         -H "Accept: application/vnd.github.v3.raw" \
         -L "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$SCRIPT_PATH?ref=$BRANCH" \
         -o "$OUTPUT_FILE"
    
    if [ $? -eq 0 ] && [ -s "$OUTPUT_FILE" ]; then
        print_message "Download successful using curl!" "$GREEN"
    else
        print_message "Curl download failed, trying wget..." "$YELLOW"
        rm -f "$OUTPUT_FILE"
    fi
fi

# Try wget if curl failed or not available
if [ ! -s "$OUTPUT_FILE" ] && command -v wget &> /dev/null; then
    print_message "Using wget to download..." "$YELLOW"
    wget --header="Authorization: token $TOKEN" \
         --header="Accept: application/vnd.github.v3.raw" \
         -O "$OUTPUT_FILE" \
         "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$SCRIPT_PATH?ref=$BRANCH"
    
    if [ $? -eq 0 ] && [ -s "$OUTPUT_FILE" ]; then
        print_message "Download successful using wget!" "$GREEN"
    else
        print_message "Download failed!" "$RED"
        exit 1
    fi
fi

# Check if download was successful
if [ ! -s "$OUTPUT_FILE" ]; then
    print_message "Error: Failed to download the script!" "$RED"
    print_message "Check your:" "$YELLOW"
    print_message "1. Token permissions (needs 'repo' scope for private repos)" "$YELLOW"
    print_message "2. Repository URL and path" "$YELLOW"
    print_message "3. Internet connection" "$YELLOW"
    exit 1
fi

# Make the script executable
chmod +x "$OUTPUT_FILE"
print_message "Script made executable" "$GREEN"

# Execute the script
print_message "Executing the downloaded script..." "$GREEN"
print_message "==========================================" "$YELLOW"
./"$OUTPUT_FILE"

# Check execution result
if [ $? -eq 0 ]; then
    print_message "==========================================" "$YELLOW"
    print_message "Script executed successfully!" "$GREEN"
else
    print_message "==========================================" "$YELLOW"
    print_message "Script execution failed!" "$RED"
fi
EOF

# Make the generated script executable
chmod +x private_repo_setup.sh

echo "Script created: private_repo_setup.sh"
echo ""
echo "IMPORTANT: Before running the script:"
echo "1. Edit private_repo_setup.sh and set your TOKEN"
echo "2. Run: ./private_repo_setup.sh"
