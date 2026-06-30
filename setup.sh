#!/bin/bash
#
# Crusty System — Master Setup Script for Debian/Ubuntu
#
# One-liner deploy:
#   curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- --ssh-key "ssh-ed25519 AAAAC3Nza..."
#
# Delegates to:
#   scripts/ubuntu/ssh-hardener.sh  — SSH hardening + UFW + fail2ban
#   scripts/ubuntu/docker-setup.sh  — Docker Engine + Compose + security
#   scripts/ubuntu/auto-update.sh   — Unattended weekly upgrades
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_BASE="https://raw.githubusercontent.com/joshuaromkes/crusty-system/main"
SELF_UPDATE_CRON="/etc/cron.d/crusty-self-update"
LOCAL_DIR="/opt/crusty-system"

SSH_KEY=""
SSH_PORT=58432
WITH_DOCKER=false
DOCKER_USER=""
NO_FAIL2BAN=false
NO_AUTO_UPDATES=false
UPDATE_TIME="02:00"
NON_INTERACTIVE=false
DRY_RUN=false

usage() {
    cat << 'EOF'
Crusty System — Debian/Ubuntu Master Setup

Usage: sudo bash setup.sh [OPTIONS]

One-liner:
  curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- --ssh-key "ssh-ed25519 AAA..."

REQUIRED (when not running interactively):
  --ssh-key "KEY"       SSH public key for authorized_keys

OPTIONAL:
  --ssh-port PORT        SSH port (1-65535, default: 58432)
  --docker               Install Docker Engine + Compose
  --docker-user USER     Add USER to docker group (implies --docker)
  --no-fail2ban          Skip fail2ban intrusion prevention
  --no-auto-updates      Skip automatic weekly updates
  --update-time HH:MM    Update time in 24H format (default: 02:00)
  --non-interactive      Skip all prompts
  --dry-run              Show what would be done without applying
  --help, -h             Show this help

WHAT THIS DOES:
  1. SSH Hardening   — Changes SSH port, disables passwords, adds your key,
                       installs UFW firewall, optional fail2ban
  2. Docker          — Installs Docker Engine from official repo, Compose plugin,
                       hardened daemon config (if --docker)
  3. Auto Updates    — Unattended weekly upgrades with conditional reboot
  4. Self-Update     — Weekly cron to auto-update crusty-system scripts

EXAMPLES:
  # Full setup with Docker
  sudo bash setup.sh --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" --docker --docker-user $USER

  # Minimal: SSH hardening only, no fail2ban, no updates
  sudo bash setup.sh --ssh-key "$(cat key.pub)" --no-fail2ban --no-auto-updates

  # Preview
  sudo bash setup.sh --ssh-key "$(cat key.pub)" --docker --dry-run
EOF
    exit 0
}

log()    { printf "${GREEN}[%s]${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_warn() { printf "${YELLOW}[%s] WARNING:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_error() { printf "${RED}[%s] ERROR:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_info() { printf "${BLUE}[%s] INFO:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS"
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_error "This script only supports Debian/Ubuntu. Detected: $ID"
        log_error "For Alpine Linux, use: $REPO_BASE/scripts/alpine/setup.sh"
        exit 1
    fi
    log_info "Detected: $PRETTY_NAME ($VERSION_CODENAME)"
}

validate_time() {
    local time_str="$1"
    if [[ ! "$time_str" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        log_error "Invalid time format: $time_str (use HH:MM)"
        exit 1
    fi
    local hour=$((10#${BASH_REMATCH[1]}))
    local minute=$((10#${BASH_REMATCH[2]}))
    if [[ "$hour" -lt 0 || "$hour" -gt 23 ]]; then
        log_error "Invalid hour in time: $time_str"
        exit 1
    fi
    if [[ "$minute" -lt 0 || "$minute" -gt 59 ]]; then
        log_error "Invalid minute in time: $time_str"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh-key)
                SSH_KEY="$2"; shift 2 ;;
            --ssh-port)
                SSH_PORT="$2"; shift 2 ;;
            --docker)
                WITH_DOCKER=true; shift ;;
            --docker-user)
                DOCKER_USER="$2"; WITH_DOCKER=true; shift 2 ;;
            --no-fail2ban)
                NO_FAIL2BAN=true; shift ;;
            --no-auto-updates)
                NO_AUTO_UPDATES=true; shift ;;
            --update-time)
                UPDATE_TIME="$2"; shift 2 ;;
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
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

    # SSH key: from CLI arg, interactive prompt, or fail if non-TTY
    if [[ "$DRY_RUN" == false ]] && [[ -z "$SSH_KEY" ]]; then
        if [[ ! -t 0 ]]; then
            log_error "--ssh-key is required when stdin is not a terminal"
            echo "Usage: $0 --ssh-key \"ssh-ed25519 AAAAC3NzaC...\" [other options]"
            exit 1
        fi
        prompt_ssh_key
    fi

    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
        log_error "Invalid --ssh-port: $SSH_PORT (must be 1-65535)"
        exit 1
    fi

    validate_time "$UPDATE_TIME"
}

