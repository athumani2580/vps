#!/bin/bash
# save as: install_admin_final.sh

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

# Create the main admin script
echo "Creating main admin script..."
cat > /usr/local/bin/admin << 'EOF'
#!/bin/bash
# Admin User Management System - Final Working Version

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
NC='\033[0m'

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
    echo "=========================================="
    echo "    USER IP MANAGEMENT SYSTEM"
    echo "         $(date '+%Y-%m-%d %H:%M')"
    echo "=========================================="
    echo ""
}

# Display menu
show_menu() {
    echo "------------- MAIN MENU --------------"
    echo "  1. Create New User"
    echo "  2. Show Online Users & Usage"
    echo "  3. Delete User"
    echo "  4. Update User Data"
    echo "  5. Disable/Enable User"
    echo "  6. View All Users"
    echo "  7. System Status"
    echo "  0. Exit"
    echo "--------------------------------------"
    echo ""
}

# Generate random password
generate_password() {
    openssl rand -base64 12 | tr -d '/+=' | head -c 12
}

# Hash password
hash_password() {
    openssl passwd -1 "$1" 2>/dev/null || echo ""
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
    
    if [[ ! -f "$DB_FILE" ]]; then
        return
    fi
    
    case $field in
        password)
            echo "$user:$value" | chpasswd 2>/dev/null
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$2=v} 1' "$DB_FILE" > "${DB_FILE}.tmp"
            ;;
        max_ips)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$3=v} 1' "$DB_FILE" > "${DB_FILE}.tmp"
            ;;
        used_ips)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$4=v} 1' "$DB_FILE" > "${DB_FILE}.tmp"
            ;;
        expiry)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$5=v} 1' "$DB_FILE" > "${DB_FILE}.tmp"
            ;;
        status)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$6=v} 1' "$DB_FILE" > "${DB_FILE}.tmp"
            if [[ "$value" == "disabled" ]]; then
                pkill -KILL -u "$user" 2>/dev/null
                usermod -L "$user" 2>/dev/null
            else
                usermod -U "$user" 2>/dev/null
            fi
            ;;
        last_login)
            awk -F: -v u="$user" -v v="$value" 'BEGIN{OFS=":"} $1==u {$8=v} 1' "$DB_FILE" > "${DB_FILE}.tmp"
            ;;
    esac
    
    if [[ -f "${DB_FILE}.tmp" ]]; then
        mv "${DB_FILE}.tmp" "$DB_FILE"
    fi
}

