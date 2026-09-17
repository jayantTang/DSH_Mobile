#!/usr/bin/env python3
"""生成 DSH Mobile 的 App 图标（1024×1024，含深色变体）。

图标是设计资产，不是派生产物——但它必须是**可重画**的：颜色、比例、字重将来都会想改，
而「只有一张 PNG、没人知道怎么改」是设计债。所以图由本脚本画出来，产物入库，
改设计改这里再跑一次即可。

风格参照 **DeepSeek 官方 App 图标**（App Store 上的 `DeepSeek - AI 智能助手`）：
一只卷身下潜的鲸、大量留白、柔和的立体感（受光面一圈浅高光 + 背光面一圈内阴影 +
一层很浅的投影）。官方版是白底蓝鲸；本 App 有自己的身份，所以底色沿用品牌深蓝渐变、
鲸取白色，形状是**自己的画法**——同一族的意象，不是他们那条路径的描摹。

怎么画出这条鲸（调形状只需要动 `SPINE` 与那几个零件参数，配合 `--mark` 看效果）：

- 鲸身是一条**沿样条走的带子**：`SPINE` 给控制点与半宽，`catmull_rom()` 插成光滑脊线，
  再按半宽向两侧摊开、两端补半圆帽。控制点可以直接读图改，不像手拉贝塞尔一改就鼓包。
- 头、尾、背鳍、胸鳍各自是一个小多边形，与鲸身**并集**：同色所以接缝看不见，
  每个零件各自平滑，比硬拼一条闭合路径好调。
- 眼睛与嘴线是**负空间**（挖空），透出底下的渐变；高光与投影都从同一张遮罩派生，
  形状永远一致。

iOS 的图标规范：不透明、直角、满幅——圆角与遮罩由系统裁，自带圆角反而会被切掉一圈。

用法：
    python3 scripts/dev/make-app-icon.py            # 写进 Assets.xcassets
    python3 scripts/dev/make-app-icon.py --preview  # 预览：两版大图 + 真实尺寸阶梯
    python3 scripts/dev/make-app-icon.py --mark     # 调形状用：标志 + 网格 + 脊线控制点
"""

import argparse
import json
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

#: 画布。按 4 倍超采样再缩到 1024：圆头线帽与渐变边缘靠的是这一步，不靠运气。
SIZE = 1024
SCALE = 4
CANVAS = SIZE * SCALE

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(REPO, "ios/DSHMobile/DSHMobile/Assets.xcassets")
ICON_SET = os.path.join(ASSETS, "AppIcon.appiconset")
SYMBOL_SET = os.path.join(ASSETS, "TailMark.imageset")

#: DeepSeek 蓝的三个步进，与 `DSHTheme.usageLow/Mid/High` 同源。
BRAND_LIGHT = (0x7C, 0x9B, 0xFF)
BRAND = (0x4D, 0x6B, 0xFE)
BRAND_DEEP = (0x1E, 0x30, 0x93)

#: 深色变体的夜色：近黑的蓝，不是纯黑——纯黑在 OLED 上与系统界面脱节。
NIGHT_TOP = (0x14, 0x1B, 0x33)
NIGHT_BOTTOM = (0x07, 0x0A, 0x14)


# ---------------------------------------------------------------- 标的几何
#
# 标的是一只**举起的鲸尾**：两片叶向上张开、中间一个 V 形缺口，下面收成尾柄。
# 坐标是标志框内的比例（0..1，y 向下）。左半边手写，右半边由它镜像出来——
# 对称是这类标志的命门，靠眼睛对齐永远差一两个像素。
#
# 为什么不是整只卷身的鲸：那个姿势要靠在圆环上摊一条带子才好看，手调的参数一多就走形
# （试过十版，尾鳍与头总是散架）。举尾是鲸最好认、也最容易画准的那一面，缩到 40pt
# 还是一只鲸尾；官方那只卷身鲸是专业画的路径，本 App 不描摹它。

#: 尾柄左下角，轮廓从这里出发。
TAIL_START = (0.418, 0.985)

