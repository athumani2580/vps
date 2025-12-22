#!/bin/bash
# apt-history.sh - Show APT history for Ubuntu/Debian

echo "=== Ubuntu/Debian APT History ==="
echo ""

# Show recent apt commands
echo "Recent APT commands:"
history | grep -E "apt (install|remove|update|upgrade|search|purge)" | tail -20
echo ""

# Show dpkg history
echo "Recent package installations:"
grep " install " /var/log/dpkg.log 2>/dev/null | tail -10
echo ""

# Show last 50 all commands
echo "All recent commands:"
history | tail -50
