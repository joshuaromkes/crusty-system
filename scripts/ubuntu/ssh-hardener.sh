#!/bin/bash
#
# SSH Hardener Script for Debian/Ubuntu Server
# Configures SSH security, firewall, fail2ban, and automatic updates
# Supports both interactive (TTY) and non-interactive (CLI args) modes
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
SSH_PORT=58432
USE_FAIL2BAN=true
ENABLE_AUTO_UPDATES=true
UPDATE_HOUR="02"
UPDATE_MINUTE="00"
USER_PUBLIC_KEY=""
ALLOW_TCP_FORWARDING="no"      # "no" | "local" | "yes"
DRY_RUN=false
SKIP_UFW=false
NON_INTERACTIVE=false
CURRENT_USER="${SUDO_USER:-${USER:-root}}"
BACKUP_DIR="/root/crusty-backups-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/ssh-hardener.log"

# Logging functions
log() {
    printf "${GREEN}[%s]${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${GREEN}[%s]${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

log_warn() {
    printf "${YELLOW}[%s] WARNING:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${YELLOW}[%s] WARNING:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

log_error() {
    printf "${RED}[%s] ERROR:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${RED}[%s] ERROR:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

log_info() {
    printf "${BLUE}[%s] INFO:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${BLUE}[%s] INFO:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

# ─────────────────────────────────────────────────────────────
# CLI argument parsing
# ─────────────────────────────────────────────────────────────
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

SSH Hardener for Debian/Ubuntu — configures SSH hardening, UFW firewall,
fail2ban intrusion prevention, and automatic updates.

OPTIONS (non-interactive mode — skips all prompts):
  --port PORT            SSH port (1-65535, default: 58432)
  --key "PUBLIC_KEY"     SSH public key for authorized_keys
  --allow-tcp-forwarding MODE   "no" (default), "local", or "yes"
  --no-fail2ban          Skip fail2ban installation
  --no-auto-updates      Skip automatic updates configuration
  --update-time HH:MM    Update time in 24H format (default: 02:00)
  --dry-run              Show what would be changed without applying
  --help                 Show this help

Without arguments, runs interactively with prompts for all settings.

Examples:
  # Interactive (default)
  sudo $0

  # Non-interactive with key from file
  sudo $0 --port 58432 --key "\$(cat ~/.ssh/id_ed25519.pub)"

  # Headless provisioning — just SSH + firewall, no fail2ban/updates
  sudo $0 --key "\$(cat authorized_key.pub)" --no-fail2ban --no-auto-updates

  # Preview changes
  sudo $0 --port 2222 --key "\$(cat ~/.ssh/id_ed25519.pub)" --dry-run
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                SSH_PORT="$2"; shift 2 ;;
            --key)
                USER_PUBLIC_KEY="$2"; NON_INTERACTIVE=true; shift 2 ;;
            --allow-tcp-forwarding)
                ALLOW_TCP_FORWARDING="$2"; shift 2 ;;
            --no-fail2ban)
                USE_FAIL2BAN=false; shift ;;
            --no-auto-updates)
                ENABLE_AUTO_UPDATES=false; shift ;;
            --update-time)
                UPDATE_HOUR="${2:0:2}"; UPDATE_MINUTE="${2:3:2}"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --help|-h)
                usage ;;
            *)
                log_error "Unknown option: $1"
                echo "Run with --help for usage."
                exit 1 ;;
        esac
    done

    # Validate port if provided
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
        log_error "Invalid port: $SSH_PORT (must be 1-65535)"
        exit 1
    fi

    # Validate allow-tcp-forwarding
    case "$ALLOW_TCP_FORWARDING" in
        no|local|yes) ;;
        *) log_error "Invalid --allow-tcp-forwarding value: $ALLOW_TCP_FORWARDING (use: no, local, yes)"; exit 1 ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# Utility
# ─────────────────────────────────────────────────────────────

