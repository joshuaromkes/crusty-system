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
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables (will be set by user prompts)
SSH_PORT=58432
USE_FAIL2BAN=true
ENABLE_AUTO_UPDATES=true
UPDATE_HOUR="02"
UPDATE_MINUTE="00"
SKIP_VERIFICATION=false
USER_PUBLIC_KEY=""
BACKUP_DIR="/root/crusty-backups-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/ssh-hardener.log"
TEST_PORT=62222

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

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
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

# Function to display SSH key generation instructions
show_key_generation_instructions() {
    echo ""
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW}    SSH KEY GENERATION INSTRUCTIONS${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo -e "${BLUE}You must generate an SSH key pair on your CLIENT machine${NC}"
    echo -e "${BLUE}(the computer you will use to connect to this server)${NC}"
    echo ""
    echo "The private key stays on your client machine."
    echo "You will provide the PUBLIC key to this script."
    echo ""
    echo -e "${GREEN}--- Windows (OpenSSH - Windows 10/11) ---${NC}"
    echo "1. Open PowerShell or Command Prompt"
    echo "2. Run: ssh-keygen -t ed25519 -C \"your_email@example.com\""
    echo "3. Press Enter to accept default location"
    echo "4. Enter a passphrase (recommended) or press Enter for none"
    echo "5. Your public key is at: C:\\Users\\YOUR_USERNAME\\.ssh\\id_ed25519.pub"
    echo ""
    echo -e "${GREEN}--- Windows (PuTTY) ---${NC}"
    echo "1. Download PuTTYgen from: https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html"
    echo "2. Open PuTTYgen, select 'Ed25519' as the key type"
    echo "3. Click 'Generate' and move your mouse randomly"
    echo "4. Add a passphrase (optional but recommended)"
    echo "5. Save the private key (.ppk file) to your computer"
    echo "6. Copy the public key text from the box at the top"
    echo ""
    echo -e "${GREEN}--- Linux / macOS ---${NC}"
    echo "1. Open a terminal"
    echo "2. Run: ssh-keygen -t ed25519 -C \"your_email@example.com\""
    echo "3. Press Enter to accept default location (~/.ssh/id_ed25519)"
    echo "4. Enter a passphrase (recommended) or press Enter for none"
    echo "5. Your public key is at: ~/.ssh/id_ed25519.pub"
    echo "6. View it with: cat ~/.ssh/id_ed25519.pub"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Keep your private key secret!${NC}"
    echo -e "${YELLOW}Only share the PUBLIC key (ends in .pub)${NC}"
    echo ""
    echo -e "${BLUE}Press Enter when you have generated your SSH key pair...${NC}"
    read -r < /dev/tty
}

# Function to prompt user for their public key
prompt_public_key() {
    echo ""
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW}    SSH PUBLIC KEY CONFIGURATION${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo "Please paste your SSH PUBLIC key below."
    echo "The key should look like one of these formats:"
    echo "  ssh-ed25519 AAAAC3NzaC... user@hostname"
    echo "  ssh-rsa AAAAB3NzaC1yc... user@hostname"
    echo ""
    echo -e "${RED}DO NOT paste your private key here!${NC}"
    echo ""
    
    local key_valid=false
    while [[ "$key_valid" == false ]]; do
        echo -e "${BLUE}Paste your public key (then press Enter):${NC}"
        read -r USER_PUBLIC_KEY < /dev/tty
        
        # Trim whitespace
        USER_PUBLIC_KEY=$(echo "$USER_PUBLIC_KEY" | xargs)
        
        # Validate key format
        if [[ -z "$USER_PUBLIC_KEY" ]]; then
            echo -e "${RED}ERROR: Key cannot be empty.${NC}"
            continue
        fi
        
        # Check for common key types
        if [[ "$USER_PUBLIC_KEY" =~ ^ssh-(ed25519|rsa|ecdsa|dsa)[[:space:]]+[A-Za-z0-9+/]+[=]{0,2} ]]; then
            key_valid=true
            log "Valid SSH public key provided"
            echo -e "${GREEN}Public key accepted.${NC}"
        else
            echo -e "${RED}ERROR: This doesn't look like a valid SSH public key.${NC}"
            echo "A valid key starts with 'ssh-ed25519', 'ssh-rsa', 'ssh-ecdsa', or 'ssh-dsa'"
            echo ""
            local retry
            read -rp "Try again? (yes/no): " retry < /dev/tty
            case "$retry" in
                [Nn][Oo])
                    log_error "User declined to provide valid SSH key"
                    echo "Exiting. You must provide a valid SSH public key to continue."
                    exit 1
                    ;;
            esac
        fi
    done
}

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

