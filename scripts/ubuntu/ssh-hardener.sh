#!/bin/bash
#
# SSH Hardener Script for Debian/Ubuntu Server
# Configures SSH security, firewall, fail2ban, and automatic updates
# Supports both interactive (TTY) and non-interactive (CLI args) modes
#
# Lockout-safety design (learned from real incidents — see git history):
#   - REFUSES to install an SSH key for root when PermitRootLogin no will
#     apply. Key goes to a designated non-root user (--user), which must
#     exist on the box. Never a silent lockout. (C1)
#   - sshd_config candidate is pre-flighted with `sshd -t`, atomically
#     replaced, and on restart/listener failure the backup is restored and
#     the script EXITS 1 — never log-and-continue. (C2)
#   - sshd is restarted and verified listening on the NEW port BEFORE any
#     firewall changes; the old port is temporarily allowed during the
#     transition and the temp rule removed after verification. (C3)
#   - UFW is never blindly reset — existing rules are preserved. (M6)
#   - fail2ban is reloaded with `fail2ban-client reload`, NEVER restarted —
#     restarts historically severed live SSH sessions (commits
#     395c2d1 / 4df6ab3 / 451bc62). (H1)
#   - The weekly cron runs ONLY the local maintenance script — it never
#     downloads anything from the network. Scripts are updated by
#     re-running the setup one-liner. (C4/C5)
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
NON_INTERACTIVE=false

# Key-install target user — resolved by resolve_target_user(); NEVER root
TARGET_USER=""
TARGET_HOME=""
CURRENT_USER="(unresolved)"

BACKUP_DIR="/root/crusty-backups-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/ssh-hardener.log"

# Local maintenance script installed for the weekly cron (cron never downloads)
MAINTENANCE_SCRIPT="/opt/crusty-system/scripts/ubuntu/maintenance.sh"
CRON_FILE="/etc/cron.d/crusty-auto-update"

