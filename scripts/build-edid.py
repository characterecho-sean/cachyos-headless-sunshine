#!/usr/bin/env python3
"""Build a fully synthetic EDID from scratch -- no real display or dummy
plug involved at any point. Declares a custom resolution as the preferred
timing (via the standard `cvt -r` CVT reduced-blanking utility, not a
hand-rolled implementation) plus HDR10 (ST2084 PQ + HLG EOTFs) and BT.2020
colorimetry capability, and a real HDMI Forum VSDB so high-bandwidth/high
TMDS-rate signaling is declared.

Validated during development with edid-decode: zero warnings/errors on a
plain decode, and a clean PASS under `edid-decode --check` (its strict
conformance mode) with only two benign warnings that are also present on
real, shipping HDMI 2.1/HDR hardware we tested this against (a VIC/DTD
resolution mismatch, which is expected since the preferred timing is a
custom resolution rather than a standard one; and a soft "declare sRGB
too" interop nudge). Verified end-to-end on an RTX 4090 with the
open-source nvidia-open kernel module, gamescope, and Sunshine, HDR
included -- see patch-edid.py for the alternative that patches a real
dummy plug's own EDID instead, if this doesn't work on your setup.
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
    return {
        "pclk_hz": round(pclk_mhz * 1_000_000),
        "hactive": hactive, "hfront": hsyncstart - hactive,
        "hsync": hsyncend - hsyncstart, "hback": htotal - hsyncend,
        "vactive": vactive, "vfront": vsyncstart - vactive,
        "vsync": vsyncend - vsyncstart, "vback": vtotal - vsyncend,
        "hsync_pos": m.group(10) == "+", "vsync_pos": m.group(11) == "+",
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

    hblank = t["hfront"] + t["hsync"] + t["hback"]
    b[2] = lo(t["hactive"])
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
    b[15] = 0
    b[16] = 0

    flags = 0b00011000  # digital separate sync
    if t["vsync_pos"]:
        flags |= 0b00000100
    if t["hsync_pos"]:
        flags |= 0b00000010
    b[17] = flags
    return bytes(b)


def build_dtd_standard_1080p60(mm_width):
    # 1920x1080@60 standard CEA timing, as a sane fallback second DTD.
    # Its own physical size is scaled to 16:9 (not the primary panel's
    # aspect ratio), or edid-decode's image-size-vs-aspect check complains.
    t = {
        "pclk_hz": 148_500_000,
        "hactive": 1920, "hfront": 88, "hsync": 44, "hback": 148,
        "vactive": 1080, "vfront": 4, "vsync": 5, "vback": 36,
        "hsync_pos": True, "vsync_pos": True,
    }
    mm_h_169 = round(mm_width * 1080 / 1920)
    return build_dtd(t, mm_width, mm_h_169)


def mfg_id(s):
    v = ((ord(s[0]) - 64) << 10) | ((ord(s[1]) - 64) << 5) | (ord(s[2]) - 64)
    return bytes([(v >> 8) & 0xFF, v & 0xFF])


def pad13(s):
    data = s.encode("ascii")
    if len(data) >= 13:
        return data[:13]
    return data + b"\n" + b" " * (13 - len(data) - 1)


def fix_checksum(block128):
    block128 = bytearray(block128)
    block128[127] = 0
    block128[127] = (256 - sum(block128) % 256) % 256
    return bytes(block128)


def build_base_block(width, height, refresh, mm_width, mm_height, product_name):
    b = bytearray(128)
    b[0:8] = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    b[8:10] = mfg_id("VRT")               # made-up "Virtual" vendor ID, unregistered
    b[10:12] = (1).to_bytes(2, "little")  # product code
    b[12:16] = (0).to_bytes(4, "little")  # serial: 0 = unspecified
    b[16] = 1                             # week of manufacture
    b[17] = 36                            # year - 1990
    b[18] = 1                             # EDID version
    b[19] = 3                             # EDID revision (1.3)
    b[20] = 0x80                          # digital input
    b[21] = round(mm_width / 10)
    b[22] = round(mm_height / 10)
    b[23] = 120                           # gamma 2.2 -> (2.2 - 1) * 100
    b[24] = 0x0A                          # preferred timing is DTD1; RGB444+YCrCb444
    # Chromaticity: a wide-gamut primary set suitable for HDR content
    # (roughly BT.2020/DCI-P3-ish), not sRGB -- matches the HDR colorimetry
    # declared in the CTA extension below.
    b[25:35] = bytes([0xCF, 0x74, 0xA3, 0x57, 0x4C, 0xB0, 0x23, 0x09, 0x48, 0x4C])
    b[35:38] = bytes([0x21, 0x08, 0x00])   # established timings: 640x480, 800x600, 1024x768
    b[38:54] = bytes([                     # standard timings: 1280x720/960/1024, rest unused
        0x81, 0xC0, 0x81, 0x40, 0x81, 0x80,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    ])

    timing = cvt_reduced_blanking(width, height, refresh)
    b[54:72] = build_dtd(timing, mm_width, mm_height)
    b[72:90] = build_dtd_standard_1080p60(mm_width)

    b[90:108] = bytes([0, 0, 0, 0xFC, 0]) + pad13(product_name)
    b[108:126] = bytes([0, 0, 0, 0xFD, 0, 59, 70, 31, 140, 60, 0x00, 0x0A]) + b" " * 6

    b[126] = 1  # 1 extension block
    return fix_checksum(bytes(b))


def build_cta_extension(max_tmds_mhz):
    blocks = bytearray()
    blocks += bytes([(2 << 5) | 1, 16])                                  # Video Data Block: VIC 16 (1080p60)
    blocks += bytes([(1 << 5) | 3, (1 << 3) | (2 - 1), 0b111, 0b111])     # Audio: LPCM 2ch 32/44.1/48k 16/20/24bit
    blocks += bytes([(4 << 5) | 3, 0x01, 0x00, 0x00])                    # Speaker Allocation: FL/FR

    hdmi_vsdb = bytes([0x03, 0x0C, 0x00, 0x10, 0x00])                    # OUI 00-0C-03 + phys addr 1.0.0.0
    blocks += bytes([(3 << 5) | len(hdmi_vsdb)]) + hdmi_vsdb

    max_tmds_byte = round(max_tmds_mhz / 5)
    hf_vsdb = bytes([0xD8, 0x5D, 0xC4, 0x01, max_tmds_byte, 0x00, 0x00])  # HDMI Forum OUI C4-5D-D8, SCDC/high rate
    blocks += bytes([(3 << 5) | len(hf_vsdb)]) + hf_vsdb

    blocks += bytes([0xE3, 0x05, 0xC0, 0x00])                            # Colorimetry: BT2020cYCC + BT2020RGB
    blocks += bytes([0xE3, 0x06, 0x0D, 0x01])                            # HDR Static Metadata: SDR+PQ+HLG, type1

    # Video Capability Data Block: RGB/YCC quantization range selectable,
    # both over/underscan for IT and CE content. PT=0 (don't duplicate
    # IT/CE -- edid-decode flags PT==IT==CE as redundant/nonsensical).
    # Bit layout: QS(7) QY(6) PT(5-4) IT(3-2) CE(1-0).
    blocks += bytes([0xE2, 0x00, 0b11_00_11_11])

    ext = bytearray(128)
    ext[0] = 0x02  # CTA extension tag
    ext[1] = 0x03  # revision 3
    ext[2] = 4 + len(blocks)  # offset to DTD area (none here, so points past data blocks)
    ext[3] = 0xF0  # underscan + basic audio + YCbCr444 + YCbCr422, 0 native DTDs
    ext[4:4 + len(blocks)] = blocks
    return fix_checksum(bytes(ext))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", required=True)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--refresh", type=int, default=60)
    ap.add_argument("--mm-width", type=int, required=True)
    ap.add_argument("--mm-height", type=int, required=True)
    ap.add_argument("--product-name", default="Virtual HDMI")
    ap.add_argument("--max-tmds-mhz", type=int, default=600)
    args = ap.parse_args()

    base = build_base_block(
        args.width, args.height, args.refresh,
        args.mm_width, args.mm_height, args.product_name,
    )
    ext = build_cta_extension(args.max_tmds_mhz)

    with open(args.output, "wb") as f:
        f.write(base + ext)

    print(
        f"Built synthetic EDID -> {args.width}x{args.height}@{args.refresh}Hz, "
        f"{args.mm_width}x{args.mm_height}mm, HDR10 (PQ+HLG) + BT.2020"
    )


if __name__ == "__main__":
    main()