# Function to prompt for verification skip
prompt_skip_verification() {
    echo ""
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW}    CONNECTION VERIFICATION${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo "This script can test your SSH connection before fully locking down the server."
    echo "This helps prevent being locked out due to configuration errors."
    echo ""
    echo "The test will:"
    echo "  1. Configure SSH on a temporary test port ($TEST_PORT)"
    echo "  2. Wait for you to test the connection from your client"
    echo "  3. Only apply the final configuration if the test succeeds"
    echo ""
    echo -e "${RED}WARNING: If you skip verification and the configuration is wrong,${NC}"
    echo -e "${RED}you may be permanently locked out of your server!${NC}"
    echo ""
    
    local response
    while true; do
        read -rp "Do you want to skip connection verification? (yes/no) [default: no]: " response < /dev/tty
        response=${response:-no}
        case "$response" in
            [Yy][Ee][Ss])
                SKIP_VERIFICATION=true
                log_warn "User chose to skip connection verification"
                echo -e "${YELLOW}Verification skipped. Proceeding without testing.${NC}"
                return 0
                ;;
            [Nn][Oo])
                SKIP_VERIFICATION=false
                log "User chose to enable connection verification"
                echo -e "${GREEN}Connection verification enabled.${NC}"
                return 0
                ;;
            *)
                echo "Please answer 'yes' or 'no'."
                ;;
        esac
    done
}

# Function to setup authorized_keys with user public key
setup_authorized_keys() {
    local ssh_dir="/root/.ssh"
    local auth_keys_file="$ssh_dir/authorized_keys"
    
    log "Setting up authorized_keys..."
    
    # Create .ssh directory if it doesn't exist
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    # Create or truncate authorized_keys file
    touch "$auth_keys_file"
    chmod 600 "$auth_keys_file"
    
    # Add user's public key
    echo "$USER_PUBLIC_KEY" > "$auth_keys_file"
    log "User's public key added to authorized_keys"
}

# Function to create SSH config for testing
create_test_ssh_config() {
    log "Creating test SSH configuration on port $TEST_PORT..."
    
    # Backup current config
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.pre-test"
    
    # Create test config that listens on both current port and test port
    cat > /etc/ssh/sshd_config << EOF
# SSH Test Configuration - Generated by Crusty System
# This is a TEST configuration for verification purposes

# Port configuration - listening on both ports for testing
Port 22
Port $TEST_PORT

# Protocol and authentication
Protocol 2
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
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
    
    # Restart SSH to apply test config
    systemctl restart sshd || systemctl restart ssh
    
    # Open test port in firewall temporarily
    ufw allow "$TEST_PORT"/tcp comment 'SSH Test Port' 2>/dev/null || true
    
    log "Test SSH configuration active on port $TEST_PORT"
}