get_primary_ip() {
    # Get the primary IP (the one used for default route) — avoids
    # Docker bridges, VPN interfaces, and other secondary IPs
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || \
        hostname -I 2>/dev/null | awk '{print $1}'
}

# ─────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_and_install_openssh() {
    log "Checking for OpenSSH server installation..."

    if command -v sshd &> /dev/null; then
        log "OpenSSH server is already installed"
        return 0
    fi

    if dpkg -l 2>/dev/null | grep -q "^ii  openssh-server"; then
        log "OpenSSH server package is installed but sshd not in PATH"
        return 0
    fi

    log_warn "OpenSSH server is not installed"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        log "Non-interactive mode: installing OpenSSH server automatically"
        if ! apt-get update -qq && apt-get install -y -qq openssh-server; then
            log_error "Failed to install OpenSSH server"
            exit 1
        fi
        systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
        systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
        return 0
    fi

    echo ""
    printf "${YELLOW}OpenSSH server is required for this script to function.${NC}\n"
    echo "It provides the SSH daemon (sshd) that allows remote SSH connections."
    echo ""

    local response
    while true; do
        read -rp "Do you want to install OpenSSH server now? (yes/no) [default: yes]: " response < /dev/tty
        response=${response:-yes}
        case "$response" in
            [Yy][Ee][Ss])
                log "Installing OpenSSH server..."
                if ! apt-get update -qq && apt-get install -y -qq openssh-server; then
                    log_error "Failed to install OpenSSH server"
                    exit 1
                fi
                systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
                systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
                return 0
                ;;
            [Nn][Oo])
                log_error "OpenSSH server is required. Exiting."
                exit 1
                ;;
            *)
                printf "Please answer 'yes' or 'no'.\n" ;;
        esac
    done
}

check_existing_ufw() {
    # Warn if UFW is already active with custom rules before resetting
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        local rule_count
        rule_count=$(ufw status numbered 2>/dev/null | grep -c '^\[' || echo 0)

        if [[ "$rule_count" -gt 0 ]]; then
            log_warn "UFW is already active with $rule_count existing rule(s)"

            if [[ "$NON_INTERACTIVE" == true ]]; then
                # Check if existing rules already match what we want
                if ufw status 2>/dev/null | grep -qE "($SSH_PORT/tcp.*(ALLOW|LIMIT)|(ALLOW|LIMIT).*$SSH_PORT/tcp)"; then
                    log_info "UFW already configured correctly with port $SSH_PORT — skipping firewall setup"
                    SKIP_UFW=true
                    return 0
                fi

                log_error "UFW has existing rules but running in non-interactive mode."
                log_error "Use --dry-run first to review, or clear UFW rules before running."
                log_error "Refusing to reset UFW without confirmation."
                exit 1
            fi

            printf "\n${RED}WARNING: UFW is already active with ${rule_count} existing rule(s).${NC}\n"
            printf "${YELLOW}This script will RESET all UFW rules and replace them.${NC}\n"
            echo "Current rules:"
            ufw status numbered 2>/dev/null
            echo ""
            local confirm
            read -rp "Proceed with UFW reset? (yes/no): " confirm < /dev/tty
            case "$confirm" in
                [Yy][Ee][Ss]) return 0 ;;
                *) log_error "User declined UFW reset. Exiting."; exit 1 ;;
            esac
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
# Interactive prompts
# ─────────────────────────────────────────────────────────────

