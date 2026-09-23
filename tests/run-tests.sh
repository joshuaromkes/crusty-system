#!/usr/bin/env bash
# crusty regression tests — the wizard UX fixes (this task):
#   1. wizard quit/cancel semantics (Esc=quit rc2, Cancel=back rc1)
#   2. paste-truncation guard (over-long key paste rejected, not chopped)
#   3. Ctrl+C/SIGINT returns to the shell even while a dialog is up
#   4. key-management keep/add/remove + headless --ssh-key bypass logic
#   5. module-checklist pitfall guard (both default-ON unchecked)
#   6. keep-key re-run = zero changes; per-module delta idempotency
#   7. firewall pre-flight (round-4): stack detection, rule review/remove,
#      inbound-listener allow, no-layering warning, converged re-run reuse
#
# Pure-function tests never need root; the PTY signal test needs `script`
# and `whiptail` (installed in CI; skipped with a note when absent).
# The firewall stack-detection tests shadow the `command` builtin so they
# pass on ANY runner regardless of which firewall tools are installed.
# Run: bash tests/run-tests.sh   (from the repo root)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
EXTRACT="$ROOT/tests/extract.sh"
TMP="$(mktemp -d /tmp/crusty-tests.XXXXXX)"
export INSTALL_LOG="$TMP/install.log"  # extracted log helpers append here
export CRUSTY_INSTALL_LOG="$TMP/install.log"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
ok()   { PASS=$((PASS + 1)); }

section() { echo; echo "== $1 =="; }

# ---- bootstrapping helpers -------------------------------------------------

source_funcs() {  # source pure functions from crusty.sh into THIS shell
    local f
    for f in "$@"; do
        # shellcheck source=crusty.sh
        source <("$EXTRACT" "$f") || return 1
    done
}

# stub log helpers so extracted code that logs works without a real environment
stub_log() {
    _emit()  { :; }
    log()    { :; }
    log_note(){ :; }
    log_warn(){ :; }
    log_error(){ :; }
    set_step() { :; }
}
export -f stub_log 2>/dev/null || true

# Deterministically control `command -v TOOL` for the firewall tests: every
# tool the firewall stack-detection probes is a tri-state env flag —
# FAKE_X=1 faked-present (prints a path, rc 0), FAKE_X=0 faked-absent
# (rc 1, never consults the host), unset = real host lookup. bash allows a
# function to shadow the `command` builtin; `builtin` reaches the real one.
fake_command() {
    command() {
        case "$1" in
            -v) local c="${2:-}" v
                case "$c" in
                    ufw)           v="${FAKE_UFW:-}" ;;
                    firewall-cmd)  v="${FAKE_FIREWALLCMD:-}" ;;
                    systemctl)     v="${FAKE_SYSTEMCTL:-}" ;;
                    nft)           v="${FAKE_NFT:-}" ;;
                    iptables-save) v="${FAKE_IPTABLES:-}" ;;
                    *)             builtin command -v "$c"; return $? ;;
                esac
                case "$v" in
                    1) printf '/usr/bin/%s\n' "$c"; return 0 ;;
                    0) return 1 ;;
                    *) builtin command -v "$c"; return $? ;;
                esac ;;
            *) builtin command "$@" ;;
        esac
    }
}
export -f fake_command 2>/dev/null || true

# Neutral probes for the detection tools a given test is NOT exercising —
# keeps stack detection hermetic on any runner (CI ubuntu images ship
# ufw, nft AND iptables, so an uncontrolled host lookup would leak state).
fw_empty_probes() {
    FAKE_NFT=1;         nft() { :; }
    FAKE_IPTABLES=1;    iptables-save() { :; }
    FAKE_SYSTEMCTL=1;   systemctl() { return 1; }
    FAKE_FIREWALLCMD=1; firewall-cmd() { :; }
}
export -f fw_empty_probes 2>/dev/null || true

# Mirrors the crusty.sh top-level globals so extracted functions run under
# `set -u` without tripping on unset-but-referenced variables.
crusty_globals() {
    CRUSTY_VERSION="test"
    ASSUME_YES=false; DRY_RUN=false; UNINSTALL=false
    HAVE_TTY=true; USE_WHIPTAIL=false; UI_CHILD=""
    UFW_SKIPPED=false; F2B_SKIPPED=false
    FW_STACK=none; FW_OPT_OUT=false; FW_OPT_IN=false
    FW_OPERATOR_ACK=false; FW_REVIEWED=false; FW_RULES_SEEN=0
    FW_ALLOW_EXTRA=(); FW_REMOVE_RULES=()
    OLD_FW_STACK=""; OLD_FW_ACK=""; OLD_FW_EXTRA_ALLOW=""
    OLD_TARGET_USER=""; OLD_SUDO=""; OLD_SSH_PORT=""; OLD_SSH_KEY_FP=""; OLD_MAINT_TIME=""
    STATE_FILE="/etc/crusty.conf"
    CHANGES=0; KEY_MAX_LEN=4096
    CURRENT_SSH_PORTS=(22); SSH_PORT=22
    TARGET_USER=""; SET_PASSWORD=""; GRANT_SUDO=""
    USER_PUBLIC_KEY=""; KEEP_KEYS=false; REMOVE_KEYS=(); EXISTING_KEYS=()
    ENABLE_DOCKER=false; ENABLE_FAIL2BAN=true; ENABLE_MAINTENANCE=true
    DOCKER_USER=""; DOCKER_RESULT=""; DOCKER_GROUP_ADDED=""
    MAINT_HOUR=02; MAINT_MINUTE=00; ALLOW_TCP_FORWARDING=no
    BACKUP_ROOT="/var/backups/"
    ENV_CLASS="debian"; CRUSTY_CREATED_USER=""; CRUSTY_USER_UID=""; SSH_KEY_FP=""
}
export -f crusty_globals 2>/dev/null || true

