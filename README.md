# Crusty System

> **Note:** This codebase was developed with AI assistance. Review and test thoroughly before deploying in production environments.

> Automated configuration and hardening scripts for Linux.

## Overview

Crusty System is a collection of quick-start scripts designed to automatically configure systems and services with a single command. When a new system is provisioned, simply execute the appropriate script to set up everything with security best practices.

**Update model (important):** the weekly cron runs LOCAL maintenance only — it never downloads anything from the network. Crusty scripts themselves are updated by re-running the setup one-liner: each downloaded sub-script is verified against SHA-256 pins embedded in `setup.sh` before it is used, and cached copies that no longer match their pin are automatically re-downloaded and re-verified. Re-running the one-liner on an already-configured box heals it to the current repo state — no per-box visits required.

## Available Scripts

| Script | Description | Status |
|--------|-------------|--------|
| `setup.sh` | **Master Debian/Ubuntu setup** — SSH hardening, Docker, auto-updates | Ready |
| `scripts/ubuntu/ssh-hardener.sh` | SSH hardening (lockout-safe) + UFW + fail2ban for Debian/Ubuntu | Ready |
| `scripts/ubuntu/docker-setup.sh` | Docker Engine + Compose with security best practices | Ready |
| `scripts/ubuntu/auto-update.sh` | Weekly LOCAL maintenance cron for Debian/Ubuntu | Ready |
| `scripts/ubuntu/maintenance.sh` | The local maintenance script the cron runs (apt + conditional reboot) | Ready |
| `scripts/alpine/setup.sh` | Full system setup for Alpine Linux (packages, SSH, UFW, fail2ban, auto-updates) | Ready |

## Quick Start

### Debian/Ubuntu — Master Setup (Recommended)

One-liner that does everything:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- \
  --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" \
  --ssh-user "$USER" \
  --docker --docker-user "$USER"
```

> **Tip:** When piping via `curl`, stdin is not a terminal, so you MUST pass `--ssh-key`. If you run the script directly on the machine (not piped), it will prompt you interactively.

> **Root-lockout guard:** the key is NEVER installed for `root` — the hardener sets `PermitRootLogin no`, so a root-installed key would lock you out. Run via `sudo` from your admin user (auto-detected via `SUDO_USER`), or pass `--ssh-user USER` explicitly. If no non-root target can be resolved, the script refuses with guidance instead of locking you out.

**What it does:**
1. **SSH Hardening** — Changes SSH port, disables password auth, disables root login, installs your key for a non-root user, configures UFW firewall (existing rules preserved), installs fail2ban and RELOADS it (never restarts — restarts historically severed live SSH sessions)
2. **Docker** — Installs Docker Engine from official repo + Compose plugin + hardened daemon (log rotation, no-new-privileges, live-restore; existing `daemon.json` keys are merged, not destroyed)
3. **Auto Updates** — Weekly LOCAL maintenance (apt upgrade, autoremove, autoclean) with conditional reboot (only if `/var/run/reboot-required` exists, +5 min delay). The cron never downloads anything; every step is logged to `/var/log/crusty-maintenance.log`
4. **Script updates** — handled by re-running the one-liner (SHA-256 verified), NOT by cron

**Flags:**
```
--ssh-key "KEY"              SSH public key for authorized_keys (required unless interactive)
--ssh-user USER              Non-root user to install the key for (default: SUDO_USER;
                             refuses instead of installing for root)
--ssh-port PORT              SSH port (default: 58432; 22 is supported for NAT'd/LXC-style
                             hosts behind a parent firewall)
--allow-tcp-forwarding MODE  "no" (default), "local", or "yes"
--docker                     Install Docker Engine + Compose
--docker-user USER           Add USER to docker group
--no-fail2ban                Skip fail2ban
--no-auto-updates            Skip weekly maintenance
--update-time HH:MM          Maintenance time (default: 02:00)
--dry-run                    Preview without applying
```

Minimal setup (SSH hardening only):
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- \
  --ssh-key "$(cat key.pub)" --ssh-user josh --no-fail2ban --no-auto-updates
```

LXC-style host that keeps port 22 (parent firewall handles filtering):
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- \
  --ssh-key "$(cat key.pub)" --ssh-user josh --ssh-port 22