#: 左半边轮廓：(控制点, 锚点)。锚点是拐角（叶根、叶尖、缺口），控制点给这一段定弧度。
#: 顺序：尾柄左侧 → 叶根 → 外缘 → 叶尖 → 内缘 → V 形缺口（落在对称轴上）。
TAIL_HALF = [
    ((0.396, 0.930), (0.400, 0.850)),   # 尾柄左侧
    ((0.302, 0.788), (0.238, 0.768)),   # 叶根外缘
    ((0.128, 0.680), (0.070, 0.470)),   # 外缘中段：最外凸的地方
    ((0.030, 0.300), (0.042, 0.150)),   # 外缘上段
    ((0.030, 0.082), (0.080, 0.038)),   # 叶尖（拐角，尖端略向外勾）
    ((0.150, 0.120), (0.248, 0.224)),   # 内缘上段：从叶尖往下收
    ((0.318, 0.318), (0.372, 0.442)),   # 内缘中段
    ((0.436, 0.520), (0.500, 0.605)),   # V 形缺口底部（拐角，在对称轴上）
]

#: 尾柄下缘的弧度：底边不是直线，向下鼓一点，收口才圆。
TAIL_BASE = (0.500, 1.030)

#: 标的占画布的比例（按外接方框的最长边算）。四周留白是「不挤」的来源。
COVERAGE = 0.68


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def vertical_gradient(size, stops):
    """把 (位置, 颜色) 列表画成一条竖直渐变。"""
    image = Image.new("RGB", (1, size))
    pixels = image.load()
    for y in range(size):
        t = y / max(1, size - 1)
        # 找到 t 落在哪一段，段内线性插值——三段比两段多一口气，过渡不显生硬。
        for index in range(len(stops) - 1):
            start, start_colour = stops[index]
            end, end_colour = stops[index + 1]
            if start <= t <= end:
                local = 0 if end == start else (t - start) / (end - start)
                pixels[0, y] = lerp(start_colour, end_colour, local)
                break
        else:
            pixels[0, y] = stops[-1][1]
    return image.resize((size, size), Image.NEAREST)


def radial_glow(size, centre, radius, colour, peak):
    """一层柔和的光：中心 peak 不透明度，向外二次衰减到 0。

    用一条径向渐变尺再缩放，不逐像素循环——4096² 的逐像素版本在纯 Python 里要几秒，
    而这里每张图标要画两次。
    """
    step = 512
    gradient = Image.new("L", (step, step), 0)
    pixels = gradient.load()
    for y in range(step):
        for x in range(step):
            distance = math.hypot(x - (step - 1) / 2, y - (step - 1) / 2) / ((step - 1) / 2)
            if distance >= 1.0:
                continue
            falloff = 1 - distance
            pixels[x, y] = int(255 * peak * falloff * falloff)
    scale = radius * size / step
    big = gradient.resize((max(1, int(step * scale)),) * 2, Image.BICUBIC)
    layer = Image.new("L", (size, size), 0)
    layer.paste(big, (int(centre[0] * size - big.width / 2),
                      int(centre[1] * size - big.height / 2)))
    return Image.new("RGB", (size, size), colour), layer


# ---------------------------------------------------------------- 曲线工具


def catmull_rom(points, steps=24):
    """Catmull-Rom 样条：曲线过每一个控制点，改控制点就是改形状。

    端点各复制一次，曲线自然收在两端，不会甩出去。维度不限——半宽也走这条样条，
    只插位置、宽度走折线的话，带子在控制点处会出现硬折角。
    """
    padded = [points[0]] + list(points) + [points[-1]]
    out = []
    for index in range(len(padded) - 3):
        p0, p1, p2, p3 = padded[index:index + 4]
        for step in range(steps):
            t = step / steps
            t2, t3 = t * t, t * t * t
            out.append(tuple(
                0.5 * ((2 * p1[k]) + (-p0[k] + p2[k]) * t
                       + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2
                       + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3)
                for k in range(len(p1))))
    out.append(tuple(points[-1]))
    return out


