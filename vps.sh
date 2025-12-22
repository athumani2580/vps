#!/bin/bash
# check_history.sh - Works on Linux, macOS, and Unix-like systems

show_last_commands() {
    echo "=== System Information ==="
    uname -a
    echo ""
    
    echo "=== Last 50 Commands ==="
    
    # Try different methods to get history
    if command -v history &> /dev/null; then
        # Method 1: Standard history command
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            history -n | tail -50
        else
            # Linux/Unix
            history | tail -50
        fi
    elif [[ -f ~/.bash_history ]]; then
        # Method 2: Read bash history file
        tail -50 ~/.bash_history
    elif [[ -f ~/.zsh_history ]]; then
        # Method 3: Read zsh history file
        tail -50 ~/.zsh_history 2>/dev/null || echo "Cannot read zsh history directly"
    elif [[ -f ~/.history ]]; then
        # Method 4: Generic history file
        tail -50 ~/.history
    else
        echo "No history found in common locations"
        echo "Trying alternative methods..."
        
        # Try to use fc command (available in some shells)
        fc -l 1 2>/dev/null | tail -50 && return 0
        
        # Try to use built-in shell history
        set -o history 2>/dev/null
        HISTFILE=~/.bash_history
        history 2>/dev/null | tail -50 && return 0
        
        echo "Unable to retrieve command history"
        return 1
    fi
}

show_last_commands
