#!/bin/bash
# check_sudo_privileges.sh
#
# This script audits sudo privileges on the system by:
#  - Determining which groups have been granted sudo rights (by parsing /etc/sudoers and /etc/sudoers.d/).
#  - Listing non-root users (with UID >= threshold) along with their group memberships.
#  - Running "sudo -l -U <user>" to list the sudo commands allowed for each user.
#  - If the sudo -l command fails (due to system limitations), logs a warning.
#  - For each user, checks if they belong to any sudo-privileged group and then prompts for each group
#    whether to remove the user from that group.
#  - Logs and reports which sudo privileges were removed and which users still have elevated rights.
#  - Provides general advice on further steps and manual review.
#
# Usage: sudo ./check_sudo_privileges.sh
#
# IMPORTANT: Test this script in a lab environment before using it in a competition.

################################################################
# 1. Define Color Variables for Enhanced Output
################################################################
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

################################################################
# 2. Ensure the script is run as root.
################################################################
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${RESET} This script must be run as root. Exiting."
    exit 1
fi

################################################################
# 3. Set Up Logging & Report File
################################################################
REPORT_FILE="/root/sudo_audit_report_$(date +%F_%H-%M-%S).txt"
touch "$REPORT_FILE" && chmod 600 "$REPORT_FILE"
LOGFILE="/var/log/sudo_audit_errors.log"
touch "$LOGFILE" && chmod 600 "$LOGFILE"
echo -e "Sudo Audit Report - $(date)" > "$REPORT_FILE"
echo -e "---------------------------------------\n" >> "$REPORT_FILE"

################################################################
# 4. Determine Sudo-Privileged Groups from Sudoers
################################################################
priv_groups=()
# Parse /etc/sudoers for lines beginning with "%" (group definitions)
while IFS= read -r line; do
    clean=$(echo "$line" | sed 's/^[[:space:]]*//')
    if [[ "$clean" =~ ^%([^[:space:]]+) ]]; then
        group="${BASH_REMATCH[1]}"
        priv_groups+=("$group")
    fi
done < /etc/sudoers

# Check /etc/sudoers.d if exists.
if [ -d /etc/sudoers.d ]; then
    for file in /etc/sudoers.d/*; do
        [ -e "$file" ] || continue
        while IFS= read -r line; do
            clean=$(echo "$line" | sed 's/^[[:space:]]*//')
            if [[ "$clean" =~ ^%([^[:space:]]+) ]]; then
                group="${BASH_REMATCH[1]}"
                priv_groups+=("$group")
            fi
        done < "$file"
    done
fi
# Remove duplicates.
readarray -t uniq_priv_groups < <(printf "%s\n" "${priv_groups[@]}" | sort -u)

echo -e "${BLUE}[INFO]${RESET} Sudo-privileged groups detected:" | tee -a "$REPORT_FILE"
for grp in "${uniq_priv_groups[@]}"; do
    echo -e "  ${YELLOW}$grp${RESET}" | tee -a "$REPORT_FILE"
done
echo "" | tee -a "$REPORT_FILE"

################################################################
# 5. Set UID Threshold and Gather Non-Root Users
################################################################
read -p "Enter the minimum UID to check (default is 1000): " UID_THRESHOLD
UID_THRESHOLD=${UID_THRESHOLD:-1000}

