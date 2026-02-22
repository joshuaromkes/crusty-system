#!/bin/bash
#
# SSH Hardener Script for Ubuntu Server
# Configures SSH security, firewall, fail2ban, and automatic updates
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables (will be set by user prompts)
SSH_PORT=58432
USE_FAIL2BAN=true
ENABLE_AUTO_UPDATES=true
UPDATE_HOUR="02"
UPDATE_MINUTE="00"
BACKUP_DIR="/root/crusty-backups-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/ssh-hardener.log"

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

# Function to check and install OpenSSH server
check_and_install_openssh() {
    log "Checking for OpenSSH server installation..."
    
    # Check if sshd command exists
    if command -v sshd &> /dev/null; then
        log "OpenSSH server is already installed"
        return 0
    fi
    
    # Check if openssh-server package is installed
    if dpkg -l | grep -q "^ii  openssh-server"; then
        log "OpenSSH server package is installed but sshd not in PATH"
        return 0
    fi
    
    log_warn "OpenSSH server is not installed"
    echo ""
    echo -e "${YELLOW}OpenSSH server is required for this script to function.${NC}"
    echo "It provides the SSH daemon (sshd) that allows remote SSH connections."
    echo ""
    
    local response
    while true; do
        read -rp "Do you want to install OpenSSH server now? (yes/no) [default: yes]: " response < /dev/tty
        response=${response:-yes}
        case "$response" in
            [Yy][Ee][Ss])
                log "Installing OpenSSH server..."
                echo -e "${GREEN}Installing OpenSSH server...${NC}"
                if apt-get update -qq && apt-get install -y -qq openssh-server; then
                    log "OpenSSH server installed successfully"
                    echo -e "${GREEN}OpenSSH server installed successfully!${NC}"
                    
                    # Start and enable the SSH service
                    systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
                    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
                    
                    return 0
                else
                    log_error "Failed to install OpenSSH server"
                    echo -e "${RED}ERROR: Failed to install OpenSSH server.${NC}"
                    echo "Please install it manually and run this script again."
                    exit 1
                fi
                ;;
            [Nn][Oo])
                log_error "OpenSSH server is required. Exiting."
                echo -e "${RED}ERROR: OpenSSH server is required for SSH hardening.${NC}"
                echo "Please install it manually and run this script again."
                exit 1
                ;;
            *)
                echo "Please answer 'yes' or 'no'."
                ;;
        esac
    done
}

# Check and install OpenSSH server before proceeding
check_and_install_openssh

# Function to prompt user for confirmation to proceed
prompt_confirmation() {
    echo ""
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW}    SSH HARDENER CONFIGURATION${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo "This script will make significant changes to your SSH configuration:"
    echo "  - Change the SSH port from default (22) to a custom port"
    echo "  - Disable password authentication (key-based only)"
    echo "  - Disable root login"
    echo "  - Configure firewall rules"
    echo "  - Optionally install and configure fail2ban"
    echo "  - Optionally configure automatic updates"
    echo ""
    echo -e "${RED}WARNING: After running this script, you will need to:${NC}"
    echo "  - Use the new SSH port to connect"
    echo "  - Use SSH key authentication (passwords will not work)"
    echo "  - Configure your SSH clients with the new settings"
    echo ""
    
    local response
    while true; do
        read -rp "Do you wish to proceed with SSH hardening? (yes/no): " response < /dev/tty
        case "$response" in
            [Yy][Ee][Ss])
                log "User confirmed proceeding with SSH hardening"
                return 0
                ;;
            [Nn][Oo])
                log "User declined SSH hardening. Exiting."
                echo "Exiting without making changes."
                exit 0
                ;;
            *)
                echo "Please answer 'yes' or 'no'."
                ;;
        esac
    done
}

# Function to prompt user for fail2ban preference
prompt_fail2ban() {
    echo ""
    echo -e "${YELLOW}=== Fail2ban Configuration ===${NC}"
    echo ""
    echo "Fail2ban provides intrusion prevention by monitoring log files"
    echo "and banning IPs that show malicious signs (e.g., brute force attacks)."
    echo ""
    
    local response
    while true; do
        read -rp "Do you wish to use fail2ban for intrusion prevention? (yes/no) [default: yes]: " response < /dev/tty
        response=${response:-yes}
        case "$response" in
            [Yy][Ee][Ss])
                USE_FAIL2BAN=true
                log "User chose to enable fail2ban"
                echo -e "${GREEN}Fail2ban will be installed and configured.${NC}"
                return 0
                ;;
            [Nn][Oo])
                USE_FAIL2BAN=false
                log "User chose to skip fail2ban"
                echo -e "${YELLOW}Fail2ban will be skipped.${NC}"
                return 0
                ;;
            *)
                echo "Please answer 'yes' or 'no'."
                ;;
        esac
    done
}

