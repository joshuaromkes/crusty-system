#!/bin/sh
#
# Alpine Linux Setup Script
# Installs common packages, configures SSH hardening, UFW firewall,
# fail2ban intrusion prevention, and automatic updates.
#
# One-liner execution:
#   curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/alpine/setup.sh | sh
#
# Or download and run:
#   wget https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/alpine/setup.sh
#   sh setup.sh
#
# Lockout safety: this script sets PermitRootLogin no — it REFUSES to
# install your SSH key for root (that would lock you out). The key goes
# to a non-root user detected via SUDO_USER/DOAS_USER, or create one first.
#

set -eu

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurable defaults
SSH_PORT=58432
USE_FAIL2BAN=true
USE_UFW=true
ENABLE_AUTO_UPDATES=true
UPDATE_HOUR="02"
UPDATE_MINUTE="00"
USER_PUBLIC_KEY=""
BACKUP_DIR="/root/crusty-backups-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/alpine-setup.log"
NON_INTERACTIVE=false
MAINTENANCE_SCRIPT="/usr/local/sbin/crusty-maintenance"

# Detect privilege escalation command (Alpine uses doas by default, fall back to sudo)
if command -v doas >/dev/null 2>&1; then
    ESCALATE="doas"
elif command -v sudo >/dev/null 2>&1; then
    ESCALATE="sudo"
else
    ESCALATE=""
fi

# ─── Logging ──────────────────────────────────────────────────

log() {
    _ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    printf "${GREEN}%s${NC} %s\n" "$_ts" "$1"
    printf "%s %s\n" "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    _ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    printf "${YELLOW}%s WARNING:${NC} %s\n" "$_ts" "$1"
    printf "%s WARNING: %s\n" "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    _ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    printf "${RED}%s ERROR:${NC} %s\n" "$_ts" "$1"
    printf "%s ERROR: %s\n" "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() {
    _ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    printf "${BLUE}%s INFO:${NC} %s\n" "$_ts" "$1"
    printf "%s INFO: %s\n" "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Utilities ────────────────────────────────────────────────

# POSIX-compatible prompt (ash doesn't support read -p with prompt string)
prompt() {
    _prompt="$1"
    _default="$2"
    printf "%s " "$_prompt"
    read -r _response </dev/tty
    if [ -z "$_response" ] && [ -n "$_default" ]; then
        _response="$_default"
    fi
    echo "$_response"
}

prompt_yes_no() {
    _prompt="$1"
    _default="$2"
    while true; do
        printf "%s " "$_prompt"
        read -r _response </dev/tty
        if [ -z "$_response" ] && [ -n "$_default" ]; then
            _response="$_default"
        fi
        case "$_response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) printf "Please answer 'yes' or 'no'.\n" ;;
        esac
    done
}

get_primary_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || \
        hostname -I 2>/dev/null | awk '{print $1}'
}

# ─── Pre-flight ───────────────────────────────────────────────

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "${RED}This script must be run as root.${NC}\n"
        if [ -n "$ESCALATE" ]; then
            printf "Try: ${YELLOW}%s sh setup.sh${NC}\n" "$ESCALATE"
        fi
        exit 1
    fi
}

enable_community_repo() {
    log "Checking community repository..."
    if grep -q '^http.*/community$' /etc/apk/repositories 2>/dev/null; then
        log "Community repository already enabled"
        return 0
    fi

    log_info "Enabling community repository (needed for ufw)..."
    # Alpine 3.16+ uses single-line repos; find main repo and derive community
    _main_repo=$(grep '^http.*/main$' /etc/apk/repositories 2>/dev/null | head -1)
    if [ -n "$_main_repo" ]; then
        _community_repo=$(echo "$_main_repo" | sed 's|/main$|/community|')
        echo "$_community_repo" >> /etc/apk/repositories
        log "Community repository enabled: $_community_repo"
    else
        log_warn "Could not detect main repository — you may need to enable community repo manually"
    fi
}

# ─── Interactive Prompts ──────────────────────────────────────

