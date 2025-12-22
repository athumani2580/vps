#!/bin/bash
# history50.sh - Show last 50 commands for Ubuntu/Debian
# Usage: ./history50.sh

echo "========================================"
echo "Ubuntu/Debian Command History - Last 50"
echo "========================================"
echo "User: $(whoami)"
echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo "Distribution: $(lsb_release -d | cut -f2)"
echo "Kernel: $(uname -r)"
echo "----------------------------------------"

# Check if running in interactive shell
if [[ $- == *i* ]]; then
    echo "Interactive shell detected"
else
    echo "Non-interactive shell - history may be limited"
fi

echo ""
echo "=== LAST 50 COMMANDS ==="

# Method 1: Try standard history command
history | tail -50

# If history is empty, try reading from history file
if [ $? -ne 0 ] || [ $(history | wc -l) -eq 0 ]; then
    echo ""
    echo "Note: Using history file directly..."
    echo "----------------------------------------"
    
    # Check which history file exists
    if [ -f ~/.bash_history ]; then
        tail -50 ~/.bash_history
    elif [ -f ~/.zsh_history ]; then
        tail -50 ~/.zsh_history | sed 's/^: [0-9]*:[0-9]*;//'
    else
        echo "No history files found!"
        echo "Common locations checked:"
        ls -la ~/.*history 2>/dev/null || echo "  No history files in home directory"
    fi
fi

echo "========================================"
