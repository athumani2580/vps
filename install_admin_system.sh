#!/bin/bash
# save as: install_admin_system.sh

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
mkdir -p /usr/local/share/admin_system

# Create the main admin script
echo "Creating main admin script..."
cat > /usr/local/bin/admin << 'EOF'
#!/bin/bash
# Admin User Management System - Auto-starts when typing 'admin'

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
CONFIG_FILE="/etc/admin_system.conf"

# Colors for beautiful interface
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Box drawing characters
BOX_TOP_L="╔"
BOX_TOP_R="╗"
BOX_BOTTOM_L="╚"
BOX_BOTTOM_R="╝"
BOX_HORIZ="═"
BOX_VERT="║"
BOX_MENU_TOP_L="┌"
BOX_MENU_TOP_R="┐"
BOX_MENU_BOTTOM_L="└"
BOX_MENU_BOTTOM_R="┘"
BOX_MENU_HORIZ="─"
BOX_MENU_VERT="│"

# Initialize database
init_database() {
    if [[ ! -f "$DB_FILE" ]]; then
        echo "# username:password_hash:max_ips:used_ips:expiry_date:status:created:last_login" > "$DB_FILE"
        mkdir -p "$IP_HISTORY_DIR"
        chmod 600 "$DB_FILE"
        echo "Database initialized."
    fi
}

# Log actions
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Display header
show_header() {
    clear
    width=38
    date_str=$(date '+%Y-%m-%d %H:%M')
    
    # Calculate padding for date
    date_pad=$((width - ${#date_str} - 2))
    
    echo -e "${PURPLE}${BOX_TOP_L}$(printf '%*s' $width | tr ' ' ${BOX_HORIZ})${BOX_TOP_R}${NC}"
    echo -e "${PURPLE}${BOX_VERT}    USER IP MANAGEMENT SYSTEM         ${BOX_VERT}${NC}"
    echo -e "${PURPLE}${BOX_VERT}         ${date_str}$(printf '%*s' $date_pad ' ')${BOX_VERT}${NC}"
    echo -e "${PURPLE}${BOX_BOTTOM_L}$(printf '%*s' $width | tr ' ' ${BOX_HORIZ})${BOX_BOTTOM_R}${NC}"
    echo ""
}

# Display menu
show_menu() {
    echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}           MAIN MENU                  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}1.${NC} Create New User               ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}2.${NC} Show Online Users & Usage     ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}3.${NC} Delete User                   ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}4.${NC} Update User Data              ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}5.${NC} Disable/Enable User           ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${BLUE}6.${NC} View All Users                ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${YELLOW}7.${NC} System Status                ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}0.${NC} Exit                         ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
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
    
    [[ -f "${DB_FILE}.tmp" ]] && mv "${DB_FILE}.tmp" "$DB_FILE"
}

# Create new user
create_user() {
    while true; do
        show_header
        echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}        CREATE NEW USER             ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
        
        read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Enter username: ${NC}")" username
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        
        if [[ -z "$username" ]]; then
            echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Username cannot be empty!      ${BOX_MENU_VERT}${NC}"
            echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
            sleep 2
            continue
        fi
        
        if user_exists "$username"; then
            echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}User '$username' already exists!${BOX_MENU_VERT}${NC}"
            echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
            sleep 2
            continue
        fi
        
        break
    done
    
    # Generate password
    password=$(generate_password)
    password_hash=$(hash_password "$password")
    
    # Get IP limit
    while true; do
        read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Max IPs allowed (default: 2): ${NC}")" max_ips
        max_ips=${max_ips:-2}
        
        if [[ "$max_ips" =~ ^[0-9]+$ ]] && [[ $max_ips -gt 0 ]]; then
            break
        else
            echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Enter valid number!            ${BOX_MENU_VERT}${NC}"
        fi
    done
    
    # Get expiry days
    while true; do
        read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Expiry days (0=never): ${NC}")" expiry_days
        expiry_days=${expiry_days:-30}
        
        if [[ "$expiry_days" =~ ^[0-9]+$ ]]; then
            break
        else
            echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Enter valid number!            ${BOX_MENU_VERT}${NC}"
        fi
    done
    
    if [[ $expiry_days -eq 0 ]]; then
        expiry_date="never"
    else
        expiry_date=$(date -d "+${expiry_days} days" '+%Y-%m-%d')
    fi
    
    # Create system user
    if useradd -m -s /bin/bash "$username" 2>/dev/null; then
        echo "$username:$password" | chpasswd
        chage -d 0 "$username"  # Force password change on first login
        
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
3. Change password on first login
==========================================
EOF
        chmod 600 "/home/$username/user_info.txt"
        
        log_action "Created user: $username (Max IPs: $max_ips, Expiry: $expiry_date)"
        
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}✓ User created successfully!    ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Username: ${GREEN}$username           ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Password: ${GREEN}$password     ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Max IPs: ${GREEN}$max_ips                ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Expiry: ${GREEN}$expiry_date      ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
        
    else
        echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}✗ Failed to create user!         ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Show online users
