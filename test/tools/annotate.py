#!/usr/bin/env python3
"""Draws the evidence onto a run's screenshots.

A screenshot on its own is ambiguous a week later: which case, which step, what
was being checked, was it good. This writes that onto the image, so the picture
carries its own context and can be reviewed on a phone without the report next
to it.

Usage:
  annotate.py --shots DIR --out DIR --manifest JSON [--meta JSON]
"""

import argparse
import json
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

# The band is drawn at the screenshot's own scale (3x on a modern iPhone), so
# text stays crisp when the image is opened full size.
FONT_PATHS = [
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
]

INK = (245, 246, 248)
DIM = (168, 174, 182)
BAND = (24, 25, 28)
PASS = (34, 197, 94)
FAIL = (239, 68, 68)
WARN = (245, 158, 11)
BRAND = (77, 107, 254)


def font(size):
    for path in FONT_PATHS:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def clean(text):
    """Drops the uniqueness suffix XCTest appends to an attachment name.

    The engine names an attachment `<step>~<name>~<note>`; what comes back is
    `<step>~<name>~<note>_0_<uuid>`. Without this the picture is captioned with a
    UUID, which reads as noise.
    """
    return re.sub(r"_\d+_[0-9A-Fa-f-]{8,}$", "", text or "").strip()


def verdict_colour(verdict):
    return {"pass": PASS, "fail": FAIL, "blocked": WARN}.get(verdict or "", DIM)


def draw_label(draw, xy, text, text_font, fill=INK):
    draw.text(xy, text, font=text_font, fill=fill)


def annotate(path, out_path, entry, meta):
    image = Image.open(path).convert("RGB")
    draw = ImageDraw.Draw(image)
    width, _ = image.size
    scale = width / 402  # points → pixels, so the band scales with the device

    title_font = font(int(15 * scale))
    text_font = font(int(13 * scale))
    small_font = font(int(11 * scale))

    verdict = entry.get("verdict")
    colour = verdict_colour(verdict)

    top = int(46 * scale)
    bottom = int(40 * scale)

    band = Image.new("RGB", (width, top), BAND)
    band_draw = ImageDraw.Draw(band)
    band_draw.rectangle([0, 0, int(4 * scale), top], fill=colour)
    draw_label(band_draw, (int(14 * scale), int(8 * scale)),
               f"{meta.get('case', '')} · 步骤 {entry.get('step', '')} {entry.get('do', '')}", small_font, DIM)
    draw_label(band_draw, (int(14 * scale), int(24 * scale)),
               clean(entry.get("title", ""))[:42], title_font, INK)
    badge = {"pass": "通过", "fail": "失败", "blocked": "未验证"}.get(verdict, "待核对")
    badge_width = int(52 * scale)
    band_draw.rounded_rectangle(
        [width - badge_width - int(12 * scale), int(12 * scale),
         width - int(12 * scale), int(12 * scale) + int(22 * scale)],
        radius=int(6 * scale), fill=colour)
    draw_label(band_draw, (width - badge_width - int(2 * scale), int(15 * scale)), badge, text_font, (10, 12, 14))

    piece = Image.new("RGB", (width, bottom), BAND)
    piece_draw = ImageDraw.Draw(piece)
    draw_label(piece_draw, (int(14 * scale), int(10 * scale)),
               f"运行 {meta.get('run', '')} · 页面 {entry.get('screen', '')} · "
               f"{meta.get('commit', '')} · App {meta.get('appVersion', '')}", small_font, DIM)

    canvas = Image.new("RGB", (width, top + image.height + bottom), BAND)
    canvas.paste(band, (0, 0))
    canvas.paste(image, (0, top))
    canvas.paste(piece, (0, top + image.height))
    draw = ImageDraw.Draw(canvas)

    # The caption the case asked for, so the picture states what it is evidence of.
    note = clean(entry.get("note"))
    if note:
        note_font = font(int(12 * scale))
        note_top = top + image.height - int(34 * scale)
        draw.rectangle([0, note_top, width, top + image.height], fill=(0, 0, 0))
        draw_label(draw, (int(12 * scale), note_top + int(9 * scale)), f"核对：{note}"[:60], note_font, INK)

    for finding in entry.get("findings", []):
        box = finding.get("box")
        if not box:
            continue
        x, y, w, h = box
        draw.rectangle([x * scale, top + y * scale, (x + w) * scale, top + (y + h) * scale],
                       outline=colour if not finding.get("ok") else BRAND, width=max(2, int(2 * scale)))

    canvas.save(out_path, "PNG")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shots", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--manifest", required=True, help="JSON list of screenshot entries")
    parser.add_argument("--meta", default="{}")
    args = parser.parse_args()

    manifest = json.loads(args.manifest)
    meta = json.loads(args.meta)
    os.makedirs(args.out, exist_ok=True)

    done = 0
    for entry in manifest:
        # A requested screenshot whose step never ran has no file at all (the
        # run failed before it, so the engine exported nothing). That is a fact
        # about the run, not a crash: say so and keep annotating the rest.
        if not entry.get("file"):
            print(f"步骤 {entry.get('step', '?')} 没有截图（该步未执行）", file=sys.stderr)
            continue
        source = os.path.join(args.shots, entry["file"])
        if not os.path.exists(source):
            print(f"缺少截图 {entry['file']}", file=sys.stderr)
            continue
        annotate(source, os.path.join(args.out, entry["file"]), entry, meta)
        done += 1
    print(f"annotated {done}/{len(manifest)}")


if __name__ == "__main__":
    main()