def closed_spline(points, steps=12):
    """闭合的 Catmull-Rom：首尾相接的一圈锚点插成光滑轮廓。

    鳍与尾叶用它画：锚点点在形状的拐角上，曲线自己圆过去，比逐条手拉贝塞尔好调，
    也不会在两条曲线的接头处留下折角。
    """
    wrapped = [points[-1]] + list(points) + [points[0], points[1]]
    out = []
    for index in range(len(wrapped) - 3):
        p0, p1, p2, p3 = wrapped[index:index + 4]
        for step in range(steps):
            t = step / steps
            t2, t3 = t * t, t * t * t
            out.append(tuple(
                0.5 * ((2 * p1[k]) + (-p0[k] + p2[k]) * t
                       + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2
                       + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3)
                for k in range(len(p1))))
    out.append(points[0])
    return out


def bezier(p0, p1, p2, steps=20):
    """二次贝塞尔：鳍的边缘有一点弧度才不像三角形，一个控制点就够。"""
    out = []
    for index in range(steps + 1):
        t = index / steps
        m = 1 - t
        out.append((m * m * p0[0] + 2 * m * t * p1[0] + t * t * p2[0],
                    m * m * p0[1] + 2 * m * t * p1[1] + t * t * p2[1]))
    return out


def ellipse_points(centre, radii, angle_deg, steps=64):
    """旋转椭圆的轮廓点。"""
    angle = math.radians(angle_deg)
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    out = []
    for index in range(steps):
        theta = 2 * math.pi * index / steps
        x, y = math.cos(theta) * radii[0], math.sin(theta) * radii[1]
        out.append((centre[0] + x * cos_a - y * sin_a, centre[1] + x * sin_a + y * cos_a))
    return out


def normals(curve):
    """脊线每点的单位法线（由相邻点差分得到）。"""
    out = []
    for index, point in enumerate(curve):
        ahead = curve[min(index + 1, len(curve) - 1)]
        behind = curve[max(index - 1, 0)]
        tx, ty = ahead[0] - behind[0], ahead[1] - behind[1]
        length = math.hypot(tx, ty) or 1.0
        out.append((-ty / length, tx / length))
    return out


def tail_mark(steps=16):
    """鲸尾的轮廓：左半边逐段画出来，再镜像着走回来，最后一条底边收口。

    镜像整条已画好的折线，不是照着重敲一遍右半边的控制点：镜像永远严格对称，
    而「照着点一遍」正是差半个像素的来源。缺口落在对称轴上，所以两半共用那一个点。
    """
    forward = [TAIL_START]
    for control, anchor in TAIL_HALF:
        forward += bezier(forward[-1], control, anchor, steps=steps)[1:]
    backward = [(1.0 - x, y) for x, y in reversed(forward)]
    outline = forward + backward[1:]
    outline += bezier(outline[-1], TAIL_BASE, TAIL_START, steps=steps)[1:-1]
    return outline


def mark_shapes():
    """标志的全部零件（并集用）。"""
    return [tail_mark()]


def mark_bounds():
    """标志在自身坐标里的外接框。

    直接量多边形的点，不靠离屏试画：试画要先把图形放进画布，形状一旦超出 0..1
    就会被裁掉，量出来的外接框随之偏小——按它算的缩放与居中会整体错位。
    """
    xs = [point[0] for shape in mark_shapes() for point in shape]
    ys = [point[1] for shape in mark_shapes() for point in shape]
    return min(xs), min(ys), max(xs), max(ys)


def mark_mask(size, offset=(0.0, 0.0), scale=1.0):
    """标志的实心遮罩。

    返回 L 通道而不是画好的图形：高光、内阴影与投影都从这一张派生，形状永远一致。
    """
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)

    def project(point):
        return ((point[0] * scale + offset[0]) * size,
                (point[1] * scale + offset[1]) * size)

    for shape in mark_shapes():
        draw.polygon([project(point) for point in shape], fill=255)
    return mask


