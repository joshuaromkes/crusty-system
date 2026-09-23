#!/usr/bin/env bash
#
# crusty — single-file Debian/Ubuntu server hardening wizard
#
# One file. No downloads, no pins, no module scripts. Re-run any time:
# crusty converges (check-before-apply everywhere) and heals V1 relics.
#
# Recommended (read it first):
#   curl -fsSLo crusty.sh <URL> && less crusty.sh && sudo bash crusty.sh
# Piping still works:
#   curl -fsSL <URL> | sudo bash
#
# Lockout-safety design (ported VERBATIM from V1 commit 90bb2ea — see the
# tagged comments; do not re-derive these):
#   C1  the SSH key is installed for a designated NON-ROOT user and VERIFIED
#       present before any authentication restriction is applied.
#   C2  sshd_config candidate is written to a temp file, pre-flighted with
#       `sshd -t`, atomically swapped, and on restart/listener failure the
#       backup is restored and the script EXITS 1 — log-and-continue is
#       FORBIDDEN here.
#   C3  port transitions keep the OLD port temporarily allowed in UFW, and
#       the new-port listener is verified BEFORE the firewall is committed.
#   H1  fail2ban is reloaded with `fail2ban-client reload`, NEVER restarted
#       (restarts historically severed live SSH sessions).
#   H4  /etc/ssh/sshd_config.d drop-ins are neutralized (moved to backup)
#       so they cannot silently re-enable password auth.
#   H5  the keyboard-interactive directive name is probed against this
#       OpenSSH (KbdInteractiveAuthentication vs the pre-8.7 name).
#   H10 SSH public keys are regex + ssh-keygen validated before use.
#   M3  /etc/docker/daemon.json is jq-MERGED (never blindly overwritten),
#       with a backup taken first.
#   M5  group/world-writable home dirs are warned about (StrictModes would
#       silently refuse key auth from them).
#   M6  UFW is never blindly reset — existing rules are always preserved.
#   M7  authorized_keys appends are atomic and dedup-safe.
#   G6  fail2ban uses `backend = systemd` (no logpath) — works on fresh
#       Debian 12 / Ubuntu 24.04 without rsyslog.
#
# CRON RULE (never break): the maintenance cron line in write_cron() must
# contain ZERO '%' characters — cron turns the first unescaped % into a
# newline and silently truncates the rest of the command. `date -Is` is
# used for exactly this reason. A self-check grep enforces it at runtime.
#
# Environment policy:
#   - PVE HOST: hard refusal, before any mutation (cluster SSH breaks).
#   - LXC/VM/bare metal: ONE uniform apply path. Env-sensitive modules
#     (UFW, fail2ban) fail SOFT at apply time: roll back what they touched,
#     warn, record the skip in /etc/crusty.conf, keep going. Never fatal.
#
# Idempotency invariants (amendment I1-I9): re-run converges; a second run
# with the same answers reports zero applied changes.

set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────

CRUSTY_VERSION="2.0.1"
# Env-overridable for tests (a fake-root harness redirects these to a sandbox)
STATE_FILE="${CRUSTY_STATE_FILE:-/etc/crusty.conf}"
INSTALL_LOG="${CRUSTY_INSTALL_LOG:-/var/log/crusty-install.log}"
CRON_FILE="${CRUSTY_CRON_FILE:-/etc/cron.d/crusty-maintenance}"
JAIL_LOCAL="${CRUSTY_JAIL_LOCAL:-/etc/fail2ban/jail.local}"
DAEMON_JSON="${CRUSTY_DAEMON_JSON:-/etc/docker/daemon.json}"
BACKUP_ROOT="${CRUSTY_BACKUP_ROOT:-/root/crusty-backups-}"

# LXC consoles can report 0x0 winsize — keep whiptail happy
export LINES="${LINES:-24}"
export COLUMNS="${COLUMNS:-80}"

# Wizard state (collected up front, applied after the final confirm)
TARGET_USER=""
TARGET_HOME=""
CRUSTY_CREATED_USER=0
CRUSTY_USER_UID=""
SET_PASSWORD=""
GRANT_SUDO=""
USER_PUBLIC_KEY=""
KEEP_KEYS=false          # re-run bypass: leave installed keys exactly as-is
REMOVE_KEYS=()           # keys explicitly queued for removal (shown in the plan)
EXISTING_KEYS=()         # keys already installed for the target user (pre-run)
SSH_KEY_FP=""            # fingerprint of the key this run installed/keeps (state)
SSH_PORT=22
ALLOW_TCP_FORWARDING="no"
ENABLE_DOCKER=false
DOCKER_USER=""
ENABLE_FAIL2BAN=true
ENABLE_MAINTENANCE=true
MAINT_HOUR="02"
MAINT_MINUTE="00"

# Flags
DRY_RUN=false
ASSUME_YES=false
UNINSTALL=false

# UI capability
HAVE_TTY=false
USE_WHIPTAIL=false
UI_CHILD=""                # pid of the live whiptail dialog (signal-aware kill)
KEY_MAX_LEN=4096           # pastes above this are rejected (paste/UI wedge guard)

# Environment
ENV_CLASS="bare"

# Mutable bookkeeping
CHANGES=0
CURRENT_STEP="startup"
UFW_SKIPPED=false
F2B_SKIPPED=false
DOCKER_RESULT="disabled"
SUDO_ADDED=0
DOCKER_GROUP_ADDED=0
BACKUP_DIR=""
PRIMARY_IP=""
# Ports sshd listens on right now (captured before config replacement)
CURRENT_SSH_PORTS=(22)
# Old ports we temporarily allowed in UFW during a port transition
UFW_TEMP_PORTS=()
# Firewall pre-flight (round-4, item 6): detected stack + operator decisions.
# FW_STACK is one of: none|ufw|inactive-ufw|firewalld|nft|iptables.
FW_STACK="none"
FW_REVIEWED=false            # existing rules were shown to the operator
FW_ALLOW_EXTRA=()            # inbound listeners the operator chose to keep open
FW_RULES_SEEN=0              # count of pre-existing rules shown in the plan
FW_OPERATOR_ACK=false        # non-UFW stack layering explicitly acknowledged
FW_OPT_OUT=false             # flag-forced: never layering UFW (--no-firewall)
FW_OPT_IN=false              # flag-forced: revisit/force UFW layering (--firewall)
# Old state (for pre-fill / drift view)
OLD_TARGET_USER=""
OLD_SSH_PORT=""
OLD_MAINT_TIME=""
OLD_CREATED_USER=""
OLD_USER_UID=""
OLD_SUDO_ADDED=""
OLD_SUDO=""              # previous SUDO choice — re-run pre-fill / convergence
OLD_SSH_KEY_FP=""        # fingerprint of a key crusty installed (headless bypass)
OLD_DGROUP_ADDED=""
OLD_FW_STACK=""          # firewall stack detected at the previous run
OLD_FW_EXTRA_ALLOW=""    # listeners allowed in a previous run (re-run pre-fill)
OLD_FW_ACK=""            # previous run's layering acknowledgment (yes/no)

# ─────────────────────────────────────────────────────────────
# Logging + traps
# ─────────────────────────────────────────────────────────────

_emit() {
    local marker="$1"
    shift
    printf '%s %s\n' "$marker" "$*" || true
    if [[ $EUID -eq 0 ]]; then
        printf '%s %s\n' "$marker" "$*" >> "$INSTALL_LOG" 2>/dev/null || true
    fi
}

log() {
    _emit '[+]' "$*"
}

log_note() {
    _emit '[i]' "$*"
}

log_warn() {
    _emit '[!]' "$*"
}

log_error() {
    _emit '[x]' "$*"
}

die() {
    log_error "$*"
    exit 1
}

set_step() {
    CURRENT_STEP="$1"
    printf -- '[.] %s\n' "$*" | tee -a "$INSTALL_LOG" 2>/dev/null || true
}

on_error() {
    local rc=$?
    trap - ERR
    log_error "FAILED (rc=$rc) during step: $CURRENT_STEP (line ${BASH_LINENO[0]:-?}: ${BASH_COMMAND:-?})"
    log_error "Last log lines ($INSTALL_LOG):"
    tail -n 10 "$INSTALL_LOG" 2>/dev/null | sed 's/^/      /' >&2 || true
    exit "$rc"
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [[ $rc -eq 0 ]]; then
        log_note "crusty run complete"
    else
        log_error "crusty run aborted (rc=$rc)"
    fi
}

sig_handler() {
    # Esc (whiptail rc 255) is the in-dialog quit; for real signals this is
    # the fallback when a dialog is up: whiptail/newt IGNORES INT and TERM
    # while it owns the raw terminal (verified empirically — even
    # group-level SIGTERM leaves the dialog up), so the live dialog child
    # is killed here. The invoking shell restores the terminal on exit.
    local sig="$1" code="$2"
    if [[ -n "$UI_CHILD" ]]; then
        kill -TERM "$UI_CHILD" 2>/dev/null || true
        kill -KILL "$UI_CHILD" 2>/dev/null || true
        wait "$UI_CHILD" 2>/dev/null || true
        UI_CHILD=""
    fi
    log_warn "caught SIG$sig — exiting without further changes"
    exit "$code"
}

trap on_error ERR
trap on_exit EXIT
trap 'sig_handler INT 130' INT
trap 'sig_handler TERM 143' TERM
trap 'sig_handler HUP 129' HUP

# ─────────────────────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────────────────────

usage() {
    cat << EOF
crusty $CRUSTY_VERSION — Debian/Ubuntu server hardening wizard (single file)

Usage: sudo bash crusty.sh [OPTIONS]

Interactive-first. A flag PRE-FILLS its answer and SKIPS its wizard prompt.
--yes accepts the defaults for anything left unasked. Headless (no TTY:
curl|bash, CI) requires --user, --ssh-key and --yes; password stays locked
by design in headless mode (key-only login).

Options:
  --user NAME              admin user the SSH key is installed for (refuses
                           root; created if absent, reused if present)
  --ssh-key KEY            SSH public key (paste or path to a .pub file);
                           validated before use. Optional on re-runs when
                           the state file records a valid key for the user
  --sudo / --no-sudo       add the admin user to the 'sudo' group
                           (interactive default: no in LXC, yes on VM/bare;
                           re-runs pre-fill the previous choice)
  --port N                 SSH port, default 22 (warns below 1024)
  --docker / --no-docker   install Docker Engine module (default: no)
  --docker-user NAME       user added to the docker group
                           (default: the admin user; implies --docker)
  --fail2ban / --no-fail2ban   fail2ban with systemd backend (default: yes)
  --maintenance / --no-maintenance   weekly local maintenance cron
                           (default: yes)
  --time HH:MM             maintenance time, default 02:00 Sunday
  --tcp-forwarding no|local|yes    AllowTcpForwarding, default no
                           (flag only — there is no wizard prompt for it)
  --firewall / --no-firewall   UFW on top of any detected firewall stack
                           (default: interactive asks when a non-UFW stack is
                           active; --no-firewall skips UFW outright, --firewall
                           forces layering even after a previous skip)
  --dry-run                show the plan, make zero changes
  --yes                    skip the final confirmation, take defaults
  --uninstall              remove exactly what crusty owns (incl. V1
                           relics); shows the plan and asks first
  --help, -h               this help

What it configures:
  1. packages       openssh-server, ufw, fail2ban, cron (as chosen)
  2. admin user     created only if absent (getent-guarded); password via
                    prompt only (chpasswd stdin, never argv, never logged;
                    decline = locked, key-only); sudo optional (--sudo)
  3. SSH key        for the non-root admin user, verified before any
                    restriction (C1); re-runs can keep installed keys
                    as-is, add another, or explicitly remove one
  4. sshd           hardened config: port, passwords off, root off,
                    pre-flight + atomic swap + rollback (C2)
  5. UFW            new port allowed, existing rules preserved (M6), old
                    port protected during transitions (C3)
  6. fail2ban       sshd jail, systemd backend (G6), reload-only (H1)
  7. Docker         official repo, hardened daemon.json merged (M3)
  8. maintenance    weekly LOCAL apt cron (flock, conffile-safe, never
                    downloads anything; reboots only when the OS asks)
  9. state          /etc/crusty.conf (0644, no secrets) — powers re-run
                    pre-fill, --dry-run drift view and --uninstall

Refuses to run on a Proxmox VE HOST (cluster SSH would break). Works inside
PVE guests (LXC/VM) and on bare metal. In containers, UFW/fail2ban fail
soft: they roll back, warn, and are recorded as skipped — never fatal.

Recommended two-step install (read what you run):
  curl -fsSLo crusty.sh <URL> && less crusty.sh && sudo bash crusty.sh
EOF
    exit 0
}

# ─────────────────────────────────────────────────────────────
# SSH public key validation (H10 — ported verbatim)
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

# Resolve a --ssh-key / pasted value that may be a path to a .pub file.
resolve_key_input() {
    local input="$1"
    if [[ -f "$input" ]]; then
        head -n 1 "$input" | tr -d '\r\n'
    else
        printf '%s' "$input" | tr -d '\r\n'
    fi
}

