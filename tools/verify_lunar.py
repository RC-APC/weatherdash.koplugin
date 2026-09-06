#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
农历算法回归测试 —— 与 koplugin/Weatherdash.koplugin/main.lua 中的实现逐行对应。
用于在改分辨率/改版式前，确认日期→农历换算没有回归。

用法：
    python tools/verify_lunar.py

锚点日期（与权威历表核对过）：
    2024-02-10  甲辰年 正月初一
    2025-01-29  乙巳年 正月初一
    2026-02-17  丙午年 正月初一
    2000-02-05  庚辰年 正月初一
    2026-09-05  丙午年 七月廿四（含 建除=除）
    2023-03-22  癸卯年 闰二月初一（闰月锚点）
"""
from datetime import date

# 1900–2100 农历对照表（与 main.lua 的 lunarInfo 一致）
# ⚠ 索引基数：本文件是 Python list（0-based），lunarInfo[0] = 1900 年。
#   main.lua 里是 Lua table（1-based），对应写法是 lunarInfo[y - 1899]（经 lInfo()）。
#   严禁把两种写法互相照抄——Lua 版曾因误写 y-1900 取到 nil 在设备上直接崩出。
lunarInfo = [
0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,
0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,
0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,
0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,
0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,
0x06ca0,0x0b550,0x15355,0x04da0,0x0a5b0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0,
0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,
0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6,
0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,
0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0,
0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,
0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,
0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,
0x05aa0,0x076a3,0x096d0,0x04bd7,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,
0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,
0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0,
0x0a2e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4,
0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0,
0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160,
0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252,
0x0d520,
]
GAN = ["甲","乙","丙","丁","戊","己","庚","辛","壬","癸"]
ZHI = ["子","丑","寅","卯","辰","巳","午","未","申","酉","戌","亥"]
N_MONTH = ["正月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","腊月"]
JIANCHU = ["建","除","满","平","定","执","破","危","成","收","开","闭"]
JIANCHU_YI = [
    "出行 嫁娶 祭祀 祈福","沐浴 扫舍 解除 理发","纳财 祭祀 祈福 移徙",
    "修造 嫁娶 安床 出行","纳采 订盟 安床 嫁娶","捕捉 修造 嫁娶 立券",
    "破屋 求医 治病 馀事勿取","安床 祭祀 祈福 求嗣","嫁娶 开市 入学 纳财",
    "纳财 入仓 捕捉 纳畜","开市 交易 嫁娶 出行","筑堤 安葬 补垣 纳畜",
]
JIANCHU_JI = [
    "开市 动土 安门","嫁娶 出行 安葬","动土 安葬 开仓",
    "词讼 出行 安葬","词讼 出行 开市","开市 移徙 入宅",
    "嫁娶 出行 动土","出行 登高 词讼","词讼 安门 安葬",
    "出行 安葬 开市","安葬 修造 动土","开市 出行 栽种",
]

_BASE = date(1900, 1, 31)
# 甲子日基准：1899-12-22（1900-01-01 为甲戌，前推 10 天）。
# ★ 旧值 1899-12-19（辛酉日）会让日干支/建除整体偏移 3 位——
#   锚点：1949-10-01=甲子、2000-01-01=戊午、2026-09-06=癸未。
_GZ_BASE = date(1899, 12, 22)

# 表完整性 + 索引基数护栏：0-based，首项=1900(0x04bd8)、末项=2100(0x0d520)。
# 若有人照抄 Lua 的 y-1899 或动表顺序，这里会立刻失败。
assert len(lunarInfo) == 201, f"lunarInfo 长度应为 201，实际 {len(lunarInfo)}"
assert lunarInfo[0] == 0x04bd8 and lunarInfo[200] == 0x0d520, "lunarInfo 首/末项不对（索引基数或表内容被改坏）"

def lYearDays(y):
    s = 348
    for m in range(1, 13):
        if lunarInfo[y - 1900] & (1 << (16 - m)):
            s += 1
    if lunarInfo[y - 1900] & 0xf:
        s += 30 if (lunarInfo[y - 1900] & 0x10000) else 29
    return s

def leapMonth(y): return lunarInfo[y - 1900] & 0xf
def leapDays(y):
    if leapMonth(y) == 0: return 0
    return 30 if (lunarInfo[y - 1900] & 0x10000) else 29

def monthDays(y, m):
    return 30 if (lunarInfo[y - 1900] & (1 << (16 - m))) else 29

def solar2lunar(y, mo, d):
    offset = (date(y, mo, d) - _BASE).days
    i = 1900
    temp = 0
    while i < 2101 and offset > 0:
        # 注意与 main.lua 保持一致：temp 必须在减完当年后仍指向该年，
        # 不能先 i += 1 再取 lYearDays(i)，否则回补会加错年份。
        temp = lYearDays(i)
        offset -= temp
        i += 1
    if offset < 0:
        offset += temp; i -= 1
    year = i; leap = leapMonth(year); isLeap = False; month = 1
    while month < 13 and offset > 0:
        if leap > 0 and month == (leap + 1) and not isLeap:
            month -= 1; isLeap = True; temp = leapDays(year)
        else:
            temp = monthDays(year, month)
        if isLeap and month == (leap + 1): isLeap = False
        offset -= temp; month += 1
    if offset == 0 and leap > 0 and month == leap + 1:
        if isLeap: isLeap = False
        else: isLeap = True; month -= 1
    if offset < 0: offset += temp; month -= 1
    day = offset + 1
    return dict(year=year, month=month, day=day, isLeap=isLeap)

def dayGZ(y, mo, d):
    dd = (date(y, mo, d) - _GZ_BASE).days
    return GAN[dd % 10] + ZHI[dd % 12], dd % 12

def lunarText(l):
    m = ("闰" if l["isLeap"] else "") + N_MONTH[l["month"] - 1]
    n = l["day"]
    s1 = ["日","一","二","三","四","五","六","七","八","九","十"]
    if n <= 10: dc = "初" + s1[n]
    elif n < 20: dc = "十" + s1[n - 10]
    elif n == 20: dc = "二十"
    elif n < 30: dc = "廿" + s1[n - 20]
    else: dc = "三十"
    return m + dc

def clean_yi_ji(yi, ji, keep=3):
    """与 main.lua 同规则：宜忌同列项（数据自相矛盾）两侧都删；各只保留前 keep 项。"""
    yt, jt = yi.split(), ji.split()
    drop = {w for w in yt if w in jt}
    y3 = [w for w in yt if w not in drop][:keep]
    j3 = [w for w in jt if w not in drop][:keep]
    return " ".join(y3), " ".join(j3)

def getLunar(y, mo, d):
    l = solar2lunar(y, mo, d)
    gz, dz = dayGZ(y, mo, d)
    yg = GAN[(l["year"] - 4) % 10] + ZHI[(l["year"] - 4) % 12]
    mz = (l["month"] + 1) % 12
    jc = (dz - mz) % 12
    yi, ji = clean_yi_ji(JIANCHU_YI[jc], JIANCHU_JI[jc])
    return dict(text=lunarText(l), ganzhi=gz, yearGZ=yg, jianchu=JIANCHU[jc], yi=yi, ji=ji)

# (年,月,日, 期望农历文字, 期望年干支)
TESTS = [
    (1900, 1, 31, "正月初一", "庚子"),  # 表基线：offset=0 路径（曾直接 band(nil) 崩）
    (2024, 2, 10, "正月初一", "甲辰"),
    (2025, 1, 29, "正月初一", "乙巳"),
    (2026, 2, 17, "正月初一", "丙午"),
    (2000, 2, 5, "正月初一", "庚辰"),
    (2026, 9, 5, "七月廿四", "丙午"),
    (2023, 3, 22, "闰二月初一", "癸卯"),
    (2020, 5, 23, "闰四月初一", "庚子"),
    (2024, 4, 9, "三月初一", "甲辰"),
    (2026, 7, 7, "五月廿三", "丙午"),
    (1996, 2, 19, "正月初一", "丙子"),
    # 注：2033 存在农历“闰十一月”世纪难题，不同 1900-2100 对照表编码不同，
    # 此处不把它作为锚点（表编码变体，非算法错误）。
    (2049, 2, 1, "腊月廿九", "戊辰"),
    (2049, 2, 2, "正月初一", "己巳"),
]

# (年,月,日, 期望日干支) —— 防基准日再次写错（历史上 1899-12-19 曾整体偏移 3 位）
DAYGZ_TESTS = [
    (1949, 10, 1, "甲子"),
    (2000, 1, 1, "戊午"),
    (2026, 9, 5, "壬午"),
    (2026, 9, 6, "癸未"),
]

def main():
    failed = 0
    for (y, mo, d, exp_text, exp_ygz) in TESTS:
        L = getLunar(y, mo, d)
        ok = (L["text"] == exp_text) and (L["yearGZ"] == exp_ygz)
        if not ok:
            failed += 1
        mark = "OK " if ok else "FAIL"
        print(f"{mark} {y}-{mo:02d}-{d:02d} -> {L['yearGZ']}年 {L['text']}  日干支 {L['ganzhi']}  "
              f"建除 {L['jianchu']}  （期望 {exp_ygz}年 {exp_text}）")
        if not ok:
            print(f"      宜: {L['yi']}")
            print(f"      忌: {L['ji']}")
    print("-" * 40)
    for (y, mo, d, exp_gz) in DAYGZ_TESTS:
        L = getLunar(y, mo, d)
        ok = L["ganzhi"] == exp_gz
        if not ok:
            failed += 1
        print(f"{'OK ' if ok else 'FAIL'} 日干支 {y}-{mo:02d}-{d:02d} -> {L['ganzhi']}（期望 {exp_gz}） 建除 {L['jianchu']}")
    # 今日案例：2026-09-06 七月廿五 闭日；宜忌不得同列、各不超 3 条
    L = getLunar(2026, 9, 6)
    yi_set = set(L["yi"].split()); ji_set = set(L["ji"].split())
    conflict = yi_set & ji_set
    ok = (L["text"] == "七月廿五" and L["jianchu"] == "闭" and not conflict
          and len(yi_set) <= 3 and len(ji_set) <= 3)
    if not ok:
        failed += 1
    print(f"{'OK ' if ok else 'FAIL'} 2026-09-06 七月廿五/闭日/宜忌无冲突且各≤3条 -> "
          f"宜[{L['yi']}] 忌[{L['ji']}]" + (f" 冲突:{conflict}" if conflict else ""))
    print("-" * 40)
    print("全部通过" if failed == 0 else f"{failed} 项失败")
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())