show_online() {
    show_header
    echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}     ONLINE USERS & USAGE           ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    
    # Get online users
    online_users=$(who | grep -v root | awk '{print $1}' | sort | uniq)
    
    if [[ -z "$online_users" ]]; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${YELLOW}No users currently online        ${BOX_MENU_VERT}${NC}"
    else
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}USER            IP              ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}══════════════════════════════  ${BOX_MENU_VERT}${NC}"
        
        who | while read -r user line; do
            ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' || echo "local")
            echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}$(printf '%-14s' "$user")${WHITE}$(printf '%-16s' "$ip")${BOX_MENU_VERT}${NC}"
        done
    fi
    
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}User IP Usage:                   ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}══════════════════════════════  ${BOX_MENU_VERT}${NC}"
    
    # Show IP usage from database
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
        
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}$(printf '%-14s' "$user")${color}$(printf '%-4s' "$used")${WHITE}/${color}$max IPs     ${BOX_MENU_VERT}${NC}"
    done < <(grep -v "^#" "$DB_FILE" 2>/dev/null || true)
    
    echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
    
    echo ""
    read -p "Press Enter to continue..."
}

# Delete user
delete_user() {
    show_header
    echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}         DELETE USER                ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    
    read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Enter username to delete: ${NC}")" username
    
    if [[ -z "$username" ]]; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Username cannot be empty!      ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        sleep 2
        return
    fi
    
    if ! user_exists "$username"; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}User '$username' not found!     ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        sleep 2
        return
    fi
    
    echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
    read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Delete user '$username'? (y/N): ${NC}")" confirm
    
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
        
        echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}✓ User '$username' deleted!       ${BOX_MENU_VERT}${NC}"
    else
        echo -e "${CYAN}${BOX_MENU_VERT}  ${YELLOW}✗ Deletion cancelled             ${BOX_MENU_VERT}${NC}"
    fi
    
    echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
    
    sleep 2
}

# Update user data
update_user() {
    show_header
    echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}       UPDATE USER DATA             ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    
    read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Enter username to update: ${NC}")" username
    
    if [[ -z "$username" ]]; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Username cannot be empty!      ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        sleep 2
        return
    fi
    
    if ! user_exists "$username"; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}User '$username' not found!     ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        sleep 2
        return
    fi
    
    # Get current user info
    user_info=$(get_user_info "$username")
    IFS=':' read -r user pass_hash max_ips used_ips expiry status created last_login <<< "$user_info"
    
    while true; do
        show_header
        echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}   Update User: ${WHITE}$(printf '%-21s' "$username")${CYAN}${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}1. Change Password               ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}2. Update Max IPs (Current: ${GREEN}$max_ips${WHITE})  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}3. Update Expiry (Current: ${GREEN}$expiry${WHITE}) ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}4. Reset IP Count (Current: ${GREEN}$used_ips${WHITE}) ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}0. Back to Main Menu             ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
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
                    echo -e "${GREEN}✓ Password updated!${NC}"
                    sleep 1
                fi
                ;;
            2)
                echo ""
                read -p "Enter new max IPs: " new_max
                if [[ "$new_max" =~ ^[0-9]+$ ]] && [[ $new_max -gt 0 ]]; then
                    update_user_field "$username" "max_ips" "$new_max"
                    max_ips=$new_max
                    echo -e "${GREEN}✓ Max IPs updated to $new_max!${NC}"
                    sleep 1
                else
                    echo -e "${RED}✗ Invalid number!${NC}"
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
                            echo -e "${GREEN}✓ Expiry set to $new_expiry!${NC}"
                        fi
                        ;;
                    2)
                        read -p "Enter date (YYYY-MM-DD): " new_expiry
                        if date -d "$new_expiry" >/dev/null 2>&1; then
                            update_user_field "$username" "expiry" "$new_expiry"
                            expiry=$new_expiry
                            echo -e "${GREEN}✓ Expiry set to $new_expiry!${NC}"
                        else
                            echo -e "${RED}✗ Invalid date format!${NC}"
                        fi
                        ;;
                    3)
                        update_user_field "$username" "expiry" "never"
                        expiry="never"
                        echo -e "${GREEN}✓ Account set to never expire!${NC}"
                        ;;
                esac
                sleep 1
                ;;
            4)
                update_user_field "$username" "used_ips" "0"
                > "$IP_HISTORY_DIR/$username.db"
                used_ips=0
                echo -e "${GREEN}✓ IP count reset to 0!${NC}"
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

