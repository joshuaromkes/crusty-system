#!/bin/bash
#
# Monitor Manager Installer for Arch Linux / CachyOS (KDE Plasma Wayland)
# Automatically manages dummy/primary monitor switching
#
# Usage:
#   curl -sSL https://YOUR_GITHUB_PAT@raw.githubusercontent.com/joshuaromkes/crusty-system/main/Arch/install-monitor-manager.sh | sudo bash
#
# Or locally:
#   sudo ./install-monitor-manager.sh [setup|status|uninstall]
#
# This script:
# - Installs required dependencies (dialog, kscreen)
# - Provides TUI to configure primary and dummy monitors
# - Sets up systemd user service and timer
# - Runs as user (not root) to avoid kscreen-doctor permission issues

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/monitor-manager-install.log"

# Logging functions
log() {
    local msg
    msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | sudo tee -a "$LOG_FILE" > /dev/null
    echo -e "${GREEN}${msg}${NC}" >&2
}

log_warn() {
    local msg
    msg="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo "$msg" | sudo tee -a "$LOG_FILE" > /dev/null
    echo -e "${YELLOW}${msg}${NC}" >&2
}

log_error() {
    local msg
    msg="[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo "$msg" | sudo tee -a "$LOG_FILE" > /dev/null
    echo -e "${RED}${msg}${NC}" >&2
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        echo -e "${RED}ERROR: This script must be run as root.${NC}"
        exit 1
    fi
}

# Get the actual user (not root)
get_user() {
    ACTUAL_USER="${SUDO_USER:-$(whoami)}"
    if [[ "$ACTUAL_USER" == "root" ]]; then
        log_error "Cannot determine actual user. Please run with sudo, not as root directly."
        echo -e "${RED}ERROR: Please run with sudo, not as root directly.${NC}"
        exit 1
    fi
    USER_HOME=$(eval echo "~$ACTUAL_USER")
    USER_UID=$(id -u "$ACTUAL_USER")
    USER_RUNTIME_DIR="/run/user/$USER_UID"
    
    # Detect Wayland display from the runtime directory
    # Look for wayland-* sockets in XDG_RUNTIME_DIR
    WAYLAND_DISPLAY=""
    if [[ -d "$USER_RUNTIME_DIR" ]]; then
        # Find the first wayland socket (usually wayland-0)
        WAYLAND_DISPLAY=$(ls "$USER_RUNTIME_DIR" 2>/dev/null | grep -m1 '^wayland-[0-9]*$' || echo "")
    fi
    
    # Fallback to wayland-0 if not found
    if [[ -z "$WAYLAND_DISPLAY" ]]; then
        WAYLAND_DISPLAY="wayland-0"
    fi
    
    # Try to detect DISPLAY from the user's session (for XWayland apps)
    DISPLAY=":0"
    
    log "Detected user: $ACTUAL_USER (home: $USER_HOME, uid: $USER_UID)"
    log "Display environment: WAYLAND_DISPLAY=$WAYLAND_DISPLAY, DISPLAY=$DISPLAY"
}

# Install dependencies
install_dependencies() {
    log "Checking and installing dependencies..."
    
    local packages_to_install=()
    
    # Check for dialog (provides whiptail)
    if ! command -v whiptail &> /dev/null; then
        log "whiptail not found, will install dialog package"
        packages_to_install+=("dialog")
    fi
    
    # Check for kscreen-doctor
    if ! command -v kscreen-doctor &> /dev/null; then
        log "kscreen-doctor not found, will install kscreen package"
        packages_to_install+=("kscreen")
    fi
    
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        log "Installing packages: ${packages_to_install[*]}"
        echo -e "${YELLOW}Installing required packages: ${packages_to_install[*]}${NC}"
        pacman -S --noconfirm "${packages_to_install[@]}"
        log "Dependencies installed successfully"
        echo -e "${GREEN}Dependencies installed successfully.${NC}"
    else
        log "All dependencies already installed"
        echo -e "${GREEN}All dependencies already installed.${NC}"
    fi
}