```

### Supply-chain verification

`setup.sh` embeds a SHA-256 pin table at the top of the file. Every sub-script it downloads is verified against its pin before use; a mismatch (tampered or stale file) is a hard error. If you edit any sub-script, regenerate the pins (`sha256sum scripts/ubuntu/*.sh`) and paste them into the table before committing — otherwise the one-liner will refuse to download the changed script.

---

### Debian/Ubuntu — Individual Scripts

#### SSH Hardener

```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh | sudo bash
```

**What it does:**
- Changes SSH port to 58432 (22 supported for LXC-style hosts)
- Disables password authentication (key-only) and root login
- Installs your key for a non-root user (`--user`, or `SUDO_USER`; never root)
- Pre-flights the new sshd_config with `sshd -t` before touching the live config, replaces it atomically, and rolls back + exits on any restart/listener failure
- Verifies sshd is listening on the new port BEFORE enabling the firewall; the old port is temporarily allowed during the transition
- Moves conflicting `/etc/ssh/sshd_config.d/` drop-ins to a backup dir (cloud-init may recreate them on boot)
- Configures UFW without resetting existing rules
- Installs fail2ban and activates it with `fail2ban-client reload` (never `restart` — restarts historically severed SSH sessions), then verifies with `fail2ban-client status sshd`

Non-interactive mode:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh | sudo bash -s -- \
  --port 58432 --key "$(cat ~/.ssh/id_ed25519.pub)" --user josh --no-fail2ban --no-auto-updates
```

---

#### Docker Setup

```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/docker-setup.sh | sudo bash -s -- --user $USER --prune-cron
```

**What it does:**
- Installs Docker Engine from the official Docker repository (not apt default)
- Installs Docker Compose plugin (`docker compose`)
- Configures daemon with security best practices:
  - Log rotation: 10MB max, 3 files
  - `no-new-privileges: true`
  - `live-restore: true`
  - `userland-proxy: false`
  - Existing `daemon.json` customizations are MERGED (jq) or backed up before any overwrite
- Optional: add user to docker group (`--user USER`)
- Optional: weekly image prune cron (`--prune-cron`) — `docker image prune -af --filter "until=168h"`: images only, volumes are NEVER pruned, exit code logged

> **WARNING — Docker bypasses UFW:** any port published with `-p` (e.g. `-p 8080:80`) is reachable from the network even with `ufw default deny incoming`. Docker inserts its own iptables rules that run before UFW. Mitigate by publishing to loopback (`-p 127.0.0.1:8080:80` + reverse proxy), restricting via the `DOCKER-USER` chain, or filtering upstream. "Firewall: UFW enabled" does NOT close published Docker ports.

---

#### Auto Update

```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh | sudo bash
```

Interactive mode prompts for maintenance time. Non-interactive:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh | sudo bash -s -- install --non-interactive --time 03:30
```

**What it does:**
- Installs the LOCAL maintenance script to `/opt/crusty-system/scripts/ubuntu/maintenance.sh`
- Creates a weekly cron job that runs ONLY that local script — no downloads, no one-line mega-command
- Maintenance: `apt update`, `apt upgrade` (never full-upgrade), `autoremove --purge`, `autoclean`
- Conditional reboot: only if `/var/run/reboot-required` exists, with 5-minute delay
- Every step and its exit code is logged to `/var/log/crusty-maintenance.log`
- Re-running `install` rewrites the cron, replacing any legacy network-fetching version

Other commands:
```bash
sudo bash auto-update.sh status      # Show current config
sudo bash auto-update.sh uninstall    # Remove cron + maintenance script
sudo bash auto-update.sh run-now     # Trigger maintenance immediately
```

---

### Alpine Linux

Full system setup — installs common packages, configures SSH hardening,
UFW firewall, fail2ban, and automatic daily updates.

```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/alpine/setup.sh | sh
```

The script walks you through:
1. **Additional packages** — choose from nano, bash, curl, htop, tmux, git, rsyslog, chrony, neofetch
2. **SSH server** — install OpenSSH, configure port (22 allowed for LXC-style hosts), add your public key for a non-root user (refuses root — same lockout guard as Debian/Ubuntu), apply hardening with `sshd -t` pre-flight + rollback
3. **UFW firewall** — deny incoming, allow SSH, enable at boot
4. **Fail2ban** — escalating bans for brute force protection
5. **Automatic updates** — daily local `apk update && apk upgrade` via the local maintenance script; the box reboots ONLY when packages actually changed (no more unconditional daily reboots)

**Note:** Alpine uses `doas` by default (not `sudo`). The script detects which is available.

---

## Requirements

- Root or doas/sudo privileges
- Internet connection for package installation (not for the maintenance cron — that runs local-only)

## Security Model

1. **No network in cron.** The weekly/daily crons run local maintenance only. Script updates happen when you re-run the one-liner, verified against embedded SHA-256 pins.
2. **Lockout-safety first.** Root-key installs are refused; sshd changes are pre-flighted, atomic, verified, and rolled back on failure; the old SSH port stays reachable until the new one is confirmed live; fail2ban is reloaded, never restarted.
3. **Honest perimeter.** UFW manages host ports; Docker-published ports bypass UFW (see the Docker section). The completion output says so explicitly.
4. **Visible failures.** Maintenance logs every step's exit code to `/var/log/crusty-maintenance.log`.

## Security Notice

These scripts are designed to enhance server security. However, security is an ongoing process. After running these scripts:

1. Keep your system updated regularly
2. Monitor logs for suspicious activity
3. Review and rotate certificates periodically
4. Follow the principle of least privilege for user access

## Contributing

### Reporting Issues

Found a bug or have a feature request? Open an issue on GitHub:
https://github.com/joshuaromkes/crusty-system/issues

When reporting bugs, include:
- Which script you were running
- Operating system and version (`cat /etc/os-release`)
- Complete error output
- Steps to reproduce

### Pull Requests

Pull requests are welcome. Please:
1. Test your changes on a fresh Debian/Ubuntu VM
2. Run `bash -n` on all modified scripts (`sh -n` for the Alpine script)
3. Regenerate the SHA-256 pin table in `setup.sh` if you touched any sub-script
4. Keep the idempotent/safe-first design philosophy
5. Follow existing code style (color-coded output, `set -euo pipefail`, clear comments)

## License

This project is licensed under the MIT License
