#!/bin/bash
# save as: install_admin_working.sh

echo "=== Installing Admin User Management System ==="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Install dependencies
echo "Installing dependencies..."
apt-get update
apt-get install -y openssl bc

# Create directories
mkdir -p /var/lib/admin_system
mkdir -p /var/log/admin_system

# Create the main admin script (SIMPLIFIED VERSION)
echo "Creating main admin script..."
cat > /usr/local/bin/admin << 'EOF'
#!/bin/bash
# Admin User Management System - Simple Working Version

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Switching to root..."
    exec sudo /usr/local/bin/admin "$@"
fi

# Configuration
DB_FILE="/var/lib/admin_system/users.db"
IP_HISTORY_DIR="/var/lib/admin_system/ip_history"
LOG_FILE="/var/log/admin_system/actions.log"
MONITOR_PID="/var/run/admin_monitor.pid"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Initialize database
init_database() {
    if [[ ! -f "$DB_FILE" ]]; then
        echo "# username:password_hash:max_ips:used_ips:expiry_date:status:created:last_login" > "$DB_FILE"
        mkdir -p "$IP_HISTORY_DIR"
        chmod 600 "$DB_FILE"
    fi
}

# Log actions
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Display header
show_header() {
    clear
    echo "╔══════════════════════════════════════╗"
    echo "║    USER IP MANAGEMENT SYSTEM         ║"
    echo "║         $(date '+%Y-%m-%d %H:%M')               ║"
    echo "╚══════════════════════════════════════╝"
    echo ""
}

# Display menu
show_menu() {
    echo "┌──────────────────────────────────────┐"
    echo "│           MAIN MENU                  │"
    echo "├──────────────────────────────────────┤"
    echo "  1. ${GREEN}Create New User${NC}"
    echo "  2. ${GREEN}Show Online Users & Usage${NC}"
    echo "  3. ${GREEN}Delete User${NC}"
    echo "  4. ${GREEN}Update User Data${NC}"
    echo "  5. ${GREEN}Disable/Enable User${NC}"
    echo "  6. ${BLUE}View All Users${NC}"
    echo "  7. ${YELLOW}System Status${NC}"
    echo "  0. ${RED}Exit${NC}"
    echo "└──────────────────────────────────────┘"
    echo ""
}

# Generate random password
generate_password() {
    openssl rand -base64 12 | tr -d '/+=' | head -c 12
}

# Hash password
hash_password() {
    openssl passwd -1 "$1"
}

# Check if user exists
user_exists() {
    [[ -f "$DB_FILE" ]] && grep -q "^$1:" "$DB_FILE"
}

# Get user info
get_user_info() {
    [[ -f "$DB_FILE" ]] && grep "^$1:" "$DB_FILE"
}

# Update user field
update_user_field() {
    local user=$1
    local field=$2
    local value=$3
    
    case $field in
        password)
            echo "$user:$value" | chpasswd
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$2=v} 1' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
            ;;
        max_ips)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$3=v} 1' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
            ;;
        used_ips)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$4=v} 1' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
            ;;
        expiry)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$5=v} 1' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
            ;;
        status)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$6=v} 1' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
            if [[ "$value" == "disabled" ]]; then
                pkill -KILL -u "$user" 2>/dev/null
                usermod -L "$user" 2>/dev/null
            else
                usermod -U "$user" 2>/dev/null
            fi
            ;;
        last_login)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$8=v} 1' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
            ;;
    esac
}

