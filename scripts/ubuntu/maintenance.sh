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
