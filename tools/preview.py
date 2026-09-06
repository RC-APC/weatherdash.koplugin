#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Weatherdash v3 本地版「灰度预览生成器」。

严格按 koplugin/Weatherdash.koplugin/main.lua 中 renderWallpaper 的坐标与画法，
用 Pillow 在电脑上生成与 Kindle BB8 输出近似的灰度 PNG，用于 README/docs 预览。

用法：
    python tools/preview.py          # 生成 docs/sample_lunar.png 与 docs/sample_cover.png

依赖：Pillow。字体自动尝试系统 CJK 字体（Windows 微软雅黑 / macOS PingFang 等）。
"""
import os
import sys
import math

from PIL import Image, ImageDraw, ImageFont

W, H = 1072, 1448
MX = 70  # 边距（与 main.lua 一致）

BLACK = 0
WHITE = 255
DIM = round(0.62 * 255)  # 次要文字灰（对应 main.lua C_DIM）

# ---------------- 字体 ----------------
_CANDIDATES = [
    "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/msyhbd.ttc",
    "C:/Windows/Fonts/simhei.ttf", "C:/Windows/Fonts/simsun.ttc",
    "/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
]
# 中文衬线（对应 main.lua familyFace("serif")：宋体/Noto Serif CJK）
_SERIF_CJK = [
    "C:/Windows/Fonts/simsun.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/STSong.ttf",
    "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
]
# 出版字体（对应 main.lua familyFace("pub")：Bookerly/Caecilia/Georgia…）
_PUB = [
    "C:/Windows/Fonts/georgia.ttf", "C:/Windows/Fonts/georgiab.ttf",
    "C:/Windows/Fonts/times.ttf",
    "/Library/Fonts/Georgia.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSerif.ttf",
]
_font_cache = {}


def _font(size, bold=False, family=None):
    key = (family, size, bold)
    if key in _font_cache:
        return _font_cache[key]
    paths = _CANDIDATES
    if family == "serif":
        paths = _SERIF_CJK
    elif family == "pub":
        paths = _PUB
    for path in paths:
        if os.path.exists(path):
            try:
                f = ImageFont.truetype(path, size=size)
                _font_cache[key] = f
                return f
            except Exception:
                continue
    # 家族缺字体 → 回落主字体链
    for path in _CANDIDATES:
        if os.path.exists(path):
            try:
                f = ImageFont.truetype(path, size=size)
                _font_cache[key] = f
                return f
            except Exception:
                continue
    f = ImageFont.load_default()
    _font_cache[key] = f
    return f


def _text_w(font, s):
    bb = font.getbbox(s)
    return bb[2] - bb[0]


def _draw_text(d, x, y, s, size, bold=False, color=BLACK, center_x=None, family=None):
    """y 为字块顶（与 main.lua drawText 近似：其 baseline = y + 0.82*size）。"""
    font = _font(size, bold, family)
    if center_x is not None:
        x = center_x - _text_w(font, s) / 2
    d.text((x, y), s, font=font, fill=color)


def _center_text(d, cx, y, s, size, bold=False, color=BLACK, family=None):
    _draw_text(d, 0, y, s, size, bold, color, center_x=cx, family=family)


# ---------------- 天气图标：内置 FontAwesome 字形（与 main.lua 一致） ----------------
# 与 koplugin/Weatherdash.koplugin/fonts/fa-weather.ttf 对应（tools/subset_fa.py 的 WANT）
FA = {
    "sun": 0xF185, "moon": 0xF186, "partly": 0xF6C4, "cloud": 0xF0C2,
    "fog": 0xF75F, "drizzle": 0xF0C2, "rain": 0xF73D, "heavy": 0xF740,
    "snow": 0xF2DC, "thunder": 0xF76C,
}
_FA_TTF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "koplugin", "Weatherdash.koplugin", "fonts", "fa-weather.ttf")
_fa_cache = {}


def _fa_font(size):
    if size in _fa_cache:
        return _fa_cache[size]
    f = ImageFont.truetype(os.path.abspath(_FA_TTF), size=size)
    _fa_cache[size] = f
    return f


def _draw_glyph(d, cx, cy, target_h, itype):
    cp = FA.get(itype)
    if cp is None:
        return False
    ch = chr(cp)
    size = max(12, int(target_h * 1.4))
    for _ in range(4):
        font = _fa_font(size)
        bb = font.getbbox(ch)
        if not bb or bb[2] <= bb[0] or bb[3] <= bb[1]:
            return False
        gh = bb[3] - bb[1]
        if abs(gh - target_h) <= max(2, target_h * 0.03):
            # 以墨迹 bbox 中心对齐 (cx, cy)：pen = 中心 - bbox 中心
            pen_x = cx - (bb[0] + bb[2]) / 2.0
            pen_y = cy - (bb[1] + bb[3]) / 2.0
            d.text((pen_x, pen_y), ch, font=font, fill=BLACK)
            return True
        new_size = int(size * target_h / gh)
        if new_size == size:
            new_size = size + (1 if target_h > gh else -1)
        size = max(8, new_size)
    return False


# ---------------- 天气图标：优先用插件内置图标库 PNG（与设备 1:1） ----------------
# 与 koplugin/Weatherdash.koplugin/fonts/fa-weather.ttf / icons/*.png 对应
ICON_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                        "koplugin", "Weatherdash.koplugin", "icons")


def _load_icon(itype, big):
    sfx = "L" if big else "S"
    path = os.path.join(ICON_LIB, "%s_%s.png" % (itype, sfx))
    if os.path.exists(path):
        return Image.open(path)
    return None


def draw_icon(img, d, cx, cy, r, itype):
    big = r >= 90
    icon = _load_icon(itype, big)
    if icon is not None:
        # 直接粘贴，保留抗锯齿灰阶（bitmap+fill 会涂成实心块）
        x = int(cx - icon.width / 2)
        y = int(cy - icon.height / 2)
        img.paste(icon, (x, y))
        return
    # 兜一：FA 字形（同一份字体，仅在没有图标库文件时使用）
    if _draw_glyph(d, cx, cy, max(16, int(r * 1.5)), itype):
        return
    draw_icon_geo(d, cx, cy, r, itype)


# ---------------- 几何图标兜底（模仿 main.lua drawIconGeo） ----------------
def _circle(d, cx, cy, r, color=BLACK, outline=False):
    box = [cx - r, cy - r, cx + r, cy + r]
    if outline:
        d.ellipse(box, outline=color, width=7)
    else:
        d.ellipse(box, fill=color)


def _ring(d, cx, cy, r, color=BLACK):
    _circle(d, cx, cy, r, color=color, outline=True)


def draw_icon_geo(d, cx, cy, r, itype):
    c = BLACK
    if itype == "sun":
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)
        for a in range(0, 360, 45):
            rad = math.radians(a)
            x1 = cx + math.cos(rad) * r * 1.15
            y1 = cy + math.sin(rad) * r * 1.15
            x2 = cx + math.cos(rad) * r * 1.55
            y2 = cy + math.sin(rad) * r * 1.55
            # 用旋转的细矩形作射线（多边形），避免短斜距被夹成方块
            th = max(4, r * 0.12)
            px = -math.sin(rad) * th / 2
            py = math.cos(rad) * th / 2
            d.polygon([(x1 + px, y1 + py), (x2 + px, y2 + py),
                       (x2 - px, y2 - py), (x1 - px, y1 - py)], fill=c)
    elif itype == "partly":
        d.ellipse([cx - r * 0.45 - r * 0.5, cy - r * 0.45 - r * 0.5,
                   cx - r * 0.45 + r * 0.5, cy - r * 0.45 + r * 0.5], fill=c)
        _ring(d, cx + r * 0.35, cy + r * 0.35, r * 0.6, c)
        d.rectangle([cx - r * 0.25, cy + r * 0.35 - 3, cx - r * 0.25 + r * 1.2, cy + r * 0.35 + 4], fill=c)
    elif itype in ("cloud", "fog"):
        _ring(d, cx - r * 0.3, cy, r * 0.55, c)
        _ring(d, cx + r * 0.3, cy - r * 0.1, r * 0.6, c)
        d.rectangle([cx - r * 0.7, cy - 3, cx - r * 0.7 + r * 1.4, cy + 4], fill=c)
        if itype == "fog":
            d.rectangle([cx - r * 0.9, cy + r * 0.5 - 2, cx - r * 0.9 + r * 1.8, cy + r * 0.5 + 3], fill=c)
            d.rectangle([cx - r * 0.7, cy + r * 0.8 - 2, cx - r * 0.7 + r * 1.4, cy + r * 0.8 + 3], fill=c)
    elif itype == "drizzle":
        # 小雨：云 + 小圆点雨滴（与 main.lua drawIconGeo / 图标库 PNG 同语义）
        _ring(d, cx - r * 0.25, cy - r * 0.1, r * 0.55, c)
        _ring(d, cx + r * 0.3, cy - r * 0.2, r * 0.55, c)
        d.rectangle([cx - r * 0.7, cy + r * 0.1 - 3, cx - r * 0.7 + r * 1.5, cy + r * 0.1 + 4], fill=c)
        dot = max(4, r * 0.08)
        for (dx, dy) in ((-0.4, 0.55), (0.0, 0.65), (0.4, 0.55), (-0.2, 0.9), (0.2, 0.9)):
            d.ellipse([cx + r * dx - dot, cy + r * dy - dot,
                       cx + r * dx + dot, cy + r * dy + dot], fill=c)
    elif itype in ("rain", "heavy", "thunder"):
        _ring(d, cx - r * 0.25, cy - r * 0.1, r * 0.55, c)
        _ring(d, cx + r * 0.3, cy - r * 0.2, r * 0.55, c)
        d.rectangle([cx - r * 0.7, cy + r * 0.1 - 3, cx - r * 0.7 + r * 1.5, cy + r * 0.1 + 4], fill=c)
        if itype == "rain":
            for dx in (-0.4, 0, 0.4):
                d.rectangle([cx + r * dx - 3, cy + r * 0.4, cx + r * dx + 3, cy + r * 0.4 + r * 0.7], fill=c)
        elif itype == "heavy":
            # 大雨：4 条更粗更长的雨丝
            for dx in (-0.5, -0.17, 0.17, 0.5):
                d.rectangle([cx + r * dx - 3.5, cy + r * 0.35,
                             cx + r * dx + 3.5, cy + r * 0.35 + r * 0.9], fill=c)
        else:
            d.polygon([(cx - r * 0.2, cy + r * 0.4), (cx + r * 0.1, cy + r * 0.4),
                       (cx - r * 0.05, cy + r * 0.75), (cx + r * 0.05, cy + r * 0.75),
                       (cx + r * 0.2, cy + r * 0.5), (cx + r * 0.35, cy + r * 0.5)], fill=c)
    elif itype == "snow":
        _ring(d, cx - r * 0.25, cy - r * 0.1, r * 0.55, c)
        _ring(d, cx + r * 0.3, cy - r * 0.2, r * 0.55, c)
        d.rectangle([cx - r * 0.7, cy + r * 0.1 - 3, cx - r * 0.7 + r * 1.5, cy + r * 0.1 + 4], fill=c)
        for dx in (-0.4, 0.0, 0.4):
            d.ellipse([cx + r * dx - 7, cy + r * 0.6 - 7, cx + r * dx + 7, cy + r * 0.6 + 7], fill=c)
    else:
        _circle(d, cx, cy, r, c)


# ---------------- 数据（示意值；农历取自 tools/verify_lunar.py 已核对锚点） ----------------
CITY = "上海"
DATE_STR = "2026年09月06日 星期日"
TEMP = 26
DESC = "多云"
CODE = 2
FC = [
    {"time": "14:00", "temp": 26, "code": 3},    # cloud
    {"time": "17:00", "temp": 24, "code": 61},   # drizzle（云+小点）
    {"time": "20:00", "temp": 23, "code": 63},   # rain（雨丝）
    {"time": "23:00", "temp": 23, "code": 82},   # heavy（粗长雨丝）
    {"time": "02:00", "temp": 22, "code": 80},   # drizzle
]
SUNRISE, SUNSET = "05:40", "18:05"
UPDATE = "更新于 09-06 09:30 · 数据 open-meteo"

# WMO 代码 → 图标类型（镜像 main.lua 的 WMO_ICON，v3.3.9 三级雨势）
WMO_ICON = {
    0: "sun", 1: "partly", 2: "cloud", 3: "cloud",
    45: "fog", 48: "fog",
    51: "drizzle", 53: "drizzle", 55: "drizzle", 56: "drizzle", 57: "drizzle",
    61: "drizzle", 63: "rain", 65: "heavy", 66: "heavy", 67: "heavy",
    71: "snow", 73: "snow", 75: "snow", 77: "snow",
    80: "drizzle", 81: "rain", 82: "heavy",
    85: "snow", 86: "snow",
    95: "thunder", 96: "thunder", 99: "thunder",
}


def icon_for(code):
    return WMO_ICON.get(code, "cloud")

# 2026-09-05 农历（已用 tools/verify_lunar.py 核对）
LUNAR_TEXT = "七月廿五"
LUNAR_YI = "筑堤 安葬 补垣"     # 2026-09-06 闭日（与 main.lua 推算一致，宜/忌各≤3 条）
LUNAR_JI = "开市 出行 栽种"


def _badge(d, x, y, w, h, title, body):
    d.rectangle([x, y, x + w, y + h], fill=WHITE)
    d.rectangle([x, y, x + w, y + 5], fill=BLACK)
    d.rectangle([x, y + h - 5, x + w, y + h], fill=BLACK)
    d.rectangle([x, y, x + 5, y + h], fill=BLACK)
    d.rectangle([x + w - 5, y, x + w, y + h], fill=BLACK)
    # 内边距加大：与 main.lua drawBadge(v3.3.6) 同步
    pad = 30
    _draw_text(d, x + pad, y + 40, title, 30, bold=True)
    # 按宽度折行（近似 main.lua drawBadge）
    font = _font(26)
    maxw = w - 2 * pad
    words = body.split()
    line1, cur = "", ""
    for wp in words:
        if _text_w(font, (cur + " " + wp).strip()) > maxw and cur:
            line1, cur = cur, wp
        else:
            cur = (cur + " " + wp).strip()
    if line1:
        _draw_text(d, x + pad, y + 112, line1, 26)
        _draw_text(d, x + pad, y + 150, cur, 26)
    else:
        _draw_text(d, x + pad, y + 112, cur, 26)


def make_canvas():
    img = Image.new("L", (W, H), WHITE)
    return img, ImageDraw.Draw(img)


def render_lunar():
    img, d = make_canvas()
    _center_text(d, W / 2, 46, CITY, 36, bold=True)
    _center_text(d, W / 2, 114, DATE_STR, 26, color=DIM)

    draw_icon(img, d, int(W * 0.27), 350, 90, icon_for(CODE))  # CODE=2 → 多云

    temp_s = f"{TEMP}°"
    font_big = _font(110, bold=True, family="pub")
    tw = _text_w(font_big, temp_s)
    _draw_text(d, W - MX - tw, 320, temp_s, 110, bold=True, family="pub")
    _draw_text(d, W - MX - _text_w(_font(34), DESC), 460, DESC, 34)

    d.rectangle([MX, 600, W - MX, 604], fill=BLACK)

    colw = (W - 2 * MX) / 5
    fy = 640
    for i, fc in enumerate(FC, start=1):
        cx = MX + colw * (i - 0.5)
        _center_text(d, cx, fy, fc["time"], 24, color=DIM)
        draw_icon(img, d, int(cx), fy + 80, 36, icon_for(fc["code"]))
        _center_text(d, cx, fy + 140, f"{fc['temp']}°", 28)

    lower_y = 880
    _center_text(d, W / 2, lower_y, LUNAR_TEXT, 38, bold=True, family="serif")
    bw = (W - 3 * MX) / 2
    by = lower_y + 92
    _badge(d, MX, by, int(bw), 190, "宜", LUNAR_YI)
    _badge(d, int(MX * 2 + bw), by, int(bw), 190, "忌", LUNAR_JI)

    _center_text(d, W / 2, H - 132, f"日出 {SUNRISE}   日落 {SUNSET}", 20, color=DIM)
    _center_text(d, W / 2, H - 76, UPDATE, 18, color=DIM)
    return img


def _synthetic_cover():
    """生成一张示意书封（不引入任何真实书籍版权图）。
    选用偏正方形的纵横比以适配下方较宽的屏保区域，避免被压成窄长条。"""
    cw, ch = 920, 460
    img = Image.new("L", (cw, ch), 245)
    d = ImageDraw.Draw(img)
    # 左侧深色色块作为封面色调
    d.rectangle([0, 0, int(cw * 0.42), ch], fill=80)
    # 中间分隔细线
    d.rectangle([int(cw * 0.42), 0, int(cw * 0.42) + 3, ch], fill=BLACK)
    # 标题（中英两行，垂直居中）
    font_t = _font(76, bold=True)
    title = "漫长的告别"
    title_y = ch // 2 - 90
    d.text(((cw - _text_w(font_t, title)) / 2, title_y), title, font=font_t, fill=BLACK)
    font_s = _font(34)
    sub = "The Long Goodbye"
    d.text(((cw - _text_w(font_s, sub)) / 2, title_y + 110), sub, font=font_s, fill=60)
    # 作者
    font_a = _font(26)
    author = "雷蒙德·钱德勒  著"
    d.text(((cw - _text_w(font_a, author)) / 2, ch - 60), author, font=font_a, fill=BLACK)
    return img


def render_cover():
    img, d = make_canvas()
    _center_text(d, W / 2, 46, CITY, 36, bold=True)
    _center_text(d, W / 2, 114, DATE_STR, 26, color=DIM)

    draw_icon(img, d, int(W * 0.27), 350, 90, "sun")

    temp_s = f"{TEMP}°"
    font_big = _font(110, bold=True, family="pub")
    tw = _text_w(font_big, temp_s)
    _draw_text(d, W - MX - tw, 320, temp_s, 110, bold=True, family="pub")
    desc_s = f"晴 {TEMP}°"
    _draw_text(d, W - MX - _text_w(_font(34), desc_s), 460, desc_s, 34)

    d.rectangle([MX, 600, W - MX, 604], fill=BLACK)

    colw = (W - 2 * MX) / 5
    fy = 640
    sunny = [0, 0, 2, 2, 45]
    for i, fc in enumerate(FC, start=1):
        cx = MX + colw * (i - 0.5)
        _center_text(d, cx, fy, fc["time"], 24, color=DIM)
        code = sunny[i - 1]
        draw_icon(img, d, int(cx), fy + 80, 36, icon_for(code))
        _center_text(d, cx, fy + 140, f"{fc['temp']}°", 28)

    # 书封区（与 main.lua renderWallpaper 的 cover 分支一致：等比缩放居中）
    cover = _synthetic_cover()
    boxw, boxh = W - 2 * MX, 420  # 缩短 40（原本 460），给下方"日出/日落"让出一行
    lower_y = 880
    scale = min(boxw / cover.width, boxh / cover.height)
    dw, dh = max(1, int(cover.width * scale)), max(1, int(cover.height * scale))
    if (dw, dh) != (cover.width, cover.height):
        cover = cover.resize((dw, dh))
    dx = MX + (boxw - dw) // 2
    dy = lower_y + (boxh - dh) // 2
    img.paste(cover, (dx, dy))
    d.rectangle([MX, lower_y, MX + boxw, lower_y + 4], fill=BLACK)
    d.rectangle([MX, lower_y + boxh - 4, MX + boxw, lower_y + boxh], fill=BLACK)

    # 日出/日落（与 main.lua 封面模式同步：画在封面盒正下方，不压书封）
    _center_text(d, W / 2, lower_y + 420 + 18, f"日出 {SUNRISE}   日落 {SUNSET}", 20, color=DIM)
    _center_text(d, W / 2, H - 76, UPDATE, 18, color=DIM)
    return img


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    docs = os.path.join(root, "docs")
    os.makedirs(docs, exist_ok=True)
    render_lunar().save(os.path.join(docs, "sample_lunar.png"))
    render_cover().save(os.path.join(docs, "sample_cover.png"))
    print("已生成 docs/sample_lunar.png 与 docs/sample_cover.png")


if __name__ == "__main__":
    sys.exit(main())
