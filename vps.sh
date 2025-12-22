# History with numbers aliases
alias histn='history | tail -50'  # Already has numbers
alias hist50='history 50'         # Direct history command with numbers
alias hist100='history 100'
alias hist200='history 200'

# Custom function with better formatting
hist() {
    local count=${1:-50}
    
    # Show header
    echo "╔══════════════════════════════════════╗"
    echo "║   Command History (Last $count)       ║"
    echo "╚══════════════════════════════════════╝"
    
    # Show history with formatted numbers
    history "$count" | \
        awk '{
            # Extract line number and command
            line_num = $1
            $1 = ""
            cmd = substr($0, 2)
            
            # Format output
            printf "\033[1;36m%4d\033[0m  %s\n", line_num, cmd
        }'
    
    # Show footer with usage tip
    echo ""
    echo "Tip: Use '!<number>' to rerun a command"
    echo "Example: !123  will run command #123"
}

# Quick search with numbers
hsearch() {
    if [ -z "$1" ]; then
        echo "Usage: hsearch <pattern>"
        echo "Example: hsearch apt"
        return 1
    fi
    
    echo "Searching for: '$1'"
    echo ""
    history | grep -i --color=always "$1" | tail -30
}
