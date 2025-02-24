#!/bin/bash
# Enhanced Account Management Script for Defense Competitions
#
# This script performs two primary functions:
#   1. Process Mode (default): Back up critical files, then list non-root accounts (UID >= threshold),
#      letting you choose which accounts to keep, and then either disable or delete the rest.
#      Disabled accounts are logged for later re-enablement.
#      Deleted accounts are logged for forensic reference.
#
#   2. Re-enable Mode (--reenable): Display disabled accounts, let you choose which ones to re-enable,
#      and update the disabled accounts list accordingly.
#
# Usage:
#   Process Mode: sudo ./account_manager.sh
#   Re-enable Mode: sudo ./account_manager.sh --reenable

# Ensure the script is run as root.
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Files to store the list of disabled and deleted accounts.
DISABLED_FILE="/root/disabled_accounts.list"
DELETED_FILE="/root/deleted_accounts.list"

# Function: Backup critical system files and /home directory.
backup_system_files() {
    TIMESTAMP=$(date +%F_%H-%M-%S)
    BACKUP_DIR="/root/backup_${TIMESTAMP}"
    echo "Creating backup directory at $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    cp /etc/passwd "$BACKUP_DIR/passwd.backup"
    cp /etc/shadow "$BACKUP_DIR/shadow.backup"
    cp /etc/group "$BACKUP_DIR/group.backup"
    cp /etc/gshadow "$BACKUP_DIR/gshadow.backup"
    tar czf "$BACKUP_DIR/home_backup.tar.gz" /home
    echo "Backup completed. Files stored in $BACKUP_DIR"
}