# 1. Create new user
create_user() {
    show_header
    echo "┌──────────────────────────────────────┐"
    echo "│        CREATE NEW USER               │"
    echo "├──────────────────────────────────────┤"
    
    read -p "Enter username: " username
    
    if [[ -z "$username" ]]; then
        echo -e "${RED}Username cannot be empty!${NC}"
        sleep 2
        return
    fi
    
    if user_exists "$username"; then
        echo -e "${RED}User '$username' already exists!${NC}"
        sleep 2
        return
    fi
    
    # Generate password
    password=$(generate_password)
    
    # Get IP limit
    read -p "Max IPs allowed (default: 2): " max_ips
    max_ips=${max_ips:-2}
    
    # Get expiry days
    read -p "Expiry days (0=never, default: 30): " expiry_days
    expiry_days=${expiry_days:-30}
    
    if [[ $expiry_days -eq 0 ]]; then
        expiry_date="never"
    else
        expiry_date=$(date -d "+${expiry_days} days" '+%Y-%m-%d')
    fi
    
    # Create system user
    if useradd -m -s /bin/bash "$username" 2>/dev/null; then
        echo "$username:$password" | chpasswd
        chage -d 0 "$username" 2>/dev/null
        
        # Hash password for database
        password_hash=$(hash_password "$password")
        
        # Add to database
        created_date=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$username:$password_hash:$max_ips:0:$expiry_date:active:$created_date:never" >> "$DB_FILE"
        
        # Create IP history file
        touch "$IP_HISTORY_DIR/$username.db"
        
        # Create user info file
        cat > "/home/$username/user_info.txt" << EOF
==========================================
        ACCOUNT INFORMATION
==========================================
Username: $username
Password: $password
Created: $created_date
Expiry: $expiry_date
Max IPs: $max_ips
==========================================
NOTES:
1. Account auto-deletes if > $max_ips IPs used
2. Expires on: $expiry_date
==========================================
EOF
        chown "$username:$username" "/home/$username/user_info.txt"
        chmod 600 "/home/$username/user_info.txt"
        
        log_action "Created user: $username (Max IPs: $max_ips, Expiry: $expiry_date)"
        
        echo ""
        echo "┌──────────────────────────────────────┐"
        echo -e "│  ${GREEN}✓ User created successfully!${NC}        │"
        echo "├──────────────────────────────────────┤"
        echo -e "  Username: ${GREEN}$username${NC}"
        echo -e "  Password: ${GREEN}$password${NC}"
        echo -e "  Max IPs:  ${GREEN}$max_ips${NC}"
        echo -e "  Expiry:   ${GREEN}$expiry_date${NC}"
        echo "└──────────────────────────────────────┘"
        
    else
        echo -e "${RED}Failed to create user!${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# 2. Show online users
show_online() {
    show_header
    echo "┌──────────────────────────────────────┐"
    echo "│     ONLINE USERS & USAGE             │"
    echo "├──────────────────────────────────────┤"
    
    echo -e "${YELLOW}Active Connections:${NC}"
    echo "--------------------------------------"
    who | while read -r user tty date time ip; do
        if [[ "$user" != "root" ]]; then
            clean_ip=$(echo "$ip" | tr -d '()' | cut -d':' -f1)
            echo -e "  ${GREEN}$user${NC} from ${CYAN}$clean_ip${NC}"
        fi
    done
    
    echo ""
    echo -e "${YELLOW}User IP Usage:${NC}"
    echo "--------------------------------------"
    
    if [[ -f "$DB_FILE" ]]; then
        while IFS=: read -r user pass max used expiry status created last; do
            [[ "$user" == "#"* ]] && continue
            [[ -z "$user" ]] && continue
            
            if [[ $used -ge $max ]]; then
                color="${RED}"
            elif [[ $used -ge $((max/2)) ]]; then
                color="${YELLOW}"
            else
                color="${GREEN}"
            fi
            
            echo -e "  ${WHITE}$user${NC}: ${color}$used${NC}/${color}$max${NC} IPs used"
        done < <(grep -v "^#" "$DB_FILE" 2>/dev/null)
    fi
    
    echo "└──────────────────────────────────────┘"
    echo ""
    read -p "Press Enter to continue..."
}

# 3. Delete user
delete_user() {
    show_header
    echo "┌──────────────────────────────────────┐"
    echo "│         DELETE USER                  │"
    echo "├──────────────────────────────────────┤"
    
    read -p "Enter username to delete: " username
    
    if [[ -z "$username" ]]; then
        echo -e "${RED}Username cannot be empty!${NC}"
        sleep 2
        return
    fi
    
    if ! user_exists "$username"; then
        echo -e "${RED}User '$username' not found!${NC}"
        sleep 2
        return
    fi
    
    read -p "Are you sure you want to delete '$username'? (y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Kill all user processes
        pkill -9 -u "$username" 2>/dev/null
        
        # Delete system user
        userdel -r "$username" 2>/dev/null
        
        # Remove from database
        sed -i "/^$username:/d" "$DB_FILE" 2>/dev/null
        
        # Remove IP history
        rm -f "$IP_HISTORY_DIR/$username.db" 2>/dev/null
        
        log_action "Deleted user: $username"
        
        echo -e "${GREEN}User '$username' deleted successfully!${NC}"
    else
        echo -e "${YELLOW}Deletion cancelled.${NC}"
    fi
    
    sleep 2
}

# 4. Update user data
update_user() {
    show_header
    echo "┌──────────────────────────────────────┐"
    echo "│       UPDATE USER DATA               │"
    echo "├──────────────────────────────────────┤"
    
    read -p "Enter username to update: " username
    
    if [[ -z "$username" ]]; then
        echo -e "${RED}Username cannot be empty!${NC}"
        sleep 2
        return
    fi
    
    if ! user_exists "$username"; then
        echo -e "${RED}User '$username' not found!${NC}"
        sleep 2
        return
    fi
    
    # Get current user info
    user_info=$(get_user_info "$username")
    IFS=':' read -r user pass_hash max_ips used_ips expiry status created last_login <<< "$user_info"
    
    while true; do
        show_header
        echo "┌──────────────────────────────────────┐"
        echo "│   Update User: $username               │"
        echo "├──────────────────────────────────────┤"
        echo "  1. Change Password"
        echo "  2. Update Max IPs (Current: $max_ips)"
        echo "  3. Update Expiry (Current: $expiry)"
        echo "  4. Reset IP Count (Current: $used_ips)"
        echo "  0. Back to Main Menu"
        echo "└──────────────────────────────────────┘"
        echo ""
        
        read -p "Select option (0-4): " update_choice
        
        case $update_choice in
            1)
                echo ""
                read -s -p "Enter new password: " new_pass
                echo ""
                if [[ -n "$new_pass" ]]; then
                    echo "$username:$new_pass" | chpasswd
                    new_hash=$(hash_password "$new_pass")
                    update_user_field "$username" "password" "$new_hash"
                    echo -e "${GREEN}Password updated!${NC}"
                    sleep 1
                fi
                ;;
            2)
                echo ""
                read -p "Enter new max IPs: " new_max
                if [[ "$new_max" =~ ^[0-9]+$ ]] && [[ $new_max -gt 0 ]]; then
                    update_user_field "$username" "max_ips" "$new_max"
                    max_ips=$new_max
                    echo -e "${GREEN}Max IPs updated to $new_max!${NC}"
                    sleep 1
                else
                    echo -e "${RED}Invalid number!${NC}"
                    sleep 1
                fi
                ;;
            3)
                echo ""
                echo "1. Set number of days from today"
                echo "2. Set specific date (YYYY-MM-DD)"
                echo "3. Never expire"
                read -p "Select option: " expiry_opt
                
                case $expiry_opt in
                    1)
                        read -p "Enter days: " days
                        if [[ "$days" =~ ^[0-9]+$ ]]; then
                            new_expiry=$(date -d "+${days} days" '+%Y-%m-%d')
                            update_user_field "$username" "expiry" "$new_expiry"
                            expiry=$new_expiry
                            echo -e "${GREEN}Expiry set to $new_expiry!${NC}"
                        fi
                        ;;
                    2)
                        read -p "Enter date (YYYY-MM-DD): " new_expiry
                        if date -d "$new_expiry" >/dev/null 2>&1; then
                            update_user_field "$username" "expiry" "$new_expiry"
                            expiry=$new_expiry
                            echo -e "${GREEN}Expiry set to $new_expiry!${NC}"
                        else
                            echo -e "${RED}Invalid date format!${NC}"
                        fi
                        ;;
                    3)
                        update_user_field "$username" "expiry" "never"
                        expiry="never"
                        echo -e "${GREEN}Account set to never expire!${NC}"
                        ;;
                esac
                sleep 1
                ;;
            4)
                update_user_field "$username" "used_ips" "0"
                > "$IP_HISTORY_DIR/$username.db"
                used_ips=0
                echo -e "${GREEN}IP count reset to 0!${NC}"
                sleep 1
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