# 1. Create new user
create_user() {
    show_header
    echo "----- CREATE NEW USER -----"
    
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
        expiry_date=$(date -d "+${expiry_days} days" '+%Y-%m-%d' 2>/dev/null || echo "never")
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
        mkdir -p "$IP_HISTORY_DIR"
        touch "$IP_HISTORY_DIR/$username.db"
        
        # Create user info file
        if [[ -d "/home/$username" ]]; then
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
            chown "$username:$username" "/home/$username/user_info.txt" 2>/dev/null
            chmod 600 "/home/$username/user_info.txt" 2>/dev/null
        fi
        
        # Log action
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Created user: $username (Max IPs: $max_ips, Expiry: $expiry_date)" >> "$LOG_FILE"
        
        echo ""
        echo "----- USER CREATED -----"
        echo -e "Username: ${GREEN}$username${NC}"
        echo -e "Password: ${GREEN}$password${NC}"
        echo -e "Max IPs:  ${GREEN}$max_ips${NC}"
        echo -e "Expiry:   ${GREEN}$expiry_date${NC}"
        echo "------------------------"
        
    else
        echo -e "${RED}Failed to create user!${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# 2. Show online users
show_online() {
    show_header
    echo "----- ONLINE USERS -----"
    
    echo "Active Connections:"
    echo "-------------------"
    online_found=0
    who | while read -r user tty date time ip; do
        if [[ "$user" != "root" ]]; then
            clean_ip=$(echo "$ip" | tr -d '()' | cut -d':' -f1)
            echo -e "  ${GREEN}$user${NC} from ${CYAN}$clean_ip${NC}"
            online_found=1
        fi
    done
    
    if [[ $online_found -eq 0 ]]; then
        echo "  No users online"
    fi
    
    echo ""
    echo "IP Usage:"
    echo "---------"
    
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
            
            echo -e "  $user: ${color}$used${NC}/${color}$max${NC} IPs"
        done < <(grep -v "^#" "$DB_FILE" 2>/dev/null)
    else
        echo "  No users in database"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# 3. Delete user
delete_user() {
    show_header
    echo "----- DELETE USER -----"
    
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
    
    read -p "Delete user '$username' and all data? (y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Kill user processes
        pkill -9 -u "$username" 2>/dev/null
        
        # Delete system user
        userdel -r "$username" 2>/dev/null
        
        # Remove from database
        sed -i "/^$username:/d" "$DB_FILE" 2>/dev/null
        
        # Remove IP history
        rm -f "$IP_HISTORY_DIR/$username.db" 2>/dev/null
        
        # Log action
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleted user: $username" >> "$LOG_FILE"
        
        echo -e "${GREEN}User '$username' deleted!${NC}"
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
    
    sleep 2
}

# 4. Update user data
update_user() {
    show_header
    echo "----- UPDATE USER -----"
    
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
        echo "----- UPDATE USER: $username -----"
        echo "  1. Change Password"
        echo "  2. Update Max IPs (Current: $max_ips)"
        echo "  3. Update Expiry (Current: $expiry)"
        echo "  4. Reset IP Count (Current: $used_ips)"
        echo "  0. Back to Main Menu"
        echo ""
        
        read -p "Select option: " update_choice
        
        case $update_choice in
            1)
                echo ""
                read -s -p "Enter new password: " new_pass
                echo ""
                if [[ -n "$new_pass" ]]; then
                    echo "$username:$new_pass" | chpasswd 2>/dev/null
                    new_hash=$(hash_password "$new_pass")
                    update_user_field "$username" "password" "$new_hash"
                    echo -e "${GREEN}Password updated!${NC}"
                else
                    echo -e "${RED}Password cannot be empty!${NC}"
                fi
                sleep 1
                ;;
            2)
                echo ""
                read -p "Enter new max IPs: " new_max
                if [[ "$new_max" =~ ^[0-9]+$ ]] && [[ $new_max -gt 0 ]]; then
                    update_user_field "$username" "max_ips" "$new_max"
                    max_ips=$new_max
                    echo -e "${GREEN}Max IPs updated!${NC}"
                else
                    echo -e "${RED}Invalid number!${NC}"
                fi
                sleep 1
                ;;
            3)
                echo ""
                echo "Expiry options:"
                echo "  1. Set days from today"
                echo "  2. Set date (YYYY-MM-DD)"
                echo "  3. Never expire"
                read -p "Select: " expiry_opt
                
                case $expiry_opt in
                    1)
                        read -p "Enter days: " days
                        if [[ "$days" =~ ^[0-9]+$ ]]; then
                            new_expiry=$(date -d "+${days} days" '+%Y-%m-%d' 2>/dev/null || echo "never")
                            update_user_field "$username" "expiry" "$new_expiry"
                            expiry=$new_expiry
                            echo -e "${GREEN}Expiry updated!${NC}"
                        fi
                        ;;
                    2)
                        read -p "Enter date (YYYY-MM-DD): " new_expiry
                        if date -d "$new_expiry" >/dev/null 2>&1; then
                            update_user_field "$username" "expiry" "$new_expiry"
                            expiry=$new_expiry
                            echo -e "${GREEN}Expiry updated!${NC}"
                        else
                            echo -e "${RED}Invalid date!${NC}"
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
                > "$IP_HISTORY_DIR/$username.db" 2>/dev/null
                used_ips=0
                echo -e "${GREEN}IP count reset!${NC}"
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
    echo "----- DISABLE/ENABLE USER -----"
    
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
        echo -e "Status: ${GREEN}ACTIVE${NC}"
        read -p "Disable this user? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            update_user_field "$username" "status" "disabled"
            echo -e "${RED}User disabled!${NC}"
        fi
    else
        echo -e "Status: ${RED}DISABLED${NC}"
        read -p "Enable this user? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            update_user_field "$username" "status" "active"
            echo -e "${GREEN}User enabled!${NC}"
        fi
    fi
    
    sleep 2
}

