# Monitor Manager for Arch/CachyOS (KDE Plasma Wayland)

## Overview

Monitor Manager is an automated monitor switching system designed for Arch Linux and CachyOS running KDE Plasma Wayland. It intelligently manages a primary monitor and a dummy/headless monitor, automatically switching between them based on connection status.

## Features

- **Automatic Monitor Switching**: Disables dummy monitor when primary is connected, enables it when disconnected
- **User-Space Service**: Runs as systemd user service to avoid permission issues with kscreen-doctor
- **Interactive TUI Setup**: Easy configuration using whiptail dialog menus
- **Configurable**: Customize monitor positions, polling intervals, and more
- **Well-Documented**: Clear logging and status reporting
- **One-Line Installation**: Quick deployment via curl

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                   Monitor Manager                        │
│                                                          │
│  ┌──────────────┐         ┌──────────────┐             │
│  │   Primary    │         │    Dummy     │             │
│  │   Monitor    │         │   Monitor    │             │
│  │   (DP-1)     │         │  (HDMI-A-1)  │             │
│  └──────────────┘         └──────────────┘             │
│         │                         │                     │
│         │                         │                     │
│         ▼                         ▼                     │
│  ┌─────────────────────────────────────┐               │
│  │     kscreen-doctor polling          │               │
│  │     (every 5 seconds)               │               │
│  └─────────────────────────────────────┘               │
│                    │                                    │
│         ┌──────────┴──────────┐                        │
│         ▼                     ▼                         │
│  Primary Connected?    Primary Disconnected?           │
│         │                     │                         │
│         ▼                     ▼                         │
│  Disable Dummy         Enable Dummy                    │
│  Set Primary           Set Dummy as Primary            │
└─────────────────────────────────────────────────────────┘
```

## Installation

### One-Line Installation

```bash
curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Arch/install-monitor-manager.sh | sudo bash
```

This will launch an interactive TUI menu where you can choose to:
- Setup/Install - Configure and install monitor manager
- Status - Show current configuration and service status
- Uninstall - Remove monitor manager
- Exit

### Local Installation

```bash
git clone https://github.com/joshuaromkes/crusty-system.git
cd crusty-system/Arch
sudo ./install-monitor-manager.sh
```

## Usage

### Interactive TUI Menu (Recommended)

Run without arguments to access the main menu:

```bash
sudo ./install-monitor-manager.sh
```

The menu provides options for:
1. **Setup/Install** - Interactive configuration wizard that guides you through:
   - Selecting your primary monitor (main display)
   - Selecting your dummy monitor (headless/backup)
   - Configuring dummy monitor position
   - Setting polling interval
   - Installing and starting the service

2. **Status** - View current configuration and service status

3. **Uninstall** - Remove monitor manager with confirmation

4. **Exit** - Close the menu

### Direct Commands

You can also use direct command-line arguments:

```bash
# Install/setup with interactive configuration
sudo ./install-monitor-manager.sh setup

# Check status
sudo ./install-monitor-manager.sh status

# Uninstall
sudo ./install-monitor-manager.sh uninstall
```

### Service Management

```bash
# Check service status
systemctl --user status monitor-manager.service

# View logs
journalctl --user -u monitor-manager.service -f

# Restart service
systemctl --user restart monitor-manager.service

# Stop service
systemctl --user stop monitor-manager.service

# Start service
systemctl --user start monitor-manager.service
```

## Configuration

### Config File Location

`~/.config/monitor-manager/config`

### Example Configuration

```bash
# Monitor Manager Configuration
# Generated on 2026-03-17

# Primary monitor (your main display)
primary_output=DP-1

# Dummy monitor (headless/backup display)
dummy_output=HDMI-A-1

# Dummy monitor position (X,Y coordinates)
dummy_position=1920,0

# Dummy monitor mode (optional, leave empty for auto)
dummy_mode=

# Poll interval in seconds
poll_interval=5
```

### Manual Configuration

You can manually edit the config file and restart the service:

```bash
nano ~/.config/monitor-manager/config
systemctl --user restart monitor-manager.service
```

## Logs

### Log Locations

- **Daemon logs**: `~/.local/share/monitor-manager/monitor-manager.log`
- **Install logs**: `/var/log/monitor-manager-install.log`

### View Recent Logs

```bash
tail -f ~/.local/share/monitor-manager/monitor-manager.log
```

## Troubleshooting

### Service Not Starting

1. Check if kscreen-doctor is available:
   ```bash
   which kscreen-doctor
   ```

2. Verify config file exists:
   ```bash
   cat ~/.config/monitor-manager/config
   ```

3. Check service status:
   ```bash
   systemctl --user status monitor-manager.service
   ```

### Monitors Not Switching

1. Test kscreen-doctor manually:
   ```bash
   kscreen-doctor -o
   ```

2. Check if outputs match config:
   ```bash
   kscreen-doctor -o | grep -E "(DP-1|HDMI-A-1)"
   ```

3. Review daemon logs:
   ```bash
   tail -n 50 ~/.local/share/monitor-manager/monitor-manager.log
   ```

### Permission Issues

The service runs as a user service (not root) to avoid kscreen-doctor permission issues. If you encounter problems:

1. Ensure you're running in a Wayland session
2. Verify XDG_RUNTIME_DIR is set:
   ```bash
   echo $XDG_RUNTIME_DIR
   ```

## Technical Details

### Architecture

- **Language**: Bash
- **Display Manager**: kscreen-doctor (KDE Plasma Wayland)
- **Service Type**: systemd user service
- **Polling Method**: Continuous loop with configurable interval
- **TUI Framework**: whiptail (dialog package)

### Files Created

```
/usr/local/bin/monitor-manager.sh              # Daemon script
~/.config/monitor-manager/config               # Configuration
~/.config/systemd/user/monitor-manager.service # Service unit
~/.config/systemd/user/monitor-manager.timer   # Timer unit (optional)
~/.local/share/monitor-manager/                # Log directory
/var/log/monitor-manager-install.log           # Installation log
```

### Dependencies

- `kscreen` - Provides kscreen-doctor command
- `dialog` - Provides whiptail for TUI
- `systemd` - User service management

## Use Cases

### Remote Desktop / Headless Server

Perfect for systems that need a display output for remote desktop (RustDesk, VNC, etc.) but don't always have a physical monitor connected.

### Laptop Docking Station

Automatically switch between laptop display and docking station monitors.

### Multi-Monitor Setups

Manage complex monitor configurations with automatic fallback to dummy display.

## Limitations

- **KDE Plasma Wayland Only**: Uses kscreen-doctor which is KDE-specific
- **Two Monitors**: Designed for primary + dummy configuration
- **Polling-Based**: Uses polling instead of event-driven (5s default interval)
- **User Session**: Requires active user session (won't work at login screen)

## Contributing

Contributions are welcome! Please follow the existing code style and include:
- Clear commit messages
- Documentation updates
- Testing on Arch/CachyOS

## License

MIT License - See main repository LICENSE file

## Support

For issues, questions, or feature requests:
- Open an issue on GitHub
- Check existing issues for solutions
- Review logs for debugging information

## Credits

Part of the Crusty System project - Automated configuration and hardening scripts for Linux and Windows.
