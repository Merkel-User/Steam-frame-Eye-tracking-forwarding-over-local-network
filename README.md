# Steam-frame-Eye-tracking-forwarding-over-local-network
A programm that should make it easy to use the Eyetracking from the Steam Frame over the local network for Games Like VR Chat


Swap 192.168.1.50 for your PC's actual IP. It handles: installing Rust if missing, installing git if missing, cloning/updating frameeyeosc, building it, and either running it live or setting it up as a systemd user service so it just runs automatically going forward.

To get it onto the headset: open the Frame's browser in Desktop Mode and download it from this chat, or drop it on a USB stick and copy it over.

One honest caveat: since frameeyeosc is such a new, minimally-tested project, the build step is the part most likely to hit a snag (e.g. a missing compiler) — the script will tell you the exact pacman command to run if that happens.

Source is  https://github.com/konsti219/frameeyeosc.git
they made all the technical stuff im just trying to make the install faster