prompt_ssh_key() {
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

    local key_valid=false
    while [[ "$key_valid" == false ]]; do
        printf "${BLUE}Paste your public key (then press Enter):${NC}\n"
        read -r SSH_KEY

        SSH_KEY=$(echo "$SSH_KEY" | xargs)

        if [[ -z "$SSH_KEY" ]]; then
            printf "${RED}ERROR: Key cannot be empty.${NC}\n"
            continue
        fi

        if [[ "$SSH_KEY" =~ ^ssh-(ed25519|rsa|ecdsa|dsa)[[:space:]]+[A-Za-z0-9+/]+[=]{0,2} ]] || \
           [[ "$SSH_KEY" =~ ^sk-ssh-(ed25519|ecdsa)@openssh\.com[[:space:]]+ ]]; then
            key_valid=true
            log "Valid SSH public key provided"
            printf "${GREEN}Public key accepted.${NC}\n"
        elif [[ "$SSH_KEY" =~ ^ecdsa-sha2-nistp[[:space:]]+[A-Za-z0-9+/]+[=]{0,2} ]]; then
            key_valid=true
            log "Valid SSH public key provided (ECDSA)"
            printf "${GREEN}Public key accepted.${NC}\n"
        else
            printf "${RED}ERROR: This doesn't look like a valid SSH public key.${NC}\n"
            echo "A valid key starts with 'ssh-ed25519', 'ssh-rsa', 'ssh-ecdsa', 'ssh-dsa',"
            echo "'sk-ssh-ed25519@openssh.com', 'sk-ecdsa...p256@openssh.com', or 'ecdsa-sha2-nistp...'"
            echo ""
            local retry
            read -rp "Try again? (yes/no): " retry
            case "$retry" in
                [Nn][Oo])
                    log_error "User declined to provide valid SSH key"
                    exit 1
                    ;;
            esac
        fi
    done
}

download_script() {
    local script_path="$1"
    local url="$REPO_BASE/$script_path"
    local dest="$LOCAL_DIR/$script_path"

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        log_info "Script already cached: $dest"
        return 0
    fi

    log "Downloading: $url"
    if ! curl -fsSL "$url" -o "$dest"; then
        log_error "Failed to download: $url"
        exit 1
    fi
    chmod +x "$dest"
    log "Downloaded: $script_path"
}

configure_self_update() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would install self-update cron at $SELF_UPDATE_CRON"
        return 0
    fi

    if [[ -f "$SELF_UPDATE_CRON" ]]; then
        log_info "Self-update cron already configured"
        return 0
    fi

    # Ensure cron is installed
    if ! command -v crontab &>/dev/null; then
        log "Installing cron..."
        apt-get install -y -qq cron
        systemctl enable --now cron
    fi

    log "Installing self-update cron job..."
    cat > "$SELF_UPDATE_CRON" << 'EOF'
# Crusty System — Self-update (weekly Sunday 01:00)
SHELL=/bin/bash
0 1 * * 0 root mkdir -p /opt/crusty-system && cd /opt/crusty-system && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh" -o /opt/crusty-system/setup.sh && chmod +x /opt/crusty-system/setup.sh && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh" -o /opt/crusty-system/scripts/ubuntu/ssh-hardener.sh && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/docker-setup.sh" -o /opt/crusty-system/scripts/ubuntu/docker-setup.sh && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh" -o /opt/crusty-system/scripts/ubuntu/auto-update.sh 2>&1 | logger -t crusty-self-update
EOF
    chmod 644 "$SELF_UPDATE_CRON"
    log "Self-update cron installed (weekly Sunday 01:00)"
}

print_banner() {
    echo ""
    printf "${BLUE}==========================================\n"
    printf "    Crusty System${NC}\n"
    printf "${BLUE}    Debian/Ubuntu Master Setup${NC}\n"
    printf "${BLUE}==========================================${NC}\n"
    echo ""
}