# Get non-root users with UID >= threshold.
userList=( $(awk -F: -v thresh="$UID_THRESHOLD" '($3 >= thresh && $1!="root") {print $1}' /etc/passwd) )
if [ ${#userList[@]} -eq 0 ]; then
    echo -e "${YELLOW}No non-root users found with UID >= $UID_THRESHOLD.${RESET}"
    exit 0
fi

echo -e "\n${BOLD}${BLUE}=== Sudo Privilege Audit ===${RESET}" | tee -a "$REPORT_FILE"

################################################################
# 6. Audit Each User's Sudo Privileges and Group Membership
################################################################
for user in "${userList[@]}"; do
    echo -e "\n${BOLD}${YELLOW}User: $user${RESET}" | tee -a "$REPORT_FILE"
    userGroups=$(id "$user")
    echo -e "${BOLD}Group Membership:${RESET} $userGroups" | tee -a "$REPORT_FILE"
    
    # Check if user is in any sudo-privileged group.
    user_grp_list=$(id -nG "$user")
    matching_groups=()
    for grp in "${uniq_priv_groups[@]}"; do
        if echo "$user_grp_list" | grep -qw "$grp"; then
            matching_groups+=("$grp")
        fi
    done

    if [ ${#matching_groups[@]} -gt 0 ]; then
        echo -e "${BOLD}[INFO]${RESET} $user belongs to sudo-privileged group(s): ${YELLOW}${matching_groups[*]}${RESET}" | tee -a "$REPORT_FILE"
    else
        echo -e "${BOLD}[INFO]${RESET} $user does not belong to any recognized sudo-privileged groups." | tee -a "$REPORT_FILE"
    fi

    # List sudo privileges using sudo -l -U. Fallback if not supported.
    echo -e "${BOLD}Sudo privileges (via sudo -l -U $user):${RESET}" | tee -a "$REPORT_FILE"
    sudo_output=$(sudo -l -U "$user" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}[WARNING]${RESET} Could not retrieve sudo privileges for $user. Output:" | tee -a "$REPORT_FILE"
        echo "$sudo_output" | tee -a "$REPORT_FILE"
    else
        echo "$sudo_output" | tee -a "$REPORT_FILE"
    fi
    echo "--------------------------------------------------" | tee -a "$REPORT_FILE"
done

################################################################
# 7. Prompt to Remove Sudo Privileges via Group Membership
################################################################
echo -e "\n${BOLD}${BLUE}=== Sudo Group Membership Removal ===${RESET}" | tee -a "$REPORT_FILE"
for user in "${userList[@]}"; do
    # Check groups for each user.
    user_grp_list=$(id -nG "$user")
    matching_groups=()
    for grp in "${uniq_priv_groups[@]}"; do
        if echo "$user_grp_list" | grep -qw "$grp"; then
            matching_groups+=("$grp")
        fi
    done

    # If the user is in any sudo-privileged group, prompt per group.
    if [ ${#matching_groups[@]} -gt 0 ]; then
        for grp in "${matching_groups[@]}"; do
            read -p "User $user is in group '$grp' (sudo privileges). Remove $user from this group? (y/N): " remove_choice
            if [[ "$remove_choice" =~ ^[Yy]$ ]]; then
                if command -v gpasswd >/dev/null 2>&1; then
                    gpasswd -d "$user" "$grp" 2>>"$LOGFILE"
                else
                    deluser "$user" "$grp" 2>>"$LOGFILE"
                fi
                if [ $? -eq 0 ]; then
                    echo -e "  ${GREEN}[OK]${RESET} Removed $user from $grp." | tee -a "$REPORT_FILE"
                else
                    echo -e "  ${RED}[ERROR]${RESET} Failed to remove $user from $grp. Check $LOGFILE for details." | tee -a "$REPORT_FILE"
                fi
            else
                echo -e "  ${YELLOW}[INFO]${RESET} Kept $user in group $grp." | tee -a "$REPORT_FILE"
            fi
        done
    fi
done

################################################################
# 8. Final Summary and Recommendations
################################################################
echo -e "\n${BOLD}${BLUE}=== Audit Completed ===${RESET}" | tee -a "$REPORT_FILE"
echo -e "Review the above output for sudo privileges and group memberships." | tee -a "$REPORT_FILE"

echo -e "\n${BOLD}Recommendations:${RESET}" | tee -a "$REPORT_FILE"
echo -e "  - Manually review any direct sudoers entries (not handled by group membership) in:" | tee -a "$REPORT_FILE"
echo -e "      /etc/sudoers and /etc/sudoers.d/" | tee -a "$REPORT_FILE"
echo -e "  - Check for complex aliases or Defaults settings that may grant elevated privileges." | tee -a "$REPORT_FILE"
echo -e "  - This script covers group-based sudo privileges but may not catch every nuance in sudoers." | tee -a "$REPORT_FILE"
echo -e "  - Further hardening might include editing /etc/sudoers manually using visudo." | tee -a "$REPORT_FILE"

################################################################
# 9. Sudo Privilege Summary Table for Remaining (Kept) Users
################################################################
echo -e "\n${BOLD}${BLUE}=== Sudo Privilege Summary Table ===${RESET}"
# Build table header: User | UID | Groups | Sudo Privileges
header="User|UID|Groups|Sudo Privileges"
rows=""
# Function to wrap text to a fixed width.
wrapText() {
    echo "$1" | fold -s -w "$2" | tr '\n' ' '
}

for user in "${keepUsers[@]}"; do
    uid=$(getent passwd "$user" | cut -d: -f3)
    groups_text=$(id -nG "$user")
    sudo_text=$(sudo -l -U "$user" 2>/dev/null)
    if [ $? -ne 0 ]; then
        sudo_text="[WARNING] Unable to retrieve sudo privileges; manual check required."
    fi
    # Wrap the Groups to 30 characters and sudo_text to 50 characters.
    groups_wrapped=$(wrapText "$groups_text" 30)
    sudo_wrapped=$(wrapText "$sudo_text" 50)
    row="$user|$uid|$groups_wrapped|$sudo_wrapped"
    rows+="$row"$'\n'
done

# Print the table header and rows using column.
{
    echo "$header"
    echo "$rows"
} | column -t -s '|'

################################################################
# 10. Final Recommendations and Next Steps
################################################################
echo -e "\n${BOLD}${BLUE}=== Final Recommendations ===${RESET}"
echo -e "1. Manually review any direct sudoers entries in /etc/sudoers and /etc/sudoers.d/." 
echo -e "2. Check for complex sudoers aliases or Defaults settings not covered by this script."
echo -e "3. Confirm that all unwanted sudo privileges have been revoked."
echo -e "4. Use visudo to edit /etc/sudoers manually if further hardening is required."
echo -e "\nA final report has been saved to ${YELLOW}$REPORT_FILE${RESET}"
echo -e "Please perform a manual review of your sudoers configuration for complete security assurance.\n" | tee -a "$REPORT_FILE"

exit 0