# ----------------------------------------------------------------------------
section "1. syntax + lint (must stay clean)"
if bash -n crusty.sh; then ok; else fail "bash -n crusty.sh"; fi
if command -v shellcheck >/dev/null; then
    if shellcheck crusty.sh; then ok; else fail "shellcheck crusty.sh"; fi
else
    echo "  (shellcheck not installed — skipping)"
fi
# cron %-free guard (also enforced in CI)
if grep 'root flock' crusty.sh | grep -q '%'; then
    fail "cron %-free guard"
else
    ok
fi

# ----------------------------------------------------------------------------
section "2. wizard quit/cancel semantics (rc 0/1/2)"
# Stub the prompts to return scripted rc values and assert wizard() maps
# them: 0=next, 1=back, 2=quit-exit-0. Each case sources wizard() AFTER the
# stubs so the $steps array resolves to the caller's stubs at call time.
# NOTE: the wizard has NINE steps (prompt_firewall included) — every stub
# set must cover all nine or the missing one loops forever at rc 127.
run_wizard_case() {  # $1 = stub body applied to all nine prompts
    local body="$1"
    (
        stub_log
        prompt_user() { eval "$body"; }
        prompt_password() { eval "$body"; }
        prompt_sudo() { eval "$body"; }
        prompt_ssh_key() { eval "$body"; }
        prompt_port() { eval "$body"; }
        prompt_modules() { eval "$body"; }
        prompt_firewall() { eval "$body"; }
        prompt_docker_user() { eval "$body"; }
        prompt_maint_time() { eval "$body"; }
        source <("$EXTRACT" wizard)
        wizard
    )
}

wizard_stub9() {  # the nine return-0 prompt stubs used by the full-path cases
    prompt_user()    { return 0; }
    prompt_password(){ return 0; }
    prompt_sudo()    { return 0; }
    prompt_ssh_key() { return 0; }
    prompt_port()    { return 0; }
    prompt_modules() { return 0; }
    prompt_firewall(){ return 0; }
    prompt_docker_user() { return 0; }
    prompt_maint_time()  { return 0; }
}
export -f wizard_stub9 2>/dev/null || true

# 2a. Esc/quit on the FIRST prompt -> exit 0, nothing changed
if run_wizard_case "return 2"; then
    ok
else
    fail "Esc on first prompt should exit 0 (got $?)"
fi

# 2b. Cancel on the FIRST prompt -> exit 0
if run_wizard_case "return 1"; then
    ok
else
    fail "Cancel on first prompt should exit 0 (got $?)"
fi

# 2c. user ok, password ok, sudo Esc-quit -> exit 0
if ( stub_log
      wizard_stub9
      prompt_sudo() { return 2; }
      source <("$EXTRACT" wizard)
      wizard
   ); then
    ok
else
    fail "Esc on step 3 should exit 0"
fi

# 2d. all-ok path completes (exit 0)
if ( stub_log
      wizard_stub9
      source <("$EXTRACT" wizard)
      wizard
   ); then
    ok
else
    fail "all-ok wizard should complete with exit 0"
fi

# 2e. back at step 5 returns to step 4 (user+pass+sudo+key called again)
if ( stub_log
      step=0 count_key=0 count_port=0
      wizard_stub9
      prompt_ssh_key() { count_key=$((count_key + 1)); [[ $count_key -eq 1 ]] && return 0; return 0; }
      prompt_port()    { count_port=$((count_port + 1)); [[ $count_port -eq 1 ]] && return 1; return 0; }
      source <("$EXTRACT" wizard)
      wizard
   ); then
    ok
else
    fail "back-step wizard flow"
fi

# 2f. Esc-quit from the FIREWALL step (step 7) must also exit 0
if ( stub_log
      wizard_stub9
      prompt_firewall() { return 2; }
      source <("$EXTRACT" wizard)
      wizard
   ); then
    ok
else
    fail "Esc on the firewall step should exit 0"
