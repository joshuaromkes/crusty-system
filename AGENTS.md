# crusty-system

Shell scripts for automated Linux system configuration and hardening.

## Stack
- **Language:** Bash (Debian/Ubuntu focus, some Alpine)
- **No build tools, no dependencies**

## Conventions
- Scripts must be self-contained and idempotent
- Security-first: SSH hardening, UFW, fail2ban, auto-updates
- One-liner deployable: `curl -sSL ... | bash`
- Alpine uses `doas`, not `sudo` — scripts detect which is available

## Scripts
- `setup.sh` — Master Debian/Ubuntu entry point (SSH + Docker + auto-updates + self-update)
- `scripts/ubuntu/ssh-hardener.sh` — SSH hardening for Debian/Ubuntu
- `scripts/ubuntu/docker-setup.sh` — Docker Engine + Compose with security defaults
- `scripts/ubuntu/auto-update.sh` — Weekly unattended upgrades with conditional reboot
- `scripts/alpine/setup.sh` — Full Alpine Linux setup

## Key Commands
```bash
# Syntax check
bash -n setup.sh
bash -n scripts/ubuntu/ssh-hardener.sh
bash -n scripts/ubuntu/docker-setup.sh
bash -n scripts/ubuntu/auto-update.sh
```
