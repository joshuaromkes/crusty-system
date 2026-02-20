# Architecture Overview

This document describes the architecture and design principles of the Crusty System project.

## Design Philosophy

### Single Command Execution

Every script in this repository is designed to be executable with a single command. This principle ensures:

- **Reproducibility**: Same configuration every time
- **Simplicity**: No manual intervention required
- **Documentation**: The script itself documents the setup process

### Idempotency

Scripts should be idempotent - running them multiple times produces the same result without errors or duplicate configurations.

### Security First

All configurations follow security best practices by default:

- Minimal attack surface
- Strong encryption and authentication
- Regular security updates
- Audit logging where applicable

## System Architecture

```mermaid
flowchart TB
    subgraph Server[Ubuntu Server]
        subgraph SSH[SSH Layer]
            SSHD[SSH Daemon - Port 58432]
            CERTS[ED25519 Certificates]
        end
        
        subgraph Firewall[Firewall Layer]
            UFW[UFW Firewall]
            FAIL2BAN[Fail2ban]
        end
        
        subgraph Updates[Update Layer]
            CRON[Cron - Weekly 2 AM]
            APT[APT Unattended Upgrades]
        end
    end
    
    CLIENT[SSH Client] -->|Certificate Auth| SSHD
    SSHD --> UFW
    FAIL2BAN --> UFW
    CRON --> APT
```

## Script Structure

```mermaid
flowchart LR
    subgraph Repository
        README[README.md]
        SCRIPTS[scripts/]
        DOCS[docs/]
        PLANS[plans/]
    end
    
    subgraph Scripts
        SSH[ssh-hardener.sh]
        DOCKER[docker-setup.sh]
        NGINX[nginx-setup.sh]
    end
    
    SCRIPTS --> SSH
    SCRIPTS --> DOCKER
    SCRIPTS --> NGINX
```

## SSH Hardener Workflow

The SSH hardener script follows this workflow:

```mermaid
flowchart TD
    START[Start] --> CHECK[Check Root/Sudo]
    CHECK --> BACKUP[Backup Current Configs]
    BACKUP --> SSH_CONFIG[Configure SSH]
    SSH_CONFIG --> KEYGEN[Generate ED25519 Keys]
    KEYGEN --> CERT_INFO[Output Certificate Info]
    CERT_INFO --> UFW[Configure UFW]
    UFW --> FAIL2BAN[Setup Fail2ban]
    FAIL2BAN --> UPDATES[Configure Auto Updates]
    UPDATES --> RESTART[Restart Services]
    RESTART --> END[Complete - Show Summary]
```

## Configuration Details

### SSH Configuration

| Setting | Value | Reason |
|---------|-------|--------|
| Port | 58432 | Non-standard port reduces automated attacks |
| PermitRootLogin | no | Prevents direct root access |
| PasswordAuthentication | no | Forces certificate authentication |
| PubkeyAuthentication | yes | Enables certificate-based auth |
| AuthorizedKeysFile | .ssh/authorized_keys | Standard key location |
| X11Forwarding | no | Reduces attack surface |
| MaxAuthTries | 3 | Limits brute force attempts |

### Firewall Rules

| Port | Protocol | Action | Purpose |
|------|----------|--------|---------|
| 58432 | TCP | Allow | SSH access |
| All others | - | Deny | Default deny policy |

### Automatic Updates Schedule

| Day | Time | Type |
|-----|------|------|
| Sunday | 02:00 AM | Security updates |
| Sunday | 02:00 AM | General updates |

## File Locations

After running the SSH hardener:

```
/etc/ssh/
├── sshd_config              # Hardened SSH configuration
├── sshd_config.backup       # Original config backup
└── ssh_host_ed25519_key     # Host key

/root/.ssh/
├── id_ed25519               # Private key - KEEP SECURE
├── id_ed25519.pub           # Public key
└── authorized_keys          # Authorized certificates

/etc/fail2ban/
├── fail2ban.conf            # Main configuration
└── jail.d/
    └── sshd.conf            # SSH jail configuration

/etc/ufw/
└── rules.before             # UFW firewall rules
```

## Output Format

The script outputs certificate information in a format ready for copy-paste into SSH clients:

```
=== SSH Certificate Information ===
Host: your-server.example.com
Port: 58432
Username: your-username

Private Key:
-----BEGIN OPENSSH PRIVATE KEY-----
[base64 encoded key data]
-----END OPENSSH PRIVATE KEY-----

Public Key:
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host

For Apache Guacamole, use the following connection parameters:
- Protocol: SSH
- Hostname: your-server.example.com
- Port: 58432
- Username: your-username
- Private Key: [paste the private key above]
===================================
```

## Future Enhancements

Planned features for future releases:

1. **Multi-server deployment**: Configure multiple servers from a central management node
2. **Configuration profiles**: Different security levels for different use cases
3. **Rollback capability**: Easy restoration of original configurations
4. **Logging and monitoring**: Integration with centralized logging systems
5. **Container support**: Hardening scripts for containerized environments
