#!/bin/bash
#
# Auto Update Script for Ubuntu Server
# Configures automatic weekly system updates at 2:00 AM
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/auto-update-setup.log"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

log "Starting Auto Update Setup..."

# Update system packages first
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# Install unattended-upgrades if not present
log "Installing unattended-upgrades..."
apt-get install -y -qq unattended-upgrades

# Configure automatic update settings
log "Configuring automatic updates..."

# Create 20auto-upgrades configuration
cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Configure unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
    // Add packages to exclude from automatic updates
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# Create weekly update cron job at 2:00 AM
log "Creating weekly update cron job..."
cat > /etc/cron.d/crusty-auto-update << 'EOF'
# Crusty System - Weekly automatic updates at 2:00 AM
0 2 * * 0 root /usr/bin/apt-get update && /usr/bin/apt-get upgrade -y >> /var/log/crusty-update.log 2>&1
EOF
chmod 644 /etc/cron.d/crusty-auto-update

# Create log file with proper permissions
touch /var/log/crusty-update.log
chmod 644 /var/log/crusty-update.log

# Display summary
echo ""
echo "=========================================="
log "Auto Update Setup Complete!"
echo "=========================================="
echo ""
echo -e "${GREEN}Configuration Summary:${NC}"
echo "  - Update Schedule: Weekly at 2:00 AM (Sunday)"
echo "  - Unattended-upgrades: Enabled"
echo "  - Security updates: Automatic"
echo "  - Package cleanup: Weekly"
echo ""
echo -e "${YELLOW}Log Files:${NC}"
echo "  - Setup log: $LOG_FILE"
echo "  - Update log: /var/log/crusty-update.log"
echo ""
echo -e "${GREEN}To manually trigger an update:${NC}"
echo "  apt-get update && apt-get upgrade -y"
echo ""
