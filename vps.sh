# Quick alias
alias h50='history | tail -50'

# Or a function with formatting
h50() {
    echo "=== Last 50 Commands ==="
    history | tail -50
    echo "========================"
}