# Parse kscreen-doctor output to get list of outputs
get_outputs() {
    local outputs_raw
    
    # Run kscreen-doctor with full Wayland/X11 environment
    outputs_raw=$(sudo -u "$ACTUAL_USER" \
        XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
        WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        DISPLAY="$DISPLAY" \
        kscreen-doctor -o 2>&1)
    
    local exit_code=$?
    
    if [[ -z "$outputs_raw" ]] || [[ $exit_code -ne 0 ]]; then
        log_error "Failed to get outputs from kscreen-doctor (exit: $exit_code)"
        return 1
    fi
    
    # Strip ANSI escape codes from the output
    # kscreen-doctor outputs colored text which breaks pattern matching
    local outputs_clean
    outputs_clean=$(echo "$outputs_raw" | sed 's/\x1b\[[0-9;]*m//g')
    
    # Parse output names (e.g., "Output: 1 HDMI-A-1 ...")
    # The format is "Output: <id> <name> <uuid>"
    # We need field 3 which is the output name (HDMI-A-1, DP-1, etc.)
    local parsed_outputs
    parsed_outputs=$(echo "$outputs_clean" | sed -n 's/^Output: [0-9]* \([^ ]*\) .*/\1/p')
    
    echo "$parsed_outputs"
}

# TUI: Select primary monitor
select_primary_monitor() {
    local outputs
    outputs=$(get_outputs)
    
    if [[ -z "$outputs" ]]; then
        log_error "No outputs detected. Is KDE Plasma Wayland running?"
        whiptail --title "Error" --msgbox "No monitors detected.\n\nPlease ensure:\n- KDE Plasma Wayland is running\n- You're running this from a graphical session\n- kscreen-doctor is working" 12 60
        return 1
    fi
    
    # Build menu items for whiptail
    local menu_items=()
    local i=1
    while IFS= read -r output; do
        menu_items+=("$output" "Monitor $i")
        ((i++))
    done <<< "$outputs"
    
    # Show selection dialog
    local selected
    selected=$(whiptail --title "Select Primary Monitor" \
        --menu "Choose your PRIMARY monitor (the one you normally use):" \
        20 70 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    
    if [[ -z "$selected" ]]; then
        log_warn "No primary monitor selected"
        return 1
    fi
    
    echo "$selected"
}

# TUI: Select dummy monitor
select_dummy_monitor() {
    local primary="$1"
    local outputs
    outputs=$(get_outputs)
    
    if [[ -z "$outputs" ]]; then
        log_error "No outputs detected"
        return 1
    fi
    
    # Build menu items, excluding primary
    local menu_items=()
    local i=1
    while IFS= read -r output; do
        if [[ "$output" != "$primary" ]]; then
            menu_items+=("$output" "Monitor $i")
        fi
        ((i++))
    done <<< "$outputs"
    
    if [[ ${#menu_items[@]} -eq 0 ]]; then
        log_error "No other monitors available for dummy selection"
        whiptail --title "Error" --msgbox "No other monitors available.\n\nYou need at least 2 monitors detected." 10 60
        return 1
    fi
    
    # Show selection dialog
    local selected
    selected=$(whiptail --title "Select Dummy Monitor" \
        --menu "Choose your DUMMY/HEADLESS monitor:" \
        20 70 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    
    if [[ -z "$selected" ]]; then
        log_warn "No dummy monitor selected"
        return 1
    fi
    
    echo "$selected"
}

# TUI: Configure dummy position
configure_dummy_position() {
    local position
    position=$(whiptail --title "Dummy Monitor Position" \
        --inputbox "Enter dummy monitor position (X,Y coordinates):\n\nExamples:\n- 1920,0 (right of 1920px wide primary)\n- 0,1080 (below 1080px tall primary)\n- 0,0 (same position, mirrored)" \
        15 70 "1920,0" \
        3>&1 1>&2 2>&3)
    
    if [[ -z "$position" ]]; then
        log_warn "Using default position: 1920,0"
        echo "1920,0"
    else
        echo "$position"
    fi
}

# TUI: Configure poll interval
configure_poll_interval() {
    local interval
    interval=$(whiptail --title "Poll Interval" \
        --inputbox "Enter monitor polling interval in seconds:\n\n(How often to check for monitor changes)" \
        12 60 "5" \
        3>&1 1>&2 2>&3)
    
    if [[ -z "$interval" ]] || ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid interval, using default: 5"
        echo "5"
    else
        echo "$interval"
    fi
}

# Run TUI configuration
run_tui_setup() {
    log "Starting TUI configuration..."
    
    # Welcome message
    whiptail --title "Monitor Manager Setup" --msgbox \
        "Welcome to Monitor Manager Setup!\n\nThis tool will help you configure automatic monitor switching for KDE Plasma Wayland.\n\nYou will select:\n- Your PRIMARY monitor (main display)\n- Your DUMMY monitor (headless/backup)\n\nThe system will automatically:\n- Disable dummy when primary is connected\n- Enable dummy when primary is disconnected" \
        18 70
    
    # Select primary monitor
    local primary
    primary=$(select_primary_monitor)
    if [[ -z "$primary" ]]; then
        log_error "Primary monitor selection cancelled"
        return 1
    fi
    log "Selected primary monitor: $primary"
    
    # Select dummy monitor
    local dummy
    dummy=$(select_dummy_monitor "$primary")
    if [[ -z "$dummy" ]]; then
        log_error "Dummy monitor selection cancelled"
        return 1
    fi
    log "Selected dummy monitor: $dummy"
    
    # Configure dummy position
    local position
    position=$(configure_dummy_position)
    log "Dummy position: $position"
    
    # Configure poll interval
    local interval
    interval=$(configure_poll_interval)
    log "Poll interval: ${interval}s"
    
    # Confirmation
    if ! whiptail --title "Confirm Configuration" --yesno \
        "Please confirm your configuration:\n\nPrimary Monitor: $primary\nDummy Monitor: $dummy\nDummy Position: $position\nPoll Interval: ${interval}s\n\nProceed with installation?" \
        15 70; then
        log_warn "Configuration cancelled by user"
        return 1
    fi
    
    # Save configuration
    save_config "$primary" "$dummy" "$position" "$interval"
}

# Save configuration file
save_config() {
    local primary="$1"
    local dummy="$2"
    local position="$3"
    local interval="$4"
    
    local config_dir="$USER_HOME/.config/monitor-manager"
    local config_file="$config_dir/config"
    
    log "Creating config directory: $config_dir"
    sudo -u "$ACTUAL_USER" mkdir -p "$config_dir"
    
    log "Writing configuration to: $config_file"
    sudo -u "$ACTUAL_USER" tee "$config_file" > /dev/null <<EOF
# Monitor Manager Configuration
# Generated on $(date)

# Primary monitor (your main display)
primary_output=$primary

# Dummy monitor (headless/backup display)
dummy_output=$dummy

# Dummy monitor position (X,Y coordinates)
dummy_position=$position

# Dummy monitor mode (optional, leave empty for auto)
dummy_mode=

# Poll interval in seconds
poll_interval=$interval
EOF
    
    log "Configuration saved successfully"
    echo -e "${GREEN}Configuration saved to: $config_file${NC}"
}

# Install daemon script
install_daemon() {
    log "Installing monitor-manager daemon..."
    
    local daemon_source="$(dirname "$(readlink -f "$0")")/monitor-manager.sh"
    local daemon_dest="/usr/local/bin/monitor-manager.sh"
    
    # Check if source exists (when run from repo)
    if [[ -f "$daemon_source" ]]; then
        log "Copying daemon from: $daemon_source"
        cp "$daemon_source" "$daemon_dest"
    else
        # If not found, try to download it (when run via curl)
        # Extract GitHub URL from script header if available, otherwise use default
        local github_url
        github_url=$(grep -oP '(?<=curl -sSL )https://[^|]+' "$0" 2>/dev/null | head -1 | sed 's|install-monitor-manager.sh|monitor-manager.sh|')
        
        if [[ -z "$github_url" ]]; then
            github_url="https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/Arch/monitor-manager.sh"
        fi
        
        log_warn "Daemon script not found locally, downloading from: $github_url"
        if ! curl -sSL "$github_url" -o "$daemon_dest"; then
            log_error "Failed to download daemon script"
            echo -e "${RED}ERROR: Failed to download daemon script from $github_url${NC}"
            exit 1
        fi
    fi
    
    chmod +x "$daemon_dest"
    log "Daemon installed to: $daemon_dest"
    echo -e "${GREEN}Daemon installed successfully.${NC}"
}

# Create systemd user service
create_systemd_service() {
    log "Creating systemd user service..."
    
    local service_dir="$USER_HOME/.config/systemd/user"
    local service_file="$service_dir/monitor-manager.service"
    
    # Create directory
    sudo -u "$ACTUAL_USER" mkdir -p "$service_dir"
    
    # Create service file
    log "Creating service file: $service_file"
    sudo -u "$ACTUAL_USER" tee "$service_file" > /dev/null <<'EOF'
[Unit]
Description=Monitor Manager Daemon
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monitor-manager.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    
    log "Systemd service created successfully"
    echo -e "${GREEN}Systemd service created successfully.${NC}"
}

# Enable and start service
enable_service() {
    log "Enabling and starting monitor-manager service..."
    
    # Reload systemd user daemon
    sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" systemctl --user daemon-reload
    
    # Enable and start the service
    sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" systemctl --user enable monitor-manager.service
    sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" systemctl --user start monitor-manager.service
    
    log "Service enabled and started successfully"
    echo -e "${GREEN}Service enabled and started successfully.${NC}"
}

# Show status
show_status() {
    echo ""
    echo -e "${BLUE}=== Monitor Manager Status ===${NC}"
    echo ""
    
    local config_file="$USER_HOME/.config/monitor-manager/config"
    
    if [[ -f "$config_file" ]]; then
        echo -e "${GREEN}Configuration:${NC}"
        cat "$config_file" | grep -v "^#" | grep -v "^$"
        echo ""
    else
        echo -e "${YELLOW}No configuration found.${NC}"
        echo ""
    fi
    
    echo -e "${GREEN}Service Status:${NC}"
    sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" systemctl --user status monitor-manager.service --no-pager || true
    echo ""
    
    echo -e "${GREEN}Recent Logs:${NC}"
    local log_file="$USER_HOME/.local/share/monitor-manager/monitor-manager.log"
    if [[ -f "$log_file" ]]; then
        tail -n 20 "$log_file"
    else
        echo "No logs found."
    fi
    echo ""
}

# Uninstall
uninstall() {
    log "Uninstalling monitor-manager..."
    
    echo -e "${YELLOW}Stopping and disabling service...${NC}"
    sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" systemctl --user stop monitor-manager.service 2>/dev/null || true
    sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" systemctl --user disable monitor-manager.service 2>/dev/null || true
    
    echo -e "${YELLOW}Removing files...${NC}"
    rm -f "/usr/local/bin/monitor-manager.sh"
    rm -f "$USER_HOME/.config/systemd/user/monitor-manager.service"
    
    sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" systemctl --user daemon-reload
    
    echo ""
    echo -e "${GREEN}Monitor Manager uninstalled successfully.${NC}"
    echo -e "${YELLOW}Note: Configuration files in ~/.config/monitor-manager were preserved.${NC}"
    echo -e "${YELLOW}To remove them: rm -rf ~/.config/monitor-manager${NC}"
    echo ""
    
    log "Uninstall completed"
}

# Main installation
install() {
    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}    Monitor Manager Installer${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo ""
    
    # Create log file
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    
    log "Starting Monitor Manager installation..."
    
    install_dependencies
    
    # Run TUI setup
    if ! run_tui_setup; then
        log_error "Setup cancelled or failed"
        echo -e "${RED}Setup cancelled or failed.${NC}"
        exit 1
    fi
    
    install_daemon
    create_systemd_service
    enable_service
    
    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}    Installation Complete!${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo ""
    echo -e "${GREEN}Monitor Manager is now running.${NC}"
    echo ""
    echo -e "Configuration: ${BLUE}~/.config/monitor-manager/config${NC}"
    echo -e "Logs: ${BLUE}~/.local/share/monitor-manager/monitor-manager.log${NC}"
    echo ""
    echo -e "Commands:"
    echo -e "  ${BLUE}sudo $0 status${NC}     - Show current status"
    echo -e "  ${BLUE}sudo $0 setup${NC}      - Reconfigure monitors"
    echo -e "  ${BLUE}sudo $0 uninstall${NC}  - Remove monitor manager"
    echo ""
    
    log "Installation completed successfully"
}

# Show main menu
show_main_menu() {
    local choice
    choice=$(whiptail --title "Monitor Manager" \
        --menu "Choose an action:" \
        18 70 4 \
        "1" "Setup/Install - Configure and install monitor manager" \
        "2" "Status - Show current configuration and service status" \
        "3" "Uninstall - Remove monitor manager" \
        "4" "Exit" \
        3>&1 1>&2 2>&3)
    
    case "$choice" in
        1)
            install
            ;;
        2)
            show_status
            echo ""
            read -p "Press Enter to continue..."
            show_main_menu
            ;;
        3)
            if whiptail --title "Confirm Uninstall" --yesno "Are you sure you want to uninstall Monitor Manager?" 10 60; then
                uninstall
            else
                show_main_menu
            fi
            ;;
        4|"")
            echo "Exiting..."
            exit 0
            ;;
        *)
            show_main_menu
            ;;
    esac
}

# Main execution
main() {
    check_root
    get_user
    
    local command="${1:-}"
    
    # If no command provided, show TUI menu
    if [[ -z "$command" ]]; then
        # Create log file
        touch "$LOG_FILE"
        chmod 640 "$LOG_FILE"
        
        # Install dependencies first (needed for whiptail)
        install_dependencies
        
        # Show main menu
        show_main_menu
    else
        # Command line argument provided
        case "$command" in
            install|setup)
                install
                ;;
            status)
                show_status
                ;;
            uninstall)
                uninstall
                ;;
            *)
                echo "Usage: $0 [install|setup|status|uninstall]"
                echo ""
                echo "Or run without arguments for interactive menu."
                exit 1
                ;;
        esac
    fi
}

main "$@"
