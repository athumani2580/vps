#!/bin/bash

# Use environment variables if set
USERNAME="${IMPORT_USERNAME}"
ALLOWED_IP="${IMPORT_IP}"
EXPIRE_DATE="${IMPORT_EXPIRE_DATE:-2024-12-31}"

# Validate required parameters
if [ -z "$USERNAME" ]; then
    read -p "Enter username: " USERNAME
fi

if [ -z "$ALLOWED_IP" ]; then
    read -p "Enter allowed IP for $USERNAME: " ALLOWED_IP
fi

echo "========================================="
echo "Creating user from imported parameters"
echo "Username: $USERNAME"
echo "Allowed IP: $ALLOWED_IP"
echo "Expiration date: $EXPIRE_DATE"
echo "========================================="

# Create user
sudo useradd -m -s /bin/bash $USERNAME
echo "Set password for $USERNAME:"
sudo passwd $USERNAME

# Set expiration date
sudo usermod -e $EXPIRE_DATE $USERNAME
sudo chage -E $EXPIRE_DATE $USERNAME

# Configure SSH
sudo tee -a /etc/ssh/sshd_config << EOF

Match User $USERNAME,Address $ALLOWED_IP
    AllowTCPForwarding no
    X11Forwarding no
    
Match User $USERNAME
    AllowTCPForwarding no
    X11Forwarding no
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

# Verify
echo "========================================="
echo "VERIFICATION"
echo "========================================="
sudo chage -l $USERNAME
echo ""
echo "User created successfully!"
echo "Username: $USERNAME"
echo "Accessible only from: $ALLOWED_IP"
echo "Account expires: $EXPIRE_DATE"
