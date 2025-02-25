#!/bin/bash
# Enhanced Account Management Script for Defense Competitions
#
# This script performs two primary functions:
#   1. Process Mode (default): Back up critical files, then list non-root accounts (UID >= threshold),
#      letting you choose which accounts to keep, and then either disable or delete the rest.
#      - Disabled accounts are logged for later re-enablement (in /root/disabled_accounts.list).
#      - Deleted accounts are logged for forensic reference (in /root/deleted_accounts.list).
#
#   2. Re-enable Mode (--reenable): Display disabled accounts, let you choose which ones to re-enable,
#      and update the disabled accounts list accordingly.
#
# Usage:
#   Process Mode: sudo ./account_manager.sh
#   Re-enable Mode: sudo ./account_manager.sh --reenable

################################################################
# 1. Define Color Variables
################################################################
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

################################################################
# Ensure the script is run as root.
################################################################
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${RESET} This script must be run as root. Exiting."
    exit 1
fi

# Files to store the list of disabled and deleted accounts.
DISABLED_FILE="/root/disabled_accounts.list"
DELETED_FILE="/root/deleted_accounts.list"

# Log file for capturing stderr output (including harmless warnings).
LOGFILE="/var/log/account_manager_errors.log"

# Ensure the log file exists and is secured.
touch "$LOGFILE"
chmod 600 "$LOGFILE"

################################################################
# Function: Backup critical system files and /home directory.
################################################################
backup_system_files() {
    # We create a timestamped directory under /root for backups.
    TIMESTAMP=$(date +%F_%H-%M-%S)
    BACKUP_DIR="/root/backup_${TIMESTAMP}"

    echo -e "\n${BOLD}${BLUE}=== Starting Backup ===${RESET}"
    echo -e "Creating backup directory at ${YELLOW}$BACKUP_DIR${RESET}..."

    mkdir -p "$BACKUP_DIR" || { echo -e "${RED}[ERROR]${RESET} Failed to create $BACKUP_DIR"; exit 1; }
    chmod 700 "$BACKUP_DIR"

    # Copy critical system files for safekeeping.
    cp /etc/passwd "$BACKUP_DIR/passwd.backup" 2>>"$LOGFILE"
    cp /etc/shadow "$BACKUP_DIR/shadow.backup" 2>>"$LOGFILE"
    cp /etc/group "$BACKUP_DIR/group.backup" 2>>"$LOGFILE"
    cp /etc/gshadow "$BACKUP_DIR/gshadow.backup" 2>>"$LOGFILE"

    # Archive the /home directory for a full backup of user data.
    echo -e "Backing up /home to ${YELLOW}$BACKUP_DIR/home_backup.tar.gz${RESET}..."
    tar czf "$BACKUP_DIR/home_backup.tar.gz" /home 2>>"$LOGFILE"
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[OK]${RESET} /home backup completed."
    else
        echo -e "  ${RED}[ERROR]${RESET} Failed to back up /home. Check $LOGFILE for details."
    fi

    echo -e "${BOLD}${BLUE}=== Backup Completed ===${RESET}"
    echo -e "Files stored in ${YELLOW}$BACKUP_DIR${RESET}\n"
}

