#!/bin/bash
#
# setup_jellyfin.sh — Interactive Jellyfin Docker setup + systemd management
#

set -e  # Exit on error

# --- CONFIGURABLE VARIABLES ---
CONFIG_DIR="/opt/jellyfin/config"
CACHE_DIR="/opt/jellyfin/cache"
MEDIA_HOME="/home"
VERA1="/run/media/veracrypt1"
VERA2="/run/media/veracrypt2"
CONTAINER_NAME="jellyfin"
IMAGE_NAME="jellyfin/jellyfin:latest"
SERVICE_NAME="jellyfin-docker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- HELPER FUNCTIONS ---
confirm() {
    read -p "➡️  $1 [y/N]: " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

restart_all() {
    echo "🔁 Restarting Jellyfin container and service..."
    sudo systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    sudo docker restart "$CONTAINER_NAME" 2>/dev/null || true
    echo "✅ Jellyfin restarted."
    exit 0
}

full_setup() {
    echo
    echo "🧩 Proceeding with full Jellyfin setup..."
    echo "-----------------------------------------"

    # STEP 1: Create necessary directories
    echo "📁 Creating Jellyfin directories..."
    sudo mkdir -p "$CONFIG_DIR" "$CACHE_DIR"
    echo "✅ Directories created: $CONFIG_DIR, $CACHE_DIR"

    # STEP 2: Fix ownership and permissions
    echo "🔧 Setting permissions so your user can access config/cache..."
    sudo chown -R $(id -u):$(id -g) "$CONFIG_DIR" "$CACHE_DIR"
    sudo chmod -R 755 "$CONFIG_DIR" "$CACHE_DIR"
    echo "✅ Permissions fixed."

    # STEP 3: Remove old container if it exists
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "🧹 Removing existing Jellyfin container..."
        sudo docker rm -f "$CONTAINER_NAME"
        echo "✅ Old container removed."
    fi

    # STEP 4: Pull latest image
    echo "⬇️ Pulling latest Jellyfin Docker image..."
    sudo docker pull "$IMAGE_NAME"
    echo "✅ Image pulled."

    # STEP 5: Run Jellyfin container
    echo "🚀 Starting Jellyfin container..."
    sudo docker run -d \
        --name "$CONTAINER_NAME" \
        --user $(id -u):$(id -g) \
        --net=host \
        --volume "$CONFIG_DIR":/config \
        --volume "$CACHE_DIR":/cache \
        --volume "$MEDIA_HOME":/media/home:ro \
        --volume "$VERA1":/media/veracrypt1:ro \
        --volume "$VERA2":/media/veracrypt2:ro \
        --restart=unless-stopped \
        "$IMAGE_NAME"
    echo "✅ Jellyfin container launched."

    # STEP 6: Create systemd service if not present
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo "🧩 Creating systemd service for Jellyfin..."
        sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=Jellyfin Media Server (Docker)
After=network.target docker.service
Requires=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a ${CONTAINER_NAME}
ExecStop=/usr/bin/docker stop -t 10 ${CONTAINER_NAME}
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
        echo "✅ Service file created at: $SERVICE_FILE"
    else
        echo "ℹ️  Systemd service already exists. Skipping creation."
    fi

    # STEP 7: Enable and start the service
    echo "🔄 Enabling and starting Jellyfin service..."
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    echo "✅ Jellyfin systemd service active."

    # STEP 8: Show container status
    echo
    echo "🔍 Current container status:"
    sudo docker ps --filter "name=$CONTAINER_NAME"

    echo
    echo "🌐 Access Jellyfin at:"
    echo "   → http://localhost:8096"
    echo "   → or http://$(hostname -I | awk '{print $1}'):8096 from your network"
    echo
    echo "📜 Logs:     sudo docker logs -f $CONTAINER_NAME"
    echo "🛑 Stop:     sudo systemctl stop $SERVICE_NAME"
    echo "▶️ Start:    sudo systemctl start $SERVICE_NAME"
    echo "♻️ Restart:  sudo systemctl restart $SERVICE_NAME"
    echo "🚫 Disable:  sudo systemctl disable $SERVICE_NAME"
}

# --- MAIN LOGIC ---
clear
echo "=============================================="
echo "  🧠 Jellyfin Docker Setup & Management Script"
echo "=============================================="
echo

# Check if container exists
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "⚠️  Existing Jellyfin container detected!"
    echo
    echo "Options:"
    echo "  [1] Restart container & service (use this if you just mounted drives)"
    echo "  [2] Full reset (remove old setup and reinstall everything)"
    echo "  [3] Cancel"
    read -p "➡️  Choose an option [1-3]: " choice
    case "$choice" in
        1) restart_all ;;
        2) full_setup ;;
        *) echo "❌ Cancelled."; exit 0 ;;
    esac
else
    echo "No existing Jellyfin container found."
    if confirm "Do you want to perform a full setup?"; then
        full_setup
    else
        echo "❌ Setup cancelled."
        exit 0
    fi
fi