fi

# ----------------------------------------------------------------------------
section "3. paste-truncation guard (key validation + overlong rejection)"
stub_log
source_funcs validate_public_key resolve_key_input key_overlong >/dev/null

# build two real keys
KEY_A="$(ssh-keygen -t ed25519 -N '' -C 'test@crusty' -f "$TMP/ka" -q && cat "$TMP/ka.pub")"
KEY_B="$(ssh-keygen -t ed25519 -N '' -C 'test2@crusty' -f "$TMP/kb" -q && cat "$TMP/kb.pub")"
if [[ -z "$KEY_A" || -z "$KEY_B" ]]; then
    fail "could not generate test keys"
else
    ok
fi

# 3a. valid key accepted
validate_public_key "$KEY_A" && ok || fail "valid ed25519 key rejected"

# 3b. truncated base64 (the paste-truncation failure mode) rejected — even
#     a valid-prefix key whose blob is chopped mid-way must FAIL the H10
#     deep check (ssh-keygen -lf), or a truncated paste silently lands.
TRUNC_BLOB=""
TRUNC_BLOB="${KEY_A##* }"
TRUNC="ssh-ed25519 ${TRUNC_BLOB:0:${#TRUNC_BLOB}/2} test@cut"
validate_public_key "$TRUNC" && fail "truncated key accepted (paste-truncation regression!)" || ok

# 3c. CRLF paste: resolve_key_input strips \r\n (paste noise) — the
#     sanitized line must equal the plain key, and the stripped key round-trips.
if [[ "$(resolve_key_input "$(printf '%s\r\n' "$KEY_A")")" == "$KEY_A" ]]; then ok; else fail "resolve_key_input CRLF strip"; fi

# 3d. resolve_key_input: file path reads line 1; paste passes through
if [[ "$(resolve_key_input "$TMP/ka.pub")" == "$KEY_A" ]]; then ok; else fail "resolve_key_input file"; fi
if [[ "$(resolve_key_input "$KEY_B")" == "$KEY_B" ]]; then ok; else fail "resolve_key_input inline"; fi

# 3e. key_overlong: 4096-cap enforcement (the size/validate guard)
KEY_MAX_LEN=4096
BIG=$(printf 'a%.0s' $(seq 1 5000))
SHORT=$(printf 'a%.0s' $(seq 1 500))
key_overlong "$BIG" && ok || fail "5000-char paste not flagged overlong"
key_overlong "$KEY_A" && fail "normal key flagged overlong" || ok
key_overlong "$SHORT" && fail "500-char input flagged overlong" || ok

# ----------------------------------------------------------------------------
section "4. key-management keep/add/remove + headless bypass logic"
# Test the pure decision helpers by extracting user_has_installed_key and
# collect_existing_keys with a FAKE home via a stub getent.
stub_log
source_funcs validate_public_key collect_existing_keys user_has_installed_key >/dev/null

FAKE_HOME="$TMP/home4"
mkdir -p "$FAKE_HOME/.ssh"
printf '%s\n' "$KEY_A" > "$FAKE_HOME/.ssh/authorized_keys"

# stub getent so collect_existing_keys resolves the fake home
_getent() { case "$1" in
    passwd) [[ "$2" == "crustytest" ]] && printf 'crustytest:x:4242:4242::%s:/bin/bash\n' "$FAKE_HOME" ;;
    *) return 1 ;;
esac; }

