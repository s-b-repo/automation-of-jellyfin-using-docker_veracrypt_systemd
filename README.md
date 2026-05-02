# Jellyfin Docker + VeraCrypt + systemd Automation

A single-script solution for deploying and managing a [Jellyfin](https://jellyfin.org/) media server inside Docker, with first-class support for [VeraCrypt](https://www.veracrypt.fr/) encrypted volumes and automatic [systemd](https://systemd.io/) service management.

Built for serving personal media — YouTube downloads, music, documentaries, memes, and anything else you keep on encrypted drives.

## Features

- **One-command setup** — pulls the Jellyfin Docker image, creates directories, launches the container, and installs a systemd service
- **VeraCrypt integration** — auto-detects whether your encrypted volumes are mounted and bind-mounts them read-only into the container
- **Hardware acceleration** — auto-detects VA-API (Intel/AMD) and NVIDIA GPUs for hardware transcoding
- **Systemd service** — Jellyfin starts on boot automatically with proper dependency ordering and failure recovery
- **Config backup** — timestamped tar.gz snapshots before any destructive operation
- **Health checks** — waits for the Jellyfin web UI to respond after start/restart/update
- **Image updates** — pull the latest Jellyfin image and recreate the container without losing config
- **Clean uninstall** — removes container, service, and optionally config/cache/image
- **Config file overrides** — customize all paths, ports, and behavior via `/etc/jellyfin-docker.conf`
- **Interactive + CLI modes** — use the menu for quick operations or CLI commands for scripting

## Requirements

| Dependency | Purpose |
|---|---|
| **Docker** | Container runtime |
| **systemd** | Service management |
| **curl** | Health check probes |
| **sudo** | Privileged operations (the script must NOT be run as root) |
| **VeraCrypt** (optional) | Encrypted volume mounts |

### Supported Platforms

Tested on Debian/Ubuntu-based distributions (including Kali Linux). Should work on any Linux distribution with Docker and systemd.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/s-b-repo/automation-of-jellyfin-using-docker_veracrypt_systemd.git
cd automation-of-jellyfin-using-docker_veracrypt_systemd

# Make executable and run
chmod +x setup_jellyfin.sh
./setup_jellyfin.sh setup
```

After setup completes, Jellyfin is available at **http://localhost:8096**.

## Usage

### CLI Commands

```bash
./setup_jellyfin.sh <command>
```

| Command | Description |
|---|---|
| `setup` | Full installation — create dirs, pull image, start container, install service |
| `update` | Pull latest Jellyfin image and recreate container (preserves config) |
| `restart` | Restart the container via systemd |
| `stop` | Stop the container and service |
| `status` | Show container state, service state, VeraCrypt mounts, and web UI health |
| `logs [N]` | Follow container logs (last N lines, default 100) |
| `backup` | Back up the Jellyfin config directory to a timestamped archive |
| `uninstall` | Remove container, service, and optionally config/cache/image |
| `help` | Show help message |

Running with no arguments launches an **interactive menu**.

### Interactive Menu

```
================================================
  Jellyfin Docker Setup & Management v2.0.0
================================================

  [1] Restart
  [2] Full reset (backup + reinstall)
  [3] Update image
  [4] Status
  [5] View logs
  [6] Stop
  [7] Backup config
  [8] Uninstall
  [0] Exit
```

## Configuration

Override any default by creating `/etc/jellyfin-docker.conf`:

```bash
# Jellyfin directories
CONFIG_DIR="/opt/jellyfin/config"
CACHE_DIR="/opt/jellyfin/cache"

# Media sources
MEDIA_HOME="/home"
VERA1="/run/media/veracrypt1"
VERA2="/run/media/veracrypt2"

# Docker settings
CONTAINER_NAME="jellyfin"
IMAGE_NAME="jellyfin/jellyfin:latest"
PORT="8096"

# Hardware acceleration: "auto" (detect) or "none" (disable)
ENABLE_HW_ACCEL="auto"
```

### Default Paths

| Path | Purpose |
|---|---|
| `/opt/jellyfin/config` | Jellyfin server configuration and database |
| `/opt/jellyfin/cache` | Transcoding cache and temp files |
| `/opt/jellyfin/backups` | Config backup archives |
| `/run/media/veracrypt1` | First VeraCrypt encrypted volume |
| `/run/media/veracrypt2` | Second VeraCrypt encrypted volume |

### Container Volume Mapping

| Host Path | Container Path | Mode |
|---|---|---|
| Config dir | `/config` | read-write |
| Cache dir | `/cache` | read-write |
| Media home | `/media/home` | read-only |
| VeraCrypt 1 | `/media/veracrypt1` | read-only |
| VeraCrypt 2 | `/media/veracrypt2` | read-only |

Media volumes are mounted **read-only** — Jellyfin can read and stream but cannot modify your files.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  systemd (jellyfin-docker.service)                  │
│    Starts on boot, restarts on failure (10s delay)  │
├─────────────────────────────────────────────────────┤
│  Docker Container (jellyfin/jellyfin:latest)        │
│    --net=host (port 8096)                           │
│    --user <your-uid>:<your-gid>                     │
│    --restart=unless-stopped                         │
├──────────┬──────────┬───────────────────────────────┤
│  /config │  /cache  │  /media/*  (read-only)        │
└──────────┴──────────┴───────────────────────────────┘
        │         │         │
   /opt/jellyfin/ │    /home, /run/media/veracrypt{1,2}
                  │
          /opt/jellyfin/cache
```

### Networking

The container runs with `--net=host`, meaning it shares the host's network stack directly. Jellyfin binds to port **8096** on all interfaces. No port mapping or bridge configuration is needed.

### Hardware Acceleration

The script auto-detects available hardware:

- **VA-API** (Intel/AMD) — detected via `/dev/dri/renderD128`, passed through with `--device`
- **NVIDIA** — detected via `nvidia-smi`, enabled with `--runtime=nvidia --gpus all`

Set `ENABLE_HW_ACCEL="none"` in the config file to force software transcoding.

After setup, enable hardware transcoding in the Jellyfin dashboard under **Settings > Playback > Transcoding**.

### systemd Service

The generated service file (`/etc/systemd/system/jellyfin-docker.service`):

- Starts after `network-online.target` and `docker.service`
- Restarts on failure with a 10-second delay (prevents tight restart loops)
- Gracefully stops the container with a 15-second timeout
- Pre-stop ensures any stale container is cleaned up before starting

Manual service control:

```bash
sudo systemctl start jellyfin-docker
sudo systemctl stop jellyfin-docker
sudo systemctl restart jellyfin-docker
sudo systemctl status jellyfin-docker
sudo journalctl -u jellyfin-docker -f
```

## VeraCrypt Workflow

A typical workflow for using Jellyfin with encrypted media:

```bash
# 1. Mount your VeraCrypt volumes
veracrypt /path/to/volume1 /run/media/veracrypt1
veracrypt /path/to/volume2 /run/media/veracrypt2

# 2. Start (or restart) Jellyfin so it picks up the mounts
./setup_jellyfin.sh restart

# 3. When done, stop Jellyfin and dismount
./setup_jellyfin.sh stop
veracrypt -d
```

The script validates mounts before setup/update and warns you if volumes are missing, giving you the option to continue without them.

## Backup & Recovery

Backups are stored as timestamped archives in `/opt/jellyfin/backups/`:

```
/opt/jellyfin/backups/
  jellyfin_config_20260502_143022.tar.gz
  jellyfin_config_20260510_091500.tar.gz
```

To restore a backup:

```bash
# Stop Jellyfin
./setup_jellyfin.sh stop

# Extract backup over the config directory
sudo tar -xzf /opt/jellyfin/backups/jellyfin_config_TIMESTAMP.tar.gz -C /opt/jellyfin/

# Restart
./setup_jellyfin.sh restart
```

## Troubleshooting

| Problem | Solution |
|---|---|
| "Docker daemon is not running" | `sudo systemctl start docker` |
| "Do not run this script as root" | Run as your normal user — the script uses `sudo` internally |
| Jellyfin doesn't see VeraCrypt media | Mount volumes first, then run `./setup_jellyfin.sh restart` |
| Health check times out | Jellyfin may still be starting — check `./setup_jellyfin.sh logs` |
| Permission denied on config | Run `sudo chown -R $(id -u):$(id -g) /opt/jellyfin/config` |
| Port 8096 already in use | Change `PORT` in `/etc/jellyfin-docker.conf` |
| No hardware transcoding | Check that your GPU driver is loaded and `ENABLE_HW_ACCEL` is not set to `none` |

## License

[MIT](LICENSE)