show_key_generation_instructions() {
    echo ""
    printf "${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    SSH KEY GENERATION INSTRUCTIONS${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"
    printf "${BLUE}You must generate an SSH key pair on your CLIENT machine${NC}\n"
    printf "${BLUE}(the computer you will use to connect to this server)${NC}\n\n"
    echo "The private key stays on your client machine."
    echo "You will provide the PUBLIC key to this script."
    echo ""
    printf "${GREEN}--- Windows (OpenSSH - Windows 10/11) ---${NC}\n"
    printf "1. Open PowerShell or Command Prompt\n"
    printf "2. Run: ssh-keygen -t ed25519 -C \"your_email@example.com\"\n"
    printf "3. Press Enter to accept default location\n"
    printf "4. Enter a passphrase (recommended) or press Enter for none\n"
    printf "5. Your public key is at: C:\\Users\\YOUR_USERNAME\\.ssh\\id_ed25519.pub\n\n"
    printf "${GREEN}--- Windows (PuTTY) ---${NC}\n"
    printf "1. Download PuTTYgen from: https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html\n"
    printf "2. Open PuTTYgen, select 'Ed25519' as the key type\n"
    printf "3. Click 'Generate' and move your mouse randomly\n"
    printf "4. Add a passphrase (optional but recommended)\n"
    printf "5. Save the private key (.ppk file) to your computer\n"
    printf "6. Copy the public key text from the box at the top\n\n"
    printf "${GREEN}--- Linux / macOS ---${NC}\n"
    printf "1. Open a terminal\n"
    printf "2. Run: ssh-keygen -t ed25519 -C \"your_email@example.com\"\n"
    printf "3. Press Enter to accept default location (~/.ssh/id_ed25519)\n"
    printf "4. Enter a passphrase (recommended) or press Enter for none\n"
    printf "5. Your public key is at: ~/.ssh/id_ed25519.pub\n"
    printf "6. View it with: cat ~/.ssh/id_ed25519.pub\n\n"
    printf "${YELLOW}IMPORTANT: Keep your private key secret!${NC}\n"
    printf "${YELLOW}Only share the PUBLIC key (ends in .pub)${NC}\n\n"
    printf "${BLUE}Press Enter when you have generated your SSH key pair...${NC}\n"
    read -r < /dev/tty
}

prompt_public_key() {
    echo ""
    printf "${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    SSH PUBLIC KEY CONFIGURATION${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"
    echo "Please paste your SSH PUBLIC key below."
    echo "The key should look like one of these formats:"
    echo "  ssh-ed25519 AAAAC3NzaC... user@hostname"
    echo "  sk-ssh-ed25519@openssh.com AAAAGnNr... user@hostname"
    echo "  ssh-rsa AAAAB3NzaC1yc... user@hostname"
    echo ""
    printf "${RED}DO NOT paste your private key here!${NC}\n\n"
    printf "${YELLOW}TIP: If you're using VNC/console and copy-paste doesn't work,${NC}\n"
    printf "${YELLOW}try using ClickPaste to simulate keystrokes:${NC}\n"
    printf "${BLUE}  https://github.com/Collective-Software/ClickPaste${NC}\n\n"

    local key_valid=false
    while [[ "$key_valid" == false ]]; do
        printf "${BLUE}Paste your public key (then press Enter):${NC}\n"
        read -r USER_PUBLIC_KEY < /dev/tty

        USER_PUBLIC_KEY=$(echo "$USER_PUBLIC_KEY" | xargs)

        if [[ -z "$USER_PUBLIC_KEY" ]]; then
            printf "${RED}ERROR: Key cannot be empty.${NC}\n"
            continue
        fi

        # Accept standard OpenSSH keys + FIDO2/U2F hardware keys
        if [[ "$USER_PUBLIC_KEY" =~ ^ssh-(ed25519|rsa|ecdsa|dsa)[[:space:]]+[A-Za-z0-9+/]+[=]{0,2} ]] || \
           [[ "$USER_PUBLIC_KEY" =~ ^sk-ssh-(ed25519|ecdsa)@openssh\.com[[:space:]]+ ]]; then
            key_valid=true
            log "Valid SSH public key provided"
            printf "${GREEN}Public key accepted.${NC}\n"
        elif [[ "$USER_PUBLIC_KEY" =~ ^ecdsa-sha2-nistp[[:space:]]+[A-Za-z0-9+/]+[=]{0,2} ]]; then
            key_valid=true
            log "Valid SSH public key provided (ECDSA)"
            printf "${GREEN}Public key accepted.${NC}\n"
        else
            printf "${RED}ERROR: This doesn't look like a valid SSH public key.${NC}\n"
            echo "A valid key starts with 'ssh-ed25519', 'ssh-rsa', 'ssh-ecdsa', 'ssh-dsa',"
            echo "'sk-ssh-ed25519@openssh.com', 'sk-ecds...p256@openssh.com', or 'ecdsa-sha2-nistp...'"
            echo ""
            local retry
            read -rp "Try again? (yes/no): " retry < /dev/tty
            case "$retry" in
                [Nn][Oo])
                    log_error "User declined to provide valid SSH key"
                    exit 1
                    ;;
            esac
        fi
    done
}