# Disable/enable user
toggle_user() {
    show_header
    echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}    DISABLE/ENABLE USER            ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    
    read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Enter username: ${NC}")" username
    
    if [[ -z "$username" ]]; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Username cannot be empty!      ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        sleep 2
        return
    fi
    
    if ! user_exists "$username"; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}User '$username' not found!     ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        sleep 2
        return
    fi
    
    user_info=$(get_user_info "$username")
    current_status=$(echo "$user_info" | cut -d: -f6)
    
    echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
    
    if [[ "$current_status" == "active" ]]; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Current status: ${GREEN}ACTIVE          ${BOX_MENU_VERT}${NC}"
        read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}Disable this user? (y/N): ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            update_user_field "$username" "status" "disabled"
            echo -e "${CYAN}${BOX_MENU_VERT}  ${RED}✓ User '$username' DISABLED!     ${BOX_MENU_VERT}${NC}"
        fi
    else
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Current status: ${RED}DISABLED        ${BOX_MENU_VERT}${NC}"
        read -p "$(echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}Enable this user? (y/N): ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            update_user_field "$username" "status" "active"
            echo -e "${CYAN}${BOX_MENU_VERT}  ${GREEN}✓ User '$username' ENABLED!      ${BOX_MENU_VERT}${NC}"
        fi
    fi
    
    echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
    
    sleep 2
}

# View all users
view_all_users() {
    show_header
    echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}         ALL USERS                  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    
    # Count users
    total_users=$(grep -c '^[^#]' "$DB_FILE" 2>/dev/null || echo "0")
    
    if [[ $total_users -eq 0 ]]; then
        echo -e "${CYAN}${BOX_MENU_VERT}  ${YELLOW}No users found                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
    else
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}USER       STATUS   IPS   EXPIRY  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}════════════════════════════════  ${BOX_MENU_VERT}${NC}"
        
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
            
            # Truncate expiry if too long
            expiry_disp="${expiry:0:10}"
            if [[ "$expiry" == "never" ]]; then
                expiry_disp="never"
            fi
            
            echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}$(printf '%-10s' "$user") ${status_disp}  ${ip_color}$(printf '%2s' "$used_ips")${WHITE}/${ip_color}$(printf '%2s' "$max_ips")  ${WHITE}$(printf '%-10s' "$expiry_disp") ${BOX_MENU_VERT}${NC}"
        done < <(grep -v "^#" "$DB_FILE" 2>/dev/null | sort)
        
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Total users: ${GREEN}$total_users                ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
        echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# System status
