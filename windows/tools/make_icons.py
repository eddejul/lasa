"""Ritar appens ikon (en uppslagen bok) och skriver filerna som Tauri behöver till src-tauri/icons.

  python windows/tools/make_icons.py

Kräver Pillow. Ikonerna checkas in, så skriptet behöver bara köras om ikonen ändras.
"""

import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src-tauri", "icons")
SIZE = 1024
BACKGROUND = (47, 93, 98, 255)   # samma gröna som testbokens omslag
PAPER = (244, 236, 216, 255)     # sepiapapper
INK = (59, 47, 35, 255)


def draw(size=SIZE):
    scale = 4  # rita större och skala ner, så att kanterna blir mjuka
    s = size * scale
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(image)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 0.22), fill=BACKGROUND)

    # Två sidor som lutar svagt mot ryggen i mitten.
    top, bottom = s * 0.27, s * 0.74
    spine = s * 0.5
    gap = s * 0.018
    left_edge, right_edge = s * 0.17, s * 0.83
    sag = s * 0.035
    d.polygon([(left_edge, top + sag), (spine - gap, top), (spine - gap, bottom), (left_edge, bottom + sag)], fill=PAPER)
    d.polygon([(spine + gap, top), (right_edge, top + sag), (right_edge, bottom + sag), (spine + gap, bottom)], fill=PAPER)

    # Textrader på båda sidorna.
    line = s * 0.018
    for i in range(6):
        y = top + s * 0.075 + i * s * 0.065
        width = 0.62 if i == 5 else 1.0
        x0, x1 = left_edge + s * 0.05, spine - gap - s * 0.05
        d.rounded_rectangle([x0, y, x0 + (x1 - x0) * width, y + line], radius=line / 2, fill=INK)
        x0, x1 = spine + gap + s * 0.05, right_edge - s * 0.05
        width = 0.45 if i == 5 else 1.0
        d.rounded_rectangle([x0, y, x0 + (x1 - x0) * width, y + line], radius=line / 2, fill=INK)
    return image.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    big = draw()
    big.save(os.path.join(OUT, "icon.png"))
    for name, size in [("32x32.png", 32), ("128x128.png", 128), ("128x128@2x.png", 256)]:
        big.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name))
    big.save(os.path.join(OUT, "icon.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    for name in sorted(os.listdir(OUT)):
        print(name, os.path.getsize(os.path.join(OUT, name)))


if __name__ == "__main__":
    main()
