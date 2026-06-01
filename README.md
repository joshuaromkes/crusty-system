# Crusty System

> Automated configuration and hardening scripts for Linux.

## Overview

Crusty System is a collection of quick-start scripts designed to automatically configure systems and services with a single command. When a new system is provisioned, simply execute the appropriate script to set up everything with security best practices.

## Available Scripts

| Script | Description | Status |
|--------|-------------|--------|
| `ssh-hardener.sh` | SSH and hardening for Debian/Ubuntu | Ready |
| `auto-update.sh` | Automatic weekly updates for Debian/Ubuntu | Ready |
| `setup.sh` | Full system setup for Alpine Linux (packages, SSH, UFW, fail2ban, auto-updates) | Ready |

## Quick Start

### Debian/Ubuntu

#### SSH Hardener

One-line installation:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh | sudo bash
```

**What it does:**
- Changes SSH port to 58432
- Disables password authentication (key-only)
- Disables root login
- Installs and configures UFW firewall
- Installs and configures fail2ban
- Generates ED25519 SSH key pair

Non-interactive mode:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/ssh-hardener.sh | sudo bash -s -- \
  --port 58432 --key "$(cat ~/.ssh/id_ed25519.pub)" --no-fail2ban --no-auto-updates
```

---

#### Auto Update

**What it does:**
- Prompts for preferred update time (24H format)
- Creates weekly cron job for system updates
- Automatically restarts after updates are applied
- Optionally runs updates immediately after setup

```bash
# Install
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh | sudo bash

# Check status
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh | sudo bash -s -- status

# Uninstall
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/auto-update.sh | sudo bash -s -- uninstall
```

---

#### Docker Setup

One-line installation:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ubuntu/docker-setup.sh | sudo bash
```

---

### Alpine Linux

Full system setup — installs common packages, configures SSH hardening,
UFW firewall, fail2ban, and automatic daily updates.

One-liner:
```bash
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/alpine/setup.sh | sh
```

Or download first:
```bash
wget https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/alpine/setup.sh
doas sh setup.sh
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