system_status() {
    show_header
    echo -e "${CYAN}${BOX_MENU_TOP_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_TOP_R}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}        SYSTEM STATUS               ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_VERT}${NC}"
    
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
    total_users=$(grep -c '^[^#]' "$DB_FILE" 2>/dev/null || echo "0")
    active_users=$(grep -c ':active:' "$DB_FILE" 2>/dev/null || echo "0")
    online_count=$(who | grep -v root | wc -l)
    
    # Disk usage
    disk_usage=$(df -h /home | tail -1 | awk '{print $5}' 2>/dev/null || echo "N/A")
    
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Monitor Daemon:   $monitor_status  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Database:         $db_status  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Total Users:      ${GREEN}$total_users${WHITE}           ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Active Users:     ${GREEN}$active_users${WHITE}           ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Online Now:       ${CYAN}$online_count${WHITE}           ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Home Disk Usage:  ${YELLOW}$disk_usage${WHITE}        ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
    
    # Recent logs
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}Recent Activities:                ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_VERT}  ${WHITE}════════════════════════════════  ${BOX_MENU_VERT}${NC}"
    
    if [[ -f "$LOG_FILE" ]]; then
        log_lines=$(tail -3 "$LOG_FILE")
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                # Truncate long lines
                if [[ ${#line} -gt 33 ]]; then
                    line="${line:0:30}..."
                fi
                echo -e "${CYAN}${BOX_MENU_VERT}  ${YELLOW}$line${WHITE}  ${BOX_MENU_VERT}${NC}"
            fi
        done <<< "$log_lines"
    else
        echo -e "${CYAN}${BOX_MENU_VERT}  ${YELLOW}No logs yet                     ${BOX_MENU_VERT}${NC}"
    fi
    
    echo -e "${CYAN}${BOX_MENU_VERT}                                  ${BOX_MENU_VERT}${NC}"
    echo -e "${CYAN}${BOX_MENU_BOTTOM_L}$(printf '%*s' 36 | tr ' ' ${BOX_MENU_HORIZ})${BOX_MENU_BOTTOM_R}${NC}"
    
    echo ""
    read -p "Press Enter to continue..."
}

# IP Monitor daemon
start_ip_monitor() {
    if [[ -f "$MONITOR_PID" ]] && kill -0 $(cat "$MONITOR_PID") 2>/dev/null; then
        return  # Already running
    fi
    
    # Start monitor in background
    (
        while true; do
            # Check each user
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
                
                # Check current connections
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
            done < <(grep -v "^#" "$DB_FILE" 2>/dev/null || true)
            
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

# Check if called with arguments
if [[ $# -gt 0 ]]; then
    case $1 in
        --help|-h)
            echo "Admin User Management System"
            echo "Usage: admin [OPTION]"
            echo ""
            echo "Options:"
            echo "  --help, -h     Show this help"
            echo "  --status       Show system status"
            echo "  --list         List all users"
            echo "  --monitor      Start IP monitor"
            echo "  --stop         Stop IP monitor"
            echo ""
            echo "With no arguments, starts the interactive menu."
            ;;
        --status)
            system_status
            ;;
        --list)
            view_all_users
            ;;
        --monitor)
            start_ip_monitor
            echo "IP monitor started."
            ;;
        --stop)
            stop_ip_monitor
            echo "IP monitor stopped."
            ;;
        *)
            echo "Unknown option: $1"
            echo "Try 'admin --help' for more information."
            ;;
    esac
else
    # Run main function
    main
fi
EOF

# Make the admin command executable
chmod +x /usr/local/bin/admin

# Create systemd service for auto-start monitor
echo "Creating systemd service for auto-start..."
cat > /etc/systemd/system/admin-monitor.service << 'EOF'
[Unit]
Description=Admin IP Monitor Daemon
After=network.target multi-user.target

[Service]
Type=forking
ExecStart=/bin/bash -c "/usr/local/bin/admin --monitor"
Restart=always
RestartSec=10
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# Create configuration file
echo "Creating configuration file..."
cat > /etc/admin_system.conf << 'EOF'
# Admin System Configuration
DEFAULT_MAX_IPS=2
DEFAULT_EXPIRY_DAYS=30
LOG_RETENTION_DAYS=7
CHECK_INTERVAL_SECONDS=10
EOF

# Create log rotation
echo "Setting up log rotation..."
cat > /etc/logrotate.d/admin-system << 'EOF'
/var/log/admin_system/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 root root
}
EOF