# 5. Disable/enable user
toggle_user() {
    show_header
    echo "┌──────────────────────────────────────┐"
    echo "│    DISABLE/ENABLE USER               │"
    echo "├──────────────────────────────────────┤"
    
    read -p "Enter username: " username
    
    if [[ -z "$username" ]]; then
        echo -e "${RED}Username cannot be empty!${NC}"
        sleep 2
        return
    fi
    
    if ! user_exists "$username"; then
        echo -e "${RED}User '$username' not found!${NC}"
        sleep 2
        return
    fi
    
    user_info=$(get_user_info "$username")
    current_status=$(echo "$user_info" | cut -d: -f6)
    
    if [[ "$current_status" == "active" ]]; then
        echo -e "Current status: ${GREEN}ACTIVE${NC}"
        read -p "Disable this user? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            update_user_field "$username" "status" "disabled"
            echo -e "${RED}User '$username' DISABLED!${NC}"
        fi
    else
        echo -e "Current status: ${RED}DISABLED${NC}"
        read -p "Enable this user? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            update_user_field "$username" "status" "active"
            echo -e "${GREEN}User '$username' ENABLED!${NC}"
        fi
    fi
    
    sleep 2
}

# 6. View all users
view_all_users() {
    show_header
    echo "┌──────────────────────────────────────┐"
    echo "│         ALL USERS                    │"
    echo "├──────────────────────────────────────┤"
    
    if [[ ! -f "$DB_FILE" ]]; then
        echo -e "${YELLOW}No users found${NC}"
        echo "└──────────────────────────────────────┘"
        echo ""
        read -p "Press Enter to continue..."
        return
    fi
    
    total_users=$(grep -c '^[^#]' "$DB_FILE" 2>/dev/null || echo "0")
    
    if [[ $total_users -eq 0 ]]; then
        echo -e "${YELLOW}No users found${NC}"
    else
        echo "Username    Status   IPs   Expiry"
        echo "--------------------------------------"
        
        while IFS=: read -r user pass_hash max_ips used_ips expiry status created last; do
            [[ "$user" == "#"* ]] && continue
            [[ -z "$user" ]] && continue
            
            # Status color
            if [[ "$status" == "active" ]]; then
                status_disp="${GREEN}ACTIVE${NC}"
            else
                status_disp="${RED}DISABL${NC}"
            fi
            
            # IP usage color
            if [[ $used_ips -ge $max_ips ]]; then
                ip_color="${RED}"
            elif [[ $used_ips -ge $((max_ips/2)) ]]; then
                ip_color="${YELLOW}"
            else
                ip_color="${GREEN}"
            fi
            
            # Truncate expiry
            expiry_disp="${expiry:0:10}"
            if [[ "$expiry" == "never" ]]; then
                expiry_disp="never"
            fi
            
            printf "%-10s %-8b %-6b %-10s\n" "$user" "$status_disp" "$ip_color$used_ips/$max_ips${NC}" "$expiry_disp"
        done < <(grep -v "^#" "$DB_FILE" 2>/dev/null | sort)
        
        echo ""
        echo -e "Total users: ${GREEN}$total_users${NC}"
    fi
    
    echo "└──────────────────────────────────────┘"
    echo ""
    read -p "Press Enter to continue..."
}

