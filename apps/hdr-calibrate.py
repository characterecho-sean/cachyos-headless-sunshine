#!/usr/bin/env python3
"""Interactive HDR calibration tool, registered as a non-Steam game shortcut
(see hdr-calibrate-launch.sh and shortcuts.vdf) so Steam's own IPC with
gamescope handles focus/compositing, same as launching any real game.

gamescope has no live convar for its SDR->HDR inverse-tone-mapping curve
(--hdr-itm-sdr-nits / --hdr-itm-target-nits are startup-only flags), so
"interactive" here means: adjust a value, apply it (which restarts the
gamescope session with the new flags and relaunches this tool), and look
at the actual result on your real display. Not a live-dragging slider --
a tight adjust/restart/look loop instead.

This only affects SDR content gamescope is inverse-tone-mapping up to HDR --
a game with its own native HDR output bypasses this entirely (gamescope's
ITM "only works for SDR input"), so a game like that needs its own in-game
HDR calibration/peak-brightness setting instead. See README's HDR section.

Touch/mouse clicks are handled (MOUSEBUTTONDOWN and FINGERDOWN both hit-test
the same padded button rects), but absolute pointer positioning is currently
unreliable here due to a known upstream gamescope bug that collapses touch/
absolute-mouse position to a small area near screen center regardless of
where the input actually lands (see ValveSoftware/gamescope#1141, #1540,
#1748 -- open/unresolved as of gamescope 3.16.24). Gamepad is the reliable
input method until that's fixed upstream; it uses SDL2's GameController API
(named buttons/axes, consistent across controllers) via pygame.controller.
"""
import os
import time
import pygame

CONFIG_DIR = os.path.expanduser("~/.config/streaming-rig")
HDR_CONF = os.path.join(CONFIG_DIR, "hdr.conf")
RESUME_FLAG = os.path.join(CONFIG_DIR, "resume-calibrate")

SDR_MIN, SDR_MAX, SDR_STEP = 50, 500, 25
TARGET_MIN, TARGET_MAX, TARGET_STEP = 200, 4000, 100

BG = (18, 18, 20)
FG = (235, 235, 235)
DIM = (150, 150, 150)
ACCENT = (80, 170, 255)
BUTTON = (45, 45, 50)
BUTTON_FOCUS = (70, 100, 140)

# Gradient endpoints for the saturated "warm highlight" test row: deep orange
# haze up to a pale, near-white sunlit highlight. Neutral grayscale patches
# alone can't reveal highlight clipping/hue-shift -- OLED panels (especially
# phone-class ones) have much less color volume at high luminance for
# saturated hues like red/orange than they do for neutral white, so a curve
# that looks fine on grayscale can still crush warm highlights to a flat,
# detail-less patch. This row makes that failure visible directly.
WARM_LO = (200, 80, 30)
WARM_HI = (255, 205, 140)


def read_hdr_conf():
    values = {"SDR_NITS": 100, "TARGET_NITS": 1000}
    if os.path.exists(HDR_CONF):
        with open(HDR_CONF) as f:
            for line in f:
                line = line.strip()
                if "=" not in line or line.startswith("#"):
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                if key in values:
                    try:
                        values[key] = int(val.strip())
                    except ValueError:
                        pass
    return values["SDR_NITS"], values["TARGET_NITS"]


def write_hdr_conf(sdr_nits, target_nits):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(HDR_CONF, "w") as f:
        f.write(f"SDR_NITS={sdr_nits}\n")
        f.write(f"TARGET_NITS={target_nits}\n")


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


class Button:
    # Hit-test area is padded beyond the drawn rect -- a fingertip on a
    # tablet touchscreen covers more area than it visually looks like it
    # does, so matching the drawn size exactly makes edge taps miss.
    HIT_PAD = 18

    def __init__(self, rect, label, action):
        self.rect = pygame.Rect(rect)
        self.hit_rect = self.rect.inflate(self.HIT_PAD * 2, self.HIT_PAD * 2)
        self.label = label
        self.action = action

    def draw(self, surf, font, focused):
        color = BUTTON_FOCUS if focused else BUTTON
        pygame.draw.rect(surf, color, self.rect, border_radius=10)
        if focused:
            pygame.draw.rect(surf, ACCENT, self.rect, width=3, border_radius=10)
        text = font.render(self.label, True, FG)
        surf.blit(text, text.get_rect(center=self.rect.center))


