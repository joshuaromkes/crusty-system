#!/bin/bash
#
# RustDesk Flatpak Unattended Installer for Arch Linux (Wayland)
# Installs RustDesk Flatpak and sets permissions for unattended screen sharing.
#
# Usage:
#   curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Arch/install-rustdesk.sh | sudo bash
#
# Note: This script assumes a KDE Plasma Wayland environment for the `kde-authorized` permission.
#       If you are using a different Wayland desktop environment (e.g., GNOME), you might need to
#       adjust the `flatpak permission-set` command (e.g., use `gnome-authorized` if applicable).
#       The user account running this script should be the one that will use RustDesk.

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/rustdesk-flatpak-install.log"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | sudo tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | sudo tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | sudo tee -a "$LOG_FILE"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        echo -e "${RED}ERROR: This script must be run as root.${NC}"
        exit 1
    fi
}

# Ensure Flatpak is installed
install_flatpak() {
    log "Checking for Flatpak installation..."
    if ! command -v flatpak &> /dev/null; then
        log "Flatpak not found. Installing Flatpak..."
        echo -e "${YELLOW}Flatpak not found. Installing now...${NC}"
        sudo pacman -S --noconfirm flatpak
        if [[ $? -ne 0 ]]; then
            log_error "Failed to install Flatpak with pacman."
            echo -e "${RED}ERROR: Failed to install Flatpak. Please install it manually and try again.${NC}"
            exit 1
        fi
        log "Flatpak installed successfully."
        echo -e "${GREEN}Flatpak installed successfully.${NC}"
    else
        log "Flatpak is already installed."
        echo -e "${GREEN}Flatpak is already installed.${NC}"
    fi
}

# Add Flathub remote
add_flathub_remote() {
    log "Adding Flathub remote..."
    flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    if [[ $? -ne 0 ]]; then
        log_error "Failed to add Flathub remote."
        echo -e "${RED}ERROR: Failed to add Flathub remote.${NC}"
        exit 1
    fi
    log "Flathub remote added successfully."
    echo -e "${GREEN}Flathub remote added successfully.${NC}"
}

# Install RustDesk Flatpak
install_rustdesk_flatpak() {
    log "Installing RustDesk Flatpak..."
    # --noninteractive flag is important for unattended
    flatpak --user install --noninteractive flathub com.rustdesk.RustDesk
    if [[ $? -ne 0 ]]; then
        log_error "Failed to install RustDesk Flatpak."
        echo -e "${RED}ERROR: Failed to install RustDesk Flatpak.${NC}\nIf RustDesk is already installed for the user, this step might fail, but it's safe to continue with setting permissions."
        # Do not exit here, allow installation to complete even if install fails (e.g., already installed).
    else
        log "RustDesk Flatpak installed successfully."
        echo -e "${GREEN}RustDesk Flatpak installed successfully.${NC}"
    fi
}

# Set Wayland permission for unattended access
set_wayland_permission() {
    log "Setting Wayland permission for unattended access (kde-authorized)..."
    local sudo_user=${SUDO_USER:-$(whoami)}
    if [[ -z "$sudo_user" ]]; then
        log_error "Could not determine SUDO_USER. Cannot set Flatpak permission."
        echo -e "${RED}ERROR: Could not determine user. Cannot set Flatpak permission for unattended access.${NC}"
        exit 1
    fi

    sudo -u "$sudo_user" flatpak permission-set kde-authorized remote-desktop com.rustdesk.RustDesk yes
    if [[ $? -ne 0 ]]; then
        log_error "Failed to set Wayland permission for RustDesk."
        echo -e "${RED}ERROR: Failed to set Wayland permission for unattended access. This may require manual confirmation when connecting (despite testing indicating otherwise).${NC}"
        # Do not exit here, allow installation to complete even if permission set fails.
    else
        log "Wayland permission set successfully for RustDesk Flatpak."
        echo -e "${GREEN}Wayland permission set successfully for RustDesk Flatpak.${NC}"
    fi
}

# Ensure xdg-desktop-portal-kde is installed for KDE Wayland environments
install_xdg_portal() {
    log "Checking for xdg-desktop-portal-kde..."
    if ! pacman -Qs xdg-desktop-portal-kde &> /dev/null; then
        log "xdg-desktop-portal-kde not found. Installing..."
        echo -e "${YELLOW}xdg-desktop-portal-kde not found. Installing now...${NC}"
        sudo pacman -S --noconfirm xdg-desktop-portal-kde
        if [[ $? -ne 0 ]]; then
            log_error "Failed to install xdg-desktop-portal-kde."
            echo -e "${RED}ERROR: Failed to install xdg-desktop-portal-kde. Screen sharing may not work correctly.${NC}"
            # Do not exit, allow installation to continue.
        fi
        log "xdg-desktop-portal-kde installed successfully."
        echo -e "${GREEN}xdg-desktop-portal-kde installed successfully.${NC}"
    else
        log "xdg-desktop-portal-kde is already installed."
        echo -e "${GREEN}xdg-desktop-portal-kde is already installed.${NC}"
    fi
}

# Main execution
main() {
    check_root

    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}    RustDesk Flatpak Unattended Installer${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo ""

    # Create log file with appropriate permissions
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    chown root:adm "$LOG_FILE" 2>/dev/null || true # Attempt to set group to adm for logs

    log "Starting RustDesk Flatpak installation script..."

    install_flatpak
    add_flathub_remote
    install_rustdesk_flatpak
    install_xdg_portal # Install portal before setting permissions
    set_wayland_permission

    log "Attempting to start RustDesk service (if applicable)..."
    local sudo_user=${SUDO_USER:-$(whoami)}
    if [[ -n "$sudo_user" ]]; then
       log "Trying to start RustDesk as user $sudo_user for initialization..."
       sudo -u "$sudo_user" flatpak run com.rustdesk.RustDesk --service &>/dev/null & disown
       log "RustDesk initiated in background for user $sudo_user."
    else
       log_warn "SUDO_USER not found, cannot initiate RustDesk in background."
    fi

    echo ""
    echo -e "${GREEN}==========================================${NC}"
    log "RustDesk Flatpak Installation Complete!"
    echo -e "${GREEN}    RustDesk Flatpak Installation Complete!${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo ""
    echo -e "${GREEN}Summary:${NC}"
    echo "  - Flatpak installed (if needed)"
    echo "  - Flathub remote added"
    echo "  - RustDesk Flatpak installed"
    echo "  - xdg-desktop-portal-kde installed (if needed)"
    echo "  - Unattended Wayland permission attempted for KDE Plasma."
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC}"
    echo "  - RustDesk should now be available from your applications menu."
    echo "  - Ensure RustDesk is running to accept incoming connections."
    echo "  - If you encounter issues with screen sharing prompts, verify your desktop environment's portal configuration."
    echo "  - The permission 'kde-authorized' assumes a KDE Plasma Wayland environment."
    echo "  - Log file: $LOG_FILE"
    echo ""
}

main "$@"