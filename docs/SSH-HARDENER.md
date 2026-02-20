# SSH Hardener Script Documentation

This document provides detailed information about the SSH hardener script, including usage, configuration options, and troubleshooting.

## Overview

The SSH hardener script (`scripts/ssh-hardener.sh`) automates the secure configuration of SSH on Ubuntu Server. It implements industry best practices for SSH security and provides certificate-based authentication.

## Features

- **Custom SSH Port**: Configures SSH to use port 58432 instead of the default port 22
- **Certificate Authentication**: Generates ED25519 keys for secure, passwordless authentication
- **Root Login Disablement**: Prevents direct root login via SSH
- **UFW Firewall**: Configures Uncomplicated Firewall with appropriate rules
- **Fail2ban**: Sets up intrusion prevention for SSH
- **Automatic Updates**: Configures weekly security and general updates at 2:00 AM

## Requirements

| Requirement | Details |
|-------------|---------|
| Operating System | Ubuntu Server 20.04 LTS or newer |
| Privileges | Root or sudo access |
| Network | Internet connection for package installation |
| Storage | ~50MB for packages and configurations |

## Usage

### Basic Usage

```bash
sudo ./scripts/ssh-hardener.sh
```

### Advanced Usage

```bash
# Dry run - show what would be changed without making changes
sudo ./scripts/ssh-hardener.sh --dry-run

# Custom port
sudo ./scripts/ssh-hardener.sh --port 443

# Skip specific components
sudo ./scripts/ssh-hardener.sh --skip-fail2ban --skip-firewall

# Verbose output
sudo ./scripts/ssh-hardener.sh --verbose
```

### Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--port` | SSH port number | 58432 |
| `--key-type` | Key type: ed25519 or rsa | ed25519 |
| `--skip-firewall` | Skip UFW configuration | false |
| `--skip-fail2ban` | Skip Fail2ban setup | false |
| `--skip-updates` | Skip automatic updates configuration | false |
| `--dry-run` | Show changes without applying | false |
| `--verbose` | Enable verbose output | false |
| `--help` | Show help message | - |

## Execution Flow

```mermaid
sequenceDiagram
    participant User
    participant Script
    participant System
    
    User->>Script: Execute with sudo
    Script->>System: Check prerequisites
    Script->>System: Backup existing configs
    Script->>System: Install required packages
    Script->>System: Generate ED25519 keys
    Script->>System: Configure SSH daemon
    Script->>System: Configure UFW firewall
    Script->>System: Configure Fail2ban
    Script->>System: Setup cron for updates
    Script->>System: Restart services
    Script->>User: Output certificate info
    Script->>User: Display connection summary
```

## Configuration Changes

### SSH Daemon Configuration

The script modifies `/etc/ssh/sshd_config` with the following changes:

```ssh
# Network Settings
Port 58432
AddressFamily any
ListenAddress 0.0.0.0

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Key Settings
AuthorizedKeysFile .ssh/authorized_keys
HostKey /etc/ssh/ssh_host_ed25519_key

# Security Settings
X11Forwarding no
PrintMotd no
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Cryptography
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

### UFW Firewall Rules

```bash
# Default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH on custom port
sudo ufw allow 58432/tcp comment 'SSH'

# Enable firewall
sudo ufw --force enable
```

### Fail2ban Configuration

The script creates `/etc/fail2ban/jail.d/sshd.conf`:

```ini
[sshd]
enabled = true
port = 58432
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
ignoreip = 127.0.0.1/8
```

### Automatic Updates Configuration

The script creates a cron job at `/etc/cron.d/security-updates`:

```cron
# Weekly security and general updates at 2:00 AM on Sunday
0 2 * * 0 root /usr/bin/apt-get update && /usr/bin/apt-get upgrade -y >> /var/log/auto-updates.log 2>&1
```

## Output Format

After successful execution, the script outputs certificate information:

```
╔════════════════════════════════════════════════════════════════╗
║              SSH HARDENER - CONFIGURATION COMPLETE            ║
╚════════════════════════════════════════════════════════════════╝

