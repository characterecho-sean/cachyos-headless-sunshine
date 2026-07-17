#!/usr/bin/env python3
"""Registers the HDR calibration tool as a Steam non-Steam-game shortcut and
generates its library artwork.

gamescope's session-mode compositor only composites a window to the display
once Steam's own focus/IPC handoff has happened for it -- plain X11 hints
aren't enough (see README's HDR calibration section). The reliable way to
get that handoff is to make the tool a genuine Steam library entry (a
"non-Steam game" shortcut) and launch it the same way Steam launches any
real game.

This writes/updates a single "HDR Calibrate" entry in Steam's binary
shortcuts.vdf, and drops matching grid art (portrait/landscape/hero/logo/
icon) into that Steam account's config/grid/ directory. Safe to re-run:
existing shortcuts.vdf entries are parsed and preserved, and our entry (if
already present) is updated in place rather than duplicated. If the file
can't be safely parsed, this aborts *without writing*, since a naive
overwrite would destroy any other non-Steam games already configured.
"""
import argparse
import binascii
import os
import struct
import sys
from collections import OrderedDict

TYPE_MAP = 0x00
TYPE_STRING = 0x01
TYPE_INT32 = 0x02
TYPE_MAP_END = 0x08


def parse_map(buf, pos):
    result = OrderedDict()
    while True:
        type_byte = buf[pos]
        pos += 1
        if type_byte == TYPE_MAP_END:
            return result, pos
        key_end = buf.index(b"\x00", pos)
        key = buf[pos:key_end].decode("utf-8", "replace")
        pos = key_end + 1
        if type_byte == TYPE_MAP:
            value, pos = parse_map(buf, pos)
        elif type_byte == TYPE_STRING:
            val_end = buf.index(b"\x00", pos)
            value = buf[pos:val_end].decode("utf-8", "replace")
            pos = val_end + 1
        elif type_byte == TYPE_INT32:
            value = struct.unpack("<I", buf[pos : pos + 4])[0]
            pos += 4
        else:
            raise ValueError(f"unknown binary VDF type byte {type_byte:#x} at offset {pos - 1}")
        result[key] = value
    # unreachable


def serialize_map(mapping):
    out = []
    for key, value in mapping.items():
        if isinstance(value, dict):
            out.append(b"\x00" + key.encode("utf-8") + b"\x00")
            out.append(serialize_map(value))
        elif isinstance(value, str):
            out.append(b"\x01" + key.encode("utf-8") + b"\x00" + value.encode("utf-8") + b"\x00")
        elif isinstance(value, int):
            out.append(b"\x02" + key.encode("utf-8") + b"\x00" + struct.pack("<I", value & 0xFFFFFFFF))
        else:
            raise TypeError(f"unsupported value type for key {key!r}: {type(value)}")
    out.append(b"\x08")
    return b"".join(out)


def legacy_appid(exe, appname):
    # Steam's "legacy" 32-bit non-Steam-game appid algorithm.
    key = ('"' + exe + '"' + appname).encode("utf-8")
    return binascii.crc32(key) | 0x80000000


def find_steam_userdata_dir(target_home):
    userdata_root = os.path.join(target_home, ".local/share/Steam/userdata")
    if not os.path.isdir(userdata_root):
        return None
    candidates = [
        d for d in os.listdir(userdata_root)
        if d.isdigit() and os.path.isdir(os.path.join(userdata_root, d))
    ]
    if not candidates:
        return None
    if len(candidates) > 1:
        candidates.sort(key=lambda d: os.path.getmtime(os.path.join(userdata_root, d)), reverse=True)
        print(f"    multiple Steam accounts found under {userdata_root}; using the most")
        print(f"    recently used one: {candidates[0]}")
        print(f"    (others found: {', '.join(candidates[1:])} -- if this picked the wrong")
        print("    one, edit shortcuts.vdf under the right ID by hand)")
    return os.path.join(userdata_root, candidates[0])


