#!/bin/bash

USERNAME="master"
ALLOWED_IP="192.168.1.100"
EXPIRE_DATE="2024-12-31"

# Create user
sudo useradd -m -s /bin/bash $USERNAME
echo "Set password for $USERNAME:"
sudo passwd $USERNAME

# Set expiration date
sudo usermod -e $EXPIRE_DATE $USERNAME

# Configure SSH for single IP restriction
echo -e "\nMatch User $USERNAME,Address $ALLOWED_IP\n    AllowTCPForwarding no\n    X11Forwarding no" | sudo tee -a /etc/ssh/sshd_config
echo -e "Match User $USERNAME\n    AllowTCPForwarding no\n    X11Forwarding no\n    ForceCommand echo 'Access denied from this IP'" | sudo tee -a /etc/ssh/sshd_config

# Configure TCP Wrappers
echo "sshd : $ALLOWED_IP : allow" | sudo tee -a /etc/hosts.allow
echo "sshd : ALL : deny" | sudo tee -a /etc/hosts.deny

# Configure PAM
echo "+ : $USERNAME : $ALLOWED_IP" | sudo tee -a /etc/security/access.conf
echo "- : $USERNAME : ALL" | sudo tee -a /etc/security/access.conf

# Restart services
sudo systemctl restart sshd

echo "User $USERNAME created and restricted to IP: $ALLOWED_IP"
echo "Expiration date: $EXPIRE_DATE"
