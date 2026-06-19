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
- `scripts/ssh-hardener.sh` — SSH hardening for Debian/Ubuntu
- `scripts/auto-update.sh` — Weekly unattended upgrades
- `scripts/setup.sh` — Full Alpine Linux setup

## Key Commands
```bash
# Test a script
bash scripts/ssh-hardener.sh
```
