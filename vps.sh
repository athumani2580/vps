#!/bin/bash
# ubuntu-history.sh - Enhanced history for Ubuntu/Debian systems
# Shows last 50 commands with system info

echo "========================================="
echo "Ubuntu/Debian System History - Last 50"
echo "========================================="

# Show system info
echo "System Information:"
echo "-------------------"
echo "Distribution: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
echo "Kernel: $(uname -rs)"
echo "User: $(whoami)@$(hostname)"
echo "Date: $(date)"
echo "Uptime: $(uptime -p)"
echo ""

# Check if history is enabled
if [ -z "$HISTFILE" ]; then
    HISTFILE=~/.bash_history
fi

echo "History Settings:"
echo "----------------"
echo "HISTFILE: $HISTFILE"
echo "HISTSIZE: ${HISTSIZE:-Default (500)}"
echo "HISTFILESIZE: ${HISTFILESIZE:-Default (2000)}"
echo ""

# Show last 50 commands
echo "Last 50 Commands:"
echo "-----------------"
history | tail -50
echo "========================================="
