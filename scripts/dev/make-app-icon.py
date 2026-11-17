#!/usr/bin/env python3
"""生成 DSH Mobile 的 App 图标（1024×1024，含深色变体与 App 内模板标志）。

图标是设计资产，不是派生产物——但它必须是**可重画**的：颜色、比例、字重将来都会想改，
而「只有一张 PNG、没人知道怎么改」是设计债。所以图由本脚本画出来，产物入库，
改设计改这里再跑一次即可。

## 这一版画的是什么

尾形直接取 App 内运行时等待行的 `WhaleTailShape`：`ProcessFoldRows.swift` 里那条
16×16 的描边路径，按原段转录成贝塞尔，底端用一段延续切线的浅弧收成尾柄。
这样图标与界面里的尾巴是同一个形状，不靠另外画一只。

- 底色：品牌钴蓝三段斜向渐变，左上与右下各一层柔光，四周压暗。
- 尾形：闭合实心，白到浅蓝的竖向渐变；外缘留一层很弱的冷光。
- 深色变体：同一尾形，底色换深海蓝，尾形亮度不变。

## 用法

    python3 scripts/dev/make-app-icon.py            # 写进 Assets.xcassets
    python3 scripts/dev/make-app-icon.py --preview  # 预览：浅色/深色/白底 + 真实尺寸
    python3 scripts/dev/make-app-icon.py --mark     # 调形状用：轮廓 + 网格 + 节点
    python3 scripts/dev/make-app-icon.py --symbol-only

iOS 的图标规范：不透明、直角、满幅——圆角与遮罩由系统裁，自带圆角反而会被切掉一圈。
"""

import argparse
import json
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

#: 画布。按 4 倍超采样再缩到 1024：曲线边缘靠这一步，不靠运气。
SIZE = 1024
SCALE = 4
CANVAS = SIZE * SCALE

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(REPO, "ios/DSHMobile/DSHMobile/Assets.xcassets")
ICON_SET = os.path.join(ASSETS, "AppIcon.appiconset")
SYMBOL_SET = os.path.join(ASSETS, "TailMark.imageset")

#: 深色变体的夜色：深蓝，不是纯黑——纯黑在 OLED 上与系统界面脱节。
NIGHT_STOPS = [(0.00, (0x36, 0x4C, 0x96)), (0.45, (0x12, 0x1C, 0x46)), (1.00, (0x05, 0x07, 0x12))]
NIGHT_BOKEH = [((0.18, 0.12), 0.80, 0.26, (120, 165, 255)),
               ((0.86, 0.86), 0.80, 0.18, (70, 60, 170))]

#: 浅色变体的钴蓝三段；与 `DSHTheme` 的品牌蓝同源。
DAY_STOPS = [(0.00, (100, 128, 255)), (0.45, (44, 66, 196)), (1.00, (9, 13, 42))]
DAY_BOKEH = [((0.18, 0.12), 0.80, 0.26, (120, 165, 255)),
             ((0.86, 0.86), 0.80, 0.18, (70, 55, 180))]

#: 尾形的竖向渐变：上白下浅蓝，像被上方的光照着。
MARK_STOPS = [(0.00, (255, 255, 255)), (0.48, (252, 253, 255)),
              (0.60, (222, 232, 255)), (1.00, (160, 184, 245))]

#: 运行时 `WhaleTailShape` 的 15 段贝塞尔（16×16 视图框，y 向下）。
SEGMENTS = [
    ((8.967, 12.328), (8.450, 10.400), (8.450, 9.650)),
    ((8.450, 8.940), (8.880, 8.430), (9.600, 8.430)),
    ((11.285, 8.430), (12.106, 8.281), (12.685, 8.104)),
    ((13.710, 7.791), (14.585, 6.768), (15.055, 5.945)),
    ((15.137, 5.803), (14.990, 5.641), (14.829, 5.671)),
    ((13.829, 5.860), (12.828, 5.376), (11.827, 4.978)),
    ((10.659, 4.514), (9.491, 4.707), (8.935, 4.876)),
    ((8.805, 4.915), (8.658, 4.819), (8.636, 4.686)),
    ((8.468, 3.643), (7.405, 2.615), (5.498, 2.238)),
    ((4.540, 2.048), (3.748, 1.574), (3.347, 1.202)),
    ((3.252, 1.113), (3.088, 1.125), (3.030, 1.242)),
    ((2.628, 2.059), (2.168, 3.820), (5.248, 6.115)),
    ((5.820, 6.494), (6.310, 6.785), (6.574, 7.637)),
    ((6.720, 8.104), (6.157, 9.168), (6.061, 9.368)),
    ((5.157, 11.270), (5.089, 12.190), (4.926, 13.742)),
]
START = (8.844, 13.742)
#: 尾柄收口：从右下端沿切线向下绕回右上端（与运行时同一条路径的闭合段）。
CLOSE = ((4.86, 14.55), (8.79, 14.55), (8.844, 13.742))

