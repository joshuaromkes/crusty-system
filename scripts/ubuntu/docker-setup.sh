#!/bin/bash
#
# Docker Setup Script for Debian/Ubuntu
# Installs Docker Engine from official repo, Docker Compose plugin,
# and configures daemon with security best practices.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOCKER_USER=""
PRUNE_CRON=false
NON_INTERACTIVE=false
LOG_FILE="/var/log/docker-setup.log"
DAEMON_JSON="/etc/docker/daemon.json"
PRUNE_CRON_FILE="/etc/cron.d/crusty-docker-prune"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install Docker Engine from the official Docker repository on Debian/Ubuntu.
Installs the Docker Compose plugin and configures the daemon with security
best practices (log rotation, no-new-privileges, live-restore).

OPTIONS:
  --user USER          Add USER to the docker group
  --prune-cron         Install a weekly cron job to prune unused Docker data
  --non-interactive    Skip all prompts
  --help, -h           Show this help

Examples:
  sudo $0
  sudo $0 --user myuser --prune-cron
  sudo $0 --non-interactive --prune-cron
EOF
    exit 0
}

log()    { printf "${GREEN}[%s]${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${GREEN}[%s]${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_warn() { printf "${YELLOW}[%s] WARNING:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${YELLOW}[%s] WARNING:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_error() { printf "${RED}[%s] ERROR:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${RED}[%s] ERROR:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
log_info() { printf "${BLUE}[%s] INFO:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" 2>/dev/null || printf "${BLUE}[%s] INFO:${NC} %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                DOCKER_USER="$2"; shift 2 ;;
            --prune-cron)
                PRUNE_CRON=true; shift ;;
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
            --help|-h)
                usage ;;
            *)
                log_error "Unknown option: $1"
                echo "Run with --help for usage."
                exit 1 ;;
        esac
    done
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS: /etc/os-release not found"
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_error "This script only supports Debian and Ubuntu (detected: $ID)"
        exit 1
    fi
    log_info "Detected: $PRETTY_NAME"
}

remove_old_docker() {
    if dpkg -l 2>/dev/null | grep -qE '^ii\s+(docker\.io|docker-compose|docker-compose-v2|docker-doc|podman-docker)\s'; then
        log "Removing old Docker packages..."
        apt-get remove -y -qq docker.io docker-compose docker-compose-v2 docker-doc podman-docker 2>/dev/null || true
    fi
}

install_docker_repo() {
    if command -v docker &>/dev/null && docker --version &>/dev/null; then
        log_info "Docker is already installed: $(docker --version)"
        return 0
    fi

    log "Setting up Docker repository..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    local arch
    arch="$(dpkg --print-architecture)"
    local repo_entry="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable"

    if ! grep -qF "$repo_entry" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
        echo "$repo_entry" > /etc/apt/sources.list.d/docker.list
    fi

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log "Docker Engine installed: $(docker --version)"
}

configure_daemon() {
    local desired
    desired=$(cat << 'DAEMON_EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "live-restore": true,
  "userland-proxy": false
}
DAEMON_EOF
)

    if [[ ! -f "$DAEMON_JSON" ]]; then
        log "Creating Docker daemon configuration with security best practices..."
        echo "$desired" > "$DAEMON_JSON"
        systemctl restart docker
        log "Docker daemon configured and restarted"
        return 0
    fi

    local missing=false
    for key in "no-new-privileges" "live-restore" "log-driver" "userland-proxy"; do
        if ! grep -q "\"$key\"" "$DAEMON_JSON"; then
            missing=true
            break
        fi
    done

    if [[ "$missing" == false ]]; then
        log_info "Docker daemon already configured with security settings"
        return 0
    fi

    log_warn "daemon.json exists but missing some security keys — overwriting"
    echo "$desired" > "$DAEMON_JSON"

    systemctl restart docker
    log "Docker daemon configured and restarted"
}

add_user_to_docker_group() {
    if [[ -z "$DOCKER_USER" ]]; then
        return 0
    fi

    if ! id "$DOCKER_USER" &>/dev/null; then
        log_error "User '$DOCKER_USER' does not exist"
        exit 1
    fi

    if groups "$DOCKER_USER" 2>/dev/null | grep -q '\bdocker\b'; then
        log_info "User '$DOCKER_USER' is already in the docker group"
        return 0
    fi

    log "Adding user '$DOCKER_USER' to docker group..."
    usermod -aG docker "$DOCKER_USER"
    log "User '$DOCKER_USER' added to docker group (re-login required to take effect)"
}

configure_prune_cron() {
    if [[ "$PRUNE_CRON" != true ]]; then
        return 0
    fi

    if [[ -f "$PRUNE_CRON_FILE" ]]; then
        log_info "Docker prune cron already configured"
        return 0
    fi

    log "Setting up weekly Docker prune cron job..."
    cat > "$PRUNE_CRON_FILE" << 'EOF'
# Crusty System - Weekly Docker system prune (Sunday 03:00)
SHELL=/bin/bash
0 3 * * 0 root /usr/bin/docker system prune -af --volumes --filter "until=168h" 2>&1 | logger -t crusty-docker-prune
EOF
    chmod 644 "$PRUNE_CRON_FILE"
    log "Docker prune cron installed (weekly Sunday 03:00)"
}

main() {
    parse_args "$@"

    # Handle --help before root check
    check_root

    echo ""
    printf "${GREEN}==========================================\n"
    printf "    Docker Setup${NC}\n"
    printf "${GREEN}    Crusty System${NC}\n"
    printf "${GREEN}==========================================${NC}\n\n"

    log "Starting Docker setup..."

    detect_os
    remove_old_docker
    install_docker_repo
    configure_daemon
    add_user_to_docker_group
    configure_prune_cron

    echo ""
    echo "=========================================="
    log "Docker Setup Complete!"
    echo "=========================================="
    echo ""
    printf "${GREEN}Installed:${NC}\n"
    echo "  - Docker Engine: $(docker --version 2>/dev/null || echo 'check with: docker --version')"
    echo "  - Docker Compose: $(docker compose version 2>/dev/null || echo 'check with: docker compose version')"
    echo ""
    printf "${GREEN}Daemon settings (${DAEMON_JSON}):${NC}\n"
    echo "  - Log rotation: max-size=10m, max-file=3"
    echo "  - no-new-privileges: true"
    echo "  - live-restore: true"
    echo "  - userland-proxy: false"
    echo ""

    if [[ -n "$DOCKER_USER" ]]; then
        printf "${YELLOW}User '$DOCKER_USER' added to docker group.${NC}\n"
        printf "${YELLOW}Log out and back in for group membership to take effect.${NC}\n"
    fi

    if [[ "$PRUNE_CRON" == true ]]; then
        echo "  - Docker prune cron: weekly Sunday 03:00"
    fi
    echo ""
}

main "$@"
