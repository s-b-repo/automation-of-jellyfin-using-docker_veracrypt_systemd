#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly DEFAULT_CONFIG_DIR="/opt/jellyfin/config"
readonly DEFAULT_CACHE_DIR="/opt/jellyfin/cache"
readonly DEFAULT_MEDIA_HOME="/home"
readonly DEFAULT_VERA1="/run/media/veracrypt1"
readonly DEFAULT_VERA2="/run/media/veracrypt2"
readonly DEFAULT_CONTAINER_NAME="jellyfin"
readonly DEFAULT_IMAGE_NAME="jellyfin/jellyfin:latest"
readonly DEFAULT_SERVICE_NAME="jellyfin-docker"
readonly DEFAULT_PORT="8096"
readonly CONF_FILE="/etc/jellyfin-docker.conf"
readonly BACKUP_DIR="/opt/jellyfin/backups"
readonly HEALTH_TIMEOUT=60

# Load overrides from config file if it exists
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

CONFIG_DIR="${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
CACHE_DIR="${CACHE_DIR:-$DEFAULT_CACHE_DIR}"
MEDIA_HOME="${MEDIA_HOME:-$DEFAULT_MEDIA_HOME}"
VERA1="${VERA1:-$DEFAULT_VERA1}"
VERA2="${VERA2:-$DEFAULT_VERA2}"
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
PORT="${PORT:-$DEFAULT_PORT}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENABLE_HW_ACCEL="${ENABLE_HW_ACCEL:-auto}"

# --- OUTPUT HELPERS ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*" >&2; }
error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
die()     { error "$@"; exit 1; }

header() {
    echo
    printf "${BOLD}%s${RESET}\n" "$1"
    printf '%*s\n' "${#1}" '' | tr ' ' '-'
}

confirm() {
    local prompt="${1:-Continue?}"
    local ans
    read -rp "  $prompt [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# --- PREREQUISITE CHECKS ---

check_root() {
    if [[ $EUID -eq 0 ]]; then
        die "Do not run this script as root. It uses sudo where needed."
    fi
}

check_command() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        if [[ -n "$install_hint" ]]; then
            die "'$cmd' is not installed. Install it with: $install_hint"
        else
            die "'$cmd' is required but not installed."
        fi
    fi
}

check_docker_running() {
    if ! sudo docker info &>/dev/null; then
        die "Docker daemon is not running. Start it with: sudo systemctl start docker"
    fi
}

check_prerequisites() {
    info "Checking prerequisites..."
    check_root
    check_command docker "sudo apt install docker.io  OR  see https://docs.docker.com/engine/install/"
    check_command systemctl
    check_command curl
    check_docker_running
    success "All prerequisites met."
}

# --- VERACRYPT HELPERS ---

is_mounted() {
    mountpoint -q "$1" 2>/dev/null
}

check_veracrypt_mounts() {
    local volumes=()
    local missing=()

    for vol in "$VERA1" "$VERA2"; do
        if is_mounted "$vol"; then
            volumes+=("$vol")
            success "VeraCrypt volume mounted: $vol"
        else
            missing+=("$vol")
            warn "VeraCrypt volume NOT mounted: $vol"
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo
        warn "Some VeraCrypt volumes are not mounted."
        warn "Jellyfin will not have access to media on unmounted volumes."
        echo
        if ! confirm "Continue anyway?"; then
            die "Aborted. Mount your VeraCrypt volumes first."
        fi
    fi

    AVAILABLE_VERA_VOLUMES=("${volumes[@]}")
}

# --- HARDWARE ACCELERATION ---