# 4a. keys are discovered
( source <("$EXTRACT" collect_existing_keys)
  getent() { _getent "$@"; }
  collect_existing_keys crustytest
  [[ ${#EXISTING_KEYS[@]} -eq 1 && "${EXISTING_KEYS[0]}" == "$KEY_A" ]] && exit 0 || exit 1
) && ok || fail "collect_existing_keys"

# 4b. user_has_installed_key true when a valid key is on disk
( source <("$EXTRACT" collect_existing_keys)
  source <("$EXTRACT" user_has_installed_key)
  getent() { _getent "$@"; }
  user_has_installed_key crustytest && exit 0 || exit 1
) && ok || fail "user_has_installed_key true case"

# 4c. ...and false when the file is empty or holds garbage
( source <("$EXTRACT" collect_existing_keys)
  source <("$EXTRACT" user_has_installed_key)
  getent() { _getent "$@"; }
  : > "$FAKE_HOME/.ssh/authorized_keys"
  user_has_installed_key crustytest && exit 1 || exit 0
) && ok || fail "user_has_installed_key empty-file case"

# 4d. setup_authorized_keys KEEP path = ZERO changes (file untouched, no
#     CHANGES bump). Emulate the pre-run state and run the extracted function.
( source <("$EXTRACT" setup_authorized_keys)
  source <("$EXTRACT" collect_existing_keys)
  source <("$EXTRACT" validate_public_key)
  source <("$EXTRACT" die)
  stub_log; command -v ssh-keygen >/dev/null
  TARGET_USER=crustytest
  TARGET_HOME="$FAKE_HOME"
  KEEP_KEYS=true
  USER_PUBLIC_KEY=""
  REMOVE_KEYS=()
  EXISTING_KEYS=("$KEY_A")
  CHANGES=0
  printf '%s\n' "$KEY_A" > "$FAKE_HOME/.ssh/authorized_keys"
  before="$(md5sum "$FAKE_HOME/.ssh/authorized_keys" | cut -d' ' -f1)"
  setup_authorized_keys
  after="$(md5sum "$FAKE_HOME/.ssh/authorized_keys" | cut -d' ' -f1)"
  [[ "$before" == "$after" && "$CHANGES" == 0 ]] && exit 0 || exit 1
) && ok || fail "keep-key re-run must be ZERO changes"

# 4e. setup_authorized_keys ADD path appends (idempotent on second add)
( source <("$EXTRACT" setup_authorized_keys)
  source <("$EXTRACT" collect_existing_keys)
  source <("$EXTRACT" validate_public_key)
  source <("$EXTRACT" die)
  stub_log
  TARGET_USER=crustytest
  TARGET_HOME="$FAKE_HOME"
  KEEP_KEYS=false
  REMOVE_KEYS=()
  EXISTING_KEYS=()
  CHANGES=0
  printf '# empty\n' > "$FAKE_HOME/.ssh/authorized_keys"
  USER_PUBLIC_KEY="$KEY_A"
  setup_authorized_keys
  c1="$CHANGES"
  n1=$(grep -c '^ssh-ed25519' "$FAKE_HOME/.ssh/authorized_keys")
  # re-run: same key — must not duplicate
  USER_PUBLIC_KEY="$KEY_A"
  setup_authorized_keys
  c2="$CHANGES"
  n2=$(grep -c '^ssh-ed25519' "$FAKE_HOME/.ssh/authorized_keys")
  [[ "$n1" == 1 && "$n2" == 1 && "$c1" == 1 && "$c2" == 1 ]] && exit 0 || exit 1
) && ok || fail "add key must be atomic + dedup (idempotent)"

# 4f. setup_authorized_keys REFUSES removing the last key (lockout-safety).
# die() exits its subshell, so capture THAT status, then verify the file
# was left untouched from the OUTER context.
printf '%s\n' "$KEY_A" > "$FAKE_HOME/.ssh/authorized_keys"
( source <("$EXTRACT" setup_authorized_keys)
  source <("$EXTRACT" collect_existing_keys)
  source <("$EXTRACT" validate_public_key)
  source <("$EXTRACT" die)
  stub_log
  TARGET_USER=crustytest
  TARGET_HOME="$FAKE_HOME"
  KEEP_KEYS=false
  REMOVE_KEYS=("$KEY_A")
  EXISTING_KEYS=("$KEY_A")
  USER_PUBLIC_KEY=""
  CHANGES=0
  setup_authorized_keys            # dies -> nonzero subshell status
)
f_rc=$?
if [[ $f_rc -ne 0 && "$(md5sum "$FAKE_HOME/.ssh/authorized_keys" | cut -d' ' -f1)" == "$(printf '%s\n' "$KEY_A" | md5sum | cut -d' ' -f1)" ]]; then
    ok
else
    fail "removing the last key must be refused (lockout)"
fi

# 4g. explicit remove with a replacement key in the same run is allowed
( source <("$EXTRACT" setup_authorized_keys)
  source <("$EXTRACT" collect_existing_keys)
  source <("$EXTRACT" validate_public_key)
  source <("$EXTRACT" die)
  stub_log
  getent() { [[ "$1" == passwd && "$2" == crustytest ]] && printf 'crustytest:x:4242:4242::%s:/bin/bash\n' "$FAKE_HOME"; }
  TARGET_USER=crustytest
  TARGET_HOME="$FAKE_HOME"
  KEEP_KEYS=false
  REMOVE_KEYS=("$KEY_A")
  EXISTING_KEYS=("$KEY_A" "$KEY_B")
  USER_PUBLIC_KEY=""
  CHANGES=0
  printf '%s\n%s\n' "$KEY_A" "$KEY_B" > "$FAKE_HOME/.ssh/authorized_keys"
  setup_authorized_keys
  grep -qF "$KEY_A" "$FAKE_HOME/.ssh/authorized_keys" && exit 1  # must be gone
  grep -qF "$KEY_B" "$FAKE_HOME/.ssh/authorized_keys" || exit 1  # must remain
  [[ "$CHANGES" == 1 ]] || exit 1
  exit 0
) && ok || fail "explicit remove (with remaining key) must work"

# ----------------------------------------------------------------------------
section "5. module-checklist pitfall guard (decision logic)"
# The guard lives in prompt_modules, which needs a TTY; here we test the
# invariant the wizard-level logic relies on: with an EMPTY checklist
# selection string, the code path must re-confirm (returns into the loop),
# i.e. prompt_modules must NOT proceed silently. We emulate by stubbing
# ui_box (returns empty = nothing selected) and ui_yesno (No then Yes).
# NOTE: start from the REAL defaults (fail2ban+maintenance ON, docker OFF,
# no flags) — otherwise prompt_modules sees "any_flag" and returns early
# before the guard can ever fire.
( stub_log
  crusty_globals
  USE_WHIPTAIL=true
  ENABLE_DOCKER=false
  ENABLE_FAIL2BAN=true
  ENABLE_MAINTENANCE=true
  calls=0
  ui_box() { return 0; }                                  # empty selection
  ui_yesno() { calls=$((calls + 1)); return $((calls == 1)); }  # No, then Yes
  source <("$EXTRACT" prompt_modules)
  prompt_modules
  # The warning must have been raised (ui_yesno called >= 1) and, after the
  # operator confirms, modules stay OFF and the step completes (rc 0).
  [[ $calls -ge 1 && "$ENABLE_FAIL2BAN" != true && "$ENABLE_MAINTENANCE" != true ]]
) && ok || fail "empty checklist (no toggles registered) must trigger re-confirm"

# and the proceed path: operator confirms -> modules stay off, returns 0
( stub_log
  crusty_globals
  USE_WHIPTAIL=true
  ENABLE_FAIL2BAN=false
  ENABLE_MAINTENANCE=false
  ENABLE_DOCKER=false
  ui_box() { return 0; }
  ui_yesno() { return 0; }                  # "Yes, proceed disabled"
  source <("$EXTRACT" prompt_modules)
  prompt_modules
) && ok || fail "confirmed-empty checklist should complete with rc 0"

# ----------------------------------------------------------------------------
section "6. Ctrl+C / SIGINT returns to the shell (PTY harness)"
# The regression: while whiptail owns the raw terminal, INT/TERM are
# swallowed by the dialog AND bash defers traps while waiting on a
# foreground child — the old code wedged. The fix backgrounds the dialog
# and kill -TERM/-KILLs it from the signal handler. The harness reproduces
# the exact primitive path (ui_box + sig_handler + traps) in a real PTY.
if [[ -x /usr/bin/script && -n "$(command -v whiptail)" && -n "$(command -v timeout)" ]]; then
    cat > "$TMP/pty_target.sh" <<'EOF'
# shellcheck disable=SC2034
UI_CHILD=""
log_warn() { printf 'LOG %s\n' "$*"; }
source <(bash tests/extract.sh ui_box)
source <(bash tests/extract.sh sig_handler)
trap 'sig_handler INT 130' INT
trap 'sig_handler TERM 143' TERM
# run a real dialog (inputbox) like the wizard's prompt would
ui_box --title Test --inputbox "type something or wait" 10 58 "" --ok-button OK --cancel-button Back
echo "DIALOG_RC=$?"
EOF
    chmod +x "$TMP/pty_target.sh"
    # Run under a PTY via script(1); send SIGTERM to the session; the child
    # script exits 130/143 and DIES BOTH the dialog child AND itself —
    # proving Ctrl+C now returns to the shell (up to 10s hard cap).
    output="$("$TMP/pty_target.sh" 2>&1 & pty_pid=$!; sleep 2; kill -TERM -"$pty_pid" 2>/dev/null || kill -TERM "$pty_pid" 2>/dev/null; wait "$pty_pid"; echo "EXIT=$?")" || true
    # The harness must terminate on its own within the wait; if wait
    # returned without a hang, the signal path worked.
    if echo "$output" | grep -q 'DIALOG_RC=' || echo "$output" | grep -qE 'EXIT=(130|143)'; then
        ok
    else
        # show what happened for debugging
        echo "  (harness output: $output)"
        fail "signal did not terminate the dialog (wedge regression?)"
    fi
else
    echo "  (no script/whiptail/timeout — PTY signal test skipped)"
fi

# ----------------------------------------------------------------------------
section "7. firewall pre-flight (round-4, item 6)"

# ---- 7a. fw_detect_stack branch matrix (via fake `command`) ----------------
stub_log

# 7a-i. no firewall stack installed -> none
( source <("$EXTRACT" fw_detect_stack)
  fake_command
  fw_empty_probes          # nft/iptables/firewalld all present but EMPTY
  FAKE_UFW=0               # ufw explicitly absent (the host may have it!)
  fw_detect_stack
  [[ "$FW_STACK" == none ]]
) && ok || fail "fw_detect_stack: none"

# 7a-ii. ufw installed and ACTIVE -> ufw (wins over nft/iptables checks)
( source <("$EXTRACT" fw_detect_stack)
  fake_command
  fw_empty_probes
  FAKE_UFW=1
  ufw() { printf 'Status: active\n'; }
  fw_detect_stack
  [[ "$FW_STACK" == ufw ]]
) && ok || fail "fw_detect_stack: ufw active"

# 7a-iii. ufw installed but INACTIVE -> inactive-ufw (falls through to the
#         nft/iptables probes, which find nothing on this box)
( source <("$EXTRACT" fw_detect_stack)
  fake_command
  fw_empty_probes
  FAKE_UFW=1
  ufw() { printf 'Status: inactive\n'; }
  fw_detect_stack
  [[ "$FW_STACK" == inactive-ufw ]]
) && ok || fail "fw_detect_stack: inactive ufw"

# 7a-iv. firewalld active -> firewalld (systemd probe)
( source <("$EXTRACT" fw_detect_stack)
  fake_command
  FAKE_UFW=0               # ufw must not short-circuit before firewalld
  FAKE_FIREWALLCMD=1
  FAKE_SYSTEMCTL=1
  systemctl() { case "$*" in *firewalld*) return 0 ;; *) return 1 ;; esac; }
  fw_detect_stack
  [[ "$FW_STACK" == firewalld ]]
) && ok || fail "fw_detect_stack: firewalld active"

# 7a-v. raw nft with a FOREIGN chain -> nft
( source <("$EXTRACT" fw_detect_stack)
  fake_command
  fw_empty_probes
  FAKE_UFW=0
  FAKE_NFT=1
  nft() { printf 'table inet filter {\n  chain INPUT {\n  }\n}\n'; }
  fw_detect_stack
  [[ "$FW_STACK" == nft ]]
) && ok || fail "fw_detect_stack: nft foreign chain"

# 7a-vi. nft with ONLY crusty-owned chains (f2b-/ufw- NAMES) -> noise, none
( source <("$EXTRACT" fw_detect_stack)
  fake_command
  fw_empty_probes
  FAKE_UFW=0
  nft() { printf 'table inet filter {\n  chain f2b-sshd {\n  }\n  chain ufw-user-input {\n  }\n}\n'; }
  fw_detect_stack
  [[ "$FW_STACK" == none ]]
) && ok || fail "fw_detect_stack: nft only own chains (f2b-/ufw-) must be noise"

# 7a-vii. iptables legacy rules -> iptables
( source <("$EXTRACT" fw_detect_stack)
  fake_command
  fw_empty_probes
  FAKE_UFW=0
  iptables-save() { printf '%s\n' '-A INPUT -p tcp --dport 25 -j ACCEPT'; }
  fw_detect_stack
  [[ "$FW_STACK" == iptables ]]
) && ok || fail "fw_detect_stack: iptables foreign rules"

# ---- 7b. fw_rule_specs + fw_count_rules (spec-based, survives renumber) ----
RULES_OUT=$(
    stub_log
    source <("$EXTRACT" fw_rule_specs)
    source <("$EXTRACT" fw_count_rules)
    fake_command
    FAKE_UFW=1
    ufw() { case "$1" in
        show) printf '%s\n' \
            '22/tcp ALLOW IN' \
            '80/tcp DENY IN' \
            '443/tcp ALLOW IN (v6)' \
            '22/tcp ALLOW IN' ;;  # duplicate — sort -u must collapse it
    esac; }
    FW_REMOVE_RULES=()
    echo "SPECS:"; fw_rule_specs
    echo "COUNT:$(fw_count_rules)"
)
if [[ "$(printf '%s' "$RULES_OUT" | grep -c '^allow ')" == 2 \
   && "$(printf '%s' "$RULES_OUT" | grep -c '^deny ')" == 1 \
   && "$(printf '%s' "$RULES_OUT" | grep -c '^allow 22/tcp$')" == 1 \
   && "$(printf '%s' "$RULES_OUT" | grep -c '^COUNT:3$')" == 1 ]]; then ok; else echo "DBG RULES_OUT=[$RULES_OUT]"; fail "fw_rule_specs parse/dedup/count"; fi

