#!/bin/bash

# Install using environment variable for token

# Set your token as environment variable:
# export GITHUB_TOKEN="your_token_here"
# OR
# GITHUB_TOKEN="your_token_here" ./env_install.sh

SCRIPT_URL="https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh"
INSTALL_SCRIPT="dns_installer.sh"

echo "🔧 DNS Script Installer"
echo "========================"

# Check for token in environment
if [ -z "$GITHUB_TOKEN" ]; then
    echo "⚠️  No GITHUB_TOKEN found in environment"
    echo "ℹ️  Using public access (may fail for private repos)"
    AUTH_HEADER=""
else
    echo "✅ Using token from environment"
    AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
fi

# Download function
download_script() {
    echo "📥 Downloading script..."
    
    if command -v curl > /dev/null 2>&1; then
        if [ -n "$AUTH_HEADER" ]; then
            curl -s -H "$AUTH_HEADER" \
                 -H "Accept: application/vnd.github.v3.raw" \
                 -L "$SCRIPT_URL" \
                 -o "$INSTALL_SCRIPT"
        else
            curl -s -L "$SCRIPT_URL" -o "$INSTALL_SCRIPT"
        fi
    elif command -v wget > /dev/null 2>&1; then
        if [ -n "$AUTH_HEADER" ]; then
            wget --quiet \
                 --header="$AUTH_HEADER" \
                 --header="Accept: application/vnd.github.v3.raw" \
                 -O "$INSTALL_SCRIPT" \
                 "$SCRIPT_URL"
        else
            wget --quiet -O "$INSTALL_SCRIPT" "$SCRIPT_URL"
        fi
    else
        echo "❌ Error: curl or wget not found!"
        exit 1
    fi
    
    # Verify download
    if [ -f "$INSTALL_SCRIPT" ] && [ -s "$INSTALL_SCRIPT" ]; then
        chmod +x "$INSTALL_SCRIPT"
        echo "✅ Download successful!"
        echo "📁 File: $INSTALL_SCRIPT"
        return 0
    else
        echo "❌ Download failed!"
        return 1
    fi
}

# Main execution
if download_script; then
    echo ""
    echo "🚀 Ready to install!"
    echo ""
    echo "To run the installer:"
    echo "  ./$INSTALL_SCRIPT"
    echo ""
    
    # Ask to run immediately
    read -p "Run installer now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "▶️  Executing installer..."
        echo "────────────────────────────"
        ./"$INSTALL_SCRIPT"
    else
        echo "ℹ️  You can run it later with: ./$INSTALL_SCRIPT"
    fi
fi
