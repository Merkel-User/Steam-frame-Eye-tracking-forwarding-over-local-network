#!/usr/bin/env bash
#
# setup_frame_eye_forward_<YOUR-PC-IP>.sh
#
# Installs, builds, calibrates and runs "frameeyeosc" (by konsti219) on a
# Steam Frame headset, forwarding the Frame's eye tracking to a PC running
# VRChat via OSC.
#
# The target IP is read from THIS FILE'S NAME. Rename the file so it contains
# the local IP of your PC, for example:
#
#     setup_frame_eye_forward_<YOUR-PC-IP>.sh
#
# Then run it from anywhere:
#
#     bash setup_frame_eye_forward_<YOUR-PC-IP>.sh
#
# After setup this file also adds "Frame Eye OSC" (and "Frame Eye OSC
# Calibrate") as non-Steam games when they are not already in the library.
#
# Upstream project (all the hard technical work): https://github.com/konsti219/frameeyeosc
# Steam Frame testing: thank you Tenebrex
#
set -euo pipefail

# ------------------------------------------------------------------ paths --
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then _self="${BASH_SOURCE[0]}"; else _self="$0"; fi
[[ "$_self" == /* ]] || _self="$PWD/$_self"
SCRIPT_PATH="$(cd -- "$(dirname -- "$_self")" && pwd)/$(basename -- "$_self")"
SCRIPT_NAME="$(basename -- "$SCRIPT_PATH")"
unset _self

HOME="${HOME:?HOME is not set}"

REPO_URL="https://github.com/konsti219/frameeyeosc.git"
SRC_DIR="$HOME/frameeyeosc"           # pristine clone, never modified
BUILD_DIR="$HOME/frameeyeosc-build"   # patched copy that is actually built
BIN_PATH="$BUILD_DIR/target/release/frameeyeosc"
CONFIG_DIR="$HOME/.config/frameeyeosc"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
STATE_DIR="$HOME/.local/state/frameeyeosc"
CTL_PATH="$HOME/.local/bin/frameeyeosc-ctl"
DESKTOP_FILE="$HOME/.local/share/applications/frameeyeosc.desktop"
DESKTOP_CAL_FILE="$HOME/.local/share/applications/frameeyeosc-calibrate.desktop"
SERVICE_NAME="frameeyeosc"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/${SERVICE_NAME}.service"
CARGO_ENV="$HOME/.cargo/env"

DEFAULT_PORT=9000
DEFAULT_PREFIX="/FT"

# ---------------------------------------------------------------- helpers --
mkdir -p "$STATE_DIR" 2>/dev/null || true
SETUP_LOG="$STATE_DIR/setup.log"

# Writes a one-line record of what happened, so problems can be diagnosed
# afterwards without watching the terminal. Shown by --status.
record() { printf '%s\t%s\t%s\n' "$(date -Is 2>/dev/null || date)" "$1" "${2:-}" >> "$SETUP_LOG" 2>/dev/null || true; }

# #region agent log
_dbg() { # $1 hypothesisId, $2 message, $3 json object
  python3 - "$1" "$2" "${3:-{}}" "$STATE_DIR" "$(dirname "$SCRIPT_PATH")" "${TARGET_IP:-}" <<'PY' 2>/dev/null || true
import json, pathlib, sys, time, urllib.request
hyp, msg, raw, state_dir, script_dir, target_ip = sys.argv[1:7]
try:
    data = json.loads(raw)
except Exception:
    data = {"raw": raw}
obj = {
    "sessionId": "c2f79c",
    "runId": "cal-during-use",
    "hypothesisId": hyp,
    "location": "setup.sh",
    "message": msg,
    "data": data,
    "timestamp": int(time.time() * 1000),
}
line = json.dumps(obj)
for p in (pathlib.Path(state_dir) / "debug-c2f79c.log", pathlib.Path(script_dir) / "debug-c2f79c.log"):
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
urls = ["http://127.0.0.1:7288/ingest/23a19f8e-0381-4849-b5b3-f30ff0cecca3"]
if target_ip:
    urls.append("http://%s:7288/ingest/23a19f8e-0381-4849-b5b3-f30ff0cecca3" % target_ip)
for url in urls:
    try:
        req = urllib.request.Request(url, data=line.encode(), headers={"Content-Type": "application/json", "X-Debug-Session-Id": "c2f79c"}, method="POST")
        urllib.request.urlopen(req, timeout=0.4).read()
    except Exception:
        pass
PY
}
# #endregion

log()  { echo "==> $*"; }
warn() { echo "--> $*" >&2; record "warn" "$*"; }
die()  { echo "ERROR: $*" >&2; record "error" "$*"; exit 1; }

valid_ipv4() {
  local ip="${1:-}" a b c d o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do ((10#$o >= 0 && 10#$o <= 255)) || return 1; done
  return 0
}

# true when $1 > $2, for float values
fgt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

ensure_cargo_on_path() {
  if [[ -f "$CARGO_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$CARGO_ENV"
  fi
  [[ -d "$HOME/.cargo/bin" && ":$PATH:" != *":$HOME/.cargo/bin:"* ]] && PATH="$HOME/.cargo/bin:$PATH"
  return 0
}

usage() {
  cat <<EOF
Frame eye forwarding — setup & launcher for frameeyeosc

Usage:
  bash "$SCRIPT_NAME" [options]

The PC IP comes from the filename ($SCRIPT_NAME).
Rename the file to e.g. setup_frame_eye_forward_<YOUR-PC-IP>.sh, or pass --ip.

Options:
  --ip ADDRESS    Override the IP taken from the filename
  --port PORT     OSC port (default: $DEFAULT_PORT)
  --prefix PATH   Avatar parameter prefix (default: $DEFAULT_PREFIX)
  --service       Install + start the background service instead of running here
  --calibrate     Only run the eye-lid calibration in a terminal (prompts + beeps)
  --lid           Same as --calibrate
  --calibrate-audio  Steam Calibrate: spoken instructions + beeps, then resume tracking
  --status        Show service status and current settings
  --stop          Stop and remove the background service
  --uninstall     Remove service, launcher and Steam entry (keeps the source code)
  -y, --yes       Skip the calibration prompt (keep the saved values)
  -h, --help      This text

Installed to:
  source      $SRC_DIR
  build       $BUILD_DIR
  binary      $BIN_PATH
  settings    $CONFIG_FILE
  service     $SERVICE_FILE
  launcher    $CTL_PATH
EOF
  exit 0
}

# ----------------------------------------------------------------- config --
PORT="$DEFAULT_PORT"
PREFIX="$DEFAULT_PREFIX"
LID_MIN="0.0"
LID_MAX="1.0"
LID_MIN_LEFT="0.0"
LID_MAX_LEFT="1.0"
LID_MIN_RIGHT="0.0"
LID_MAX_RIGHT="1.0"
LID_OUT_MAX="1.0"  # value sent when fully open (VRCFT v2 treats 0.75 as fully open)
LID_INVERT="0"     # 1 when the headset reports closedness instead of openness

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  # Old configs only had LID_MIN / LID_MAX for both eyes.
  LID_MIN_LEFT="${LID_MIN_LEFT:-${LID_MIN:-0.0}}"
  LID_MAX_LEFT="${LID_MAX_LEFT:-${LID_MAX:-1.0}}"
  LID_MIN_RIGHT="${LID_MIN_RIGHT:-${LID_MIN:-0.0}}"
  LID_MAX_RIGHT="${LID_MAX_RIGHT:-${LID_MAX:-1.0}}"
  LID_MIN="$LID_MIN_LEFT"
  LID_MAX="$LID_MAX_LEFT"
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  LID_MIN="$LID_MIN_LEFT"
  LID_MAX="$LID_MAX_LEFT"
  cat > "$CONFIG_FILE" <<EOF
# frameeyeosc settings — written by $SCRIPT_NAME
TARGET_IP=${TARGET_IP:-}
PORT=$PORT
PREFIX=$PREFIX
LID_MIN=$LID_MIN
LID_MAX=$LID_MAX
LID_MIN_LEFT=$LID_MIN_LEFT
LID_MAX_LEFT=$LID_MAX_LEFT
LID_MIN_RIGHT=$LID_MIN_RIGHT
LID_MAX_RIGHT=$LID_MAX_RIGHT
LID_OUT_MAX=$LID_OUT_MAX
LID_INVERT=$LID_INVERT
EOF
}

show_calibration() {
  cat <<EOF
  left closed  (--lid-min-left)  : $LID_MIN_LEFT
  left open    (--lid-max-left)  : $LID_MAX_LEFT
  right closed (--lid-min-right) : $LID_MIN_RIGHT
  right open   (--lid-max-right) : $LID_MAX_RIGHT
  value when open (--lid-out-max): $LID_OUT_MAX
  inverted     (--lid-invert)    : $([[ "$LID_INVERT" == "1" ]] && echo yes || echo no)
EOF
}

apply_cli_overrides() { # the command line wins over the saved settings
  [[ -n "${CLI_PORT:-}" ]] && PORT="$CLI_PORT"
  [[ -n "${CLI_PREFIX:-}" ]] && PREFIX="$CLI_PREFIX"
  return 0
}

CALIBRATION_AVAILABLE=1

run_args() {
  RUN_ARGS=( --target "${TARGET_IP}:${PORT}" --prefix "$PREFIX" )
  if [[ $CALIBRATION_AVAILABLE -eq 1 ]]; then
    RUN_ARGS+=( --lid-min-left "$LID_MIN_LEFT" --lid-max-left "$LID_MAX_LEFT"
                --lid-min-right "$LID_MIN_RIGHT" --lid-max-right "$LID_MAX_RIGHT"
                --lid-out-max "$LID_OUT_MAX" )
    [[ "$LID_INVERT" == "1" ]] && RUN_ARGS+=( --lid-invert )
  fi
  return 0
}

tracker_count() {
  local n
  n="$(pgrep -x frameeyeosc 2>/dev/null | wc -l | tr -d ' ')" || true
  printf '%s' "${n:-0}"
}

# Steam Calibrate (and any --print-lids sample) cannot share the eye mmap with a
# live sender. Stop systemd and any foreground frameeyeosc, then wait for it.
stop_eye_tracker() {
  local n_before n_after svc="inactive"
  n_before="$(tracker_count)"
  if systemctl --user is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    svc="active"
  fi
  # #region agent log
  _dbg "A" "stop_tracker_begin" "{\"n\":${n_before:-0},\"service\":\"$svc\"}"
  # #endregion
  systemctl --user stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  pkill -x frameeyeosc >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x frameeyeosc >/dev/null 2>&1 || break
    sleep 0.15
  done
  if pgrep -x frameeyeosc >/dev/null 2>&1; then
    pkill -9 -x frameeyeosc >/dev/null 2>&1 || true
    sleep 0.2
  fi
  n_after="$(tracker_count)"
  # #region agent log
  _dbg "A" "stop_tracker_end" "{\"n_before\":${n_before:-0},\"n_after\":${n_after:-0},\"service_was\":\"$svc\"}"
  # #endregion
}

# Writes ~/.local/bin/frameeyeosc-ctl. Start always re-reads settings.conf so a
# Steam Calibrate during tracking does not leave the library entry on old lids.
write_ctl_file() {
  run_args
  mkdir -p "$(dirname "$CTL_PATH")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Generated by '"$SCRIPT_NAME"' — start/stop frameeyeosc without a terminal.'
    printf '%s\n' 'set -euo pipefail'
    printf 'unit=%q\n' "${SERVICE_NAME}.service"
    printf 'service_file=%q\n' "$SERVICE_FILE"
    printf 'setup_script=%q\n' "$SCRIPT_PATH"
    printf 'bin_path=%q\n' "$BIN_PATH"
    printf 'state_dir=%q\n' "$STATE_DIR"
    printf 'config_file=%q\n' "$CONFIG_FILE"
    printf 'fallback_run_args=('
    printf ' %q' "${RUN_ARGS[@]}"
    printf ' )\n'
  } > "$CTL_PATH"
  cat >> "$CTL_PATH" <<'CTLEOF'
cmd="${1:-start}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "${XDG_RUNTIME_DIR}/bus" ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

# #region agent log
_ctl_dbg() {
  python3 - "$1" "$2" "$3" "$state_dir" <<'PY' 2>/dev/null || true
import json, pathlib, sys, time
hyp, msg, raw, state_dir = sys.argv[1:5]
try:
    data = json.loads(raw)
except Exception:
    data = {"raw": raw}
obj = {
    "sessionId": "c2f79c",
    "runId": "steam-exec",
    "hypothesisId": hyp,
    "location": "frameeyeosc-ctl",
    "message": msg,
    "data": data,
    "timestamp": int(time.time() * 1000),
}
line = json.dumps(obj)
try:
    pathlib.Path(state_dir).mkdir(parents=True, exist_ok=True)
    with open(pathlib.Path(state_dir) / "debug-c2f79c.log", "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
except OSError:
    pass
try:
    with open(pathlib.Path(state_dir) / "setup.log", "a", encoding="utf-8") as fh:
        fh.write("%s\tctl\t%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg, raw))
except OSError:
    pass
PY
}
# #endregion

load_run_args() {
  run_args=("${fallback_run_args[@]}")
  sourced=0
  [[ -f "$config_file" ]] || return 0
  set +u
  # shellcheck disable=SC1090
  source "$config_file"
  set -u
  sourced=1
  PORT="${PORT:-9000}"
  PREFIX="${PREFIX:-/FT}"
  LID_MIN_LEFT="${LID_MIN_LEFT:-${LID_MIN:-0.0}}"
  LID_MAX_LEFT="${LID_MAX_LEFT:-${LID_MAX:-1.0}}"
  LID_MIN_RIGHT="${LID_MIN_RIGHT:-${LID_MIN:-0.0}}"
  LID_MAX_RIGHT="${LID_MAX_RIGHT:-${LID_MAX:-1.0}}"
  LID_OUT_MAX="${LID_OUT_MAX:-1.0}"
  LID_INVERT="${LID_INVERT:-0}"
  [[ -n "${TARGET_IP:-}" ]] || return 0
  run_args=( --target "${TARGET_IP}:${PORT}" --prefix "$PREFIX"
             --lid-min-left "$LID_MIN_LEFT" --lid-max-left "$LID_MAX_LEFT"
             --lid-min-right "$LID_MIN_RIGHT" --lid-max-right "$LID_MAX_RIGHT"
             --lid-out-max "$LID_OUT_MAX" )
  [[ "$LID_INVERT" == "1" ]] && run_args+=( --lid-invert )
}

case "$cmd" in
  calibrate|lid)
    exec bash "$setup_script" --calibrate
    ;;
  calibrate-audio)
    exec bash "$setup_script" --calibrate-audio
    ;;
  start|steam-run)
    # Steam Game Mode: do NOT systemctl-and-exit (that looks like a silent
    # crash). Run the tracker in the foreground, same as a working terminal
    # start. Steam keeps this process alive until you leave the library item.
    dbus_set=false
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && dbus_set=true
    load_run_args
    _ctl_dbg "C" "before_exec" "{\"cmd\":\"$cmd\",\"dbus_set\":$dbus_set,\"bin_exists\":$( [[ -x "$bin_path" ]] && echo true || echo false ),\"sourced\":${sourced:-0},\"argc\":${#run_args[@]}}"
    if [[ -z "${INVOCATION_ID:-}" ]]; then
      systemctl --user stop "$unit" >/dev/null 2>&1 || true
    fi
    # Replace a sender left running by Steam Calibrate (same binary name).
    pkill -x frameeyeosc >/dev/null 2>&1 || true
    sleep 0.2
    if [[ ! -x "$bin_path" ]]; then
      _ctl_dbg "B" "missing_binary" "{\"bin\":\"$bin_path\"}"
      echo "ERROR: $bin_path is missing. Re-run setup once." >&2
      sleep 3
      exit 1
    fi
    echo
    echo "========================================"
    echo "  Frame Eye OSC is RUNNING"
    echo "  ${run_args[*]}"
    echo "  Close this window, or stop the game in Steam, to quit."
    echo "========================================"
    echo
    _ctl_dbg "C" "exec" "{\"argc\":${#run_args[@]},\"sourced\":${sourced:-0}}"
    exec "$bin_path" "${run_args[@]}"
    ;;
  stop)    systemctl --user stop "$unit" ;;
  restart) systemctl --user restart "$unit" ;;
  status)  systemctl --user status "$unit" --no-pager ;;
  toggle)
    if [[ ! -f "$service_file" ]]; then
      echo "ERROR: $service_file is missing. Re-run the setup script once in Desktop Mode." >&2
      exit 1
    fi
    if systemctl --user is-active --quiet "$unit"; then
      systemctl --user stop "$unit"
    else
      systemctl --user start "$unit"
    fi
    ;;
  *) echo "usage: $0 [start|stop|restart|status|toggle|calibrate|calibrate-audio]" >&2; exit 1 ;;
esac
CTLEOF
  chmod +x "$CTL_PATH"
}

# ------------------------------------------------------------ subcommands --
service_installed() {
  [[ -f "$SERVICE_FILE" ]] || systemctl --user list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"
}

stop_service() {
  if service_installed; then
    log "Stopping and removing the ${SERVICE_NAME} service..."
    systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    log "Done."
  else
    log "No ${SERVICE_NAME} service is installed."
  fi
}

uninstall_all() {
  stop_service
  rm -f "$CTL_PATH" "$DESKTOP_FILE" "$DESKTOP_CAL_FILE"
  log "Removed launcher and Steam entry."
  log "Source and build directories were kept: $SRC_DIR, $BUILD_DIR"
}

show_status() {
  load_config
  apply_cli_overrides
  echo "Target      : ${TARGET_IP:-unknown}:$PORT  (prefix $PREFIX)"
  echo "Binary      : $BIN_PATH $([[ -x "$BIN_PATH" ]] && echo '(built)' || echo '(NOT built yet)')"
  echo "Calibration :"
  show_calibration
  echo "Service     :"
  systemctl --user status "${SERVICE_NAME}.service" --no-pager 2>&1 | sed 's/^/  /' || true
  echo "Last runs   :"
  if [[ -s "$SETUP_LOG" ]]; then
    tail -n 20 "$SETUP_LOG" | sed 's/^/  /'
  else
    echo "  (nothing recorded yet)"
  fi
}

# ---------------------------------------------------------- argument pass --
CLI_IP=""
CLI_PORT=""
CLI_PREFIX=""
MODE="run"
ASSUME_YES=0
WANT_SERVICE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)        CLI_IP="${2:-}"; shift ;;
    --port)      CLI_PORT="${2:-}"; shift ;;
    --prefix)    CLI_PREFIX="${2:-}"; shift ;;
    --service)   WANT_SERVICE=1 ;;
    --calibrate|--lid) MODE="calibrate" ;;
    --calibrate-audio) MODE="calibrate-audio" ;;
    --status)    MODE="status" ;;
    --stop)      MODE="stop" ;;
    --uninstall) MODE="uninstall" ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage ;;
    *)           die "Unknown option '$1'. Run with --help." ;;
  esac
  shift
done

if [[ "$MODE" == "stop" ]]; then stop_service; exit 0; fi
if [[ "$MODE" == "uninstall" ]]; then uninstall_all; exit 0; fi

# --------------------------------------------------- target IP resolution --
TARGET_IP=""
if [[ -n "$CLI_IP" ]]; then
  valid_ipv4 "$CLI_IP" || die "'--ip $CLI_IP' is not a valid IPv4 address."
  TARGET_IP="$CLI_IP"
elif [[ "$SCRIPT_NAME" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
  # keep the match before valid_ipv4 runs, it overwrites BASH_REMATCH
  NAME_IP="${BASH_REMATCH[1]}"
  valid_ipv4 "$NAME_IP" && TARGET_IP="$NAME_IP"
fi

if [[ "$MODE" == "status" ]]; then show_status; exit 0; fi

if [[ -z "$TARGET_IP" ]]; then
  die "No PC IP found.
  This file is called '$SCRIPT_NAME'. Rename it so it contains your PC's local IP:
      mv \"$SCRIPT_PATH\" \"\$(dirname \"$SCRIPT_PATH\")/setup_frame_eye_forward_<YOUR-PC-IP>.sh\"
  ...or run it with:  bash \"$SCRIPT_NAME\" --ip <YOUR-PC-IP>"
fi

load_config
apply_cli_overrides

INTERACTIVE=0
[[ $ASSUME_YES -eq 0 && -t 0 && -t 1 ]] && INTERACTIVE=1

log "Target: ${TARGET_IP}:${PORT}  (prefix: $PREFIX)"
record "run-start" "file=$SCRIPT_NAME target=${TARGET_IP}:${PORT} prefix=$PREFIX service=$WANT_SERVICE mode=$MODE interactive=$INTERACTIVE lid_L=$LID_MIN_LEFT/$LID_MAX_LEFT lid_R=$LID_MIN_RIGHT/$LID_MAX_RIGHT invert=$LID_INVERT"

if [[ "$MODE" == "calibrate" || "$MODE" == "calibrate-audio" ]] && [[ -x "$BIN_PATH" ]]; then
  command -v python3 &>/dev/null || die "python3 is required for calibration. Install it and re-run."
  log "Using existing binary $BIN_PATH (skipping clone/build)."
  record "build" "skipped=yes"
else
# ------------------------------------------------------------ dependencies --
if ! command -v git &>/dev/null; then
  log "git not found, attempting to install it..."
  if command -v pacman &>/dev/null; then
    sudo steamos-readonly disable 2>/dev/null || true
    sudo pacman -Sy --noconfirm git || die "Could not install git. Install it manually and re-run."
    sudo steamos-readonly enable 2>/dev/null || true
  else
    die "git is missing and no supported package manager was found."
  fi
fi

command -v python3 &>/dev/null || die "python3 is required (it applies the eye-lid calibration patch). Install it and re-run."

ensure_cargo_on_path
if ! command -v cargo &>/dev/null; then
  log "Rust/Cargo not found, installing via rustup (into your home dir, no root needed)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  ensure_cargo_on_path
fi
command -v cargo &>/dev/null || die "Cargo still not available. Open a new terminal or run: source \"$CARGO_ENV\""

# --------------------------------------------------------- source + patch --
if [[ -d "$SRC_DIR/.git" ]]; then
  log "Updating frameeyeosc source in $SRC_DIR..."
  git -C "$SRC_DIR" pull --ff-only || warn "Could not update, continuing with the existing checkout."
else
  [[ -e "$SRC_DIR" ]] && die "$SRC_DIR exists but is not a git checkout. Move or delete it and re-run."
  log "Cloning frameeyeosc into $SRC_DIR..."
  git clone "$REPO_URL" "$SRC_DIR"
fi

mkdir -p "$BUILD_DIR/src" "$STATE_DIR"
for f in Cargo.toml Cargo.lock; do
  [[ -f "$SRC_DIR/$f" ]] || die "Upstream file $f is missing from $SRC_DIR."
  cmp -s "$SRC_DIR/$f" "$BUILD_DIR/$f" || cp "$SRC_DIR/$f" "$BUILD_DIR/$f"
done

PATCHED_MAIN="$(mktemp)"
trap 'rm -f "$PATCHED_MAIN"' EXIT

log "Adding eye-lid calibration options to a private copy of the source..."
if ! python3 - "$SRC_DIR/src/main.rs" "$PATCHED_MAIN" <<'PYPATCH'
import re, sys, pathlib

source = pathlib.Path(sys.argv[1]).read_text()
out = source
missing = []

extra_args = '''    #[arg(long, default_value_t = 0.0, help = "Raw openness when the LEFT eye is fully closed")]
    lid_min_left: f32,
    #[arg(long, default_value_t = 1.0, help = "Raw openness when the LEFT eye is fully open")]
    lid_max_left: f32,
    #[arg(long, default_value_t = 0.0, help = "Raw openness when the RIGHT eye is fully closed")]
    lid_min_right: f32,
    #[arg(long, default_value_t = 1.0, help = "Raw openness when the RIGHT eye is fully open")]
    lid_max_right: f32,
    #[arg(long, default_value_t = 1.0, help = "Value sent when the eye is fully open (VRCFT v2 treats 0.75 as open)")]
    lid_out_max: f32,
    #[arg(long, help = "The headset reports closedness instead of openness")]
    lid_invert: bool,
    #[arg(long, help = "Print raw left/right openness to stderr, used by the calibration helper")]
    print_lids: bool,
'''

map_lid = '''fn map_lid(args: &Args, raw: f32, right: bool) -> f32 {
    let value = if args.lid_invert { 1.0 - raw } else { raw };
    let lid_min = if right { args.lid_min_right } else { args.lid_min_left };
    let lid_max = if right { args.lid_max_right } else { args.lid_max_left };
    let span = lid_max - lid_min;
    let normalized = if span.abs() < 1e-6 {
        value.clamp(0.0, 1.0)
    } else {
        ((value - lid_min) / span).clamp(0.0, 1.0)
    };
    (normalized * args.lid_out_max).clamp(0.0, 1.0)
}

'''

anchor = re.search(r'\n[ \t]*prefix:\s*String,[ \t]*\n', out)
if anchor:
    out = out[:anchor.end()] + extra_args + out[anchor.end():]
else:
    missing.append("--prefix argument in struct Args")

for eye, right in ((0, "false"), (1, "true")):
    out, hits = re.subn(r'data\.openness\[%d\]\s*\.clamp\(\s*0\.0\s*,\s*1\.0\s*\)' % eye,
                        'map_lid(args, data.openness[%d], %s)' % (eye, right), out)
    if hits != 1:
        missing.append("EyeLid value for eye %d" % eye)

anchor = re.search(r'\nfn send_eye_data', out)
if anchor:
    out = out[:anchor.start() + 1] + map_lid + out[anchor.start() + 1:]
else:
    missing.append("fn send_eye_data")


def with_print(match):
    pad = match.group(1)
    return ('%sif args.print_lids {\n'
            '%s    let openness = data.openness;\n'
            '%s    eprintln!("{:.5} {:.5}", openness[0], openness[1]);\n'
            '%s}\n'
            '%ssend_eye_data(&socket, &args, data)?;' % (pad, pad, pad, pad, pad))


out, hits = re.subn(r'([ \t]*)send_eye_data\(&socket,\s*&args,\s*data\)\?;', with_print, out)
if hits != 1:
    missing.append("send_eye_data call in main")

if missing:
    sys.exit("upstream frameeyeosc changed, could not patch: " + ", ".join(missing))

pathlib.Path(sys.argv[2]).write_text(out)
PYPATCH
then
  warn "Could not add the calibration options, falling back to the unmodified upstream version."
  CALIBRATION_AVAILABLE=0
  cp "$SRC_DIR/src/main.rs" "$PATCHED_MAIN"
else
  record "patch" "applied=yes"
fi

cmp -s "$PATCHED_MAIN" "$BUILD_DIR/src/main.rs" || cp "$PATCHED_MAIN" "$BUILD_DIR/src/main.rs"

# ------------------------------------------------------------------ build --
log "Building frameeyeosc (release) — the first build takes a few minutes..."
if ! ( cd "$BUILD_DIR" && cargo build --release ); then
  if [[ $CALIBRATION_AVAILABLE -eq 1 ]]; then
    warn "The build with calibration failed, retrying with the unmodified upstream source..."
    CALIBRATION_AVAILABLE=0
    cp "$SRC_DIR/src/main.rs" "$BUILD_DIR/src/main.rs"
    ( cd "$BUILD_DIR" && cargo build --release ) || die "Build failed even without the calibration patch.
  If the error mentions a missing compiler or linker, run:
    sudo steamos-readonly disable && sudo pacman -S --needed base-devel && sudo steamos-readonly enable
  then re-run: bash \"$SCRIPT_PATH\""
  else
    die "Build failed. If the error mentions a missing compiler or linker, run:
    sudo steamos-readonly disable && sudo pacman -S --needed base-devel && sudo steamos-readonly enable
  then re-run: bash \"$SCRIPT_PATH\""
  fi
fi
[[ -x "$BIN_PATH" ]] || die "Build finished but no binary at $BIN_PATH."
record "build" "ok=yes calibration_available=$CALIBRATION_AVAILABLE"
[[ $CALIBRATION_AVAILABLE -eq 0 ]] && warn "Running without eye-lid calibration (plain upstream behaviour)."
fi

# ------------------------------------------------------------ calibration --
mean() { # average of numbers on stdin
  awk 'NF { n++; s += $1 } END { if (n < 1) exit 1; printf "%.4f", s / n }'
}

sample_phase() { # $1 = seconds, $2 = output file; collects raw openness samples
  local seconds="$1" out="$2" raw="$STATE_DIR/phase-raw.txt"
  local n lines=0 head=""
  n="$(tracker_count)"
  timeout "$seconds" "$BIN_PATH" --target 127.0.0.1:9 --prefix "$PREFIX" --print-lids \
    >/dev/null 2>"$raw" || true
  grep -E '^-?[0-9]+\.[0-9]+ -?[0-9]+\.[0-9]+$' "$raw" > "$out" || true
  [[ -f "$out" ]] && lines="$(wc -l < "$out" | tr -d ' ')" || true
  head="$(head -c 80 "$raw" 2>/dev/null | tr -cd 'A-Za-z0-9._: +-' | tr '\n' ' ')" || true
  # #region agent log
  _dbg "A" "sample_phase" "{\"seconds\":$seconds,\"trackers_at_start\":${n:-0},\"lines\":${lines:-0},\"raw_head\":\"$head\"}"
  # #endregion
  if [[ ! -s "$out" ]]; then
    warn "No eye data was received. frameeyeosc said:"
    sed 's/^/    /' "$raw" >&2
    return 1
  fi
  return 0
}

# Beeps only. Never call espeak / spd-say. speaker-test on SteamOS often has
# no audible output (wrong ALSA device), so PipeWire/Pulse is tried first.
play_tone() { # $1 = Hz, $2 = milliseconds
  local freq ms wav secs
  freq="${1:-880}"
  ms="${2:-180}"
  secs="$(awk -v m="$ms" 'BEGIN { s = m / 1000.0; if (s < 0.05) s = 0.05; printf "%.3f", s }')"
  wav="/tmp/frameeye-beep.wav"
  python3 - "$wav" "$freq" "$ms" <<'PY' 2>/dev/null || true
import math, struct, sys, wave
path, hz, duration_ms = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
sr, n = 22050, max(1, int(22050 * duration_ms / 1000.0))
with wave.open(path, "w") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(sr)
    fade = max(1, int(sr * 0.004))
    for i in range(n):
        env = min(1.0, i / fade, (n - 1 - i) / fade)
        sample = int(30000 * env * math.sin(2 * math.pi * hz * i / sr))
        out.writeframes(struct.pack("<h", max(-32767, min(32767, sample))))
PY
  if [[ -f "$wav" ]]; then
    if command -v pw-play &>/dev/null && pw-play "$wav" 2>/dev/null; then return 0; fi
    if command -v paplay &>/dev/null && paplay "$wav" 2>/dev/null; then return 0; fi
    if command -v aplay &>/dev/null && aplay -q "$wav" 2>/dev/null; then return 0; fi
  fi
  if command -v speaker-test &>/dev/null; then
    timeout "$secs" speaker-test -t sine -f "$freq" -l 1 -c 1 >/dev/null 2>&1 || true
  fi
  printf '\a'
  return 0
}

# Speaks a short instruction. Used only for Steam Calibrate (CAL_SPEAK=1).
# Writes a wav and plays it (same path as beeps). Do not use spd-say — on
# SteamOS it often speaks "the eSpeak module is working" instead of the text.
speak() {
  local text="${1:-}" wav="/tmp/frameeye-tts.wav" engine="none" played=0
  [[ "${CAL_SPEAK:-0}" == "1" ]] || return 0
  [[ -n "$text" ]] || return 0
  rm -f "$wav"
  if command -v espeak-ng &>/dev/null; then
    engine="espeak-ng"
    espeak-ng -s 130 -w "$wav" -- "$text" >/dev/null 2>&1 || true
  elif command -v espeak &>/dev/null; then
    engine="espeak"
    espeak -s 130 -w "$wav" -- "$text" >/dev/null 2>&1 || true
  fi
  if [[ -s "$wav" ]]; then
    if command -v pw-play &>/dev/null && pw-play "$wav" >/dev/null 2>&1; then played=1
    elif command -v paplay &>/dev/null && paplay "$wav" >/dev/null 2>&1; then played=1
    elif command -v aplay &>/dev/null && aplay -q "$wav" >/dev/null 2>&1; then played=1
    fi
  fi
  # #region agent log
  python3 - "$engine" "$text" "$played" "$STATE_DIR" <<'PY' 2>/dev/null || true
import json, pathlib, sys, time
engine, text, played, state_dir = sys.argv[1:5]
obj = {
    "sessionId": "c2f79c",
    "runId": "tts-wav",
    "hypothesisId": "A",
    "location": "setup.sh:speak",
    "message": "tts",
    "data": {"engine": engine, "text": text, "played": played == "1"},
    "timestamp": int(time.time() * 1000),
}
try:
    pathlib.Path(state_dir).mkdir(parents=True, exist_ok=True)
    with open(pathlib.Path(state_dir) / "debug-c2f79c.log", "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj) + "\n")
except OSError:
    pass
PY
  # #endregion
  return 0
}

ensure_tts() {
  if command -v espeak-ng &>/dev/null || command -v espeak &>/dev/null; then
    return 0
  fi
  log "Installing espeak-ng so Steam calibration can speak instructions..."
  if command -v pacman &>/dev/null; then
    sudo steamos-readonly disable 2>/dev/null || true
    sudo pacman -S --needed --noconfirm espeak-ng || warn "Could not install espeak-ng. Steam calibration will still beep."
    sudo steamos-readonly enable 2>/dev/null || true
  fi
}

cue() { # on-screen text + beep; Steam voice is handled by speak() at the same steps
  echo
  echo "  >>> $1"
  play_tone "${2:-880}" "${3:-180}" || true
}

countdown() { # $1 = header, $2 = seconds, $3 = close|open
  local action="${3:-close}" i
  echo "  $1"
  if [[ "$action" == "close" ]]; then
    echo "     Keep your eyes OPEN during this countdown."
    echo "     CLOSE them when you hear the high beep after 1."
    speak "Keep your eyes open. Close them when I say, close your eyes."
  else
    echo "     Keep your eyes WIDE OPEN the whole time (countdown and recording)."
    echo "     Do not squint. Look around when you hear the high beep after 1."
    speak "Keep your eyes wide open."
  fi
  for ((i = "$2"; i > 0; i--)); do
    if [[ "$action" == "close" && "$i" -eq 3 ]]; then
      printf '     %d...  (get ready to CLOSE)\n' "$i"
    elif [[ "$action" == "close" && "$i" -eq 1 ]]; then
      printf '     %d...  CLOSE YOUR EYES NOW\n' "$i"
      speak "Close your eyes now."
    elif [[ "$action" == "open" && "$i" -eq 1 ]]; then
      printf '     %d...  KEEP EYES WIDE OPEN — recording starts\n' "$i"
      speak "Keep your eyes wide open."
    else
      printf '     %d...\n' "$i"
    fi
    if [[ "$i" -eq 1 ]]; then play_tone 1320 280 || true; else play_tone 880 70 || true; fi
    sleep 1
  done
}

# Terminal "Proceed" control — waits until Enter (or the word proceed).
proceed() {
  local hint="${1:-Proceed}"
  local answer
  echo
  echo "  +------------------+"
  echo "  |   [ PROCEED ]    |"
  echo "  +------------------+"
  echo "  $hint"
  read -r -p "  Press Enter to proceed: " answer
  if [[ -n "${answer:-}" && ! "${answer}" =~ ^([Pp]roceed|[Yy]|[Oo]k)$ ]]; then
    echo "  (continuing anyway)"
  fi
  return 0
}

# Guided measurement: 8s countdown, 3s recording.
# Terminal path: printed cues + beeps, no voice.
# Steam audio path (\$1=audio): spoken instructions + a long get-ready wait.
CAL_READY_SEC=8
CAL_HOLD_SEC=3
CAL_AUDIO_INTRO_SEC=15
CAL_SPEAK=0

guided_calibration() {
  local closed="$STATE_DIR/closed.txt" open="$STATE_DIR/open.txt" intro
  echo
  echo "========================================"
  echo "  Eyelid calibration (2 recordings)"
  echo "========================================"
  if [[ "${1:-}" == "audio" ]]; then
    echo "  Steam Calibrate: spoken instructions plus beeps."
  else
    echo "  Sounds: BEEPS ONLY. There is no voice / text-to-speech."
  fi
  echo
  echo "  STEP 1 — CLOSED: eyes OPEN during countdown, CLOSE at the high beep,"
  echo "           keep them SHUT until the low beep (${CAL_HOLD_SEC}s)."
  echo "  STEP 2 — OPEN:   keep your eyes WIDE OPEN the whole time; look around at the high beep."
  echo
  if [[ "${1:-}" == "audio" ]]; then
    CAL_SPEAK=1
    speak "Eyelid calibration. Put the headset on. Keep your eyes open. Recording starts in ${CAL_AUDIO_INTRO_SEC} seconds."
    for ((intro = CAL_AUDIO_INTRO_SEC; intro > 0; intro--)); do
      if [[ "$intro" -eq 10 ]]; then speak "Ten seconds."; fi
      if [[ "$intro" -eq 5 ]]; then speak "Five seconds."; fi
      play_tone 880 70 || true
      sleep 1
    done
    speak "Step one. Eyes closed."
  else
    proceed "Headset on. Eyes can stay OPEN. Next is the CLOSED-eye recording."
  fi

  echo
  echo "  -------- STEP 1 of 2: EYES CLOSED --------"
  echo "  Right now: leave your eyes OPEN."
  # A live Steam tracker holds the eye mmap; sampling needs the binary alone.
  if [[ "${1:-}" == "audio" ]]; then
    stop_eye_tracker
  fi
  countdown "Countdown (${CAL_READY_SEC}s). Close ONLY when it says CLOSE YOUR EYES NOW." "$CAL_READY_SEC" close
  cue "HIGH BEEP — CLOSE YOUR EYES NOW. Keep them shut." 1320 320
  echo "  Recording CLOSED eyes (${CAL_HOLD_SEC}s average) — do not open them yet."
  sample_phase "$CAL_HOLD_SEC" "$closed" || return 1
  cue "LOW BEEP — OPEN YOUR EYES. Closed recording is finished." 440 320
  speak "Open your eyes."
  echo "  ...step 1 done."

  if [[ "${1:-}" == "audio" ]]; then
    sleep 2
    speak "Step two. Eyes wide open."
  else
    proceed "Next is the OPEN-eye recording. Keep your eyes WIDE OPEN (do not close or squint)."
  fi

  echo
  echo "  -------- STEP 2 of 2: EYES WIDE OPEN --------"
  echo "  Right now: open your eyes as WIDE as is comfortable. Do not close or squint."
  countdown "Countdown (${CAL_READY_SEC}s). Keep eyes WIDE OPEN." "$CAL_READY_SEC" open
  cue "HIGH BEEP — KEEP YOUR EYES WIDE OPEN. Look around." 1320 320
  echo "  Recording WIDE OPEN eyes (${CAL_HOLD_SEC}s average) — do not blink if you can help it."
  sample_phase "$CAL_HOLD_SEC" "$open" || return 1
  cue "LOW BEEP — DONE. You can blink normally again." 990 320
  speak "Done."
  echo "  ...step 2 done."

  local closed_l closed_r open_l open_r invert=0
  closed_l="$(awk '{ print $1 }' "$closed" | mean)" || return 1
  closed_r="$(awk '{ print $2 }' "$closed" | mean)" || return 1
  open_l="$(awk '{ print $1 }' "$open" | mean)" || return 1
  open_r="$(awk '{ print $2 }' "$open" | mean)" || return 1
  echo "  ${CAL_HOLD_SEC}s average left : closed $closed_l / open $open_l"
  echo "  ${CAL_HOLD_SEC}s average right: closed $closed_r / open $open_r"
  record "measure" "avg_sec=$CAL_HOLD_SEC closed_samples=$(wc -l < "$closed") open_samples=$(wc -l < "$open") L_closed=$closed_l L_open=$open_l R_closed=$closed_r R_open=$open_r"

  if fgt "$(awk -v a="$closed_l" -v b="$closed_r" 'BEGIN { print a + b }')" \
         "$(awk -v a="$open_l" -v b="$open_r" 'BEGIN { print a + b }')"; then
    invert=1
    echo "  the headset reports closedness, enabling --lid-invert"
  fi

  local new_min_l new_max_l new_min_r new_max_r span_l span_r fail_l=0 fail_r=0
  new_min_l="$(awk -v v="$closed_l" -v i="$invert" 'BEGIN { printf "%.4f", (i == 1 ? 1 - v : v) }')"
  new_max_l="$(awk -v v="$open_l" -v i="$invert" 'BEGIN { printf "%.4f", (i == 1 ? 1 - v : v) }')"
  new_min_r="$(awk -v v="$closed_r" -v i="$invert" 'BEGIN { printf "%.4f", (i == 1 ? 1 - v : v) }')"
  new_max_r="$(awk -v v="$open_r" -v i="$invert" 'BEGIN { printf "%.4f", (i == 1 ? 1 - v : v) }')"
  span_l="$(awk -v a="$new_max_l" -v b="$new_min_l" 'BEGIN { printf "%.4f", a - b }')"
  span_r="$(awk -v a="$new_max_r" -v b="$new_min_r" 'BEGIN { printf "%.4f", a - b }')"

  if ! fgt "$span_l" "0.05"; then
    warn "LEFT eye closed/open are too close ($new_min_l / $new_max_l) — keeping the previous left values."
    fail_l=1
  else
    LID_MIN_LEFT="$new_min_l"
    LID_MAX_LEFT="$new_max_l"
  fi
  if ! fgt "$span_r" "0.05"; then
    warn "RIGHT eye closed/open are too close ($new_min_r / $new_max_r) — keeping the previous right values."
    fail_r=1
  else
    LID_MIN_RIGHT="$new_min_r"
    LID_MAX_RIGHT="$new_max_r"
  fi
  if [[ "$fail_l" -eq 1 && "$fail_r" -eq 1 ]]; then
    warn "Make sure eye tracking is calibrated in Settings > Display > Eye Tracking Calibration."
    record "calibration" "result=rejected L=$new_min_l/$new_max_l R=$new_min_r/$new_max_r"
    return 1
  fi

  LID_MIN="$LID_MIN_LEFT"
  LID_MAX="$LID_MAX_LEFT"
  LID_INVERT="$invert"
  record "calibration" "result=accepted L=$LID_MIN_LEFT/$LID_MAX_LEFT R=$LID_MIN_RIGHT/$LID_MAX_RIGHT invert=$LID_INVERT"
  echo "  new calibration:"
  echo "    left  closed $LID_MIN_LEFT  open $LID_MAX_LEFT"
  echo "    right closed $LID_MIN_RIGHT  open $LID_MAX_RIGHT"
  echo "    invert $LID_INVERT"
  return 0
}

# Runs guided measurement until the user keeps a result or gives up.
guided_calibration_until_kept() {
  local answer prev_min_l="$LID_MIN_LEFT" prev_max_l="$LID_MAX_LEFT" prev_min_r="$LID_MIN_RIGHT" prev_max_r="$LID_MAX_RIGHT" prev_out="$LID_OUT_MAX" prev_inv="$LID_INVERT"
  while true; do
    if guided_calibration; then
      echo
      echo "  1) keep this calibration"
      echo "  2) redo the close/open recording"
      echo "  3) discard and keep the previous values"
      read -r -p "Choice [1]: " answer
      case "${answer:-1}" in
        2|r|R|redo)
          LID_MIN_LEFT="$prev_min_l"; LID_MAX_LEFT="$prev_max_l"
          LID_MIN_RIGHT="$prev_min_r"; LID_MAX_RIGHT="$prev_max_r"
          LID_MIN="$LID_MIN_LEFT"; LID_MAX="$LID_MAX_LEFT"
          LID_OUT_MAX="$prev_out"; LID_INVERT="$prev_inv"
          echo "  Redoing..."
          continue
          ;;
        3|n|N)
          LID_MIN_LEFT="$prev_min_l"; LID_MAX_LEFT="$prev_max_l"
          LID_MIN_RIGHT="$prev_min_r"; LID_MAX_RIGHT="$prev_max_r"
          LID_MIN="$LID_MIN_LEFT"; LID_MAX="$LID_MAX_LEFT"
          LID_OUT_MAX="$prev_out"; LID_INVERT="$prev_inv"
          warn "Calibration was not changed."
          return 1
          ;;
        *) return 0 ;;
      esac
    else
      LID_MIN_LEFT="$prev_min_l"; LID_MAX_LEFT="$prev_max_l"
      LID_MIN_RIGHT="$prev_min_r"; LID_MAX_RIGHT="$prev_max_r"
      LID_MIN="$LID_MIN_LEFT"; LID_MAX="$LID_MAX_LEFT"
      LID_OUT_MAX="$prev_out"; LID_INVERT="$prev_inv"
      read -r -p "  Recording failed. Redo? [Y/n]: " answer
      [[ "${answer:-Y}" =~ ^[Nn] ]] && return 1
    fi
  done
}

manual_calibration() {
  local answer
  read -r -p "  LEFT  closed [$LID_MIN_LEFT]: " answer; LID_MIN_LEFT="${answer:-$LID_MIN_LEFT}"
  read -r -p "  LEFT  open   [$LID_MAX_LEFT]: " answer; LID_MAX_LEFT="${answer:-$LID_MAX_LEFT}"
  read -r -p "  RIGHT closed [$LID_MIN_RIGHT]: " answer; LID_MIN_RIGHT="${answer:-$LID_MIN_RIGHT}"
  read -r -p "  RIGHT open   [$LID_MAX_RIGHT]: " answer; LID_MAX_RIGHT="${answer:-$LID_MAX_RIGHT}"
  read -r -p "  value to send when fully open (1.0 full range, 0.75 for VRCFT v2) [$LID_OUT_MAX]: " answer
  LID_OUT_MAX="${answer:-$LID_OUT_MAX}"
  read -r -p "  invert (headset reports closedness)? [y/N]: " answer
  [[ "${answer:-}" =~ ^[Yy] ]] && LID_INVERT=1 || LID_INVERT=0
  LID_MIN="$LID_MIN_LEFT"
  LID_MAX="$LID_MAX_LEFT"
  return 0
}

calibration_menu() {
  if [[ $CALIBRATION_AVAILABLE -eq 0 ]]; then
    warn "Eye-lid calibration is unavailable in this build, skipping the question."
    return 0
  fi
  echo
  echo "Eyelid calibration runs every time (so blinks stay accurate)."
  echo "Current saved values:"
  show_calibration
  echo
  echo "  +------------------+"
  echo "  |   [ PROCEED ]    |"
  echo "  +------------------+"
  local answer
  read -r -p "  Enter=proceed  s=skip this run only  m=type values by hand  r=reset to no calibration : " answer
  case "${answer:-proceed}" in
    s|S|skip) echo "  Skipping calibration this time."; return 0 ;;
    m|M) manual_calibration ;;
    r|R) LID_MIN="0.0"; LID_MAX="1.0"; LID_MIN_LEFT="0.0"; LID_MAX_LEFT="1.0"; LID_MIN_RIGHT="0.0"; LID_MAX_RIGHT="1.0"; LID_OUT_MAX="1.0"; LID_INVERT="0" ;;
    *) guided_calibration_until_kept || warn "Calibration was not changed." ;;
  esac
  save_config
  return 0
}

if [[ "$MODE" == "calibrate" ]]; then
  [[ $CALIBRATION_AVAILABLE -eq 1 ]] || die "This build has no calibration support, see the warnings above."
  guided_calibration_until_kept || die "Calibration failed, see the messages above."
  save_config
  log "Saved to $CONFIG_FILE"
  if service_installed && systemctl --user is-active --quiet "${SERVICE_NAME}.service"; then
    log "Restarting the service with the new calibration..."
    exec bash "$SCRIPT_PATH" --ip "$TARGET_IP" --service -y
  fi
  exit 0
fi

# Steam Game Mode entry: spoken instructions + beeps, no [PROCEED] prompts.
# Safe to launch while Frame Eye OSC is already sending: tracking is paused
# for the two recordings, then resumed here with the new lids (no --service rebuild).
resume_tracking_after_audio_cal() {
  run_args
  write_ctl_file
  # #region agent log
  _dbg "B" "resume_tracking" "{\"bin_exists\":$( [[ -x "$BIN_PATH" ]] && echo true || echo false ),\"args\":\"${RUN_ARGS[*]}\",\"lids\":\"L=$LID_MIN_LEFT/$LID_MAX_LEFT R=$LID_MIN_RIGHT/$LID_MAX_RIGHT inv=$LID_INVERT\"}"
  # #endregion
  [[ -x "$BIN_PATH" ]] || die "Missing $BIN_PATH. Re-run setup once."
  log "Starting tracking -> ${TARGET_IP}:${PORT} with the current calibration. Stop this item in Steam to quit."
  exec "$BIN_PATH" "${RUN_ARGS[@]}"
}

if [[ "$MODE" == "calibrate-audio" ]]; then
  [[ $CALIBRATION_AVAILABLE -eq 1 ]] || die "This build has no calibration support, see the warnings above."
  CAL_SPEAK=1
  # #region agent log
  _cal_svc="$(systemctl --user is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  _dbg "D" "cal_audio_start" "{\"trackers\":$(tracker_count),\"service\":\"${_cal_svc:-inactive}\"}"
  unset _cal_svc
  # #endregion
  if guided_calibration audio; then
    save_config
    log "Saved to $CONFIG_FILE"
    # #region agent log
    _dbg "B" "cal_saved" "{\"file\":\"$CONFIG_FILE\",\"L\":\"$LID_MIN_LEFT/$LID_MAX_LEFT\",\"R\":\"$LID_MIN_RIGHT/$LID_MAX_RIGHT\",\"inv\":\"$LID_INVERT\"}"
    # #endregion
    speak "Calibration saved. Starting tracking."
    play_tone 880 150 || true
    play_tone 1320 280 || true
    resume_tracking_after_audio_cal
  fi
  load_config
  apply_cli_overrides
  speak "Calibration failed. Starting tracking."
  play_tone 220 400 || true
  play_tone 180 500 || true
  warn "Calibration failed; resuming tracking with the previous values."
  # #region agent log
  _dbg "B" "cal_failed_resume" "{\"trackers\":$(tracker_count)}"
  # #endregion
  resume_tracking_after_audio_cal
fi

[[ $INTERACTIVE -eq 1 ]] && calibration_menu
save_config

# ------------------------------------------------- launcher + Steam entry --
# Always writes the systemd unit and desktop entries, then adds them to Steam
# as non-Steam games when missing. Frame Eye OSC runs in a terminal until you
# stop it in Steam or close that window.
write_service_unit() {
  mkdir -p "$SERVICE_DIR" "$STATE_DIR"
  cat > "$SERVICE_FILE" <<SERVICEEOF
[Unit]
Description=Forward Steam Frame eye tracking to VRChat via OSC
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=${BUILD_DIR}
ExecStart=${BIN_PATH} ${RUN_ARGS[*]}
Restart=on-failure
RestartSec=3
StandardOutput=append:${STATE_DIR}/service.log
StandardError=append:${STATE_DIR}/service.log

[Install]
WantedBy=default.target
SERVICEEOF
}

print_steam_hint() {
  echo
  echo "Steam library:"
  echo "  Frame Eye OSC           (terminal stays open until you stop it in Steam)"
  echo "  Frame Eye OSC Calibrate (spoken instructions + beeps; safe while tracking is already running)"
  echo "  Added as non-Steam games when missing (skipped if already in the library)."
  echo
  echo "  calibrate : $CTL_PATH calibrate"
  echo "         or : bash \"$SCRIPT_PATH\" --calibrate"
  echo "  status    : $CTL_PATH status"
  echo "  stop      : bash \"$SCRIPT_PATH\" --stop"
}

# True when any Steam userdata shortcuts.vdf already lists this exact name
# (NUL-terminated, so "Frame Eye OSC" is not a match for "Frame Eye OSC Calibrate")
# or this desktop-file path.
steam_shortcut_exists() {
  local name="$1" path="$2"
  python3 - "$name" "$path" <<'PY'
import os, pathlib, sys
name, path_s = sys.argv[1], sys.argv[2]
path = pathlib.Path(path_s).expanduser()
try:
    path = path.resolve()
except OSError:
    pass
nul, dq = bytes([0]), bytes([34])
name_b = name.encode("utf-8")
path_b = os.fsencode(str(path))
needles = (name_b + nul, path_b + nul, dq + path_b + dq + nul)
home = pathlib.Path.home()
roots = (
    home / ".steam/steam/userdata",
    home / ".steam/root/userdata",
    home / ".steam/debian-installation/userdata",
    home / ".local/share/Steam/userdata",
    home / ".var/app/com.valvesoftware.Steam/.local/share/Steam/userdata",
)
seen = set()
for root in roots:
    if not root.is_dir():
        continue
    try:
        found = list(root.glob("*/config/shortcuts.vdf")) + list(root.rglob("shortcuts.vdf"))
    except OSError:
        continue
    for vdf in found:
        rp = str(vdf)
        if rp in seen:
            continue
        seen.add(rp)
        try:
            data = vdf.read_bytes()
        except OSError:
            continue
        if any(n in data for n in needles):
            sys.exit(0)
sys.exit(1)
PY
}

# Append a non-Steam shortcut to each real Steam userdata config (used when the
# running client does not write shortcuts.vdf itself).
steam_write_shortcut() {
  local name="$1" path="$2"
  python3 - "$name" "$path" <<'PY'
import os, pathlib, struct, sys, zlib
NUL, SOH, STX, BS, DQ = bytes([0]), bytes([1]), bytes([2]), bytes([8]), bytes([34])
name, path_s = sys.argv[1], sys.argv[2]
exe = str(pathlib.Path(path_s).expanduser().resolve())

def str_field(key, val):
    return SOH + key.encode("utf-8") + NUL + val.encode("utf-8") + NUL

def int_field(key, val):
    return STX + key.encode("utf-8") + NUL + struct.pack("<I", val & 0xffffffff)

def blob(index, appname, exe_path):
    exe_q = chr(34) + exe_path + chr(34)
    start_q = chr(34) + str(pathlib.Path(exe_path).parent) + chr(34)
    appid = (zlib.crc32((exe_q + appname).encode("utf-8")) & 0xffffffff) | 0x80000000
    body = (
        int_field("appid", appid)
        + str_field("AppName", appname)
        + str_field("Exe", exe_q)
        + str_field("StartDir", start_q)
        + str_field("icon", "")
        + str_field("ShortcutPath", "")
        + str_field("LaunchOptions", "")
        + int_field("IsHidden", 0)
        + int_field("AllowDesktopConfig", 1)
        + int_field("AllowOverlay", 1)
        + int_field("OpenVR", 0)
        + int_field("Devkit", 0)
        + str_field("DevkitGameID", "")
        + int_field("LastPlayTime", 0)
        + NUL + b"tags" + NUL + BS
        + BS
    )
    return NUL + str(index).encode("ascii") + NUL + body

def next_index(data):
    i = 0
    while (NUL + str(i).encode("ascii") + NUL) in data:
        i += 1
    return i

def already(data, appname, exe_path):
    name_b = appname.encode("utf-8") + NUL
    path_b = os.fsencode(exe_path)
    return name_b in data or (path_b + NUL) in data or (DQ + path_b + DQ + NUL) in data

home = pathlib.Path.home()
roots = (
    home / ".steam/steam/userdata",
    home / ".steam/root/userdata",
    home / ".steam/debian-installation/userdata",
    home / ".local/share/Steam/userdata",
)
users, seen = [], set()
for root in roots:
    if not root.is_dir():
        continue
    try:
        kids = [p for p in root.iterdir() if p.is_dir()]
    except OSError:
        continue
    for kid in kids:
        key = str(kid.resolve()) if kid.exists() else str(kid)
        if key in seen:
            continue
        seen.add(key)
        users.append(kid)
numeric = [u for u in users if u.name.isdigit() and u.name != "0"]
if numeric:
    users = numeric
if not users:
    for root in roots:
        if root.is_dir() or root.parent.is_dir():
            users = [root / "0"]
            break
wrote_ok = False
for user in users:
    vdf = user / "config" / "shortcuts.vdf"
    try:
        vdf.parent.mkdir(parents=True, exist_ok=True)
        data = vdf.read_bytes() if vdf.is_file() and vdf.stat().st_size > 0 else (NUL + b"shortcuts" + NUL + BS + BS)
        if already(data, name, exe):
            wrote_ok = True
            continue
        entry = blob(next_index(data), name, exe)
        data = (data[:-1] + entry + BS) if data.endswith(BS) else (data + entry + BS)
        tmp = vdf.with_suffix(".vdf.tmp")
        tmp.write_bytes(data)
        tmp.replace(vdf)
        wrote_ok = True
    except OSError:
        pass
sys.exit(0 if wrote_ok else 1)
PY
}

# Add a .desktop file as a non-Steam game. Skip if that name or path is already
# in shortcuts.vdf. Prefer steamos-add-to-steam, then steam://addnonsteamgame/,
# then write shortcuts.vdf if Steam still did not create the entry.
add_nonsteam_game() {
  local file="$1" name="$2" resolved url rc=1 via="none" i
  [[ -f "$file" ]] || return 1
  resolved="$(realpath -- "$file" 2>/dev/null || echo "$file")"
  log "Steam: '$name' — add as a non-Steam game if it is not already there..."
  if steam_shortcut_exists "$name" "$resolved"; then
    log "Steam already has '$name' — not adding a duplicate."
    record "steam" "exists name=$name"
    return 0
  fi
  touch /tmp/addnonsteamgamefile 2>/dev/null || true

  if command -v steamos-add-to-steam >/dev/null 2>&1; then
    set +e
    steamos-add-to-steam "$resolved" >/dev/null 2>&1
    rc=$?
    set -e
    via="steamos-add-to-steam"
  fi
  if [[ $rc -ne 0 ]] && command -v steam >/dev/null 2>&1; then
    url="steam://addnonsteamgame/$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$resolved")"
    set +e
    steam "$url" >/dev/null 2>&1
    rc=$?
    set -e
    via="steam-url"
  fi
  if [[ $rc -ne 0 ]] && command -v xdg-open >/dev/null 2>&1; then
    url="${url:-steam://addnonsteamgame/$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$resolved")}"
    set +e
    xdg-open "$url" >/dev/null 2>&1
    rc=$?
    set -e
    via="xdg-open"
  fi

  for i in 1 2 3 4 5 6; do
    if steam_shortcut_exists "$name" "$resolved"; then
      log "Added '$name' to the Steam library."
      record "steam" "verified name=$name via=$via"
      return 0
    fi
    sleep 0.3
  done

  log "Steam did not write a shortcut yet — writing one into shortcuts.vdf..."
  if steam_write_shortcut "$name" "$resolved" && steam_shortcut_exists "$name" "$resolved"; then
    log "Wrote '$name' into Steam's non-Steam list. Restart Steam (or switch to Game Mode) if it is not visible yet."
    record "steam" "wrote-vdf name=$name"
    return 0
  fi
  warn "Could not add '$name' to Steam automatically. Add it once with: Steam > Games > Add a Non-Steam Game > $resolved"
  record "steam" "failed name=$name via=$via"
  return 1
}

