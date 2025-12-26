#!/bin/bash

# Simple script that prompts for token
read -sp "Enter GitHub Personal Access Token: " TOKEN
echo ""

REPO_OWNER="athumani2580"
REPO_NAME="DNS"
BRANCH="main"
SCRIPT_PATH="slowdns/setup.sh"
OUTPUT_FILE="setup.sh"

# Download using the token
if command -v curl &> /dev/null; then
    curl -s -H "Authorization: token $TOKEN" \
         -H "Accept: application/vnd.github.v3.raw" \
         -L "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$SCRIPT_PATH?ref=$BRANCH" \
         -o "$OUTPUT_FILE"
elif command -v wget &> /dev/null; then
    wget --header="Authorization: token $TOKEN" \
         --header="Accept: application/vnd.github.v3.raw" \
         -O "$OUTPUT_FILE" \
         "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$SCRIPT_PATH?ref=$BRANCH"
else
    echo "Error: Neither curl nor wget is installed!"
    exit 1
fi

# Check if download was successful
if [ -s "$OUTPUT_FILE" ]; then
    chmod +x "$OUTPUT_FILE"
    echo "Script downloaded successfully!"
    echo "Executing script..."
    ./"$OUTPUT_FILE"
else
    echo "Error: Failed to download script!"
    echo "Check your token and repository permissions."
fi
