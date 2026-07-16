#!/usr/bin/env python3
"""Interactive HDR calibration tool, meant to run as its own Sunshine app
under the gamescope session (see enter-calibration.sh / exit-calibration.sh
and the "Calibrate HDR" entry in apps.json).

gamescope has no live convar for its SDR->HDR inverse-tone-mapping curve
(--hdr-itm-sdr-nits / --hdr-itm-target-nits are startup-only flags), so
"interactive" here means: adjust a value, apply it (which restarts the
gamescope session with the new flags and relaunches this tool), and look
at the actual result on your real display. Not a live-dragging slider --
a tight adjust/restart/look loop instead.

Touch is handled as ordinary mouse clicks (Sunshine/Moonlight forward it
that way). Gamepad uses SDL2's joystick API via pygame.
"""
import os
import pygame

CONFIG_DIR = os.path.expanduser("~/.config/streaming-rig")
HDR_CONF = os.path.join(CONFIG_DIR, "hdr.conf")
SELECTOR = os.path.join(CONFIG_DIR, "next-app")

SDR_MIN, SDR_MAX, SDR_STEP = 50, 500, 25
TARGET_MIN, TARGET_MAX, TARGET_STEP = 200, 4000, 100

BG = (18, 18, 20)
FG = (235, 235, 235)
DIM = (150, 150, 150)
ACCENT = (80, 170, 255)
BUTTON = (45, 45, 50)
BUTTON_FOCUS = (70, 100, 140)


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
    def __init__(self, rect, label, action):
        self.rect = pygame.Rect(rect)
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
    os.environ.setdefault("SDL_VIDEODRIVER", "wayland")
    pygame.init()
    pygame.joystick.init()
    controllers = [pygame.joystick.Joystick(i) for i in range(pygame.joystick.get_count())]
    for c in controllers:
        c.init()

    screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
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
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(SELECTOR, "w") as f:
            f.write("calibrate\n")
        os.system("pkill -u \"$USER\" -x gamescope")

    def exit_to_steam():
        raise SystemExit

    buttons = [
        Button((w * 0.08, h * 0.62, 90, 70), "-", dec_sdr),
        Button((w * 0.08 + 100, h * 0.62, 90, 70), "+", inc_sdr),
        Button((w * 0.55, h * 0.62, 90, 70), "-", dec_target),
        Button((w * 0.55 + 100, h * 0.62, 90, 70), "+", inc_target),
        Button((w * 0.30, h * 0.85, 340, 80), "Apply & Preview", apply_and_restart),
        Button((w * 0.62, h * 0.85, 220, 80), "Exit", exit_to_steam),
    ]
    focus = 0

    patches = 10
    clock = pygame.time.Clock()
    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.MOUSEBUTTONDOWN:
                for b in buttons:
                    if b.rect.collidepoint(event.pos):
                        b.action()
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

        screen.fill(BG)

        title = font_big.render("HDR Calibration", True, FG)
        screen.blit(title, (w * 0.08, h * 0.06))

        instructions = [
            "Adjust the values below, then Apply & Preview to see the real result on your display.",
            "If highlights look flat/grey, raise Peak Brightness. If midtones look too dark, raise White Level.",
            "Gamepad: D-pad left/right to move focus, A to select, B to exit.",
        ]
        for i, line in enumerate(instructions):
            t = font_small.render(line, True, DIM)
            screen.blit(t, (w * 0.08, h * 0.16 + i * 30))

        patch_w = (w * 0.84) / patches
        for i in range(patches):
            level = int(255 * i / (patches - 1))
            rect = pygame.Rect(w * 0.08 + i * patch_w, h * 0.32, patch_w - 6, h * 0.22)
            pygame.draw.rect(screen, (level, level, level), rect)
            label = font_small.render(str(level), True, DIM)
            screen.blit(label, (rect.centerx - label.get_width() / 2, rect.bottom + 6))

        sdr_label = font_mid.render("SDR White Level (nits)", True, FG)
        screen.blit(sdr_label, (w * 0.08, h * 0.56))
        sdr_val = font_big.render(str(sdr_nits), True, ACCENT)
        screen.blit(sdr_val, (w * 0.08 + 210, h * 0.60))

        target_label = font_mid.render("HDR Peak Brightness (nits)", True, FG)
        screen.blit(target_label, (w * 0.55, h * 0.56))
        target_val = font_big.render(str(target_nits), True, ACCENT)
        screen.blit(target_val, (w * 0.55 + 260, h * 0.60))

        for i, b in enumerate(buttons):
            b.draw(screen, font_mid, focused=(i == focus))

        pygame.display.flip()
        clock.tick(30)

    pygame.quit()


if __name__ == "__main__":
    main()