install_launcher() {
  ensure_tts
  write_service_unit
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true

  mkdir -p "$(dirname "$CTL_PATH")" "$(dirname "$DESKTOP_FILE")"
  write_ctl_file

  if command -v konsole >/dev/null 2>&1; then
    steam_exec="$(command -v konsole) --hold -e $CTL_PATH start"
    steam_term=false
  else
    steam_exec="$CTL_PATH start"
    steam_term=true
  fi
  cat > "$DESKTOP_FILE" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Frame Eye OSC
Comment=Forward Steam Frame eye tracking to VRChat (terminal stays open until you stop it)
Exec=$steam_exec
Icon=preferences-desktop-display
Terminal=$steam_term
Categories=Game;Utility;
DESKTOPEOF
  chmod +x "$DESKTOP_FILE"

  cat > "$DESKTOP_CAL_FILE" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Frame Eye OSC Calibrate
Comment=Spoken eyelid calibration (voice + beeps). Safe to run while Frame Eye OSC is already sending.
Exec=$CTL_PATH calibrate-audio
Icon=preferences-desktop-display
Terminal=false
Categories=Game;Utility;
DESKTOPEOF
  chmod +x "$DESKTOP_CAL_FILE"
  update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
  add_nonsteam_game "$DESKTOP_FILE" "Frame Eye OSC" || true
  add_nonsteam_game "$DESKTOP_CAL_FILE" "Frame Eye OSC Calibrate" || true
  record "launcher" "ctl=$CTL_PATH desktop=$DESKTOP_FILE cal=$DESKTOP_CAL_FILE unit=$SERVICE_FILE"
}

# ------------------------------------------------------------------- run! --
run_args

if [[ $WANT_SERVICE -eq 1 ]]; then
  log "Installing the background service..."
  install_launcher
  systemctl --user restart "${SERVICE_NAME}.service"
  record "launch" "mode=service active=$(systemctl --user is-active "${SERVICE_NAME}.service" 2>&1) args=${RUN_ARGS[*]}"
  log "Service running. It starts again by itself whenever you log in."
  print_steam_hint
else
  log "Installing the Steam launcher (service unit enabled, not started — this run stays in the foreground)."
  install_launcher
  record "launch" "mode=foreground unit_installed=yes args=${RUN_ARGS[*]}"
  print_steam_hint
  log "Starting frameeyeosc -> ${TARGET_IP}:${PORT} (prefix $PREFIX). Ctrl+C to stop."
  exec "$BIN_PATH" "${RUN_ARGS[@]}"
fi
