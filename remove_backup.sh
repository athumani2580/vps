#!/bin/bash
# backup_nuke.sh - COMPLETE BACKUP DESTRUCTION SCRIPT
# USE WITH EXTREME CAUTION - THIS WILL REMOVE ALL BACKUPS

# ============================================
# CONFIGURATION - REVIEW BEFORE RUNNING
# ============================================
LOG_FILE="/tmp/backup_removal_$(date +%Y%m%d_%H%M%S).log"
DRY_RUN=false  # Set to true to see what would be removed without actually doing it
SKIP_DATA=false # Set to true to skip deleting actual backup data files

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
# FUNCTIONS
# ============================================
log() {
    echo -e "$1"
    echo "$(date): $(echo -e "$1" | sed -r "s/\x1B\[[0-9;]*[mK]//g")" >> "$LOG_FILE"
}

warning() {
    log "${YELLOW}[WARNING] $1${NC}"
}

error() {
    log "${RED}[ERROR] $1${NC}"
}

success() {
    log "${GREEN}[SUCCESS] $1${NC}"
}

confirm_action() {
    if [ "$DRY_RUN" = true ]; then
        log "${YELLOW}[DRY RUN] Would execute: $1${NC}"
        return 0
    fi
    
    if [ "$SKIP_DATA" = true ] && [[ "$1" == *"rm -rf"* ]] && [[ "$1" == *"backup"* ]]; then
        log "${YELLOW}[SKIPPED] Data deletion: $1${NC}"
        return 0
    fi
    
    eval "$1" >> "$LOG_FILE" 2>&1
    return $?
}

# ============================================
# SAFETY CHECKS
# ============================================
echo -e "${RED}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                ⚠️  DANGEROUS OPERATION ⚠️                 ║"
echo "║     THIS WILL REMOVE ALL BACKUPS AND RELATED FILES       ║"
echo "║                                                          ║"
echo "║  This script will:                                       ║"
echo "║  • Stop all backup processes                             ║"
echo "║  • Remove cron jobs                                      ║"
echo "║  • Uninstall backup software                             ║"
echo "║  • Delete backup data                                    ║"
echo "║  • Remove configuration files                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$DRY_RUN" = true ]; then
    warning "DRY RUN MODE - No changes will be made"
fi

if [ "$SKIP_DATA" = true ]; then
    warning "SKIPPING DATA DELETION - Only removing configurations"
fi

read -p "Are you absolutely sure? Type 'DESTROY-ALL-BACKUPS' to confirm: " confirmation
if [ "$confirmation" != "DESTROY-ALL-BACKUPS" ]; then
    error "Confirmation failed. Aborting."
    exit 1
fi

log "=== BACKUP DESTRUCTION STARTED ==="
log "Log file: $LOG_FILE"
log "Timestamp: $(date)"
log "Hostname: $(hostname)"
log "User: $(whoami)"

# ============================================
# 1. KILL ALL BACKUP PROCESSES
# ============================================
log "=== STEP 1: Stopping all backup processes ==="

backup_processes=(
    "backup" "rsync" "tar" "duplicity" "borg" "restic" "bacula" "amanda"
    "duplicati" "rclone" "arq" "timeshift" "deja-dup" "urbackup"
    "backintime" "backuppc" "bareos" "kbackup" "sbackup"
    "pg_dump" "mysqldump" "mongodump" "xtrabackup" "mariabackup"
    "wbadmin" "ntbackup" "windowsbackup"
)

for proc in "${backup_processes[@]}"; do
    # Find and kill processes
    pids=$(pgrep -f "$proc" 2>/dev/null)
    if [ -n "$pids" ]; then
        warning "Found $proc processes: $pids"
        confirm_action "kill -9 $pids 2>/dev/null"
        confirm_action "pkill -9 -f '$proc' 2>/dev/null"
    fi
done

# ============================================
# 2. REMOVE CRON JOBS
# ============================================
log "=== STEP 2: Removing all backup cron jobs ==="

# All user crontabs
for user in $(cut -f1 -d: /etc/passwd); do
    if sudo -u "$user" crontab -l 2>/dev/null | grep -q -i "backup\|rsync\|tar\|dump"; then
        warning "Removing backup cron for user: $user"
        if [ "$DRY_RUN" = false ]; then
            sudo -u "$user" crontab -l 2>/dev/null | grep -v -i "backup\|rsync\|tar\|dump" | sudo -u "$user" crontab -
        fi
    fi
done

# System crontabs
system_crons=(
    "/etc/crontab"
    "/etc/cron.d/*"
    "/etc/cron.daily/*"
    "/etc/cron.weekly/*"
    "/etc/cron.monthly/*"
    "/etc/cron.hourly/*"
    "/var/spool/cron/*"
)

