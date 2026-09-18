#!/bin/bash
#
# Crusty System — Master Setup Script for Debian/Ubuntu
#
# One-liner deploy:
#   curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- --ssh-key "ssh-ed25519 AAAAC3Nza..." --ssh-user "$USER"
#
# Delegates to:
#   scripts/ubuntu/ssh-hardener.sh  — SSH hardening + UFW + fail2ban
#   scripts/ubuntu/docker-setup.sh  — Docker Engine + Compose + security
#   scripts/ubuntu/auto-update.sh   — Weekly LOCAL maintenance cron
#
# UPDATE MODEL (operator requirement):
#   - The weekly cron NEVER downloads anything. Cron runs local maintenance
#     only (see scripts/ubuntu/maintenance.sh).
#   - THIS script is the update mechanism: every sub-script it downloads is
#     verified against the SHA-256 pins below BEFORE it is used. Cached
#     copies in /opt/crusty-system that no longer match their pin are
#     re-downloaded and re-verified automatically — re-running the one-liner
#     on an already-configured box heals it to the current repo state.
#
# If you edit any sub-script, regenerate the pins and paste them below
# BEFORE committing, or the one-liner will (correctly) refuse to use it:
#   sha256sum scripts/ubuntu/ssh-hardener.sh scripts/ubuntu/docker-setup.sh scripts/ubuntu/auto-update.sh
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# SHA-256 PIN TABLE — sub-script integrity verification
# ─────────────────────────────────────────────────────────────
declare -A SCRIPT_PINS=(
    ["scripts/ubuntu/ssh-hardener.sh"]="4df828404a2bf49abea485ada4612c4121e2087b5f36387f78f2405dff259344"
    ["scripts/ubuntu/docker-setup.sh"]="1037a062f78f5361395ff53afa433964b030fcc5694165deeac76badaf9730cb"
    ["scripts/ubuntu/auto-update.sh"]="52e2dd5e0fd63c8a95f875e82af29586709a79bdfb5c1dd1f5ef501c019eebdc"
)

REPO_BASE="https://raw.githubusercontent.com/joshuaromkes/crusty-system/main"
SELF_UPDATE_CRON="/etc/cron.d/crusty-self-update"
LEGACY_UPDATE_CRON="/etc/cron.d/crusty-auto-update"
LOCAL_DIR="/opt/crusty-system"

SSH_KEY=""
SSH_USER=""
SSH_PORT=58432
WITH_DOCKER=false
DOCKER_USER=""
NO_FAIL2BAN=false
NO_AUTO_UPDATES=false
UPDATE_TIME="02:00"
ALLOW_TCP_FORWARDING="no"
NON_INTERACTIVE=false
DRY_RUN=false

