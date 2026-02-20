# Scripts Directory

This directory contains all executable configuration scripts for the Crusty System project.

## Available Scripts

| Script | Description | Status |
|--------|-------------|--------|
| `ssh-hardener.sh` | SSH and server hardening for Ubuntu Server | Planned |

## Usage

All scripts should be run with root or sudo privileges:

```bash
sudo ./scripts/script-name.sh
```

## Script Standards

All scripts in this directory follow these standards:

1. **Idempotent**: Safe to run multiple times
2. **Backup**: Create backups before modifying files
3. **Logging**: Clear output with timestamps
4. **Error Handling**: Graceful failure with rollback capability
5. **Documentation**: Inline comments and separate docs

## Adding New Scripts

When adding new scripts:

1. Follow the header template from [CONTRIBUTING.md](../CONTRIBUTING.md)
2. Add documentation to the `docs/` directory
3. Update the table above
4. Test thoroughly before committing

## Security Note

⚠️ **Never commit private keys, passwords, or other secrets to this repository.**

Scripts should generate secrets at runtime and output them securely for the administrator to save.
