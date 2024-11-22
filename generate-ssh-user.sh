#!/bin/zsh

# Script used to create temporary users for SSH reverse tunnels. Will add users to SSH users and offer change SSHD authentication
#   to password or identity file. If the latter is chose, identity files (private / public key) are created and their filepaths
#   are provided. Default choice is to configure SSHD for password authentication since using identity files require writing to disk.
#   User's original SSHD config, located at /etc/ssh/sshd_config, is copied on first run and may be restored with by specifying the
#   "--clean" flag. Doing so will also delete all users created with this script, including their home directory.

# Ensure script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Please use sudo or run as root."
  exit 1
fi

# Path to store user-related data
USER_FILE="/var/log/created_users.log"
SSHD_CONFIG_BACKUP="/etc/ssh/sshd_config.backup"
KEY_STORE="/var/ssh_keys"

# Ensure key store directory exists
mkdir -p "$KEY_STORE"

# Function to generate random username
generate_username() {
  echo "user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
}

# Function to create a user
create_user() {
  local username="$1"
  local password="$2"

  if [[ -z "$username" ]]; then
    username=$(generate_username)
  fi

  if [[ -z "$password" ]]; then
    password=$(openssl rand -base64 12)
  fi

  echo "Creating user: $username with password: $password"

  # Create the user with home directory and set password
  useradd -m -s /bin/bash "$username"
  echo "$username:$password" | chpasswd

  # Save the created username
  echo "$username" >> "$USER_FILE"

  # Set global variables for username and password
  GENERATED_USERNAME="$username"
  GENERATED_PASSWORD="$password"
}

# Function to modify SSHD configuration
modify_sshd_config() {
  local username="$1"
  keyDest=""
  if [[ ! -f "$SSHD_CONFIG_BACKUP" ]]; then
    cp /etc/ssh/sshd_config "$SSHD_CONFIG_BACKUP"
  fi

  local allow_passwords=$(grep -i "^PasswordAuthentication yes" /etc/ssh/sshd_config)
  if [[ -n "$allow_passwords" ]]; then
    echo "SSHD is currently set to allow passwords. No identity file will be created."
  else
    echo "SSHD is not set to allow passwords."
    while true; do
        read "?Would you like to enable SSHD password login (Y/n) or generate an identity file (g)? " REPLY
        REPLY="${REPLY:l}" # Convert response to lowercase
        if [[ -z "$REPLY" ]]; then
            REPLY="Y"
            break
        elif [[ "$REPLY" == "y" || "$REPLY" == "Y" || "$REPLY" == "n" || "$REPLY" == "g" ]]; then
            break
        else
            echo "Invalid response. Please enter 'Y', 'n', 'g', or press Enter to select 'Y'."
        fi
    done
    if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
        sed -i 's/^#PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    elif [[ "$REPLY" == "g" ]]; then
        echo "Allowing SSH identity file login and generating identity file."
        sed -i 's/^#PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
      if [[ -z "$username" ]]; then
        echo "Error: Username not provided to modify_sshd_config function."
        echo "USERNAME IS: $username"
        exit 1
      fi
        keyDest="$KEY_STORE""/""$username""_key"
        ssh-keygen -t rsa -f "$keyDest" -N ""
        echo "Identity file generated for user $username. Private key: $KEY_STORE/${username}_key, Public key: $KEY_STORE/${username}_key.pub"
    fi
  fi
}

# Function to delete generated users
delete_users() {
  if [[ -f "$USER_FILE" ]]; then
    while IFS= read -r username; do
      echo "Deleting user: $username"
      
      # To avoid 'userdel' complaining about non-existent mail spool, create one for the user and make them the owner.
      touch "/var/mail/$username" 1> /dev/null 2> /dev/null
      chown "$username"":""$username" "/var/mail/$username" 1> /dev/null 2> /dev/null

      userdel -r "$username"
    done < "$USER_FILE"
    rm -f "$USER_FILE"
  fi

  if [[ -f "$SSHD_CONFIG_BACKUP" ]]; then
    echo "Restoring original SSHD configuration."
    cp "$SSHD_CONFIG_BACKUP" /etc/ssh/sshd_config
    rm -f "$SSHD_CONFIG_BACKUP"
  fi
}

# Main script logic
if [[ "$1" == "--clean" ]]; then
  delete_users
  systemctl restart sshd
  echo "Clean-up complete. SSHD configuration restored to original state."
  exit 0
fi

# Read username and password from input
read "?Enter username (or leave blank to generate one): " username
read "?Enter password (or leave blank to generate one): " password

# Call create_user and use global variables
create_user "$username" "$password"
modify_sshd_config "$GENERATED_USERNAME"

# Start SSHD service
systemctl restart sshd

echo "User creation complete. To remove generated users and restore SSHD config, rerun this script with --clean."
