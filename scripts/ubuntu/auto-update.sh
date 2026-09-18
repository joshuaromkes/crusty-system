#!/bin/bash
#
# Auto Update Script for Ubuntu Server
# Configures automatic weekly system updates
#
# DESIGN (operator requirement): the weekly cron runs ONLY the local
# maintenance script (/opt/crusty-system/scripts/ubuntu/maintenance.sh).
# It NEVER downloads anything from the network — no curl, no script
# fetches, no one-line megacommand. Crusty scripts are updated by
# re-running the setup one-liner (SHA-256 verified), not by cron.
#
# The maintenance script performs: apt-get update, apt-get upgrade
# (never full-upgrade), autoremove --purge, autoclean, and a reboot
# ONLY if /var/run/reboot-required exists. Every step and its exit
# code is logged to /var/log/crusty-maintenance.log.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { printf "${GREEN}[%s]${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_info() { printf "${BLUE}[%s] INFO:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_warn() { printf "${YELLOW}[%s] WARNING:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_error() { printf "${RED}[%s] ERROR:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }

CRON_FILE="/etc/cron.d/crusty-auto-update"
MAINTENANCE_SCRIPT="/opt/crusty-system/scripts/ubuntu/maintenance.sh"
UPDATE_HOUR="02"
UPDATE_MINUTE="00"
NON_INTERACTIVE=false