# 7b-ii. a rule queued for removal is not re-listed (and the count drops)
RULES_OUT2=$(
    stub_log
    source <("$EXTRACT" fw_rule_specs)
    source <("$EXTRACT" fw_count_rules)
    fake_command
    FAKE_UFW=1
    ufw() { case "$1" in
        show) printf '%s\n' '22/tcp ALLOW IN' '443/tcp ALLOW IN (v6)' ;;
    esac; }
    FW_REMOVE_RULES=("allow 443/tcp")
    echo "COUNT:$(fw_count_rules)"
)
if [[ "$(printf '%s' "$RULES_OUT2" | grep -c '^COUNT:1$')" == 1 && -z "$(printf '%s' "$RULES_OUT2" | grep '443')" ]]; then
    ok
else
    echo "DBG RULES_OUT2=[$RULES_OUT2]"
    fail "fw_rule_specs must exclude rules queued for removal"
fi

# ---- 7c. fw_listener_lines (ss -tlnp parse) --------------------------------
LISTENERS=$(
    stub_log
    source <("$EXTRACT" fw_listener_lines)
    ss() { printf '%s\n' \
        'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
        'LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:(("webui",pid=123,fd=3))' \
        'LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1,fd=4))'; }
    fw_listener_lines
)
if [[ "$(printf '%s' "$LISTENERS" | grep -c '8080 webui')" == 1 \
   && "$(printf '%s' "$LISTENERS" | grep -c '2222 sshd')" == 1 ]]; then
    ok
