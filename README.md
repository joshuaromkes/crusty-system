# Crusty System

> Automated server configuration and hardening scripts for Ubuntu Server

## Overview

Crusty System is a collection of quick-start scripts designed to automatically configure servers and services with a single command. When a new system is provisioned, simply execute the appropriate script to set up everything with security best practices.

## Features

- **SSH Hardening**: Secure SSH configuration with certificate-based authentication
- **Firewall Setup**: UFW configuration with sensible defaults
- **Intrusion Prevention**: Fail2ban setup to protect against brute-force attacks
- **Automatic Updates**: Weekly security and general updates via cron
- **Root Protection**: Disabled root login with secure alternatives

## Available Scripts

| Script | Description | Status |
|--------|-------------|--------|
| `ssh-hardener.sh` | SSH and server hardening for Ubuntu Server | Ready |
| `auto-update.sh` | Automatic weekly updates for Ubuntu Server | Ready |
| `docker-setup.sh` | Docker and Docker Compose installation | Planned |

## Quick Start

```bash
# SSH Hardener
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/ssh-hardener.sh | sudo bash

# Auto Update
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/auto-update.sh | sudo bash

# Docker Setup
curl -sSL https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/scripts/docker-setup.sh | sudo bash

## Requirements

- Ubuntu Server 20.04 LTS or newer
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
