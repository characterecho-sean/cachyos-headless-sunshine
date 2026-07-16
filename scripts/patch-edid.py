#!/usr/bin/env python3
"""Patch an EDID's first detailed timing descriptor (DTD1) so an HDMI dummy
plug reports a custom resolution as its preferred/native timing, while
leaving everything else (vendor block, HDMI/HDR capability blocks in the
CTA extension, etc.) untouched.

Timing values come from the system `cvt -r` (CVT reduced-blanking) utility
rather than a hand-rolled implementation, so the generated mode is a
standard, well-tested timing rather than something bespoke.
"""
import argparse
import re
import subprocess
import sys


def cvt_reduced_blanking(width, height, refresh):
    out = subprocess.run(
        ["cvt", "-r", str(width), str(height), str(refresh)],
        check=True, capture_output=True, text=True,
    ).stdout

    m = re.search(
        r'Modeline\s+"\S+"\s+([\d.]+)\s+'
        r'(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+'
        r'(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+'
        r'(\+|-)hsync\s+(\+|-)vsync',
        out,
    )
    if not m:
        raise RuntimeError(f"could not parse cvt output:\n{out}")

    pclk_mhz = float(m.group(1))
    hactive, hsyncstart, hsyncend, htotal = (int(m.group(i)) for i in (2, 3, 4, 5))
    vactive, vsyncstart, vsyncend, vtotal = (int(m.group(i)) for i in (6, 7, 8, 9))
    hsync_pos = m.group(10) == "+"
    vsync_pos = m.group(11) == "+"

    return {
        "pclk_hz": round(pclk_mhz * 1_000_000),
        "hactive": hactive, "hfront": hsyncstart - hactive,
        "hsync": hsyncend - hsyncstart, "hback": htotal - hsyncend,
        "vactive": vactive, "vfront": vsyncstart - vactive,
        "vsync": vsyncend - vsyncstart, "vback": vtotal - vsyncend,
        "hsync_pos": hsync_pos, "vsync_pos": vsync_pos,
    }


def build_dtd(t, mm_width, mm_height):
    def lo(v):
        return v & 0xFF

    def hi4(v):
        return (v >> 8) & 0xF

    b = bytearray(18)
    clk10k = t["pclk_hz"] // 10_000
    b[0] = lo(clk10k)
    b[1] = (clk10k >> 8) & 0xFF

    b[2] = lo(t["hactive"])
    hblank = t["hfront"] + t["hsync"] + t["hback"]
    b[3] = lo(hblank)
    b[4] = (hi4(t["hactive"]) << 4) | hi4(hblank)

    vblank = t["vfront"] + t["vsync"] + t["vback"]
    b[5] = lo(t["vactive"])
    b[6] = lo(vblank)
    b[7] = (hi4(t["vactive"]) << 4) | hi4(vblank)

    b[8] = lo(t["hfront"])
    b[9] = lo(t["hsync"])
    b[10] = ((t["vfront"] & 0xF) << 4) | (t["vsync"] & 0xF)
    b[11] = (
        (((t["hfront"] >> 8) & 0x3) << 6) |
        (((t["hsync"] >> 8) & 0x3) << 4) |
        (((t["vfront"] >> 4) & 0x3) << 2) |
        (((t["vsync"] >> 4) & 0x3))
    )

    b[12] = lo(mm_width)
    b[13] = lo(mm_height)
    b[14] = (((mm_width >> 8) & 0xF) << 4) | ((mm_height >> 8) & 0xF)

    b[15] = 0  # h border
    b[16] = 0  # v border

    flags = 0b00011000  # digital separate sync
    if t["vsync_pos"]:
        flags |= 0b00000100
    if t["hsync_pos"]:
        flags |= 0b00000010
    b[17] = flags

    return bytes(b)


def fix_checksum(block128):
    block128 = bytearray(block128)
    block128[127] = 0
    block128[127] = (256 - sum(block128) % 256) % 256
    return bytes(block128)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, help="raw EDID dump from the dummy plug (128 or 256 bytes)")
    ap.add_argument("--output", required=True, help="path to write the patched EDID")
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--refresh", type=int, default=60)
    ap.add_argument("--mm-width", type=int, required=True, help="physical panel width in mm")
    ap.add_argument("--mm-height", type=int, required=True, help="physical panel height in mm")
    args = ap.parse_args()

    with open(args.input, "rb") as f:
        edid = bytearray(f.read())

    if len(edid) < 128:
        sys.exit(f"input EDID is only {len(edid)} bytes, expected at least 128")

    timing = cvt_reduced_blanking(args.width, args.height, args.refresh)
    dtd = build_dtd(timing, args.mm_width, args.mm_height)
    edid[54:72] = dtd

    # Ensure "first detailed timing is the preferred timing" is set (byte 24, bit 1).
    edid[24] |= 0x02

    # Base-block-level overall image size, in whole cm (legacy/simplified field,
    # separate from the DTD's own per-mode mm size set above).
    edid[21] = round(args.mm_width / 10)
    edid[22] = round(args.mm_height / 10)

    edid[0:128] = fix_checksum(edid[0:128])

    with open(args.output, "wb") as f:
        f.write(edid)

    print(
        f"Patched DTD1 -> {args.width}x{args.height}@{args.refresh}Hz "
        f"({timing['pclk_hz']/1_000_000:.2f} MHz, {args.mm_width}x{args.mm_height}mm)"
    )


if __name__ == "__main__":
    main()