detect_hw_accel() {
    local hw_args=()

    if [[ "$ENABLE_HW_ACCEL" == "none" ]]; then
        info "Hardware acceleration disabled by config."
        HW_ACCEL_ARGS=()
        return
    fi

    if [[ -e /dev/dri/renderD128 ]]; then
        info "VA-API device detected (/dev/dri/renderD128)."
        hw_args+=(--device /dev/dri/renderD128:/dev/dri/renderD128)
    fi

    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        info "NVIDIA GPU detected."
        hw_args+=(--runtime=nvidia)
        hw_args+=(--gpus all)
    fi

    if [[ ${#hw_args[@]} -eq 0 ]]; then
        info "No hardware acceleration devices found. Using software transcoding."
    fi

    HW_ACCEL_ARGS=("${hw_args[@]}")
}

# --- BACKUP ---

backup_config() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        info "No config directory to back up."
        return
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/jellyfin_config_${timestamp}.tar.gz"

    info "Backing up config to $backup_path..."
    sudo mkdir -p "$BACKUP_DIR"
    sudo tar -czf "$backup_path" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")"
    success "Config backed up: $backup_path"
}

# --- CONTAINER OPERATIONS ---

container_exists() {
    sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

container_running() {
    sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

remove_container() {
    if container_exists; then
        info "Removing existing container '$CONTAINER_NAME'..."
        sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
        sudo docker rm "$CONTAINER_NAME"
        success "Container removed."
    fi
}

build_volume_args() {
    local vol_args=()
    vol_args+=(--volume "${CONFIG_DIR}:/config")
    vol_args+=(--volume "${CACHE_DIR}:/cache")
    vol_args+=(--volume "${MEDIA_HOME}:/media/home:ro")

    for vol in "${AVAILABLE_VERA_VOLUMES[@]:-}"; do
        [[ -z "$vol" ]] && continue
        local basename
        basename=$(basename "$vol")
        vol_args+=(--volume "${vol}:/media/${basename}:ro")
    done

    VOLUME_ARGS=("${vol_args[@]}")
}

create_container() {
    local uid gid
    uid=$(id -u)
    gid=$(id -g)

    build_volume_args

    info "Creating Jellyfin container..."
    sudo docker run -d \
        --name "$CONTAINER_NAME" \
        --user "${uid}:${gid}" \
        --net=host \
        "${VOLUME_ARGS[@]}" \
        "${HW_ACCEL_ARGS[@]:+${HW_ACCEL_ARGS[@]}}" \
        --restart=unless-stopped \
        "$IMAGE_NAME"
    success "Container '$CONTAINER_NAME' created."
}

wait_for_healthy() {
    info "Waiting for Jellyfin to respond on port $PORT (up to ${HEALTH_TIMEOUT}s)..."

    local elapsed=0
    while [[ $elapsed -lt $HEALTH_TIMEOUT ]]; do
        if curl -sf "http://localhost:${PORT}/health" &>/dev/null ||
           curl -sf "http://localhost:${PORT}/web/index.html" &>/dev/null; then
            success "Jellyfin is up and responding."
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    warn "Jellyfin did not respond within ${HEALTH_TIMEOUT}s."
    warn "It may still be starting. Check logs: sudo docker logs -f $CONTAINER_NAME"
    return 1
}

# --- SYSTEMD SERVICE ---

install_service() {
    if [[ -f "$SERVICE_FILE" ]]; then
        info "Systemd service already exists. Updating..."
    fi

    info "Writing systemd service: $SERVICE_FILE"
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Jellyfin Media Server (Docker)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
ExecStartPre=-/usr/bin/docker stop ${CONTAINER_NAME}
ExecStart=/usr/bin/docker start -a ${CONTAINER_NAME}
ExecStop=/usr/bin/docker stop -t 15 ${CONTAINER_NAME}
TimeoutStartSec=0
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    success "Service installed and enabled."
}

# --- MAIN COMMANDS ---

cmd_setup() {
    header "Jellyfin Full Setup"
    check_prerequisites
    check_veracrypt_mounts
    detect_hw_accel

    if container_exists; then
        warn "Existing container detected."
        if confirm "Back up current config before proceeding?"; then
            backup_config
        fi
        remove_container
    fi

    info "Creating directories..."
    sudo mkdir -p "$CONFIG_DIR" "$CACHE_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$CONFIG_DIR" "$CACHE_DIR"
    success "Directories ready."

    info "Pulling image: $IMAGE_NAME"
    sudo docker pull "$IMAGE_NAME"
    success "Image pulled."

    create_container
    install_service

    sudo systemctl start "$SERVICE_NAME"
    success "Service started."

    wait_for_healthy || true
    show_access_info
}

cmd_update() {
    header "Update Jellyfin"
    check_prerequisites

    if ! container_exists; then
        die "No existing container found. Run setup first."
    fi

    info "Pulling latest image..."
    local old_image
    old_image=$(sudo docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    sudo docker pull "$IMAGE_NAME"

    local new_image
    new_image=$(sudo docker image inspect --format='{{.Id}}' "$IMAGE_NAME" 2>/dev/null || echo "unknown")

    if [[ "$old_image" == "$new_image" ]]; then
        success "Already running the latest image. No update needed."
        return
    fi

    info "New image available. Recreating container..."
    check_veracrypt_mounts
    detect_hw_accel

    if confirm "Back up config before updating?"; then
        backup_config
    fi

    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    remove_container
    create_container
    install_service
    sudo systemctl start "$SERVICE_NAME"
    success "Jellyfin updated and restarted."

    wait_for_healthy || true
    show_access_info
}

cmd_restart() {
    header "Restart Jellyfin"

    if ! container_exists; then
        die "No container found. Run setup first."
    fi

    info "Restarting via systemd..."
    sudo systemctl restart "$SERVICE_NAME"
    success "Jellyfin restarted."

    wait_for_healthy || true
}

cmd_stop() {
    header "Stop Jellyfin"

    info "Stopping service..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    success "Jellyfin stopped."
}

cmd_status() {
    header "Jellyfin Status"

    echo
    printf "${BOLD}Container:${RESET} "
    if container_running; then
        printf "${GREEN}running${RESET}\n"
    elif container_exists; then
        printf "${YELLOW}stopped${RESET}\n"
    else
        printf "${RED}not found${RESET}\n"
    fi

    printf "${BOLD}Service:${RESET}   "
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        printf "${GREEN}active${RESET}\n"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        printf "${YELLOW}enabled but inactive${RESET}\n"
    else
        printf "${RED}not installed${RESET}\n"
    fi

    printf "${BOLD}Image:${RESET}     "
    if container_exists; then
        sudo docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown"
    else
        echo "N/A"
    fi

    printf "${BOLD}VeraCrypt:${RESET}\n"
    for vol in "$VERA1" "$VERA2"; do
        if is_mounted "$vol"; then
            printf "  ${GREEN}mounted${RESET}  %s\n" "$vol"
        else
            printf "  ${RED}missing${RESET}  %s\n" "$vol"
        fi
    done

    if container_running; then
        echo
        info "Container details:"
        sudo docker ps --filter "name=$CONTAINER_NAME" --format "table {{.ID}}\t{{.Status}}\t{{.Ports}}"
    fi

    echo
    if curl -sf "http://localhost:${PORT}/health" &>/dev/null ||
       curl -sf "http://localhost:${PORT}/web/index.html" &>/dev/null; then
        success "Web UI responding on port $PORT."
    else
        warn "Web UI not responding on port $PORT."
    fi
}

cmd_logs() {
    if ! container_exists; then
        die "No container found."
    fi
    local lines="${1:-100}"
    sudo docker logs --tail "$lines" -f "$CONTAINER_NAME"
}

cmd_backup() {
    header "Backup Jellyfin Config"
    backup_config
}

cmd_uninstall() {
    header "Uninstall Jellyfin"

    warn "This will remove the Jellyfin container, service, and optionally config/cache."
    echo
    if ! confirm "Are you sure?"; then
        die "Aborted."
    fi

    if confirm "Back up config first?"; then
        backup_config
    fi

    info "Stopping and removing service..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload

    info "Removing container..."
    remove_container

    if confirm "Also remove config and cache directories? ($CONFIG_DIR, $CACHE_DIR)"; then
        sudo rm -rf "$CONFIG_DIR" "$CACHE_DIR"
        success "Config and cache removed."
    else
        info "Config and cache preserved."
    fi

    if confirm "Remove the Docker image ($IMAGE_NAME)?"; then
        sudo docker rmi "$IMAGE_NAME" 2>/dev/null || true
        success "Image removed."
    fi

    success "Jellyfin uninstalled."
}

show_access_info() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    echo
    printf "${BOLD}Access Jellyfin:${RESET}\n"
    echo "  Local:   http://localhost:${PORT}"
    if [[ -n "${ip:-}" ]]; then
        echo "  Network: http://${ip}:${PORT}"
    fi
    echo
    printf "${BOLD}Management:${RESET}\n"
    echo "  Status:   $0 status"
    echo "  Logs:     $0 logs"
    echo "  Restart:  $0 restart"
    echo "  Update:   $0 update"
    echo "  Stop:     $0 stop"
    echo "  Backup:   $0 backup"
    echo "  Uninstall:$0 uninstall"
}

usage() {
    cat <<EOF
Jellyfin Docker Setup & Management v${SCRIPT_VERSION}

Usage: $0 [COMMAND]

Commands:
  setup       Full installation (create dirs, pull image, start container, install service)
  update      Pull latest image and recreate container (preserves config)
  restart     Restart the Jellyfin container via systemd
  stop        Stop the Jellyfin container and service
  status      Show container, service, and mount status
  logs [N]    Follow container logs (last N lines, default 100)
  backup      Back up the Jellyfin config directory
  uninstall   Remove container, service, and optionally config/cache
  help        Show this help message

If no command is given, an interactive menu is shown.

Configuration:
  Override defaults by creating $CONF_FILE with variable assignments:
    CONFIG_DIR="/opt/jellyfin/config"
    CACHE_DIR="/opt/jellyfin/cache"
    MEDIA_HOME="/home"
    VERA1="/run/media/veracrypt1"
    VERA2="/run/media/veracrypt2"
    CONTAINER_NAME="jellyfin"
    IMAGE_NAME="jellyfin/jellyfin:latest"
    PORT="8096"
    ENABLE_HW_ACCEL="auto"    # auto, none

EOF
}

interactive_menu() {
    clear
    printf "${BOLD}================================================${RESET}\n"
    printf "${BOLD}  Jellyfin Docker Setup & Management v%s${RESET}\n" "$SCRIPT_VERSION"
    printf "${BOLD}================================================${RESET}\n"
    echo

    if container_exists; then
        local state="stopped"
        container_running && state="running"
        warn "Existing container detected (${state})."
        echo
        echo "  [1] Restart"
        echo "  [2] Full reset (backup + reinstall)"
        echo "  [3] Update image"
        echo "  [4] Status"
        echo "  [5] View logs"
        echo "  [6] Stop"
        echo "  [7] Backup config"
        echo "  [8] Uninstall"
        echo "  [0] Exit"
        echo
        local choice
        read -rp "  Choose [0-8]: " choice
        case "$choice" in
            1) cmd_restart ;;
            2) cmd_setup ;;
            3) cmd_update ;;
            4) cmd_status ;;
            5) cmd_logs ;;
            6) cmd_stop ;;
            7) cmd_backup ;;
            8) cmd_uninstall ;;
            0) exit 0 ;;
            *) die "Invalid option." ;;
        esac
    else
        info "No existing Jellyfin container found."
        echo
        if confirm "Run full setup?"; then
            cmd_setup
        else
            info "Nothing to do."
        fi
    fi
}

# --- ENTRYPOINT ---

main() {
    case "${1:-}" in
        setup)     cmd_setup ;;
        update)    cmd_update ;;
        restart)   cmd_restart ;;
        stop)      cmd_stop ;;
        status)    cmd_status ;;
        logs)      cmd_logs "${2:-100}" ;;
        backup)    cmd_backup ;;
        uninstall) cmd_uninstall ;;
        help|--help|-h)
                   usage ;;
        "")        interactive_menu ;;
        *)         error "Unknown command: $1"
                   usage
                   exit 1 ;;
    esac
}

main "$@"
