# cachyos-headless-sunshine

Turnkey setup for a headless Linux game-streaming box: a GPU-equipped
machine with an HDMI dummy plug, running [Sunshine](https://github.com/LizardByte/Sunshine)
+ [gamescope](https://github.com/ValveSoftware/gamescope) so a phone/tablet/TV
running [Moonlight](https://moonlight-stream.org/) gets a native-resolution,
HDR-capable stream of Steam Big Picture, with no monitor, keyboard, or mouse
ever attached to the host.

Built and tested on CachyOS (Arch-based) with an NVIDIA RTX 4090, a
Samsung Galaxy Tab S9 Ultra (2960x1848) as the client, and
[this HDMI 2.1 dummy plug](https://a.co/d/08Ff1qnP) (verified against the
4090 -- this is the "genuine HDMI 2.1-class hardware" referenced in
Prerequisites below). Should generalize to other Arch-based distros, other
GPUs, and other resolutions; see **Limitations** below for what's assumed.

## What this actually does

A generic HDMI dummy plug reports a small set of standard resolutions
(1080p, 4K, etc.) in its EDID, not your specific phone/tablet's native
resolution. Left alone, you'd stream at some fallback resolution and the
client would have to scale it, or you'd fight the driver into a custom
resolution every boot. This repo:

1. **Patches the dummy plug's real EDID** to declare your device's native
   resolution as its preferred timing, computed with the standard `cvt -r`
   (CVT reduced-blanking) utility -- not a synthetic/invented mode, a
   legitimate one, while leaving the plug's genuine HDMI/HDR capability
   blocks untouched. Loaded via `drm.edid_firmware=` at boot, so the
   kernel and every userspace consumer see the correct native mode from
   the start.
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
  `xorg-cvt`, `sunshine`, and `steam` itself (enabling the `multilib` repo
  first if needed, since Steam requires it) -- all four are plain packages
  in CachyOS's own repos, no AUR required. Other Arch-based distros should
  work in principle, but CachyOS is what this has actually been run on, and
  package availability/naming may differ elsewhere.
- NVIDIA GPU. This has only been tested with NVIDIA's driver stack; AMD/Intel
  should work for gamescope in general but the capture-backend behavior
  hasn't been verified here.
- An HDMI dummy plug that's **genuine HDMI 2.1-class hardware** with a real
  timing generator -- not a bare-minimum EDID-only plug. Cheap non-HDR dummy
  plugs are usually fine for standard resolutions, but tend to judder badly
  on a custom/non-standard timing, and won't declare HDR capability at all.
  Look for one explicitly advertised as HDMI 2.1 / 4K / HDR.
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

1. Plug in your HDMI dummy plug and confirm the connector name:
   ```
   ls /sys/class/drm/ | grep -i hdmi
   ```
2. Edit `config.sh` -- at minimum set `HDMI_CONNECTOR`, `TARGET_WIDTH`,
   `TARGET_HEIGHT`, `TARGET_REFRESH`, and `PANEL_WIDTH_MM`/`PANEL_HEIGHT_MM`
   to match your streaming client.
3. Run it:
   ```
   sudo ./install.sh
   ```
4. Reboot. The console should come up in gamescope with Steam Big Picture
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
- **Single output**: assumes exactly one HDMI dummy plug / connector is in
  play.
- **Package installation**: assumes CachyOS's repos, where `sunshine` and
  `steam` are plain `pacman` packages. On a distro where either comes from
  the AUR, Flatpak, or somewhere else, install them yourself first and the
  script's `pacman -S --needed ...` call will just no-op past them.

## Troubleshooting

**Steam Big Picture's own UI judders, but games run smoothly.** Check
Steam's Settings -> Interface -> "Enable GPU accelerated rendering in Big
Picture Mode" (wording varies by Steam version). Big Picture's UI is
CEF/Chromium-based; without hardware acceleration it composites in
software and stutters independently of the actual game (which usually gets
direct DRM scan-out from gamescope and isn't affected either way).

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
