#!/bin/bash
# Script: interactive-harden-ssh.sh
# Purpose: Interactively harden SSH by letting the user choose settings.
# Features:
#   - Detects Debian-based vs. RHEL-based OS to choose the correct SSH service name
#   - Provides an interactive menu for each SSH option with color-coded hints
#   - Comments out any existing lines for each directive, then appends the chosen settings at the end
#   - Displays a color-coded summary of changes
#
# CAUTION: Test in a safe environment first. Ensure you have a backup method (e.g., console access).

####################################
# Color Variables for Pretty Output
####################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

####################################
# Detect OS and Set SSH Service Name
####################################
if command -v apt-get &>/dev/null; then
  SSH_SERVICE="ssh"
elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
  SSH_SERVICE="sshd"
else
  SSH_SERVICE="sshd"
fi

CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%F_%T)"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Please run as root.${NC}"
  exit 1
fi

echo -e "${YELLOW}[+] Backing up current SSH config to ${BACKUP_FILE}${NC}"
cp "$CONFIG_FILE" "$BACKUP_FILE"

####################################
# Interactive prompts for each setting
####################################

# 1. Protocol (only option SSH Protocol 2 is secure)
echo -e "\n${BLUE}[+] Protocol${NC} (Only SSH Protocol 2 is secure. Press Enter for default ${GREEN}(2)${NC}):"
read -rp "> " protocol
if [ -z "$protocol" ]; then protocol="2"; fi

# 2. PermitRootLogin
echo -e "\n${BLUE}[+] Select PermitRootLogin setting:${NC}"
echo -e "  1) no                - ${GREEN}Disable all root logins (recommended)${NC}"
echo -e "  2) prohibit-password - ${YELLOW}Allow root login with keys only (if needed)${NC}"
echo -e "  3) yes               - ${RED}Allow all root logins (not recommended)${NC}"
read -rp "Enter option number (default 1): " prl_choice
case "$prl_choice" in
  2) permit_root_login="prohibit-password" ;;
  3) permit_root_login="yes" ;;
  *) permit_root_login="no" ;;
esac

# 3. PasswordAuthentication
echo -e "\n${BLUE}[+] Select PasswordAuthentication setting:${NC}"
echo -e "  1) no  - ${GREEN}Disable password authentication (recommended)${NC}"
echo -e "  2) yes - ${RED}Enable password authentication (less secure)${NC}"
read -rp "Enter option number (default 1): " pa_choice
case "$pa_choice" in
  2) password_auth="yes" ;;
  *) password_auth="no" ;;
esac

# 4. ChallengeResponseAuthentication
echo -e "\n${BLUE}[+] Select ChallengeResponseAuthentication setting:${NC}"
echo -e "  1) no  - ${GREEN}Disable challenge-response authentication (recommended)${NC}"
echo -e "  2) yes - ${YELLOW}Enable challenge-response authentication${NC}"
read -rp "Enter option number (default 1): " cra_choice
case "$cra_choice" in
  2) challenge_response="yes" ;;
  *) challenge_response="no" ;;
esac

# 5. PermitEmptyPasswords
echo -e "\n${BLUE}[+] Select PermitEmptyPasswords setting:${NC}"
echo -e "  1) no  - ${GREEN}Do not allow login with empty passwords (recommended)${NC}"
echo -e "  2) yes - ${RED}Allow empty password logins (not recommended)${NC}"
read -rp "Enter option number (default 1): " pep_choice
case "$pep_choice" in
  2) permit_empty_passwords="yes" ;;
  *) permit_empty_passwords="no" ;;
esac

# 6. X11Forwarding
echo -e "\n${BLUE}[+] Select X11Forwarding setting:${NC}"
echo -e "  1) no  - ${GREEN}Disable X11 forwarding (recommended for security)${NC}"
echo -e "  2) yes - ${YELLOW}Enable X11 forwarding (if required for GUI applications)${NC}"
read -rp "Enter option number (default 1): " x11_choice
case "$x11_choice" in
  2) x11_forwarding="yes" ;;
  *) x11_forwarding="no" ;;
esac