usage() {
    cat << 'EOF'
Crusty System — Debian/Ubuntu Master Setup

Usage: sudo bash setup.sh [OPTIONS]

One-liner:
  curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- \
    --ssh-key "ssh-ed25519 AAA..." --ssh-user "$USER"

REQUIRED (when not running interactively):
  --ssh-key "KEY"       SSH public key for authorized_keys

TARGET USER:
  --ssh-user USER       Non-root user the key is installed for (default:
                        SUDO_USER when run via sudo). The key is NEVER
                        installed for root — the hardener sets
                        PermitRootLogin no and refuses root targets.

OPTIONAL:
  --ssh-port PORT        SSH port (1-65535, default: 58432; 22 is supported
                         for NAT'd/LXC-style hosts behind a parent firewall)
  --allow-tcp-forwarding MODE   "no" (default), "local", or "yes"
  --docker               Install Docker Engine + Compose
  --docker-user USER     Add USER to docker group (implies --docker)
  --no-fail2ban          Skip fail2ban intrusion prevention
  --no-auto-updates      Skip automatic weekly maintenance
  --update-time HH:MM    Maintenance time in 24H format (default: 02:00)
  --non-interactive      Skip all prompts
  --dry-run              Show what would be done without applying
  --help, -h             Show this help

WHAT THIS DOES:
  1. SSH Hardening   — Custom port, passwords off, root login off, your key
                       for a non-root user, UFW (existing rules preserved),
                       fail2ban (reloaded, never restarted)
  2. Docker          — Engine from official repo, Compose plugin, hardened
                       daemon (if --docker)
  3. Auto Updates    — Weekly LOCAL maintenance (apt upgrade + cleanup +
                       conditional reboot). The cron never downloads
                       anything; scripts update by re-running this one-liner.

SUPPLY CHAIN: downloaded sub-scripts are verified against SHA-256 pins
embedded in this file. A mismatch is a hard error (fail closed).

EXAMPLES:
  # Full setup with Docker, run from your admin user via sudo
  sudo bash setup.sh --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" --docker --docker-user $USER

  # Explicit target user (when SUDO_USER can't be detected)
  sudo bash setup.sh --ssh-key "$(cat key.pub)" --ssh-user josh

  # LXC-style host that keeps port 22
  sudo bash setup.sh --ssh-key "$(cat key.pub)" --ssh-user josh --ssh-port 22

  # Minimal: SSH hardening only, no fail2ban, no maintenance
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

# H10: same validation rules as ssh-hardener.sh. Real key types only
# (ssh-dss not "ssh-dsa", ecdsa-sha2-nistp256|384|521, both sk- FIDO
# variants), minimum blob length, plus ssh-keygen as the authoritative
# check when available.
validate_public_key() {
    local key="$1"

    if [[ "$key" =~ ^ssh-(ed25519|rsa|dss)[[:space:]]+[A-Za-z0-9+/]{40,}[=]{0,3} ]] || \
       [[ "$key" =~ ^ecdsa-sha2-nistp(256|384|521)[[:space:]]+[A-Za-z0-9+/]{40,}[=]{0,3} ]] || \
       [[ "$key" =~ ^(sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]{40,}[=]{0,3} ]]; then
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh-key)
                SSH_KEY="$2"; shift 2 ;;
            --ssh-user)
                SSH_USER="$2"; shift 2 ;;
            --ssh-port)
                SSH_PORT="$2"; shift 2 ;;
            --allow-tcp-forwarding)
                ALLOW_TCP_FORWARDING="$2"; shift 2 ;;
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

    # Validate provided key up front (H10) — fail fast, not after downloads
    if [[ -n "$SSH_KEY" ]] && ! validate_public_key "$SSH_KEY"; then
        log_error "The provided --ssh-key failed validation"
        log_error "Expected: ssh-ed25519 AAAA..., ssh-rsa AAAA..., ecdsa-sha2-nistp256|384|521 AAAA...,"
        log_error "         sk-ssh-ed25519@openssh.com AAAA..., or sk-ecdsa-sha2-nistp256@openssh.com AAAA..."
        exit 1
    fi

    # Validate allow-tcp-forwarding mode
    case "$ALLOW_TCP_FORWARDING" in
        no|local|yes) ;;
        *) log_error "Invalid --allow-tcp-forwarding: $ALLOW_TCP_FORWARDING (use: no, local, yes)"; exit 1 ;;
    esac
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

    local key_valid=false
    while [[ "$key_valid" == false ]]; do
        printf "${BLUE}Paste your public key (then press Enter):${NC}\n"
        read -r SSH_KEY

        SSH_KEY=$(echo "$SSH_KEY" | xargs)

        if [[ -z "$SSH_KEY" ]]; then
            printf "${RED}ERROR: Key cannot be empty.${NC}\n"
            continue
        fi

        if validate_public_key "$SSH_KEY"; then
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

file_sha256() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# C4: pinned download. The live config is never fed an unverified script:
#   - cached + pin-valid   → reuse
#   - cached + pin-MISMATCH→ re-download, re-verify, replace (auto-heal)
#   - fresh download      → verify against pin, atomic rename into place
#   - any failure         → hard exit (fail closed)
download_script() {
    local script_path="$1"
    local expected="${SCRIPT_PINS[$script_path]:-}"

    if [[ -z "$expected" ]]; then
        log_error "No SHA-256 pin for '$script_path' — refusing to download (update the pin table)"
        exit 1
    fi

    local url="$REPO_BASE/$script_path"
    local dest="$LOCAL_DIR/$script_path"

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        if [[ "$(file_sha256 "$dest")" == "$expected" ]]; then
            log_info "Cached script verified (sha256 OK): $dest"
            return 0
        fi
        log_warn "Cached '$script_path' does NOT match its pin — re-downloading and re-verifying"
    fi

    log "Downloading: $url"
    local tmp="$dest.new"
    if ! curl -fsSL "$url" -o "$tmp"; then
        log_error "Failed to download: $url"
        rm -f "$tmp"
        exit 1
    fi

    local actual
    actual=$(file_sha256 "$tmp")
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA-256 MISMATCH for '$script_path' — refusing to use it"
        log_error "  expected: $expected"
        log_error "  actual:   $actual"
        log_error "If you just edited the sub-scripts, regenerate the pin table in setup.sh."
        rm -f "$tmp"
        exit 1
    fi

    mv -f "$tmp" "$dest"
    chmod 755 "$dest"
    log "Downloaded + verified (sha256 OK): $script_path"
}