def positioned(canvas, coverage=None):
    """把标志按目标占比缩放居中，返回 (遮罩, 偏移, 缩放)。

    偏移与缩放也返回给调用方：调试视图要按同一套变换画锚点，否则标注和形状对不上。
    """
    coverage = COVERAGE if coverage is None else coverage
    x0, y0, x1, y1 = mark_bounds()
    scale = coverage / max(x1 - x0, y1 - y0)
    offset = (0.5 - (x0 + x1) / 2 * scale, 0.5 - (y0 + y1) / 2 * scale)
    return mark_mask(canvas, offset=offset, scale=scale), offset, scale


# ---------------------------------------------------------------- 合成


def compose(dark, paper=False):
    """画一张图标。`dark=True` 出深色变体；`paper=True` 出白底蓝鲸的官方味版本。"""
    if paper:
        base = vertical_gradient(CANVAS, [(0.0, (255, 255, 255)), (1.0, (0xF1, 0xF3, 0xFA))])
        glow_layer, glow_mask = radial_glow(CANVAS, (0.30, 0.20), 1.00, (255, 255, 255), 0.0)
        mark_colour = BRAND
        rim_light = (0x9C, 0xB0, 0xFF)
        rim_shadow = (0x2B, 0x40, 0xC8)
        shadow = (0x2A, 0x3C, 0x9E, 70)
    elif dark:
        base = vertical_gradient(CANVAS, [(0.0, NIGHT_TOP), (0.55, (0x0D, 0x12, 0x24)),
                                          (1.0, NIGHT_BOTTOM)])
        glow_layer, glow_mask = radial_glow(CANVAS, (0.5, 0.30), 0.72, BRAND, 0.30)
        mark_colour = (0xE9, 0xEF, 0xFF)
        rim_light = (255, 255, 255)
        rim_shadow = (0x5A, 0x6C, 0xC0)
        shadow = (0, 0, 0, 130)
    else:
        base = vertical_gradient(CANVAS, [(0.0, BRAND_LIGHT), (0.52, BRAND), (1.0, BRAND_DEEP)])
        glow_layer, glow_mask = radial_glow(CANVAS, (0.30, 0.16), 0.92, (255, 255, 255), 0.24)
        mark_colour = (255, 255, 255)
        rim_light = (255, 255, 255)
        rim_shadow = (0x27, 0x3A, 0xB4)
        shadow = (0x08, 0x10, 0x38, 110)

    image = Image.composite(glow_layer, base, glow_mask).convert("RGBA")
    clear = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    mask, _, _ = positioned(CANVAS)

    # 投影：整只鲸向下偏一点，大半径模糊——立体感来自这一层，不是来自描边。
    drop = ImageChops.offset(mask, int(CANVAS * 0.004), int(CANVAS * 0.013))
    drop = drop.filter(ImageFilter.GaussianBlur(CANVAS * 0.015))
    image = Image.alpha_composite(
        image, Image.composite(Image.new("RGBA", (CANVAS, CANVAS), shadow), clear, drop))

    # 鲸身：底色 + 一圈内阴影（右下）+ 一圈内高光（左上）。
    # 官方的立体感就是这两圈：受光面提亮、背光面压暗，边缘因此「鼓」起来。
    body = Image.composite(Image.new("RGBA", (CANVAS, CANVAS), mark_colour + (255,)), clear, mask)
    for shift, colour, alpha, blur in (
            (-0.010, rim_shadow, 150, 0.013),
            (0.009, rim_light, 165, 0.011)):
        band = ImageChops.subtract(
            mask, ImageChops.offset(mask, int(CANVAS * shift), int(CANVAS * shift)))
        band = band.filter(ImageFilter.GaussianBlur(CANVAS * blur))
        body = Image.alpha_composite(
            body, Image.composite(Image.new("RGBA", (CANVAS, CANVAS), colour + (alpha,)),
                                  clear, ImageChops.multiply(band, mask)))
    image = Image.alpha_composite(image, body)

    return image.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


# ---------------------------------------------------------------- 入口


def symbol_image(size):
    """标志的单色剪影：App 内当模板图用（染色由 `foregroundStyle` 决定）。

    同一份几何出图，因此界面里的标志与桌面图标永远是同一个形状；
    描边粗细按图片尺寸缩放，小尺寸下不会细到看不见。
    """
    mask = mark_mask(size, *positioned_transform(coverage=0.92)[1:])
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    image.putalpha(mask)
    return image


