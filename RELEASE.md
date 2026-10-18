# v0.1.0 — Desktop Mode only

**Date:** 2026-09-28

Setup wrapper around [konsti219/frameeyeosc](https://github.com/konsti219/frameeyeosc) so a Steam Frame can forward eye tracking (gaze and eyelids) to VRChat on your PC over the local network.

## What works

**Only normal Desktop Mode execution works in this release.**

1. Rename `setup_frame_eye_forward_INSERT_LOCAL_IP_HERE.sh` so the filename contains your PC’s local IP.
2. Copy it to the headset.
3. In **Desktop Mode**, open a terminal and run:

```sh
bash setup_frame_eye_forward_<YOUR-PC-IP>.sh
```

That path installs, builds, asks for eyelid calibration (`[ PROCEED ]` + beeps), and keeps tracking running in that terminal until you stop it (Ctrl+C). Recalibrate later with `--calibrate` in the same kind of terminal.

## What does not work yet

The **non-Steam games** the script may add to Steam — **Frame Eye OSC** and **Frame Eye OSC Calibrate** — **do not work yet**. Do not start tracking or calibration from Steam or Game Mode.

`--service` (always-on background unit) is also not a supported launch path in this release.

Use Desktop Mode and the setup script in a terminal until a later release.

## Also in this tree

- Per-eye eyelid calibration on top of upstream frameeyeosc
- IP taken from the setup filename (or `--ip`)
- `README.md` how-to and errors
- Wrapper license: PolyForm Noncommercial (Merkel_User). Upstream frameeyeosc stays MIT (konsti219).

## Credits

- **konsti219** — frameeyeosc
- **Tenebrex** — Steam Frame testing
- **Merkel_User** — this installer / calibration wrapper
