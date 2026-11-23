#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""从 shared/branding/logo-source.jpg（白底的 Q 版小死神）生成两个平台的应用图标。

生成的文件：
- macos/packaging/AppIcon.png：1024x1024 的 macOS 应用图标。按 macOS 的图标网格画深空渐变圆角方块，
  角色加白色贴纸描边放在上面。build-app.sh 再由它生成 icns。
- windows/crates/eveo-app/assets/app.ico：exe 与托盘用的图标，不画底板（Windows 的图标没有统一形状）。
  48 像素及以上用整个角色；32 像素及以下只用头部，整个角色缩到这么小认不出来。
- windows/crates/eveo-ui/ui/images/app-icon.png：设置窗口标题栏与任务栏用的 64 像素头像，与 ico 的小尺寸一致。

用法（在仓库根目录）：python3 shared/branding/make-icons.py
依赖 Pillow 与 numpy。
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "shared/branding/logo-source.jpg"
MAC_ICON = ROOT / "macos/packaging/AppIcon.png"
WIN_ICO = ROOT / "windows/crates/eveo-app/assets/app.ico"
WIN_PNG = ROOT / "windows/crates/eveo-ui/ui/images/app-icon.png"

# 原图里被线条围住、但属于背景的两块空隙（镰刀弯里、刀柄与下巴之间），各取一个内部的点作种子。
ENCLOSED_GAPS = [(358, 706), (517, 572)]
# 头部（兜帽与骷髅脸）在原图里的范围：左、上、右、下。小尺寸图标只用这一块。
HEAD_BOX = (395, 0, 1220, 580)
# 头部范围左下角的刀柄：裁头部时把这个多边形擦成透明，只留兜帽与骷髅脸。
HANDLE_CUT = [(395, 478), (505, 468), (565, 520), (565, 580), (395, 580)]
# ico 里放的尺寸；32 及以下用头部。
ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
HEAD_MAX = 32


def cut_out(path: Path) -> Image.Image:
    """把白底变透明：与图边相连的白色和 ENCLOSED_GAPS 两块空隙。线条边缘按亮度给半透明，去掉白边。"""
    rgb = Image.open(path).convert("RGB")
    w, h = rgb.size
    # 白色像素的掩码，外面补一圈白，让四条边上的白色区域连成一片，一次泛洪就能取到。
    white = rgb.convert("L").point(lambda v: 255 if v > 225 else 0)
    padded = Image.new("L", (w + 2, h + 2), 255)
    padded.paste(white, (1, 1))
    ImageDraw.floodfill(padded, (0, 0), 128)
    for x, y in ENCLOSED_GAPS:
        assert padded.getpixel((x + 1, y + 1)) == 255, f"种子 {x},{y} 不在白色空隙里"
        ImageDraw.floodfill(padded, (x + 1, y + 1), 128)
    bg = np.asarray(padded.crop((1, 1, w + 1, h + 1))) == 128
    # 背景外扩 3 像素的环：线条与白底混合的抗锯齿像素。
    grown = np.asarray(Image.fromarray(bg.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(7))) > 0
    rim = grown & ~bg
    a = np.asarray(rgb).astype(float)
    lum = a.mean(axis=2)
    alpha = np.ones(lum.shape)
    alpha[bg] = 0
    alpha[rim] = np.clip((255 - lum[rim]) / (255 - 40), 0, 1)
    # 半透明处还原前景色：像素 = α·前景 + (1-α)·白。
    al = alpha[..., None]
    fg = np.clip((a - (1 - al) * 255) / np.maximum(al, 1e-3), 0, 255)
    color = np.where(rim[..., None], fg, a)
    return Image.fromarray(np.dstack([color, alpha * 255]).astype(np.uint8), "RGBA")


def head(art: Image.Image) -> Image.Image:
    """头部：裁出 HEAD_BOX，擦掉左下角露出的刀柄。"""
    art = art.copy()
    alpha = art.split()[3]
    ImageDraw.Draw(alpha).polygon(HANDLE_CUT, fill=0)
    art.putalpha(alpha)
    return art.crop(HEAD_BOX)