# Function to prompt user for SSH port with validation
prompt_ssh_port() {
    echo ""
    echo -e "${YELLOW}=== SSH Port Configuration ===${NC}"
    echo ""
    echo "Please specify the desired SSH port."
    echo "Valid range: 1-65535"
    echo "Commonly used ports to avoid: 22 (default SSH), 80 (HTTP), 443 (HTTPS)"
    echo ""
    
    local valid=false
    local port_input
    
    while [[ "$valid" == false ]]; do
        read -rp "Enter SSH port [default: 58432]: " port_input < /dev/tty
        port_input=${port_input:-58432}
        
        # Check if input is a number
        if [[ "$port_input" =~ ^[0-9]+$ ]]; then
            # Check if port is in valid range
            if [[ "$port_input" -ge 1 && "$port_input" -le 65535 ]]; then
                # Check for commonly used ports
                if [[ "$port_input" -eq 22 ]]; then
                    echo -e "${RED}ERROR: Port 22 is the default SSH port. Using it defeats the purpose of hardening.${NC}"
                    echo "Please choose a different port."
                elif [[ "$port_input" -eq 80 ]]; then
                    echo -e "${RED}ERROR: Port 80 is used for HTTP. Please choose a different port.${NC}"
                elif [[ "$port_input" -eq 443 ]]; then
                    echo -e "${RED}ERROR: Port 443 is used for HTTPS. Please choose a different port.${NC}"
                elif [[ "$port_input" -lt 1024 ]]; then
                    echo -e "${YELLOW}WARNING: Ports below 1024 require root privileges and are often reserved.${NC}"
                    local confirm
                    read -rp "Are you sure you want to use port $port_input? (yes/no): " confirm < /dev/tty
                    case "$confirm" in
                        [Yy][Ee][Ss])
                            valid=true
                            ;;
                        *)
                            echo "Please choose a different port."
                            ;;
                    esac
                else
                    valid=true
                fi
            else
                echo -e "${RED}ERROR: Port must be between 1 and 65535.${NC}"
            fi
        else
            echo -e "${RED}ERROR: Please enter a valid number.${NC}"
        fi
    done
    
    SSH_PORT=$port_input
    echo ""
    echo -e "${GREEN}SSH port set to: $SSH_PORT${NC}"
    log "SSH port configured: $SSH_PORT"
}

# Function to prompt user for automatic updates preference
prompt_auto_updates() {
    echo ""
    echo -e "${YELLOW}=== Automatic Updates Configuration ===${NC}"
    echo ""
    echo "Automatic updates help keep your system secure by installing"
    echo "security patches and updates on a regular schedule."
    echo ""
    
    local response
    while true; do
        read -rp "Do you want to enable automatic updates? (yes/no) [default: yes]: " response < /dev/tty
        response=${response:-yes}
        case "$response" in
            [Yy][Ee][Ss])
                ENABLE_AUTO_UPDATES=true
                log "User chose to enable automatic updates"
                echo -e "${GREEN}Automatic updates will be configured.${NC}"
                prompt_update_time
                return 0
                ;;
            [Nn][Oo])
                ENABLE_AUTO_UPDATES=false
                log "User chose to skip automatic updates"
                echo -e "${YELLOW}Automatic updates will not be configured.${NC}"
                return 0
                ;;
            *)
                echo "Please answer 'yes' or 'no'."
                ;;
        esac
    done
}

# Function to prompt user for update time with input validation
prompt_update_time() {
    echo ""
    echo "Please specify when you'd like automatic updates to run."
    echo "Enter time in 24-hour format (HH:MM), e.g., 02:00 for 2:00 AM"
    echo ""
    
    local valid=false
    local hour
    local minute
    
    while [[ "$valid" == false ]]; do
        read -rp "Enter update time (HH:MM) [default: 02:00]: " time_input < /dev/tty
        time_input=${time_input:-02:00}
        
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
    echo -e "${GREEN}Update time set to: ${UPDATE_HOUR}:${UPDATE_MINUTE} (weekly on Sunday)${NC}"
    log "Automatic update time configured: ${UPDATE_HOUR}:${UPDATE_MINUTE}"
}