prompt_additional_packages() {
    printf "\n${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    ADDITIONAL PACKAGES${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"
    printf "Commonly useful packages for Alpine Linux:\n\n"
    printf "  ${GREEN}nano${NC}        - Simple text editor (easier than vi)\n"
    printf "  ${GREEN}bash${NC}        - Bash shell (more features than ash)\n"
    printf "  ${GREEN}curl${NC}        - HTTP client (wget is pre-installed)\n"
    printf "  ${GREEN}htop${NC}        - Interactive process viewer\n"
    printf "  ${GREEN}tmux${NC}        - Terminal multiplexer\n"
    printf "  ${GREEN}git${NC}         - Version control\n"
    printf "  ${GREEN}rsyslog${NC}     - System logging daemon\n"
    printf "  ${GREEN}chrony${NC}      - NTP client for time sync\n"
    printf "  ${GREEN}neofetch${NC}    - System info display\n"
    printf "\n"

    _install_pkgs=""
    if prompt_yes_no "Install commonly useful packages? (yes/no) [default: yes]" "yes"; then
        printf "\nSelect packages to install:\n\n"

        for _pkg in nano bash curl htop tmux git rsyslog chrony neofetch; do
            if prompt_yes_no "  Install ${GREEN}${_pkg}${NC}? (yes/no) [default: yes]" "yes"; then
                _install_pkgs="$_install_pkgs $_pkg"
            fi
        done
    fi

    ADDITIONAL_PACKAGES="$_install_pkgs"
    printf "\n${GREEN}Selected packages:%s${NC}\n" "${ADDITIONAL_PACKAGES:- (none)}"
    log "Additional packages selected:${ADDITIONAL_PACKAGES:- (none)}"
}

prompt_sshd_setup() {
    printf "\n${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    SSH SERVER SETUP${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"

    if ! prompt_yes_no "Install and configure OpenSSH server? (yes/no) [default: yes]" "yes"; then
        INSTALL_SSHD=false
        log "SSH server setup skipped by user"
        return 0
    fi

    INSTALL_SSHD=true

    printf "\n${BLUE}SSH Key Setup${NC}\n"
    printf "You will need an SSH public key from your CLIENT machine.\n"
    printf "Generate one if needed:\n"
    printf "  ${GREEN}ssh-keygen -t ed25519 -C \"your_email@example.com\"${NC}\n\n"

    # Prompt for public key with validation
    _key_valid=false
    while [ "$_key_valid" = false ]; do
        printf "${BLUE}Paste your SSH PUBLIC key (then press Enter):${NC}\n"
        read -r USER_PUBLIC_KEY </dev/tty

        # Trim
        USER_PUBLIC_KEY=$(echo "$USER_PUBLIC_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [ -z "$USER_PUBLIC_KEY" ]; then
            printf "${RED}ERROR: Key cannot be empty.${NC}\n"
            continue
        fi

        # Validate format: real key types + a base64 blob of >= 40 chars
        # (rejects truncated pastes). ssh-dss (not "ssh-dsa"), ecdsa
        # nistp256/384/521, and both sk- FIDO variants.
        case "$USER_PUBLIC_KEY" in
            ssh-ed25519\ *|ssh-rsa\ *|ssh-dss\ *|\
            ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *|\
            sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *)
                if echo "$USER_PUBLIC_KEY" | awk 'NF >= 2 && length($2) >= 40 { exit 0 } exit 1'; then
                    _key_valid=true
                    printf "${GREEN}Public key accepted.${NC}\n"
                else
                    printf "${RED}ERROR: Key blob is too short — the paste looks truncated.${NC}\n"
                fi
                ;;
            *)
                printf "${RED}ERROR: This doesn't look like a valid SSH public key.${NC}\n"
                printf "Expected format: ssh-ed25519 AAAAC3NzaC1lZDI1... user@host\n"
                if ! prompt_yes_no "Try again?" "yes"; then
                    log_error "User declined to provide a valid SSH key"
                    exit 1
                fi
                ;;
        esac
    done

    # SSH port
    printf "\n${YELLOW}SSH Port Configuration${NC}\n\n"
    _port_valid=false
    while [ "$_port_valid" = false ]; do
        printf "Enter SSH port [default: %s]: " "$SSH_PORT"
        read -r _port_input </dev/tty
        _port_input=${_port_input:-$SSH_PORT}

        case "$_port_input" in
            ''|*[!0-9]*)
                printf "${RED}ERROR: Please enter a valid number.${NC}\n" ;;
            *)
                if [ "$_port_input" -lt 1 ] || [ "$_port_input" -gt 65535 ]; then
                    printf "${RED}ERROR: Port must be between 1 and 65535.${NC}\n"
                elif [ "$_port_input" -eq 22 ]; then
                    printf "${YELLOW}WARNING: Port 22 is the default SSH port — no obscurity benefit.${NC}\n"
                    printf "Fine for NAT'd/LXC-style hosts behind a parent firewall.\n"
                    if prompt_yes_no "Use port 22 anyway? (yes/no)" "no"; then
                        _port_valid=true
                    fi
                elif [ "$_port_input" -eq 80 ] || [ "$_port_input" -eq 443 ]; then
                    printf "${RED}ERROR: Port ${_port_input} is used for HTTP/HTTPS.${NC}\n"
                elif [ "$_port_input" -lt 1024 ]; then
                    printf "${YELLOW}WARNING: Ports below 1024 are privileged.${NC}\n"
                    if prompt_yes_no "Use port $_port_input anyway? (yes/no)" "no"; then
                        _port_valid=true
                    fi
                else
                    _port_valid=true
                fi
                ;;
        esac
    done
    SSH_PORT="$_port_input"
    printf "${GREEN}SSH port set to: %s${NC}\n" "$SSH_PORT"
}

