#!/usr/bin/env bash
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
# 1. Define Color Variables & Helper Functions
################################################################
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

heading() {
  echo -e "\n${BOLD}${BLUE}=== $* ===${RESET}"
}

info() {
  echo -e "${BLUE}[INFO]${RESET} $*"
}

warn() {
  echo -e "${YELLOW}[WARNING]${RESET} $*"
}

error() {
  echo -e "${RED}[ERROR]${RESET} $*"
}

success() {
  echo -e "${GREEN}[OK]${RESET} $*"
}

################################################################
# 2. Ensure the script is run as root.
################################################################
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root. Exiting."
    exit 1
fi

################################################################
# 3. Set Up Logging & Report File
################################################################
REPORT_FILE="/root/sudo_audit_report_$(date +%F_%H-%M-%S).txt"
touch "$REPORT_FILE" && chmod 600 "$REPORT_FILE"
LOGFILE="/var/log/sudo_audit_errors.log"
touch "$LOGFILE" && chmod 600 "$LOGFILE"

{
  echo "Sudo Audit Report - $(date)"
  echo "---------------------------------------"
  echo
} >> "$REPORT_FILE"

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

# Check /etc/sudoers.d if it exists
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

# Remove duplicates
readarray -t uniq_priv_groups < <(printf "%s\n" "${priv_groups[@]}" | sort -u)

info "Sudo-privileged groups detected:" | tee -a "$REPORT_FILE"
for grp in "${uniq_priv_groups[@]}"; do
    echo -e "  ${YELLOW}$grp${RESET}" | tee -a "$REPORT_FILE"
done
echo "" | tee -a "$REPORT_FILE"

################################################################
# 5. Set UID Threshold and Gather Non-Root Users
################################################################
echo -ne "${YELLOW}Enter the minimum UID to check (default is 1000): ${RESET}"
read UID_THRESHOLD
UID_THRESHOLD=${UID_THRESHOLD:-1000}

mapfile -t userList < <(awk -F: -v thresh="$UID_THRESHOLD" '($3 >= thresh && $1!="root") {print $1}' /etc/passwd)
if [ ${#userList[@]} -eq 0 ]; then
    warn "No non-root users found with UID >= $UID_THRESHOLD."
    exit 0
fi

heading "Sudo Privilege Audit"
echo -e "${BOLD}Auditing the following users:${RESET} ${userList[*]}" | tee -a "$REPORT_FILE"

################################################################
# 6. Audit Each User's Sudo Privileges and Group Membership
################################################################
for user in "${userList[@]}"; do
    echo -e "\n${BOLD}${YELLOW}User: $user${RESET}" | tee -a "$REPORT_FILE"
    userGroups=$(id "$user")
    echo -e "${BOLD}Group Membership:${RESET} $userGroups" | tee -a "$REPORT_FILE"
    
    # Check if user is in any sudo-privileged group
    user_grp_list=$(id -nG "$user")
    matching_groups=()
    for grp in "${uniq_priv_groups[@]}"; do
        if echo "$user_grp_list" | grep -qw "$grp"; then
            matching_groups+=("$grp")
        fi
    done

    if [ ${#matching_groups[@]} -gt 0 ]; then
        info "$user belongs to sudo-privileged group(s): ${matching_groups[*]}" | tee -a "$REPORT_FILE"
    else
        info "$user does not belong to any recognized sudo-privileged groups." | tee -a "$REPORT_FILE"
    fi

    echo -e "${BOLD}Sudo privileges (via sudo -l -U $user):${RESET}" | tee -a "$REPORT_FILE"
    sudo_output=$(sudo -l -U "$user" 2>&1)
    if [ $? -ne 0 ]; then
        warn "Could not retrieve sudo privileges for $user. Output:" | tee -a "$REPORT_FILE"
        echo "$sudo_output" | tee -a "$REPORT_FILE"
    else
        echo "$sudo_output" | tee -a "$REPORT_FILE"
    fi
    echo "--------------------------------------------------" | tee -a "$REPORT_FILE"
done

################################################################
# 7. Prompt to Remove Sudo Privileges via Group Membership
################################################################
heading "Sudo Group Membership Removal" | tee -a "$REPORT_FILE"

for user in "${userList[@]}"; do
    user_grp_list=$(id -nG "$user")
    matching_groups=()
    for grp in "${uniq_priv_groups[@]}"; do
        if echo "$user_grp_list" | grep -qw "$grp"; then
            matching_groups+=("$grp")
        fi
    done

    if [ ${#matching_groups[@]} -gt 0 ]; then
        for grp in "${matching_groups[@]}"; do
            echo -ne "${YELLOW}User $user is in group '$grp' (sudo privileges). Remove $user from this group? (y/N): ${RESET}"
            read remove_choice
            if [[ "$remove_choice" =~ ^[Yy]$ ]]; then
                if command -v gpasswd >/dev/null 2>&1; then
                    gpasswd -d "$user" "$grp" 2>>"$LOGFILE"
                else
                    deluser "$user" "$grp" 2>>"$LOGFILE"
                fi
                if [ $? -eq 0 ]; then
                    success "Removed $user from $grp." | tee -a "$REPORT_FILE"
                else
                    error "Failed to remove $user from $grp. Check $LOGFILE for details." | tee -a "$REPORT_FILE"
                fi
            else
                info "Kept $user in group $grp." | tee -a "$REPORT_FILE"
            fi
        done
    fi
done

################################################################
# 8. Audit Completion and Basic Recommendations
################################################################
heading "Audit Completed" | tee -a "$REPORT_FILE"
echo -e "Review the above output for sudo privileges and group memberships.\n" | tee -a "$REPORT_FILE"

echo -e "${BOLD}Recommendations:${RESET}" | tee -a "$REPORT_FILE"
echo -e "  - Manually review any direct sudoers entries (not handled by group membership) in:" | tee -a "$REPORT_FILE"
echo -e "      /etc/sudoers and /etc/sudoers.d/" | tee -a "$REPORT_FILE"
echo -e "  - Check for complex aliases or Defaults settings that may grant elevated privileges." | tee -a "$REPORT_FILE"
echo -e "  - This script covers group-based sudo privileges but may not catch every nuance in sudoers." | tee -a "$REPORT_FILE"
echo -e "  - Further hardening might include editing /etc/sudoers manually using visudo." | tee -a "$REPORT_FILE"

echo -e "\nA final report has been saved to ${YELLOW}$REPORT_FILE${RESET}" | tee -a "$REPORT_FILE"
echo -e "Please perform a manual review of your sudoers configuration for complete security assurance.\n" | tee -a "$REPORT_FILE"

exit 0