def load_shortcuts(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return OrderedDict([("shortcuts", OrderedDict())])
    with open(path, "rb") as f:
        data = f.read()
    root, pos = parse_map(data, 0)
    if "shortcuts" not in root:
        root["shortcuts"] = OrderedDict()
    return root


def upsert_shortcut(root, appname, exe, start_dir, appid):
    shortcuts = root["shortcuts"]
    existing_index = None
    for index, entry in shortcuts.items():
        if isinstance(entry, dict) and entry.get("AppName") == appname:
            existing_index = index
            break

    entry = OrderedDict()
    entry["appid"] = appid
    entry["AppName"] = appname
    entry["Exe"] = f'"{exe}"'
    entry["StartDir"] = f'"{start_dir}"'
    entry["icon"] = ""
    entry["ShortcutPath"] = ""
    entry["LaunchOptions"] = ""
    entry["IsHidden"] = 0
    entry["AllowDesktopConfig"] = 1
    entry["AllowOverlay"] = 1
    entry["OpenVR"] = 0
    entry["Devkit"] = 0
    entry["DevkitGameID"] = ""
    entry["DevkitOverrideAppID"] = 0
    entry["LastPlayTime"] = 0
    entry["FlatpakAppID"] = ""
    entry["tags"] = OrderedDict()

    if existing_index is not None:
        shortcuts[existing_index] = entry
    else:
        next_index = 0
        numeric_keys = [int(k) for k in shortcuts.keys() if k.isdigit()]
        if numeric_keys:
            next_index = max(numeric_keys) + 1
        shortcuts[str(next_index)] = entry


# ---- Grid artwork ----
# Dark navy background, a "sunburst" mark, and a warm-to-cool gradient bar
# echoing the calibration tool's own on-screen test pattern (SDR warm/dim ->
# HDR cool/bright), so the shortcut's library tile doesn't look like a
# blank/default Steam icon.
BG_TOP = (10, 12, 18)
BG_BOTTOM = (20, 22, 30)
SDR_COLOR = (255, 150, 60)
HDR_COLOR = (90, 190, 255)
SUN_COLOR = (255, 235, 200, 230)

FONT_CANDIDATES = [
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def load_font(size):
    from PIL import ImageFont

    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def vertical_gradient(draw, box, top, bottom):
    x0, y0, x1, y1 = box
    height = max(1, y1 - y0)
    for i in range(height):
        t = i / height
        color = tuple(int(top[c] + (bottom[c] - top[c]) * t) for c in range(3))
        draw.line([(x0, y0 + i), (x1, y0 + i)], fill=color)


def draw_sunburst(draw, cx, cy, radius):
    import math

    for angle in range(0, 360, 15):
        rad = math.radians(angle)
        x1 = cx + radius * 0.5 * math.cos(rad)
        y1 = cy + radius * 0.5 * math.sin(rad)
        x2 = cx + radius * math.cos(rad)
        y2 = cy + radius * math.sin(rad)
        draw.line([(x1, y1), (x2, y2)], fill=SUN_COLOR, width=int(max(2, radius // 20)))
    draw.ellipse(
        [cx - radius * 0.4, cy - radius * 0.4, cx + radius * 0.4, cy + radius * 0.4],
        fill=SUN_COLOR,
    )


def nits_bar(draw, box, patches=8):
    from PIL import Image

    x0, y0, x1, y1 = box
    width = x1 - x0
    patch_w = width / patches
    for i in range(patches):
        t = i / (patches - 1)
        color = tuple(int(SDR_COLOR[c] + (HDR_COLOR[c] - SDR_COLOR[c]) * t) for c in range(3))
        px0 = x0 + i * patch_w
        draw.rectangle([px0, y0, px0 + patch_w - 4, y1], fill=color)


def base_canvas(w, h):
    from PIL import Image, ImageDraw

    img = Image.new("RGB", (w, h))
    draw = ImageDraw.Draw(img)
    vertical_gradient(draw, (0, 0, w, h), BG_TOP, BG_BOTTOM)
    return img, draw


def draw_wordmark(draw, w, h, cx_frac=0.5, y_frac=0.6, big_size=None, small_size=None):
    big_size = big_size or int(h * 0.11)
    small_size = small_size or int(h * 0.05)
    font_big = load_font(big_size)
    font_small = load_font(small_size)
    hdr_text = "HDR"
    cal_text = "CALIBRATE"
    bbox = draw.textbbox((0, 0), hdr_text, font=font_big)
    tw = bbox[2] - bbox[0]
    draw.text((w * cx_frac - tw / 2, h * y_frac), hdr_text, font=font_big, fill=(255, 255, 255))
    bbox2 = draw.textbbox((0, 0), cal_text, font=font_small)
    tw2 = bbox2[2] - bbox2[0]
    draw.text(
        (w * cx_frac - tw2 / 2, h * y_frac + big_size * 1.15),
        cal_text,
        font=font_small,
        fill=(150, 190, 255),
    )


def make_portrait(grid_dir, appid):
    w, h = 600, 900
    img, draw = base_canvas(w, h)
    draw_sunburst(draw, w * 0.5, h * 0.32, w * 0.28)
    nits_bar(draw, (w * 0.08, h * 0.58, w * 0.92, h * 0.66))
    draw_wordmark(draw, w, h, y_frac=0.74)
    img.save(os.path.join(grid_dir, f"{appid}p.png"))


def make_landscape(grid_dir, appid):
    w, h = 460, 215
    img, draw = base_canvas(w, h)
    draw_sunburst(draw, w * 0.22, h * 0.5, h * 0.38)
    nits_bar(draw, (w * 0.42, h * 0.62, w * 0.94, h * 0.78))
    draw_wordmark(draw, w, h, cx_frac=0.68, y_frac=0.12, big_size=int(h * 0.24), small_size=int(h * 0.11))
    img.save(os.path.join(grid_dir, f"{appid}.png"))


def make_hero(grid_dir, appid):
    w, h = 1920, 620
    img, draw = base_canvas(w, h)
    draw_sunburst(draw, w * 0.15, h * 0.5, h * 0.45)
    nits_bar(draw, (w * 0.35, h * 0.72, w * 0.95, h * 0.84))
    draw_wordmark(draw, w, h, cx_frac=0.65, y_frac=0.15, big_size=int(h * 0.18), small_size=int(h * 0.08))
    img.save(os.path.join(grid_dir, f"{appid}_hero.png"))


def make_logo(grid_dir, appid):
    from PIL import Image, ImageDraw

    w, h = 900, 300
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw_wordmark(draw, w, h, y_frac=0.15, big_size=int(h * 0.32), small_size=int(h * 0.13))
    img.save(os.path.join(grid_dir, f"{appid}_logo.png"))


def make_icon(grid_dir, appid):
    w, h = 256, 256
    img, draw = base_canvas(w, h)
    draw_sunburst(draw, w * 0.5, h * 0.5, w * 0.42)
    img.save(os.path.join(grid_dir, f"{appid}_icon.png"))


def generate_art(config_dir, appid):
    try:
        import PIL  # noqa: F401
    except ImportError:
        print("    python-pillow not available -- skipping Steam grid art generation")
        print("    (the shortcut will still work, just with a blank/default icon)")
        return
    grid_dir = os.path.join(config_dir, "grid")
    os.makedirs(grid_dir, exist_ok=True)
    make_portrait(grid_dir, appid)
    make_landscape(grid_dir, appid)
    make_hero(grid_dir, appid)
    make_logo(grid_dir, appid)
    make_icon(grid_dir, appid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-home", required=True)
    parser.add_argument("--launch-script", required=True, help="Path to hdr-calibrate-launch.sh")
    parser.add_argument("--start-dir", required=True)
    parser.add_argument("--appid-file", required=True)
    parser.add_argument("--gameid-file", required=True)
    args = parser.parse_args()

    config_dir_parent = find_steam_userdata_dir(args.target_home)
    if config_dir_parent is None:
        print("    Steam hasn't logged in yet (no userdata dir found) -- skipping the HDR")
        print("    Calibrate Steam shortcut/artwork for now. Once you've logged into Steam")
        print("    at least once, re-run install.sh to set this up.")
        return

    config_dir = os.path.join(config_dir_parent, "config")
    os.makedirs(config_dir, exist_ok=True)
    shortcuts_vdf = os.path.join(config_dir, "shortcuts.vdf")

    appid = legacy_appid(args.launch_script, "HDR Calibrate")
    gameid = (appid << 32) | 0x02000000

    try:
        root = load_shortcuts(shortcuts_vdf)
        upsert_shortcut(root, "HDR Calibrate", args.launch_script, args.start_dir, appid)
        data = serialize_map(root)
    except Exception as e:
        print(f"    could not safely parse/update {shortcuts_vdf} ({e}) -- leaving it")
        print("    untouched to avoid losing any other non-Steam games already configured.")
        print("    Add the HDR Calibrate shortcut by hand via Steam's own")
        print(f"    'Add a Non-Steam Game' dialog instead, pointing it at {args.launch_script}")
        return

    with open(shortcuts_vdf, "wb") as f:
        f.write(data)

    with open(args.appid_file, "w") as f:
        f.write(str(appid))
    with open(args.gameid_file, "w") as f:
        f.write(str(gameid))

    generate_art(config_dir, appid)

    print(f"    registered as Steam appid {appid}, gameid {gameid}")
    print("    (Steam needs a fresh start to pick this up -- a reboot, per the final step")
    print("    below, is sufficient; if Steam is already running, restart it instead of")
    print("    just re-running this script, since a running Steam can overwrite")
    print("    shortcuts.vdf with its own in-memory state on exit)")


if __name__ == "__main__":
    main()