# 6. View all users
view_all_users() {
    show_header
    echo "----- ALL USERS -----"
    
    if [[ ! -f "$DB_FILE" ]]; then
        echo -e "${YELLOW}No users found${NC}"
        echo ""
        read -p "Press Enter to continue..."
        return
    fi
    
    total_users=$(grep -c '^[^#]' "$DB_FILE" 2>/dev/null || echo "0")
    
    if [[ $total_users -eq 0 ]]; then
        echo -e "${YELLOW}No users found${NC}"
    else
        echo "Username    Status    IPs    Expiry"
        echo "-----------------------------------"
        
        while IFS=: read -r user pass_hash max_ips used_ips expiry status created last; do
            [[ "$user" == "#"* ]] && continue
            [[ -z "$user" ]] && continue
            
            # Status
            if [[ "$status" == "active" ]]; then
                status_disp="${GREEN}ACTIVE${NC}"
            else
                status_disp="${RED}DISABLED${NC}"
            fi
            
            # IP color
            if [[ $used_ips -ge $max_ips ]]; then
                ip_color="${RED}"
            elif [[ $used_ips -ge $((max_ips/2)) ]]; then
                ip_color="${YELLOW}"
            else
                ip_color="${GREEN}"
            fi
            
            echo -e "$user     $status_disp     ${ip_color}$used_ips/$max_ips${NC}     $expiry"
        done < <(grep -v "^#" "$DB_FILE" 2>/dev/null | sort)
        
        echo ""
        echo -e "Total users: ${GREEN}$total_users${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# 7. System status
system_status() {
    show_header
    echo "----- SYSTEM STATUS -----"
    
    # Monitor status
    if [[ -f "$MONITOR_PID" ]] && kill -0 $(cat "$MONITOR_PID") 2>/dev/null; then
        echo -e "Monitor: ${GREEN}RUNNING${NC}"
    else
        echo -e "Monitor: ${RED}STOPPED${NC}"
    fi
    
    # Database status
    if [[ -f "$DB_FILE" ]]; then
        echo -e "Database: ${GREEN}OK${NC}"
        total_users=$(grep -c '^[^#]' "$DB_FILE" 2>/dev/null || echo "0")
        active_users=$(grep -c ':active:' "$DB_FILE" 2>/dev/null || echo "0")
    else
        echo -e "Database: ${RED}MISSING${NC}"
        total_users=0
        active_users=0
    fi
    
    online_count=$(who | grep -v root | wc -l)
    
    echo -e "Total users: $total_users"
    echo -e "Active users: $active_users"
    echo -e "Online now: $online_count"
    
    echo ""
    echo "Recent logs:"
    echo "-----------"
    if [[ -f "$LOG_FILE" ]]; then
        tail -5 "$LOG_FILE" 2>/dev/null || echo "No logs"
    else
        echo "No log file"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# IP Monitor daemon
start_ip_monitor() {
    if [[ -f "$MONITOR_PID" ]] && kill -0 $(cat "$MONITOR_PID") 2>/dev/null; then
        return
    fi
    
    (
        while true; do
            if [[ -f "$DB_FILE" ]]; then
                while IFS=: read -r username pass_hash max_ips used_ips expiry status created last; do
                    [[ "$username" == "#"* ]] && continue
                    [[ -z "$username" ]] && continue
                    
                    # Skip disabled
                    [[ "$status" != "active" ]] && continue
                    
                    # Check expiry
                    if [[ "$expiry" != "never" ]]; then
                        if [[ $(date +%s) -gt $(date -d "$expiry" +%s) 2>/dev/null ]]; then
                            pkill -9 -u "$username" 2>/dev/null
                            userdel -r "$username" 2>/dev/null
                            sed -i "/^$username:/d" "$DB_FILE" 2>/dev/null
                            rm -f "$IP_HISTORY_DIR/$username.db" 2>/dev/null
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] User $username expired" >> "$LOG_FILE"
                            continue
                        fi
                    fi
                    
                    # Check connections
                    who | grep "^$username " | while read -r line; do
                        ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')
                        [[ -z "$ip" ]] && continue
                        
                        # Update last login
                        update_user_field "$username" "last_login" "$(date '+%Y-%m-%d %H:%M:%S')"
                        
                        # Check IP
                        ip_file="$IP_HISTORY_DIR/$username.db"
                        if ! grep -q "^$ip$" "$ip_file" 2>/dev/null; then
                            echo "$ip" >> "$ip_file"
                            new_count=$((used_ips + 1))
                            update_user_field "$username" "used_ips" "$new_count"
                            
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $username from $ip ($new_count/$max_ips)" >> "$LOG_FILE"
                            
                            if [[ $new_count -gt $max_ips ]]; then
                                pkill -9 -u "$username" 2>/dev/null
                                userdel -r "$username" 2>/dev/null
                                sed -i "/^$username:/d" "$DB_FILE" 2>/dev/null
                                rm -f "$ip_file"
                                echo "[$(date '+%Y-%m-%d %H:%M:%S')] $username deleted (exceeded $max_ips IPs)" >> "$LOG_FILE"
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
                echo "Goodbye!"
                stop_ip_monitor
                exit 0
                ;;
            *)
                echo "Invalid option!"
                sleep 1
                ;;
        esac
    done
}

# Start
main
EOF

# Make the admin command executable
chmod 755 /usr/local/bin/admin

# Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/admin-monitor.service << 'EOF'
[Unit]
Description=Admin IP Monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c "while true; do sleep 10; done"
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# Add alias
echo "Adding alias..."
echo "alias admin='/usr/local/bin/admin'" >> /root/.bashrc
source /root/.bashrc

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo ""
echo "Type 'admin' to start the user management system!"
echo ""
echo "Features:"
echo "1. Create users with IP limits"
echo "2. Monitor online users"
echo "3. Auto-delete when IP limit exceeded"
echo "4. Set account expiry"
echo "5. All options return to main menu"
echo ""