# 7. System status
system_status() {
    show_header
    echo "┌──────────────────────────────────────┐"
    echo "│        SYSTEM STATUS                 │"
    echo "├──────────────────────────────────────┤"
    
    # Monitor status
    if [[ -f "$MONITOR_PID" ]] && kill -0 $(cat "$MONITOR_PID") 2>/dev/null; then
        monitor_status="${GREEN}RUNNING ✓${NC}"
    else
        monitor_status="${RED}STOPPED ✗${NC}"
    fi
    
    # Database status
    if [[ -f "$DB_FILE" ]]; then
        db_size=$(ls -lh "$DB_FILE" 2>/dev/null | awk '{print $5}' || echo "0B")
        db_status="${GREEN}OK ($db_size) ✓${NC}"
    else
        db_status="${RED}MISSING ✗${NC}"
    fi
    
    # User counts
    if [[ -f "$DB_FILE" ]]; then
        total_users=$(grep -c '^[^#]' "$DB_FILE" 2>/dev/null || echo "0")
        active_users=$(grep -c ':active:' "$DB_FILE" 2>/dev/null || echo "0")
    else
        total_users=0
        active_users=0
    fi
    
    online_count=$(who | grep -v root | wc -l)
    
    echo -e "Monitor Daemon:   $monitor_status"
    echo -e "Database:         $db_status"
    echo -e "Total Users:      ${GREEN}$total_users${NC}"
    echo -e "Active Users:     ${GREEN}$active_users${NC}"
    echo -e "Online Now:       ${CYAN}$online_count${NC}"
    
    echo ""
    echo -e "${YELLOW}Recent Activities:${NC}"
    echo "--------------------------------------"
    
    if [[ -f "$LOG_FILE" ]]; then
        tail -5 "$LOG_FILE" 2>/dev/null || echo "No logs"
    else
        echo "No logs yet"
    fi
    
    echo "└──────────────────────────────────────┘"
    echo ""
    read -p "Press Enter to continue..."
}