#: 尾形占画布的比例（按外接方框最长边）。比旧版 0.68 更大，四周不空。
COVERAGE = 0.78
#: 视觉重心的微调：向右、向上各一点。
OFFSET = (0.02, -0.02)


# ---------------------------------------------------------------- 曲线


def cubic_points(p0, c1, c2, p3, steps=64):
    points = []
    for index in range(1, steps + 1):
        t = index / steps
        mt = 1 - t
        points.append((
            mt ** 3 * p0[0] + 3 * mt * mt * t * c1[0] + 3 * mt * t * t * c2[0] + t ** 3 * p3[0],
            mt ** 3 * p0[1] + 3 * mt * mt * t * c1[1] + 3 * mt * t * t * c2[1] + t ** 3 * p3[1],
        ))
    return points


def tail_outline():
    """闭合的尾形轮廓：逐段贝塞尔 + 尾柄收口。"""
    points = [START]
    for control1, control2, end in SEGMENTS + [CLOSE]:
        points += cubic_points(points[-1], control1, control2, end)
    return points


#: 一次算好，画图与调试共用。
OUTLINE = tail_outline()
_XS = [point[0] for point in OUTLINE]
_YS = [point[1] for point in OUTLINE]
BOUNDS = (min(_XS), min(_YS), max(_XS), max(_YS))


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def interpolate(stops, t):
    t = min(max(t, 0.0), 1.0)
    for index in range(len(stops) - 1):
        start, start_colour = stops[index]
        end, end_colour = stops[index + 1]
        if start <= t <= end:
            local = 0 if end == start else (t - start) / (end - start)
            return lerp(start_colour, end_colour, local)
    return stops[-1][1]


def linear_stops(size, stops, angle_deg):
    """斜向渐变：投影到指定角度后分段插值，再按需要缩放。"""
    angle = math.radians(angle_deg)
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    corners = [0.0, cos_a, sin_a, cos_a + sin_a]
    low, high = min(corners), max(corners)
    span = high - low or 1.0
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    for y in range(size):
        v = y / (size - 1)
        for x in range(size):
            u = x / (size - 1)
            pixels[x, y] = interpolate(stops, (u * cos_a + v * sin_a - low) / span)
    return image


def falloff(dx, dy, radius, gamma):
    distance = math.hypot(dx, dy) / radius
    if distance >= 1.0:
        return 0.0
    return (1.0 - distance) ** gamma


def background(dark):
    """底色：斜向三段渐变 + 两层柔光 + 暗角。"""
    steps = 512
    stops = NIGHT_STOPS if dark else DAY_STOPS
    bokeh = NIGHT_BOKEH if dark else DAY_BOKEH
    angle = math.radians(124)
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    corners = [0.0, cos_a, sin_a, cos_a + sin_a]
    low, high = min(corners), max(corners)
    span = high - low or 1.0
    image = Image.new("RGB", (steps, steps))
    pixels = image.load()
    for y in range(steps):
        v = y / (steps - 1)
        for x in range(steps):
            u = x / (steps - 1)
            base = list(interpolate(stops, (u * cos_a + v * sin_a - low) / span))
            for (cx, cy), radius, strength, colour in bokeh:
                light = falloff(u - cx, v - cy, radius, 1.8) * strength
                for channel in range(3):
                    base[channel] += light * colour[channel]
            vignette = 0.84 + 0.16 * falloff(u - 0.5, v - 0.4, 0.95, 1.3)
            pixels[x, y] = tuple(int(min(255, max(0, value * vignette))) for value in base)
    return image.resize((CANVAS, CANVAS), Image.BICUBIC)


def mark_mask(coverage=COVERAGE, offset=OFFSET):
    """尾形的实心遮罩（按画布超采样）。"""
    x0, y0, x1, y1 = BOUNDS
    scale = coverage * CANVAS / max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    dx, dy = offset[0] * CANVAS, offset[1] * CANVAS
    points = [((x - cx) * scale + CANVAS / 2 + dx, (y - cy) * scale + CANVAS / 2 + dy)
              for x, y in OUTLINE]
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def apply_grain(image):
    """细颗粒：只压到几乎看不见，避免大块渐变在 OLED 上台阶。"""
    noise = Image.effect_noise((SIZE, SIZE), 2.0).convert("RGB")
    return Image.blend(image, noise, 0.006)


