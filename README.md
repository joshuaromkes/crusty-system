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
| `ssh-hardener.sh` | SSH and server hardening for Ubuntu Server | Planned |
| `docker-setup.sh` | Docker and Docker Compose installation | Planned |
| `nginx-setup.sh` | Nginx reverse proxy configuration | Planned |

## Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/crusty-system.git
cd crusty-system

# Run the SSH hardener script
sudo ./scripts/ssh-hardener.sh
```

## Requirements

- Ubuntu Server 20.04 LTS or newer
- Root or sudo privileges
- Internet connection for package installation

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)
- [SSH Hardener Documentation](docs/SSH-HARDENER.md)
- [Contributing Guide](CONTRIBUTING.md)

## Security Notice

These scripts are designed to enhance server security. However, security is an ongoing process. After running these scripts:

1. Keep your system updated regularly
2. Monitor logs for suspicious activity
3. Review and rotate certificates periodically
4. Follow the principle of least privilege for user access

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Ubuntu Server documentation
- OpenSSH best practices guides
- Security hardening community resources