# Create bash completion
echo "Creating bash completion..."
cat > /etc/bash_completion.d/admin << 'EOF'
_admin_completion() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="--help --status --list --monitor --stop"

    if [[ ${cur} == -* ]] ; then
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi
}
complete -F _admin_completion admin
EOF

# Create welcome message
echo "Creating welcome message..."
cat > /usr/local/share/admin_system/welcome.txt << 'EOF'
╔══════════════════════════════════════╗
║    ADMIN SYSTEM INSTALLED!           ║
║                                      ║
║    Type 'admin' to start managing    ║
║    users with IP restrictions.       ║
╚══════════════════════════════════════╝

Features:
• Create users with IP limits
• Auto-delete when IP limit exceeded
• Set account expiry dates
• Monitor online users
• Enable/disable accounts
• Full user management
EOF

# Add alias to bashrc for all users
echo "Adding alias to bash profiles..."
for bash_file in /home/*/.bashrc /root/.bashrc; do
    if [[ -f "$bash_file" ]] && ! grep -q "alias admin=" "$bash_file"; then
        echo "alias admin='/usr/local/bin/admin'" >> "$bash_file"
    fi
done

# Add to global bashrc
if ! grep -q "alias admin=" /etc/bash.bashrc 2>/dev/null; then
    echo "alias admin='/usr/local/bin/admin'" >> /etc/bash.bashrc
fi

# Create uninstall script
echo "Creating uninstall script..."
cat > /usr/local/bin/uninstall-admin-system << 'EOF'
#!/bin/bash
echo "=== Uninstalling Admin System ==="

# Stop services
systemctl stop admin-monitor.service 2>/dev/null
systemctl disable admin-monitor.service 2>/dev/null

# Remove files
rm -f /usr/local/bin/admin
rm -f /usr/local/bin/uninstall-admin-system
rm -f /etc/systemd/system/admin-monitor.service
rm -f /etc/admin_system.conf
rm -f /etc/bash_completion.d/admin
rm -f /etc/logrotate.d/admin-system
rm -rf /var/lib/admin_system
rm -rf /var/log/admin_system
rm -rf /usr/local/share/admin_system

# Remove aliases
sed -i '/alias admin=/d' /root/.bashrc 2>/dev/null
sed -i '/alias admin=/d' /etc/bash.bashrc 2>/dev/null
for bash_file in /home/*/.bashrc; do
    [[ -f "$bash_file" ]] && sed -i '/alias admin=/d' "$bash_file" 2>/dev/null
done

systemctl daemon-reload
echo "Admin System has been uninstalled."
echo "You may need to restart your shell."
EOF

chmod +x /usr/local/bin/uninstall-admin-system

# Enable and start services
echo "Enabling services..."
systemctl daemon-reload
systemctl enable admin-monitor.service
systemctl start admin-monitor.service

echo ""
echo -e "${GREEN}=== Installation Complete! ==="
echo ""
cat /usr/local/share/admin_system/welcome.txt
echo ""
echo -e "${CYAN}Quick Commands:${NC}"
echo "  • Type ${GREEN}admin${NC} to start the menu"
echo "  • ${GREEN}admin --status${NC} for system status"
echo "  • ${GREEN}admin --list${NC} to list all users"
echo "  • ${GREEN}admin --help${NC} for help"
echo ""
echo -e "${YELLOW}The IP monitor runs automatically in background.${NC}"
echo -e "${YELLOW}Just type 'admin' anywhere in your VPS!${NC}"
echo ""

# Test the command
echo "Testing 'admin' command..."
if command -v admin &>/dev/null; then
    echo -e "${GREEN}✓ 'admin' command is working!${NC}"
else
    echo -e "${RED}✗ 'admin' command not found. Please restart your shell.${NC}"
fi

# Show sample usage
echo ""
echo -e "${CYAN}Sample Usage:${NC}"
echo "1. Type ${GREEN}admin${NC} and press Enter"
echo "2. Select option 1 to create a user"
echo "3. Enter username, IP limit, expiry days"
echo "4. User will auto-delete if they exceed IP limit"
echo ""
echo -e "${YELLOW}Try it now! Type 'admin' below:${NC}"
echo ""
