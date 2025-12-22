#!/bin/bash
# install-hist.sh - Install hist command globally

# Make the script executable
chmod +x hist.sh

# Copy to /usr/local/bin
sudo cp hist.sh /usr/local/bin/hist

# Or create a symlink
sudo ln -sf /usr/local/bin/hist.sh /usr/local/bin/hist

echo "Installed 'hist' command globally"
echo ""
echo "Usage examples:"
echo "  hist                 # Show last 50 commands with numbers"
echo "  hist -n 20          # Show last 20 commands with numbers"
echo "  hist -s apt         # Search for 'apt' with numbers"
echo "  hist -t             # Show with timestamps and numbers"
echo "  hist -f             # Read from history file with numbers"
