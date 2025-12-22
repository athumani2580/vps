#!/bin/sh
# Universal history script for all POSIX systems

# Get OS type
OS="$(uname -s)"

echo "OS: $OS"
echo "User: $(whoami)"
echo "Home: $HOME"
echo ""

# Try different methods
if command -v history >/dev/null 2>&1; then
    # Method 1: Use history command
    echo "Using 'history' command:"
    if [ "$OS" = "Darwin" ]; then
        # macOS
        history -r 2>/dev/null  # Read from file first
    fi
    history 2>/dev/null | tail -50
elif [ -f "$HOME/.bash_history" ]; then
    # Method 2: Read bash history
    echo "Reading from ~/.bash_history:"
    tail -50 "$HOME/.bash_history"
elif [ -f "$HOME/.history" ]; then
    # Method 3: Read generic history
    echo "Reading from ~/.history:"
    tail -50 "$HOME/.history"
elif [ -f "$HOME/.zsh_history" ]; then
    # Method 4: Read zsh history (need to parse)
    echo "Reading from ~/.zsh_history (zsh format):"
    tail -50 "$HOME/.zsh_history" | sed 's/^: [0-9]*:[0-9]*;//'
else
    # Last resort: try to set history and read
    echo "Trying to enable history..."
    set -o history 2>/dev/null
    history 2>/dev/null | tail -50 || echo "Cannot access command history"
fi