prompt_ufw_setup() {
    printf "\n${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    FIREWALL SETUP${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"

    if prompt_yes_no "Install and configure UFW firewall? (yes/no) [default: yes]" "yes"; then
        USE_UFW=true
        printf "${GREEN}UFW firewall will be installed and configured.${NC}\n"
    else
        USE_UFW=false
        printf "${YELLOW}UFW firewall will be skipped.${NC}\n"
    fi
}

prompt_fail2ban_setup() {
    printf "\n${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    FAIL2BAN SETUP${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"

    printf "Fail2ban prevents brute-force attacks by banning IPs\n"
    printf "after repeated failed login attempts.\n\n"

    if prompt_yes_no "Install and configure fail2ban? (yes/no) [default: yes]" "yes"; then
        USE_FAIL2BAN=true
        printf "${GREEN}Fail2ban will be installed and configured.${NC}\n"
    else
        USE_FAIL2BAN=false
        printf "${YELLOW}Fail2ban will be skipped.${NC}\n"
    fi
}

prompt_auto_updates() {
    printf "\n${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    AUTOMATIC UPDATES${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"

    printf "Automatic updates keep your system secure by installing\n"
    printf "the latest packages on a regular schedule. The box only\n"
    printf "reboots when packages actually changed.\n\n"

    if prompt_yes_no "Enable automatic updates? (yes/no) [default: yes]" "yes"; then
        ENABLE_AUTO_UPDATES=true

        printf "\nWhen should updates run? (24H format, HH:MM)\n"
        _time_valid=false
        while [ "$_time_valid" = false ]; do
            printf "Enter update time [default: %s:%s]: " "$UPDATE_HOUR" "$UPDATE_MINUTE"
            read -r _time_input </dev/tty
            _time_input=${_time_input:-${UPDATE_HOUR}:${UPDATE_MINUTE}}

            _hour="${_time_input%%:*}"
            _min="${_time_input##*:}"
            case "$_hour" in 0[0-9]|1[0-9]|2[0-3]|[0-9]) ;; *) printf "${RED}Invalid hour (00-23)${NC}\n"; continue ;; esac
            case "$_min" in [0-5][0-9]) ;; *) printf "${RED}Invalid minute (00-59)${NC}\n"; continue ;; esac

            _hour=$(printf "%02d" "$((10#$_hour))")
            _min=$(printf "%02d" "$((10#$_min))")
            UPDATE_HOUR="$_hour"
            UPDATE_MINUTE="$_min"
            _time_valid=true
        done
        printf "${GREEN}Updates will run daily at %s:%s${NC}\n" "$UPDATE_HOUR" "$UPDATE_MINUTE"
    else
        ENABLE_AUTO_UPDATES=false
        printf "${YELLOW}Automatic updates will be skipped.${NC}\n"
    fi
}