# Function: Process user accounts (disable or delete).
process_accounts() {
    # Backup before making any changes.
    backup_system_files

    # Prompt for UID threshold (default 1000).
    read -p "Enter the minimum UID to affect (default is 1000): " UID_THRESHOLD
    UID_THRESHOLD=${UID_THRESHOLD:-1000}

    # Gather list of non-root usernames from /etc/passwd where UID >= threshold.
    mapfile -t userList < <(awk -F: -v thresh="$UID_THRESHOLD" '($3 >= thresh && $3 != 0) {print $1}' /etc/passwd)

    # If no accounts found, exit.
    if [ ${#userList[@]} -eq 0 ]; then
        echo "No user accounts found with UID >= $UID_THRESHOLD."
        exit 0
    fi

    # Display the accounts with an index number.
    echo "Found the following user accounts:"
    for i in "${!userList[@]}"; do
        printf "%3d) %s\n" "$((i+1))" "${userList[$i]}"
    done

    # Prompt for which accounts to keep.
    read -p "Enter the index numbers (separated by spaces) of accounts you want to keep [default: keep none]: " keepInput

    # Convert input into an array of indices.
    keepIndices=()
    if [[ -n "$keepInput" ]]; then
        for index in $keepInput; do
            if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#userList[@]}" ]; then
                keepIndices+=($((index-1)))
            else
                echo "Invalid index: $index. Skipping."
            fi
        done
    fi

    # Build list of usernames to keep.
    keepUsers=()
    for idx in "${keepIndices[@]}"; do
        keepUsers+=("${userList[$idx]}")
    done

    echo
    if [ ${#keepUsers[@]} -gt 0 ]; then
        echo "The following accounts will be kept:"
        for user in "${keepUsers[@]}"; do
            echo "  $user"
        done
    else
        echo "No accounts will be kept. All listed accounts will be processed."
    fi

    # Confirm proceeding.
    read -p "Are you sure you want to process the remaining accounts? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 1
    fi

    # Prompt for action on the remaining accounts.
    echo "For the remaining accounts, choose the action:"
    echo "  d) Disable (lock account, expire login)"
    echo "  r) Remove (delete account and home directory)"
    read -p "Enter your choice (default is disable): " actionChoice
    actionChoice=${actionChoice:-d}
    if [[ "$actionChoice" != "d" && "$actionChoice" != "r" ]]; then
        echo "Invalid option. Defaulting to disable."
        actionChoice="d"
    fi

    # Process each account not in the keep list.
    for user in "${userList[@]}"; do
        # Always check the actual account status.
        status=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
        # If an account in our disabled list is now active, remove it from the disabled file.
        if [ "$status" != "L" ]; then
            if grep -q "^$user\$" "$DISABLED_FILE"; then
                echo "Account $user is active now; removing from disabled list."
                sed -i "/^$user$/d" "$DISABLED_FILE"
            fi
        fi

        # Skip accounts you wish to keep.
        if [[ " ${keepUsers[*]} " == *" $user "* ]]; then
            echo "Keeping account: $user"
            continue
        fi

        if [ "$actionChoice" == "d" ]; then
            if [ "$status" == "L" ]; then
                echo "Account $user is already disabled. Skipping."
            else
                echo "Disabling account: $user"
                usermod -L "$user" && chage -E 0 "$user"
                if [ $? -eq 0 ]; then
                    echo "Account $user disabled successfully."
                    if ! grep -q "^$user\$" "$DISABLED_FILE"; then
                        echo "$user" >> "$DISABLED_FILE"
                    fi
                else
                    echo "Failed to disable account $user."
                fi
            fi
        else
            echo "Deleting account: $user"
            userdel -r "$user"
            if [ $? -eq 0 ]; then
                echo "Account $user deleted successfully."
                # Log the deleted account for forensic reference.
                echo "$user $(date +%F_%H-%M-%S)" >> "$DELETED_FILE"
            else
                echo "Failed to delete account $user."
            fi
        fi
    done

    echo "Operation completed. Please review /etc/passwd for current user accounts."
}

# Function: Re-enable previously disabled accounts.
reenable_accounts() {
    if [ ! -f "$DISABLED_FILE" ]; then
        echo "No disabled accounts file found at $DISABLED_FILE. Nothing to re-enable."
        exit 0
    fi

    # Read disabled accounts into an array.
    mapfile -t disabledAccounts < "$DISABLED_FILE"
    if [ ${#disabledAccounts[@]} -eq 0 ]; then
        echo "The disabled accounts file is empty. Nothing to re-enable."
        exit 0
    fi

    echo "The following accounts are marked as disabled:"
    for i in "${!disabledAccounts[@]}"; do
        printf "%3d) %s\n" "$((i+1))" "${disabledAccounts[$i]}"
    done

    read -p "Enter the index numbers (separated by spaces) of accounts you want to re-enable [default: re-enable all]: " reenableInput

    reenableIndices=()
    if [[ -n "$reenableInput" ]]; then
        for index in $reenableInput; do
            if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#disabledAccounts[@]}" ]; then
                reenableIndices+=($((index-1)))
            else
                echo "Invalid index: $index. Skipping."
            fi
        done
    fi

    # Determine which accounts to re-enable.
    if [ ${#reenableIndices[@]} -gt 0 ]; then
        reenableUsers=()
        for idx in "${reenableIndices[@]}"; do
            reenableUsers+=("${disabledAccounts[$idx]}")
        done
    else
        # Default: re-enable all.
        reenableUsers=("${disabledAccounts[@]}")
    fi

    echo
    echo "The following accounts will be re-enabled:"
    for user in "${reenableUsers[@]}"; do
        echo "  $user"
    done

    read -p "Are you sure you want to re-enable these accounts? (y/N): " confirmReenable
    if [[ ! "$confirmReenable" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 1
    fi

    for user in "${reenableUsers[@]}"; do
        echo "Re-enabling account: $user"
        usermod -U "$user" && chage -E -1 "$user"
        if [ $? -eq 0 ]; then
            echo "Account $user re-enabled successfully."
        else
            echo "Failed to re-enable account $user."
        fi
    done

    # Ask if the disabled accounts list should be cleared.
    read -p "Clear the disabled accounts list? (y/N): " clearList
    if [[ "$clearList" =~ ^[Yy]$ ]]; then
        > "$DISABLED_FILE"
        echo "Disabled accounts list cleared."
    fi
}

# Main logic: choose mode based on command-line argument.
if [ "$1" == "--reenable" ]; then
    echo "Re-enable mode selected."
    reenable_accounts
else
    echo "Process mode selected."
    process_accounts
fi