usage() {
    cat << EOF
Usage: $0 [OPTION]

Configure automatic weekly system updates for Debian/Ubuntu.

The weekly cron runs ONLY the local maintenance script — it never
downloads anything. Log: /var/log/crusty-maintenance.log

OPTIONS:
  install            Install and configure auto-updates (default)
  uninstall          Remove auto-update configuration and files
  status             Show current auto-update configuration
  run-now            Trigger system updates immediately
  --help, -h         Show this help

NON-INTERACTIVE FLAGS (used with 'install'):
  --non-interactive   Skip all prompts (requires --time)
  --time HH:MM        Update time in 24H format (default: 02:00)

Examples:
  sudo $0 install
  sudo $0 install --non-interactive --time 03:30
  sudo $0 uninstall
  sudo $0 run-now
EOF
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

validate_time() {
    local time_str="$1"
    local hour minute
    if [[ ! "$time_str" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        return 1
    fi
    hour=$((10#${BASH_REMATCH[1]}))
    minute=$((10#${BASH_REMATCH[2]}))
    if [[ "$hour" -lt 0 || "$hour" -gt 23 ]]; then
        return 1
    fi
    if [[ "$minute" -lt 0 || "$minute" -gt 59 ]]; then
        return 1
    fi
    printf -v UPDATE_HOUR "%02d" "$hour"
    printf -v UPDATE_MINUTE "%02d" "$minute"
    return 0
}

prompt_update_time() {
    local hour minute valid=false
    echo ""
    printf "${YELLOW}=== Automatic Update Schedule Configuration ===${NC}\n"
    echo ""
    echo "Please specify when you'd like automatic updates to run."
    echo "Enter time in 24-hour format (HH:MM), e.g., 02:00 for 2:00 AM"
    echo ""

    while [[ "$valid" == false ]]; do
        read -rp "Enter update time (HH:MM) [default: 02:00]: " time_input < /dev/tty
        time_input=${time_input:-02:00}

        if validate_time "$time_input"; then
            valid=true
        else
            printf "${RED}ERROR: Invalid format. Use HH:MM (e.g., 02:00, 14:30)${NC}\n"
        fi
    done

    echo ""
    printf "${GREEN}Update time set to: ${UPDATE_HOUR}:${UPDATE_MINUTE}${NC}\n"
}

# Install the LOCAL maintenance script the cron will run.
# Keep in sync with scripts/ubuntu/maintenance.sh (canonical copy).
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
    log "Local maintenance script installed: $MAINTENANCE_SCRIPT"
}

create_cron_job() {
    log "Creating weekly maintenance cron job for ${UPDATE_HOUR}:${UPDATE_MINUTE}..."

    install_maintenance_script

    # Always (re)written: replaces any legacy network-fetching cron line
    # (curl mega-command) so re-running this script heals deployed boxes.
    cat > "$CRON_FILE" << EOF
# Crusty System - Weekly LOCAL maintenance (runs Sunday at ${UPDATE_HOUR}:${UPDATE_MINUTE})
# Local apt maintenance ONLY — this cron NEVER downloads anything.
# Crusty scripts update by re-running the setup one-liner (SHA-256 verified).
# Log: /var/log/crusty-maintenance.log
SHELL=/bin/bash
${UPDATE_MINUTE} ${UPDATE_HOUR} * * 0 root ${MAINTENANCE_SCRIPT}
EOF
    chmod 644 "$CRON_FILE"
    log "Cron job created at $CRON_FILE (runs ONLY the local maintenance script)"
}

run_updates_now() {
    # Immediate maintenance — same chain as the weekly cron (no downloads)
    echo ""
    log "Starting immediate system update..."
    echo ""

    log "Running: apt-get update"
    if ! apt-get update -qq; then
        log_error "Failed to update package list"
        return 1
    fi
    log "Package list updated successfully"

    echo ""
    log "Running: apt-get upgrade -y"
    if ! apt-get upgrade -y -qq; then
        log_error "Failed to upgrade packages"
        return 1
    fi
    log "System packages upgraded successfully"

    echo ""
    log "Running: apt-get autoremove --purge -y"
    apt-get autoremove --purge -y -qq
    log "Orphaned packages removed"

    echo ""
    log "Running: apt-get autoclean"
    apt-get autoclean
    log "Package cache cleaned"

    echo ""
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "Reboot required after updates"
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log "Non-interactive mode: scheduling reboot in 5 minutes"
            shutdown -r +5 "Crusty System: reboot required after updates"
        else
            local response
            read -rp "Reboot required. Reboot now? [y/N]: " response < /dev/tty
            if [[ "$response" =~ ^[Yy]$ ]]; then
                shutdown -r +1 "Crusty System: reboot required after updates"
                log "Reboot scheduled in 1 minute"
            else
                log "Reboot skipped — please reboot manually when ready"
            fi
        fi
    fi

    echo ""
    log "Update completed"
}

prompt_run_now() {
    echo ""
    printf "${YELLOW}=== Run Updates Now ===${NC}\n"
    echo ""
    read -rp "Would you like to run system updates now? [y/N]: " run_now < /dev/tty

    if [[ "$run_now" =~ ^[Yy]$ ]]; then
        run_updates_now
    else
        printf "${GREEN}Skipping immediate update.${NC}\n"
    fi
}

uninstall_auto_updates() {
    log "Starting uninstallation of auto-update configuration..."

    if [[ -f "$CRON_FILE" ]]; then
        log "Removing cron job: $CRON_FILE"
        rm -f "$CRON_FILE"
    else
        log_warn "Cron job not found at $CRON_FILE"
    fi

    if [[ -f "$MAINTENANCE_SCRIPT" ]]; then
        log "Removing maintenance script: $MAINTENANCE_SCRIPT"
        rm -f "$MAINTENANCE_SCRIPT"
    fi

    echo ""
    echo "=========================================="
    log "Uninstallation Complete!"
    echo "=========================================="
    echo ""
    printf "${GREEN}Removed:${NC}\n"
    echo "  - Cron job: $CRON_FILE"
    echo "  - Maintenance script: $MAINTENANCE_SCRIPT"
    echo ""
}

show_config() {
    echo ""
    echo "=========================================="
    printf "${GREEN}Current Auto-Update Configuration${NC}\n"
    echo "=========================================="
    echo ""

    if [[ -f "$CRON_FILE" ]]; then
        printf "${GREEN}Cron Job:${NC}\n"
        echo "  Schedule: Weekly on Sunday"
        grep -v "^#" "$CRON_FILE" | grep -v "^SHELL=" | head -1
        if grep -q "curl" "$CRON_FILE"; then
            log_warn "Legacy network-fetching cron detected — run 'install' to replace it"
        fi
        echo ""
    else
        printf "${YELLOW}No cron job found.${NC}\n"
    fi
    echo ""
}

parse_args() {
    local mode="install"
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
            --time)
                if [[ -z "${2:-}" ]]; then
                    log_error "--time requires an HH:MM value"
                    exit 1
                fi
                if ! validate_time "$2"; then
                    log_error "Invalid --time value: $2 (use HH:MM format)"
                    exit 1
                fi
                shift 2 ;;
            --help|-h)
                usage ;;
            install|uninstall|status|run-now)
                mode="$1"; shift ;;
            *)
                log_error "Unknown option: $1"
                echo "Run with --help for usage."
                exit 1 ;;
        esac
    done

    echo "$mode"
}

install_auto_updates() {
    if [[ -f "$CRON_FILE" ]]; then
        log_info "Auto-update cron exists — rewriting it to ensure the local-only version"
    fi

    log "Starting Auto Update Setup..."

    # Ensure cron is installed
    if ! command -v crontab &>/dev/null; then
        log "Installing cron..."
        apt-get install -y -qq cron
        systemctl enable --now cron
    fi

    if [[ "$NON_INTERACTIVE" != true ]]; then
        prompt_update_time
    fi

    create_cron_job

    echo ""
    echo "=========================================="
    log "Auto Update Setup Complete!"
    echo "=========================================="
    echo ""
    printf "${GREEN}Configuration Summary:${NC}\n"
    echo "  - Update Schedule: Weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE} (Sunday)"
    echo "  - Maintenance: LOCAL script only ($MAINTENANCE_SCRIPT)"
    echo "  - No network downloads from cron — scripts update via the setup one-liner"
    echo "  - Reboot: Conditional (only if /var/run/reboot-required exists, +5 min delay)"
    echo "  - Log: /var/log/crusty-maintenance.log"
    echo ""

    if [[ "$NON_INTERACTIVE" != true ]]; then
        prompt_run_now
    fi

    echo ""
    printf "${GREEN}To manually trigger maintenance later, run:${NC}\n"
    echo "  sudo $MAINTENANCE_SCRIPT"
    echo ""
}

main() {
    check_root

    local mode
    mode=$(parse_args "$@")

    case "$mode" in
        install)
            install_auto_updates ;;
        uninstall)
            uninstall_auto_updates ;;
        status)
            show_config ;;
        run-now)
            run_updates_now ;;
        *)
            log_error "Unknown mode: $mode"
            exit 1 ;;
    esac
}

main "$@"