################################################################
# Function: Process user accounts (disable or delete).
################################################################
process_accounts() {
    # Indicate which mode we're in (process mode).
    echo -e "${BOLD}${BLUE}Process mode selected.${RESET}\n"

    # Backup before making any changes.
    backup_system_files

    # Prompt for UID threshold (default 1000).
    read -p "Enter the minimum UID to affect (default is 1000): " UID_THRESHOLD
    UID_THRESHOLD=${UID_THRESHOLD:-1000}

    # Gather list of non-root usernames from /etc/passwd where UID >= threshold.
    mapfile -t userList < <(awk -F: -v thresh="$UID_THRESHOLD" '($3 >= thresh && $3 != 0) {print $1}' /etc/passwd)

    # If no accounts found, exit.
    if [ ${#userList[@]} -eq 0 ]; then
        echo -e "${YELLOW}No user accounts found with UID >= $UID_THRESHOLD.${RESET}"
        exit 0
    fi

    # Display the accounts with an index number and show each account's UID.
    echo -e "Found the following user accounts (UID >= ${YELLOW}$UID_THRESHOLD${RESET}):"
    for i in "${!userList[@]}"; do
        uid=$(getent passwd "${userList[$i]}" | cut -d: -f3)
        printf "  %2d) %s (UID: %s)\n" "$((i+1))" "${userList[$i]}" "$uid"
    done

    echo
    read -p "Enter the index numbers (separated by spaces) of accounts you want to keep [default: keep none]: " keepInput

    # Convert input into an array of indices.
    keepIndices=()
    if [[ -n "$keepInput" ]]; then
        for index in $keepInput; do
            if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#userList[@]}" ]; then
                keepIndices+=($((index-1)))
            else
                echo -e "${RED}[ERROR]${RESET} Invalid index: $index. Skipping."
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
        echo -e "The following accounts will be ${GREEN}kept${RESET}:"
        for user in "${keepUsers[@]}"; do
            echo "  $user"
        done
    else
        echo -e "${YELLOW}No accounts will be kept. All listed accounts will be processed.${RESET}"
    fi

    echo
    read -p "Are you sure you want to process the remaining accounts? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${RED}[ERROR]${RESET} Operation cancelled."
        exit 1
    fi

    # Prompt for action on the remaining accounts.
    echo -e "For the remaining accounts, choose the action:"
    echo -e "  d) Disable (lock account, expire login, delete home directory)"
    echo -e "  r) Remove (delete account and home directory)"
    read -p "Enter your choice (default is disable): " actionChoice
    actionChoice=${actionChoice:-d}
    if [[ "$actionChoice" != "d" && "$actionChoice" != "r" ]]; then
        echo -e "${RED}[ERROR]${RESET} Invalid option. Defaulting to disable."
        actionChoice="d"
    fi

    echo -e "\n${BOLD}${BLUE}=== Processing Accounts ===${RESET}"
    for user in "${userList[@]}"; do
        # Always check the actual account status from /etc/shadow.
        status=$(passwd -S "$user" 2>>"$LOGFILE" | awk '{print $2}')

        # If an account is in the disabled list but is no longer locked, remove it from that file.
        if [ "$status" != "L" ]; then
            if grep -q "^$user\$" "$DISABLED_FILE" 2>/dev/null; then
                echo "Account $user is active now; removing from disabled list."
                sed -i "/^$user$/d" "$DISABLED_FILE"
            fi
        fi

        # Skip accounts that we chose to keep.
        if [[ " ${keepUsers[*]} " == *" $user "* ]]; then
            echo -e "Keeping account: ${GREEN}$user${RESET}"
            continue
        fi

        # Action: Disable or Remove
        if [ "$actionChoice" == "d" ]; then
            # Disabling the account (lock password, expire login, delete home dir).
            if [ "$status" == "L" ]; then
                echo -e "Account $user is already disabled. ${YELLOW}Skipping.${RESET}"
            else
                echo -e "Disabling account: ${YELLOW}$user${RESET}"
                usermod -L "$user" 2>>"$LOGFILE" && chage -E 0 "$user" 2>>"$LOGFILE"
                if [ $? -eq 0 ]; then
                    echo -e "  ${GREEN}[OK]${RESET} Account $user disabled."
                    # Log disabled user if not already logged.
                    if ! grep -q "^$user\$" "$DISABLED_FILE" 2>/dev/null; then
                        echo "$user" >> "$DISABLED_FILE"
                    fi

                    # Delete the user's home directory.
                    userHome=$(getent passwd "$user" | cut -d: -f6)
                    if [ -d "$userHome" ]; then
                        echo "Deleting home directory for $user at $userHome..."
                        rm -rf "$userHome" 2>>"$LOGFILE"
                        if [ $? -eq 0 ]; then
                            echo -e "  ${GREEN}[OK]${RESET} Home directory for $user deleted."
                        else
                            echo -e "  ${RED}[ERROR]${RESET} Failed to delete $user's home directory."
                        fi
                    else
                        echo -e "${YELLOW}No home directory found for $user.${RESET}"
                    fi
                else
                    echo -e "  ${RED}[ERROR]${RESET} Failed to disable $user. See $LOGFILE for details."
                fi
            fi
        else
            # Removing the account entirely with userdel -r.
            echo -e "Deleting account: ${YELLOW}$user${RESET}"
            userdel -r "$user" 2>>"$LOGFILE"
            if [ $? -eq 0 ]; then
                echo -e "  ${GREEN}[OK]${RESET} Account $user deleted."
                # Log the deleted account for forensic reference.
                echo "$user $(date +%F_%H-%M-%S)" >> "$DELETED_FILE"
            else
                echo -e "  ${RED}[ERROR]${RESET} Failed to delete $user. See $LOGFILE for details."
            fi
        fi
    done

    echo -e "\n${BOLD}${BLUE}=== Operation Completed ===${RESET}"
    echo -e "Please review ${YELLOW}/etc/passwd${RESET} for current user accounts."
}

################################################################
# Function: Re-enable previously disabled accounts.
################################################################
reenable_accounts() {
    # Indicate we're in re-enable mode.
    echo -e "${BOLD}${BLUE}Re-enable mode selected.${RESET}\n"

    # Check if the disabled file exists and has content.
    if [ ! -f "$DISABLED_FILE" ]; then
        echo -e "${YELLOW}No disabled accounts file found at $DISABLED_FILE. Nothing to re-enable.${RESET}"
        exit 0
    fi

    mapfile -t disabledAccounts < "$DISABLED_FILE"
    if [ ${#disabledAccounts[@]} -eq 0 ]; then
        echo -e "${YELLOW}The disabled accounts file is empty. Nothing to re-enable.${RESET}"
        exit 0
    fi

    echo "The following accounts are marked as disabled:"
    for i in "${!disabledAccounts[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${disabledAccounts[$i]}"
    done

    echo
    read -p "Enter the index numbers (separated by spaces) of accounts you want to re-enable [default: re-enable all]: " reenableInput

    reenableIndices=()
    if [[ -n "$reenableInput" ]]; then
        for index in $reenableInput; do
            if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#disabledAccounts[@]}" ]; then
                reenableIndices+=($((index-1)))
            else
                echo -e "${RED}[ERROR]${RESET} Invalid index: $index. Skipping."
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
        reenableUsers=("${disabledAccounts[@]}")
    fi

    echo -e "\nThe following accounts will be ${GREEN}re-enabled${RESET}:"
    for user in "${reenableUsers[@]}"; do
        echo "  $user"
    done

    read -p "Are you sure you want to re-enable these accounts? (y/N): " confirmReenable
    if [[ ! "$confirmReenable" =~ ^[Yy]$ ]]; then
        echo -e "${RED}[ERROR]${RESET} Operation cancelled."
        exit 1
    fi

    # Re-enable each selected user (unlock password, remove expiration).
    for user in "${reenableUsers[@]}"; do
        echo -e "Re-enabling account: ${YELLOW}$user${RESET}"
        usermod -U "$user" 2>>"$LOGFILE" && chage -E -1 "$user" 2>>"$LOGFILE"
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}[OK]${RESET} Account $user re-enabled."
        else
            echo -e "  ${RED}[ERROR]${RESET} Failed to re-enable $user. See $LOGFILE for details."
        fi
    done

    echo
    read -p "Clear the disabled accounts list? (y/N): " clearList
    if [[ "$clearList" =~ ^[Yy]$ ]]; then
        > "$DISABLED_FILE"
        echo -e "${GREEN}[OK]${RESET} Disabled accounts list cleared."
    fi
}

################################################################
# Main logic: choose mode based on command-line argument.
################################################################
if [ "$1" == "--reenable" ]; then
    reenable_accounts
else
    process_accounts
fi
