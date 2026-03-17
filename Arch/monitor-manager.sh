#!/bin/bash
#
# Monitor Manager Daemon
# Automatically manages dummy/primary monitor switching for KDE Plasma Wayland
#
# This script runs as a user service and polls monitor status every few seconds.
# When the primary monitor is connected, it disables the dummy monitor.
# When the primary monitor is disconnected, it enables the dummy monitor.
#
# Config: ~/.config/monitor-manager/config
# Log: ~/.local/share/monitor-manager/monitor-manager.log

set -euo pipefail

# Config paths
CONFIG_DIR="${HOME}/.config/monitor-manager"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="${HOME}/.local/share/monitor-manager"
LOG_FILE="${LOG_DIR}/monitor-manager.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Source config file
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    # Validate required variables
    if [[ -z "${primary_output:-}" ]] || [[ -z "${dummy_output:-}" ]]; then
        log_error "Config missing required variables: primary_output, dummy_output"
        exit 1
    fi
    
    # Set defaults
    poll_interval="${poll_interval:-5}"
    dummy_position="${dummy_position:-1920,0}"
    dummy_mode="${dummy_mode:-}"
    
    log "Loaded config: primary=$primary_output, dummy=$dummy_output, poll=${poll_interval}s"
}

# Check if kscreen-doctor is available
check_kscreen() {
    if ! command -v kscreen-doctor &> /dev/null; then
        log_error "kscreen-doctor not found. Please install kscreen package."
        exit 1
    fi
}

# Parse kscreen-doctor output to check if output is connected and enabled
# Returns: "connected enabled", "connected disabled", "disconnected", or "unknown"
get_output_status() {
    local output_name="$1"
    local kscreen_output
    
    kscreen_output=$(kscreen-doctor -o 2>/dev/null || echo "")
    
    if [[ -z "$kscreen_output" ]]; then
        echo "unknown"
        return
    fi
    
    # Parse output line for the specified output using awk for robust field extraction
    # Example: "Output: 123 HDMI-A-1 enabled connected priority 1"
    # Fields: $1=Output: $2=ID $3=NAME $4+=status_words
    local output_line
    output_line=$(echo "$kscreen_output" | awk -v name="$output_name" '$3 == name {print}' || echo "")
    
    if [[ -z "$output_line" ]]; then
        echo "unknown"
        return
    fi
    
    # Extract status words (everything after field 3)
    local status_words
    status_words=$(echo "$output_line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i}')
    
    local is_connected=false
    local is_enabled=false
    
    if echo "$status_words" | grep -qw "connected"; then
        is_connected=true
    fi
    
    if echo "$status_words" | grep -qw "enabled"; then
        is_enabled=true
    fi
    
    if [[ "$is_connected" == true ]] && [[ "$is_enabled" == true ]]; then
        echo "connected enabled"
    elif [[ "$is_connected" == true ]] && [[ "$is_enabled" == false ]]; then
        echo "connected disabled"
    elif [[ "$is_connected" == false ]]; then
        echo "disconnected"
    else
        echo "unknown"
    fi
}

# Enable dummy monitor with position and mode
enable_dummy() {
    log "Enabling dummy monitor: $dummy_output"
    
    local cmd="kscreen-doctor output.${dummy_output}.enable"
    
    # Add position if specified
    if [[ -n "$dummy_position" ]]; then
        cmd="$cmd output.${dummy_output}.position.${dummy_position}"
    fi
    
    # Add mode if specified
    if [[ -n "$dummy_mode" ]]; then
        cmd="$cmd output.${dummy_output}.mode.${dummy_mode}"
    fi
    
    # Set dummy as primary when primary is not connected
    cmd="$cmd output.${dummy_output}.primary"
    
    if eval "$cmd" &>> "$LOG_FILE"; then
        log "Dummy monitor enabled successfully"
        return 0
    else
        log_error "Failed to enable dummy monitor"
        return 1
    fi
}

# Disable dummy monitor
disable_dummy() {
    log "Disabling dummy monitor: $dummy_output"
    
    if kscreen-doctor "output.${dummy_output}.disable" &>> "$LOG_FILE"; then
        log "Dummy monitor disabled successfully"
        return 0
    else
        log_error "Failed to disable dummy monitor"
        return 1
    fi
}

# Set primary monitor
set_primary() {
    local output="$1"
    log "Setting primary monitor: $output"
    
    if kscreen-doctor "output.${output}.primary" &>> "$LOG_FILE"; then
        log "Primary monitor set successfully"
        return 0
    else
        log_error "Failed to set primary monitor"
        return 1
    fi
}

# Main monitoring loop
monitor_loop() {
    log "Starting monitor management loop (poll interval: ${poll_interval}s)"
    
    local last_primary_status=""
    local last_dummy_status=""
    
    while true; do
        # Get current status
        local primary_status
        local dummy_status
        
        primary_status=$(get_output_status "$primary_output")
        dummy_status=$(get_output_status "$dummy_output")
        
        # Only log status changes to reduce log spam
        if [[ "$primary_status" != "$last_primary_status" ]] || [[ "$dummy_status" != "$last_dummy_status" ]]; then
            log "Status: primary=$primary_status, dummy=$dummy_status"
            last_primary_status="$primary_status"
            last_dummy_status="$dummy_status"
        fi
        
        # Decision logic
        if [[ "$primary_status" == "connected enabled" ]] || [[ "$primary_status" == "connected disabled" ]]; then
            # Primary is connected - ensure it's enabled and set as primary
            if [[ "$primary_status" == "connected disabled" ]]; then
                log "Primary monitor connected but disabled, enabling..."
                kscreen-doctor "output.${primary_output}.enable" &>> "$LOG_FILE" || true
            fi
            
            # Set primary as primary display
            set_primary "$primary_output"
            
            # Disable dummy if it's enabled
            if [[ "$dummy_status" == "connected enabled" ]]; then
                disable_dummy
            fi
        else
            # Primary is not connected - enable dummy
            if [[ "$dummy_status" == "connected disabled" ]] || [[ "$dummy_status" == "disconnected" ]]; then
                enable_dummy
            elif [[ "$dummy_status" == "connected enabled" ]]; then
                # Dummy already enabled, ensure it's primary
                set_primary "$dummy_output"
            fi
        fi
        
        # Sleep before next poll
        sleep "$poll_interval"
    done
}

# Main execution
main() {
    log "=== Monitor Manager Daemon Starting ==="
    
    check_kscreen
    load_config
    
    # Start monitoring loop
    monitor_loop
}

# Handle signals for graceful shutdown
trap 'log "Received shutdown signal, exiting..."; exit 0' SIGTERM SIGINT

main "$@"