prompt_confirmation() {
    printf "\n${YELLOW}==========================================${NC}\n"
    printf "${YELLOW}    CONFIGURATION SUMMARY${NC}\n"
    printf "${YELLOW}==========================================${NC}\n\n"
    printf "  Packages:     %s\n" "${ADDITIONAL_PACKAGES:-none}"
    printf "  SSH Server:   %s\n" "$(if [ "$INSTALL_SSHD" = true ]; then echo "yes (port $SSH_PORT)"; else echo "no"; fi)"
    printf "  Firewall:     %s\n" "$(if [ "$USE_UFW" = true ]; then echo "UFW"; else echo "none"; fi)"
    printf "  Fail2ban:     %s\n" "$(if [ "$USE_FAIL2BAN" = true ]; then echo "yes"; else echo "no"; fi)"
    printf "  Auto Updates: %s\n" "$(if [ "$ENABLE_AUTO_UPDATES" = true ]; then echo "yes (daily at ${UPDATE_HOUR}:${UPDATE_MINUTE})"; else echo "no"; fi)"
    printf "\n"

    if [ "$NON_INTERACTIVE" = true ]; then
        return 0
    fi

    if ! prompt_yes_no "Proceed with these settings? (yes/no)" "yes"; then
        log "User cancelled. Exiting."
        exit 0
    fi
}

# ─── Apply Functions ──────────────────────────────────────────

install_packages() {
    if [ -z "${ADDITIONAL_PACKAGES:-}" ]; then
        log "No additional packages selected"
        return 0
    fi

    log "Installing packages:${ADDITIONAL_PACKAGES}"
    # shellcheck disable=SC2086
    apk add $ADDITIONAL_PACKAGES || {
        log_warn "Some packages may have failed to install"
    }
    log "Package installation complete"
}

