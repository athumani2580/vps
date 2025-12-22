#!/bin/bash
# history-with-numbers.sh - Show history with line numbers

# Default number of commands to show
COUNT=${1:-50}

# Check if argument is a number
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "Usage: $0 [number_of_commands]"
    echo "Example: $0 50"
    exit 1
fi

echo "=== Last $COUNT Commands with Line Numbers ==="
echo ""

# Method 1: Using history command (already has numbers)
history "$COUNT"

# If history doesn't show numbers, use alternative method
if [ $? -ne 0 ] || [ $(history "$COUNT" | grep -c "^[[:space:]]*[0-9]") -eq 0 ]; then
    echo ""
    echo "Using alternative method..."
    echo ""
    
    # Method 2: Read from history file and add numbers
    if [ -f ~/.bash_history ]; then
        tail -n "$COUNT" ~/.bash_history | nl -w 3 -s "  "
    elif [ -f ~/.zsh_history ]; then
        tail -n "$COUNT" ~/.zsh_history | sed 's/^: [0-9]*:[0-9]*;//' | nl -w 3 -s "  "
    else
        echo "No history file found!"
        exit 1
    fi
fi
