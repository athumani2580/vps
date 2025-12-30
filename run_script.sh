#!/bin/bash
echo "🔐 DNS Installer - Token Required"
read -p "Enter GitHub token: " token
echo "Installing..."
bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh")