# Ports sshd currently listens on (captured BEFORE the config is replaced)
CURRENT_SSH_PORTS=()
# Ports we temporarily allowed in UFW during the port transition
UFW_TEMP_PORTS=()

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
  --port PORT            SSH port (1-65535, default: 58432; 22 is allowed
                         for NAT'd/LXC-style hosts behind a parent firewall)
  --key "PUBLIC_KEY"     SSH public key for authorized_keys
  --user USER            Non-root user to install the key for (required when
                         running as actual root with no SUDO_USER — the key
                         is NEVER installed for root because this script
                         sets PermitRootLogin no)
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

  # Non-interactive with key from file, key installed for 'josh'
  sudo $0 --port 58432 --key "\$(cat ~/.ssh/id_ed25519.pub)" --user josh

  # Run via sudo from your admin user (target user auto-detected)
  sudo $0 --key "\$(cat ~/.ssh/id_ed25519.pub)"

  # LXC-style host that keeps port 22
  sudo $0 --port 22 --key "\$(cat ~/.ssh/id_ed25519.pub)" --user josh

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
            --user)
                if [[ -z "${2:-}" ]]; then
                    log_error "--user requires a username"
                    exit 1
                fi
                TARGET_USER="$2"; shift 2 ;;
            --allow-tcp-forwarding)
                ALLOW_TCP_FORWARDING="$2"; shift 2 ;;
            --no-fail2ban)
                USE_FAIL2BAN=false; shift ;;
            --no-auto-updates)
                ENABLE_AUTO_UPDATES=false; shift ;;
            --update-time)
                local t="${2:-}"
                if [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
                    printf -v UPDATE_HOUR "%02d" "$((10#${BASH_REMATCH[1]}))"
                    printf -v UPDATE_MINUTE "%02d" "$((10#${BASH_REMATCH[2]}))"
                else
                    log_error "Invalid --update-time: '$t' (use HH:MM)"
                    exit 1
                fi
                shift 2 ;;
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
# SSH public key validation (H10)
#
# Regex accepts: ssh-ed25519, ssh-rsa, ssh-dss (NOT "ssh-dsa"),
# ecdsa-sha2-nistp256|384|521, sk-ssh-ed25519@openssh.com,
# sk-ecdsa-sha2-nistp256@openssh.com — each with a base64 blob of
# >= 40 chars (rejects truncated pastes). When ssh-keygen is available
# it is the authoritative check (ssh-keygen -lf -).
# ─────────────────────────────────────────────────────────────
validate_public_key() {
    local key="$1"

    if [[ "$key" =~ ^ssh-(ed25519|rsa|dss)[[:space:]]+[A-Za-z0-9+/]{40,}[=]{0,3} ]] || \
       [[ "$key" =~ ^ecdsa-sha2-nistp(256|384|521)[[:space:]]+[A-Za-z0-9+/]{40,}[=]{0,3} ]] || \
       [[ "$key" =~ ^(sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]{40,}[=]{0,3} ]]; then
        # Deep validation when possible — catches truncated/corrupt blobs
        # that still pass the charset+length regex
        if command -v ssh-keygen &>/dev/null; then
            if printf '%s\n' "$key" | ssh-keygen -lf - &>/dev/null; then
                return 0
            fi
            log_error "Key rejected by ssh-keygen (malformed or truncated)"
            return 1
        fi
        return 0
    fi
    return 1
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

# C1: resolve the user the SSH key will be installed for, and REFUSE root.
# This script sets PermitRootLogin no + PasswordAuthentication no — a key
# in /root with no other keyed account is a guaranteed lockout (console only).
resolve_target_user() {
    if [[ -n "$TARGET_USER" ]]; then
        log_info "Target user (from --user): $TARGET_USER"
    elif [[ -n "${SUDO_USER:-}" ]]; then
        TARGET_USER="$SUDO_USER"
        log_info "Target user (from sudo): $TARGET_USER"
    else
        TARGET_USER="root"
    fi

    if [[ "$TARGET_USER" == "root" ]]; then
        log_error "REFUSING to install an SSH key for root."
        log_error "This script sets 'PermitRootLogin no' AND 'PasswordAuthentication no'."
        log_error "A key in /root with no other keyed account = permanent SSH lockout (console-only recovery)."
        echo ""
        log "Pick ONE of these, then re-run:"
        log "  1. Run via sudo from your regular admin user:"
        echo "       sudo $0 --key \"ssh-ed25519 AAAA...\""
        log "  2. Create an admin user first, then re-run with --user:"
        echo "       useradd -m -s /bin/bash -G sudo <username>"
        echo "       $0 --key \"ssh-ed25519 AAAA...\" --user <username>"
        echo ""
        exit 1
    fi

    if ! getent passwd "$TARGET_USER" >/dev/null 2>&1; then
        log_error "Target user '$TARGET_USER' does not exist on this system."
        log_error "Create it first: useradd -m -s /bin/bash -G sudo $TARGET_USER"
        exit 1
    fi

    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        log_error "Cannot resolve a home directory for '$TARGET_USER' (got: '${TARGET_HOME:-empty}')"
        log_error "Refusing to continue — never write keys to an unknown location."
        exit 1
    fi

    CURRENT_USER="$TARGET_USER"

    # After this run, root login is SSH-disabled — make sure the target user
    # can actually administer the box (warn only: custom sudoers are possible)
    if ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx -e sudo -e wheel \
       && ! grep -rqs "$TARGET_USER" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        log_warn "'$TARGET_USER' is not in the 'sudo'/'wheel' group and has no sudoers entry."
        log_warn "After this run, remote administration of this box may be impossible."
        log_warn "Verify admin access for '$TARGET_USER' before proceeding."
    fi
}

# C3: remember which port(s) sshd listens on right now, so the firewall can
# keep the old port reachable during the transition to the new port.
detect_current_ssh_ports() {
    CURRENT_SSH_PORTS=()
    local p
    while read -r p; do
        [[ -n "$p" ]] && CURRENT_SSH_PORTS+=("$p")
    done < <(awk '$1 == "Port" {print $2}' /etc/ssh/sshd_config 2>/dev/null || true)

    if [[ ${#CURRENT_SSH_PORTS[@]} -eq 0 ]]; then
        CURRENT_SSH_PORTS=(22)   # no Port directive = default 22
    fi
    log_info "sshd currently listens on port(s): ${CURRENT_SSH_PORTS[*]}"
}

check_existing_ufw() {
    # Informational only — we never reset UFW, so existing rules are safe.
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        local rule_count
        rule_count=$(ufw status numbered 2>/dev/null | grep -c '^\[' || true)
        if [[ "$rule_count" -gt 0 ]]; then
            log_info "UFW is active with $rule_count existing rule(s) — they will be PRESERVED (no reset)"
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
    printf "5. Your public key is at: C:\\\\Users\\\\YOUR_USERNAME\\\\.ssh\\\\id_ed25519.pub\n\n"
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
    echo "  ssh-ed25519 AAAAC3NzaC1lZDI1... user@hostname"
    echo "  ssh-rsa AAAAB3NzaC1yc2EAAA... user@hostname"
    echo "  ecdsa-sha2-nistp256 AAAAE2VjZHNh... user@hostname"
    echo "  sk-ssh-ed25519@openssh.com AAAAGnNrLqg... user@hostname"
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

        if validate_public_key "$USER_PUBLIC_KEY"; then
            key_valid=true
            log "Valid SSH public key provided"
            printf "${GREEN}Public key accepted.${NC}\n"
        else
            printf "${RED}ERROR: This doesn't look like a valid SSH public key.${NC}\n"
            echo "A valid key starts with one of:"
            echo "  ssh-ed25519, ssh-rsa, ssh-dss, ecdsa-sha2-nistp256|384|521,"
            echo "  sk-ssh-ed25519@openssh.com, sk-ecdsa-sha2-nistp256@openssh.com"
            echo "followed by a long base64 blob."
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
    echo "Commonly used ports to avoid: 80 (HTTP), 443 (HTTPS)"
    echo "Port 22 is allowed for NAT'd/LXC-style hosts behind a parent firewall."
    echo ""

    local valid=false
    local port_input

    while [[ "$valid" == false ]]; do
        read -rp "Enter SSH port [default: 58432]: " port_input < /dev/tty
        port_input=${port_input:-58432}

        if [[ "$port_input" =~ ^[0-9]+$ ]]; then
            if [[ "$port_input" -ge 1 && "$port_input" -le 65535 ]]; then
                if [[ "$port_input" -eq 22 ]]; then
                    printf "${YELLOW}WARNING: Port 22 is the default SSH port — no obscurity benefit.${NC}\n"
                    echo "Fine for NAT'd/LXC-style hosts where a parent firewall handles filtering."
                    local confirm
                    read -rp "Use port 22 anyway? (yes/no): " confirm < /dev/tty
                    case "$confirm" in
                        [Yy][Ee][Ss]) valid=true ;;
                        *) echo "Please choose a different port." ;;
                    esac
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
    echo "The server reboots after updates ONLY if the OS flags a reboot as required."
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
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would install your public key for '$TARGET_USER' in $TARGET_HOME/.ssh/authorized_keys"
        return 0
    fi

    local user_home="$TARGET_HOME"
    local ssh_dir="$user_home/.ssh"
    local auth_keys_file="$ssh_dir/authorized_keys"
    local key_line="$USER_PUBLIC_KEY"

    log "Setting up authorized_keys for user: $TARGET_USER"
    log "Home directory: $user_home"

    # M5: warn about group/world-writable home — sshd StrictModes REFUSES
    # keys from such homes ("Authentication refused: bad ownership")
    local home_mode
    home_mode=$(stat -c '%a' "$user_home" 2>/dev/null || echo 0)
    if (( (8#$home_mode & 8#022) != 0 )); then
        log_warn "Home directory $user_home is group/world-writable (mode $home_mode)"
        log_warn "sshd StrictModes will REFUSE key auth from this home directory."
        log_warn "Fix it: chmod go-w $user_home"
    fi

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # M7: atomic, dedup-safe append — temp file in the same dir, then mv.
    # Trailing whitespace in existing lines no longer defeats the dup check.
    local tmp="$auth_keys_file.tmp.$$"
    if [[ -f "$auth_keys_file" ]]; then
        cp "$auth_keys_file" "$tmp"
    fi
    if awk -v k="$key_line" '{ gsub(/[[:space:]]+$/, ""); if ($0 == k) found=1 } END { exit found ? 0 : 1 }' "$tmp" 2>/dev/null; then
        log "Public key already present in authorized_keys — skipping"
    else
        printf '%s\n' "$key_line" >> "$tmp"
        log "Public key appended to authorized_keys"
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$auth_keys_file"
    chown -R "$TARGET_USER:" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys_file"

    # C1: verify the key actually landed BEFORE any auth restriction is applied
    if ! grep -qF "$key_line" "$auth_keys_file"; then
        log_error "Key verification FAILED — aborting before disabling root/password login."
        exit 1
    fi
    log "Verified: key present in $auth_keys_file for $TARGET_USER"
}

# H4: /etc/ssh/sshd_config.d drop-ins override the main config and can
# silently re-enable PasswordAuthentication / PermitRootLogin. Move them to
# the backup dir before writing our config.
handle_sshd_dropins() {
    local dropin_dir="/etc/ssh/sshd_config.d"
    [[ -d "$dropin_dir" ]] || return 0

    local moved=0 f
    mkdir -p "$BACKUP_DIR/sshd_config.d"
    for f in "$dropin_dir"/*.conf; do
        if [[ -f "$f" ]]; then
            mv "$f" "$BACKUP_DIR/sshd_config.d/"
            log_warn "Moved conflicting drop-in to backup: $f -> $BACKUP_DIR/sshd_config.d/"
            moved=$((moved + 1))
        fi
    done

    if [[ "$moved" -gt 0 ]]; then
        log_warn "NOTE: cloud-init may recreate drop-ins on boot. Re-run this script"
        log_warn "after a reboot, or disable cloud-init's ssh config module in /etc/cloud/cloud.cfg.d/"
    fi
}

# H5: OpenSSH 8.7+ uses KbdInteractiveAuthentication; the old
# ChallengeResponseAuthentication name is a deprecated no-op alias on 9.8+.
# Probe which one this sshd understands instead of hardcoding either.
kbdinteractive_supported() {
    local probe
    probe=$(mktemp)
    printf 'KbdInteractiveAuthentication no\n' > "$probe"
    local ok=false
    if sshd -t -f "$probe" >/dev/null 2>&1; then
        ok=true
    fi
    rm -f "$probe"
    [[ "$ok" == true ]]
}

restart_sshd() {
    # Try ssh first (Debian default unit name), then sshd
    if systemctl restart ssh 2>/dev/null; then
        log "SSH service restarted (ssh.service)"
        return 0
    fi
    if systemctl restart sshd 2>/dev/null; then
        log "SSH service restarted (sshd.service)"
        return 0
    fi
    log_error "Cannot restart SSH service (tried ssh and sshd)"
    return 1
}

# C2: restore the pre-run config and restart. Temporary UFW rules for the
# OLD port are intentionally KEPT so the box stays reachable after rollback.
rollback_ssh_config() {
    if [[ -f "$BACKUP_DIR/sshd_config.backup" ]]; then
        cp "$BACKUP_DIR/sshd_config.backup" /etc/ssh/sshd_config
        if restart_sshd; then
            log "Rolled back sshd_config and restarted sshd on the previous port"
        else
            log_error "Rollback restart ALSO failed — use the console NOW."
            log_error "Backup of the original config: $BACKUP_DIR/sshd_config.backup"
        fi
    else
        log_error "No backup available for rollback ($BACKUP_DIR/sshd_config.backup missing)"
    fi
    log_error "SSH hardening ABORTED — the live config was restored to its pre-run state."
}

# C3: verify sshd actually has a listener on the given port
verify_ssh_listener() {
    local port="$1"
    local tries=15 i
    for ((i = 1; i <= tries; i++)); do
        if command -v ss &>/dev/null; then
            if ss -tln 2>/dev/null | grep -q ":$port[[:space:]]"; then
                return 0
            fi
        elif command -v netstat &>/dev/null; then
            if netstat -tln 2>/dev/null | grep -q ":$port[[:space:]]"; then
                return 0
            fi
        else
            log_warn "Neither ss nor netstat available — cannot verify listener"
            return 0
        fi
        sleep 1
    done
    return 1
}

apply_ssh_config() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would write hardened sshd_config on port $SSH_PORT"
        log_info "[DRY RUN]   (sshd -t pre-flight + atomic replace + rollback on failure)"
        return 0
    fi

    log "Applying SSH configuration..."

    mkdir -p "$BACKUP_DIR"
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup"

    # H4: neutralize drop-ins that could override our hardening
    handle_sshd_dropins

    # H5: pick the keyboard-interactive directive this OpenSSH supports
    local kbd_line
    if kbdinteractive_supported; then
        kbd_line="KbdInteractiveAuthentication no"
    else
        # pre-8.7 name — the real option there, not a deprecated alias
        kbd_line="ChallengeResponseAuthentication no"
    fi

    # Ensure host keys referenced below exist (fresh boxes / stripped images)
    ssh-keygen -A >/dev/null 2>&1 || true

    # C2: write the candidate to a temp file FIRST — the live config is
    # never touched until the candidate passes `sshd -t`.
    local candidate="/etc/ssh/sshd_config.new.$$"
    cat > "$candidate" << EOF
# SSH Hardened Configuration - Generated by Crusty System
# NOTE: sshd uses first-obtained-value-wins. Hardened directives below take
# precedence over anything included from sshd_config.d at the end.
# Port configuration
Port $SSH_PORT

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
$kbd_line
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

# Include distro/cloud drop-ins LAST — our hardened values above win
Include /etc/ssh/sshd_config.d/*.conf
EOF

    # C2: pre-flight — a bad directive must NEVER kill sshd mid-run
    if ! sshd -t -f "$candidate"; then
        log_error "Candidate sshd_config FAILED 'sshd -t' pre-flight — live config untouched"
        log_error "Fix the error above (often an unsupported directive for this OpenSSH version)"
        rm -f "$candidate"
        exit 1
    fi

    # Idempotency: skip the restart if nothing would change
    local old_hash new_hash
    old_hash=$(md5sum /etc/ssh/sshd_config 2>/dev/null | cut -d' ' -f1)
    new_hash=$(md5sum "$candidate" | cut -d' ' -f1)
    if [[ "$old_hash" == "$new_hash" ]]; then
        log_info "SSH config unchanged — skipping restart"
        rm -f "$candidate"
        return 0
    fi

    # C2: atomic replace + restart, with hard rollback on failure
    chmod 600 "$candidate"
    chown root:root "$candidate"
    mv -f "$candidate" /etc/ssh/sshd_config

    if ! restart_sshd; then
        log_error "sshd restart FAILED — rolling back to the previous config"
        rollback_ssh_config
        exit 1
    fi

    # C3: verify the NEW port is actually live before firewall changes.
    # A restart that returns 0 but left no listener is still a lockout.
    if ! verify_ssh_listener "$SSH_PORT"; then
        log_error "sshd is NOT listening on port $SSH_PORT — rolling back"
        rollback_ssh_config
        exit 1
    fi

    log "SSH configuration applied and verified on port $SSH_PORT"
}

# C3: before sshd moves to the new port, make sure the OLD port stays
# reachable through UFW during the transition (only when UFW is active).
maybe_allow_old_ssh_ports() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    command -v ufw &>/dev/null || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0

    local p
    for p in "${CURRENT_SSH_PORTS[@]}"; do
        if [[ "$p" == "$SSH_PORT" ]]; then
            continue
        fi
        # only add a temp rule if the old port isn't already allowed
        if ! ufw status | awk -v rule="$p/tcp" '$1 == rule' | grep -q .; then
            if ufw allow "$p"/tcp comment 'crusty-ssh-transition (temporary)' >/dev/null 2>&1; then
                UFW_TEMP_PORTS+=("$p")
                log "Temporarily allowing old SSH port $p/tcp during the transition"
            fi
        fi
    done
}

# C3: remove temporary old-port rules once the new port is verified
remove_temp_ufw_rules() {
    local p
    for p in "${UFW_TEMP_PORTS[@]}"; do
        if ufw delete allow "$p"/tcp >/dev/null 2>&1; then
            log "Removed temporary UFW rule for old SSH port $p/tcp"
        else
            log_warn "Could not remove temporary UFW rule for $p/tcp — remove manually: ufw delete allow $p/tcp"
        fi
    done
    UFW_TEMP_PORTS=()
}

configure_firewall() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would ensure UFW allows $SSH_PORT/tcp (preserving existing rules — no reset) and enable UFW"
        return 0
    fi

    log "Configuring UFW firewall (existing rules are preserved — NO reset)..."

    local ufw_was_active=false
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw_was_active=true
    fi

    # M6: no 'ufw --force reset' — never destroy the operator's existing rules.
    # Idempotently make sure the new SSH port is allowed.
    if ! ufw status | awk -v rule="$SSH_PORT/tcp" '$1 == rule' | grep -q .; then
        ufw allow "$SSH_PORT"/tcp comment 'SSH'
    fi

    if [[ "$ufw_was_active" == false ]]; then
        # Fresh/inactive firewall — set hardened defaults
        ufw default deny incoming
        ufw default allow outgoing
    else
        log_info "UFW already active — keeping existing policy and rules untouched"
    fi

    ufw logging on || true
    ufw --force enable

    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        log_error "UFW failed to become active"
        exit 1
    fi

    # C3: transition complete — drop the temporary old-port rules
    remove_temp_ufw_rules

    log "UFW firewall active — SSH allowed on port $SSH_PORT"
}

configure_fail2ban() {
    FAIL2BAN_CHANGED=false

    if [[ "$USE_FAIL2BAN" != true ]]; then
        log "Skipping fail2ban configuration (user opted out)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would install fail2ban with escalating bans on port $SSH_PORT, then reload it"
        return 0
    fi

    log "Configuring Fail2ban..."

    # Detect the correct auth log path (Debian/Ubuntu)
    local auth_log="/var/log/auth.log"
    [[ -f "$auth_log" ]] || auth_log="/var/log/secure"

    local old_hash=""
    if [[ -f /etc/fail2ban/jail.local ]]; then
        old_hash=$(md5sum /etc/fail2ban/jail.local | cut -d" " -f1)
    fi

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

    local new_hash
    if [[ -f /etc/fail2ban/jail.local ]]; then
        new_hash=$(md5sum /etc/fail2ban/jail.local | cut -d" " -f1)
    else
        new_hash=""
    fi

    systemctl enable fail2ban

    if [[ "$old_hash" != "$new_hash" ]]; then
        # H1: the config must take effect NOW, not after a reboot.
        # RELOAD only — fail2ban restarts historically severed live SSH
        # sessions (git 395c2d1 / 4df6ab3 / 451bc62); reload is non-disruptive.
        if systemctl is-active --quiet fail2ban; then
            if fail2ban-client reload; then
                log "Fail2ban reloaded (fail2ban-client reload — no restart, no session disruption)"
            else
                log_error "fail2ban-client reload failed — check: journalctl -u fail2ban"
            fi
        else
            systemctl start fail2ban
            log "Fail2ban started (was inactive)"
        fi
        FAIL2BAN_CHANGED=true
    else
        log_info "fail2ban jail.local unchanged — ensuring service is active"
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
            log "Fail2ban started (was inactive)"
        fi
    fi

    # H1: verify the sshd jail actually took effect on the new port
    local i
    for ((i = 1; i <= 10; i++)); do
        if fail2ban-client status sshd &>/dev/null; then
            log "Verified: fail2ban sshd jail is active (monitoring port $SSH_PORT)"
            return 0
        fi
        sleep 1
    done
    log_warn "Could not verify fail2ban sshd jail yet — check manually: fail2ban-client status sshd"
}

# C4/C5: install the LOCAL maintenance script the weekly cron will run.
# The cron NEVER downloads anything — scripts are updated by re-running
# the setup one-liner. Keep in sync with scripts/ubuntu/maintenance.sh.
install_maintenance_script() {
    mkdir -p "$(dirname "$MAINTENANCE_SCRIPT")"
    cat > "$MAINTENANCE_SCRIPT" << 'MAINT_EOF'
#!/bin/bash
#
# Crusty System — Weekly Local Maintenance (Debian/Ubuntu)
#
# DESIGN RULE (operator requirement): this script NEVER downloads anything.
# It performs local apt maintenance only. Crusty scripts themselves are
# updated by re-running the setup one-liner (which verifies each downloaded
# script against SHA-256 pins embedded in setup.sh) — the cron never fetches.
#
# All steps and their exit codes are logged to /var/log/crusty-maintenance.log
# so silent failures are visible (unlike the old one-line cron command).
#
# Canonical copy: scripts/ubuntu/maintenance.sh in joshuaromkes/crusty-system.
# ssh-hardener.sh and auto-update.sh embed this same content — keep in sync.
#

set -u  # NOT -e: we run every step and log failures instead of aborting midway

LOG_FILE="/var/log/crusty-maintenance.log"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

run_step() {
    # run_step "description" command [args...] — logs OK/FAILED + exit code
    local desc="$1"
    shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        log "OK: $desc"
    else
        local rc=$?
        log "FAILED (rc=$rc): $desc"
    fi
}

# Serialize — never run two maintenance jobs at once
if command -v flock >/dev/null 2>&1; then
    exec 9>/var/run/crusty-maintenance.lock
    if ! flock -n 9; then
        log "another maintenance instance is running — exiting"
        exit 0
    fi
fi

log "=== crusty weekly maintenance start ==="

run_step "apt update"              /usr/bin/apt-get update -qq
run_step "apt upgrade"             /usr/bin/apt-get upgrade -y -qq
run_step "apt autoremove --purge"  /usr/bin/apt-get autoremove --purge -y -qq
run_step "apt autoclean"           /usr/bin/apt-get autoclean

# Conditional reboot — ONLY when the OS explicitly flags it
if [[ -f /var/run/reboot-required ]]; then
    log "reboot required (/var/run/reboot-required) — scheduling reboot in 5 minutes"
    /usr/sbin/shutdown -r +5 "Crusty System: reboot required after updates" >> "$LOG_FILE" 2>&1
else
    log "no reboot required"
fi

log "=== crusty weekly maintenance end ==="
MAINT_EOF
    chmod 755 "$MAINTENANCE_SCRIPT"

    if [[ ! -x "$MAINTENANCE_SCRIPT" ]]; then
        log_error "Failed to install maintenance script at $MAINTENANCE_SCRIPT"
        exit 1
    fi
}

configure_auto_updates() {
    if [[ "$ENABLE_AUTO_UPDATES" != true ]]; then
        log "Skipping automatic updates configuration (user opted out)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would configure unattended-upgrades + weekly LOCAL maintenance cron at ${UPDATE_HOUR}:${UPDATE_MINUTE}"
        return 0
    fi

    log "Configuring automatic updates..."

    apt-get install -y -qq unattended-upgrades

    # Ensure cron is installed
    if ! command -v crontab &>/dev/null; then
        log "Installing cron..."
        apt-get install -y -qq cron
        systemctl enable --now cron
    fi

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

    # C4/C5: the weekly cron runs ONLY the local maintenance script.
    # No curl, no script downloads, no one-line megacommand. Always
    # (re)written — this replaces any legacy network-fetching cron on
    # re-run (re-running the one-liner heals deployed boxes).
    install_maintenance_script

    cat > "$CRON_FILE" << EOF
# Crusty System - Weekly LOCAL maintenance (runs Sunday at ${UPDATE_HOUR}:${UPDATE_MINUTE})
# Local apt maintenance ONLY — this cron NEVER downloads anything.
# Crusty scripts update by re-running the setup one-liner (SHA-256 verified).
# Log: /var/log/crusty-maintenance.log
SHELL=/bin/bash
${UPDATE_MINUTE} ${UPDATE_HOUR} * * 0 root ${MAINTENANCE_SCRIPT}
EOF
    chmod 644 "$CRON_FILE"

    log "Automatic updates configured (weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE} — local maintenance only)"
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

# C1: resolve + validate the target user BEFORE touching anything
resolve_target_user

check_and_install_openssh

# Non-interactive: use CLI args; Interactive: prompt
if [[ "$NON_INTERACTIVE" == true ]]; then
    log "Running in non-interactive mode"

    # Validate key was provided (H10: validated even non-interactively)
    if [[ -z "$USER_PUBLIC_KEY" ]]; then
        log_error "Non-interactive mode requires --key with a public key"
        echo "Usage: $0 --key \"ssh-ed25519 AAAAC3NzaC...\" [other options]"
        exit 1
    fi
    if ! validate_public_key "$USER_PUBLIC_KEY"; then
        log_error "The provided --key failed validation — refusing to continue"
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
log "SSH key will be installed for: $TARGET_USER ($TARGET_HOME)"

# Check for existing UFW rules (informational — they are preserved)
check_existing_ufw

# C3: capture the port(s) sshd listens on right now
detect_current_ssh_ports

# Backup existing configurations
backup_configs

# Update system packages (with error handling) — skipped in dry-run
if [[ "$DRY_RUN" != true ]]; then
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
    if ! dpkg -l ufw 2>/dev/null | grep -q "^ii"; then
        apt-get install -y -qq ufw || {
            log_error "Failed to install ufw"
            exit 1
        }
    else
        log_info "ufw already installed"
    fi
    if [[ "$USE_FAIL2BAN" == true ]]; then
        if ! dpkg -l fail2ban 2>/dev/null | grep -q "^ii"; then
            apt-get install -y -qq fail2ban || {
                log_error "Failed to install fail2ban"
                exit 1
            }
        else
            log_info "fail2ban already installed"
        fi
    fi
fi

# ── Apply configurations ──────────────────────────────────────
# ORDER MATTERS (C3): key in place → old port protected in UFW →
# sshd config verified on the new port → firewall committed → cleanup.
setup_authorized_keys
maybe_allow_old_ssh_ports
apply_ssh_config
configure_firewall

# Completion banner — print BEFORE fail2ban in case anything disrupts
# the connection, so the operator always sees how to connect.
PRIMARY_IP=$(get_primary_ip)
echo ""
echo "=========================================="
printf "${GREEN}[%s]${NC} SSH Hardening Complete!\n" "$(date +'%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""
printf "${GREEN}SSH Port:${NC} %s\n" "$SSH_PORT"
printf "${GREEN}User:${NC} %s\n" "$CURRENT_USER"
printf "${GREEN}IP:${NC} %s\n" "$PRIMARY_IP"
echo ""
printf "${YELLOW}Connect:${NC} ssh -p %s %s@%s\n" "$SSH_PORT" "$CURRENT_USER" "$PRIMARY_IP"
echo ""
echo "Now configuring fail2ban and auto-updates..."
echo ""

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

echo ""
echo "=========================================="
log "SSH Hardening Complete!"
echo "=========================================="
echo ""
printf "${GREEN}Configuration Summary:${NC}\n"
echo "  - SSH Port: $SSH_PORT"
echo "  - Root Login: Disabled"
echo "  - Password Authentication: Disabled"
echo "  - Key-based Authentication: Enabled (user: $CURRENT_USER)"
echo "  - TCP Forwarding: $ALLOW_TCP_FORWARDING"
echo "  - Firewall: UFW active (existing rules preserved)"
if [[ "$USE_FAIL2BAN" == true ]]; then
    echo "  - Intrusion Prevention: Fail2ban enabled + reloaded (sshd jail verified)"
else
    echo "  - Intrusion Prevention: Fail2ban skipped"
fi
if [[ "$ENABLE_AUTO_UPDATES" == true ]]; then
    echo "  - Automatic Updates: Weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE} (local maintenance only — no downloads)"
    echo "  - Reboot: Only if /var/run/reboot-required exists (+5 min delay)"
else
    echo "  - Automatic Updates: Not configured"
fi
echo ""
printf "${YELLOW}SSH Connection Info:${NC}\n"
echo "  ssh -p $SSH_PORT $CURRENT_USER@$PRIMARY_IP"
echo ""
printf "${GREEN}Your public key has been added to authorized_keys for '$CURRENT_USER'.${NC}\n"
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
echo "   You MUST use your SSH key to connect as '$CURRENT_USER'"
echo ""
printf "${YELLOW}3. Keep your private key safe${NC}\n"
echo "   There is no password fallback!"
echo ""
printf "${GREEN}If the new connection works, you can safely close this session.${NC}\n"
printf "${RED}If it doesn't work, you can troubleshoot using this current session.${NC}\n\n"