else
    fail "fw_listener_lines parse (got: $LISTENERS)"
fi

# ---- 7d. prompt_firewall decision logic ------------------------------------
# Shared stub set: fw_detect_stack is fully controlled; rule/listener output
# is empty so the (b) review and (c) listener steps are inert unless the
# test sets them up. ui_yesno is a spy (records how many times it was asked).
pf_setup() {
    stub_log
    crusty_globals
    source <("$EXTRACT" prompt_firewall)
    fake_command
    FAKE_UFW=0               # (b) rule review is inert unless a test sets it up
    fw_detect_stack() { :; }        # FW_STACK set by each test
    fw_rule_specs()   { :; }        # no pre-existing rules
    fw_listener_lines(){ :; }       # no inbound listeners
    ui_yesno() { yesno_calls=$((yesno_calls + 1)); return "${yesno_give:-0}"; }
    ui_msg()   { :; }
    ui_menu()  { printf 'done\n'; }
}
export -f pf_setup 2>/dev/null || true

# 7d-i. --no-firewall: skipped regardless of what stack is live, no prompts
( yesno_calls=0
  pf_setup
  FW_OPT_OUT=true; FW_STACK=ufw; HAVE_TTY=true; ASSUME_YES=false
  prompt_firewall
  [[ "$UFW_SKIPPED" == true && "$yesno_calls" == 0 ]]
) && ok || fail "--no-firewall must skip UFW without asking"