# IP Monitor daemon (simplified)
start_ip_monitor() {
    if [[ -f "$MONITOR_PID" ]] && kill -0 $(cat "$MONITOR_PID") 2>/dev/null; then
        return
    fi
    
    # Start monitor in background
    (
        while true; do
            if [[ -f "$DB_FILE" ]]; then
                while IFS=: read -r username pass_hash max_ips used_ips expiry status created last; do
                    [[ "$username" == "#"* ]] && continue
                    [[ -z "$username" ]] && continue
                    
                    # Skip disabled users
                    [[ "$status" != "active" ]] && continue
                    
                    # Check expiry
                    if [[ "$expiry" != "never" ]]; then
                        if [[ $(date +%s) -gt $(date -d "$expiry" +%s) 2>/dev/null ]]; then
                            # User expired - delete
                            pkill -9 -u "$username" 2>/dev/null
                            userdel -r "$username" 2>/dev/null
                            sed -i "/^$username:/d" "$DB_FILE" 2>/dev/null
                            rm -f "$IP_HISTORY_DIR/$username.db" 2>/dev/null
                            log_action "User $username expired and deleted"
                            continue
                        fi
                    fi
                    
                    # Check current connections for this user
                    who | grep "^$username " | while read -r line; do
                        ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')
                        [[ -z "$ip" ]] && continue
                        
                        # Update last login
                        update_user_field "$username" "last_login" "$(date '+%Y-%m-%d %H:%M:%S')"
                        
                        # Check IP history
                        ip_file="$IP_HISTORY_DIR/$username.db"
                        if ! grep -q "^$ip$" "$ip_file" 2>/dev/null; then
                            # New IP
                            echo "$ip" >> "$ip_file"
                            new_count=$((used_ips + 1))
                            update_user_field "$username" "used_ips" "$new_count"
                            
                            log_action "User $username new IP: $ip ($new_count/$max_ips)"
                            
                            # Check if exceeded limit
                            if [[ $new_count -gt $max_ips ]]; then
                                pkill -9 -u "$username" 2>/dev/null
                                userdel -r "$username" 2>/dev/null
                                sed -i "/^$username:/d" "$DB_FILE" 2>/dev/null
                                rm -f "$ip_file"
                                log_action "User $username deleted: Exceeded IP limit ($new_count/$max_ips)"
                            fi
                        fi
                    done
                done < <(grep -v "^#" "$DB_FILE" 2>/dev/null)
            fi
            
            sleep 10
        done
    ) &
    
    echo $! > "$MONITOR_PID"
}

# Stop monitor
stop_ip_monitor() {
    if [[ -f "$MONITOR_PID" ]]; then
        kill $(cat "$MONITOR_PID") 2>/dev/null
        rm -f "$MONITOR_PID"
    fi
}

