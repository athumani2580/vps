#!/bin/bash
# Save as setup-history-auto.sh

# Backup original .bashrc
cp ~/.bashrc ~/.bashrc.backup.$(date +%Y%m%d)

# Create scripts directory
mkdir -p ~/scripts

# Create auto-history script
cat > ~/scripts/auto-history.sh << 'EOF'
#!/bin/bash
# Auto-show history on SSH login

if [ -n "$SSH_CONNECTION" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║               COMMAND HISTORY LOG                ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║ Last login: $(who -b | awk '{print $3, $4}')                 ║"
    echo "║ User: $(whoami) | Host: $(hostname)                 ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo "Last 50 commands:"
    echo "────────────────────────────────────────────────────"
    
    # Show history with line numbers
    history | tail -50 | nl -w2 -s'. '
    
    echo ""
    echo "Total commands in history: $(history | wc -l)"
    echo ""
fi
EOF

chmod +x ~/scripts/auto-history.sh

# Add to .bashrc
echo "" >> ~/.bashrc
echo "# Auto-show history on SSH login" >> ~/.bashrc
echo "source ~/scripts/auto-history.sh" >> ~/.bashrc
echo "" >> ~/.bashrc

echo "Setup complete! Reconnect via SSH to see the history."
