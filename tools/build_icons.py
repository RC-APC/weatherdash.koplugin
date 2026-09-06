# -*- coding: utf-8 -*-
"""
生成插件内置「天气图标库」（灰度 PNG 文件集合）。

与 loeffner/WeatherLockscreen 的思路一致：把图标做成预置文件放进插件目录，
运行时按天气类型直接取用，而不是每次生成都现画。

默认图标源：koplugin/Weatherdash.koplugin/fonts/fa-weather.ttf
（Font Awesome Free Solid 子集，SIL OFL 1.1）。

产出：
  koplugin/Weatherdash.koplugin/icons/<type>_L.png   (300×300，主图区 r≥90 使用)
  koplugin/Weatherdash.koplugin/icons/<type>_S.png   (100×100，预报区小图标)

type ∈ sun partly cloud fog drizzle rain heavy snow thunder
  - drizzle（毛毛雨/小雨）：纯几何画法（实心云 + 小圆点雨滴），不依赖字体——
    FA 子集里没有"小雨"码点（fa-cloud-drizzle 0xF738 未入集），
    之前误用 fa-cloud-rain 大雨滴字形，观感成了"下大雨"（v3.3.9 修复）。
  - rain（中雨）= fa-cloud-rain 0xF73D；heavy（大雨）= fa-cloud-showers-heavy 0xF740。
替换图标：把同名 PNG（同尺寸或更大）覆盖进 icons/ 即可换肤，无需改代码。

用法：
    python tools/build_icons.py
依赖：Pillow
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
TTF = os.path.join(HERE, "..", "koplugin", "Weatherdash.koplugin", "fonts", "fa-weather.ttf")
OUT_DIR = os.path.join(HERE, "..", "koplugin", "Weatherdash.koplugin", "icons")

# 与 main.lua FA_GLYPH / tools/subset_fa.py 保持一致
GLYPHS = {
    "sun": 0xF185,
    "moon": 0xF186,   # 备用
    "partly": 0xF6C4,
    "cloud": 0xF0C2,
    "fog": 0xF75F,
    "rain": 0xF73D,   # fa-cloud-rain（中雨）
    "heavy": 0xF740,  # fa-cloud-showers-heavy（大雨/强阵雨）
    "snow": 0xF2DC,
    "thunder": 0xF76C,
}
TYPES = ["sun", "partly", "cloud", "fog", "drizzle", "rain", "heavy", "snow", "thunder"]

# (后缀, 画布边长, 字形目标像素高)
# L = 主图区画布（hero 区半径 130 → 直径 260）
# S = 预报区画布（forecast 半径 46 → 直径 92）
SIZES = [("L", 260, 170), ("S", 92, 60)]

_font_cache = {}


def _font(px):
    if px not in _font_cache:
        _font_cache[px] = ImageFont.truetype(os.path.abspath(TTF), px)
    return _font_cache[px]


def _render_glyph(canvas, target_h, cp):
    """在 canvas 边长的白底图上画居中字形，返回 PIL 图。"""
    img = Image.new("L", (canvas, canvas), 255)
    d = ImageDraw.Draw(img)
    px = max(12, int(target_h * 1.4))
    for _ in range(4):
        font = _font(px)
        ch = chr(cp)
        bb = font.getbbox(ch)
        if not bb or bb[2] <= bb[0] or bb[3] <= bb[1]:
            return None
        gh = bb[3] - bb[1]
        if abs(gh - target_h) <= max(2, target_h * 0.03):
            pen_x = canvas / 2 - (bb[0] + bb[2]) / 2.0
            pen_y = canvas / 2 - (bb[1] + bb[3]) / 2.0
            d.text((pen_x, pen_y), ch, font=font, fill=0)
            return img
        npx = int(px * target_h / gh)
        if npx == px:
            npx = px + (1 if target_h > gh else -1)
        px = max(8, npx)
    return None


# drizzle 几何画法的设计坐标系：内容高 170（与 L 档 target_h 一致），
# 坐标以内容盒中心为原点，画时按 target_h/170 等比缩放。
# 云 = 3 个实心圆 + 底部填充矩形（平底），雨 = 5 颗小圆点（两排错位）。
_DRIZZLE_CLOUD = [
    # (cx, cy, r)
    (-40, -16, 28),   # 左圆
    (40, -16, 28),    # 右圆
    (0, -38, 50),     # 主圆（云顶）
]
_DRIZZLE_BASE = (-46, -24, 46, 12)   # 底部矩形 (x0, y0, x1, y1)
_DRIZZLE_DOTS = [
    # (cx, cy, r)
    (-30, 40, 6), (0, 44, 6), (30, 40, 6),
    (-15, 68, 6), (15, 68, 6),
]


def _render_drizzle(canvas, target_h):
    """毛毛雨：实心云 + 小圆点雨滴（几何画法，白底黑图，与其余图标同风格）。"""
    img = Image.new("L", (canvas, canvas), 255)
    d = ImageDraw.Draw(img)
    s = target_h / 170.0
    cx = canvas / 2.0
    cy = canvas / 2.0

    def E(x, y, r):
        r = r * s
        d.ellipse([cx + x * s - r, cy + y * s - r, cx + x * s + r, cy + y * s + r], fill=0)

    for (x, y, r) in _DRIZZLE_CLOUD:
        E(x, y, r)
    x0, y0, x1, y1 = _DRIZZLE_BASE
    d.rectangle([cx + x0 * s, cy + y0 * s, cx + x1 * s, cy + y1 * s], fill=0)
    for (x, y, r) in _DRIZZLE_DOTS:
        E(x, y, r)
    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for t in TYPES:
        for suffix, canvas, th in SIZES:
            if t == "drizzle":
                img = _render_drizzle(canvas, th)
            else:
                img = _render_glyph(canvas, th, GLYPHS[t])
            if img is None:
                print("!! render failed:", t, suffix)
                continue
            path = os.path.join(OUT_DIR, "%s_%s.png" % (t, suffix))
            img.save(path)
            print("saved:", os.path.relpath(path, os.path.join(HERE, "..")),
                  os.path.getsize(path), "bytes")


if __name__ == "__main__":
    main()