# 7d-ii. foreign stack + headless: refuse to silently layer, skip, no prompts
( yesno_calls=0
  pf_setup
  FW_STACK=firewalld; FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=false; ASSUME_YES=false
  prompt_firewall
  [[ "$UFW_SKIPPED" == true && "$yesno_calls" == 0 ]]
) && ok || fail "foreign stack + headless must skip UFW (no silent layering)"

# 7d-iii. foreign stack + interactive + operator picks NO -> skip, logged
( yesno_calls=0; yesno_give=1
  pf_setup
  FW_STACK=iptables; FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=true; ASSUME_YES=false
  prompt_firewall
  [[ "$UFW_SKIPPED" == true && "$yesno_calls" == 1 ]]
) && ok || fail "foreign stack + interactive No must set UFW_SKIPPED"

# 7d-iv. foreign stack + interactive + operator says YES -> acknowledged
( yesno_calls=0; yesno_give=0
  pf_setup
  FW_STACK=firewalld; FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=true; ASSUME_YES=false
  prompt_firewall
  [[ "$FW_OPERATOR_ACK" == true && "$UFW_SKIPPED" != true ]]
) && ok || fail "foreign stack + interactive Yes must acknowledge layering"

# 7d-v. foreign stack + interactive + Esc/quit -> rc 2 (wizard quits)
( yesno_calls=0; yesno_give=2
  pf_setup
  FW_STACK=nft; FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=true; ASSUME_YES=false
  prompt_firewall; rc=$?
  [[ $rc == 2 && "$yesno_calls" == 1 ]]
) && ok || fail "foreign stack + Esc must return quit rc 2"

# 7d-vi. converged re-run: same stack + acknowledged before -> reuse, no re-ask
( yesno_calls=0
  pf_setup
  FW_STACK=firewalld; OLD_FW_STACK=firewalld; OLD_FW_ACK=yes
  FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=true; ASSUME_YES=false
  prompt_firewall
  [[ "$FW_OPERATOR_ACK" == true && "$yesno_calls" == 0 ]]
) && ok || fail "converged re-run must reuse the previous firewall decision"

# 7d-vii. previous run SKIPPED (FW_ACK=no) + same stack -> stays skipped
( yesno_calls=0
  pf_setup
  FW_STACK=nft; OLD_FW_STACK=nft; OLD_FW_ACK=no
  FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=true; ASSUME_YES=false
  prompt_firewall
  [[ "$UFW_SKIPPED" == true && "$yesno_calls" == 0 ]]
) && ok || fail "previous skip + unchanged stack must stay skipped"

# 7d-viii. --firewall OVERRIDES a previous skip (FW_ACK=no) — operator wants layering
( yesno_calls=0
  pf_setup
  FW_STACK=nft; OLD_FW_STACK=nft; OLD_FW_ACK=no
  FW_OPT_OUT=false; FW_OPT_IN=true
  HAVE_TTY=true; ASSUME_YES=false
  prompt_firewall
  [[ "$FW_OPERATOR_ACK" == true && "$UFW_SKIPPED" != true ]]
) && ok || fail "--firewall must override a previous skip"