prompt_confirmation() {
    echo ""
    printf "${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    SSH HARDENER CONFIGURATION${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"
    echo "This script will make significant changes to your SSH configuration:"
    echo "  - Change the SSH port from default (22) to a custom port"
    echo "  - Disable password authentication (key-based only)"
    echo "  - Disable root login"
    echo "  - Configure firewall rules"
    echo "  - Optionally install and configure fail2ban"
    echo "  - Optionally configure automatic updates"
    echo ""
    printf "${RED}WARNING: After running this script, you will need to:${NC}\n"
    echo "  - Use the new SSH port to connect"
    echo "  - Use SSH key authentication (passwords will not work)"
    echo "  - Configure your SSH clients with the new settings"
    echo ""

    local response
    while true; do
        read -rp "Do you wish to proceed with SSH hardening? (yes/no): " response < /dev/tty
        case "$response" in
            [Yy][Ee][Ss])
                log "User confirmed proceeding with SSH hardening"
                return 0
                ;;
            [Nn][Oo])
                log "User declined SSH hardening. Exiting."
                exit 0
                ;;
            *)
                printf "Please answer 'yes' or 'no'.\n" ;;
        esac
    done
}

prompt_fail2ban() {
    echo ""
    printf "${YELLOW}=== Fail2ban Configuration ===${NC}\n\n"
    echo "Fail2ban provides intrusion prevention by monitoring log files"
    echo "and banning IPs that show malicious signs (e.g., brute force attacks)."
    echo ""

    local response
    while true; do
        read -rp "Do you wish to use fail2ban for intrusion prevention? (yes/no) [default: yes]: " response < /dev/tty
        response=${response:-yes}
        case "$response" in
            [Yy][Ee][Ss])
                USE_FAIL2BAN=true
                log "User chose to enable fail2ban"
                return 0
                ;;
            [Nn][Oo])
                USE_FAIL2BAN=false
                log "User chose to skip fail2ban"
                return 0
                ;;
            *)
                printf "Please answer 'yes' or 'no'.\n" ;;
        esac
    done
}

prompt_ssh_port() {
    echo ""
    printf "${YELLOW}=== SSH Port Configuration ===${NC}\n\n"
    echo "Please specify the desired SSH port."
    echo "Valid range: 1-65535"
    echo "Commonly used ports to avoid: 22 (default SSH), 80 (HTTP), 443 (HTTPS)"
    echo ""

    local valid=false
    local port_input

    while [[ "$valid" == false ]]; do
        read -rp "Enter SSH port [default: 58432]: " port_input < /dev/tty
        port_input=${port_input:-58432}

        if [[ "$port_input" =~ ^[0-9]+$ ]]; then
            if [[ "$port_input" -ge 1 && "$port_input" -le 65535 ]]; then
                if [[ "$port_input" -eq 22 ]]; then
                    printf "${RED}ERROR: Port 22 is the default SSH port. Using it defeats the purpose of hardening.${NC}\n"
                    echo "Please choose a different port."
                elif [[ "$port_input" -eq 80 ]]; then
                    printf "${RED}ERROR: Port 80 is used for HTTP. Please choose a different port.${NC}\n"
                elif [[ "$port_input" -eq 443 ]]; then
                    printf "${RED}ERROR: Port 443 is used for HTTPS. Please choose a different port.${NC}\n"
                elif [[ "$port_input" -lt 1024 ]]; then
                    printf "${YELLOW}WARNING: Ports below 1024 require root privileges and are often reserved.${NC}\n"
                    local confirm
                    read -rp "Are you sure you want to use port $port_input? (yes/no): " confirm < /dev/tty
                    case "$confirm" in
                        [Yy][Ee][Ss]) valid=true ;;
                        *) echo "Please choose a different port." ;;
                    esac
                else
                    valid=true
                fi
            else
                printf "${RED}ERROR: Port must be between 1 and 65535.${NC}\n"
            fi
        else
            printf "${RED}ERROR: Please enter a valid number.${NC}\n"
        fi
    done

    SSH_PORT=$port_input
    echo ""
    printf "${GREEN}SSH port set to: $SSH_PORT${NC}\n"
    log "SSH port configured: $SSH_PORT"
}

