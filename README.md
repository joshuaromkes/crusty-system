# Crusty System

> Automated configuration and hardening scripts for Linux.

## Overview

Crusty System is a collection of quick-start scripts designed to automatically configure systems and services with a single command. When a new system is provisioned, simply execute the appropriate script to set up everything with security best practices.

## Available Scripts

| Script | Description | Status |
|--------|-------------|--------|
| `setup.sh` | **Master Debian/Ubuntu setup** — SSH hardening, Docker, auto-updates, self-update | Ready |
| `scripts/ubuntu/ssh-hardener.sh` | SSH and hardening for Debian/Ubuntu | Ready |
| `scripts/ubuntu/docker-setup.sh` | Docker Engine + Compose with security best practices | Ready |
| `scripts/ubuntu/auto-update.sh` | Automatic weekly updates for Debian/Ubuntu | Ready |
| `scripts/alpine/setup.sh` | Full system setup for Alpine Linux (packages, SSH, UFW, fail2ban, auto-updates) | Ready |

## Quick Start

### Debian/Ubuntu — Master Setup (Recommended)

One-liner that does everything:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- \
  --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" \
  --docker --docker-user $USER
```

**What it does:**
1. **SSH Hardening** — Changes SSH port, disables password auth, adds your public key, configures UFW firewall, installs fail2ban
2. **Docker** — Installs Docker Engine from official repo + Compose plugin + hardened daemon (log rotation, no-new-privileges, live-restore)
3. **Auto Updates** — Weekly unattended upgrades with conditional reboot (only if `/var/run/reboot-required` exists, +5 min delay)
4. **Self-Update** — Weekly cron job to auto-update crusty-system scripts

**Flags:**
```
--ssh-key "KEY"        SSH public key (REQUIRED)
--ssh-port PORT        SSH port (default: 58432)
--docker               Install Docker Engine + Compose
--docker-user USER     Add USER to docker group
--no-fail2ban          Skip fail2ban
--no-auto-updates      Skip weekly updates
--update-time HH:MM    Update time (default: 02:00)
--dry-run              Preview without applying
```

Minimal setup (SSH hardening only):
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/setup.sh | sudo bash -s -- \
  --ssh-key "$(cat key.pub)" --no-fail2ban --no-auto-updates
```

---

### Debian/Ubuntu — Individual Scripts

#### SSH Hardener

```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh | sudo bash
```

**What it does:**
- Changes SSH port to 58432
- Disables password authentication (key-only)
- Disables root login
- Installs and configures UFW firewall
- Installs and configures fail2ban with escalating bans

Non-interactive mode:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh | sudo bash -s -- \
  --port 58432 --key "$(cat ~/.ssh/id_ed25519.pub)" --no-fail2ban --no-auto-updates
```

---

#### Docker Setup

```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/docker-setup.sh | sudo bash -s -- --user $USER --prune-cron
```

**What it does:**
- Installs Docker Engine from official Docker repository (not apt default)
- Installs Docker Compose plugin (`docker compose`)
- Configures daemon with security best practices:
  - Log rotation: 10MB max, 3 files
  - `no-new-privileges: true`
  - `live-restore: true`
  - `userland-proxy: false`
- Optional: add user to docker group (`--user USER`)
- Optional: weekly system prune cron (`--prune-cron`)

---

#### Auto Update

```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh | sudo bash
```

Interactive mode prompts for update time. Non-interactive:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh | sudo bash -s -- install --non-interactive --time 03:30
```

**What it does:**
- Creates weekly cron job for system updates
- Conditional reboot: only if `/var/run/reboot-required` exists, with 5-minute delay
- `status`, `uninstall`, `run-now` subcommands

Other commands:
```bash
sudo bash auto-update.sh status      # Show current config
sudo bash auto-update.sh uninstall    # Remove cron job
sudo bash auto-update.sh run-now      # Trigger updates immediately
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
2. **SSH server** — install OpenSSH, configure port, add your public key, apply hardening
3. **UFW firewall** — deny incoming, allow SSH, enable at boot
4. **Fail2ban** — escalating bans for brute force protection
5. **Automatic updates** — daily `apk update && apk upgrade` + reboot

**Note:** Alpine uses `doas` by default (not `sudo`). The script detects which is available.

---

## Requirements

- Root or doas/sudo privileges
- Internet connection for package installation

## Security Notice

These scripts are designed to enhance server security. However, security is an ongoing process. After running these scripts:

1. Keep your system updated regularly
2. Monitor logs for suspicious activity
3. Review and rotate certificates periodically
4. Follow the principle of least privilege for user access

## License

This project is licensed under the MIT License