def write_symbol():
    """写出 `TailMark.imageset`：1x/2x/3x 三张模板图 + 登记文件。"""
    os.makedirs(SYMBOL_SET, exist_ok=True)
    scales = (("1x", 256), ("2x", 512), ("3x", 768))
    for suffix, size in scales:
        symbol_image(size).save(os.path.join(SYMBOL_SET, f"tail-mark-{suffix}.png"))
    contents = {
        "images": [
            {"filename": f"tail-mark-{suffix}.png", "idiom": "universal",
             "scale": suffix}
            for suffix, _ in scales
        ],
        "info": {"author": "xcode", "version": 1},
        # 模板图：App 里用 `foregroundStyle` 染色，不锁定颜色。
        "properties": {"template-rendering-intent": "template"},
    }
    with open(os.path.join(SYMBOL_SET, "Contents.json"), "w") as handle:
        json.dump(contents, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"写入 {SYMBOL_SET}/tail-mark-*.png（模板图）")


def positioned_transform(coverage=None):
    """缩放与居中，不落成像素：出别的尺寸（App 内的模板图）时也要用同一套。"""
    coverage = COVERAGE if coverage is None else coverage
    x0, y0, x1, y1 = mark_bounds()
    scale = coverage / max(x1 - x0, y1 - y0)
    offset = (0.5 - (x0 + x1) / 2 * scale, 0.5 - (y0 + y1) / 2 * scale)
    return None, offset, scale


def preview(out):
    """对比图：本设计的两版 + 官方味白底版 + 真实尺寸阶梯。"""
    images = [compose(dark=False), compose(dark=True), compose(dark=False, paper=True)]
    sheet = Image.new("RGB", (SIZE * 3 + 160, SIZE + 300), (0xF5, 0xF6, 0xF7))
    for column, image in enumerate(images):
        x = 40 + column * (SIZE + 40)
        sheet.paste(image, (x, 60))
        for index, size in enumerate((180, 120, 80, 40)):
            sheet.paste(image.resize((size, size), Image.LANCZOS), (x + index * 200, SIZE + 110))
    sheet.save(out)
    print(out)


def mark_debug(out):
    """调形状用：把标志单独画大，叠 0.1 网格与轮廓锚点（按同一套变换投影）。"""
    image = compose(dark=False).convert("RGB")
    draw = ImageDraw.Draw(image)
    _, offset, scale = positioned(SIZE)

    def project(point):
        return ((point[0] * scale + offset[0]) * SIZE,
                (point[1] * scale + offset[1]) * SIZE)

    for index in range(1, 10):
        at = SIZE * index / 10
        draw.line([(at, 0), (at, SIZE)], fill=(255, 90, 90), width=2)
        draw.line([(0, at), (SIZE, at)], fill=(255, 90, 90), width=2)
    for control, anchor in TAIL_HALF:
        px, py = project(control)
        draw.ellipse([px - 5, py - 5, px + 5, py + 5], fill=(255, 120, 220))
        px, py = project(anchor)
        draw.ellipse([px - 6, py - 6, px + 6, py + 6], fill=(255, 210, 90))
    px, py = project(TAIL_START)
    draw.ellipse([px - 7, py - 7, px + 7, py + 7], fill=(120, 255, 160))
    image.save(out)
    print(out)


def main():
    parser = argparse.ArgumentParser(description="生成 DSH Mobile 的 App 图标")
    parser.add_argument("--preview", action="store_true",
                        help="预览图（三版大图 + 真实尺寸缩略），不写入 Assets")
    parser.add_argument("--mark", action="store_true", help="只画标志 + 网格 + 控制点")
    parser.add_argument("--out", default=None, help="输出路径")
    parser.add_argument("--variant", default="tile", choices=("tile", "paper"),
                        help="tile = 品牌蓝底白标志（默认）；paper = 白底蓝标志")
    parser.add_argument("--symbol-only", action="store_true",
                        help="只出 App 内用的模板图，不动桌面图标")
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