# Main function
main() {
    # Initialize
    init_database
    start_ip_monitor
    
    # Trap exit to stop monitor
    trap 'stop_ip_monitor' EXIT
    
    while true; do
        show_header
        show_menu
        
        echo -n "Select option (0-7): "
        read choice
        
        case $choice in
            1) create_user ;;
            2) show_online ;;
            3) delete_user ;;
            4) update_user ;;
            5) toggle_user ;;
            6) view_all_users ;;
            7) system_status ;;
            0)
                echo ""
                echo -e "${GREEN}Goodbye!${NC}"
                echo ""
                stop_ip_monitor
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option! Press Enter to try again...${NC}"
                read
                ;;
        esac
    done
}

# Run main function
main
EOF

# Make the admin command executable
chmod +x /usr/local/bin/admin

# Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/admin-monitor.service << 'EOF'
[Unit]
Description=Admin IP Monitor Daemon
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/admin --monitor
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

# Create log rotation
echo "Setting up log rotation..."
cat > /etc/logrotate.d/admin-system << 'EOF'
/var/log/admin_system/*.log {
    daily
    missingok
    rotate 7
    compress
    notifempty
    create 640 root root
}
EOF

# Add alias to bashrc
echo "Adding alias to bash profiles..."
if ! grep -q "alias admin=" /root/.bashrc 2>/dev/null; then
    echo "alias admin='/usr/local/bin/admin'" >> /root/.bashrc
fi

# Add to global bashrc
if ! grep -q "alias admin=" /etc/bash.bashrc 2>/dev/null; then
    echo "alias admin='/usr/local/bin/admin'" >> /etc/bash.bashrc
fi

# Create uninstall script
echo "Creating uninstall script..."
cat > /usr/local/bin/uninstall-admin << 'EOF'
#!/bin/bash
echo "=== Uninstalling Admin System ==="

# Stop services
systemctl stop admin-monitor.service 2>/dev/null
systemctl disable admin-monitor.service 2>/dev/null

# Remove files
rm -f /usr/local/bin/admin
rm -f /usr/local/bin/uninstall-admin
rm -f /etc/systemd/system/admin-monitor.service
rm -f /etc/logrotate.d/admin-system
rm -rf /var/lib/admin_system
rm -rf /var/log/admin_system

# Remove aliases
sed -i '/alias admin=/d' /root/.bashrc 2>/dev/null
sed -i '/alias admin=/d' /etc/bash.bashrc 2>/dev/null

systemctl daemon-reload
echo "Admin System has been uninstalled."
echo "Type: source ~/.bashrc  (if needed)"
EOF

chmod +x /usr/local/bin/uninstall-admin

# Enable and start services
echo "Enabling services..."
systemctl daemon-reload
systemctl enable admin-monitor.service
systemctl start admin-monitor.service

echo ""
echo -e "${GREEN}=== Installation Complete! ==="
echo ""
echo "╔══════════════════════════════════════╗"
echo "║    ADMIN SYSTEM INSTALLED!           ║"
echo "║                                      ║"
echo "║    Type 'admin' to start managing    ║"
echo "║    users with IP restrictions.       ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo -e "${CYAN}Quick Commands:${NC}"
echo "  • Type ${GREEN}admin${NC} to start the menu"
echo "  • ${GREEN}admin --status${NC} for system status"
echo "  • ${GREEN}admin --list${NC} to list all users"
echo ""
echo -e "${YELLOW}The IP monitor runs automatically in background.${NC}"
echo -e "${YELLOW}Just type 'admin' anywhere in your VPS!${NC}"
echo ""

# Test the command
echo "Testing 'admin' command..."
if type admin &>/dev/null; then
    echo -e "${GREEN}✓ 'admin' command is working!${NC}"
    echo ""
    echo -e "${YELLOW}Would you like to start the admin system now? (y/N):${NC}"
    read -n 1 start_now
    echo ""
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        echo "Starting admin system..."
        admin
    fi
else
    echo -e "${RED}✗ 'admin' command not found. Please restart your shell.${NC}"
    echo "Try: source ~/.bashrc"
fi
