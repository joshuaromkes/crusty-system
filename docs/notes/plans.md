# Future Features Plan

This document outlines planned features and enhancements for the Crusty System project.

## Current State (matches reality)

### SSH Hardener Script
**Status**: Implemented

**Features**:
- Custom SSH port (58432 default; 22 supported for NAT'd/LXC-style hosts)
- Key installed for a non-root user only (root installs REFUSED — lockout guard)
- sshd_config pre-flighted with `sshd -t`, atomically replaced, rolled back on failure
- New port verified listening BEFORE the firewall is committed; old port temporarily allowed during transition
- /etc/ssh/sshd_config.d drop-ins moved to backup (cloud-init warning)
- UFW firewall configuration WITHOUT resetting existing rules
- Fail2ban intrusion prevention — enabled + RELOADED (never restarted; restarts severed SSH sessions historically), verified with `fail2ban-client status sshd`
- Backup of existing configurations

### Auto Update Script
**Status**: Implemented

**Features**:
- Weekly LOCAL maintenance cron (Sunday, configurable time) that runs only the local maintenance script
- The cron NEVER downloads anything — scripts update by re-running the setup one-liner (SHA-256 verified)
- Maintenance: apt update, apt upgrade (never full-upgrade), autoremove --purge, autoclean
- Conditional reboot only if /var/run/reboot-required exists (+5 min delay)
- Per-step exit-code logging to /var/log/crusty-maintenance.log
- `status`, `uninstall`, `run-now` subcommands
- Idempotent — re-running `install` rewrites the cron, healing legacy network-fetching versions

### Docker Setup Script
**Status**: Implemented

**Features**:
- Install Docker Engine from the official Docker repository
- Install Docker Compose plugin
- Configure Docker daemon with security best practices
- Merge (jq) or back up existing daemon.json — operator customizations survive
- Add specified user to the docker group (with root-equivalence warning)
- Weekly image prune cron: `docker image prune -af --filter "until=168h"` — images only, volumes NEVER pruned, exit code logged
- Prominent warning that published -p ports bypass UFW on Docker hosts

### Alpine Linux Setup
**Status**: Implemented

**Features**:
- Package selection, SSH hardening (same root-lockout guard), UFW, fail2ban
- Daily local maintenance: apk update/upgrade; reboots ONLY when packages actually changed
- sshd config pre-flight + rollback

### Master Setup Script
**Status**: Implemented

**Features**:
- One-liner bootstrap (curl main | bash)
- Downloads each sub-script and verifies it against embedded SHA-256 pins before use
- Cached copies that mismatch their pins are re-downloaded and re-verified (re-run heals boxes)
- Flags: --ssh-key, --ssh-user, --ssh-port (22 OK for LXC), --allow-tcp-forwarding, --docker, --docker-user, --no-fail2ban, --no-auto-updates, --update-time, --dry-run
- Weekly maintenance cron runs LOCAL maintenance only

---

## Priority 2: Infrastructure Scripts

### Nginx Reverse Proxy Script
**Status**: Planned

**Features**:
- Install Nginx
- Configure as reverse proxy
- SSL/TLS setup with Let's Encrypt
- Security headers configuration
- Rate limiting
- WebSocket support

**Configuration Options**:
- Domain names
- SSL certificate type
- Upstream servers
- Custom security headers

---

## Priority 3: Utility Scripts

### User Management Script
**Status**: Planned

**Features**:
- Create users with secure defaults
- Configure sudo access
- Set up SSH keys for users
- Configure user-specific firewall rules

---

### Backup Configuration Script
**Status**: Planned

**Features**:
- Backup server configurations
- Backup to remote storage (S3, SFTP)
- Encryption of backups
- Retention policy management
- Backup verification

---

### Monitoring Setup Script
**Status**: Planned

**Features**:
- Install Node Exporter
- Configure Prometheus scraping
- Set up basic alerts
- Log rotation configuration

---

## Priority 4: Advanced Features

### Multi-Server Deployment
**Status**: Future

**Description**: Deploy configurations across multiple servers from a central management node.

**Features**:
- Inventory management
- Parallel execution
- Rollback capabilities
- Configuration drift detection

---

### Configuration Profiles
**Status**: Future

**Description**: Pre-defined security profiles for different use cases.

**Profiles**:
- **Minimal**: Basic hardening for development servers
- **Standard**: Balanced security for production servers
- **Maximum**: Maximum security for sensitive systems
- **Compliance**: CIS benchmark compliant configuration

---

### Web Dashboard
**Status**: Future

**Description**: Web-based dashboard for managing server configurations.

**Features**:
- Server inventory
- Configuration status
- Deployment history
- Scheduled tasks
- Alert management
