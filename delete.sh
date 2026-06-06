#!/bin/bash
# uninstall-customer-service.sh - Complete uninstaller

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_step() { echo -e "${BLUE}[→]${NC} $1"; }

# Configuration
SERVICE_NAME="customer-service"
INSTALL_DIR="/opt/customer-service"
CONFIG_DIR="/etc/customer-service"
BIN_CTL="/usr/local/bin/customer-ctl"
SYSTEMD_SERVICE="/etc/systemd/system/customer-service.service"
LOG_FILE="/var/log/customer-service.log"

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Must be run as root"
        echo "Run: sudo $0"
        exit 1
    fi
}

# Stop and disable service
stop_service() {
    print_step "Stopping service..."
    
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
        print_status "Service stopped"
    else
        print_warning "Service was not running"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable "$SERVICE_NAME"
        print_status "Service disabled"
    fi
}

# Remove systemd service
remove_systemd() {
    print_step "Removing systemd service..."
    
    if [[ -f "$SYSTEMD_SERVICE" ]]; then
        rm -f "$SYSTEMD_SERVICE"
        print_status "Systemd service file removed"
    fi
    
    systemctl daemon-reload
}

# Remove files and directories
remove_files() {
    print_step "Removing files and directories..."
    
    # Remove main directories
    for dir in "$INSTALL_DIR" "$CONFIG_DIR"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            print_status "Removed: $dir"
        fi
    done
    
    # Remove control script
    if [[ -f "$BIN_CTL" ]]; then
        rm -f "$BIN_CTL"
        print_status "Removed: $BIN_CTL"
    fi
    
    # Remove log file
    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
        print_status "Removed: $LOG_FILE"
    fi
}

# Remove firewall rules (optional)
remove_firewall_rules() {
    print_step "Removing firewall rules..."
    
    read -p "Remove firewall rules for port 53? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if command -v ufw &>/dev/null; then
            ufw delete allow 53/udp 2>/dev/null && print_status "UFW rule removed" || true
        fi
        
        if command -v iptables &>/dev/null; then
            iptables -D INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null && print_status "iptables rule removed" || true
            iptables -D INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
        fi
        
        print_status "Firewall rules removed"
    else
        print_warning "Skipped firewall cleanup"
    fi
}

# Remove rc.local iptables rules (optional)
remove_rc_local_rules() {
    print_step "Checking rc.local..."
    
    if [[ -f "/etc/rc.local" ]]; then
        read -p "Remove DNS/port 53 rules from /etc/rc.local? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Backup first
            cp /etc/rc.local /etc/rc.local.backup
            
            # Remove lines related to port 53 and 5300
            sed -i '/port 53/d' /etc/rc.local
            sed -i '/port 5300/d' /etc/rc.local
            sed -i '/DNS/d' /etc/rc.local
            
            print_status "Rules removed from rc.local (backup saved as rc.local.backup)"
        fi
    fi
}

# Remove Python packages (optional)
remove_python_pkgs() {
    print_step "Checking Python packages..."
    
    read -p "Remove installed Python packages (scapy, pyyaml)? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pip3 uninstall -y scapy pyyaml 2>/dev/null && print_status "Python packages removed" || true
    fi
}

# Show summary
show_summary() {
    echo ""
    echo "=================================================="
    echo -e "${GREEN}Uninstall Complete${NC}"
    echo "=================================================="
    echo ""
    echo "Removed:"
    echo "  ✓ Service: $SERVICE_NAME"
    echo "  ✓ Directory: $INSTALL_DIR"
    echo "  ✓ Directory: $CONFIG_DIR"
    echo "  ✓ Binary: $BIN_CTL"
    echo "  ✓ Systemd: $SYSTEMD_SERVICE"
    echo ""
    echo "Leftovers (manual cleanup if needed):"
    echo "  • /var/log/customer-service.log (if exists)"
    echo "  • /etc/rc.local (backup at /etc/rc.local.backup)"
    echo ""
    echo "Verification:"
    echo "  ss -uln | grep :53    # Check if port 53 is free"
    echo "  systemctl list-units | grep customer  # Check for残留"
    echo ""
    echo "=================================================="
}

# Main
main() {
    echo "=================================================="
    echo "  Customer Service Uninstaller"
    echo "=================================================="
    echo ""
    
    check_root
    
    print_warning "This will remove customer-service completely"
    read -p "Continue? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted"
        exit 0
    fi
    
    stop_service
    remove_systemd
    remove_files
    remove_firewall_rules
    remove_rc_local_rules
    remove_python_pkgs
    
    show_summary
}

main "$@"
