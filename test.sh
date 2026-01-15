#!/bin/bash

echo "🔐 DNS Installer - Token Required"
echo ""

# Get GitHub token
read -p "Enter GitHub token: " token

if [ -z "$token" ]; then
    echo "❌ Error: Token cannot be empty!"
    exit 1
fi

echo "📦 Installing..."
echo ""

# Try to download and execute directly
bash <(curl -s -H "Authorization: token $token" \
    -H "Accept: application/vnd.github.v3.raw" \
    "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con1.sh")
