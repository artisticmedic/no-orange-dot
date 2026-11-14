#!/usr/bin/env python3
"""Turns an icon study into a shippable 1024 px master: finds the tile, puts it on the standard
macOS icon grid (824 px tile, 100 px margin) and cuts a clean rounded edge.
Usage: make-icons.py <source.png> <out.png>   (needs Pillow)"""
import sys
from PIL import Image, ImageDraw

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
box = im.split()[3].point(lambda v: 255 if v > 200 else 0).getbbox()
tile = im.crop(box)
# The tile's own colour, taken just inside its left edge, fills any gap the new corners expose.
w, h = tile.size
bg = tile.getpixel((int(w * 0.06), h // 2))[:3] + (255,)
SIZE, TILE, RADIUS, GROW = 1024, 824, 186, 12
tile = tile.resize((TILE + GROW * 2, TILE + GROW * 2), Image.LANCZOS).crop((GROW, GROW, GROW + TILE, GROW + TILE))
flat = Image.new("RGBA", (TILE, TILE), bg)
flat.alpha_composite(tile)
S = 4
mask = Image.new("L", (TILE * S, TILE * S), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, TILE * S - 1, TILE * S - 1), radius=RADIUS * S, fill=255)
flat.putalpha(mask.resize((TILE, TILE), Image.LANCZOS))
canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
canvas.alpha_composite(flat, ((SIZE - TILE) // 2, (SIZE - TILE) // 2))
canvas.save(out)
print(out, "tile found at", box, "fill", bg)
