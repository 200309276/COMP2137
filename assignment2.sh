#!/bin/bash

# ==============================================================================
# COMP2137 - Assignment 2 Script
# Andrew Bridgman - 200309276
# This script configures network, software, and users on a target server with minimal input.
# It is designed to be "idempotent" and provide clear, human friendly output.
# ==============================================================================

echo "**=== STARTING SERVER CONFIGURATION SCRIPT ===**"
echo "This script will configure network, software, and users."
echo "NOTE: This script must be run with root privileges (sudo)."
echo

# === CHECK FOR ROOT, EXIT IF NOT ===
if [ "$EUID" -ne 0 ]; then #
  echo "ERROR: This script must be run as root. Please use sudo."
  exit 1 #
fi

# === 1. NETWORK CONFIGURATION ===
echo "**=== CONFIGURING NETWORK ===**"

# Use command substitution to store output in a variable
# Use a pipeline to find the interface name (ip > grep > awk)
iface=$(ip a | grep 'inet 192.168.16' | awk '{print $NF}')
netplan_file=$(find /etc/netplan -name "*.yaml" | head -n1)

# Use 'test -n' and 'test -f' (file test)
if [ -n "$iface" ] && [ -f "$netplan_file" ]; then
    echo "Found interface $iface and Netplan file $netplan_file"
    
    # Use 'if' and 'grep -q' to test for the string
    if grep -q "192.168.16.21/24" "$netplan_file"; then
        echo "Static IP 192.168.16.21 is already set in $netplan_file."
    else
        echo "Setting static IP for $iface in $netplan_file..."
        # Use sed to modify the file in-place
        # This command finds the interface block and replaces dhcp4: true
        sed -i "/^ *${iface}:/,/^[a-zA-Z]/ s/.*dhcp4: true.*/      addresses: [192.168.16.21\/24]/" "$netplan_file"
        
        # Check exit status
        if [ $? -eq 0 ]; then
            echo "Netplan file updated. Applying changes..."
            netplan apply
            echo "Network changes applied."
        else
            echo "ERROR: Failed to update $netplan_file."
        fi
    fi
else
    echo "ERROR: Could not find Netplan file or interface."
fi

echo
echo "Updating /etc/hosts file..."
# Check if the correct entry exists
if grep -q "192.168.16.21.*server1" /etc/hosts; then
    echo "/etc/hosts already contains correct server1 entry."
else
    echo "Removing old server1 entries and adding new one..."
    # Use sed to find and delete lines matching 'server1'
    sed -i '/server1/d' /etc/hosts
    
    # Use echo with '>>' to append to the file
    echo "192.168.16.21 server1" >> /etc/hosts
    echo "/etc/hosts updated."
fi

echo
# === 2. SOFTWARE INSTALLATION ===
echo "**=== INSTALLING SOFTWARE ===**"
echo "Updating package lists (this may take a moment)..."
# Run apt-get update
apt-get update > /dev/null 2>&1

# Use a 'for' loop to iterate over a list of words
packages_to_install="apache2 squid"
for pkg in $packages_to_install; do
    
    # Check if package is installed by checking dpkg exit status
    # 'dpkg' manages packages on the system
    if ! dpkg -s "$pkg" > /dev/null 2>&1; then
        echo "Installing $pkg..."
        apt-get install -y "$pkg" > /dev/null 2>&1
        
        # Check the exit status of the install command
        if [ $? -eq 0 ]; then
            echo "$pkg installed successfully."
        else
            echo "ERROR: Failed to install $pkg."
        fi
    else
        echo "$pkg is already installed."
    fi
    
    # Check for systemctl status
    echo "Ensuring $pkg service is running and enabled..."
    # Use '||' conditional operator to run command only if first one fails
    systemctl is-active --quiet "$pkg" || systemctl start "$pkg"
    systemctl is-enabled --quiet "$pkg" || systemctl enable "$pkg"
    
    if systemctl is-active --quiet "$pkg"; then
        echo "$pkg service is running."
    else
        echo "ERROR: $pkg service failed to start."
    fi
done

echo
# === 3. USER ACCOUNT CREATION ===
echo "**=== CONFIGURING USER ACCOUNTS ===**"

# Create a variable for DENNIS SSH key and USER list
user_list="dennis aubrey captain snibbles brownie scooter sandy perrier cindy tiger yoda"
dennis_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4rT3vTt99Ox5kndS4HmgTrKBT8SKzhK4rhGkEVGlCI student@generic-vm"

# Use a 'for' loop to process the list
for user in $user_list; do
    
    # Use 'if' and 'grep' to check if user exists in /etc/passwd
    if ! grep -q "^${user}:" /etc/passwd; then
        echo "Creating user $user..."
        # 'useradd' creates user accounts
        useradd -m -s /bin/bash "$user"
        if [ $? -eq 0 ]; then
            echo "User $user created."
        else
            echo "ERROR: Failed to create user $user."
        fi
    else
        echo "User $user already exists."
    fi
    
    # Get home directory from /etc/passwd using a pipeline
    home_dir=$(grep "^${user}:" /etc/passwd | cut -d: -f6)
    ssh_dir="$home_dir/.ssh"
    auth_keys="$ssh_dir/authorized_keys"
    
    # Use 'test -d' (file test) to check for directory
    if [ ! -d "$ssh_dir" ]; then
        mkdir -p "$ssh_dir"
        chown "$user":"$user" "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi
    
    # Use 'test -f' (file test) to check for file
    if [ ! -f "$auth_keys" ]; then
        touch "$auth_keys"
        chown "$user":"$user" "$auth_keys"
        chmod 600 "$auth_keys"
    fi
    
    # Generate rsa key if it doesn't exist
    if [ ! -f "$ssh_dir/id_rsa" ]; then
        echo "Generating rsa key for $user..."
        ssh-keygen -t rsa -N "" -f "$ssh_dir/id_rsa"
        chown "$user":"$user" "$ssh_dir/id_rsa" "$ssh_dir/id_rsa.pub"
    fi
    
    # Generate ed25519 key if it doesn't exist
    if [ ! -f "$ssh_dir/id_ed25519" ]; then
        echo "Generating ed25519 key for $user..."
        ssh-keygen -t ed25519 -N "" -f "$ssh_dir/id_ed25519"
        chown "$user":"$user" "$ssh_dir/id_ed25519" "$ssh_dir/id_ed25519.pub"
    fi
    
    # Add user's own keys to authorized_keys
    rsa_pub=$(cat "$ssh_dir/id_rsa.pub")
    ed_pub=$(cat "$ssh_dir/id_ed25519.pub")
    
    echo "Adding $user's own keys to $auth_keys..."
    # Use grep -q and '||' to append only if key is missing
    grep -q -F "$rsa_pub" "$auth_keys" || echo "$rsa_pub" >> "$auth_keys"
    grep -q -F "$ed_pub" "$auth_keys" || echo "$ed_pub" >> "$auth_keys"
    
    # Special handling for user dennis
    # Use binary text comparison operator '='
    if [ "$user" = "dennis" ]; then
        echo "Configuring special access for dennis..."
        # 'usermod' modifies user accounts
        usermod -aG sudo "$user"
        
        # Add the specific student key
        grep -q -F "$dennis_key" "$auth_keys" || echo "$dennis_key" >> "$auth_keys"
        echo "Dennis added to sudo group and student key added."
    fi
    
    echo "--- Finished $user ---"
    
done

echo
echo "**=== SERVER CONFIGURATION SCRIPT FINISHED! ===**"
