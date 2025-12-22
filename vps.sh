#!/bin/bash

IP=$(echo $SSH_CONNECTION | awk '{print $1}')
if [ -n "$IP" ]; then
    echo ""
    echo "🔐 SSH Login from: $IP"
    echo "🕒 Time: $(date)"
    echo "📜 Recent command history:"
    echo "----------------------------------------"
    
    # Show last 50 commands with timestamps
    if command -v tac >/dev/null; then
        tail -100 ~/.bash_history | tac | head -50 | cat -n
    else
        history | tail -50
    fi
    
    echo ""
    echo "💡 Tip: Use 'history' to see full history"
    echo ""
fi
