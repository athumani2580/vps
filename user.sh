#!/bin/bash

# Use environment variables if set
USERNAME="${IMPORT_USERNAME}"
ALLOWED_IP="${IMPORT_IP}"
ACTIVE_DAYS="${IMPORT_ACTIVE_DAYS:-30}"

# Validate required parameters
if [ -z "$USERNAME" ]; then
    read -p "Enter username: " USERNAME
fi

if [ -z "$ALLOWED_IP" ]; then
    read -p "Enter allowed IP for $USERNAME: " ALLOWED_IP
fi

# Get days from user
read -p "Enter number of active days [default: $ACTIVE_DAYS]: " INPUT_DAYS
if [ ! -z "$INPUT_DAYS" ]; then
    ACTIVE_DAYS="$INPUT_DAYS"
fi

# Calculate dates
EXPIRE_DATE=$(date -d "+$ACTIVE_DAYS days" +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)

echo "========================================="
echo "Creating user with day-based expiration"
echo "Username: $USERNAME"
echo "Allowed IP: $ALLOWED_IP"
echo "Active for: $ACTIVE_DAYS days"
echo "Expires on: $EXPIRE_DATE"
echo "========================================="

# Create user
sudo useradd -m -s /bin/bash $USERNAME
echo "Set password for $USERNAME:"
sudo passwd $USERNAME

# Set account expiration date
sudo usermod -e $EXPIRE_DATE $USERNAME

# Set password policy with chage
# -m 0: Minimum days between password change (0 = can change anytime)
# -M $ACTIVE_DAYS: Password expires after X days
# -W 7: Warn 7 days before expiration
# -I 1: Inactive days after expiration
# -E $EXPIRE_DATE: Account expiration date
sudo chage -m 0 -M $ACTIVE_DAYS -W 7 -I 1 -E $EXPIRE_DATE $USERNAME

# Configure SSH
sudo tee -a /etc/ssh/sshd_config << EOF

Match User $USERNAME,Address $ALLOWED_IP
    AllowTCPForwarding no
    X11Forwarding no
    PermitTTY yes
    
Match User $USERNAME
    AllowTCPForwarding no
    X11Forwarding no
    PermitTTY no
    ForceCommand echo 'Access denied. Allowed only from $ALLOWED_IP'
EOF

# Configure TCP Wrappers
echo "sshd : $ALLOWED_IP : allow" | sudo tee -a /etc/hosts.allow
echo "sshd : ALL : deny" | sudo tee -a /etc/hosts.deny

# Configure PAM
echo "+ : $USERNAME : $ALLOWED_IP" | sudo tee -a /etc/security/access.conf
echo "- : $USERNAME : ALL" | sudo tee -a /etc/security/access.conf

# Restart SSH
sudo systemctl restart sshd

# Display summary
echo "========================================="
echo "SUMMARY"
echo "========================================="
echo "Username:        $USERNAME"
echo "Allowed IP:      $ALLOWED_IP"
echo "Active days:     $ACTIVE_DAYS"
echo "Start date:      $TODAY"
echo "Expiration date: $EXPIRE_DATE"
echo ""
echo "Account details:"
sudo chage -l $USERNAME
