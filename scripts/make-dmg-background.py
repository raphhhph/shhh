#!/usr/bin/env python3
# Draws the DMG window background (Resources/DMG/background.png and @2x).
# Needs Pillow: python3 -m pip install pillow. Layout must match release.sh:
# 660x420 window, Joe icon at (170,190), Applications at (490,190).
from PIL import Image, ImageDraw, ImageFont
import os, sys

OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "DMG")
FONTS = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]

def font(size):
    for f in FONTS:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()

def draw(s):
    W, H = 660 * s, 420 * s
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):  # soft vertical gradient
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(250 - 14 * t), int(248 - 12 * t), int(255 - 8 * t)))
    def center(text, y, size, color):
        f = font(size * s)
        w = d.textlength(text, font=f)
        d.text(((W - w) / 2, y * s), text, font=f, fill=color)
    center("Drag Joe into Applications", 40, 24, (30, 30, 40))
    # Arrow between the two icons
    y = 190 * s
    d.line([(250 * s, y), (400 * s, y)], fill=(120, 110, 230), width=6 * s)
    d.polygon([(410 * s, y), (390 * s, y - 14 * s), (390 * s, y + 14 * s)], fill=(120, 110, 230))
    center("Then open Joe from Applications. First time only:", 262, 13, (70, 70, 85))
    center("if macOS says it can't check Joe, open the \"First open\" guide below.", 282, 13, (70, 70, 85))
    return img

os.makedirs(OUT, exist_ok=True)
draw(1).save(os.path.join(OUT, "background.png"))
draw(2).save(os.path.join(OUT, "background@2x.png"))
print("Wrote", OUT)
