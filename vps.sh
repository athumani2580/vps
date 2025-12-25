#!/bin/bash

# Show what will be deleted
echo "Last 50 commands to be deleted:"
history | tail -50

# Auto-delete without confirmation
for i in {1..50}; do
    history -d $(history | tail -1 | awk '{print $1}') 2>/dev/null
done

# Write changes to history file
history -w

echo "Deleted last 50 commands"