# Run all prompts
prompt_confirmation
prompt_fail2ban
prompt_ssh_port
prompt_auto_updates

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}    Starting SSH Hardening Process${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""

log "Starting SSH Hardener Script..."

# Create backup directory
mkdir -p "$BACKUP_DIR"
log "Created backup directory: $BACKUP_DIR"

# Backup existing configurations
backup_config() {
    if [[ -f "$1" ]]; then
        cp "$1" "$BACKUP_DIR/"
        log "Backed up: $1"
    fi
}

backup_config "/etc/ssh/sshd_config"
backup_config "/etc/ufw/default"
backup_config "/etc/fail2ban/jail.local" 2>/dev/null || true

# Update system packages
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# Install required packages
log "Installing required packages..."
if [[ "$USE_FAIL2BAN" == true ]]; then
    apt-get install -y -qq ufw fail2ban
else
    apt-get install -y -qq ufw
fi

# Generate ED25519 SSH key pair for the current user
generate_ssh_keys() {
    local ssh_dir="/root/.ssh"
    local key_file="$ssh_dir/id_ed25519"
    
    # Check if key already exists
    if [[ -f "$key_file" ]]; then
        log_warn "SSH key already exists at $key_file, skipping generation"
        return 0
    fi
    
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    log "Generating ED25519 SSH key pair..."
    ssh-keygen -t ed25519 -f "$key_file" -N "" -C "root@$(hostname)"
    chmod 600 "$key_file"
    chmod 644 "${key_file}.pub"
    
    # Add to authorized_keys if not already present
    if [[ ! -f "$ssh_dir/authorized_keys" ]]; then
        touch "$ssh_dir/authorized_keys"
        chmod 600 "$ssh_dir/authorized_keys"
    fi
    
    cat "${key_file}.pub" >> "$ssh_dir/authorized_keys"
    log "SSH key generated and added to authorized_keys"
}

generate_ssh_keys

# Configure SSH
configure_ssh() {
    log "Configuring SSH..."
    
    # Backup original sshd_config
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.original"
    
    # Create new sshd_config with security best practices
    cat > /etc/ssh/sshd_config << EOF
# SSH Hardened Configuration - Generated by Crusty System
# Port configuration
Port $SSH_PORT

# Protocol and authentication
Protocol 2
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Key algorithms
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# Security settings
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

# Connection settings
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
MaxAuthTries 3
MaxStartups 10:30:60

# Logging
SyslogFacility AUTH
LogLevel VERBOSE
EOF
    
    log "SSH configuration updated"
}

configure_ssh

# Configure UFW Firewall
configure_firewall() {
    log "Configuring UFW firewall..."
    
    # Reset UFW to defaults
    ufw --force reset
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH on custom port
    ufw allow "$SSH_PORT"/tcp comment 'SSH'
    
    # Enable logging
    ufw logging on
    
    # Enable UFW
    ufw --force enable
    
    log "UFW firewall configured - SSH allowed on port $SSH_PORT"
}

configure_firewall

# Configure Fail2ban (conditional)
configure_fail2ban() {
    if [[ "$USE_FAIL2BAN" != true ]]; then
        log "Skipping fail2ban configuration (user opted out)"
        return 0
    fi
    
    log "Configuring Fail2ban..."
    
    # Create jail.local configuration
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Ban duration (10 minutes)
bantime = 600

# Time window for counting failures
findtime = 600

# Number of failures before ban
maxretry = 3

# Backend for log monitoring
backend = auto

# Email notifications (optional - configure if needed)
# destemail = your-email@example.com
# sendername = Fail2Ban
# mta = sendmail

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
    
    # Enable and restart fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    log "Fail2ban configured and started"
}

configure_fail2ban

# Configure automatic updates (conditional)
configure_auto_updates() {
    if [[ "$ENABLE_AUTO_UPDATES" != true ]]; then
        log "Skipping automatic updates configuration (user opted out)"
        return 0
    fi
    
    log "Configuring automatic updates..."
    
    # Install unattended-upgrades if not present
    apt-get install -y -qq unattended-upgrades
    
    # Configure unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
    
    # Configure which packages to update automatically
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
    
    # Add weekly update cron job at user-specified time (matching auto-update.sh format)
    cat > /etc/cron.d/crusty-auto-update << EOF
# Crusty System - Weekly automatic updates at ${UPDATE_HOUR}:${UPDATE_MINUTE}
${UPDATE_MINUTE} ${UPDATE_HOUR} * * 0 root /usr/bin/apt-get update && /usr/bin/apt-get upgrade -y
EOF
    chmod 644 /etc/cron.d/crusty-auto-update
    
    log "Automatic updates configured (weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE})"
}

configure_auto_updates

# Restart SSH service
log "Restarting SSH service..."
systemctl restart sshd

# Display summary
echo ""
echo "=========================================="
log "SSH Hardening Complete!"
echo "=========================================="
echo ""
echo -e "${GREEN}Configuration Summary:${NC}"
echo "  - SSH Port: $SSH_PORT"
echo "  - Root Login: Disabled"
echo "  - Password Authentication: Disabled"
echo "  - Key-based Authentication: Enabled"
echo "  - Firewall: UFW enabled"
if [[ "$USE_FAIL2BAN" == true ]]; then
    echo "  - Intrusion Prevention: Fail2ban active"
else
    echo "  - Intrusion Prevention: Fail2ban skipped"
fi
if [[ "$ENABLE_AUTO_UPDATES" == true ]]; then
    echo "  - Automatic Updates: Weekly at ${UPDATE_HOUR}:${UPDATE_MINUTE}"
else
    echo "  - Automatic Updates: Not configured"
fi
echo ""
echo -e "${YELLOW}SSH Connection Info:${NC}"
echo "  ssh -p $SSH_PORT root@$(hostname -I | awk '{print $1}')"
echo ""
echo -e "${GREEN}Public Key (add this to your SSH client):${NC}"
cat /root/.ssh/id_ed25519.pub
echo ""
echo -e "${YELLOW}Private Key Location:${NC}"
echo "  /root/.ssh/id_ed25519"
echo ""
echo -e "${YELLOW}Backup Location:${NC}"
echo "  $BACKUP_DIR"
echo ""
echo -e "${YELLOW}Log File:${NC}"
echo "  $LOG_FILE"
echo ""
echo -e "${RED}IMPORTANT: Save your SSH keys before closing this session!${NC}"
echo ""