# Load the keys currently installed for a user (before this run) into
# EXISTING_KEYS (array of full key lines; comments/blank lines skipped).
collect_existing_keys() {
    EXISTING_KEYS=()
    local user="$1" home="" file
    # `|| true`: under set -Eeuo pipefail a failing getent (user not created
    # YET during the wizard — prompt_ssh_key runs before the apply phase)
    # would otherwise abort the whole script on a fresh box.
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$home" || ! -d "$home" ]] && return 0
    file="$home/.ssh/authorized_keys"
    [[ -f "$file" ]] || return 0
    local line
    while IFS= read -r line; do
        [[ "$line" == \#* || -z "$line" ]] && continue
        EXISTING_KEYS+=("$line")
    done < "$file"
}

# Has this user at least one installed key that passes validation (H10)?
# Used by the headless --ssh-key bypass: never trust state alone — the key
# must still actually be on disk.
user_has_installed_key() {
    local user="$1" k
    collect_existing_keys "$user"
    for k in "${EXISTING_KEYS[@]}"; do
        if validate_public_key "$k" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# First-line key prompt length cap. Real ed25519 keys are ~100-750 chars;
# a paste far beyond that is a wedged terminal or a foreign blob. We reject
# instead of feeding a truncated fragment to the H10 validator (which would
# then blame the KEY for what was a UI problem).
key_overlong() {
    local key="$1"
    [[ ${#key} -gt $KEY_MAX_LEN ]]
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_time() {
    local t="$1"
    if [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        (( 10#${BASH_REMATCH[1]} <= 23 && 10#${BASH_REMATCH[2]} <= 59 ))
    else
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────

need_value() {
    if [[ -z "${2:-}" || "$2" == --* ]]; then
        die "$1 requires a value"
    fi
}

parse_args() {
    # --help works without root, before anything else
    local arg
    for arg in "$@"; do
        [[ "$arg" == "--help" || "$arg" == "-h" ]] && usage
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                need_value "$@"
                TARGET_USER="$2"; shift 2 ;;
            --ssh-key)
                need_value "$@"
                USER_PUBLIC_KEY="$(resolve_key_input "$2")"; shift 2 ;;
            --port)
                need_value "$@"
                SSH_PORT="$2"; shift 2 ;;
            --docker)
                ENABLE_DOCKER=true; shift ;;
            --no-docker)
                ENABLE_DOCKER=false; shift ;;
            --docker-user)
                need_value "$@"
                DOCKER_USER="$2"; ENABLE_DOCKER=true; shift 2 ;;
            --fail2ban)
                ENABLE_FAIL2BAN=true; shift ;;
            --no-fail2ban)
                ENABLE_FAIL2BAN=false; shift ;;
            --maintenance)
                ENABLE_MAINTENANCE=true; shift ;;
            --no-maintenance)
                ENABLE_MAINTENANCE=false; shift ;;
            --sudo)
                GRANT_SUDO=yes; shift ;;
            --no-sudo)
                GRANT_SUDO=no; shift ;;
            --firewall)
                FW_OPT_OUT=false; FW_OPT_IN=true; shift ;;
            --no-firewall)
                FW_OPT_OUT=true; FW_OPT_IN=false; shift ;;
            --time)
                need_value "$@"
                if ! validate_time "$2"; then
                    die "Invalid --time '$2' (use HH:MM, 24h)"
                fi
                printf -v MAINT_HOUR '%02d' "$((10#${BASH_REMATCH[1]}))"
                printf -v MAINT_MINUTE '%02d' "$((10#${BASH_REMATCH[2]}))"
                shift 2 ;;
            --tcp-forwarding)
                need_value "$@"
                case "$2" in
                    no|local|yes) ALLOW_TCP_FORWARDING="$2" ;;
                    *) die "Invalid --tcp-forwarding '$2' (use: no, local, yes)" ;;
                esac
                shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --yes|-y)
                ASSUME_YES=true; shift ;;
            --uninstall)
                UNINSTALL=true; shift ;;
            *)
                die "Unknown option: $1 (run with --help)" ;;
        esac
    done

    # Early validation of flag-supplied values
    if [[ -n "$TARGET_USER" ]]; then
        if [[ "$TARGET_USER" == "root" ]]; then
            die "REFUSING --user root: this script sets 'PermitRootLogin no' — a root key is a lockout (C1)."
        fi
        validate_username "$TARGET_USER" || die "Invalid username '$TARGET_USER'"
    fi
    validate_port "$SSH_PORT" || die "Invalid port '$SSH_PORT' (1-65535)"
    if [[ -n "$USER_PUBLIC_KEY" ]]; then
        if ! validate_public_key "$USER_PUBLIC_KEY"; then
            die "The provided --ssh-key failed validation (H10) — refusing to continue"
        fi
    fi
    if [[ -n "$DOCKER_USER" ]]; then
        validate_username "$DOCKER_USER" || die "Invalid --docker-user '$DOCKER_USER'"
    fi
}

# ─────────────────────────────────────────────────────────────
# UI primitives — whiptail primary, plain-read fallback, TTY gate.
# No bare `read` anywhere: every read is gated on HAVE_TTY and reads
# /dev/tty so `curl | bash` still gets a working console.
# ─────────────────────────────────────────────────────────────

ui_init() {
    if (exec 3<>/dev/tty) 2>/dev/null; then
        HAVE_TTY=true
    fi
    if [[ "$HAVE_TTY" == true ]] && command -v whiptail &>/dev/null && [[ ${TERM:-dumb} != dumb ]]; then
        USE_WHIPTAIL=true
    fi
    if [[ "$HAVE_TTY" != true ]]; then
        # Spec §5: headless (no TTY — CI, cron) requires --user and --yes;
        # the account stays password-locked (key-only) by design. --ssh-key
        # is required later UNLESS the state file already records a valid
        # key for the user (re-run bypass — checked in prompt_ssh_key).
        if [[ "$ASSUME_YES" != true ]]; then
            die "No console (headless). Headless runs require --user, --ssh-key (unless the state file already records a valid key for the user) and --yes; the account stays password-locked (key-only) by design."
        fi
        if [[ "$UNINSTALL" != true ]]; then
            [[ -n "$TARGET_USER" ]] || die "headless run requires --user NAME (there is no console to ask)"
        fi
    fi
}

# Run whiptail in the BACKGROUND and wait for it. A foreground child makes
# bash defer the INT/TERM traps until the child exits, and whiptail/newt
# ignores INT+TERM while the dialog owns the (raw) terminal — the old code
# therefore wedged on ^C (byte in raw mode) and even on external signals.
# As a background job the shell is free to run sig_handler and kill the
# dialog child. rc passes through (0 ok, 1 Cancel, 255 Esc).
ui_box() {
    local rc=0 child
    whiptail "$@" 3>&1 1>&2 2>&3 &
    child=$!
    UI_CHILD=$child
    if ! wait "$child"; then
        rc=$?
    fi
    UI_CHILD=""
    return "$rc"
}

# Wide input box for SSH keys (real keys are ~100-750 chars; a narrow box
# invites truncated pastes). Clamped to the terminal so whiptail never
# errors out on a narrow LXC console.
ui_key_width() {
    local w=110
    if [[ -n "${COLUMNS:-}" && "$COLUMNS" -gt 0 && "$COLUMNS" -lt 110 ]]; then
        w="$COLUMNS"
    fi
    printf '%s' "$w"
}

# ui_input TITLE TEXT DEFAULT [WIDTH] -> echoes the answer. rc 0 = ok,
# rc 1 = back (Cancel), rc 2 = quit (Esc / 'quit' in the read fallback).
ui_input() {
    local title="$1" text="$2" default="$3" width="${4:-58}" out rc=0
    if [[ "$USE_WHIPTAIL" == true ]]; then
        out=$(ui_box --title "$title" --inputbox "$text" 12 "$width" "$default" \
                     --ok-button "OK" --cancel-button "Back") || rc=$?
        if (( rc == 255 )); then
            return 2   # Esc: quit the wizard, zero changes
        fi
        (( rc != 0 )) && return 1
        printf '%s' "$out"
        return 0
    fi
    printf '%s\n[%s] (enter ok, "quit" cancels): ' "$text" "$default" > /dev/tty
    if ! IFS= read -r out < /dev/tty; then
        die "console input closed (EOF) — aborting"
    fi
    case "$out" in
        [Qq][Uu][Ii][Tt]|[Cc][Aa][Nn][Cc][Ee][Ll]) return 2 ;;
    esac
    printf '%s' "${out:-$default}"
    return 0
}

# ui_password TITLE TEXT -> echoes the password (possibly empty). rc 1 = back,
# rc 2 = quit. The plain-read fallback has no quit word on purpose (a password
# may legitimately be 'quit') — Ctrl+C (cooked mode) is the quit there.
ui_password() {
    local title="$1" text="$2" out rc=0
    if [[ "$USE_WHIPTAIL" == true ]]; then
        out=$(ui_box --title "$title" --passwordbox "$text" 10 58 \
                     --ok-button "OK" --cancel-button "Back") || rc=$?
        if (( rc == 255 )); then
            return 2
        fi
        (( rc != 0 )) && return 1
        printf '%s' "$out"
        return 0
    fi
    printf '%s\n[hidden] (ctrl-c cancels): ' "$text" > /dev/tty
    if ! IFS= read -rs out < /dev/tty; then
        die "console input closed (EOF) — aborting"
    fi
    printf '\n' > /dev/tty
    printf '%s' "$out"
    return 0
}

# ui_yesno TITLE TEXT DEFAULT(yes|no) -> rc 0 = yes, rc 1 = no, rc 2 = quit.
ui_yesno() {
    local title="$1" text="$2" default="$3" out rc=0
    if [[ "$USE_WHIPTAIL" == true ]]; then
        ui_box --title "$title" --yesno "$text" 10 58 \
               --yes-button "Yes" --no-button "No" || rc=$?
        case "$rc" in
            0)    return 0 ;;
            255)  return 2 ;;   # Esc: quit, zero changes
            *)    return 1 ;;
        esac
    fi
    local hint="[y/N] (q=cancel)"
    [[ "$default" == yes ]] && hint="[Y/n] (q=cancel)"
    while true; do
        printf '%s\n%s ' "$text" "$hint" > /dev/tty
        if ! IFS= read -r out < /dev/tty; then
            die "console input closed (EOF) — aborting"
        fi
        case "${out:-$default}" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            [Qq]|[Qq][Uu][Ii][Tt]|[Cc][Aa][Nn][Cc][Ee][Ll]) return 2 ;;
            *) printf "Please answer 'y', 'n', or 'q' to quit.\n" > /dev/tty ;;
        esac
    done
}

ui_msg() {
    if [[ "$USE_WHIPTAIL" == true ]]; then
        ui_box --title "Attention" --msgbox "$1" 12 58 || true
    else
        printf '%s\n' "$1" > /dev/tty
    fi
}

# ui_menu TITLE TEXT TAG DESC [TAG DESC ...] -> echoes the chosen TAG.
# rc 0 = ok, rc 1 = back (Cancel), rc 2 = quit (Esc / 'quit').
ui_menu() {
    local title="$1" text="$2"; shift 2
    local out rc=0 i=1 line
    local -a tags=()
    if [[ "$USE_WHIPTAIL" == true ]]; then
        out=$(ui_box --title "$title" --menu "$text" 16 62 8 "$@" \
                     --ok-button "OK" --cancel-button "Back") || rc=$?
        case "$rc" in
            0)    printf '%s' "$out"; return 0 ;;
            255)  return 2 ;;
            *)    return 1 ;;
        esac
    fi
    while [[ $# -gt 1 ]]; do
        tags+=("$1")
        printf '  %d) %s\n' "$i" "$1" > /dev/tty
        i=$((i + 1)); shift 2
    done
    printf '%s\n' "$text" > /dev/tty
    while true; do
        printf 'Choose a number (or "quit"): ' > /dev/tty
        if ! IFS= read -r line < /dev/tty; then
            die "console input closed (EOF) — aborting"
        fi
        case "$line" in
            [Qq][Uu][Ii][Tt]|[Cc][Aa][Nn][Cc][Ee][Ll]) return 2 ;;
            "" | *[!0-9]*) printf "Enter the number of your choice, or 'quit'.\n" > /dev/tty ;;
            *)
                if (( line >= 1 && line <= ${#tags[@]} )); then
                    printf '%s' "${tags[$((line - 1))]}"
                    return 0
                fi
                printf 'Invalid choice.\n' > /dev/tty ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────

ensure_root() {
    local -a args=("$@")
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]] && ! sudo -n true 2>/dev/null; then
        log_warn "dry-run without root and sudo needs a password — showing the plan with limited live state"
        return 0
    fi
    if ! command -v sudo &>/dev/null; then
        die "must run as root and sudo is not available — re-run as root: sudo bash crusty.sh"
    fi
    if [[ ! -f "$0" ]]; then
        die "cannot elevate a piped script — download first: curl -fsSLo crusty.sh <URL> && sudo bash crusty.sh"
    fi
    log_note "re-execing as root via sudo"
    exec sudo bash "$0" "${args[@]}"
}

detect_os() {
    set_step "OS detection"
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS: /etc/os-release not found"
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
        die "Only Debian and Ubuntu are supported (detected: ${ID:-unknown})"
    fi
    log_note "detected ${PRETTY_NAME:-unknown} (${VERSION_CODENAME:-?})"
}

# Environment detection per spec §4. Missing /proc/self/uid_map must NOT
# default to privileged-assume-features — treat as unknown and proceed
# uniformly (amendment 3-B: no capability branching in the apply path).
detect_environment() {
    set_step "environment detection"
    ENV_CLASS="bare"
    if [[ -f /etc/pve/.node_name ]] || command -v pveversion &>/dev/null; then
        ENV_CLASS="pve-host"
    else
        local container virt
        container=$(systemd-detect-virt --container 2>/dev/null || true)
        virt=$(systemd-detect-virt 2>/dev/null || true)
        if [[ -n "$container" && "$container" != "none" ]]; then
            case "$container" in
                lxc|openvz)
                    if [[ -f /proc/self/uid_map ]] && awk '$1==0 && $2==0' /proc/self/uid_map | grep -q .; then
                        ENV_CLASS="lxc-privileged"
                    elif [[ -f /proc/self/uid_map ]] && awk '$1==0 && $2>0' /proc/self/uid_map | grep -q .; then
                        ENV_CLASS="lxc-unprivileged"
                    else
                        ENV_CLASS="lxc-unknown"   # uid_map absent ≠ privileged
                    fi
                    ;;
                *)
                    ENV_CLASS="container-other"
                    ;;
            esac
        elif [[ -n "$virt" && "$virt" != "none" ]]; then
            ENV_CLASS="vm"
        fi
    fi
    case "$ENV_CLASS" in
        pve-host)
            log_error "REFUSING to run on a Proxmox VE HOST."
            log_error "SSH hardening (PermitRootLogin no, PasswordAuthentication no) breaks PVE"
            log_error "cluster migration/replication, which relies on root SSH between nodes."
            log_error "Harden the PVE host following the vendor guide instead:"
            log_error "  https://pve.proxmox.com/wiki/Security"
            log_error "Inside PVE guests (LXC/VM) crusty is fully supported."
            exit 1
            ;;
        lxc-privileged)   log_note "environment: privileged LXC container" ;;
        lxc-unprivileged) log_note "environment: unprivileged LXC container" ;;
        lxc-unknown)      log_note "environment: LXC container (privilege unknown — uid_map absent)" ;;
        container-other) log_note "environment: non-LXC container ($container)" ;;
        vm)               log_note "environment: virtual machine ($virt)" ;;
        bare)             log_note "environment: bare metal" ;;
    esac
}

