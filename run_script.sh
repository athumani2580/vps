#!/bin/bash

# One-liner installer with token support
# Usage: ./one_liner_install.sh [TOKEN]

TOKEN="${1:-}"
SCRIPT_URL="https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh"
OUTPUT_FILE="install.sh"

echo "=== DNS Script Installer ==="

# Check for token
if [ -n "$TOKEN" ]; then
    echo "Using provided token..."
    if command -v curl > /dev/null; then
        curl -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github.v3.raw" -L "$SCRIPT_URL" -o "$OUTPUT_FILE"
    elif command -v wget > /dev/null; then
        wget --header="Authorization: token $TOKEN" --header="Accept: application/vnd.github.v3.raw" -O "$OUTPUT_FILE" "$SCRIPT_URL"
    fi
else
    echo "No token provided, trying public access..."
    if command -v curl > /dev/null; then
        curl -L "$SCRIPT_URL" -o "$OUTPUT_FILE"
    elif command -v wget > /dev/null; then
        wget -O "$OUTPUT_FILE" "$SCRIPT_URL"
    fi
fi

# Check if download was successful
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    chmod +x "$OUTPUT_FILE"
    echo "Download successful! Script saved as: $OUTPUT_FILE"
    echo "To run: ./$OUTPUT_FILE"
else
    echo "Download failed!"
    exit 1
fi
