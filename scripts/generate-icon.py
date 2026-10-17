from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import math

S = 2048
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources/AppIcon-1024.png"

def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    px = grad.load()
    for y in range(h):
        px[0, y] = lerp(top, bottom, y / (h - 1))
    return grad.resize((w, h), Image.Resampling.BICUBIC)

def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask

# Canvas and soft drop shadow
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((190, 250, S - 190, S - 150), radius=390, fill=(0, 0, 0, 165))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(70)))

# Main rounded-square background
margin, radius = 180, 390
box = (margin, margin, S - margin, S - margin)
bg = vertical_gradient((S, S), (24, 34, 78), (7, 11, 28)).convert("RGBA")

# Add a radial glow in the upper-left
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
for r, alpha in [(900, 30), (700, 45), (500, 60), (320, 75)]:
    gd.ellipse((620 - r, 520 - r, 620 + r, 520 + r), fill=(58, 92, 255, alpha))
glow = glow.filter(ImageFilter.GaussianBlur(120))
bg.alpha_composite(glow)
bg.putalpha(rounded_mask((S, S), box, radius))
canvas.alpha_composite(bg)

# Inner highlight ring
ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(ring).rounded_rectangle((box[0] + 3, box[1] + 3, box[2] - 3, box[3] - 3),
                                       radius=radius - 3, outline=(255, 255, 255, 32), width=5)
canvas.alpha_composite(ring)

# Tablet shadow
tshadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(tshadow).rounded_rectangle((500, 540, 1560, 1400), radius=120, fill=(0, 0, 0, 190))
canvas.alpha_composite(tshadow.filter(ImageFilter.GaussianBlur(55)))

# Colored rim light behind the tablet
rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
rd = ImageDraw.Draw(rim)
rd.rounded_rectangle((480, 490, 1580, 1400), radius=124, outline=(64, 225, 255, 150), width=18)
rim = rim.filter(ImageFilter.GaussianBlur(30))
canvas.alpha_composite(rim)

# Tablet frame
frame_box = (490, 500, 1570, 1390)
frame = vertical_gradient((S, S), (250, 252, 255), (188, 201, 232)).convert("RGBA")
frame.putalpha(rounded_mask((S, S), frame_box, 120))
canvas.alpha_composite(frame)
fd = ImageDraw.Draw(canvas)
fd.rounded_rectangle(frame_box, radius=120, outline=(255, 255, 255, 235), width=7)

# Screen
screen_box = (540, 550, 1520, 1340)
screen = vertical_gradient((S, S), (18, 28, 68), (6, 9, 22)).convert("RGBA")
screen.putalpha(rounded_mask((S, S), screen_box, 74))
canvas.alpha_composite(screen)

# Screen glow
sglow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sg = ImageDraw.Draw(sglow)
sg.ellipse((700, 650, 1450, 1350), fill=(36, 220, 255, 34))
sg.ellipse((1000, 800, 1600, 1450), fill=(126, 82, 255, 40))
canvas.alpha_composite(sglow.filter(ImageFilter.GaussianBlur(120)))

# Mini desktop: menu bar
fd = ImageDraw.Draw(canvas)
fd.rounded_rectangle((585, 585, 1475, 638), radius=26, fill=(255, 255, 255, 34))
for i, color in enumerate([(255, 95, 86, 220), (255, 189, 46, 220), (39, 201, 63, 220)]):
    cx = 625 + i * 34
    fd.ellipse((cx - 9, 602 - 9, cx + 9, 602 + 9), fill=color)

# Window 1 (blue)
fd.rounded_rectangle((610, 690, 1160, 1110), radius=30, fill=(19, 30, 68, 255))
fd.rounded_rectangle((610, 690, 1160, 758), radius=30, fill=(48, 108, 255, 255))
fd.rounded_rectangle((610, 728, 1160, 758), radius=0, fill=(48, 108, 255, 255))
for i, w in enumerate([380, 300, 430, 250]):
    y = 800 + i * 66
    fd.rounded_rectangle((650, y, 650 + w, y + 24), radius=12, fill=(122, 160, 255, 90))

# Window 2 (violet)
fd.rounded_rectangle((970, 815, 1455, 1215), radius=30, fill=(33, 24, 78, 255))
fd.rounded_rectangle((970, 815, 1455, 880), radius=30, fill=(139, 92, 246, 255))
fd.rounded_rectangle((970, 850, 1455, 880), radius=0, fill=(139, 92, 246, 255))
for i, w in enumerate([300, 360, 240]):
    y = 925 + i * 66
    fd.rounded_rectangle((1010, y, 1010 + w, y + 24), radius=12, fill=(196, 181, 253, 110))

# Cursor with shadow
def cursor(draw, x, y, scale=1.0, fill=(255, 255, 255, 255), outline=(8, 12, 30, 255)):
    pts = [(0, 0), (0, 92), (23, 70), (40, 108), (58, 99), (41, 62), (72, 58)]
    pts = [(x + px * scale, y + py * scale) for px, py in pts]
    draw.polygon(pts, fill=fill, outline=outline)

cursor_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
cursor(ImageDraw.Draw(cursor_shadow), 1195, 1020, 2.0, fill=(0, 0, 0, 180), outline=(0, 0, 0, 180))
canvas.alpha_composite(cursor_shadow.filter(ImageFilter.GaussianBlur(18)))
cursor(fd, 1180, 1005, 2.0)

# Wireless arcs above the tablet, kept inside the rounded background
cx, cy = 1465, 415
for r, width in [(82, 18), (148, 20), (214, 22)]:
    fd.arc((cx - r, cy - r, cx + r, cy + r), start=268, end=356, fill=(96, 235, 255, 235), width=width)
fd.ellipse((cx - 22, cy - 22, cx + 22, cy + 22), fill=(255, 255, 255, 245))

# Tiny sparkles
for dx, dy, r in [(-30, -40, 7), (70, 20, 5), (-90, 30, 4)]:
    fd.ellipse((cx + dx - r, cy + dy - r, cx + dx + r, cy + dy + r), fill=(255, 255, 255, 150))

# Final subtle inner frame highlight
fd.rounded_rectangle((box[0] + 20, box[1] + 20, box[2] - 20, box[3] - 20),
                     radius=radius - 20, outline=(255, 255, 255, 18), width=2)

canvas = canvas.resize((1024, 1024), Image.Resampling.LANCZOS)
canvas.save(str(OUT))
print("wrote", OUT)
