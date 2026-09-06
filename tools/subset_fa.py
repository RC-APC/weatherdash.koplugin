# -*- coding: utf-8 -*-
"""
从 FontAwesome 6 Free (Solid) 裁剪天气图标子集，产出插件内置图标字体。

用法（先手动把 fa-solid-900.ttf 放到本目录，如从
https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@6.5.2/webfonts/fa-solid-900.ttf 下载）：
    python tools/subset_fa.py

输出：koplugin/Weatherdash.koplugin/fonts/fa-weather.ttf
字体授权：Font Awesome Free 采用 SIL OFL 1.1，见仓库 LICENSE.fonts。
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
from fontTools.ttLib import TTFont
from fontTools import subset

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "fa-solid-900.ttf")
OUT = os.path.join(HERE, "..", "koplugin", "Weatherdash.koplugin", "fonts", "fa-weather.ttf")
OUT = os.path.abspath(OUT)

# 名称 -> 期望码点（Font Awesome 6 Free Solid）。映射到 main.lua 的 FA_GLYPH 表。
# v3.3.9 三级雨势：drizzle 用纯几何画法（build_icons.py），不走字体；
# rain=cloud-rain（中雨）、heavy=cloud-showers-heavy（大雨）。
WANT = {
    "sun":     0xF185,  # fa-sun
    "moon":    0xF186,  # fa-moon
    "partly":  0xF6C4,  # fa-cloud-sun
    "cloud":   0xF0C2,  # fa-cloud（drizzle 的字形兜底也用它）
    "fog":     0xF75F,  # fa-smog
    "rain":    0xF73D,  # fa-cloud-rain
    "heavy":   0xF740,  # fa-cloud-showers-heavy
    "snow":    0xF2DC,  # fa-snowflake
    "thunder": 0xF76C,  # fa-cloud-bolt
    "wind":    0xF72E,  # fa-wind (备用)
    "location": 0xF3C5, # fa-location-dot (备用)
}

def glyph_expected_name(key):
    return {"partly": "cloud-sun", "rain": "cloud-rain",
            "heavy": "cloud-showers-heavy"}.get(key, key)

def main():
    assert os.path.exists(SRC), "缺少源字体 %s" % SRC
    font = TTFont(SRC)
    cmap = font.getBestCmap()
    print("== codepoint verification (FontAwesome 6.5.2) ==")
    matched = {}
    for key, cp in WANT.items():
        gn = cmap.get(cp)
        ok = gn is not None and glyph_expected_name(key) in gn
        print("  %-10s U+%04X -> %-28s %s" % (key, cp, gn, "OK" if ok else "!! MISMATCH"))
        if gn:
            matched[cp] = key
    print("matched:", len(matched))

    ss = subset.Options()
    ss.name_IDs = ["*"]
    ss.name_legacy = True
    ss.name_languages = ["*"]
    ss.notdef_outline = True
    ss.recalc_bounds = True
    ss.drop_tables = ["FFTM"]
    sub = subset.Subsetter(ss)
    sub.populate(unicodes=set(matched.keys()))
    out_font = TTFont(SRC)
    sub.subset(out_font)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    out_font.save(OUT)
    print("saved:", OUT, os.path.getsize(OUT), "bytes")

if __name__ == "__main__":
    main()
