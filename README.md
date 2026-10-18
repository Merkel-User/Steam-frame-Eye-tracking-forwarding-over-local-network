# Frame eye forwarding

One script that installs, builds, calibrates and runs **[frameeyeosc](https://github.com/konsti219/frameeyeosc)** on a
**Steam Frame**, so the headset's eye tracking (gaze **and** eyelids) shows up on your avatar in **VRChat** on your PC.

**This release only supports normal Desktop Mode execution.** Rename the script with your PC IP, open a terminal in
Desktop Mode, and run `bash setup_frame_eye_forward_<YOUR-PC-IP>.sh`. The **Frame Eye OSC** / **Frame Eye OSC Calibrate**
items added as non-Steam games are **not working yet** — do not use them from Steam or Game Mode for now.

## Credits

All of the actual technical work — reverse engineering the Frame's private eye-tracking shared memory
(`/dev/shm/eye-server.mmap`), decoding the data layout and sending it out as VRCFT-style OSC parameters — was done by
**[konsti219](https://github.com/konsti219)** in **[konsti219/frameeyeosc](https://github.com/konsti219/frameeyeosc)** (MIT).

This repository contains **only a setup script around it**: dependency installation, building, and an eyelid calibration
step. If frameeyeosc is useful to you, go star the upstream project.

**Thank you Tenebrex** for letting this be tested on their Steam Frame.

## License

This **wrapper** (scripts, README, patches, Steam helpers) is Copyright (c) 2026 **Merkel_User**,
[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0):
use and modify freely for non-commercial purposes if you keep the credit notices; commercial use of the wrapper
needs permission.

**frameeyeosc** remains **MIT**, Copyright (c) 2026 **[konsti219](https://github.com/konsti219)**.
That license is not replaced. Full texts are in [`LICENSE`](LICENSE).

---

## What the script does

1. Installs `git` (via pacman on SteamOS) and **Rust/Cargo** (via rustup into your home directory) if missing.
2. Clones **frameeyeosc** into `~/frameeyeosc` and keeps that copy untouched so `git pull` always works.
3. Copies the source to `~/frameeyeosc-build` and adds **eyelid calibration options** to that copy.
4. Builds the release binary.
5. Asks whether you want to adjust the eyelid calibration, then runs it in the foreground (Desktop Mode terminal).
6. May also write Steam / desktop launchers. **Those non-Steam Game Mode entries do not work yet** — use Desktop Mode only.

### Where things end up

| What | Path |
|---|---|
| Upstream source (never modified) | `~/frameeyeosc` |
| Patched build directory | `~/frameeyeosc-build` |
| Binary | `~/frameeyeosc-build/target/release/frameeyeosc` |
| Your settings and calibration | `~/.config/frameeyeosc/settings.conf` |
| Run log (what happened, for diagnosing) | `~/.local/state/frameeyeosc/setup.log` |
| Background service | `~/.config/systemd/user/frameeyeosc.service` |
| Launcher (Steam-friendly) | `~/.local/bin/frameeyeosc-ctl` |
| Steam / desktop entry | `~/.local/share/applications/frameeyeosc.desktop` |

Nothing is installed system-wide except `git` (only when it's missing).

---

## How to use

### 1. Put your PC's IP in the filename

The script reads the target IP **from its own filename**. Rename the file so it contains the local IP of the PC
running VRChat:

```
setup_frame_eye_forward_INSERT_LOCAL_IP_HERE.sh   ->   setup_frame_eye_forward_192.168.178.71.sh
```

On Windows you can find that IP with `ipconfig` (IPv4 Address). It usually looks like `192.168.x.x`.

### 2. Copy the file to the headset and run it

In Desktop Mode on the Frame, open a terminal (Konsole) and run — from **any** folder:

```sh
bash ~/Downloads/setup_frame_eye_forward_192.168.178.71.sh
```

The first run takes a few minutes (it compiles Rust). Later runs are quick.

### 3. Foreground or background

```sh
bash ~/Downloads/setup_frame_eye_forward_192.168.178.71.sh            # this terminal
bash ~/Downloads/setup_frame_eye_forward_192.168.178.71.sh --service  # background
```

Either way the script can write a systemd user unit and Steam launcher files. **`--service` and the non-Steam Game Mode
entries are not working yet.** Skipping `--service` runs tracking in this Desktop Mode terminal until you press Ctrl+C —
that is the supported path for this release.

### 4. Steam (not working yet)

The script may add **Frame Eye OSC** and **Frame Eye OSC Calibrate** as non-Steam games. **Do not use those library
items in this release.** Tracking and calibration only work when you run the setup script from a **Desktop Mode
terminal**. Game Mode / non-Steam launchers will be wired up in a later release.

### VRChat side (on your PC)

* VRChat must have **OSC enabled** (Action Menu → Options → OSC → Enable).
* Your avatar needs **VRCFaceTracking-style parameters** (`EyeLidLeft`, `EyeLidRight`, `EyeLeftX`, …).
* Windows Firewall must allow **inbound UDP 9000** for VRChat.
* Parameters are sent as `/avatar/parameters/FT/v2/...` with the default prefix `/FT`.

---

## Eyelid calibration (why eyes don't fully close)

The Frame rarely reports a raw openness of exactly `0` when you close your eyes — it may bottom out at `0.2` or so.
Upstream frameeyeosc forwards the raw value unchanged, so your avatar's eyes stay slightly open.

**This script adds a calibration step.** Every interactive run shows a **[ PROCEED ]** prompt. On the input line:

- **Enter** — start guided capture (default)
- **s** — skip this run only
- **m** — type values by hand
- **r** — reset to no calibration

Use `-y` only when you want to skip asking.

Each close/open phase also waits on **[ PROCEED ]**. Then you get **8 seconds** of countdown beeps and **3 seconds** of
recording, using the **average** lid value for each eye. Sounds are **beeps only**. Step 1: eyes stay **open** during the countdown, **close at the high beep**, stay
shut until the **low beep**. Step 2: keep your eyes **wide open** the whole time (do not squint). After the numbers you can keep, redo, or discard.

You can also run the **terminal** calibration on its own (prompts + beeps; skips clone/build if already built):

```sh
bash setup_frame_eye_forward_<YOUR-PC-IP>.sh --calibrate
bash setup_frame_eye_forward_<YOUR-PC-IP>.sh --lid          # same thing
~/.local/bin/frameeyeosc-ctl calibrate                     # after the first full run
```

**Steam Calibrate is not working yet.** Use terminal `--calibrate` in Desktop Mode (prompts + beeps; no voice).

### What the values mean

| Setting | Meaning |
|---|---|
| `LID_MIN_LEFT` / `LID_MIN_RIGHT` | Raw value that should count as **fully closed** for that eye. |
| `LID_MAX_LEFT` / `LID_MAX_RIGHT` | Raw value that should count as **fully open** (wide) for that eye. |
| `LID_OUT_MAX` | What is sent when fully open. `1.0` = full range. Use **`0.75`** if your avatar follows the VRCFT v2 spec, where `0.75` is "fully open" and `0.75–1.0` means "eyes widened". |
| `LID_INVERT` | Set automatically if the headset reports *closedness* instead of openness. |

Each eye is mapped on its own: `output = clamp((raw - min) / (max - min), 0, 1) * LID_OUT_MAX`.

---

## Command reference

```sh
bash setup_frame_eye_forward_<IP>.sh                 # build + run in the foreground
bash setup_frame_eye_forward_<IP>.sh --service       # build + run as a background service
bash setup_frame_eye_forward_<IP>.sh --calibrate     # terminal eyelid calibration (prompts + beeps)
bash setup_frame_eye_forward_<IP>.sh --calibrate-audio  # Steam Calibrate: voice + beeps
bash setup_frame_eye_forward_<IP>.sh --status        # show settings and service state
bash setup_frame_eye_forward_<IP>.sh --stop          # stop and remove the service
bash setup_frame_eye_forward_<IP>.sh --uninstall     # also remove launcher and Steam entry
bash setup_frame_eye_forward_<IP>.sh -y              # never ask anything (keep saved calibration)
bash setup_frame_eye_forward_<IP>.sh --ip 10.0.0.5   # override the IP from the filename
bash setup_frame_eye_forward_<IP>.sh --port 9000 --prefix /FT
```

Service control without the script:

```sh
~/.local/bin/frameeyeosc-ctl start|stop|restart|status|toggle
journalctl --user -u frameeyeosc.service -f          # live log
```

---

## Troubleshooting

Start here: `bash setup_frame_eye_forward_<IP>.sh --status` prints the current settings, the service state and the
last 20 recorded events (patch applied or not, build result, measured eye values, how it was started). Every run
appends to `~/.local/state/frameeyeosc/setup.log`.

### Script won't start

| Message | Cause | Fix |
|---|---|---|
| `bash: ./setup_...sh: Permission denied` | File isn't executable, or it's on a `noexec` mount | Run it as `bash setup_...sh` (always works), or `chmod +x setup_...sh` |
| `bad interpreter: No such file or directory` | Windows line endings (CRLF) | `sed -i 's/\r$//' setup_...sh` |
| `ERROR: No PC IP found.` | Filename has no valid IP | Rename to `setup_frame_eye_forward_192.168.178.71.sh` or pass `--ip 192.168.178.71` |
| `ERROR: Unknown option '--x'` | Typo in a flag | Run with `--help` |

### Install and build problems

| Message | Cause | Fix |
|---|---|---|
| `Could not install git` | SteamOS read-only filesystem or pacman keys | `sudo steamos-readonly disable`, then `sudo pacman-key --init && sudo pacman-key --populate`, then retry |
| `sudo: no password was provided` | The `deck`/user account has no password yet | Run `passwd` once to set one |
| `python3 is required` | python3 missing (very unusual on SteamOS) | `sudo pacman -S python` |
| `error: linker 'cc' not found` | No build tools | `sudo steamos-readonly disable && sudo pacman -S --needed base-devel && sudo steamos-readonly enable` |
| `Cargo still not available` | rustup installed but not on PATH in this shell | `source ~/.cargo/env`, or open a new terminal |
| `... exists but is not a git checkout` | Leftover `~/frameeyeosc` folder | `rm -rf ~/frameeyeosc` and re-run |
| `Could not add the calibration options` | Upstream changed its source | The script falls back to plain upstream; calibration is then unavailable |
| Everything breaks after a SteamOS update | System updates wipe pacman packages | Re-run the script; Rust in `~/.cargo` survives, `git` may be reinstalled |

### It builds but there is no eye data

| Message | Cause | Fix |
|---|---|---|
| `No such file or directory (os error 2)` | `/dev/shm/eye-server.mmap` doesn't exist — the eye service isn't running | Put the headset on, make sure eye tracking is enabled, run **Settings → Display → Eye Tracking Calibration** |
| `eye shared memory is not initialized` | Eye service started but has no data yet | Wear the headset and wait a few seconds, then restart the script |
| `unsupported eye shared-memory version N; expected 4` | A Frame OS update changed the internal layout | Wait for an upstream fix in [frameeyeosc](https://github.com/konsti219/frameeyeosc) — this script can't work around it |
| `Permission denied` on `/dev/shm/eye-server.mmap` | Running as a different user than the eye service | Run as your normal user, not with `sudo` |
| `No eye data was received` during calibration | Same causes as above | Fix eye tracking first, then re-run `--calibrate` |

### Data is sent but VRChat shows nothing

| Symptom | Cause | Fix |
|---|---|---|
| Nothing moves at all | Wrong IP in the filename | Check `ipconfig` on the PC, rename the file, re-run |
| Nothing moves, IP is right | Windows Firewall blocks UDP 9000 | Allow inbound UDP 9000 for VRChat |
| Nothing moves, firewall is open | VRChat OSC disabled, or a stale OSC config | Enable OSC in the Action Menu; reset the avatar's OSC config |
| Eyes move, eyelids don't | Avatar has no `EyeLid` parameters | Use a VRCFT-ready avatar, or add `v2/EyeLidLeft` and `v2/EyeLidRight` |
| Only some parameters arrive | Prefix mismatch | Match `--prefix` to what your avatar expects (default `/FT`) |

### Eye behaviour is wrong

| Symptom | Cause | Fix |
|---|---|---|
| **Eyes never fully close** | Raw openness never reaches 0 | Run `--calibrate` and pick guided measurement |
| Eyes always closed | Value is inverted | `--calibrate` detects this automatically, or set `LID_INVERT=1` |
| Eyes look permanently wide | Avatar follows VRCFT v2 where `0.75` is fully open | Set `LID_OUT_MAX` to `0.75` via the manual calibration option |
| Blinks are twitchy | Calibration range too narrow | Re-run `--calibrate` and hold your eyes properly closed, then properly open |
| `Closed and open values are too close` | Eye tracking isn't really tracking | Run **Settings → Display → Eye Tracking Calibration** on the headset first |

### Service and Steam entry

**Not supported in this release.** If a non-Steam **Frame Eye OSC** / **Calibrate** item appears in Steam, ignore it and
run the script from a Desktop Mode terminal instead. `--service` is also not a supported launch path yet.

---

## Uninstall

```sh
bash setup_frame_eye_forward_<IP>.sh --uninstall   # service, launcher, Steam entry
rm -rf ~/frameeyeosc ~/frameeyeosc-build ~/.config/frameeyeosc ~/.local/state/frameeyeosc
```

Rust itself can be removed with `rustup self uninstall`.

---

## Notes

* The forwarding only works while the headset and the PC are on the **same network**.
* The script never modifies `~/frameeyeosc`; all changes happen in `~/frameeyeosc-build`.
* frameeyeosc reads a **private, undocumented** interface of the Frame. A headset update can break it at any time.
