# Contributing to Crusty System

Thank you for your interest in contributing to Crusty System! This document provides guidelines and instructions for contributing.

## Code of Conduct

By participating in this project, you agree to maintain a respectful and inclusive environment for all contributors.

## How to Contribute

### Reporting Issues

If you find a bug or have a suggestion:

1. Check existing issues to avoid duplicates
2. Use the issue templates provided
3. Include as much detail as possible:
   - Operating system version
   - Steps to reproduce
   - Expected vs actual behavior
   - Relevant logs or screenshots

### Submitting Changes

1. **Fork the repository**
2. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes**
4. **Test thoroughly**
5. **Commit with clear messages**:
   ```bash
   git commit -m "Add: Description of your change"
   ```
6. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```
7. **Open a Pull Request**

## Development Guidelines

### Script Standards

All scripts must follow these standards:

#### Header Template

```bash
#!/bin/bash

#===============================================================================
# Script Name: script-name.sh
# Description: Brief description of what the script does
# Author: Your Name
# Version: 1.0.0
# License: MIT
# Usage: sudo ./script-name.sh [options]
#===============================================================================
```

#### Error Handling

```bash
set -euo pipefail

# Log function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    log "ERROR: $1" >&2
    exit 1
}
```

#### Idempotency

Scripts should be safe to run multiple times:

```bash
# Good: Check before creating
if [ ! -f /etc/config ]; then
    echo "Creating config"
    # Create config
fi

# Avoid: Always overwriting
echo "Creating config"
# Create config
```

#### Backup Before Changes

```bash
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
}
```

### Documentation Standards

- Update README.md for new scripts
- Create detailed documentation in docs/
- Include usage examples
- Document all configuration options

### Testing

Before submitting:

1. Test on a clean Ubuntu Server VM
2. Verify idempotency by running twice
3. Check all output is clear and accurate
4. Verify rollback procedures work

## Project Structure

```
crusty-system/
├── README.md                 # Project overview
├── CONTRIBUTING.md           # This file
├── LICENSE                   # MIT License
├── docs/                     # Documentation
│   ├── ARCHITECTURE.md       # System architecture
│   └── SSH-HARDENER.md       # Script documentation
├── scripts/                  # Executable scripts
│   └── ssh-hardener.sh       # SSH hardening script
└── plans/                    # Planning documents
    └── future-features.md    # Planned features
```

## Commit Message Format

Use clear, descriptive commit messages:

```
<type>: <description>

[optional body]

[optional footer]
```

Types:
- `Add`: New feature
- `Fix`: Bug fix
- `Update`: Update to existing feature
- `Docs`: Documentation changes
- `Refactor`: Code refactoring
- `Test`: Adding tests
- `Chore`: Maintenance tasks

Examples:
```
Add: Docker installation script
Fix: SSH port validation in hardener script
Docs: Update architecture diagram
```

## Security Considerations

When contributing security-related scripts:

1. **Never hardcode credentials**
2. **Use strong encryption defaults**
3. **Follow principle of least privilege**
4. **Document security implications**
5. **Test for security regressions**

## Questions?

If you have questions about contributing:

1. Check existing documentation
2. Search closed issues
3. Open a new issue with the "question" label

Thank you for helping improve Crusty System!