setup_sshd() {
    if [ "$INSTALL_SSHD" != true ]; then
        log "Skipping SSH server setup"
        return 0
    fi

    log "Installing OpenSSH server..."
    if ! apk info -e openssh >/dev/null 2>&1; then
        apk add openssh || {
            log_error "Failed to install openssh"
            exit 1
        }
    else
        log_info "openssh already installed"
    fi

    # Determine the target user for the SSH key.
    # NEVER root: this script writes 'PermitRootLogin no' + disables
    # password auth — a key in /root with no other keyed account is a
    # guaranteed lockout (console-only recovery).
    if [ -n "${SUDO_USER:-}" ]; then
        _ssh_user="$SUDO_USER"
    elif [ -n "${DOAS_USER:-}" ]; then
        _ssh_user="$DOAS_USER"
    else
        _ssh_user="root"
    fi

    if [ "$_ssh_user" = "root" ]; then
        log_error "REFUSING to install an SSH key for root."
        log_error "This script sets 'PermitRootLogin no' AND 'PasswordAuthentication no'."
        log_error "A key in /root with no other keyed account = permanent SSH lockout."
        echo ""
        log "Pick ONE of these, then re-run:"
        log "  1. Run via ${ESCALATE:-doas/sudo} from your regular admin user."
        log "  2. Create a non-root user first, e.g.:"
        echo "       adduser -D <username> && adduser <username> wheel"
        echo "       (then add your key to /home/<username>/.ssh/authorized_keys)"
        echo ""
        exit 1
    fi

    # Resolve the home directory from /etc/passwd (POSIX, no getent needed)
    _user_home=$(awk -F: -v u="$_ssh_user" '$1 == u {print $6; exit}' /etc/passwd)
    if [ -z "$_user_home" ] || [ ! -d "$_user_home" ]; then
        log_error "Cannot resolve a home directory for '$_ssh_user' — refusing to continue."
        exit 1
    fi

    # Setup authorized_keys
    _ssh_dir="$_user_home/.ssh"
    _auth_keys="$_ssh_dir/authorized_keys"

    log "Setting up authorized_keys for user: $_ssh_user"
    log "Home directory: $_user_home"
    mkdir -p "$_ssh_dir"
    chmod 700 "$_ssh_dir"

    if [ -f "$_auth_keys" ] && grep -qF "$USER_PUBLIC_KEY" "$_auth_keys" 2>/dev/null; then
        log "Public key already present — skipping"
    else
        echo "$USER_PUBLIC_KEY" >> "$_auth_keys"
        log "Public key appended to authorized_keys"
    fi

    chmod 600 "$_auth_keys"
    chown -R "$_ssh_user:$_ssh_user" "$_ssh_dir" 2>/dev/null || true

    # Verify the key landed BEFORE any auth restriction is applied
    if ! grep -qF "$USER_PUBLIC_KEY" "$_auth_keys"; then
        log_error "Key verification failed — aborting before disabling root/password login."
        exit 1
    fi

    # Backup existing sshd_config
    mkdir -p "$BACKUP_DIR"
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup"
    fi

    # Write hardened sshd_config.
    # NOTE: no ChallengeResponseAuthentication (deprecated alias) —
    # keyboard-interactive is PAM-managed on modern OpenSSH.
    cat > /etc/ssh/sshd_config << EOF
# SSH Hardened Configuration - Generated by Crusty System (Alpine)
Port $SSH_PORT

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
UsePAM yes

# Key algorithms
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Forwarding
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no

# Misc
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/ssh/sftp-server

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

    # Generate host keys if missing
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N '' >/dev/null 2>&1
    fi
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N '' >/dev/null 2>&1
    fi

    # Pre-flight the new config before touching the running sshd
    if ! sshd -t -f /etc/ssh/sshd_config >/dev/null 2>&1; then
        log_error "New sshd_config FAILED 'sshd -t' pre-flight — restoring backup."
        if [ -f "$BACKUP_DIR/sshd_config.backup" ]; then
            cp "$BACKUP_DIR/sshd_config.backup" /etc/ssh/sshd_config
        fi
        exit 1
    fi

    # Enable and start SSH service (OpenRC) — with rollback on failure
    rc-update add sshd default 2>/dev/null || rc-update add sshd
    rc-service sshd restart || {
        log_error "Failed to restart SSH!"
        if [ -f "$BACKUP_DIR/sshd_config.backup" ]; then
            cp "$BACKUP_DIR/sshd_config.backup" /etc/ssh/sshd_config
            rc-service sshd restart
        fi
        exit 1
    }

    log "SSH server configured on port $SSH_PORT for user $_ssh_user"
}

setup_ufw() {
    if [ "$USE_UFW" != true ]; then
        log "Skipping UFW firewall setup"
        return 0
    fi

    log "Installing UFW firewall..."
    if ! apk info -e ufw >/dev/null 2>&1; then
        apk add ip6tables ufw || {
            log_error "Failed to install ufw"
            log_error "Make sure the community repository is enabled in /etc/apk/repositories"
            exit 1
        }
    else
        log_info "ufw already installed"
    fi

    # Backup existing iptables rules
    if [ -d /etc/ufw ]; then
        cp -r /etc/ufw "$BACKUP_DIR/ufw" 2>/dev/null || true
    fi

    log "Configuring UFW..."

    # Reset to defaults
    ufw --force reset 2>/dev/null || true

    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH port
    ufw allow "$SSH_PORT"/tcp comment 'SSH'

    ufw logging on
    ufw --force enable

    # Enable UFW at boot (OpenRC)
    rc-update add ufw default 2>/dev/null || rc-update add ufw

    log "UFW configured — SSH allowed on port $SSH_PORT"
}

setup_fail2ban() {
    if [ "$USE_FAIL2BAN" != true ]; then
        log "Skipping fail2ban setup"
        return 0
    fi

    log "Installing fail2ban..."
    if ! apk info -e fail2ban >/dev/null 2>&1; then
        apk add fail2ban fail2ban-openrc || {
            log_error "Failed to install fail2ban"
            exit 1
        }
    else
        log_info "fail2ban already installed"
    fi

    # Detect auth log location (Alpine uses /var/log/messages by default,
    # but /var/log/auth.log if rsyslog is installed)
    _auth_log="/var/log/messages"
    if [ -f /var/log/auth.log ]; then
        _auth_log="/var/log/auth.log"
    fi

    # Write fail2ban config
    mkdir -p /etc/fail2ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Escalating bans: 10 min initial, doubles on repeat, max 7 days
bantime = 600
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 604800

findtime = 600
maxretry = 3
backend = auto

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = $_auth_log
maxretry = 3
bantime = 3600
findtime = 600
EOF

    # Enable and start
    rc-update add fail2ban default 2>/dev/null || rc-update add fail2ban
    rc-service fail2ban restart || rc-service fail2ban start

    log "Fail2ban configured (monitoring $_auth_log)"
}

