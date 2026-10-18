#!/usr/bin/env bash
# Shared helpers for Frame eye forwarding scripts (source, do not execute directly).

frame_eye_bundle_dir() {
  if [[ -n "${FRAME_EYE_BUNDLE_DIR:-}" ]]; then
    echo "$FRAME_EYE_BUNDLE_DIR"
    return
  fi
  local src
  if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
    src="${BASH_SOURCE[1]}"
  else
    src="${BASH_SOURCE[0]}"
  fi
  if [[ "$src" != /* ]]; then
    src="$(pwd)/$src"
  fi
  dirname "$src"
}

apply_frameeyeosc_lid_patch() {
  local install_dir="$1"
  local bundle_dir="$2"
  local patch_file="${bundle_dir}/patches/frameeyeosc-lid-calibration.patch"
  local marker="${install_dir}/.frame-eye-lid-patch-applied"

  [[ -f "$patch_file" ]] || die "Missing patch file: $patch_file (copy the whole 'Frame eye forwarding' folder to the headset)."

  if [[ -f "$marker" ]]; then
    log "Eyelid calibration patch already applied."
    return 0
  fi

  log "Applying eyelid calibration patch to frameeyeosc..."
  if patch -d "$install_dir" -p1 --forward --batch < "$patch_file"; then
    touch "$marker"
    log "Patch applied."
  else
    die "Failed to apply $patch_file — frameeyeosc source may have changed upstream."
  fi
}

prompt_lid_calibration() {
  local conf="${HOME}/.config/frame-eye-forward/lid.defaults"
  mkdir -p "$(dirname "$conf")"

  local def_min="0.0" def_max="1.0" def_scale="1.0"
  if [[ -f "$conf" ]]; then
    # shellcheck disable=SC1090
    source "$conf"
  fi

  echo
  echo "=== Eyelid calibration ==="
  echo "Maps raw Frame eye openness to VRChat. Press Enter to keep the shown default."
  echo "If eyes won't fully close in-game, raise min and/or lower max (e.g. min=0.2 max=0.85)."
  read -rp "  Raw value when your eyes are fully CLOSED [${def_min}]: " LID_MIN
  read -rp "  Raw value when your eyes are fully OPEN  [${def_max}]: " LID_MAX
  read -rp "  Lid scale after normalize (0.5–1.5)     [${def_scale}]: " LID_SCALE

  LID_MIN="${LID_MIN:-$def_min}"
  LID_MAX="${LID_MAX:-$def_max}"
  LID_SCALE="${LID_SCALE:-$def_scale}"

  cat > "$conf" <<EOF
def_min='${LID_MIN}'
def_max='${LID_MAX}'
def_scale='${LID_SCALE}'
EOF
}

lid_cli_args() {
  printf -- '--lid-min %s --lid-max %s --lid-scale %s' "$LID_MIN" "$LID_MAX" "$LID_SCALE"
}

install_steam_launcher() {
  local bundle_dir="$1"
  local launch_name="${2:-launch_frame_eye_forward.sh}"
  local dest_dir="${HOME}/.local/share/frame-eye-forward"
  local dest_launch="${dest_dir}/launch.sh"
  local apps_dir="${HOME}/.local/share/applications"
  local desktop_file="${apps_dir}/frame-eye-forward.desktop"

  mkdir -p "$dest_dir" "$apps_dir"
  cp "${bundle_dir}/${launch_name}" "$dest_launch"
  cp "${bundle_dir}/frame_eye_common.sh" "${dest_dir}/frame_eye_common.sh"
  chmod +x "$dest_launch"

  cat > "$desktop_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Frame Eye Forward
GenericName=VRChat eye OSC
Comment=Forward Steam Frame eye tracking to VRChat (asks lid calibration each run)
Exec=${dest_launch}
Path=${HOME}
Terminal=true
Categories=Game;
StartupNotify=true
EOF

  if [[ -d "${HOME}/Desktop" ]]; then
    cp "$desktop_file" "${HOME}/Desktop/frame-eye-forward.desktop"
  fi

  log "Steam / desktop launcher installed:"
  echo "  ${desktop_file}"
  echo "  In Steam (Desktop Mode): Library → Add a Game → Add a Non-Steam Game"
  echo "  → enable 'Show all' → select 'Frame Eye Forward' → Add Selected Programs"
}
