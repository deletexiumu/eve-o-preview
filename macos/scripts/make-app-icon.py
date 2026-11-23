#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""生成 macos/packaging/AppIcon.png（1024x1024 的 macOS 应用图标）。

图标主体是上游 EveOPlus/eve-o-preview 的分子图标，背景是程序绘制的深空渐变与星点，
不含 CCP 的 EVE 商标或游戏美术。

源图是上游仓库的 assets/molecule-3d-transparent.png（GPL-3.0），
取自 https://github.com/EveOPlus/eve-o-preview 的提交 26470b2。本仓库不收录这张源图，
重新生成图标时先从上游取得，再把路径作为第一个参数传入。

用法：python3 macos/scripts/make-app-icon.py <分子图标 PNG> macos/packaging/AppIcon.png
依赖 Pillow。
"""
# 生成 macOS 风格应用图标：深空渐变圆角方形背景 + 上游分子图标
import random, sys
from PIL import Image, ImageDraw, ImageFilter
src, out = sys.argv[1], sys.argv[2]
N = 1024
canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
# macOS 图标网格：内容方块 824px，四周留 100px，圆角约 185px
box, inset, radius = 824, 100, 185
bg = Image.new("RGBA", (box, box))
d = ImageDraw.Draw(bg)
cx, cy = box * 0.5, box * 0.38
for r in range(int(box * 0.95), 0, -4):
    t = r / (box * 0.95)
    col = (int(20 + 30 * (1 - t)), int(30 + 50 * (1 - t)), int(52 + 90 * (1 - t)), 255)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
random.seed(7)
for _ in range(140):
    x, y = random.random() * box, random.random() * box
    s = random.choice([1, 1, 1, 2, 2, 3])
    a = random.randint(90, 230)
    d.ellipse([x, y, x + s, y + s], fill=(220, 230, 255, a))
mask = Image.new("L", (box, box), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, box - 1, box - 1], radius=radius, fill=255)
# 阴影
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 12, inset + box, inset + box + 12], radius=radius, fill=(0, 0, 0, 110))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
canvas.paste(bg, (inset, inset), mask)
# 内描边
ring = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(ring).rounded_rectangle([inset, inset, inset + box - 1, inset + box - 1], radius=radius, outline=(140, 170, 220, 90), width=3)
canvas.alpha_composite(ring)
# 分子图标，带一圈柔光
mol = Image.open(src).convert("RGBA")
size = int(box * 0.74)
mol = mol.resize((size, size), Image.LANCZOS)
glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
alpha = mol.split()[3].point(lambda v: int(v * 0.55))
tint = Image.new("RGBA", mol.size, (120, 180, 255, 255)); tint.putalpha(alpha)
pos = ((N - size) // 2, (N - size) // 2)
glow.paste(tint, pos, tint)
canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(22)))
canvas.alpha_composite(mol, pos)
canvas.save(out)