def compose(dark=False, paper=False):
    """画一张图标：浅色钴蓝 / 深色深海 / 白底蓝尾。"""
    mask = mark_mask()
    clear = Image.new("L", (CANVAS, CANVAS), 0)

    if paper:
        base = Image.new("RGB", (CANVAS, CANVAS), (0xF7, 0xF8, 0xFB))
        shadow = mask.filter(ImageFilter.GaussianBlur(CANVAS * 0.065))
        shadow = ImageChops.offset(shadow, 0, int(CANVAS * 0.016))
        alpha = shadow.point(lambda value: int(value * 0.10))
        image = Image.composite(Image.new("RGB", (CANVAS, CANVAS), (24, 38, 70)), base, alpha)
        ink = linear_stops(512, [(0.0, (91, 118, 255)), (1.0, (47, 79, 214))], 108)
    else:
        image = background(dark)
        glow = mask.filter(ImageFilter.GaussianBlur(CANVAS * 0.03))
        alpha = glow.point(lambda value: int(value * 0.05))
        image = Image.composite(Image.new("RGB", (CANVAS, CANVAS), (190, 215, 255)), image, alpha)
        ink = linear_stops(512, MARK_STOPS, 108)

    ink = ink.resize((CANVAS, CANVAS), Image.BICUBIC)
    image = Image.composite(ink, image, mask)
    return apply_grain(image.resize((SIZE, SIZE), Image.LANCZOS))


def symbol_image(size):
    """App 内模板图：同一份几何，白色 + 遮罩，颜色交给 `foregroundStyle`。"""
    mask = mark_mask(coverage=0.92, offset=(0.0, 0.0)).resize((size, size), Image.LANCZOS)
    image = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    image.putalpha(mask)
    return image


def write_symbol():
    os.makedirs(SYMBOL_SET, exist_ok=True)
    scales = (("1x", 256), ("2x", 512), ("3x", 768))
    for suffix, size in scales:
        symbol_image(size).save(os.path.join(SYMBOL_SET, f"tail-mark-{suffix}.png"))
    contents = {
        "images": [
            {"filename": f"tail-mark-{suffix}.png", "idiom": "universal", "scale": suffix}
            for suffix, _ in scales
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }
    with open(os.path.join(SYMBOL_SET, "Contents.json"), "w") as handle:
        json.dump(contents, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"写入 {SYMBOL_SET}/tail-mark-*.png（模板图）")


def preview(out):
    images = [compose(dark=False), compose(dark=True), compose(paper=True)]
    sheet = Image.new("RGB", (SIZE * 3 + 160, SIZE + 300), (0xF5, 0xF6, 0xF7))
    for column, image in enumerate(images):
        x = 40 + column * (SIZE + 40)
        sheet.paste(image, (x, 60))
        for index, size in enumerate((180, 120, 80, 40)):
            sheet.paste(image.resize((size, size), Image.LANCZOS), (x + index * 200, SIZE + 110))
    sheet.save(out)
    print(out)


def mark_debug(out):
    image = compose(dark=False)
    draw = ImageDraw.Draw(image)
    for index in range(1, 10):
        at = SIZE * index / 10
        draw.line([(at, 0), (at, SIZE)], fill=(255, 90, 90), width=2)
        draw.line([(0, at), (SIZE, at)], fill=(255, 90, 90), width=2)
    x0, y0, x1, y1 = BOUNDS
    scale = COVERAGE * SIZE / max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    for point in OUTLINE[::40]:
        px = (point[0] - cx) * scale + SIZE / 2 + OFFSET[0] * SIZE
        py = (point[1] - cy) * scale + SIZE / 2 + OFFSET[1] * SIZE
        draw.ellipse([px - 3, py - 3, px + 3, py + 3], fill=(255, 210, 90))
    image.save(out)
    print(out)


def main():
    parser = argparse.ArgumentParser(description="生成 DSH Mobile 的 App 图标")
    parser.add_argument("--preview", action="store_true", help="预览图，不写 Assets")
    parser.add_argument("--mark", action="store_true", help="只画轮廓 + 网格 + 采样点")
    parser.add_argument("--out", default=None, help="输出路径")
    parser.add_argument("--variant", default="tile", choices=("tile", "paper"),
                        help="tile = 钴蓝底白尾（默认）；paper = 白底蓝尾")
    parser.add_argument("--symbol-only", action="store_true", help="只出 App 内模板图")
    args = parser.parse_args()

    if args.mark:
        mark_debug(args.out or "/tmp/dsh-icon-mark.png")
        return 0
    if args.preview:
        preview(args.out or "/tmp/dsh-icon-preview.png")
        return 0
    if args.symbol_only:
        write_symbol()
        return 0

    light = compose(dark=False, paper=args.variant == "paper")
    dark = compose(dark=True)
    os.makedirs(ICON_SET, exist_ok=True)
    light_path = os.path.join(ICON_SET, "icon-1024.png")
    dark_path = os.path.join(ICON_SET, "icon-1024-dark.png")
    light.save(light_path)
    dark.save(dark_path)
    print(f"写入 {light_path}")
    print(f"写入 {dark_path}")
    print("提醒：Contents.json 里两张图都要登记，否则 Xcode 只打其中一张进包")
    write_symbol()
    return 0


if __name__ == "__main__":
    sys.exit(main())