for cron_file in ${system_crons[@]}; do
    for file in $cron_file; do
        if [ -f "$file" ]; then
            if grep -q -i "backup\|rsync\|tar\|dump" "$file" 2>/dev/null; then
                warning "Found backup job in: $file"
                if [[ "$file" == *.d/* ]]; then
                    confirm_action "rm -f '$file'"
                else
                    if [ "$DRY_RUN" = false ]; then
                        grep -v -i "backup\|rsync\|tar\|dump" "$file" > "/tmp/temp_cron" && \
                        sudo mv "/tmp/temp_cron" "$file"
                    fi
                fi
            fi
        fi
    done
done

# ============================================
# 3. STOP AND DISABLE SERVICES
# ============================================
log "=== STEP 3: Stopping and disabling backup services ==="

# Systemd services
if command -v systemctl &> /dev/null; then
    services=$(systemctl list-units --all --type=service | grep -i backup | awk '{print $1}')
    for service in $services; do
        warning "Stopping service: $service"
        confirm_action "systemctl stop '$service'"
        confirm_action "systemctl disable '$service'"
        confirm_action "systemctl mask '$service'"
    done
    
    # Also look for common backup service names
    backup_services=(
        "bacula*" "restic*" "duplicati*" "urbackup*" "backuppc*" 
        "bareos*" "amanda*" "timeshift*"
    )
    
    for pattern in "${backup_services[@]}"; do
        confirm_action "systemctl stop '$pattern' 2>/dev/null"
        confirm_action "systemctl disable '$pattern' 2>/dev/null"
    done
fi

# SysV init scripts
if [ -d "/etc/init.d" ]; then
    for script in /etc/init.d/*backup* /etc/init.d/*bacula* /etc/init.d/*amanda*; do
        if [ -f "$script" ]; then
            warning "Disabling init script: $script"
            confirm_action "$script stop"
            if command -v update-rc.d &> /dev/null; then
                confirm_action "update-rc.d -f $(basename "$script") remove"
            elif command -v chkconfig &> /dev/null; then
                confirm_action "chkconfig $(basename "$script") off"
            fi
        fi
    done
fi

# ============================================
# 4. UNINSTALL BACKUP SOFTWARE
# ============================================
log "=== STEP 4: Uninstalling backup software ==="

# Debian/Ubuntu
if command -v apt &> /dev/null; then
    backup_packages=$(apt list --installed 2>/dev/null | grep -i "backup\|bacula\|amanda\|duplicity\|borg\|restic\|rsync" | cut -d'/' -f1)
    for pkg in $backup_packages; do
        warning "Removing package: $pkg"
        confirm_action "apt-get purge -y --auto-remove '$pkg'"
    done
fi

# RHEL/CentOS/Fedora
if command -v yum &> /dev/null; then
    backup_packages=$(yum list installed | grep -i "backup\|bacula\|amanda\|duplicity\|borg\|restic" | awk '{print $1}')
    for pkg in $backup_packages; do
        warning "Removing package: $pkg"
        confirm_action "yum remove -y '$pkg'"
    done
fi

# Arch
if command -v pacman &> /dev/null; then
    backup_packages=$(pacman -Q | grep -i "backup\|bacula\|amanda\|duplicity\|borg\|restic" | awk '{print $1}')
    for pkg in $backup_packages; do
        warning "Removing package: $pkg"
        confirm_action "pacman -Rns --noconfirm '$pkg'"
    done
fi

# Snap/Flatpak
confirm_action "snap remove --purge '*backup*' 2>/dev/null"
confirm_action "flatpak uninstall --assumeyes '*backup*' 2>/dev/null"

# ============================================
# 5. REMOVE CONFIGURATION FILES
# ============================================
log "=== STEP 5: Removing configuration files ==="

config_dirs=(
    "/etc/backup*" "/etc/bacula*" "/etc/amanda*" "/etc/duplicity*"
    "/etc/restic*" "/etc/borg*" "/etc/rsnapshot*" "/etc/backuppc*"
    "/etc/bareos*" "/etc/urbackup*" "/etc/duplicati*" "/etc/timeshift*"
    "/usr/local/etc/backup*" "/opt/backup*" "/var/lib/backup*"
    "/var/backups" "/var/lib/bacula*" "/var/lib/amanda*"
    "/root/.config/restic*" "/root/.config/borg*" "/root/.cache/duplicity*"
    "/home/*/.config/restic*" "/home/*/.config/borg*" "/home/*/.cache/duplicity*"
    "/home/*/.duplicity*" "/home/*/.borg*" "/home/*/.restic*"
)

for dir_pattern in "${config_dirs[@]}"; do
    for dir in $dir_pattern; do
        if [ -e "$dir" ]; then
            warning "Removing config directory: $dir"
            confirm_action "rm -rf '$dir'"
        fi
    done
done

# ============================================
# 6. DELETE BACKUP DATA FILES
# ============================================
if [ "$SKIP_DATA" = false ]; then
    log "=== STEP 6: Deleting backup data files ==="
    
    # Common backup locations
    backup_locations=(
        "/backup*" "/backups*" "/mnt/backup*" "/media/backup*"
        "/storage/backup*" "/data/backup*" "/archive*"
        "/var/backup*" "/tmp/backup*" "/root/backup*"
        "/home/*/backup*" "/home/*/Backup*" "/home/*/.backup*"
    )
    
    for location in "${backup_locations[@]}"; do
        for item in $location; do
            if [ -e "$item" ]; then
                warning "Deleting backup data: $item"
                confirm_action "rm -rf '$item'"
            fi
        done
    done
    
    # Find and delete backup files anywhere
    log "Searching for backup files in filesystem..."
    find_patterns=(
        "-name '*backup*' -o -name '*Backup*' -o -name '*BACKUP*'"
        "-name '*.bak' -o -name '*.BAK'"
        "-name '*.tar.gz' -name '*.tgz' -o -name '*.tar.bz2' -o -name '*.tar.xz'"
        "-name '*dump*' -o -name '*Dump*'"
        "-name '*.sql.gz' -o -name '*.sql.bz2'"
    )
    
    for pattern in "${find_patterns[@]}"; do
        warning "Deleting files matching: $pattern"
        if [ "$DRY_RUN" = true ]; then
            find / -type f \( $pattern \) -exec echo "[DRY RUN] Would delete: {}" \; 2>/dev/null | head -50
        else
            find / -type f \( $pattern \) -delete 2>/dev/null
        fi
    done
fi

# ============================================
# 7. CLEAN UP DATABASE BACKUPS
# ============================================
log "=== STEP 7: Cleaning database backup settings ==="

# MySQL/MariaDB
if command -v mysql &> /dev/null; then
    warning "Cleaning MySQL backup events"
    mysql -e "SHOW EVENTS" 2>/dev/null | grep -i backup | while read event; do
        event_name=$(echo $event | awk '{print $1}')
        confirm_action "mysql -e \"DROP EVENT IF EXISTS $event_name\""
    done
fi

# PostgreSQL
if command -v psql &> /dev/null; then
    warning "Cleaning PostgreSQL backup settings"
    # Remove backup-related extensions
    confirm_action "psql -c \"DROP EXTENSION IF EXISTS pg_background;\" 2>/dev/null"
fi

# ============================================
# 8. WINDOWS SPECIFIC (if running under WSL)
# ============================================
if uname -r | grep -i microsoft &> /dev/null; then
    log "=== WSL DETECTED: Cleaning Windows backups ==="
    
    # Clean Windows backup registry entries
    confirm_action "cmd.exe /c 'wbadmin delete systemstatebackup 2>nul'"
    confirm_action "cmd.exe /c 'wbadmin delete backup -keepVersions:0 2>nul'"
    
    # Remove Windows backup tasks
    confirm_action "cmd.exe /c 'schtasks /delete /tn \"*Backup*\" /f 2>nul'"
fi

# ============================================
# 9. FINAL CLEANUP
# ============================================
log "=== STEP 8: Final cleanup ==="

# Remove backup scripts
find / -type f -name "*.sh" -exec grep -l "backup\|Backup\|BACKUP" {} \; 2>/dev/null | while read script; do
    warning "Removing backup script: $script"
    confirm_action "rm -f '$script'"
done

# Clean package manager cache
confirm_action "apt-get autoremove -y 2>/dev/null"
confirm_action "apt-get autoclean -y 2>/dev/null"
confirm_action "yum autoremove -y 2>/dev/null"

# ============================================
# VERIFICATION
# ============================================
log "=== VERIFICATION ==="

# Check for remaining backup processes
remaining_procs=$(ps aux | grep -iE "backup|rsync|tar|duplicity|borg|restic" | grep -v grep | grep -v "$0")
if [ -n "$remaining_procs" ]; then
    error "Remaining backup processes found:"
    echo "$remaining_procs"
else
    success "No backup processes running"
fi

# Check for remaining cron jobs
remaining_crons=$(crontab -l 2>/dev/null | grep -i backup)
if [ -n "$remaining_crons" ]; then
    error "Remaining backup cron jobs found:"
    echo "$remaining_crons"
else
    success "No backup cron jobs found"
fi

# Check for backup directories
remaining_dirs=$(find / -type d -name "*backup*" 2>/dev/null | head -20)
if [ -n "$remaining_dirs" ]; then
    warning "Remaining backup directories (first 20):"
    echo "$remaining_dirs"
fi

log "=== DESTRUCTION COMPLETE ==="
warning "ALL BACKUP CONFIGURATIONS HAVE BEEN REMOVED"
if [ "$SKIP_DATA" = false ]; then
    warning "BACKUP DATA HAS BEEN DELETED"
else
    warning "Backup data was NOT deleted (SKIP_DATA=true)"
fi
warning "Review log file: $LOG_FILE"
echo -e "${RED}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                     ⚠️  WARNING ⚠️                       ║"
echo "║   Your system no longer has automated backups!           ║"
echo "║   Data loss risk is extremely high!                      ║"
echo "║   Consider implementing a new backup solution ASAP!      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