# Function to wait for user to test connection
wait_for_connection_test() {
    echo ""
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW}    TEST YOUR SSH CONNECTION${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo -e "${GREEN}The server is now configured for testing.${NC}"
    echo ""
    echo "From your CLIENT machine, test the connection with:"
    echo ""
    echo -e "${BLUE}  ssh -p $TEST_PORT root@$(hostname -I | awk '{print $1}')${NC}"
    echo ""
    echo "Make sure you can connect successfully before continuing."
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC} This test uses your provided public key."
    echo "If the connection fails, check that:"
    echo "  1. Your private key is loaded (ssh-add or Pageant)"
    echo "  2. You provided the correct public key"
    echo "  3. The key permissions are correct on your client"
    echo ""
    
    local response
    while true; do
        read -rp "Did the SSH connection test succeed? (yes/no): " response < /dev/tty
        case "$response" in
            [Yy][Ee][Ss])
                log "User confirmed successful SSH connection test"
                echo -e "${GREEN}Great! Proceeding with final configuration.${NC}"
                return 0
                ;;
            [Nn][Oo])
                log_error "SSH connection test failed"
                echo ""
                echo -e "${RED}The SSH connection test failed.${NC}"
                echo ""
                echo "Options:"
                echo "  1. Check your SSH key setup and try again"
                echo "  2. View the SSH logs: tail -f /var/log/auth.log"
                echo "  3. Exit and troubleshoot manually"
                echo ""
                local retry
                read -rp "Do you want to try again? (yes/no): " retry < /dev/tty
                case "$retry" in
                    [Yy][Ee][Ss])
                        echo ""
                        echo "Make sure your SSH key is correct, then test again."
                        echo ""
                        ;;
                    *)
                        log "Rolling back test configuration..."
                        rollback_test_config
                        echo "Test configuration removed. Exiting."
                        exit 1
                        ;;
                esac
                ;;
            *)
                echo "Please answer 'yes' or 'no'."
                ;;
        esac
    done
}

# Function to rollback test configuration
rollback_test_config() {
    log "Rolling back test configuration..."
    
    # Remove test port from firewall
    ufw delete allow "$TEST_PORT"/tcp 2>/dev/null || true
    
    # Restore original config if backup exists
    if [[ -f "$BACKUP_DIR/sshd_config.pre-test" ]]; then
        cp "$BACKUP_DIR/sshd_config.pre-test" /etc/ssh/sshd_config
        systemctl restart sshd || systemctl restart ssh
        log "Original SSH configuration restored"
    fi
}

# Function to apply final SSH configuration
apply_final_ssh_config() {
    log "Applying final SSH configuration..."
    
    # Remove test port from firewall
    ufw delete allow "$TEST_PORT"/tcp 2>/dev/null || true
    
    # Create final hardened sshd_config
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
    
    # Restart SSH service
    systemctl restart sshd || systemctl restart ssh
    
    log "Final SSH configuration applied on port $SSH_PORT"
}

# Main execution starts here

# Check and install OpenSSH server before proceeding
check_and_install_openssh

# Show key generation instructions
show_key_generation_instructions

# Get user's public key
prompt_public_key

# Run configuration prompts
prompt_confirmation
prompt_fail2ban
prompt_ssh_port
prompt_auto_updates
prompt_skip_verification

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

# Setup authorized_keys with user's public key
setup_authorized_keys

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

# Test mode or direct application
if [[ "$SKIP_VERIFICATION" == true ]]; then
    log_warn "Skipping verification - applying configuration directly"
    apply_final_ssh_config
else
    # Test mode
    create_test_ssh_config
    wait_for_connection_test
    apply_final_ssh_config
fi

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
echo -e "${GREEN}Your public key has been added to authorized_keys.${NC}"
echo ""
echo -e "${YELLOW}Backup Location:${NC}"
echo "  $BACKUP_DIR"
echo ""
echo -e "${YELLOW}Log File:${NC}"
echo "  $LOG_FILE"
echo ""
echo -e "${RED}IMPORTANT:${NC}"
echo "  - Password authentication is now DISABLED"
echo "  - You MUST use your SSH key to connect"
echo "  - Keep your private key safe - there is no password fallback!"
echo ""
