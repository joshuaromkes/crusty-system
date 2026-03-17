# Crusty System

> Automated configuration and hardening scripts for Linux and Windows.

## Overview

Crusty System is a collection of quick-start scripts designed to automatically configures and services with a single command. When a new system is provisioned, simply execute the appropriate script to set up everything with security best practices.

## Available Scripts
## Available Scripts

| Script | Description | Status |
|--------|-------------|--------|
| `ssh-hardener.sh` | SSH and hardening for Ubuntu | Ready |
| `auto-update.sh` | Automatic weekly updates for Ubuntu | Ready |

| `install-rustdesk.sh` | RustDesk Flatpak installer for Arch Linux (Wayland) | Ready |


## Quick Start

### SSH Hardener

One-line installation:
```bash
curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Ubuntu/ssh-hardener.sh | sudo bash
```

**What it does:**
- Changes SSH port to 58432
- Disables password authentication (key-only)
- Disables root login
- Installs and configures UFW firewall
- Installs and configures fail2ban
- Generates ED25519 SSH key pair

---

### Auto Update

**What it does:**
- Prompts for preferred update time (24H format)
- Creates weekly cron job for system updates
- Automatically restarts the after updates are applied
- Optionally runs updates immediately after setup

**Usage Examples:**

If the script is **not downloaded locally**, use curl with arguments:
```bash
# Install with interactive time selection
curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Ubuntu/auto-update.sh | sudo bash

# Check current configuration
curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Ubuntu/auto-update.sh | sudo bash -s -- status

# Uninstall and clean up
curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Ubuntu/auto-update.sh | sudo bash -s -- uninstall
```

If the script is **downloaded locally**:
```bash
# Install with interactive time selection
sudo ./auto-update.sh install

# Run updates immediately
sudo ./auto-update.sh run-now

# Check current configuration
sudo ./auto-update.sh status

# Uninstall and clean up
sudo ./auto-update.sh uninstall
```

---

### Docker Setup

One-line installation:
```bash
curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Ubuntu/docker-setup.sh | sudo bash
```
---

### RustDesk Flatpak Installer

One-line installation:
```bash
curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Arch/install-rustdesk.sh | sudo bash
```

**What it does:**
- Installs Flatpak (if not present) and adds Flathub remote
- Installs RustDesk Flatpak for Arch Linux (Wayland)
- Configures xdg-desktop-portal-kde for KDE Plasma Wayland
- Sets permission for unattended screen sharing (`kde-authorized remote-desktop`)
- Starts RustDesk in the background

**Note:** This script is designed for Arch Linux with KDE Plasma Wayland. For other desktop environments, the permission command may need adjustment.


## Requirements

- Root or sudo privileges
- Internet connection for package installation

## Security Notice

These scripts are designed to enhance server security. However, security is an ongoing process. After running these scripts:

1. Keep your system updated regularly
2. Monitor logs for suspicious activity
3. Review and rotate certificates periodically
4. Follow the principle of least privilege for user access

## License

This project is licensed under the MIT License