is_container() {
    [[ "$ENV_CLASS" == lxc-* || "$ENV_CLASS" == "container-other" ]]
}

sudo_default() {
    # Spec ruling #5: no inside LXC (PVE console is the admin path), yes on VM/bare
    if is_container; then
        printf 'no'
    else
        printf 'yes'
    fi
}

load_state() {
    set_step "reading state file"
    if [[ -f "$STATE_FILE" ]]; then
        local line key val
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            key="${line%%=*}"
            val="${line#*=}"
            case "$key" in
                TARGET_USER)          OLD_TARGET_USER="$val" ;;
                SSH_PORT)             OLD_SSH_PORT="$val" ;;
                MAINT_TIME)           OLD_MAINT_TIME="$val" ;;
                CRUSTY_CREATED_USER)  OLD_CREATED_USER="$val" ;;
                CRUSTY_USER_UID)      OLD_USER_UID="$val" ;;
                SUDO)                 OLD_SUDO="$val" ;;
                SUDO_ADDED)           OLD_SUDO_ADDED="$val" ;;
                SSH_KEY_FP)           OLD_SSH_KEY_FP="$val" ;;
                DOCKER_GROUP_ADDED)   OLD_DGROUP_ADDED="$val" ;;
                FW_STACK)             OLD_FW_STACK="$val" ;;
                FW_EXTRA_ALLOW)       OLD_FW_EXTRA_ALLOW="$val" ;;
                FW_ACK)               OLD_FW_ACK="$val" ;;
            esac
        done < "$STATE_FILE"
        log_note "previous crusty state found (user=${OLD_TARGET_USER:-?}, port=${OLD_SSH_PORT:-?})"
    fi
}

# ─────────────────────────────────────────────────────────────
# Wizard — collect EVERYTHING first (9 prompts), then plan+confirm.
# Cancel on step 1 exits; cancel on later steps goes back one step.
# ─────────────────────────────────────────────────────────────

wizard() {
    local steps=(
        prompt_user
        prompt_password
        prompt_sudo
        prompt_ssh_key
        prompt_port
        prompt_modules
        prompt_firewall
        prompt_docker_user
        prompt_maint_time
    )
    local i=0 rc=0
    while (( i < ${#steps[@]} )); do
        rc=0   # reset every iteration: `|| rc=$?` only assigns on nonzero
        "${steps[$i]}" || rc=$?
        case $rc in
            0)   i=$((i + 1)) ;;
            2)   log_note "quit requested — nothing was changed"
                 exit 0 ;;
            *)   # rc 1 = back one step; rc 255 = Esc handled earlier
                if (( i == 0 )); then
                    log_note "cancelled at the first prompt — nothing was changed"
                    exit 0
                fi
                i=$((i - 1))
                ;;
        esac
    done
}

prompt_user() {
    if [[ -n "$TARGET_USER" ]]; then
        return 0    # pre-filled by --user
    fi
    if [[ "$ASSUME_YES" == true ]]; then
        # --yes takes the default (spec §5); still refuse root (C1)
        TARGET_USER="${SUDO_USER:-${OLD_TARGET_USER:-admin}}"
        [[ "$TARGET_USER" != "root" ]] || die "REFUSING the --yes default user 'root' — pass --user NAME (C1)"
        validate_username "$TARGET_USER" || die "Invalid default user '$TARGET_USER' — pass --user NAME"
        log_note "--yes: using admin user '$TARGET_USER'"
        return 0
    fi
    local default="${SUDO_USER:-${OLD_TARGET_USER:-admin}}"
    local answer rc=0
    while true; do
        answer=$(ui_input "Admin user" \
            "Dedicated non-root admin user. Created if absent, reused if present. Never root (C1)." \
            "$default") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        if [[ "$answer" == "root" ]]; then
            ui_msg "REFUSING root: crusty sets PermitRootLogin no — a root-only key is a guaranteed lockout (C1)."
            continue
        fi
        if ! validate_username "$answer"; then
            ui_msg "Invalid username. Use lowercase letters, digits, _ or -, starting with a letter or _ (max 32 chars)."
            continue
        fi
        TARGET_USER="$answer"
        return 0
    done
}

prompt_password() {
    if [[ "$HAVE_TTY" != true ]]; then
        SET_PASSWORD=""
        log_note "headless: account stays password-locked (key-only) by design"
        return 0
    fi
    if [[ "$ASSUME_YES" == true ]]; then
        SET_PASSWORD=""
        log_note "--yes: password left as-is (new users stay locked, key-only)"
        return 0
    fi
    local p1 p2 rc=0
    while true; do
        p1=$(ui_password "Password (1/2)" \
            "Set a password for the admin user.
Leave EMPTY to skip (new/locked accounts become key-only; existing passwords are NOT touched).") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        p2=$(ui_password "Password (2/2)" "Repeat the password (must match).") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        if [[ -z "$p1" && -z "$p2" ]]; then
            SET_PASSWORD=""
            return 0
        fi
        if [[ "$p1" != "$p2" ]]; then
            ui_msg "Passwords do not match — try again, or leave both empty to skip."
            continue
        fi
        SET_PASSWORD="$p1"
        return 0
    done
}

prompt_sudo() {
    if [[ -z "$GRANT_SUDO" && "$ASSUME_YES" == true ]]; then
        GRANT_SUDO="${OLD_SUDO:-$(sudo_default)}"
        return 0
    fi
    if [[ -z "$GRANT_SUDO" && "$HAVE_TTY" != true ]]; then
        GRANT_SUDO="${OLD_SUDO:-$(sudo_default)}"
        return 0
    fi
    if [[ -n "$GRANT_SUDO" ]]; then
        return 0
    fi
    local def rc=0
    # Re-run convergence: pre-fill the PREVIOUS choice, not the fresh default
    def="${OLD_SUDO:-$(sudo_default)}"
    local text
    text="Add '$TARGET_USER' to the 'sudo' group?
(LXC default: no — the PVE console is the admin path.
VM/bare-metal default: yes.)"
    ui_yesno "Sudo access" "$text" "$def" || rc=$?
    case $rc in
        2) return 2 ;;
        0) GRANT_SUDO="yes" ;;
        1) GRANT_SUDO="no" ;;
    esac
    [[ "$def" != "$GRANT_SUDO" ]] && OLD_SUDO=""   # diverge from state -> plan shows the change
    return 0
}

paste_key_prompt() {
    local answer rc=0 key
    while true; do
        answer=$(ui_input "SSH public key" \
            "Paste your SSH PUBLIC key (ssh-ed25519 AAAA... user@host) or a path to a .pub file.
A key is REQUIRED: password auth will be disabled." \
            "" "$(ui_key_width)") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        key="$(resolve_key_input "$answer")"
        if [[ -z "$key" ]]; then
            ui_msg "The key cannot be empty — password auth will be disabled, so a key is mandatory."
            continue
        fi
        # Paste/UI wedge guard: an over-long paste (wedged terminal buffer,
        # accidental multi-line dump) is REJECTED with a clear message instead
        # of being silently truncated by the input box / validator.
        if key_overlong "$key"; then
            ui_msg "Pasted input is ${#key} characters — above the ${KEY_MAX_LEN}-char cap.
This is usually a wedged terminal paste, not a key. Re-paste a single public key (max ${KEY_MAX_LEN} chars)."
            continue
        fi
        if ! validate_public_key "$key"; then
            ui_msg "That does not look like a valid SSH public key (H10).
Valid types: ssh-ed25519, ssh-rsa, ssh-dss, ecdsa-sha2-nistp256|384|521, sk-ssh-ed25519, sk-ecdsa — followed by a long base64 blob."
            continue
        fi
        USER_PUBLIC_KEY="$key"
        return 0
    done
}

view_keys() {
    local out="Installed keys for '$TARGET_USER':" line
    local i k fp
    if [[ ${#EXISTING_KEYS[@]} -eq 0 ]]; then
        ui_msg "No installed keys found for '$TARGET_USER'."
        return 0
    fi
    for i in "${!EXISTING_KEYS[@]}"; do
        k="${EXISTING_KEYS[$i]}"
        fp=""
        if command -v ssh-keygen &>/dev/null; then
            fp="$(printf '%s\n' "$k" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true)"
        fi
        out+="\n[$((i + 1))] ${fp:-${k:0:60}}"
    done
    ui_msg "$out"
    return 0
}

# Remove one installed key. LOCKOUT-SAFETY: refusing to remove the LAST key
# (password auth is disabled — a zero-key box is lockout by construction),
# unless a replacement is being added in the same run.
remove_key_prompt() {
    local rc=0 choice i k desc
    local -a tags=()
    for i in "${!EXISTING_KEYS[@]}"; do
        k="${EXISTING_KEYS[$i]}"
        desc="${k:0:70}"
        tags+=("$i" "$desc")
    done
    choice=$(ui_menu "Remove a key" \
        "Pick the key to REMOVE (shown in the plan; keys are never removed implicitly):" \
        "${tags[@]}") || rc=$?
    case $rc in
        2) return 2 ;;
        1) return 1 ;;
    esac
    if [[ ${#REMOVE_KEYS[@]} -eq 0 && ${#EXISTING_KEYS[@]} -le 1 && -z "$USER_PUBLIC_KEY" ]]; then
        ui_msg "REFUSING: that is the LAST installed key. Removing it leaves no way in
(password auth is disabled by crusty). Add a replacement key first, or keep this one."
        return 0
    fi
    REMOVE_KEYS+=("${EXISTING_KEYS[10#$choice]}")
    unset 'EXISTING_KEYS[10#'"$choice"']'
    # collapse the array to drop the hole
    local -a shifted=()
    for k in "${EXISTING_KEYS[@]}"; do shifted+=("$k"); done
    EXISTING_KEYS=("${shifted[@]}")
    log_note "queued removal of key ${REMOVE_KEYS[-1]:0:60}... (explicit)"
    return 0
}

key_management_menu() {
    local rc=0 choice
    while true; do
        choice=$(ui_menu "SSH keys" \
            "Manage installed keys for '$TARGET_USER' (re-run keep/add/view/remove):" \
            keep   "Keep existing key(s) — no changes" \
            add    "Add a new key (paste another)" \
            view   "View installed keys" \
            remove "Remove an installed key (explicit)" \
            quit   "Quit — no changes") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        case "$choice" in
            keep)
                KEEP_KEYS=true
                log_note "keeping existing keys as-is (user chose keep)"
                return 0
                ;;
            add)
                paste_key_prompt || return $?
                return 0
                ;;
            view)
                view_keys || return $?
                ;;
            remove)
                remove_key_prompt || return $?
                ;;
            quit)
                return 2
                ;;
        esac
    done
}

prompt_ssh_key() {
    if [[ -n "$USER_PUBLIC_KEY" ]]; then
        return 0    # pre-filled and validated by --ssh-key
    fi
    if [[ "$KEEP_KEYS" == true ]]; then
        return 0    # explicit --keep-keys (or keep chosen earlier)
    fi
    # State records a valid key for this user AND it is still on disk:
    # headless/--yes re-runs (module flips only) must not be forced to
    # re-declare a key (round-3 requirement). Key stays untouched.
    if [[ -n "$OLD_SSH_KEY_FP" ]] && user_has_installed_key "$TARGET_USER" \
       && { [[ "$HAVE_TTY" != true || "$ASSUME_YES" == true ]]; }; then
        KEEP_KEYS=true
        log_note "state records a valid key for '$TARGET_USER' — keeping existing keys (--ssh-key optional on re-runs)"
        return 0
    fi
    if [[ "$HAVE_TTY" != true ]]; then
        die "headless run requires --ssh-key (no key recorded in $STATE_FILE for '$TARGET_USER')"
    fi
    if [[ "$ASSUME_YES" == true ]]; then
        die "--yes with no --ssh-key: no key recorded in $STATE_FILE for '$TARGET_USER' — pass --ssh-key (or drop --yes to use the menu)"
    fi
    collect_existing_keys "$TARGET_USER"
    if [[ ${#EXISTING_KEYS[@]} -gt 0 ]]; then
        key_management_menu || return $?
        return 0
    fi
    paste_key_prompt
}

prompt_port() {
    if [[ "$SSH_PORT" != 22 ]]; then
        return 0    # pre-filled by --port
    fi
    if [[ "$ASSUME_YES" == true ]]; then
        [[ -n "$OLD_SSH_PORT" ]] && SSH_PORT="$OLD_SSH_PORT"
        return 0
    fi
    local default="${OLD_SSH_PORT:-22}"
    local answer rc=0 yn=0
    while true; do
        answer=$(ui_input "SSH port" \
            "SSH port to listen on (current: ${CURRENT_SSH_PORTS[*]}).
22 is fine behind a parent firewall (PVE/WireGuard); a custom port only adds obscurity. 80/443 are refused." \
            "$default") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        if ! validate_port "$answer"; then
            ui_msg "Port must be a number between 1 and 65535."
            continue
        fi
        if [[ "$answer" == 80 || "$answer" == 443 ]]; then
            ui_msg "Port 80/443 is reserved for HTTP/HTTPS — pick another port."
            continue
        fi
        if (( 10#$answer < 1024 )) && [[ "$answer" != 22 ]]; then
            yn=0   # reset — `|| yn=$?` only assigns on nonzero (stale-rc guard)
            ui_yesno "SSH port < 1024" \
                "Ports below 1024 are usually reserved for system services.
Use port $answer anyway?" "no" || yn=$?
            case $yn in
                2) return 2 ;;
                1) continue ;;
            esac
        fi
        SSH_PORT="$answer"
        return 0
    done
}

prompt_modules() {
    local any_flag=false
    if [[ "$ENABLE_DOCKER" == true || "${DOCKER_USER:-}" != "" ]]; then any_flag=true; fi
    if [[ "$ENABLE_FAIL2BAN" == false ]]; then any_flag=true; fi
    if [[ "$ENABLE_MAINTENANCE" == false ]]; then any_flag=true; fi
    if [[ "$any_flag" == true ]]; then
        return 0    # at least one module flag given — defaults cover the rest
    fi
    if [[ "$ASSUME_YES" == true ]]; then
        return 0    # defaults: docker off, fail2ban on, maintenance on
    fi
    if [[ "$USE_WHIPTAIL" == true ]]; then
        local out choices rc=0 yn=0 c
        while true; do
            out=$(ui_box --title "Modules" --checklist \
                    "Choose what to install/configure (Space toggles):" 16 58 4 \
                    "fail2ban"    "Intrusion prevention (systemd backend)" ON \
                    "maintenance" "Weekly local apt maintenance cron"      ON \
                    "docker"      "Docker Engine + Compose (hardened)"     OFF) || rc=$?
            case $rc in
                2) return 2 ;;    # Esc: quit, zero changes
                1) return 1 ;;    # Cancel: back
            esac
            ENABLE_FAIL2BAN=false
            ENABLE_MAINTENANCE=false
            ENABLE_DOCKER=false
            choices=$(printf '%s' "$out" | tr -s ' ' '\n')
            for c in $choices; do
                case "$c" in
                    fail2ban)    ENABLE_FAIL2BAN=true ;;
                    maintenance) ENABLE_MAINTENANCE=true ;;
                    docker)      ENABLE_DOCKER=true ;;
                esac
            done
            # PITFALL GUARD (Guac/noVNC): whiptail checklist toggles (SPACE)
            # can silently fail to register over remote consoles. If BOTH
            # modules that DEFAULT ON come back unchecked with an empty
            # selection (no manual toggle at all), re-confirm explicitly
            # before proceeding — an empty OK here permanently disables
            # fail2ban + maintenance while the operator believes they are on.
            if [[ "$ENABLE_FAIL2BAN" != true && "$ENABLE_MAINTENANCE" != true ]]; then
                yn=0   # reset — `|| yn=$?` only assigns on nonzero (stale-rc guard)
                ui_yesno "Module selection warning" \
                    "fail2ban and maintenance BOTH came back unchecked with an empty selection.