# 7. UsePAM
echo -e "\n${BLUE}[+] Select UsePAM setting:${NC}"
echo -e "  1) yes - ${GREEN}Enable PAM for authentication, session, and account management (recommended)${NC}"
echo -e "  2) no  - ${RED}Disable PAM integration${NC}"
read -rp "Enter option number (default 1): " pam_choice
case "$pam_choice" in
  2) use_pam="no" ;;
  *) use_pam="yes" ;;
esac

# 8. LogLevel
echo -e "\n${BLUE}[+] Select LogLevel setting:${NC}"
echo -e "  1) VERBOSE - ${GREEN}Detailed logging for auditing (recommended)${NC}"
echo -e "  2) INFO    - ${YELLOW}Normal logging level${NC}"
echo -e "  3) DEBUG   - ${RED}Highly verbose logging (not recommended for production)${NC}"
read -rp "Enter option number (default 1): " log_choice
case "$log_choice" in
  2) log_level="INFO" ;;
  3) log_level="DEBUG" ;;
  *) log_level="VERBOSE" ;;
esac

# 9. ClientAliveInterval (in seconds)
echo -e "\n${BLUE}[+] ClientAliveInterval${NC} in seconds (default ${GREEN}300${NC}):"
read -rp "> " client_alive_interval
if [ -z "$client_alive_interval" ]; then client_alive_interval="300"; fi

# 10. ClientAliveCountMax
echo -e "\n${BLUE}[+] ClientAliveCountMax${NC} (default ${GREEN}0${NC}):"
read -rp "> " client_alive_count_max
if [ -z "$client_alive_count_max" ]; then client_alive_count_max="0"; fi

####################################
# Build the settings associative array
####################################
declare -A settings=(
  ["Protocol"]="$protocol"
  ["PermitRootLogin"]="$permit_root_login"
  ["PasswordAuthentication"]="$password_auth"
  ["ChallengeResponseAuthentication"]="$challenge_response"
  ["PermitEmptyPasswords"]="$permit_empty_passwords"
  ["X11Forwarding"]="$x11_forwarding"
  ["UsePAM"]="$use_pam"
  ["LogLevel"]="$log_level"
  ["ClientAliveInterval"]="$client_alive_interval"
  ["ClientAliveCountMax"]="$client_alive_count_max"
)

####################################
# Function to comment out any existing directive lines
####################################
comment_existing() {
  local key="$1"
  sed -i "/^\s*${key}\s/ s/^/# /" "$CONFIG_FILE"
}

echo -e "\n${YELLOW}[+] Commenting out any existing settings for our directives...${NC}"
for key in "${!settings[@]}"; do
  comment_existing "$key"
done

####################################
# Append the new override settings at the end of the file
####################################
{
  echo ""
  echo "# Override settings added by interactive-harden-ssh.sh on $(date)"
  for key in "${!settings[@]}"; do
    echo "${key} ${settings[$key]}"
  done
} >> "$CONFIG_FILE"

####################################
# Validate SSH Configuration
####################################
echo -e "\n${YELLOW}[+] Testing SSH configuration syntax...${NC}"
if sshd -t; then
  echo -e "${GREEN}[+] Configuration test passed.${NC}"
else
  echo -e "${RED}[!] Configuration test failed. Restoring backup...${NC}"
  cp "$BACKUP_FILE" "$CONFIG_FILE"
  exit 1
fi

####################################
# Restart SSH Service
####################################
echo -e "\n${YELLOW}[+] Restarting SSH service: ${SSH_SERVICE}.service${NC}"
if systemctl restart "${SSH_SERVICE}.service"; then
  echo -e "${GREEN}[+] SSH service restarted successfully.${NC}"
else
  echo -e "${RED}[!] Failed to restart ${SSH_SERVICE}.service. Restoring backup...${NC}"
  cp "$BACKUP_FILE" "$CONFIG_FILE"
  exit 1
fi

####################################
# Summary of Changes
####################################
echo -e "\n${GREEN}[+] Summary of SSH settings applied:${NC}"
for key in "${!settings[@]}"; do
  echo -e "  ${BLUE}${key}${NC}: ${settings[$key]}"
done