print_summary() {
    echo ""
    echo "=========================================="
    log "Setup Complete!"
    echo "=========================================="
    echo ""
    printf "${GREEN}Configuration Summary:${NC}\n"
    echo "  - SSH Port:            $SSH_PORT"
    echo "  - Password Auth:       Disabled (key-only)"
    echo "  - Firewall:            UFW enabled"
    echo "  - Fail2ban:            $([[ "$NO_FAIL2BAN" == false ]] && echo 'Active' || echo 'Skipped')"
    echo "  - Auto Updates:        $([[ "$NO_AUTO_UPDATES" == false ]] && echo "Weekly at $UPDATE_TIME" || echo 'Skipped')"
    echo "  - Docker:              $([[ "$WITH_DOCKER" == true ]] && echo 'Installed' || echo 'Skipped')"
    if [[ -n "$DOCKER_USER" ]]; then
        echo "  - Docker User:         $DOCKER_USER"
    fi
    echo "  - Self-Update Cron:    Installed (weekly Sunday 01:00)"
    echo ""
    printf "${YELLOW}SSH Connection:${NC}\n"
    echo "  ssh -p $SSH_PORT $(whoami)@<server-ip>"
    echo ""
    printf "${RED}IMPORTANT: Test the new SSH connection before closing this session!${NC}\n"
    echo ""
}

main() {
    parse_args "$@"

    print_banner

    if [[ "$DRY_RUN" == true ]]; then
        printf "${BLUE}   DRY RUN — no changes will be made${NC}\n\n"
        log_info "Would configure with:"
        log_info "  SSH key: $(echo "$SSH_KEY" | cut -d' ' -f1-2)..."
        log_info "  SSH port: $SSH_PORT"
        log_info "  Docker: $WITH_DOCKER"
        log_info "  Docker user: ${DOCKER_USER:-none}"
        log_info "  Fail2ban: $([[ "$NO_FAIL2BAN" == false ]] && echo 'yes' || echo 'no')"
        log_info "  Auto updates: $([[ "$NO_AUTO_UPDATES" == false ]] && echo "yes ($UPDATE_TIME)" || echo 'no')"
        log_info "  Self-update: yes"
        log_info "Dry run complete."
        exit 0
    fi

    check_root
    detect_os

    # ── Step 1: SSH Hardening ──────────────────────────────────
    log_info "--- Step 1: SSH Hardening ---"
    download_script "scripts/ubuntu/ssh-hardener.sh"

    local ssh_args=()
    ssh_args+=(--port "$SSH_PORT")
    ssh_args+=(--key "$SSH_KEY")
    ssh_args+=(--allow-tcp-forwarding no)
    ssh_args+=(--update-time "$UPDATE_TIME")

    if [[ "$NO_FAIL2BAN" == true ]]; then
        ssh_args+=(--no-fail2ban)
    fi

    if [[ "$NO_AUTO_UPDATES" == true ]]; then
        ssh_args+=(--no-auto-updates)
    fi

    log "Running ssh-hardener.sh..."
    bash "$LOCAL_DIR/scripts/ubuntu/ssh-hardener.sh" "${ssh_args[@]}"

    # ── Step 2: Docker ─────────────────────────────────────────
    if [[ "$WITH_DOCKER" == true ]]; then
        log_info "--- Step 2: Docker ---"
        download_script "scripts/ubuntu/docker-setup.sh"

        local docker_args=(--non-interactive --prune-cron)
        if [[ -n "$DOCKER_USER" ]]; then
            docker_args+=(--user "$DOCKER_USER")
        fi

        log "Running docker-setup.sh..."
        bash "$LOCAL_DIR/scripts/ubuntu/docker-setup.sh" "${docker_args[@]}"
    else
        log_info "--- Step 2: Docker — skipped ---"
    fi

    # ── Step 3: Auto Updates ───────────────────────────────────
    if [[ "$NO_AUTO_UPDATES" == false ]]; then
        log_info "--- Step 3: Auto Updates ---"
        download_script "scripts/ubuntu/auto-update.sh"

        log "Running auto-update.sh..."
        bash "$LOCAL_DIR/scripts/ubuntu/auto-update.sh" install --non-interactive --time "$UPDATE_TIME"
    else
        log_info "--- Step 3: Auto Updates — skipped ---"
    fi

    # ── Step 4: Self-Update Cron ───────────────────────────────
    log_info "--- Step 4: Self-Update Cron ---"
    configure_self_update

    print_summary
}

main "$@"