If you intended them ON and only pressed Enter, the checklist SPACE-toggles
may not have registered over this console (known Guac/noVNC issue).

Proceed with both DISABLED?" "no" || yn=$?
                case $yn in
                    2) return 2 ;;
                    1) continue ;;    # re-show the checklist
                    0) return 0 ;;    # operator confirms — proceed
                esac
            fi
            return 0
        done
    fi
    # read fallback — explicit quit word on every yes/no (rc 2)
    local yn1=0 yn2=0 yn3=0
    ui_yesno "fail2ban" "Install fail2ban (intrusion prevention)?" "yes" || yn1=$?
    case $yn1 in
        2) return 2 ;;
        1) ENABLE_FAIL2BAN=false ;;
        0) ENABLE_FAIL2BAN=true ;;
    esac
    ui_yesno "maintenance" "Enable weekly LOCAL maintenance (apt update/upgrade, conditional reboot)?" "yes" || yn2=$?
    case $yn2 in
        2) return 2 ;;
        1) ENABLE_MAINTENANCE=false ;;
        0) ENABLE_MAINTENANCE=true ;;
    esac
    ui_yesno "docker" "Install Docker Engine + Compose (hardened daemon)?" "no" || yn3=$?
    case $yn3 in
        2) return 2 ;;
        1) ENABLE_DOCKER=false ;;
        0) ENABLE_DOCKER=true ;;
    esac
    # same pitfall guard on the read fallback: both default-ON rejected
    if [[ "$ENABLE_FAIL2BAN" != true && "$ENABLE_MAINTENANCE" != true ]]; then
        ui_msg "NOTE: fail2ban and maintenance are both DISABLED — both default ON.
You answered No to both; re-run with --fail2ban/--maintenance to flip."
    fi
    return 0
}

prompt_docker_user() {
    if [[ "$ENABLE_DOCKER" != true ]]; then
        return 0
    fi
    if [[ -n "$DOCKER_USER" ]]; then
        return 0
    fi
    if [[ "$ASSUME_YES" == true ]]; then
        DOCKER_USER="$TARGET_USER"
        return 0
    fi
    local answer rc=0
    while true; do
        answer=$(ui_input "Docker user" \
            "User added to the 'docker' group (root-equivalent on this host).
Default: the admin user ($TARGET_USER)." \
            "$TARGET_USER") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        if ! validate_username "$answer"; then
            ui_msg "Invalid username."
            continue
        fi
        DOCKER_USER="$answer"
        return 0
    done
}

prompt_maint_time() {
    if [[ "$ENABLE_MAINTENANCE" != true ]]; then
        return 0
    fi
    if [[ "${MAINT_HOUR}" != "02" || "${MAINT_MINUTE}" != "00" ]]; then
        return 0    # pre-filled by --time
    fi
    if [[ "$ASSUME_YES" == true ]]; then
        [[ -n "$OLD_MAINT_TIME" ]] && IFS=: read -r MAINT_HOUR MAINT_MINUTE <<< "$OLD_MAINT_TIME"
        return 0
    fi
    local default="${OLD_MAINT_TIME:-02:00}"
    local answer rc=0
    while true; do
        answer=$(ui_input "Maintenance time" \
            "Weekly maintenance runs every Sunday at this time (24h HH:MM).
It is LOCAL and never downloads anything." \
            "$default") || rc=$?
        case $rc in
            2) return 2 ;;
            1) return 1 ;;
        esac
        if ! validate_time "$answer"; then
            ui_msg "Use 24-hour HH:MM, e.g. 02:00 or 14:30."
            continue
        fi
        printf -v MAINT_HOUR '%02d' "$((10#${BASH_REMATCH[1]}))"
        printf -v MAINT_MINUTE '%02d' "$((10#${BASH_REMATCH[2]}))"
        return 0
    done
}

# ─────────────────────────────────────────────────────────────
# Firewall pre-flight (round-4, item 6) — detect the existing stack
# BEFORE enabling UFW; WARN + ASK when a non-UFW stack is active;
# review/remove pre-existing rules; one-shot allow for inbound
# listeners default-deny would cut off.
# ─────────────────────────────────────────────────────────────

# Detect which firewall stack is live. Sets FW_STACK:
#   none / ufw / inactive-ufw / firewalld / nft / iptables
fw_detect_stack() {
    FW_STACK="none"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            FW_STACK="ufw"
        else
            FW_STACK="inactive-ufw"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 \
       && systemctl is-active --quiet firewalld 2>/dev/null; then
        FW_STACK="firewalld"
        return 0
    fi
    # UFW/firewalld own the box; nothing to warn about layering on top.
    if [[ "$FW_STACK" == "ufw" || "$FW_STACK" == "firewalld" ]]; then
        return 0
    fi
    # nftables: count chains that are NOT owned by crusty's own modules
    # (ufw- backend tables, f2b- fail2ban chains).
    if command -v nft >/dev/null 2>&1; then
        local nft_foreign
        nft_foreign="$(nft list ruleset 2>/dev/null | grep -E 'chain ' | grep -vcE 'f2b-|ufw-' 2>/dev/null || true)"
        if (( nft_foreign > 0 )); then
            FW_STACK="nft"
            return 0
        fi
    fi
    if command -v iptables-save >/dev/null 2>&1; then
        local ipt_foreign
        ipt_foreign="$(iptables-save 2>/dev/null | grep -E '^\-A ' | grep -vcE 'f2b-|ufw-' 2>/dev/null || true)"
        if (( ipt_foreign > 0 )); then
            FW_STACK="iptables"
            return 0
        fi
    fi
    return 0
}

# Print existing UFW rules one per line as "<action> <port>/<proto>" — the
# spec `ufw delete` understands (never rule numbers, which renumber). Uses
# `ufw show added` (works even when inactive; ufw stores rules in files).
# Rules already queued for removal (FW_REMOVE_RULES) are not listed again.
fw_rule_specs() {
    command -v ufw >/dev/null 2>&1 || return 0
    local spec q
    { ufw show added 2>/dev/null || true; } | awk '$2 == "ALLOW" || $2 == "DENY" || $2 == "LIMIT" {
        printf "%s %s\n", tolower($2), $1 }' | sort -u | while IFS= read -r spec; do
        for q in "${FW_REMOVE_RULES[@]:-}"; do
            [[ "$spec" == "$q" ]] && continue 2
        done
        printf '%s\n' "$spec"
    done
}

# Count pre-existing rules for the plan display and the wizard review step.
fw_count_rules() {
    fw_rule_specs | sed '/^$/d' | wc -l | tr -d ' '
}

# Print the running service + port for each TCP listener, one per line:
#   "8080 <service>"  (ss -tlnp; no process info when unprivileged)
fw_listener_lines() {
    command -v ss >/dev/null 2>&1 || { echo "(ss not available) 0 unknown"; return 0; }
    ss -tlnp 2>/dev/null | awk 'NR>1 {
        split($4, a, ":"); port=a[length(a)];
        if (port !~ /^[0-9]+$/) next;
        svc=$6; sub(/^users:\(\("/, "", svc); sub(/".*/, "", svc);
        printf "%s %s\n", port, (svc=="" ? "unknown" : svc)
    }' | sort -n -u
}

# ─────────────────────────────────────────────────────────────
# Wizard step — firewall pre-flight (round-4, item 6)
# ─────────────────────────────────────────────────────────────
prompt_firewall() {
    FW_OPERATOR_ACK=false
    FW_REVIEWED=false
    FW_RULES_SEEN=0
    FW_ALLOW_EXTRA=()
    FW_REMOVE_RULES=()

    fw_detect_stack

    # --no-firewall: flag-forced opt-out outranks everything (even a previous
    # acknowledged run). Recorded in state so a converged re-run stays quiet.
    if [[ "$FW_OPT_OUT" == true ]]; then
        log_note "--no-firewall: UFW will be skipped regardless of stack"
        UFW_SKIPPED=true
        return 0
    fi

    # Headless / --yes: restore the previously allowed listeners into the plan
    # and apply. The allow itself is idempotent (I4), so an identical re-run
    # stays at zero changes — but the state's FW_EXTRA_ALLOW is the source of
    # truth for what must stay open across runs (round-4, item 6(c)).
    if [[ "$HAVE_TTY" != true || "$ASSUME_YES" == true ]] && [[ -n "$OLD_FW_EXTRA_ALLOW" ]]; then
        FW_ALLOW_EXTRA=()
        local _p
        for _p in $OLD_FW_EXTRA_ALLOW; do FW_ALLOW_EXTRA+=("$_p"); done
        log_note "restoring previously allowed listeners: ${FW_ALLOW_EXTRA[*]}"
    fi

    # (a) non-UFW stack active: WARN + ASK instead of silently layering UFW.
    if [[ "$FW_STACK" != "none" && "$FW_STACK" != "ufw" && "$FW_STACK" != "inactive-ufw" ]]; then
        # Converged re-run: same stack, already decided (either way) — no re-ask,
        # unless --firewall explicitly overrides a previous skip.
        if [[ "$OLD_FW_STACK" == "$FW_STACK" && -n "$OLD_FW_ACK" ]]; then
            if [[ "$FW_OPT_IN" == true && "$OLD_FW_ACK" != "yes" ]]; then
                FW_OPERATOR_ACK=true
                log_note "--firewall: overriding the previous skip of $FW_STACK — UFW will be layered"
            elif [[ "$OLD_FW_ACK" == "yes" || "$FW_OPT_IN" == true ]]; then
                FW_OPERATOR_ACK=true
                log_note "firewall stack $FW_STACK unchanged since the acknowledged run — reusing that decision"
            else
                log_note "UFW skipped in a previous run (stack $FW_STACK kept) — reusing that decision"
                UFW_SKIPPED=true
                return 0
            fi
        elif [[ "$HAVE_TTY" != true || "$ASSUME_YES" == true ]]; then
            log_warn "[!] non-UFW firewall stack detected: $FW_STACK — refusing to silently layer UFW on top"
            log_warn "[!] UFW skipped; existing $FW_STACK stack kept (state: FW_ACK=no). Re-run with --firewall to override."
            UFW_SKIPPED=true
            return 0
        else
            local text yn=0
            text="A NON-UFW firewall stack is ACTIVE on this box: $FW_STACK.\n\nUFW would be layered ON TOP of it. Existing rules are never reset (M6), but two stacks can fight over the same chains.\n\nProceed with UFW anyway?"
            ui_yesno "Existing firewall detected" "$text" "no" || yn=$?
            case $yn in
                2) return 2 ;;
                1) log_note "UFW skipped — keeping the existing $FW_STACK stack"
                   UFW_SKIPPED=true
                   return 0 ;;
                0) FW_OPERATOR_ACK=true
                   log_note "operator acknowledged layering UFW on top of $FW_STACK" ;;
            esac
        fi
    fi

    if [[ "$UFW_SKIPPED" == true || "$HAVE_TTY" != true || "$ASSUME_YES" == true ]]; then
        return 0
    fi

    # (b) show existing rules; operator may review and remove from inside crusty.
    if command -v ufw >/dev/null 2>&1; then
        FW_RULES_SEEN="$(fw_count_rules)"
        if (( FW_RULES_SEEN > 0 )); then
            local rules
            rules="$(fw_rule_specs)"
            ui_msg "Existing UFW rules ($FW_RULES_SEEN) — crusty never resets or hides these:
$rules"
            local yn=0
            ui_yesno "Review existing rules" "Remove any pre-existing UFW rule as part of this run? (each removal is explicit and shown in the plan)" "no" || yn=$?
            case $yn in
                2) return 2 ;;
                1) FW_REVIEWED=true ;;
                0)
                    FW_REVIEWED=true
                    local spec rc=0 choice i
                    while true; do
                        local -a opts=()
                        i=0
                        while IFS= read -r spec; do
                            [[ -n "$spec" ]] || continue
                            i=$((i + 1))
                            opts+=("$i" "$spec")
                        done < <(fw_rule_specs)
                        (( ${#opts[@]} > 0 )) || { ui_msg "No removable rules left."; break; }
                        choice=$(ui_menu "Remove a rule" "Pick a pre-existing UFW rule to REMOVE (explicit; shown in the plan)." \
                            "${opts[@]}" \
                            "done" "Stop removing rules") || rc=$?
                        case $rc in
                            2) return 2 ;;
                            1) break ;;
                        esac
                        [[ "$choice" == "done" ]] && break
                        spec="$(fw_rule_specs | sed -n "${choice}p")"
                        [[ -z "$spec" ]] && { ui_msg "No such rule."; continue; }
                        FW_REMOVE_RULES+=("$spec")
                        log_note "queued removal: ufw delete $spec (explicit)"
                    done
                    ;;
            esac
        fi
    fi

    # (c) inbound listeners default-deny would cut off: warn + one-shot allow.
    local -A allowed=()
    local p spec_line
    for p in "${CURRENT_SSH_PORTS[@]}" "$SSH_PORT"; do allowed[$p]=1; done
    while IFS= read -r spec_line; do
        [[ -z "$spec_line" ]] && continue
        p="${spec_line##* }"; p="${p%%/*}"
        allowed[$p]=1
    done < <(fw_rule_specs)
    local -a cutoff=()
    local port svcname entry list=""
    while read -r port svcname; do
        [[ -n "$port" ]] || continue
        [[ -n "${allowed[$port]:-}" ]] && continue
        cutoff+=("$port/$svcname")
    done < <(fw_listener_lines)
    if [[ ${#cutoff[@]} -gt 0 ]]; then
        for entry in "${cutoff[@]}"; do
            list+="  ${entry%%/*}  (${entry#*/})\n"
        done
        local warn_text yn2=0
        warn_text="Default-deny incoming would cut off these services:
$list
Allow them through UFW now? (one-shot; removed rules stay removed)"
        ui_yesno "Services affected by default-deny" "$warn_text" "yes" || yn2=$?
        case $yn2 in
            2) return 2 ;;
            1) log_note "listeners NOT auto-allowed — they will be cut off by default-deny" ;;
            0) for entry in "${cutoff[@]}"; do FW_ALLOW_EXTRA+=("${entry%%/*}"); done
               log_note "queued allow: ${FW_ALLOW_EXTRA[*]} (inbound listener pre-flight)" ;;
        esac
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────
# Plan display
# ─────────────────────────────────────────────────────────────

plan_display() {
    local user_note="reuse existing"
    if ! getent passwd "$TARGET_USER" >/dev/null 2>&1; then
        user_note="CREATE (absent)"
    fi
    local pass_note="leave untouched"
    if [[ -n "$SET_PASSWORD" ]]; then
        pass_note="set via chpasswd (stdin, never argv/logged)"
    elif ! getent passwd "$TARGET_USER" >/dev/null 2>&1; then
        pass_note="LOCKED (key-only) + explicit console-lockout warning"
    fi
    local sudo_note="no"
    [[ "$GRANT_SUDO" == yes ]] && sudo_note="yes (docker group independent)"
    local key_note="ADD new key"
    if [[ "$KEEP_KEYS" == true ]]; then
        key_note="KEEP existing key(s) — no key changes"
    elif [[ ${#REMOVE_KEYS[@]} -gt 0 ]]; then
        key_note="ADD new key + REMOVE ${#REMOVE_KEYS[@]} explicit"
    elif [[ -n "$USER_PUBLIC_KEY" ]]; then
        key_note="ADD: ${USER_PUBLIC_KEY:0:40}..."
    fi
    local mod_flags=""
    mod_flags="fail2ban=$([[ "$ENABLE_FAIL2BAN" == true ]] && printf 'ON' || printf OFF) maintenance=$([[ "$ENABLE_MAINTENANCE" == true ]] && printf 'ON' || printf OFF) docker=$([[ "$ENABLE_DOCKER" == true ]] && printf 'ON' || printf OFF)"
    local mod_note=""
    if is_container; then
        mod_note="
[!] container detected ($ENV_CLASS): UFW and fail2ban will be ATTEMPTED and
    fail soft (rollback + skip recorded in $STATE_FILE) if the container
    lacks the capability. A container firewall protects the container,
    not the host — the PVE/datacenter boundary is the real firewall."
    fi
    local docker_note=""
    if [[ "$ENABLE_DOCKER" == true ]]; then
        docker_note="
    Docker user : $DOCKER_USER (added to the docker group)"
        if is_container; then
            docker_note="$docker_note
    [!] Docker in LXC requires 'features: nesting=1' (+ keyctl=1 if unprivileged)
        in the pct config — set on the PVE host; crusty cannot fix it."
        fi
    fi

    # Firewall pre-flight summary (round-4, item 6)
    local fw_note="UFW will be enabled (stack: $FW_STACK)"
    if [[ "$UFW_SKIPPED" == true ]]; then
        fw_note="UFW SKIPPED"
        if [[ "$FW_STACK" != "none" && "$FW_STACK" != "ufw" ]]; then
            fw_note="UFW SKIPPED — existing $FW_STACK stack kept (no layering)"
        fi
    elif [[ "$FW_OPERATOR_ACK" == true ]]; then
        fw_note="UFW layered ON TOP of existing $FW_STACK (operator acknowledged)"
    fi
    local fw_actions=""
    if [[ ${#FW_REMOVE_RULES[@]} -gt 0 ]]; then
        fw_actions+="\n    REMOVE pre-existing: ${FW_REMOVE_RULES[*]} (explicit)"
    fi
    if [[ ${#FW_ALLOW_EXTRA[@]} -gt 0 ]]; then
        fw_actions+="\n    ALLOW listeners: ${FW_ALLOW_EXTRA[*]} (pre-flight one-shot)"
    fi
    if (( FW_RULES_SEEN > 0 )) && [[ "$UFW_SKIPPED" != true ]]; then
        fw_actions+="\n    Existing UFW rules ($FW_RULES_SEEN) PRESERVED — never reset (M6)"
        [[ "$FW_REVIEWED" == true ]] && fw_actions+=" (reviewed by operator)"
    fi

    cat << EOF

================ crusty PLAN ================
Environment      : $ENV_CLASS (Debian/Ubuntu)
Admin user       : $TARGET_USER ($user_note)
Password         : $pass_note
Sudo group       : $sudo_note
SSH key action   : $key_note
SSH public key   : ${USER_PUBLIC_KEY:0:40}...
SSH port         : ${CURRENT_SSH_PORTS[*]} -> $SSH_PORT
TCP forwarding   : $ALLOW_TCP_FORWARDING (flag-only)
MODULES          : $mod_flags
Fail2ban         : $([[ "$ENABLE_FAIL2BAN" == true ]] && printf yes || printf no) (backend=systemd, reload-only)
Maintenance cron  : $([[ "$ENABLE_MAINTENANCE" == true ]] && printf 'weekly Sunday %s (local, never downloads)' "${MAINT_HOUR}:${MAINT_MINUTE}" || printf no)
Docker           : $([[ "$ENABLE_DOCKER" == true ]] && printf yes || printf no)$docker_note$mod_note
Firewall         : $fw_note$fw_actions

Artifacts crusty will own:
  - /etc/ssh/sshd_config (hardened; drop-ins neutralized, H4)
  - /home/$TARGET_USER/.ssh/authorized_keys (0600, atomic dedup append)
  - $(getent passwd "$TARGET_USER" >/dev/null 2>&1 && printf 'existing user kept' || printf '/home/%s + passwd entry (only if created by crusty)' "$TARGET_USER")
  - $STATE_FILE (0644, no secrets)
  - backups under ${BACKUP_ROOT}<timestamp>/
  - nothing in any user dotfiles (zero login-cosmetics footprint)
============================================
EOF
}

confirm_plan() {
    if [[ "$ASSUME_YES" == true ]]; then
        log_note "--yes: skipping the final confirmation"
        return 0
    fi
    if [[ "$HAVE_TTY" != true ]]; then
        die "no console for the final confirmation — headless runs need --yes"
    fi
    local rc=0
    ui_yesno "Confirm" "Apply this plan now?
A FINAL WARNING: this restarts sshd (existing sessions survive) and
disables password authentication. Keep this session open until you have
tested the new connection." "no" || rc=$?
    case $rc in
        2) log_note "quit requested at the final confirmation — nothing was changed"; exit 0 ;;
        1) die "cancelled at the final confirmation — nothing was changed" ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────
# HEAL — remove V1 relics (idempotent; runs before the new cron write,
# so no duplicate cron sources can ever exist — invariant I7)
# ─────────────────────────────────────────────────────────────

heal_v1_relics() {
    set_step "healing V1 relics"
    local f
    for f in /etc/cron.d/crusty-auto-update /etc/cron.d/crusty-self-update /etc/cron.d/crusty-docker-prune; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            CHANGES=$((CHANGES + 1))
            log_note "healed: removed legacy cron $f"
        fi
    done
    if [[ -d /opt/crusty-system ]]; then
        rm -rf /opt/crusty-system
        CHANGES=$((CHANGES + 1))
        log_note "healed: removed legacy /opt/crusty-system"
    fi
    for f in /var/log/ssh-hardener.log /var/log/docker-setup.log; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            CHANGES=$((CHANGES + 1))
            log_note "healed: removed legacy log $f"
        fi
    done
    # V1 wrote unattended-upgrades machinery — V2's single weekly cron
    # replaces it. Only remove files that match the V1 signature (compact
    # generated content), never the distro's own stock files.
    if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]] \
       && grep -q 'Unattended-Upgrade::AutoFixInterruptedDpkg "true"' /etc/apt/apt.conf.d/50unattended-upgrades \
       && [[ $(stat -c %s /etc/apt/apt.conf.d/50unattended-upgrades) -lt 600 ]]; then
        rm -f /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/20auto-upgrades
        CHANGES=$((CHANGES + 1))
        log_note "healed: removed V1-generated unattended-upgrades config (weekly cron is the single update mechanism)"
    fi
}

# ─────────────────────────────────────────────────────────────
# Apply: packages
# ─────────────────────────────────────────────────────────────

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# §7.5: guard for ANY unattended apt call crusty makes (headless flag-mode
# qualifies) — never prompt, never open a conffile merge editor.
apt_guard() {
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

apt_install() {
    apt_guard install -y -qq "$@"
}

install_packages() {
    set_step "installing required packages"
    if ! apt_guard update -qq; then
        die "apt-get update failed — check network/DNS"
    fi
    if ! command -v sshd &>/dev/null && ! pkg_installed openssh-server; then
        apt_install openssh-server
        systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
        CHANGES=$((CHANGES + 1))
        log "installed openssh-server"
    else
        log "[ok] openssh-server present"
    fi
    if ! pkg_installed ufw; then
        if apt_install ufw; then
            CHANGES=$((CHANGES + 1))
            log "installed ufw"
        else
            UFW_SKIPPED=true
            log_warn "could not install ufw — module will be skipped (soft-fail)"
        fi
    else
        log "[ok] ufw present"
    fi
    if [[ "$ENABLE_FAIL2BAN" == true ]] && ! pkg_installed fail2ban; then
        if apt_install fail2ban; then
            CHANGES=$((CHANGES + 1))
            log "installed fail2ban"
        else
            F2B_SKIPPED=true
            log_warn "could not install fail2ban — module will be skipped (soft-fail)"
        fi
    elif [[ "$ENABLE_FAIL2BAN" == true ]]; then
        log "[ok] fail2ban present"
    fi
    if [[ "$ENABLE_MAINTENANCE" == true ]] && ! pkg_installed cron; then
        apt_install cron
        systemctl enable --now cron >/dev/null 2>&1 || true
        CHANGES=$((CHANGES + 1))
        log "installed cron"
    fi
    if [[ "$ENABLE_DOCKER" == true ]]; then
        pkg_installed jq || apt_install jq || log_warn "jq missing — daemon.json merge will use the backup+overwrite fallback (M3)"
    fi
}

# ─────────────────────────────────────────────────────────────
# Apply: admin user / password / sudo (amendment Part 2)
# ─────────────────────────────────────────────────────────────

setup_admin_user() {
    set_step "admin user"
    if getent passwd "$TARGET_USER" >/dev/null 2>&1; then
        # Existing user. Ownership stays sticky across re-runs: if a prior
        # run recorded that CRUSTY created this user AND the uid still
        # matches, it remains ours (amendment Part 2 — state records what
        # we did; getent is what is true now).
        CRUSTY_CREATED_USER=0
        if [[ "${OLD_CREATED_USER:-}" == 1 ]]; then
            if [[ -z "${OLD_USER_UID:-}" || "$(id -u "$TARGET_USER")" == "$OLD_USER_UID" ]]; then
                CRUSTY_CREATED_USER=1
            fi
        fi
        log "[ok] existing user '$TARGET_USER' — reusing (password NOT touched unless you set one; created-by-crusty: $CRUSTY_CREATED_USER)"
    else
        useradd -m -s /bin/bash "$TARGET_USER"
        CRUSTY_CREATED_USER=1
        CHANGES=$((CHANGES + 1))
        log "created admin user '$TARGET_USER'"
    fi
    CRUSTY_USER_UID="$(id -u "$TARGET_USER")"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        # M5 sibling guard: never write keys to an unknown location
        die "Cannot resolve a home directory for '$TARGET_USER' (got: '${TARGET_HOME:-empty}') — refusing to continue"
    fi

    if [[ -n "$SET_PASSWORD" ]]; then
        # Password via chpasswd STDIN ONLY — never argv (ps/history), never logged
        printf '%s:%s\n' "$TARGET_USER" "$SET_PASSWORD" | chpasswd
        SET_PASSWORD=""
        CHANGES=$((CHANGES + 1))
        log "password set for '$TARGET_USER' (via chpasswd stdin)"
    fi

    if [[ "$GRANT_SUDO" == yes ]]; then
        if ! getent group sudo >/dev/null 2>&1; then
            log_warn "no 'sudo' group on this system — skipping sudo grant (configure sudoers manually)"
        elif id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx sudo; then
            # already a member — sticky: stays "added by crusty" if we added it
            if [[ "${OLD_SUDO_ADDED:-}" == 1 ]]; then
                SUDO_ADDED=1
            else
                SUDO_ADDED=0
            fi
            log "[ok] '$TARGET_USER' already in the sudo group"
        else
            usermod -aG sudo "$TARGET_USER"
            SUDO_ADDED=1
            CHANGES=$((CHANGES + 1))
            log "'$TARGET_USER' added to the sudo group"
        fi
    fi

    # C1 companion warning: after this run root login is SSH-disabled —
    # make sure the admin can actually administer the box (warn only).
    if [[ "$GRANT_SUDO" != yes ]] \
       && ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx -e sudo -e wheel \
       && ! grep -rqs "$TARGET_USER" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        log_warn "'$TARGET_USER' has no sudo access — after this run, remote administration may be impossible."
        log_warn "Verify admin access (PVE console / console) before proceeding."
    fi
}

# ─────────────────────────────────────────────────────────────
# Apply: authorized_keys (RP0 — before ANY auth restriction)
# ─────────────────────────────────────────────────────────────

setup_authorized_keys() {
    set_step "authorized_keys (C1/M5/M7)"
    local user_home="$TARGET_HOME"
    local ssh_dir="$user_home/.ssh"
    local auth_keys_file="$ssh_dir/authorized_keys"
    local key_line="$USER_PUBLIC_KEY"

    # KEEP path (re-run, module flips only): nothing about keys changed —
    # authorized_keys is NOT touched, so a keep-key re-run applies zero
    # changes (idempotency invariant, round-3 requirement).
    if [[ "$KEEP_KEYS" == true && -z "$key_line" && ${#REMOVE_KEYS[@]} -eq 0 ]]; then
        log "[ok] keys left exactly as-is (keep path) — authorized_keys untouched"
        SSH_KEY_FP="$(printf '%s\n' "${EXISTING_KEYS[0]:-}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
        return 0
    fi

    # LOCKOUT-SAFETY pre-checks (do them BEFORE any write):
    # 1. If the ONLY change queued is a removal, never let it empty the file.
    # 2. If we add a key AND remove some, the final set must be non-empty.
    local remaining=0
    if [[ -n "$key_line" ]]; then remaining=$((remaining + 1)); fi
    remaining=$((remaining + ${#EXISTING_KEYS[@]} - ${#REMOVE_KEYS[@]}))
    if (( remaining <= 0 )); then
        die "REFUSING: this run would leave ZERO keys for '$TARGET_USER' (password auth is disabled — lockout by construction). Add a key or keep the existing ones."
    fi
    if [[ -z "$key_line" && ${#REMOVE_KEYS[@]} -eq 0 ]]; then
        # KEEP path with no key action but REMOVE_KEYS empty — already handled above.
        :
    fi

    log "updating public keys for '$TARGET_USER' in $auth_keys_file"

    # M5: warn about group/world-writable home — sshd StrictModes REFUSES
    # keys from such homes ("Authentication refused: bad ownership")
    local home_mode
    home_mode=$(stat -c '%a' "$user_home" 2>/dev/null || echo 0)
    if (( (8#$home_mode & 8#022) != 0 )); then
        log_warn "Home directory $user_home is group/world-writable (mode $home_mode)"
        log_warn "sshd StrictModes will REFUSE key auth from this home directory."
        log_warn "Fix it: chmod go-w $user_home"
    fi

    # LOW-4: refuse symlink traversal — cp/chown -R/chmod below would
    # follow a symlinked .ssh or authorized_keys and mutate its target.
    if [[ -L "$ssh_dir" ]]; then
        die "$ssh_dir is a symlink — refusing to install keys through it"
    fi
    if [[ -L "$auth_keys_file" ]]; then
        die "$auth_keys_file is a symlink — refusing (chown/chmod would follow it)"
    fi

    # INFO: umask 077 around the temp write — no 0644 window on the
    # in-progress authorized_keys copy.
    local saved_umask
    saved_umask="$(umask)"
    umask 077
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # M7: atomic, dedup-safe update — temp file in the same dir, then mv.
    local tmp="$auth_keys_file.tmp.$$"
    if [[ -f "$auth_keys_file" ]]; then
        cp "$auth_keys_file" "$tmp"
    fi

    local changed=false k
    # 1) Explicit removals first (operator-selected, shown in the plan).
    if [[ ${#REMOVE_KEYS[@]} -gt 0 ]]; then
        for k in "${REMOVE_KEYS[@]}"; do
            if awk -v k="$k" '{ gsub(/[[:space:]]+$/, ""); if ($0 == k) found=1 } END { exit found ? 0 : 1 }' "$tmp" 2>/dev/null; then
                # delete only the EXACT matching line(s) — nothing else moves
                awk -v k="$k" '{ line=$0; gsub(/[[:space:]]+$/, "", line); if (line != k) print }' "$tmp" > "$tmp.new" && mv -f "$tmp.new" "$tmp"
                changed=true
                log "removed explicit key ${k:0:50}... from authorized_keys"
            else
                log_note "removal requested for a key that is not in authorized_keys — nothing to do: ${k:0:50}..."
            fi
        done
        # NOTE: no CHANGES bump here — the single write at the bottom counts
        # the whole operation once (removals+additions land in one mv).
    fi

    # 2) Addition (dedup-safe append) when a key was declared.
    if [[ -n "$key_line" ]]; then
        if [[ -f "$tmp" ]] && awk -v k="$key_line" '{ gsub(/[[:space:]]+$/, ""); if ($0 == k) found=1 } END { exit found ? 0 : 1 }' "$tmp" 2>/dev/null; then
            log "[ok] public key already present — skipping (I2)"
        else
            printf '%s\n' "$key_line" >> "$tmp"
            changed=true
            log "public key appended to authorized_keys (atomic)"
        fi
    fi

    if [[ "$changed" == true ]]; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$auth_keys_file"
        CHANGES=$((CHANGES + 1))
    else
        rm -f "$tmp"
        log "[ok] authorized_keys already converged — zero writes"
    fi
    chown -R "$TARGET_USER:" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys_file"
    umask "$saved_umask"

    # C1: verify the key actually landed BEFORE any auth restriction is applied.
    # A keep-path run has nothing to verify (keys untouched by definition).
    SSH_KEY_FP=""
    if [[ -n "$key_line" ]]; then
        if ! grep -qF "$key_line" "$auth_keys_file"; then
            die "Key verification FAILED — aborting before disabling root/password login."
        fi
        SSH_KEY_FP="$(printf '%s\n' "$key_line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
        log "[ok] verified: key present in $auth_keys_file for $TARGET_USER"
    elif [[ ${#REMOVE_KEYS[@]} -gt 0 ]]; then
        # removals only: verify the file is non-empty and valid
        collect_existing_keys "$TARGET_USER"
        if [[ ${#EXISTING_KEYS[@]} -eq 0 ]]; then
            die "Key verification FAILED after removals — no keys remain for '$TARGET_USER'; aborting before disabling password login."
        fi
        log "[ok] verified: ${#EXISTING_KEYS[@]} key(s) remain in $auth_keys_file for $TARGET_USER"
    fi
}

# ─────────────────────────────────────────────────────────────
# Apply: sshd (C2/C3/H4/H5 + invariant I3)
# ─────────────────────────────────────────────────────────────

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
    log_note "sshd currently listens on port(s): ${CURRENT_SSH_PORTS[*]}"
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
    if (( moved > 0 )); then
        log_warn "NOTE: cloud-init may recreate drop-ins on boot. Re-run crusty"
        log_warn "after a reboot, or disable cloud-init's ssh config module in /etc/cloud/cloud.cfg.d/"
    fi
    return "$moved"
}

# H5: OpenSSH 8.7+ uses KbdInteractiveAuthentication; the old
# ChallengeResponseAuthentication name is a deprecated no-op alias on 9.8+.
# Probe which one this sshd understands instead of hardcoding either.
kbdinteractive_supported() {
    local probe ok=false
    probe=$(mktemp)
    printf 'KbdInteractiveAuthentication no\n' > "$probe"
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
    # LOW-3: a missing ss/netstat must NEVER soft-pass — a verification
    # that silently succeeds with no check is a lockout risk (C2). Try to
    # obtain iproute2 first; if that fails, report verification failure.
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        log_warn "Neither ss nor netstat available — attempting to install iproute2"
        apt_install iproute2 2>/dev/null || true
    fi
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        log_warn "No socket-listing tool available — listener verification FAILED (not a pass)"
        return 1
    fi
    local tries=15 i
    for ((i = 1; i <= tries; i++)); do
        if command -v ss &>/dev/null; then
            if ss -tln 2>/dev/null | grep -q ":${port}[[:space:]]"; then
                return 0
            fi
        else
            if netstat -tln 2>/dev/null | grep -q ":${port}[[:space:]]"; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# C3: before sshd moves to the new port, make sure the OLD port stays
# reachable through UFW during the transition (only when UFW is active).
maybe_allow_old_ssh_ports() {
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
            CHANGES=$((CHANGES + 1))
            log "Removed temporary UFW rule for old SSH port $p/tcp"
        else
            log_warn "Could not remove temporary UFW rule for $p/tcp — remove manually: ufw delete allow $p/tcp"
        fi
    done
    UFW_TEMP_PORTS=()
}

apply_sshd() {
    set_step "sshd hardening (C2: pre-flight + atomic + rollback)"
    local candidate kbd_line

    # H5: pick the keyboard-interactive directive this OpenSSH supports
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
    candidate=$(mktemp /tmp/crusty-sshd-config.XXXXXX)
    cat > "$candidate" << EOF
# SSH Hardened Configuration - Generated by crusty $CRUSTY_VERSION
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

# Forwarding (flag-only in V2; default no)
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
        rm -f "$candidate"
        die "Candidate sshd_config FAILED 'sshd -t' pre-flight — live config untouched. Fix the error above."
    fi

    # I3: hash-compare against the active config — skip everything when
    # content is identical, so a re-run does ZERO writes.
    local old_hash new_hash
    # `|| true`: missing live config (stripped image) = empty hash -> need_write,
    # not an errexit abort.
    old_hash=$(md5sum /etc/ssh/sshd_config 2>/dev/null | cut -d' ' -f1 || true)
    new_hash=$(md5sum "$candidate" | cut -d' ' -f1)
    local need_write=false
    [[ "$old_hash" != "$new_hash" ]] && need_write=true
    # H4: drop-ins that appeared since the last run (cloud-init) must be
    # neutralized even when the main config is unchanged
    if [[ -d /etc/ssh/sshd_config.d ]] && ls /etc/ssh/sshd_config.d/*.conf &>/dev/null; then
        need_write=true
    fi

    if [[ "$need_write" == false ]]; then
        rm -f "$candidate"
        log "[ok] sshd_config already converged — zero writes (I3)"
        return 0
    fi

    BACKUP_DIR="${BACKUP_ROOT}$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup"
    if [[ -f "$JAIL_LOCAL" ]]; then
        cp "$JAIL_LOCAL" "$BACKUP_DIR/jail.local" 2>/dev/null || true
    fi
    log "backed up sshd_config to $BACKUP_DIR/sshd_config.backup"

    # H4: neutralize drop-ins that could override our hardening
    handle_sshd_dropins || true

    # C2: atomic replace + restart, with hard rollback on failure
    chmod 600 "$candidate"
    chown root:root "$candidate"
    mv -f "$candidate" /etc/ssh/sshd_config
    CHANGES=$((CHANGES + 1))

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
    log "[ok] SSH configuration applied and verified on port $SSH_PORT"
}

# ─────────────────────────────────────────────────────────────
# Apply: UFW (M6/C3 + apply-time soft-fail, amendment 3-B)
# ─────────────────────────────────────────────────────────────

configure_firewall() {
    if [[ "$UFW_SKIPPED" == true ]]; then
        log_warn "[!] UFW skipped: package unavailable"
        return 0
    fi
    set_step "UFW firewall (M6: no reset; C3: listener verified before enable)"
    command -v ufw &>/dev/null || { UFW_SKIPPED=true; log_warn "[!] UFW not available — skipped"; return 0; }

    log "configuring UFW (existing rules are preserved — NO reset)"
    local ufw_was_active=false
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw_was_active=true
    fi

    # Round-4, item 6(b): operator-queued removals of pre-existing rules.
    # Explicit only, shown in the plan; spec-based delete survives renumbering.
    local rem
    for rem in "${FW_REMOVE_RULES[@]:-}"; do
        [[ -n "$rem" ]] || continue
        if ufw status 2>/dev/null | awk -v r="${rem##* }" '$1==r || $1==r"(v6)"' | grep -q .; then
            if ufw --force delete "$rem" >/dev/null 2>&1; then
                CHANGES=$((CHANGES + 1))
                log "removed pre-existing rule (explicit): $rem"
            else
                log_note "ufw delete $rem returned an error — rule left as-is"
            fi
        else
            log_note "rule to remove is not present — nothing to do (I4): $rem"
        fi
    done

    # M6: no 'ufw --force reset' — never destroy the operator's existing rules.
    # Idempotently make sure the new SSH port is allowed.
    if ! ufw status | awk -v rule="$SSH_PORT/tcp" '$1 == rule' | grep -q .; then
        ufw allow "$SSH_PORT"/tcp comment 'crusty-ssh-port' >/dev/null
        CHANGES=$((CHANGES + 1))
        log "allowed $SSH_PORT/tcp"
    else
        log "[ok] $SSH_PORT/tcp already allowed (I4)"
    fi

    # Round-4, item 6(c): one-shot allow for inbound listeners the operator
    # chose to keep open before default-deny lands (the :8080 incident fix).
    local extra
    for extra in "${FW_ALLOW_EXTRA[@]:-}"; do
        [[ -n "$extra" ]] || continue
        if ufw status | awk -v rule="$extra/tcp" '$1 == rule' | grep -q .; then
            log "[ok] $extra/tcp already allowed (I4)"
        else
            ufw allow "$extra"/tcp comment 'crusty-listener' >/dev/null
            CHANGES=$((CHANGES + 1))
            log "allowed $extra/tcp (inbound listener pre-flight)"
        fi
    done

    if [[ "$ufw_was_active" == false ]]; then
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
    else
        log_note "UFW already active — keeping existing policy and rules untouched"
    fi
    ufw logging on >/dev/null 2>&1 || true

    if ! ufw --force enable >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep -q "Status: active"; then
        # Apply-time soft-fail (amendment 3-B): roll back exactly what we
        # did, warn, record the skip — never fatal for the overall install.
        if [[ "$ufw_was_active" == false ]]; then
            ufw disable >/dev/null 2>&1 || true
        fi
        UFW_SKIPPED=true
        log_warn "[!] UFW failed to become active in this environment ($ENV_CLASS)"
        log_warn "[!] rolled back; 'UFW=skipped' will be recorded in $STATE_FILE"
        log_warn "[!] a container firewall protects the container, not the host —"
        log_warn "[!] the PVE/datacenter boundary is the real firewall."
        return 0
    fi

    # C3: transition complete — drop the temporary old-port rules
    remove_temp_ufw_rules
    log "[ok] UFW active — SSH allowed on port $SSH_PORT (existing rules preserved)"
}

# ─────────────────────────────────────────────────────────────
# Apply: fail2ban (G6/H1 + apply-time soft-fail)
# ─────────────────────────────────────────────────────────────

# Soft-fail rollback for the jail: restore the pre-crusty backup when one
# exists, otherwise remove the file crusty just wrote (a soft-failed run
# must not leave a crusty jail.local behind on a box that never had one).
f2b_rollback_jail() {
    if [[ -f "${JAIL_LOCAL}.pre-crusty.bak" ]]; then
        mv -f "${JAIL_LOCAL}.pre-crusty.bak" "$JAIL_LOCAL"
    else
        rm -f "$JAIL_LOCAL"
    fi
}

configure_fail2ban() {
    if [[ "$ENABLE_FAIL2BAN" != true ]]; then
        log "skipping fail2ban (not selected)"
        return 0
    fi
    if [[ "$F2B_SKIPPED" == true ]]; then
        log_warn "[!] fail2ban skipped: package unavailable"
        return 0
    fi
    set_step "fail2ban (G6: systemd backend; H1: reload, never restart)"
    command -v fail2ban-client &>/dev/null || { F2B_SKIPPED=true; log_warn "[!] fail2ban not available — skipped"; return 0; }

    local old_hash=""
    [[ -f "$JAIL_LOCAL" ]] && old_hash=$(md5sum "$JAIL_LOCAL" | cut -d' ' -f1)
    if [[ -f "$JAIL_LOCAL" ]] && [[ ! -f "${JAIL_LOCAL}.pre-crusty.bak" ]]; then
        cp "$JAIL_LOCAL" "${JAIL_LOCAL}.pre-crusty.bak"   # restore point for soft-fail
    fi

    # G6: `backend = systemd` — no logpath. rsyslog-independent; works on
    # fresh Debian 12 / Ubuntu 24.04 where /var/log/auth.log does not exist.
    cat > "$JAIL_LOCAL" << EOF
# crusty-system — managed by crusty. Full rewrite each run (converge).
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

# Backend: systemd journal (G6) — no logpath, no rsyslog dependency
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
maxretry = 3
bantime = 3600
findtime = 600
EOF

    local new_hash
    new_hash=$(md5sum "$JAIL_LOCAL" | cut -d' ' -f1)

    systemctl enable fail2ban >/dev/null 2>&1 || {
        f2b_rollback_jail
        F2B_SKIPPED=true
        log_warn "[!] fail2ban could not be enabled in this environment ($ENV_CLASS) — rolled back, skipped"
        return 0
    }

    if [[ "$old_hash" != "$new_hash" ]]; then
        # H1: the config must take effect NOW, not after a reboot.
        # RELOAD only — fail2ban restarts historically severed live SSH
        # sessions (git 395c2d1 / 4df6ab3 / 451bc62); reload is non-disruptive.
        if systemctl is-active --quiet fail2ban; then
            if ! fail2ban-client reload >/dev/null 2>&1; then
                f2b_rollback_jail
                F2B_SKIPPED=true
                log_warn "[!] fail2ban-client reload failed — rolled back, skipped (check: journalctl -u fail2ban)"
                return 0
            fi
            log "fail2ban reloaded (fail2ban-client reload — no restart, no session disruption)"
        else
            if ! systemctl start fail2ban >/dev/null 2>&1; then
                f2b_rollback_jail
                F2B_SKIPPED=true
                log_warn "[!] fail2ban failed to start in this environment ($ENV_CLASS) — rolled back, skipped"
                return 0
            fi
            log "fail2ban started (was inactive)"
        fi
        CHANGES=$((CHANGES + 1))
    else
        log "[ok] jail.local unchanged — no service action (I5)"
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban >/dev/null 2>&1 || true
        fi
    fi
    rm -f "${JAIL_LOCAL}.pre-crusty.bak"

    # H1: verify the sshd jail actually took effect on the new port
    local i
    for ((i = 1; i <= 10; i++)); do
        if fail2ban-client status sshd &>/dev/null; then
            log "[ok] verified: fail2ban sshd jail is active (monitoring port $SSH_PORT)"
            return 0
        fi
        sleep 1
    done
    log_warn "Could not verify fail2ban sshd jail yet — check manually: fail2ban-client status sshd"
}

# ─────────────────────────────────────────────────────────────
# Apply: Docker (official repo + M3 daemon.json merge)
# ─────────────────────────────────────────────────────────────

remove_old_docker() {
    if dpkg -l 2>/dev/null | grep -qE '^ii\s+(docker\.io|docker-compose|docker-compose-v2|docker-doc|podman-docker)\s'; then
        log "removing old/conflicting Docker packages"
        apt_guard remove -y -qq docker.io docker-compose docker-compose-v2 docker-doc podman-docker 2>/dev/null || true
        CHANGES=$((CHANGES + 1))
    fi
}

install_docker_repo() {
    # I6: check-before-apply — install vs upgrade vs skip.
    # NOTE: called in a condition context (`if ! install_docker_repo`),
    # which suppresses errexit inside — every fallible command therefore
    # carries an explicit `|| return 1` so failures actually propagate.
    if command -v docker &>/dev/null && docker --version &>/dev/null; then
        log_note "[ok] Docker already installed: $(docker --version)"
        return 0
    fi
    log "installing Docker Engine from the official repository"
    apt_guard install -y -qq ca-certificates curl >/dev/null || return 1
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    local arch repo_entry
    arch="$(dpkg --print-architecture)"
    repo_entry="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable"
    if ! grep -qF "$repo_entry" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
        printf '%s\n' "$repo_entry" > /etc/apt/sources.list.d/docker.list
    fi
    apt_guard update -qq || return 1
    apt_guard install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    if ! systemctl enable -q --now docker; then
        log_warn "docker service failed to enable/start in this environment ($ENV_CLASS)"
        return 1
    fi
    CHANGES=$((CHANGES + 1))
    log "Docker Engine installed: $(docker --version)"
}

configure_daemon() {
    local desired
    desired=$(cat << 'DAEMON_EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "live-restore": true,
  "userland-proxy": false
}
DAEMON_EOF
)
    if [[ ! -f "$DAEMON_JSON" ]]; then
        log "creating $DAEMON_JSON with security defaults"
        printf '%s\n' "$desired" > "$DAEMON_JSON"
        systemctl restart docker
        CHANGES=$((CHANGES + 1))
        return 0
    fi

    local key missing=false
    for key in "no-new-privileges" "live-restore" "log-driver" "userland-proxy"; do
        if ! grep -q "\"$key\"" "$DAEMON_JSON"; then
            missing=true
            break
        fi
    done
    if [[ "$missing" == false ]]; then
        log_note "[ok] daemon.json already carries the security settings (I6)"
        return 0
    fi

    # M3: MERGE the desired keys into the existing daemon.json instead of
    # overwriting it — operator customizations (registry mirrors, MTU, ...)
    # survive. jq deep-merges with our keys winning only where we set them.
    if command -v jq &>/dev/null; then
        log "merging security settings into existing daemon.json (jq)"
        cp "$DAEMON_JSON" "${DAEMON_JSON}.pre-crusty.bak"
        local desired_tmp merge_tmp
        desired_tmp=$(mktemp)
        merge_tmp=$(mktemp)
        printf '%s\n' "$desired" > "$desired_tmp"
        if jq -s '.[0] * .[1]' "$DAEMON_JSON" "$desired_tmp" > "$merge_tmp" && jq empty "$merge_tmp"; then
            mv -f "$merge_tmp" "$DAEMON_JSON"
            rm -f "$desired_tmp"
            CHANGES=$((CHANGES + 1))
            log "daemon.json merged (previous copy: ${DAEMON_JSON}.pre-crusty.bak)"
        else
            rm -f "$desired_tmp" "$merge_tmp"
            log_error "jq merge failed — daemon.json left untouched"
            return 1
        fi
    else
        # No jq: back up first, then overwrite (custom keys are lost but
        # recoverable from the backup)
        log_warn "jq not available — backing up daemon.json and overwriting it"
        log_warn "Custom keys will be lost; restore/merge them from the backup"
        cp "$DAEMON_JSON" "${DAEMON_JSON}.pre-crusty.bak"
        printf '%s\n' "$desired" > "$DAEMON_JSON"
        CHANGES=$((CHANGES + 1))
    fi
    systemctl restart docker
    log "docker daemon configured and restarted"
}

add_docker_group_member() {
    if [[ -z "$DOCKER_USER" ]]; then
        return 0
    fi
    if ! getent passwd "$DOCKER_USER" >/dev/null 2>&1; then
        log_warn "docker user '$DOCKER_USER' does not exist — skipping group add"
        return 0
    fi
    if id -nG "$DOCKER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        # already a member — sticky: stays "added by crusty" if we added it
        if [[ "${OLD_DGROUP_ADDED:-}" == 1 ]]; then
            DOCKER_GROUP_ADDED=1
        else
            DOCKER_GROUP_ADDED=0
        fi
        log_note "[ok] '$DOCKER_USER' already in the docker group"
        return 0
    fi
    usermod -aG docker "$DOCKER_USER" || { log_warn "could not add '$DOCKER_USER' to the docker group"; return 0; }
    DOCKER_GROUP_ADDED=1
    CHANGES=$((CHANGES + 1))
    log "'$DOCKER_USER' added to the docker group (re-login required; docker group is ROOT-EQUIVALENT)"
}

apply_docker() {
    if [[ "$ENABLE_DOCKER" != true ]]; then
        DOCKER_RESULT="disabled"
        return 0
    fi
    set_step "Docker Engine (official repo, M3 daemon merge)"
    if is_container; then
        log_note "[i] Docker in LXC requires 'features: nesting=1' (+ keyctl=1 if unprivileged) in the pct config (set on the PVE host)"
    fi
    remove_old_docker
    # Soft-fail the whole module (same operational rule as UFW/fail2ban):
    # SSH hardening has already succeeded — a module failure after it must
    # never abort the run mid-apply (state file + summary would be lost).
    if ! install_docker_repo; then
        DOCKER_RESULT="failed"
        log_warn "[!] Docker installation failed — module recorded as failed in the state file, install continues"
        return 0
    fi
    if configure_daemon; then
        add_docker_group_member
        DOCKER_RESULT="enabled"
    else
        # Non-fatal by design: sshd hardening has already succeeded; the
        # state file records the failure so a re-run retries the module.
        DOCKER_RESULT="failed"
        log_warn "[!] Docker daemon configuration failed — module recorded as failed, install continues"
    fi
}

# ─────────────────────────────────────────────────────────────
# Apply: weekly maintenance cron (spec §3 — EXACT line, %-free)
# ─────────────────────────────────────────────────────────────────
# GUARD: cron turns the first unescaped % into a newline and truncates the
# command. `date -Is` is used on purpose. The grep below fails the run if
# anyone ever reintroduces a % here.
# ─────────────────────────────────────────────────────────────────────

write_cron() {
    if [[ "$ENABLE_MAINTENANCE" != true ]]; then
        if [[ -f "$CRON_FILE" ]]; then
            rm -f "$CRON_FILE"
            CHANGES=$((CHANGES + 1))
            log_note "maintenance not selected — removed $CRON_FILE"
        fi
        return 0
    fi
    set_step "weekly maintenance cron (I7: converge, %-free)"
    local desired_cron
    desired_cron=$(cat << EOF
# crusty — weekly LOCAL maintenance. Never downloads anything.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$MAINT_MINUTE $MAINT_HOUR * * 0 root flock -n /run/crusty-maintenance.lock /bin/bash -c 'exec >>/var/log/crusty-maintenance.log 2>&1; export DEBIAN_FRONTEND=noninteractive; echo "=== \$(date -Is) crusty maintenance ==="; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" update -qq; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y -qq; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" autoremove --purge -y -qq; apt-get autoclean -qq; if [ -f /var/run/reboot-required ]; then echo "reboot-required — rebooting in 5 min"; shutdown -r +5 "crusty: reboot required"; else echo "no reboot required"; fi'
EOF
)
    if [[ -f "$CRON_FILE" ]] && [[ "$(md5sum "$CRON_FILE" | cut -d' ' -f1)" == "$(printf '%s\n' "$desired_cron" | md5sum | cut -d' ' -f1)" ]]; then
        log "[ok] $CRON_FILE already converged — identical content (I7)"
        return 0
    fi
    printf '%s\n' "$desired_cron" > "$CRON_FILE"
    chmod 0644 "$CRON_FILE"
    if grep -q '%' "$CRON_FILE"; then
        die "cron self-check FAILED: '%' found in $CRON_FILE — the whole maintenance chain would be truncated (man 5 crontab). This is a bug in crusty."
    fi
    CHANGES=$((CHANGES + 1))
    log "[ok] weekly maintenance cron written (Sunday ${MAINT_HOUR}:${MAINT_MINUTE}, flock-serialized, conffile-safe, never downloads)"
}

# ─────────────────────────────────────────────────────────────
# Apply: state file (I8 — rewritten from scratch, never appended;
# 0644, no secrets)
# ─────────────────────────────────────────────────────────────

write_state() {
    set_step "writing state file"
    cat > "$STATE_FILE" << EOF
# crusty-system state — managed file, no secrets. Rewritten each successful run.
CRUSTY_VERSION=$CRUSTY_VERSION
TARGET_USER=$TARGET_USER
CRUSTY_CREATED_USER=$CRUSTY_CREATED_USER
CRUSTY_USER_UID=$CRUSTY_USER_UID
SSH_PORT=$SSH_PORT
SUDO=$GRANT_SUDO
SUDO_ADDED=$SUDO_ADDED
SSH_KEY_FP=${SSH_KEY_FP:-}
FAIL2BAN=$([[ "$ENABLE_FAIL2BAN" == true ]] && { [[ "$F2B_SKIPPED" == true ]] && printf skipped || printf enabled; } || printf disabled)
UFW=$([[ "$UFW_SKIPPED" == true ]] && printf skipped || printf active)
MAINTENANCE=$([[ "$ENABLE_MAINTENANCE" == true ]] && printf enabled || printf disabled)
MAINT_TIME=${MAINT_HOUR}:${MAINT_MINUTE}
DOCKER=$DOCKER_RESULT
DOCKER_USER=$([[ "$ENABLE_DOCKER" == true ]] && printf '%s' "$DOCKER_USER" || printf '')
DOCKER_GROUP_ADDED=$DOCKER_GROUP_ADDED
FW_STACK=$FW_STACK
FW_EXTRA_ALLOW=$(IFS=' '; printf '%s' "${FW_ALLOW_EXTRA[*]}")
FW_ACK=$([[ "$FW_OPERATOR_ACK" == true ]] && printf yes || printf no)
ENV_CLASS=$ENV_CLASS
EOF
    chmod 0644 "$STATE_FILE"
    log "[ok] state written to $STATE_FILE"
}

# ─────────────────────────────────────────────────────────────
# Verify + summary
# ─────────────────────────────────────────────────────────────

get_primary_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || \
        hostname -I 2>/dev/null | awk '{print $1}'
}

verify_and_summarize() {
    set_step "verification"
    PRIMARY_IP="$(get_primary_ip)"

    echo ""
    echo "================ crusty summary ================"
    echo "  Environment      : $ENV_CLASS"
    echo "  Admin user      : $TARGET_USER (created-by-crusty: $CRUSTY_CREATED_USER)"
    local key_action="new key"
    if [[ "$KEEP_KEYS" == true ]]; then
        key_action="existing key(s) kept as-is"
    elif [[ ${#REMOVE_KEYS[@]} -gt 0 ]]; then
        key_action="new key + removed ${#REMOVE_KEYS[@]} explicit key(s)"
    fi
    echo "  SSH keys        : $key_action"
    local port_status="LISTENER NOT FOUND"
    if verify_ssh_listener "$SSH_PORT" >/dev/null 2>&1; then
        port_status="listener verified"
    fi
    echo "  SSH port        : $SSH_PORT ($port_status)"
    echo "  Password auth   : disabled (key-only)"
    echo "  Root login      : disabled"
    echo "  TCP forwarding  : $ALLOW_TCP_FORWARDING"
    if [[ "$UFW_SKIPPED" == true ]]; then
        echo "  UFW             : SKIPPED (rolled back; recorded in state)"
    else
        echo "  UFW             : active (existing rules preserved)"
    fi
    if [[ "$ENABLE_FAIL2BAN" == true ]]; then
        if [[ "$F2B_SKIPPED" == true ]]; then
            echo "  Fail2ban        : SKIPPED (rolled back; recorded in state)"
        else
            echo "  Fail2ban        : enabled (sshd jail, systemd backend, reload-only)"
        fi
    else
        echo "  Fail2ban        : not selected"
    fi
    if [[ "$ENABLE_MAINTENANCE" == true ]]; then
        echo "  Maintenance     : weekly Sunday ${MAINT_HOUR}:${MAINT_MINUTE} (local only, never downloads; log: /var/log/crusty-maintenance.log)"
        echo "  Reboot policy   : only when /var/run/reboot-required exists (+5 min grace)"
    else
        echo "  Maintenance     : not selected"
    fi
    if [[ "$ENABLE_DOCKER" == true ]]; then
        echo "  Docker          : $DOCKER_RESULT"
        [[ -n "$DOCKER_USER" ]] && echo "  Docker user     : $DOCKER_USER"
    fi
    echo "  Changes applied : $CHANGES"
    echo "  Backup dir      : ${BACKUP_DIR:-none needed (already converged)}"
    echo "  Install log     : $INSTALL_LOG"
    echo "=================================================="
    echo ""
    echo "  Connect (test BEFORE closing this session):"
    echo "      ssh -p $SSH_PORT $TARGET_USER@$PRIMARY_IP"
    echo ""
    if [[ "$ENABLE_DOCKER" == true && "$UFW_SKIPPED" != true ]]; then
        log_warn "H2: Docker published ports (-p) BYPASS UFW — 'firewall active' does not close them."
        log_warn "    Publish to loopback (127.0.0.1:8080:80) or filter via the DOCKER-USER chain."
    fi
    if is_container; then
        log_warn "Container caveat: this firewall/fail2ban protects the CONTAINER only — the PVE/datacenter boundary is the real firewall."
    fi
    if [[ -z "$SET_PASSWORD" && "$CRUSTY_CREATED_USER" == 1 ]]; then
        log_warn "The new account '$TARGET_USER' is password-LOCKED (key-only by design)."
        log_warn "If you lose the key, recovery is console-only (PVE console / physical)."
    fi
    log_note "DO NOT close this session until the new connection has been tested."
}

early_connect_banner() {
    # Printed right after the firewall step, before anything that could
    # still disturb the session (fail2ban/docker), so the operator always
    # knows how to connect.
    PRIMARY_IP="$(get_primary_ip)"
    echo ""
    log_note "SSH is now hardened and reachable at: ssh -p $SSH_PORT $TARGET_USER@$PRIMARY_IP"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# --uninstall
# ─────────────────────────────────────────────────────────────

state_get() {
    local key="$1" line
    if [[ -f "$STATE_FILE" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "$key="* ]]; then
                printf '%s' "${line#*=}"
                return 0
            fi
        done < "$STATE_FILE"
    fi
    return 1
}

uninstall_plan() {
    local u_target u_created u_uid u_port u_dgroup u_sudo
    u_target="$(state_get TARGET_USER || printf '')"
    u_created="$(state_get CRUSTY_CREATED_USER || printf 0)"
    u_uid="$(state_get CRUSTY_USER_UID || printf '')"
    u_port="$(state_get SSH_PORT || printf '')"
    u_dgroup="$(state_get DOCKER_GROUP_ADDED || printf 0)"
    u_sudo="$(state_get SUDO_ADDED || printf 0)"

    echo ""
    echo "================ crusty UNINSTALL PLAN ================"
    echo "Will REMOVE (exactly what crusty owns):"
    echo "  - $CRON_FILE (weekly maintenance cron)"
    echo "  - $STATE_FILE (state file)"
    echo "  - $JAIL_LOCAL (only if it carries the crusty marker; backup restored if present)"
    if [[ -n "$u_port" ]]; then
        echo "  - UFW rule 'allow $u_port/tcp' (only if it carries the crusty marker comment) + any temporary crusty-ssh-transition rules"
    fi
    echo "  - sshd_config: restore the OLDEST backup under ${BACKUP_ROOT}* (the pre-crusty original) + restart sshd"
    if [[ "$u_sudo" == 1 && -n "$u_target" ]]; then
        echo "  - remove '$u_target' from the sudo group (crusty added it)"
    fi
    if [[ "$u_dgroup" == 1 && -n "$u_target" ]]; then
        echo "  - remove '$u_target' from the docker group (crusty added it)"
    fi
    if [[ "$u_created" == 1 && -n "$u_target" ]]; then
        echo "  - user '$u_target' + home (created by crusty, uid recorded as $u_uid)"
    else
        echo "  - user/home NOT touched (not created by crusty)"
    fi
    echo "  - V1 relics: /opt/crusty-system, legacy crusty cron files/logs"
    echo "Backups under ${BACKUP_ROOT}* are KEPT (manual delete if desired)."
    if [[ "$u_created" == 0 && -n "$u_target" ]]; then
        echo ""
        echo "NOTE: '$u_target' existed before crusty — it and its home stay."
    fi
    echo "======================================================="
}

do_uninstall() {
    uninstall_plan
    if [[ "$ASSUME_YES" != true ]]; then
        if [[ "$HAVE_TTY" != true ]]; then
            die "--uninstall needs a console for confirmation, or --yes"
        fi
        ui_yesno "Uninstall" "Proceed with the removal plan above?" "no" || die "uninstall cancelled — nothing was changed"
    fi

    set_step "uninstall"

    local u_target u_created u_uid u_port u_dgroup u_sudo
    u_target="$(state_get TARGET_USER || printf '')"
    u_created="$(state_get CRUSTY_CREATED_USER || printf 0)"
    u_uid="$(state_get CRUSTY_USER_UID || printf '')"
    u_port="$(state_get SSH_PORT || printf '')"
    u_dgroup="$(state_get DOCKER_GROUP_ADDED || printf 0)"
    u_sudo="$(state_get SUDO_ADDED || printf 0)"

    # 1. cron + legacy relics
    local f
    for f in "$CRON_FILE" /etc/cron.d/crusty-auto-update /etc/cron.d/crusty-self-update /etc/cron.d/crusty-docker-prune; do
        [[ -f "$f" ]] && rm -f "$f" && log "removed $f"
    done
    [[ -d /opt/crusty-system ]] && rm -rf /opt/crusty-system && log "removed /opt/crusty-system"
    for f in /var/log/ssh-hardener.log /var/log/docker-setup.log; do
        [[ -f "$f" ]] && rm -f "$f" && log "removed legacy log $f"
    done

    # 2. fail2ban jail — only if crusty wrote it
    if [[ -f "$JAIL_LOCAL" ]] && grep -q '# crusty-system — managed by crusty' "$JAIL_LOCAL"; then
        systemctl stop fail2ban >/dev/null 2>&1 || true
        if [[ -f "${JAIL_LOCAL}.pre-crusty.bak" ]]; then
            mv -f "${JAIL_LOCAL}.pre-crusty.bak" "$JAIL_LOCAL"
        else
            rm -f "$JAIL_LOCAL"
        fi
        log "removed crusty jail.local"
    fi

    # 3. UFW rules crusty added — the SSH port rule (only when crusty added
    # it, identified by its 'crusty-ssh-port' marker comment) and any
    # temporary old-port transition rules ('crusty-ssh-transition') left
    # behind by an aborted run (C3). Rules without a crusty marker were
    # there before crusty and are left alone.
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        local crusty_ports p
        crusty_ports=$(ufw status 2>/dev/null | grep -F "crusty-ssh" | awk '{print $1}' | sed 's|/tcp$||' | sort -u || true)
        for p in $crusty_ports; do
            if ufw delete allow "$p/tcp" >/dev/null 2>&1; then
                log "removed crusty-added UFW rule for $p/tcp"
            else
                log_note "no UFW rule for $p/tcp (already gone)"
            fi
        done
    fi

    # 4. restore the OLDEST sshd backup — that is the config as it was
    # before crusty ever ran (with repeated crusty runs, newer backups
    # are themselves crusty-generated configs)
    local oldest
    oldest=$(find /root -maxdepth 1 -type d -name 'crusty-backups-*' 2>/dev/null | sort | head -n 1 || true)
    if [[ -n "$oldest" && -f "$oldest/sshd_config.backup" ]]; then
        cp "$oldest/sshd_config.backup" /etc/ssh/sshd_config
        if sshd -t && restart_sshd; then
            log "sshd_config restored from $oldest (pre-crusty original) and sshd restarted"
        else
            log_warn "sshd restore/restart failed — check /etc/ssh/sshd_config and the console"
        fi
    else
        log_note "no sshd backup found — leaving the current sshd_config in place"
        log_note "(hardening directives remain: review /etc/ssh/sshd_config manually)"
    fi

    # 5. group memberships — only the ones crusty added (state file)
    if [[ -n "$u_target" ]] && getent passwd "$u_target" >/dev/null 2>&1; then
        if [[ "$u_sudo" == 1 ]]; then
            if deluser "$u_target" sudo >/dev/null 2>&1; then
                log "removed '$u_target' from sudo group"
            else
                log_note "'$u_target' no longer in sudo group"
            fi
        fi
        if [[ "$u_dgroup" == 1 ]]; then
            if deluser "$u_target" docker >/dev/null 2>&1; then
                log "removed '$u_target' from docker group"
            else
                log_note "'$u_target' no longer in docker group"
            fi
        fi
    fi

    # 6. user + home — ONLY if crusty created the user AND the uid still matches
    # (guards against someone recreating the same name later; amendment Part 2)
    if [[ "$u_created" == 1 && -n "$u_target" ]]; then
        if getent passwd "$u_target" >/dev/null 2>&1; then
            if [[ -n "$u_uid" && "$(id -u "$u_target")" == "$u_uid" ]]; then
                if userdel -r "$u_target" 2>/dev/null; then
                    log "removed user '$u_target' and its home (created by crusty, uid matched)"
                else
                    userdel "$u_target" >/dev/null 2>&1 || true
                    log_warn "userdel -r failed (running processes?) — user removed without home cleanup or kept; check manually"
                fi
            elif [[ -z "$u_uid" ]]; then
                log_warn "'$u_target' was created by crusty but no uid was recorded — NOT removing (amendment Part 2)"
            else
                log_warn "'$u_target' exists but its uid ($(id -u "$u_target")) != recorded ($u_uid) — NOT removing (recreated by someone else)"
            fi
        else
            log_note "user '$u_target' already gone"
        fi
    else
        log_note "user/home not touched (pre-existing user)"
    fi

    # 7. state file last
    rm -f "$STATE_FILE"
    log "removed $STATE_FILE"
    log_note "uninstall complete. Backups kept under ${BACKUP_ROOT}*"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
# Rigid order (spec §1): parse -> preflight -> ask -> plan+confirm ->
# apply (heal -> packages -> user -> keys -> sshd -> UFW -> fail2ban ->
# docker -> cron -> state) -> verify+summary.
# ─────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    if [[ "$UNINSTALL" == true ]]; then
        ensure_root "$@"
        ui_init
        load_state
        do_uninstall
        exit 0
    fi

    ensure_root "$@"
    ui_init
    detect_os
    detect_environment     # includes the PVE-host hard refusal
    load_state
    detect_current_ssh_ports

    wizard                 # collect EVERYTHING (9 prompts), no mutations yet

    plan_display
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log_note "DRY RUN complete — zero changes were made"
        exit 0
    fi
    confirm_plan

    echo ""
    log "crusty $CRUSTY_VERSION starting apply phase"
    export DEBIAN_FRONTEND=noninteractive

    heal_v1_relics
    install_packages
    setup_admin_user
    setup_authorized_keys   # RP0: key verified BEFORE any restriction
    maybe_allow_old_ssh_ports
    apply_sshd              # RP1: pre-flight + atomic + rollback (C2)
    configure_firewall      # RP2: soft rollback + temp-rule cleanup (C3/M6)
    early_connect_banner
    configure_fail2ban
    apply_docker
    write_cron
    write_state
    verify_and_summarize
}

main "$@"