setup_auto_updates() {
    if [ "$ENABLE_AUTO_UPDATES" != true ]; then
        log "Skipping automatic updates"
        return 0
    fi

    log "Configuring automatic updates..."

    # Ensure crond is installed and running
    if ! apk info -e cronie >/dev/null 2>&1 && ! apk info -e dcron >/dev/null 2>&1; then
        apk add cronie >/dev/null 2>&1 || apk add dcron >/dev/null 2>&1 || true
    else
        log_info "cron daemon already installed"
    fi

    # Install the LOCAL maintenance script the cron will run.
    # The cron NEVER downloads anything; the box only reboots when
    # packages actually changed (apk-changes marker).
    log "Installing local maintenance script: $MAINTENANCE_SCRIPT"
    cat > "$MAINTENANCE_SCRIPT" << 'MAINT_EOF'
#!/bin/sh
#
# Crusty System — Alpine daily local maintenance.
# NEVER downloads anything. Runs apk update/upgrade and reboots
# ONLY when the package set actually changed.
# Log: /var/log/crusty-maintenance.log
#

LOG_FILE="/var/log/crusty-maintenance.log"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Serialize — never run two maintenance jobs at once
if command -v flock >/dev/null 2>&1; then
    exec 9>/var/run/crusty-maintenance.lock
    if ! flock -n 9; then
        log "another maintenance instance is running — exiting"
        exit 0
    fi
fi

log "=== crusty daily maintenance start ==="

# Marker: package state before the upgrade
_pre=$(apk info -v 2>/dev/null | sort)

if apk update -q >/dev/null 2>&1; then
    log "OK: apk update"
else
    log "FAILED: apk update"
fi
if apk upgrade --available -q >/dev/null 2>&1; then
    log "OK: apk upgrade"
else
    log "FAILED: apk upgrade"
fi

# Reboot ONLY if the package set changed (apk-changes marker)
_post=$(apk info -v 2>/dev/null | sort)
if [ "$_pre" != "$_post" ]; then
    log "packages changed — rebooting"
    log "=== crusty daily maintenance end (rebooting) ==="
    /sbin/reboot
else
    log "no package changes — skipping reboot"
fi

log "=== crusty daily maintenance end ==="
MAINT_EOF
    chmod 755 "$MAINTENANCE_SCRIPT"

    # Cron entry: runs ONLY the local maintenance script (no downloads,
    # no unconditional reboot)
    _cron_entry="${UPDATE_MINUTE} ${UPDATE_HOUR} * * * ${MAINTENANCE_SCRIPT}"

    # Alpine's default cron daemon reads /etc/crontabs/root
    mkdir -p /etc/crontabs

    if [ -f /etc/crontabs/root ]; then
        # Remove any existing crusty auto-update lines (legacy versions)
        sed -i '/crusty/d' /etc/crontabs/root 2>/dev/null || true
    fi

    echo "# Crusty System — daily LOCAL maintenance at ${UPDATE_HOUR}:${UPDATE_MINUTE} (no downloads; reboots only when packages changed)" >> /etc/crontabs/root
    echo "$_cron_entry" >> /etc/crontabs/root

    # Signal crond to reload (via cron.update file)
    touch /etc/crontabs/cron.update 2>/dev/null || true

    # Start and enable crond
    rc-service crond start 2>/dev/null || true
    rc-update add crond default 2>/dev/null || true

    log "Automatic updates configured (daily at ${UPDATE_HOUR}:${UPDATE_MINUTE} — local maintenance only)"
}

# ─── Summary ──────────────────────────────────────────────────

