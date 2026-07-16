# cachyos-headless-sunshine

Turnkey setup for a headless Linux game-streaming box: a GPU-equipped
machine with **no display or dummy plug attached at all**, running
[Sunshine](https://github.com/LizardByte/Sunshine) +
[gamescope](https://github.com/ValveSoftware/gamescope) so a phone/tablet/TV
running [Moonlight](https://moonlight-stream.org/) gets a native-resolution,
HDR-capable stream of Steam Big Picture, with no monitor, keyboard, or mouse
ever attached to the host.

Built and tested on CachyOS (Arch-based) with an NVIDIA RTX 4090 and a
Samsung Galaxy Tab S9 Ultra (2960x1848) as the client. Should generalize to
other Arch-based distros, other GPUs, and other resolutions; see
**Limitations** below for what's assumed.

## What this actually does

A generic HDMI dummy plug reports a small set of standard resolutions
(1080p, 4K, etc.) in its EDID, not your specific phone/tablet's native
resolution. Left alone, you'd stream at some fallback resolution and the
client would have to scale it, or you'd fight the driver into a custom
resolution every boot. This repo:

1. **Builds a synthetic EDID from scratch** (`EDID_MODE=synthetic`, the
   default -- see Prerequisites) declaring your device's native resolution
   as its preferred timing, computed with the standard `cvt -r` (CVT
   reduced-blanking) utility, plus HDR10 (ST2084 PQ + HLG) and BT.2020
   capability. Loaded via `drm.edid_firmware=` at boot, combined with
   `video=<connector>:e` to force the kernel to treat the connector as
   connected regardless of hotplug/physical detection -- no display or
   dummy plug is ever involved, at setup time or afterward. If this
   doesn't work on your hardware/compositor combination, `EDID_MODE=real`
   falls back to patching a real HDMI 2.1/HDR dummy plug's own EDID
   instead (preserving its genuine capability blocks rather than
   synthesizing them) -- see Prerequisites for when you'd want that.
2. **Installs and configures gamescope** as the display compositor,
   running headless via its DRM backend, pinned to your native
   resolution/refresh, with `--hdr-itm-enabled` so SDR content (which is
   all Proton/XWayland games render, even on a title with no native Linux
   HDR support) gets properly inverse-tone-mapped up to HDR -- rather than
   the raw, un-tone-mapped PQ passthrough you'd get from a plain Wayland
   compositor, which just looks dark and wrong.
3. **Wires up Sunshine's `kms` capture backend**, which reads DRM
   planes/framebuffers directly rather than going through a
   compositor-specific protocol -- it works the same under gamescope as
   under any other Wayland compositor.
4. **Autostarts the whole thing** on an autologin console (tty1), with
   gamescope launching Sunshine and Steam Big Picture as its own children
   so they inherit the right Wayland socket.
5. **Enables a MangoHud performance overlay** via gamescope's own
   `--mangoapp` flag (its recommended way to run MangoHud, rather than
   enabling it on the game or gamescope separately), so you can check
   real in-game frame times/FPS while streaming. Toggle in gamescope's
   Quick Access Menu (see below for how to actually open that on a
   standard controller); set `MANGOHUD_ENABLED=false` in `config.sh` to
   skip it entirely. `gamescope-session.sh` also sets `SteamDeck=1` and
   launches `steam -bigpicture -steamos3`, since Steam's Quick Access Menu
   only exposes the Performance Overlay Level control (which drives the
   MangoHud visibility) when it believes it's running on genuine Deck
   hardware -- it isn't otherwise unlocked on a vanilla desktop Linux +
   gamescope setup. One side effect: this also unlocks Steam's Suspend
   power option, which `install.sh` masks at the systemd level (see
   Prerequisites/below) since a stray button press suspending a headless
   streaming box is a real, observed failure mode, not a hypothetical one.
6. **Installs an interactive HDR calibration tool**, selectable as its own
   "Calibrate HDR" app from Sunshine/Moonlight, so you can tune the
   inverse-tone-mapping curve against your actual display instead of
   guessing at numbers in `config.sh`. See **Calibrating HDR** below.

## Calibrating HDR

gamescope has no live control for its SDR->HDR inverse-tone-mapping curve
(`--hdr-itm-sdr-nits`/`--hdr-itm-target-nits` are startup-only flags), so
this isn't a live-dragging slider -- it's an adjust-and-restart loop:

1. From Moonlight, launch "Calibrate HDR" instead of "Steam". This restarts
   the session (a brief stream interruption, expected) into a fullscreen
   tool showing a grayscale test pattern and the current SDR white
   level / HDR peak brightness values.
2. Adjust the values (touch, or a controller's D-pad to move focus + A to
   select), then hit **Apply & Preview**. This writes
   `~/.config/streaming-rig/hdr.conf` and restarts the session again, so
   you're looking at the *actual* result on your real display, not a
   preview.
3. Repeat until it looks right, then hit **Exit** to return to the normal
   Steam session. Your tuned values persist in `hdr.conf` -- re-running
   `install.sh` won't overwrite them.

A reasonable starting point if you know your display's spec sheet: set
peak brightness close to its published HDR peak nits, and raise or lower
white level if midtones look too dark/washed out.

## Prerequisites

- **A fresh, headless [CachyOS](https://cachyos.org/) install is strongly
  recommended** -- specifically one of CachyOS's minimal/no-desktop
  install options, without a display manager (GDM/SDDM/lightdm) or desktop
  environment installed. This setup takes over tty1 via autologin +
  `.zprofile` to launch gamescope directly; a display manager will fight
  it for that console, and an existing desktop environment brings its own
  compositor, session files, and package conflicts that this repo isn't
  designed to coexist with. Bringing your own already-configured desktop
  machine to this is likely to cause exactly the kind of hard-to-debug
  conflicts this repo is meant to avoid.
- Arch-based distro with `pacman`. The script installs `gamescope`,
  `xorg-cvt`, `sunshine`, `steam`, `mangohud`, and `python-pygame` itself
  (enabling the `multilib` repo first if needed, since Steam requires it)
  -- all plain packages in CachyOS's own repos, no AUR required. Other
  Arch-based distros should work in principle, but CachyOS is what this
  has actually been run on, and package availability/naming may differ
  elsewhere.
- NVIDIA GPU with the open-source `nvidia-open` kernel module. `EDID_MODE=synthetic`
  (the default, no hardware at all) is verified end-to-end -- including
  HDR in an actual game -- on an RTX 4090 with `nvidia-open` and gamescope
  specifically. It relies on the kernel driver implementing the standard
  DRM debugfs `force`/`edid_override` connector interface, which
  `nvidia-open` does; this has **not** been tested on AMD/Intel, on
  NVIDIA's older/fully-closed driver branch, or under a different
  compositor (KDE/GNOME Wayland) -- gamescope was Valve's own compositor,
  reasonably likely to get first-class support here, but that's an
  assumption, not something we've confirmed elsewhere. If `EDID_MODE=synthetic`
  doesn't bring up a connector on your setup, switch to `EDID_MODE=real`
  (below).
- **Only if using `EDID_MODE=real`**: an HDMI dummy plug that's **genuine
  HDMI 2.1-class hardware** with a real timing generator -- not a
  bare-minimum EDID-only plug. Cheap non-HDR dummy plugs are usually fine
  for standard resolutions, but tend to judder badly on a
  custom/non-standard timing, and won't declare HDR capability at all.
  Look for one explicitly advertised as HDMI 2.1 / 4K / HDR --
  [this one](https://a.co/d/08Ff1qnP) is what we used and verified against
  the 4090 before switching to `EDID_MODE=synthetic`. Needs to be
  connected to `HDMI_CONNECTOR` when you run `install.sh` (unlike
  `synthetic` mode, `real` mode relies on genuine hotplug detection, so it
  needs to stay connected afterward too).
- The [Limine](https://github.com/limine-bootloader/limine) bootloader.
  Other bootloaders aren't automated here -- the installer will tell you
  the one kernel cmdline argument to add by hand.
- Autologin configured on a text console (tty1) for the user that will run
  the session -- e.g. a `getty@tty1.service` override with
  `--autologin <user>`. This repo doesn't set that up for you, since it's a
  security-relevant change (anyone with physical/console access gets a
  logged-in shell) that's worth doing deliberately, not silently via a
  script.

## Usage

1. Find your HDMI connector's name -- this works whether or not anything
   is plugged in, since connectors are always listed, just marked
   disconnected when empty:
   ```
   ls /sys/class/drm/ | grep -i hdmi
   ```
2. Decide `EDID_MODE` (see Prerequisites above): `synthetic` (default, no
   hardware needed) or `real` (needs a genuine HDMI 2.1/HDR dummy plug).
   If you're using `real`, plug it into the connector from step 1 now.
3. Edit `config.sh`: set `HDMI_CONNECTOR` to the name from step 1,
   `EDID_MODE` from step 2, and `TARGET_WIDTH`/`TARGET_HEIGHT`/`TARGET_REFRESH`/
   `PANEL_WIDTH_MM`/`PANEL_HEIGHT_MM` to match your streaming client.
4. Run it:
   ```
   sudo ./install.sh
   ```
5. Reboot. The console should come up in gamescope with Steam Big Picture
   running, and Sunshine should be reachable/pairable from Moonlight
   immediately.

`install.sh` is safe to re-run -- it skips steps that are already applied
(EDID registration, kernel cmdline, `.zprofile` block) rather than
duplicating them.

## Limitations / things this doesn't handle

- **Bootloader**: only Limine's kernel cmdline is edited automatically.
  Other bootloaders need the printed `drm.edid_firmware=...` argument added
  by hand.
- **Per-client resolution switching**: this pins gamescope's output to one
  fixed resolution rather than dynamically matching whatever a given
  Moonlight client requests per session. If you stream to multiple
  devices with different native resolutions, you'll want to either pick
  the highest common resolution or extend `install.sh` yourself.
- **Single output**: assumes exactly one HDMI connector is in play.
- **`EDID_MODE=synthetic` portability**: verified end-to-end on an RTX
  4090 with `nvidia-open` and gamescope. It should generalize -- the
  mechanism (DRM debugfs `force`/`edid_override`) is a generic kernel
  interface, not gamescope- or NVIDIA-specific -- but that's untested here
  on AMD/Intel or under KDE/GNOME Wayland. If it doesn't come up on your
  setup, `EDID_MODE=real` with a genuine HDMI 2.1/HDR dummy plug is the
  fallback.
- **Package installation**: assumes CachyOS's repos, where `sunshine` and
  `steam` are plain `pacman` packages. On a distro where either comes from
  the AUR, Flatpak, or somewhere else, install them yourself first and the
  script's `pacman -S --needed ...` call will just no-op past them.

## Troubleshooting

**Opening Steam's Quick Access Menu with a standard (non-Deck) controller.**
A single Guide/Xbox-button press opens Steam's main Big Picture
overlay/home menu -- that's `gamescope`'s `GuideKeyboardHotkey` equivalent.
The Quick Access Menu (QAM) specifically -- the side panel with Performance,
Battery, etc. -- needs Guide+A, and the order matters: **hold Guide down
first, then tap A while still holding Guide**. Pressing them at nearly the
same time, or A before Guide, won't register as the chord. (Confirmed by
watching raw evdev events on Sunshine's virtual gamepad device while
testing -- pressing in the wrong order shows up as two separate button
events with no real overlap, which Steam's chord detection doesn't treat
as "Guide held, A pressed while held.")

**A stray Steam power-menu press could suspend the box.** Since
`gamescope-session.sh` makes Steam believe it's on genuine Deck hardware
(see "What this actually does" above), Steam's Big Picture power menu also
exposes a working Suspend option -- not something you want reachable at
all on a dedicated, always-on streaming appliance. `install.sh` masks
`sleep.target`/`suspend.target`/`hibernate.target`/`hybrid-sleep.target`/
`suspend-then-hibernate.target` at the systemd level, so any suspend
trigger (Steam's menu, `systemctl suspend`, anything) fails harmlessly
instead of actually sleeping the machine. If you ever *want* suspend to
work again: `systemctl unmask <target>...`.

**Steam Big Picture's own UI judders, but games run smoothly.** Big
Picture's UI is CEF/Chromium-based; without hardware acceleration it
composites in software and stutters independently of the actual game
(which usually gets direct DRM scan-out from gamescope and isn't affected
either way). `install.sh` sets this for you (`CEFGPUBlocklistDisabled` and
`GPUAccelWebViewsV3` in `~/.steam/registry.vdf`, the same two keys behind
Steam's Settings -> Interface -> "Enable GPU accelerated rendering in Big
Picture Mode" toggle) -- but only if that file already exists, i.e. Steam
has run at least once. On a genuinely fresh install, `install.sh` runs
*before* Steam's first launch, so the file won't exist yet; re-run
`install.sh` after the first boot to apply it, or just flip the toggle by
hand.

**A specific game caps its resolution below your native resolution, even
though gamescope's output and XRandr both correctly report the full native
size.** Some game engines keep their own hardcoded resolution list/config
independent of what the display reports, and offer only the largest
"standard" size (e.g. 2560x1600) at or below your actual resolution rather
than the exact custom value. If the game stores its display settings in a
plaintext config file (check `~/.local/share/<Studio>/<Game>/` or the
Proton prefix under `steamapps/compatdata/<appid>/pfx/`), you can usually
set the exact width/height there directly, bypassing the in-game dropdown
entirely. Once gamescope's own reported mode list includes your custom
resolution (it generally will, since it always advertises the real current
output mode), the in-game dropdown may pick it up correctly on its own
after that -- worth checking before resorting to manual config edits again.

**Judder even on genuine HDMI 2.1 hardware, at your custom resolution.**
Custom/non-standard pixel clocks are inherently somewhat more prone to
timing jitter than universally standard clocks (1920x1080@60,
3840x2160@60, etc.), even on capable hardware -- there's a real but usually
small cost to being the only device in the world requesting that exact
timing. If you're chasing the last bit of smoothness, A/B testing your
custom resolution against a standard one to size the actual disparity you're 
working with can be useful; Linux capture backends (NvFBC/KMS) also
just have looser frame-pacing than Windows' DXGI Desktop Duplication, an
architectural gap that isn't fully closable from Sunshine's side.

## License

MIT