prompt_auto_updates() {
    echo ""
    printf "${YELLOW}=== Automatic Updates Configuration ===${NC}\n\n"
    echo "Automatic updates help keep your system secure by installing"
    echo "security patches and updates on a regular schedule."
    echo "The server will restart after updates to ensure all changes take effect."
    echo ""

    local response
    while true; do
        read -rp "Do you want to enable automatic updates? (yes/no) [default: yes]: " response < /dev/tty
        response=${response:-yes}
        case "$response" in
            [Yy][Ee][Ss])
                ENABLE_AUTO_UPDATES=true
                log "User chose to enable automatic updates"
                prompt_update_time
                return 0
                ;;
            [Nn][Oo])
                ENABLE_AUTO_UPDATES=false
                log "User chose to skip automatic updates"
                return 0
                ;;
            *)
                printf "Please answer 'yes' or 'no'.\n" ;;
        esac
    done
}

prompt_update_time() {
    echo ""
    echo "Please specify when you'd like automatic updates to run."
    printf "Enter time in 24-hour format (HH:MM), e.g., 02:00 for 2:00 AM\n\n"

    local valid=false
    local hour
    local minute

    while [[ "$valid" == false ]]; do
        read -rp "Enter update time (HH:MM) [default: 02:00]: " time_input < /dev/tty
        time_input=${time_input:-02:00}

        if [[ "$time_input" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
            # Use 10# to prevent octal interpretation (e.g., 08, 09)
            hour=$((10#${BASH_REMATCH[1]}))
            minute=$((10#${BASH_REMATCH[2]}))

            if [[ "$hour" -ge 0 && "$hour" -le 23 ]]; then
                if [[ "$minute" -ge 0 && "$minute" -le 59 ]]; then
                    valid=true
                else
                    printf "${RED}ERROR: Invalid minutes. Please enter a value between 00 and 59.${NC}\n"
                fi
            else
                printf "${RED}ERROR: Invalid hour. Please enter a value between 00 and 23.${NC}\n"
            fi
        else
            printf "${RED}ERROR: Invalid format. Please use HH:MM format (e.g., 02:00, 14:30)${NC}\n"
        fi
    done

    printf -v UPDATE_HOUR "%02d" "$hour"
    printf -v UPDATE_MINUTE "%02d" "$minute"

    echo ""
    printf "${GREEN}Update time set to: ${UPDATE_HOUR}:${UPDATE_MINUTE} (weekly on Sunday)${NC}\n"
    log "Automatic update time configured: ${UPDATE_HOUR}:${UPDATE_MINUTE}"
}

# ─────────────────────────────────────────────────────────────
# Apply functions
# ─────────────────────────────────────────────────────────────

setup_authorized_keys() {
    local user_home
    if [[ -n "$SUDO_USER" ]]; then
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        user_home="$HOME"
    fi

    local ssh_dir="$user_home/.ssh"
    local auth_keys_file="$ssh_dir/authorized_keys"

    log "Setting up authorized_keys for user: $CURRENT_USER"
    log "Home directory: $user_home"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # Check if key already exists in authorized_keys
    if [[ -f "$auth_keys_file" ]] && grep -qF "$USER_PUBLIC_KEY" "$auth_keys_file"; then
        log "Public key already present in authorized_keys — skipping"
    else
        # Append instead of overwrite (preserves existing keys)
        echo "$USER_PUBLIC_KEY" >> "$auth_keys_file"
        log "Public key appended to authorized_keys"
    fi

    chmod 600 "$auth_keys_file"

    if [[ -n "$SUDO_USER" ]]; then
        chown -R "$SUDO_USER:$SUDO_USER" "$ssh_dir"
        log "Ownership set to $SUDO_USER:$SUDO_USER"
    fi
}

apply_ssh_config() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would write hardened sshd_config on port $SSH_PORT"
        return 0
    fi

    log "Applying SSH configuration..."

    mkdir -p "$BACKUP_DIR"
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup"

    old_hash=$(md5sum /etc/ssh/sshd_config 2>/dev/null | cut -d" " -f1)

    cat > /etc/ssh/sshd_config << EOF
# SSH Hardened Configuration - Generated by Crusty System
# Port configuration
Port $SSH_PORT

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Key algorithms
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Forwarding (configurable)
X11Forwarding no
AllowTcpForwarding $ALLOW_TCP_FORWARDING
AllowAgentForwarding no

# Misc
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

# Connection settings
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
MaxAuthTries 3
MaxStartups 10:30:60

# Logging
SyslogFacility AUTH
LogLevel INFO
EOF

    new_hash=$(md5sum /etc/ssh/sshd_config | cut -d" " -f1)

    if [[ "$old_hash" == "$new_hash" ]]; then
        log_info "SSH config unchanged — skipping restart"
        return 0
    fi

    # Restart SSH — try ssh first (Debian default), then sshd
    if systemctl restart ssh 2>/dev/null; then
        log "SSH service restarted (ssh.service)"
    elif systemctl restart sshd 2>/dev/null; then
        log "SSH service restarted (sshd.service)"
    else
        log_error "Cannot restart SSH service (tried ssh and sshd)"
    fi

    log "SSH configuration applied on port $SSH_PORT"
}

configure_firewall() {
    if [[ "$SKIP_UFW" == true ]]; then
        log_info "UFW already configured — skipping"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would reset UFW, allow port $SSH_PORT/tcp, and enable firewall"
        return 0
    fi

    log "Configuring UFW firewall..."

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp comment 'SSH'
    ufw logging on
    ufw --force enable

    log "UFW firewall configured — SSH allowed on port $SSH_PORT"
}

configure_fail2ban() {
    if [[ "$USE_FAIL2BAN" != true ]]; then
        log "Skipping fail2ban configuration (user opted out)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would install fail2ban with escalating bans on port $SSH_PORT"
        return 0
    fi

    log "Configuring Fail2ban..."

    # Detect the correct auth log path (Debian/Ubuntu)
    local auth_log="/var/log/auth.log"
    [[ -f "$auth_log" ]] || auth_log="/var/log/secure"

    old_hash=$(md5sum /etc/fail2ban/jail.local 2>/dev/null | cut -d" " -f1)

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Ban duration: 10 minutes initial, doubles on repeat (max 7 days)
bantime = 600
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 604800

# Time window for counting failures
findtime = 600

# Number of failures before ban
maxretry = 3

# Backend for log monitoring
backend = auto

# Email notifications (optional — configure if needed)
# destemail = your-email@example.com
# sendername = Fail2Ban
# mta = sendmail

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = $auth_log
maxretry = 3
bantime = 3600
findtime = 600
EOF

    new_hash=$(md5sum /etc/fail2ban/jail.local | cut -d" " -f1)

    if [[ "$old_hash" == "$new_hash" ]]; then
        log_info "fail2ban jail.local unchanged — skipping restart"
        return 0
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban

    log "Fail2ban configured and started (escalating bans on port $SSH_PORT)"
}

configure_auto_updates() {
    if [[ "$ENABLE_AUTO_UPDATES" != true ]]; then
        log "Skipping automatic updates configuration (user opted out)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would configure unattended-upgrades + weekly cron at ${UPDATE_HOUR}:${UPDATE_MINUTE}"
        return 0
    fi

    log "Configuring automatic updates..."

    apt-get install -y -qq unattended-upgrades

    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
    // Add packages to exclude from automatic updates
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    # Root crontab — no sudo needed
    if [[ -f /etc/cron.d/crusty-auto-update ]]; then
        log_info "Auto-update cron already exists — skipping"
        return 0
    fi
    cat > /etc/cron.d/crusty-auto-update << EOF
# Crusty System - Weekly automatic updates at ${UPDATE_HOUR}:${UPDATE_MINUTE}
SHELL=/bin/bash
${UPDATE_MINUTE} ${UPDATE_HOUR} * * 0 root /usr/bin/apt-get update -qq && /usr/bin/apt-get upgrade -y -qq && if [ -f /var/run/reboot-required ]; then /usr/sbin/shutdown -r +5 "Crusty System: reboot required after updates"; fi
EOF
    chmod 644 /etc/cron.d/crusty-auto-update

    log "Automatic updates configured (weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE})"
}

backup_configs() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would back up existing configs to $BACKUP_DIR"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    log "Created backup directory: $BACKUP_DIR"

    local f
    for f in "/etc/ssh/sshd_config" "/etc/ufw/default" "/etc/fail2ban/jail.local"; do
        if [[ -f "$f" ]]; then
            cp "$f" "$BACKUP_DIR/"
            log "Backed up: $f"
        fi
    done
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

# Check for --help before root check (help should work without root)
for arg in "$@"; do
    if [[ "$arg" == "--help" ]] || [[ "$arg" == "-h" ]]; then
        usage
    fi
done

check_root
parse_args "$@"

# Warn about dry-run mode upfront
if [[ "$DRY_RUN" == true ]]; then
    echo ""
    printf "${BLUE}==========================================${NC}\n"
    printf "${BLUE}           DRY RUN MODE${NC}\n"
    printf "${BLUE}==========================================${NC}\n"
    echo ""
    echo "No changes will be made. Preview of what would happen:"
    echo "  SSH Port: $SSH_PORT"
    echo "  TCP Forwarding: $ALLOW_TCP_FORWARDING"
    echo "  Fail2ban: $([[ "$USE_FAIL2BAN" == true ]] && echo 'enabled' || echo 'disabled')"
    echo "  Auto Updates: $([[ "$ENABLE_AUTO_UPDATES" == true ]] && echo "enabled (${UPDATE_HOUR}:${UPDATE_MINUTE})" || echo 'disabled')"
    echo "  Key: $([[ -n "$USER_PUBLIC_KEY" ]] && echo 'provided' || echo 'not provided')"
    echo ""
fi

check_and_install_openssh

# Non-interactive: use CLI args; Interactive: prompt
if [[ "$NON_INTERACTIVE" == true ]]; then
    log "Running in non-interactive mode"

    # Validate key was provided
    if [[ -z "$USER_PUBLIC_KEY" ]]; then
        log_error "Non-interactive mode requires --key with a public key"
        echo "Usage: $0 --key \"ssh-ed25519 AAAAC3NzaC...\" [other options]"
        exit 1
    fi
else
    show_key_generation_instructions
    prompt_public_key
    prompt_confirmation
    prompt_fail2ban
    prompt_ssh_port
    prompt_auto_updates
fi

echo ""
printf "${GREEN}==========================================${NC}\n"
printf "${GREEN}    Starting SSH Hardening Process${NC}\n"
printf "${GREEN}==========================================${NC}\n\n"

log "Starting SSH Hardener Script..."

# Check for existing UFW rules before proceeding
check_existing_ufw

# Backup existing configurations
backup_configs

# Update system packages (with error handling)
log "Updating system packages..."
if ! apt-get update -qq; then
    log_error "apt-get update failed — check network connection"
    exit 1
fi
if ! apt-get upgrade -y -qq; then
    log_warn "apt-get upgrade had errors — continuing anyway (some packages may be held)"
fi

# Install required packages
log "Installing required packages..."
if [[ "$USE_FAIL2BAN" == true ]]; then
    if ! dpkg -l ufw 2>/dev/null | grep -q "^ii"; then
        apt-get install -y -qq ufw || {
            log_error "Failed to install ufw"
            exit 1
        }
    else
        log_info "ufw already installed"
    fi
    if ! dpkg -l fail2ban 2>/dev/null | grep -q "^ii"; then
        apt-get install -y -qq fail2ban || {
            log_error "Failed to install fail2ban"
            exit 1
        }
    else
        log_info "fail2ban already installed"
    fi
else
    if ! dpkg -l ufw 2>/dev/null | grep -q "^ii"; then
        apt-get install -y -qq ufw || {
            log_error "Failed to install ufw"
            exit 1
        }
    else
        log_info "ufw already installed"
    fi
fi

# Apply configurations
setup_authorized_keys
configure_firewall
apply_ssh_config
configure_fail2ban
configure_auto_updates

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    printf "${BLUE}==========================================${NC}\n"
    printf "${BLUE}    DRY RUN COMPLETE — no changes made${NC}\n"
    printf "${BLUE}==========================================${NC}\n\n"
    exit 0
fi

PRIMARY_IP=$(get_primary_ip)

echo ""
echo "=========================================="
log "SSH Hardening Complete!"
echo "=========================================="
echo ""
printf "${GREEN}Configuration Summary:${NC}\n"
echo "  - SSH Port: $SSH_PORT"
echo "  - Root Login: Disabled"
echo "  - Password Authentication: Disabled"
echo "  - Key-based Authentication: Enabled"
echo "  - TCP Forwarding: $ALLOW_TCP_FORWARDING"
echo "  - Firewall: UFW enabled"
if [[ "$USE_FAIL2BAN" == true ]]; then
    echo "  - Intrusion Prevention: Fail2ban active (escalating bans)"
else
    echo "  - Intrusion Prevention: Fail2ban skipped"
fi
if [[ "$ENABLE_AUTO_UPDATES" == true ]]; then
    echo "  - Automatic Updates: Weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE}"
    echo "  - Auto Restart: Enabled (server will restart after updates)"
else
    echo "  - Automatic Updates: Not configured"
fi
echo ""
printf "${YELLOW}SSH Connection Info:${NC}\n"
echo "  ssh -p $SSH_PORT $CURRENT_USER@$PRIMARY_IP"
echo ""
printf "${GREEN}Your public key has been added to authorized_keys.${NC}\n"
echo ""
printf "${YELLOW}Backup Location:${NC}\n"
echo "  $BACKUP_DIR"
echo ""
printf "${YELLOW}Log File:${NC}\n"
echo "  $LOG_FILE"
echo ""
printf "${RED}==========================================${NC}\n"
printf "${RED}              IMPORTANT!${NC}\n"
printf "${RED}==========================================${NC}\n\n"
printf "${YELLOW}1. DO NOT close this session until you've tested the new connection!${NC}\n"
echo "   Open a new terminal/SSH window and test connecting with:"
printf "   ${GREEN}ssh -p $SSH_PORT $CURRENT_USER@$PRIMARY_IP${NC}\n\n"
printf "${YELLOW}2. Password authentication is now DISABLED${NC}\n"
echo "   You MUST use your SSH key to connect"
echo ""
printf "${YELLOW}3. Keep your private key safe${NC}\n"
echo "   There is no password fallback!"
echo ""
printf "${GREEN}If the new connection works, you can safely close this session.${NC}\n"
printf "${RED}If it doesn't work, you can troubleshoot using this current session.${NC}\n\n"