# C4 cleanup: remove any cron job that downloads scripts from the network.
configure_self_update() {
    if [[ -f "$SELF_UPDATE_CRON" ]]; then
        log_info "Removing legacy self-update cron (network downloads are no longer allowed in cron)..."
        rm -f "$SELF_UPDATE_CRON"
    fi
    # A legacy crusty-auto-update cron that curls scripts is a remote-code
    # execution vector — remove it. If auto-updates are enabled, step 3
    # below immediately installs the correct local-only cron.
    if [[ -f "$LEGACY_UPDATE_CRON" ]] && grep -q "curl" "$LEGACY_UPDATE_CRON" 2>/dev/null; then
        log_warn "Removing legacy network-fetching auto-update cron (scripts now update via the one-liner)..."
        rm -f "$LEGACY_UPDATE_CRON"
    fi
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
    # H3: print the REAL target user, never whoami/root — after hardening,
    # root login is forbidden and whoami is usually root under sudo.
    local ssh_user="${SSH_USER:-${SUDO_USER:-}}"
    if [[ -z "$ssh_user" ]]; then
        ssh_user="<admin-user>"
    fi

    echo ""
    echo "=========================================="
    log "Setup Complete!"
    echo "=========================================="
    echo ""
    printf "${GREEN}Configuration Summary:${NC}\n"
    echo "  - SSH Port:            $SSH_PORT"
    echo "  - SSH User:            $ssh_user (root login disabled — key-only)"
    echo "  - Password Auth:       Disabled (key-only)"
    echo "  - Firewall:            UFW enabled (existing rules preserved)"
    echo "  - Fail2ban:            $([[ "$NO_FAIL2BAN" == false ]] && echo 'Enabled + reloaded (sshd jail verified)' || echo 'Skipped')"
    echo "  - Auto Updates:        $([[ "$NO_AUTO_UPDATES" == false ]] && echo "Weekly LOCAL maintenance at $UPDATE_TIME (no downloads)" || echo 'Skipped')"
    echo "  - Docker:              $([[ "$WITH_DOCKER" == true ]] && echo 'Installed' || echo 'Skipped')"
    if [[ -n "$DOCKER_USER" ]]; then
        echo "  - Docker User:         $DOCKER_USER (re-login required for group membership)"
    fi
    echo ""
    printf "${YELLOW}SSH Connection:${NC}\n"
    echo "  ssh -p $SSH_PORT $ssh_user@<server-ip>"
    echo ""
    if [[ "$WITH_DOCKER" == true ]]; then
        printf "${RED}NOTE: Docker-published ports (-p) BYPASS UFW — see the security${NC}\n"
        printf "${RED}note in the Docker output above. UFW does not close them.${NC}\n"
        echo ""
    fi
    printf "${YELLOW}Maintenance:${NC}\n"
    echo "  The weekly cron runs LOCAL maintenance only (log: /var/log/crusty-maintenance.log)."
    echo "  To update crusty scripts, re-run this one-liner — never via cron."
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
        log_info "  SSH user: ${SSH_USER:-${SUDO_USER:-auto-detected (never root)}}"
        log_info "  TCP forwarding: $ALLOW_TCP_FORWARDING"
        log_info "  Docker: $WITH_DOCKER"
        log_info "  Docker user: ${DOCKER_USER:-none}"
        log_info "  Fail2ban: $([[ "$NO_FAIL2BAN" == false ]] && echo 'yes' || echo 'no')"
        log_info "  Auto updates: $([[ "$NO_AUTO_UPDATES" == false ]] && echo "yes, LOCAL maintenance at $UPDATE_TIME" || echo 'no')"
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
    ssh_args+=(--allow-tcp-forwarding "$ALLOW_TCP_FORWARDING")
    ssh_args+=(--update-time "$UPDATE_TIME")

    # H3/C1: explicit target user. Empty → ssh-hardener resolves SUDO_USER
    # and refuses (with guidance) rather than installing the key for root.
    if [[ -n "$SSH_USER" ]]; then
        ssh_args+=(--user "$SSH_USER")
    fi

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
        log_info "--- Step 3: Auto Updates (local maintenance only) ---"
        download_script "scripts/ubuntu/auto-update.sh"

        log "Running auto-update.sh..."
        bash "$LOCAL_DIR/scripts/ubuntu/auto-update.sh" install --non-interactive --time "$UPDATE_TIME"
    else
        log_info "--- Step 3: Auto Updates — skipped ---"
    fi

    # ── Step 4: Legacy cron cleanup ────────────────────────────
    log_info "--- Step 4: Legacy cron cleanup ---"
    configure_self_update

    print_summary
}

main "$@"