def sticker(art: Image.Image, width: int, stroke: int, glow: tuple | None = None) -> Image.Image:
    """把角色缩放到给定宽度，加白色贴纸描边（可选外发光），四周留出描边与发光的空间。"""
    height = round(art.height * width / art.width)
    art = art.resize((width, height), Image.LANCZOS)
    pad = stroke * 3
    layer = Image.new("RGBA", (width + 2 * pad, height + 2 * pad), (0, 0, 0, 0))
    layer.alpha_composite(art, (pad, pad))
    # 描边：不透明区域向外扩 stroke 像素，再轻微模糊抗锯齿。MaxFilter 的核必须是奇数。
    mask = layer.split()[3].filter(ImageFilter.MaxFilter(2 * stroke + 1))
    mask = mask.point(lambda v: 255 if v > 40 else 0).filter(ImageFilter.GaussianBlur(max(stroke / 14, 0.6)))
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    if glow:
        halo = Image.new("RGBA", layer.size, glow)
        halo.putalpha(mask.point(lambda v: v // 2))
        out.alpha_composite(halo.filter(ImageFilter.GaussianBlur(stroke * 1.5)))
    white = Image.new("RGBA", layer.size, (245, 248, 255, 255))
    white.putalpha(mask)
    out.alpha_composite(white)
    out.alpha_composite(layer)
    return out


def square(img: Image.Image, size: int) -> Image.Image:
    """把图等比放进 size 见方的透明画布正中。"""
    scale = size / max(img.size)
    fitted = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(fitted, ((size - fitted.width) // 2, (size - fitted.height) // 2))
    return canvas


def mac_icon(art: Image.Image) -> Image.Image:
    """macOS 图标：1024 画布，内容方块 824、四周留 100、圆角约 185（macOS 图标网格），深空渐变加星点。"""
    n, box, inset, radius = 1024, 824, 100, 185
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    bg = Image.new("RGBA", (box, box))
    d = ImageDraw.Draw(bg)
    # 偏上的径向渐变：中心亮、四周暗的深蓝。
    cx, cy = box * 0.5, box * 0.38
    for r in range(int(box * 0.95), 0, -4):
        t = r / (box * 0.95)
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=(int(20 + 30 * (1 - t)), int(30 + 50 * (1 - t)), int(52 + 90 * (1 - t)), 255))
    # 固定种子的星点，每次生成结果相同。
    rng = np.random.default_rng(7)
    for _ in range(140):
        x, y = rng.random() * box, rng.random() * box
        s = int(rng.choice([1, 1, 1, 2, 2, 3]))
        d.ellipse([x, y, x + s, y + s], fill=(220, 230, 255, int(rng.integers(90, 231))))
    mask = Image.new("L", (box, box), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, box - 1, box - 1], radius=radius, fill=255)
    # 底板的投影与内描边。
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 12, inset + box, inset + box + 12],
                                             radius=radius, fill=(0, 0, 0, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    canvas.paste(bg, (inset, inset), mask)
    ring = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle([inset, inset, inset + box - 1, inset + box - 1],
                                           radius=radius, outline=(140, 170, 220, 90), width=3)
    canvas.alpha_composite(ring)
    # 角色宽占内容方块的 84%，带淡蓝外发光，略向下放（兜帽比镰刀高，视觉上居中）。
    figure = sticker(art, int(box * 0.84), 8, glow=(120, 180, 255, 255))
    canvas.alpha_composite(figure, ((n - figure.width) // 2, (n - figure.height) // 2 + 10))
    return canvas


def windows_icons(art: Image.Image) -> list[Image.Image]:
    """Windows 图标的各个尺寸：大尺寸是整个角色，小尺寸是头部，都带白色贴纸描边，深浅色任务栏上都看得清。"""
    full = square(sticker(art, 960, 26), 256)
    bust = square(sticker(head(art), 960, 40), 256)
    return [(bust if size <= HEAD_MAX else full).resize((size, size), Image.LANCZOS) for size in ICO_SIZES]


def main() -> None:
    art = cut_out(SOURCE)
    mac_icon(art).save(MAC_ICON)
    icons = windows_icons(art)
    WIN_ICO.parent.mkdir(parents=True, exist_ok=True)
    # Pillow 写 ico 时按 sizes 从最大的一张缩放；各尺寸用 append_images 传入，保留小尺寸的头像。
    icons[-1].save(WIN_ICO, format="ICO", sizes=[(s, s) for s in ICO_SIZES], append_images=icons[:-1])
    WIN_PNG.parent.mkdir(parents=True, exist_ok=True)
    # 设置窗口的图标用头像：标题栏 16、任务栏 24～32 像素，与 ico 的小尺寸一致。
    square(sticker(head(art), 960, 40), 64).save(WIN_PNG)


if __name__ == "__main__":
    main()