print_summary() {
    _ip=$(get_primary_ip)

    printf "\n==========================================\n"
    log "Alpine setup complete!"
    printf "==========================================\n\n"

    printf "${GREEN}Configuration Summary:${NC}\n"
    printf "  Packages installed: %s\n" "${ADDITIONAL_PACKAGES:-none}"
    if [ "$INSTALL_SSHD" = true ]; then
        printf "  SSH Port:           %s\n" "$SSH_PORT"
        printf "  Key installed for:  %s\n" "${_ssh_user:-<user>}"
        printf "  Root Login:         Disabled\n"
        printf "  Password Auth:      Disabled (key-only)\n"
    fi
    printf "  Firewall:           %s\n" "$(if [ "$USE_UFW" = true ]; then echo "UFW enabled"; else echo "none"; fi)"
    printf "  Fail2ban:            %s\n" "$(if [ "$USE_FAIL2BAN" = true ]; then echo "configured + running"; else echo "skipped"; fi)"
    printf "  Auto Updates:       %s\n" "$(if [ "$ENABLE_AUTO_UPDATES" = true ]; then echo "daily at ${UPDATE_HOUR}:${UPDATE_MINUTE} (reboots only when changed)"; else echo "none"; fi)"

    if [ "$INSTALL_SSHD" = true ]; then
        printf "\n${YELLOW}SSH Connection:${NC}\n"
        printf "  ssh -p %s %s@%s\n" "$SSH_PORT" "${_ssh_user:-<user>}" "$_ip"
    fi

    printf "\n${YELLOW}Backup Location:${NC}\n"
    printf "  %s\n" "$BACKUP_DIR"
    printf "\n${YELLOW}Log File:${NC}\n"
    printf "  %s\n" "$LOG_FILE"

    if [ "$INSTALL_SSHD" = true ]; then
        printf "\n${RED}==========================================${NC}\n"
        printf "${RED}              IMPORTANT!${NC}\n"
        printf "${RED}==========================================${NC}\n\n"
        printf "${YELLOW}1. DO NOT close this session until you test the new SSH connection!${NC}\n"
        printf "   ${GREEN}ssh -p %s %s@%s${NC}\n\n" "$SSH_PORT" "${_ssh_user:-<user>}" "$_ip"
        printf "${YELLOW}2. Password authentication is DISABLED — use your SSH key${NC}\n\n"
        printf "${YELLOW}3. Keep your private key safe — there is no password fallback!${NC}\n\n"
    fi
    printf "\n"
}

# ─── Main ─────────────────────────────────────────────────────

# Show help without root check
for _arg in "$@"; do
    case "$_arg" in
        --help|-h)
            echo "Usage: sh setup.sh"
            echo ""
            echo "Alpine Linux Setup Script — installs packages, configures SSH,"
            echo "UFW firewall, fail2ban, and automatic updates."
            echo ""
            echo "NOTE: refuses to install the SSH key for root (it sets"
            echo "PermitRootLogin no). Run via doas/sudo from your admin user."
            echo ""
            echo "One-liner:"
            echo "  curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/alpine/setup.sh | sh"
            echo ""
            echo "Or download first:"
            echo "  wget https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/alpine/setup.sh"
            echo "  sh setup.sh"
            exit 0
            ;;
    esac
done

check_root

printf "\n${GREEN}==========================================${NC}\n"
printf "${GREEN}    Alpine Linux Setup${NC}\n"
printf "${GREEN}    Crusty System${NC}\n"
printf "${GREEN}==========================================${NC}\n"

log "Starting Alpine setup..."

# Update package index first
log "Updating package index..."
apk update || {
    log_error "apk update failed — check network connection"
    exit 1
}

enable_community_repo

# Interactive prompts
prompt_additional_packages
prompt_sshd_setup
prompt_ufw_setup
prompt_fail2ban_setup
prompt_auto_updates
prompt_confirmation

# Apply
printf "\n${GREEN}Applying configuration...${NC}\n\n"

mkdir -p "$BACKUP_DIR"
install_packages
setup_sshd
setup_ufw
setup_fail2ban
setup_auto_updates

print_summary