def main():
    # gamescope exposes its nested Wayland socket as GAMESCOPE_WAYLAND_DISPLAY,
    # not the plain WAYLAND_DISPLAY that SDL's wayland backend actually reads
    # (it defaults to "wayland-0", which doesn't exist here) -- so a wayland
    # SDL_VIDEODRIVER always fails outright, no matter how long you retry.
    # gamescope also runs an embedded Xwayland (DISPLAY=:0), which Steam and
    # other apps already rely on in this same session -- use that instead.
    os.environ.setdefault("SDL_VIDEODRIVER", "x11")

    # Kept as a defensive retry in case Xwayland itself isn't quite up yet
    # this early in gamescope's startup, even though DISPLAY is already set.
    screen = None
    last_err = None
    for _ in range(60):
        try:
            pygame.init()
            screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
            break
        except pygame.error as e:
            last_err = e
            pygame.quit()
            time.sleep(0.5)
    else:
        raise last_err

    pygame.joystick.init()
    # Some of Sunshine's other virtual input devices (touch/pen/mouse
    # passthrough) can enumerate here alongside the real gamepad without
    # actually being openable as a joystick -- skip whichever ones fail
    # rather than letting one bad device crash the whole app. Keyed by SDL
    # instance id (not slot index) so a reconnect -- which gets a new
    # instance id -- is handled as "add", not confused with the old one.
    controllers = {}

    def add_joystick(device_index):
        try:
            c = pygame.joystick.Joystick(device_index)
            c.init()
            controllers[c.get_instance_id()] = c
        except pygame.error:
            pass

    for i in range(pygame.joystick.get_count()):
        add_joystick(i)

    # Restrict SDL to only the event types we actually handle. Sunshine's
    # virtual controller emits newer SDL2 controller event types (battery /
    # touchpad / sensor updates) that this pygame build has no name for --
    # left unfiltered, pygame.event.get() crashes translating them
    # ("SystemError: <built-in function get> returned a result with an
    # exception set", root cause "KeyError: 1"). Blocking them at the SDL
    # level means they're dropped before pygame ever tries to translate them.
    pygame.event.set_allowed([
        pygame.QUIT,
        pygame.MOUSEBUTTONDOWN,
        pygame.KEYDOWN,
        pygame.JOYHATMOTION,
        pygame.JOYBUTTONDOWN,
        pygame.JOYDEVICEADDED,
        pygame.JOYDEVICEREMOVED,
        pygame.MOUSEMOTION,
        # Moonlight/Sunshine can forward taps as genuine SDL touch events
        # (FINGERDOWN) rather than emulated mouse clicks, depending on
        # client/host touch settings -- without these explicitly allowed,
        # SDL drops every tap before the app ever sees it: no crash, no
        # click, nothing.
        pygame.FINGERDOWN,
        pygame.FINGERMOTION,
    ])

    pygame.display.set_caption("HDR Calibration")
    pygame.mouse.set_visible(True)
    w, h = screen.get_size()

    font_big = pygame.font.SysFont(None, 72)
    font_mid = pygame.font.SysFont(None, 40)
    font_small = pygame.font.SysFont(None, 28)

    sdr_nits, target_nits = read_hdr_conf()

    def dec_sdr():
        nonlocal sdr_nits
        sdr_nits = clamp(sdr_nits - SDR_STEP, SDR_MIN, SDR_MAX)

    def inc_sdr():
        nonlocal sdr_nits
        sdr_nits = clamp(sdr_nits + SDR_STEP, SDR_MIN, SDR_MAX)

    def dec_target():
        nonlocal target_nits
        target_nits = clamp(target_nits - TARGET_STEP, TARGET_MIN, TARGET_MAX)

    def inc_target():
        nonlocal target_nits
        target_nits = clamp(target_nits + TARGET_STEP, TARGET_MIN, TARGET_MAX)

    def apply_and_restart():
        write_hdr_conf(sdr_nits, target_nits)
        # gamescope's --hdr-itm-*-nits flags are startup-only, so picking up
        # the new values means restarting the whole session. Leave a flag
        # so streaming-session.sh knows to relaunch us (via the Steam
        # shortcut) once Steam is back up, landing the user right back in
        # the calibration screen. Backgrounded with a short delay so this
        # click's own input event and any in-flight frame finish first,
        # rather than cutting the stream off mid-event.
        open(RESUME_FLAG, "w").close()
        os.system("(sleep 2; pkill gamescope) >/dev/null 2>&1 &")

    def exit_to_steam():
        raise SystemExit

    # Mobile OLEDs limit sustained brightness by lit area (ABL) much more
    # aggressively than they limit a few small patches -- a haze/sky region
    # covering 15-20% of the frame can get crushed/hue-shifted even when a
    # small swatch of the same color renders cleanly. These modes swap the
    # warm row for one big block so that area-dependent clipping (as opposed
    # to a plain nits-curve problem) can be told apart from the small-patch
    # gradient above. Saturated (not just bright/pale) is deliberately
    # included: highlights staying reddish-orange and losing detail (rather
    # than washing out toward white) is the failure mode worth checking for.
    WARM_MODES = ["small", "large_saturated", "large_mid", "large_pale"]
    warm_mode_i = [0]

    def cycle_warm_mode():
        warm_mode_i[0] = (warm_mode_i[0] + 1) % len(WARM_MODES)

    buttons = [
        Button((w * 0.08, h * 0.78, 90, 70), "-", dec_sdr),
        Button((w * 0.08 + 100, h * 0.78, 90, 70), "+", inc_sdr),
        Button((w * 0.55, h * 0.78, 90, 70), "-", dec_target),
        Button((w * 0.55 + 100, h * 0.78, 90, 70), "+", inc_target),
        Button((w * 0.30, h * 0.90, 340, 80), "Apply & Preview", apply_and_restart),
        Button((w * 0.62, h * 0.90, 220, 80), "Exit", exit_to_steam),
        Button((w * 0.83, h * 0.46, 150, 44), "Cycle Test", cycle_warm_mode),
    ]
    focus = 0

    patches = 10
    clock = pygame.time.Clock()
    running = True
    while running:
        # pygame.event.get() can itself throw ("SystemError: <built-in
        # function get> returned a result with an exception set", root
        # cause a KeyError deep in pygame's C event translation -- looks
        # tied to a joystick device index/instance id, not the event type,
        # since restricting allowed types didn't stop it). Treat it as a
        # dropped frame of input rather than a fatal crash.
        try:
            events = pygame.event.get()
        except SystemError:
            pygame.event.clear()
            events = []
        for event in events:
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.MOUSEMOTION:
                # Highlights the button under the finger/cursor, same as
                # gamepad/keyboard focus -- gives touch users visible
                # confirmation of what a tap will hit before they commit.
                for i, b in enumerate(buttons):
                    if b.hit_rect.collidepoint(event.pos):
                        focus = i
                        break
            elif event.type == pygame.MOUSEBUTTONDOWN:
                for i, b in enumerate(buttons):
                    if b.hit_rect.collidepoint(event.pos):
                        focus = i
                        b.action()
                        break
            elif event.type in (pygame.FINGERMOTION, pygame.FINGERDOWN):
                # SDL reports finger position normalized to 0.0-1.0, not
                # pixels like mouse events -- scale to the window size
                # before reusing the same hit-test as the mouse path.
                pos = (event.x * w, event.y * h)
                for i, b in enumerate(buttons):
                    if b.hit_rect.collidepoint(pos):
                        focus = i
                        if event.type == pygame.FINGERDOWN:
                            b.action()
                        break
            elif event.type == pygame.KEYDOWN:
                if event.key in (pygame.K_LEFT,):
                    focus = (focus - 1) % len(buttons)
                elif event.key in (pygame.K_RIGHT,):
                    focus = (focus + 1) % len(buttons)
                elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
                    buttons[focus].action()
                elif event.key == pygame.K_ESCAPE:
                    running = False
            elif event.type == pygame.JOYHATMOTION:
                if event.value[0] == -1:
                    focus = (focus - 1) % len(buttons)
                elif event.value[0] == 1:
                    focus = (focus + 1) % len(buttons)
            elif event.type == pygame.JOYBUTTONDOWN:
                # Standard SDL mapping for Xbox-style pads: 0=A, 1=B
                if event.button == 0:
                    buttons[focus].action()
                elif event.button == 1:
                    running = False
            elif event.type == pygame.JOYDEVICEADDED:
                # A timeout/reconnect (Sunshine's virtual controller drops
                # after inactivity) gets a brand-new SDL instance id -- the
                # old Joystick object is dead and never fires events again,
                # so without this the app looks frozen to the gamepad until
                # force-quit. Re-opening on reconnect is what picks it back
                # up.
                add_joystick(event.device_index)
            elif event.type == pygame.JOYDEVICEREMOVED:
                controllers.pop(event.instance_id, None)

        screen.fill(BG)

        title = font_big.render("HDR Calibration", True, FG)
        screen.blit(title, (w * 0.08, h * 0.06))

        instructions = [
            "Adjust the values below, then Apply & Preview to see the real result on your display.",
            "If highlights look flat/grey, raise Peak Brightness. If midtones look too dark, raise White Level.",
            "Warm row below: if the right-hand patches look flat/identical or shift toward pure red instead of",
            "gradually getting brighter, Peak Brightness is set too high for this display -- lower it and retest.",
            "Gamepad: D-pad left/right to move focus, A to select, B to exit.",
        ]
        for i, line in enumerate(instructions):
            t = font_small.render(line, True, DIM)
            screen.blit(t, (w * 0.08, h * 0.12 + i * 26))

        patch_w = (w * 0.84) / patches

        gray_caption = font_small.render("Neutral steps", True, DIM)
        screen.blit(gray_caption, (w * 0.08, h * 0.245))
        for i in range(patches):
            level = int(255 * i / (patches - 1))
            rect = pygame.Rect(w * 0.08 + i * patch_w, h * 0.27, patch_w - 6, h * 0.13)
            pygame.draw.rect(screen, (level, level, level), rect)
            label = font_small.render(str(level), True, DIM)
            screen.blit(label, (rect.centerx - label.get_width() / 2, rect.bottom + 6))

        warm_mode = WARM_MODES[warm_mode_i[0]]
        warm_caption = font_small.render(f"Warm highlight (haze/sunset test) -- {warm_mode}", True, DIM)
        screen.blit(warm_caption, (w * 0.08, h * 0.46))
        if warm_mode == "small":
            for i in range(patches):
                t = i / (patches - 1)
                color = tuple(int(WARM_LO[c] + (WARM_HI[c] - WARM_LO[c]) * t) for c in range(3))
                rect = pygame.Rect(w * 0.08 + i * patch_w, h * 0.485, patch_w - 6, h * 0.13)
                pygame.draw.rect(screen, color, rect)
        else:
            # One block the size of the whole row -- mimics a large in-game
            # haze/sky region instead of a small swatch, to reveal
            # area-dependent ABL clipping. Three fixed points along the ramp
            # (saturated / mid / pale) since the failure mode reported is
            # staying reddish rather than washing out toward white.
            t = {"large_saturated": 0.0, "large_mid": 0.5, "large_pale": 1.0}[warm_mode]
            color = tuple(int(WARM_LO[c] + (WARM_HI[c] - WARM_LO[c]) * t) for c in range(3))
            rect = pygame.Rect(w * 0.08, h * 0.485, w * 0.84, h * 0.13)
            pygame.draw.rect(screen, color, rect)

        sdr_label = font_mid.render("SDR White Level (nits)", True, FG)
        screen.blit(sdr_label, (w * 0.08, h * 0.66))
        sdr_val = font_big.render(str(sdr_nits), True, ACCENT)
        screen.blit(sdr_val, (w * 0.08 + 210, h * 0.70))

        target_label = font_mid.render("HDR Peak Brightness (nits)", True, FG)
        screen.blit(target_label, (w * 0.55, h * 0.66))
        target_val = font_big.render(str(target_nits), True, ACCENT)
        screen.blit(target_val, (w * 0.55 + 260, h * 0.70))

        for i, b in enumerate(buttons):
            b.draw(screen, font_mid, focused=(i == focus))

        pygame.display.flip()
        clock.tick(30)

    pygame.quit()


if __name__ == "__main__":
    main()
