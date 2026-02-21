#!/bin/bash
#
# Auto Update Script for Ubuntu Server
# Configures automatic weekly system updates
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CRON_FILE="/etc/cron.d/crusty-auto-update"

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root${NC}"
        exit 1
    fi
}

# Function to prompt user for update time with input validation
prompt_update_time() {
    local hour
    local minute
    local valid=false

    echo ""
    echo -e "${YELLOW}=== Automatic Update Schedule Configuration ===${NC}"
    echo ""
    echo "Please specify when you'd like automatic updates to run."
    echo "Enter time in 24-hour format (HH:MM), e.g., 02:00 for 2:00 AM"
    echo ""

    while [[ "$valid" == false ]]; do
        read -rp "Enter update time (HH:MM): " time_input < /dev/tty

        # Check if input matches HH:MM format
        if [[ "$time_input" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
            hour="${BASH_REMATCH[1]}"
            minute="${BASH_REMATCH[2]}"

            # Validate hour (0-23)
            if [[ "$hour" -ge 0 && "$hour" -le 23 ]]; then
                # Validate minute (0-59)
                if [[ "$minute" -ge 0 && "$minute" -le 59 ]]; then
                    valid=true
                else
                    echo -e "${RED}ERROR: Invalid minutes. Please enter a value between 00 and 59.${NC}"
                fi
            else
                echo -e "${RED}ERROR: Invalid hour. Please enter a value between 00 and 23.${NC}"
            fi
        else
            echo -e "${RED}ERROR: Invalid format. Please use HH:MM format (e.g., 02:00, 14:30)${NC}"
        fi
    done

    # Format with leading zeros
    printf -v UPDATE_HOUR "%02d" "$hour"
    printf -v UPDATE_MINUTE "%02d" "$minute"

    echo ""
    echo -e "${GREEN}Update time set to: ${UPDATE_HOUR}:${UPDATE_MINUTE}${NC}"
}

# Function to create cron job
create_cron_job() {
    echo -e "${GREEN}Creating weekly update cron job for ${UPDATE_HOUR}:${UPDATE_MINUTE}...${NC}"
    cat > "$CRON_FILE" << EOF
# Crusty System - Weekly automatic updates at ${UPDATE_HOUR}:${UPDATE_MINUTE}
${UPDATE_MINUTE} ${UPDATE_HOUR} * * 0 root /usr/bin/apt-get update && /usr/bin/apt-get upgrade -y
EOF
    chmod 644 "$CRON_FILE"
}

# Function to run updates immediately
run_updates_now() {
    echo ""
    echo -e "${GREEN}Starting immediate system update...${NC}"
    echo ""

    echo -e "${YELLOW}Running: apt-get update${NC}"
    if apt-get update; then
        echo -e "${GREEN}Package list updated successfully.${NC}"
    else
        echo -e "${RED}ERROR: Failed to update package list.${NC}"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}Running: apt-get upgrade -y${NC}"
    if apt-get upgrade -y; then
        echo -e "${GREEN}System packages upgraded successfully.${NC}"
    else
        echo -e "${RED}ERROR: Failed to upgrade packages.${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Update completed.${NC}"
}

# Function to prompt for immediate update
prompt_run_now() {
    echo ""
    echo -e "${YELLOW}=== Run Updates Now ===${NC}"
    echo ""
    read -rp "Would you like to run system updates now? [y/N]: " run_now < /dev/tty

    if [[ "$run_now" =~ ^[Yy]$ ]]; then
        run_updates_now
    else
        echo -e "${GREEN}Skipping immediate update.${NC}"
    fi
}

# Function to uninstall auto-updates
uninstall_auto_updates() {
    echo -e "${GREEN}Starting uninstallation of auto-update configuration...${NC}"

    # Remove cron job
    if [[ -f "$CRON_FILE" ]]; then
        echo -e "${GREEN}Removing cron job: $CRON_FILE${NC}"
        rm -f "$CRON_FILE"
    else
        echo -e "${YELLOW}Cron job not found at $CRON_FILE${NC}"
    fi

    echo ""
    echo "=========================================="
    echo -e "${GREEN}Uninstallation Complete!${NC}"
    echo "=========================================="
    echo ""
    echo -e "${GREEN}Removed:${NC}"
    echo "  - Cron job: $CRON_FILE"
    echo ""
}

# Function to display current configuration
show_config() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Current Auto-Update Configuration${NC}"
    echo "=========================================="
    echo ""

    if [[ -f "$CRON_FILE" ]]; then
        echo -e "${GREEN}Cron Job:${NC}"
        echo "  Schedule: Weekly on Sunday"
        grep -v "^#" "$CRON_FILE" | head -1
        echo ""
    else
        echo -e "${YELLOW}No cron job found.${NC}"
    fi
    echo ""
}

# Function to display usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  install     Install and configure auto-updates (default)"
    echo "  uninstall   Remove auto-update configuration and files"
    echo "  status      Show current auto-update configuration"
    echo "  run-now     Trigger system updates immediately"
    echo "  --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo $0 install"
    echo "  sudo $0 uninstall"
    echo "  sudo $0 run-now"
    echo ""
}

# Main installation function
install_auto_updates() {
    echo -e "${GREEN}Starting Auto Update Setup...${NC}"

    # Prompt for update time
    prompt_update_time

    # Create cron job
    create_cron_job

    # Display summary
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Auto Update Setup Complete!${NC}"
    echo "=========================================="
    echo ""
    echo -e "${GREEN}Configuration Summary:${NC}"
    echo "  - Update Schedule: Weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE} (Sunday)"
    echo ""

    # Ask if user wants to run updates now
    prompt_run_now

    echo ""
    echo -e "${GREEN}To manually trigger an update later, run:${NC}"
    echo "  sudo apt-get update && sudo apt-get upgrade -y"
    echo ""
}

# Main script logic
main() {
    check_root

    case "${1:-install}" in
        install)
            install_auto_updates
            ;;
        uninstall)
            uninstall_auto_updates
            ;;
        status)
            show_config
            ;;
        run-now)
            run_updates_now
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            echo -e "${RED}ERROR: Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
