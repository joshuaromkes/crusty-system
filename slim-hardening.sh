#!/bin/bash
# slim-hardening.sh — the 15-minute setup, as if a human typed it.
# Does exactly 3 things: SSH hardening, unattended upgrades, optional Docker.
# No TUI. Ctrl+C aborts instantly. Every change is one file, easy to undo.
#
# Usage (as root):
#   ./slim-hardening.sh                                  # ssh hardening + auto-updates
#   ./slim-hardening.sh --port 58432                     # also move SSH off 22
#   ./slim-hardening.sh --key "$(cat ~/.ssh/id_ed25519.pub)"  # install your pubkey
#   ./slim-hardening.sh --docker                         # also install docker
#
# Safety rules:
#   - if no --key is given, password auth is LEFT ALONE (you won't lock yourself out)
#   - keep your current SSH session open until you've tested a NEW login
#   - no firewall changes, ever (do that by hand: ufw allow <port> && ufw enable)

set -euo pipefail

PORT=""
PUBKEY=""
INSTALL_DOCKER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)   PORT="$2"; shift 2 ;;
        --key)    PUBKEY="$2"; shift 2 ;;
        --docker) INSTALL_DOCKER=true; shift ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

echo "=== [1/3] SSH hardening ==="
SSHD_DROPIN=/etc/ssh/sshd_config.d/50-hardening.conf
if [[ ! -f /etc/ssh/sshd_config.orig ]]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig
    echo "  backed up sshd_config -> sshd_config.orig"
fi

if [[ -n "$PUBKEY" ]]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "  pubkey installed for root"
    # key is in place -> safe to disable password login
    cat > "$SSHD_DROPIN" <<EOF
PubkeyAuthentication yes
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    echo "  password auth DISABLED (key-only)"
else
    echo "  no --key given -> leaving password auth alone, only ensuring pubkey login works"
    cat > "$SSHD_DROPIN" <<EOF
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF
fi

if [[ -n "$PORT" && "$PORT" != "22" ]]; then
    echo "Port $PORT" >> "$SSHD_DROPIN"
    echo "  ssh moved to port $PORT"
fi

# validate BEFORE restarting — a broken config never gets applied
sshd -t
systemctl restart ssh
echo "  sshd restarted (config validated first). DO NOT close this session yet —"
echo "  open a SECOND terminal and confirm you can still log in."

echo
echo "=== [2/3] unattended upgrades ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unattended-upgrades
# enable the daily automatic run (Debian's own mechanism, not a cron hack)
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null
systemctl is-active --quiet unattended-upgrades && echo "  auto-updates: ON (daily security updates, no auto-reboot)"

echo
echo "=== [3/3] docker ==="
if [[ "$INSTALL_DOCKER" == true ]]; then
    apt-get install -y -qq docker.io docker-compose-v2
    systemctl enable --now docker
    echo "  docker installed + enabled"
else
    echo "  skipped (no --docker flag)"
fi

echo
echo "=== done. what changed: ==="
echo "  - /etc/ssh/sshd_config.d/50-hardening.conf   (delete this file + restart ssh to revert)"
echo "  - /etc/ssh/sshd_config.orig                  (original config backup)"
echo "  - /etc/apt/apt.conf.d/20auto-upgrades        (auto-updates on)"
[[ "$INSTALL_DOCKER" == true ]] && echo "  - docker.io installed + enabled"
echo "  firewall: NOT touched. if you want one: ufw allow <your-port>/tcp && ufw enable"