# 7d-ix. headless / --yes re-run: previously allowed listeners restored from
#        state into FW_ALLOW_EXTRA (round-4, item 6(c): the :8080 case)
( yesno_calls=0
  pf_setup
  FW_STACK=none; OLD_FW_EXTRA_ALLOW="8080 8443"
  FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=false; ASSUME_YES=false
  prompt_firewall
  [[ "${FW_ALLOW_EXTRA[*]:-}" == "8080 8443" ]]
) && ok || fail "headless re-run must restore previously allowed listeners"

# 7d-x. inbound listener NOT covered by ssh/fw rules -> warn + one-shot allow
#       (the PVE-UPS :8080 incident: default-deny would cut it off silently)
( yesno_calls=0; yesno_give=0
  pf_setup
  FW_STACK=ufw; FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=true; ASSUME_YES=false
  SSH_PORT=22; CURRENT_SSH_PORTS=(22)
  fw_listener_lines(){ printf '%s\n' '8080 webui' '22 sshd'; }
  prompt_firewall
  [[ "${FW_ALLOW_EXTRA[*]:-}" == "8080" && "$yesno_calls" == 1 ]]
) && ok || fail "default-deny cutoff warning must offer a one-shot allow"

# 7d-xi. operator DECLINES the allow -> no auto-allow queued (noted instead)
( yesno_calls=0; yesno_give=1
  pf_setup
  FW_STACK=ufw; FW_OPT_OUT=false; FW_OPT_IN=false
  HAVE_TTY=true; ASSUME_YES=false
  SSH_PORT=22; CURRENT_SSH_PORTS=(22)
  fw_listener_lines(){ printf '%s\n' '8080 webui'; }
  prompt_firewall
  [[ "${#FW_ALLOW_EXTRA[@]}" -eq 0 && "$yesno_calls" == 1 ]]
) && ok || fail "declining the listener allow must queue no rules"

# ---- 7e. plan display shows the firewall state (module-visibility) --------
# (a) a converged keep-key re-run with UFW to be enabled shows the Firewall line
PLAN=$(
    stub_log
    crusty_globals
    source <("$EXTRACT" is_container)
    source <("$EXTRACT" plan_display)
    ENV_CLASS="debian"
    TARGET_USER=admin; SET_PASSWORD=""; GRANT_SUDO=no
    KEEP_KEYS=true; REMOVE_KEYS=(); USER_PUBLIC_KEY="add a key"
    ENABLE_FAIL2BAN=true; ENABLE_MAINTENANCE=true; ENABLE_DOCKER=false
    CURRENT_SSH_PORTS=(22); SSH_PORT=22; ALLOW_TCP_FORWARDING=no
    MAINT_HOUR=02; MAINT_MINUTE=00; BACKUP_ROOT="/var/backups/"
    UFW_SKIPPED=false; FW_STACK=ufw; FW_OPERATOR_ACK=false
    FW_RULES_SEEN=3; FW_REVIEWED=true; FW_REMOVE_RULES=(); FW_ALLOW_EXTRA=()
    plan_display
)
if printf '%s' "$PLAN" | grep -q '^Firewall'; then
    ok
else
    fail "plan display lacks the Firewall line"
fi

# (b) the operator-queued listener allow and the foreign-stack SKIP both
#     surface in the plan (no silent firewall state)
PLAN2=$(
    stub_log
    crusty_globals
    source <("$EXTRACT" is_container)
    source <("$EXTRACT" plan_display)
    ENV_CLASS="debian"
    TARGET_USER=admin; SET_PASSWORD=""; GRANT_SUDO=no
    KEEP_KEYS=true; REMOVE_KEYS=(); USER_PUBLIC_KEY="add a key"
    ENABLE_FAIL2BAN=true; ENABLE_MAINTENANCE=true; ENABLE_DOCKER=false
    CURRENT_SSH_PORTS=(22); SSH_PORT=22; ALLOW_TCP_FORWARDING=no
    MAINT_HOUR=02; MAINT_MINUTE=00; BACKUP_ROOT="/var/backups/"
    UFW_SKIPPED=true; FW_STACK=firewalld; FW_OPERATOR_ACK=false
    FW_RULES_SEEN=0; FW_REVIEWED=false
    FW_REMOVE_RULES=(); FW_ALLOW_EXTRA=(8080 8443)
    plan_display
)
if printf '%s' "$PLAN2" | grep -q 'UFW SKIPPED — existing firewalld stack kept' \
   && printf '%s' "$PLAN2" | grep -q 'ALLOW listeners: 8080 8443'; then
    ok
else
    fail "plan display must show the firewall SKIP and the queued listener allows"
fi

# ----------------------------------------------------------------------------
echo
echo "=========================================================="
echo "PASS: $PASS   FAIL: $FAIL"
echo "=========================================================="
[[ "$FAIL" -eq 0 ]]