Server Configuration:
  • SSH Port: 58432
  • Authentication: Certificate-based (ED25519)
  • Root Login: Disabled
  • Firewall: UFW enabled
  • Intrusion Prevention: Fail2ban active
  • Auto Updates: Weekly at 2:00 AM

═══════════════════════════════════════════════════════════════════
                    CERTIFICATE INFORMATION
═══════════════════════════════════════════════════════════════════

Host: 192.168.1.100
Port: 58432
Username: admin

-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
... [truncated for documentation] ...
-----END OPENSSH PRIVATE KEY-----

Public Key:
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC... admin@server

═══════════════════════════════════════════════════════════════════
              APACHE GUACAMOLE CONNECTION SETTINGS
═══════════════════════════════════════════════════════════════════

Protocol: SSH
Hostname: 192.168.1.100
Port: 58432
Username: admin
Private Key: [Copy the private key above]

═══════════════════════════════════════════════════════════════════
                         IMPORTANT NOTES
═══════════════════════════════════════════════════════════════════

⚠️  SAVE THE PRIVATE KEY SECURELY - It will not be shown again!
⚠️  The private key file is located at: /root/.ssh/id_ed25519
⚠️  Current SSH session will remain active - test new connection before closing!

To connect from a client:
  ssh -i /path/to/private_key -p 58432 admin@192.168.1.100

╔════════════════════════════════════════════════════════════════╗
║                    SETUP COMPLETE!                            ║
╚════════════════════════════════════════════════════════════════╝
```

## Connecting After Hardening

### Linux/macOS

```bash
# Save the private key to a file
nano ~/.ssh/server_key
# Paste the private key content

# Set correct permissions
chmod 600 ~/.ssh/server_key

# Connect
ssh -i ~/.ssh/server_key -p 58432 username@server-ip
```

### Windows (PowerShell)

```powershell
# Save the private key to a file
notepad $env:USERPROFILE\.ssh\server_key

# Set correct permissions
icacls "$env:USERPROFILE\.ssh\server_key" /inheritance:r /grant:r "$env:USERNAME:R"

# Connect
ssh -i $env:USERPROFILE\.ssh\server_key -p 58432 username@server-ip
```

### Apache Guacamole

1. Navigate to Settings → Connections
2. Create new connection with:
   - Name: Your Server Name
   - Protocol: SSH
   - Hostname: Your server IP
   - Port: 58432
   - Username: Your username
   - Private Key: Paste the private key content

## Troubleshooting

### Cannot Connect After Running Script

1. **Verify the port is open**:
   ```bash
   sudo ufw status
   sudo netstat -tlnp | grep 58432
   ```

2. **Check SSH service status**:
   ```bash
   sudo systemctl status sshd
   sudo journalctl -u sshd
   ```

3. **Verify key permissions**:
   ```bash
   ls -la ~/.ssh/
   # Private key should be 600
   # .ssh directory should be 700
   ```

### Fail2ban Blocking Legitimate Access

```bash
# Check banned IPs
sudo fail2ban-client status sshd

# Unban an IP
sudo fail2ban-client set sshd unbanip IP_ADDRESS
```

### Need to Revert Changes

```bash
# Restore original SSH config
sudo cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
sudo systemctl restart sshd

# Disable UFW
sudo ufw disable

# Remove Fail2ban
sudo apt-get remove fail2ban
```

## Security Recommendations

After running the script, consider these additional security measures:

1. **Key Management**
   - Store private keys in a secure location
   - Consider using a hardware security key (YubiKey)
   - Rotate keys periodically

2. **Monitoring**
   - Review `/var/log/auth.log` regularly
   - Set up log monitoring and alerts
   - Monitor Fail2ban statistics

3. **Network Security**
   - Consider VPN access only for SSH
   - Use security groups if on cloud platforms
   - Implement network segmentation

4. **Backup**
   - Backup your keys securely
   - Document server configurations
   - Test recovery procedures

## Related Documentation

- [Architecture Overview](ARCHITECTURE.md)
- [Main README](../README.md)
