#!/usr/bin/env bash
#
# setup_frame_eye_forward.sh
#
# Installs, builds, and runs "frameeyeosc" on a Steam Frame headset (SteamOS)
# to forward the Frame's eye-tracking data to a PC running VRChat via OSC.
#
# Run this ON THE HEADSET, in Desktop Mode, from a terminal.
#
# Usage:
#   ./setup_frame_eye_forward.sh <PC_IP> [PORT] [PREFIX]              # build + run in foreground
#   ./setup_frame_eye_forward.sh <PC_IP> [PORT] [PREFIX] --service    # build + run as a background service
#   ./setup_frame_eye_forward.sh --stop                               # stop the background service
#
# Examples:
#   ./setup_frame_eye_forward.sh 192.168.1.50
#   ./setup_frame_eye_forward.sh 192.168.1.50 9000 /FT --service
#
set -euo pipefail

REPO_URL="https://github.com/konsti219/frameeyeosc.git"
INSTALL_DIR="$HOME/frameeyeosc"
BIN_PATH="$INSTALL_DIR/target/release/frameeyeosc"
DEFAULT_PORT=9000
DEFAULT_PREFIX="/FT"
SERVICE_NAME="frameeyeosc"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/${SERVICE_NAME}.service"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0 <PC_IP> [PORT] [PREFIX] [--service]
  $0 --stop

  PC_IP      IP address of the PC running VRChat (required)
  PORT       OSC destination port (default: $DEFAULT_PORT)
  PREFIX     Avatar-parameter prefix (default: $DEFAULT_PREFIX)
  --service  Install & start a background systemd service instead of
             running in the foreground (auto-restarts, survives logout)
  --stop     Stop and remove the background service
EOF
  exit 1
}

stop_service() {
  if systemctl --user list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    log "Stopping and removing the ${SERVICE_NAME} service..."
    systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload
    log "Done."
  else
    log "No ${SERVICE_NAME} service is installed."
  fi
  exit 0
}

[[ $# -lt 1 ]] && usage
[[ "$1" == "--stop" ]] && stop_service

TARGET_IP="$1"; shift
PORT="$DEFAULT_PORT"
PREFIX="$DEFAULT_PREFIX"
USE_SERVICE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) USE_SERVICE=1 ;;
    [0-9]*)    PORT="$1" ;;
    *)         PREFIX="$1" ;;
  esac
  shift
done

[[ "$TARGET_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "'$TARGET_IP' doesn't look like a valid IPv4 address."

log "Target: $TARGET_IP:$PORT  (prefix: $PREFIX)"

# --- git ---
if ! command -v git &>/dev/null; then
  log "git not found, attempting to install it..."
  if command -v pacman &>/dev/null; then
    sudo steamos-readonly disable 2>/dev/null || true
    sudo pacman -Sy --noconfirm git || die "Could not install git automatically. Install it manually and re-run this script."
    sudo steamos-readonly enable 2>/dev/null || true
  else
    die "git is missing and no supported package manager was found. Install git manually and re-run this script."
  fi
fi

# --- Rust / Cargo ---
if ! command -v cargo &>/dev/null; then
  log "Rust/Cargo not found, installing via rustup (installs to your home dir, no root needed)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi

# --- Clone / update frameeyeosc ---
if [[ -d "$INSTALL_DIR/.git" ]]; then
  log "Updating existing frameeyeosc checkout..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  log "Cloning frameeyeosc into $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- Build ---
log "Building frameeyeosc (release mode) — this can take a few minutes the first time..."
if ! ( cd "$INSTALL_DIR" && cargo build --release ); then
  die "Build failed. If the error mentions a missing compiler/linker, run:
    sudo steamos-readonly disable && sudo pacman -S --needed base-devel && sudo steamos-readonly enable
  then re-run this script."
fi

[[ -x "$BIN_PATH" ]] || die "Build finished but the binary wasn't found at $BIN_PATH."

# --- Run it (foreground) or install as a background service ---
if [[ "$USE_SERVICE" -eq 1 ]]; then
  log "Installing systemd user service..."
  mkdir -p "$SERVICE_DIR"
  cat > "$SERVICE_FILE" <<SERVICEEOF
[Unit]
Description=Forward Steam Frame eye-tracking data to VRChat via OSC
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN_PATH --target $TARGET_IP:$PORT --prefix $PREFIX
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
SERVICEEOF
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}.service"
  log "Service installed and running."
  echo "  Check status : systemctl --user status ${SERVICE_NAME}.service"
  echo "  View logs    : journalctl --user -u ${SERVICE_NAME}.service -f"
  echo "  Stop it      : $0 --stop"
else
  log "Starting frameeyeosc -> $TARGET_IP:$PORT (prefix $PREFIX). Press Ctrl+C to stop."
  exec "$BIN_PATH" --target "$TARGET_IP:$PORT" --prefix "$PREFIX"
fi
