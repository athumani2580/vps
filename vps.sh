#!/bin/bash
# hist.sh - Enhanced history viewer for Ubuntu/Debian
# Usage: ./hist.sh [-n NUM] [-u USER] [-d DATE] [-s SEARCH]

VERSION="1.0.0"
DEFAULT_COUNT=50

show_help() {
    echo "Usage: hist.sh [OPTIONS]"
    echo "Display command history for Ubuntu/Debian systems"
    echo ""
    echo "Options:"
    echo "  -n NUM     Show last NUM commands (default: 50)"
    echo "  -u USER    Show history for specific user (requires sudo)"
    echo "  -d DATE    Show commands from specific date (YYYY-MM-DD)"
    echo "  -s SEARCH  Search for commands containing SEARCH"
    echo "  -t         Show timestamps (if enabled)"
    echo "  -f         Show from file instead of session history"
    echo "  -c         Count commands by frequency"
    echo "  -h         Show this help message"
    echo "  -v         Show version"
    echo ""
    echo "Examples:"
    echo "  hist.sh -n 100          # Show last 100 commands"
    echo "  hist.sh -s apt          # Search for 'apt' commands"
    echo "  hist.sh -d 2024-01-15   # Show commands from Jan 15, 2024"
    echo "  hist.sh -u root -n 20   # Show last 20 root commands"
}

show_version() {
    echo "hist.sh v$VERSION - Ubuntu/Debian History Viewer"
}

show_last_commands() {
    local count=$1
    local user=$2
    local date_filter=$3
    local search=$4
    local show_timestamps=$5
    local use_file=$6
    local count_freq=$7
    
    # System info header
    echo "========================================"
    echo "Ubuntu/Debian Command History"
    echo "========================================"
    echo "Distribution: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    echo "Kernel: $(uname -rs)"
    echo "Shell: $(basename $SHELL)"
    echo "HISTFILE: ${HISTFILE:-~/.bash_history}"
    echo "HISTSIZE: ${HISTSIZE:-Not set}"
    echo "----------------------------------------"
    
    # Set timestamp format if requested
    if [ "$show_timestamps" = "true" ]; then
        export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S "
    fi
    
    # Get history based on user
    if [ -n "$user" ] && [ "$user" != "$(whoami)" ]; then
        if [ "$EUID" -eq 0 ]; then
            echo "Showing history for user: $user"
            if [ "$use_file" = "true" ]; then
                sudo tail -n "$count" "/home/$user/.bash_history" 2>/dev/null || \
                sudo tail -n "$count" "/home/$user/.zsh_history" 2>/dev/null | sed 's/^: [0-9]*:[0-9]*;//'
            else
                sudo -u "$user" bash -c "history $count"
            fi
        else
            echo "Error: Need sudo privileges to view other user's history"
            return 1
        fi
    else
        # Current user history
        if [ "$use_file" = "true" ]; then
            tail -n "$count" ~/.bash_history
        else
            history "$count"
        fi
    fi | {
        # Apply filters if specified
        if [ -n "$date_filter" ]; then
            grep "^[ 0-9]*[0-9]  $date_filter"
        elif [ -n "$search" ]; then
            grep -i "$search"
        else
            cat
        fi
    } | {
        # Count frequency or just display
        if [ "$count_freq" = "true" ]; then
            awk '{cmd=$2; for(i=3;i<=NF;i++) cmd=cmd " " $i; count[cmd]++} END {for (cmd in count) printf "%4d %s\n", count[cmd], cmd}' | sort -rn
        else
            cat
        fi
    }
    
    echo "========================================"
}

# Default values
COUNT=$DEFAULT_COUNT
USER=""
DATE=""
SEARCH=""
SHOW_TIMESTAMPS=false
USE_FILE=false
COUNT_FREQ=false

# Parse command line arguments
while getopts "n:u:d:s:tfchv" opt; do
    case $opt in
        n) COUNT="$OPTARG" ;;
        u) USER="$OPTARG" ;;
        d) DATE="$OPTARG" ;;
        s) SEARCH="$OPTARG" ;;
        t) SHOW_TIMESTAMPS=true ;;
        f) USE_FILE=true ;;
        c) COUNT_FREQ=true ;;
        h) show_help; exit 0 ;;
        v) show_version; exit 0 ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
    esac
done

# Validate count
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "Error: Count must be a number" >&2
    exit 1
fi

# Show history
show_last_commands "$COUNT" "$USER" "$DATE" "$SEARCH" "$SHOW_TIMESTAMPS" "$USE_FILE" "$COUNT_FREQ"
