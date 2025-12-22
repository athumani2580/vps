# Enhanced version with logging
export HISTTIMEFORMAT="%Y-%m-%d %T "
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTFILE=~/.bash_history_$(whoami)

# Auto-show recent commands on SSH login
if [ -n "$SSH_CONNECTION" ]; then
    echo ""
    echo "🔍 Recent Activity (last 50 commands):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    tail -50 ~/.bash_history 2>/dev/null || history | tail -50
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi
