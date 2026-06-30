#!/bin/bash
#
# Auto Update Script for Ubuntu Server
# Configures automatic weekly system updates
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
UPDATE_HOUR="02"
UPDATE_MINUTE="00"
NON_INTERACTIVE=false

usage() {
    cat << EOF
Usage: $0 [OPTION]

Configure automatic weekly system updates for Debian/Ubuntu.

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

create_cron_job() {
    log "Creating weekly update cron job for ${UPDATE_HOUR}:${UPDATE_MINUTE}..."
    cat > "$CRON_FILE" << EOF
# Crusty System - Combined weekly maintenance job (script download + apt updates + conditional reboot)
# Runs weekly on Sunday at ${UPDATE_HOUR}:${UPDATE_MINUTE}
# Downloads latest scripts, then runs apt update, full-upgrade, autoremove, autoclean, and reboots if needed
SHELL=/bin/bash
${UPDATE_MINUTE} ${UPDATE_HOUR} * * 0 root mkdir -p /opt/crusty-system && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh" -o /opt/crusty-system/setup.sh && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh" -o /opt/crusty-system/scripts/ubuntu/ssh-hardener.sh && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/docker-setup.sh" -o /opt/crusty-system/scripts/ubuntu/docker-setup.sh && curl -fsSL "https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh" -o /opt/crusty-system/scripts/ubuntu/auto-update.sh && /usr/bin/apt update -qq && /usr/bin/apt full-upgrade -y -qq && /usr/bin/apt autoremove --purge -y -qq && /usr/bin/apt autoclean && if [ -f /var/run/reboot-required ]; then /usr/sbin/shutdown -r +5 "Crusty System: reboot required after updates"; fi
EOF
    chmod 644 "$CRON_FILE"
    log "Cron job created at $CRON_FILE"
}

run_updates_now() {
    # Scripts are auto-updated in the weekly cron job — this function only runs apt maintenance.
    echo ""
    log "Starting immediate system update..."
    echo ""

    log "Running: apt update"
    if ! apt update -qq; then
        log_error "Failed to update package list"
        return 1
    fi
    log "Package list updated successfully"

    echo ""
    log "Running: apt full-upgrade -y"
    if ! apt full-upgrade -y -qq; then
        log_error "Failed to upgrade packages"
        return 1
    fi
    log "System packages upgraded successfully"

    echo ""
    log "Running: apt autoremove --purge -y"
    apt autoremove --purge -y -qq
    log "Orphaned packages removed"

    echo ""
    log "Running: apt autoclean"
    apt autoclean
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

    echo ""
    echo "=========================================="
    log "Uninstallation Complete!"
    echo "=========================================="
    echo ""
    printf "${GREEN}Removed:${NC}\n"
    echo "  - Cron job: $CRON_FILE"
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
        log_info "Auto-update cron already configured at $CRON_FILE"
        show_config
        return 0
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
    echo "  - Reboot: Conditional (only if /var/run/reboot-required exists, +5 min delay)"
    echo ""

    if [[ "$NON_INTERACTIVE" != true ]]; then
        prompt_run_now
    fi

    echo ""
    printf "${GREEN}To manually trigger an update later, run:${NC}\n"
    echo "  sudo apt update && sudo apt full-upgrade -y && sudo apt autoremove --purge -y && sudo apt autoclean"
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
