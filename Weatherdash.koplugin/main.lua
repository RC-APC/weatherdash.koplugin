--[[--
Weatherdash v3.1 —— 完全本地版天气壁纸插件（无服务器依赖）

与旧版（v2，依赖云端 wallpaper_service）的区别：
  · 天气数据：设备直接用 luasocket 直连 open-meteo（https，免费、无 Key、公网）。
  · 城市坐标：用 open-meteo 的 geocoding 接口解析中文城市名（同样免费无 Key），结果缓存。
  · 黄历：内置纯 Lua 农历算法（1900–2100 对照表 + 建除十二神推宜忌），完全离线。
  · 壁纸合成：在设备端用 Blitbuffer 直接绘制（内置 FontAwesome 图标字形 + 文字 + 书封 blit），
    再用 writeToFile 写成 PNG 写入屏保目录。全程不解码、不显示任何图片，
    避开 KOReader（尤其是定制版）图片渲染崩出的路径。
  · 天气图标：随插件分发裁剪过的 fa-weather.ttf（Font Awesome Free，SIL OFL 1.1），
    用 Font:getFace(绝对路径) 加载后走 RenderText 字形渲染，与 KOReader 文字同一渲染链；
    字体加载失败时自动退回内置几何画法。
  · 封面版：本地 getCoverImage 拿到书封 Blitbuffer，直接裁剪 blit 到画布，不发往任何服务器。

菜单结构：
  · 应用黄历天气壁纸（拉天气 + 本地绘黄历壁纸）
  · 应用书籍封面天气壁纸（选书 → 提取书封 BB → 本地与天气合成为壁纸）
  · 我的位置（IP 自动定位 / 90+ 城市 / 恢复默认上海）
  · 温度单位（℃ / ℉）
  · 每日自动更新（开 / 关 + 时间 + 上次状态 + 立即更新）
  · 使用说明

注意：界面文字硬编码字符串，不依赖 gettext（KOReader 全局 _ 是数值，直接 _() 会崩溃）。
源码来自 open-meteo（CC BY 4.0，免费无 Key）与公开的 1900–2100 农历对照表。

上机：把 Weatherdash.koplugin 整个目录放进 Kindle 的
      /mnt/us/koreader/plugins/，重启 KOReader，主页菜单 →
      更多工具 → 「天气壁纸」。
--]]--

-- [诊断 v3.3.4] 加载标记：A=文件开始被读到，B=顶层代码全部执行完。
-- 若插件菜单整个消失，看 koreader/plugins/Weatherdash.koplugin/_load_mark.log：
--   · 只有 A  → 加载期崩在 A 与 B 之间（模块顶层某处报错）。
--   · A、B 都有 → 加载成功；菜单不显示是别的问题。
--   · 什么都没有 → 插件根本没被加载（目录位置不对 / 没重启 KOReader）。
local function _mark(m)
    for _, p in ipairs({
        "./plugins/Weatherdash.koplugin/_load_mark.log",
        "/mnt/us/koreader/plugins/Weatherdash.koplugin/_load_mark.log",
    }) do
        pcall(function()
            local f = io.open(p, "a")
            if f then f:write(os.date("%H:%M:%S") .. " " .. m .. "\n"); f:close() end
        end)
    end
end
_mark("A file-start")

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12
pcall(function() ltn12 = require("ltn12") end)
if not ltn12 then ltn12 = require("socket.ltn12") end
local Blitbuffer = require("ffi/blitbuffer")
local RenderText = require("ui/rendertext")
local Font = require("ui/font")
local bit = require("bit")

-- 屏保子目录：天气壁纸写 screensaver/weatherdash/，
-- 「看板壁纸」（DashWallpaper 插件）写 screensaver/dashwallpaper/。
-- 两个插件各写各的文件夹互不覆盖；屏保指向哪一个由菜单「屏保指向」切换。
local WD_SUBDIR  = "weatherdash"
local DW_SUBDIR  = "dashwallpaper"
local WD_OUTNAME = "weatherdash.png"

-- JSON 解码：KOReader 不同版本/分支暴露的模块名不同，依次尝试 common 的几种。
-- 返回带 .decode 的模块（json/dkjson/cjson 都提供 .decode），失败返回 nil。
local _json_mod
local function getJSON()
    if _json_mod then return _json_mod end
    for _, name in ipairs({ "json", "dkjson", "cjson" }) do
        local ok, mod = pcall(require, name)
        if ok and mod and type(mod.decode) == "function" then
            _json_mod = mod
            return mod
        end
    end
    return nil
end

-- 公网、无 Key 的数据源（全部不需要任何私人部署）
local OPEN_METEO = "https://api.open-meteo.com/v1/forecast"
local GEOCODING = "https://geocoding-api.open-meteo.com/v1/search"

local Weatherdash = WidgetContainer:extend{
    name = "weatherdash",
    -- ★ 关键：不加 is_doc_only=false，MiuRead 定制版 KOReader 会把插件当成
    --   "仅在文档上下文可见"，导致在主页/文件浏览器菜单中看不到入口。
    is_doc_only = false,
}

local SETTINGS_FILE = "weatherdash.lua"

-- 画布尺寸（Kindle Paperwhite 4，6″ 300ppi 竖屏）。改这里即可换分辨率。
local W, H = 1072, 1448

-- 颜色：直接取 KOReader 自带的 COLOR_* 常量，原样传给 paintRect / renderUtf8Text，
--   **绝不对它们做算术、比较、==/~=**。
-- 关键事实（crash log 实证）：本固件 Blitbuffer.COLOR_BLACK / COLOR_WHITE 是
--   ffi Color8 **结构体**，不是数字——
--   · v3.3.3 顶层对它们做 `C_WHITE > C_BLACK` → "attempt to compare 'struct Color8'
--     with 'struct Color8'" → 插件加载失败（菜单消失）。
--   · v3.3.4/3.3.5 在 resolveColors 里做 `C_BLACK == nil` → 触发 Color8.__eq 元方法
--     → blitbuffer.lua:601 "attempt to index local 'color' (a nil value)" → 运行崩。
-- 结论：颜色一律"不透名"传递；解析状态用独立布尔标志（colors_resolved）跟踪，
--   绝不拿颜色 cdata 本身做判断。灰度做不了就用纯黑（字号/位置区分层级）。
local C_BLACK, C_WHITE, C_DIM
local colors_resolved = false
local function resolveColors()
    if colors_resolved then return end
    colors_resolved = true  -- 先置位防重入
    local ok = pcall(function()
        C_BLACK = Blitbuffer.COLOR_BLACK
        C_WHITE = Blitbuffer.COLOR_WHITE
    end)
    if not ok then
        C_BLACK = 0
        C_WHITE = 255  -- 极端兜底：paintRect 能吃裸数字（v3.3.2 不崩）
    end
    C_DIM = C_BLACK
end

-- 默认坐标：IP 定位失败 / 用户未设置时的兜底
local DEFAULT_CITY = "上海"
local DEFAULT_LAT, DEFAULT_LON = 31.2304, 121.4737

-- 可选城市（中日英）。本地用 geocoding 解析坐标，所以这里只放名字。
local CITY_CHOICES = {
    "上海", "北京", "广州", "深圳", "杭州", "成都", "武汉", "南京", "西安", "重庆",
    "苏州", "天津", "长沙", "青岛", "厦门", "宁波", "郑州", "无锡", "福州", "济南",
    "合肥", "昆明", "大连", "哈尔滨", "沈阳", "石家庄", "南宁", "贵阳", "太原", "长春",
    "南昌", "兰州", "海口", "呼和浩特", "银川", "西宁", "乌鲁木齐", "拉萨", "香港", "澳门", "台北",
    "东京", "纽约", "伦敦", "巴黎", "首尔", "新加坡", "曼谷", "悉尼", "墨尔本", "洛杉矶",
    "旧金山", "西雅图", "芝加哥", "波士顿", "多伦多", "温哥华", "柏林", "莫斯科", "迪拜",
    "罗马", "马德里", "巴塞罗那", "阿姆斯特丹", "苏黎世", "维也纳", "斯德哥尔摩", "哥本哈根",
    "都柏林", "雅典", "华沙", "布拉格", "里斯本", "开罗", "伊斯坦布尔", "孟买", "新德里",
    "吉隆坡", "雅加达", "马尼拉", "胡志明市", "河内", "大阪", "京都", "圣保罗", "墨西哥城",
    "布宜诺斯艾利斯", "约翰内斯堡",
}

-- 自动更新时间窗（小时）
local AUTO_HOURS = { 0, 5, 6, 7, 8, 9, 12, 18, 21, 23 }
local AUTO_CHECK_SECONDS = 30 * 60

-- ============================================================
-- 工具：URL 编码 / 时间
-- ============================================================
local function urlEncode(s)
    if not s then return "" end
    s = tostring(s)
    local out = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b <= 122 and b >= 97)
            or b == 45 or b == 46 or b == 95 or b == 126 then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = string.format("%%%02X", b)
        end
    end
    return table.concat(out)
end

local function _nowStamp()
    return os.date("%m-%d %H:%M")
end

-- ============================================================
-- 农历算法（1900–2100，公开对照表；离线，无网络）
-- ============================================================
local lunarInfo = {
    0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2, --1900-1909
    0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977, --1910-1919
    0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970, --1920-1929
    0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950, --1930-1939
    0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557, --1940-1949
    0x06ca0,0x0b550,0x15355,0x04da0,0x0a5b0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0, --1950-1959
    0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0, --1960-1969
    0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6, --1970-1979
    0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570, --1980-1989
    0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0, --1990-1999
    0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5, --2000-2009
    0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930, --2010-2019
    0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530, --2020-2029
    0x05aa0,0x076a3,0x096d0,0x04bd7,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45, --2030-2039
    0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0, --2040-2049
    0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0, --2050-2059
    0x0a2e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4, --2060-2069
    0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0, --2070-2079
    0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160, --2080-2089
    0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252, --2090-2099
    0x0d520, --2100
}

-- ★ 表为 Lua 1-based：lunarInfo[1] = 1900 年数据。
--   Y 年（1900..2100）下标 = Y - 1899。
--   ⚠ 曾误写 Y-1900（0-based 索引）：1900 年取到 lunarInfo[0]=nil，
--     bit.band(nil, b) 直接 Lua error → KOReader 当崩溃重启（两台壁纸都崩）。
--     移植自 Python（list 0-based）时必须 +1 换算。
local function lInfo(y)
    local v = lunarInfo[y - 1899]
    if not v then
        -- 越界防御（黄历范围 1900-2100，设备日期不可能越界，但求不崩）
        v = lunarInfo[y > 2100 and 201 or 1]
    end
    return v
end

local GAN = {"甲","乙","丙","丁","戊","己","庚","辛","壬","癸"}
local ZHI = {"子","丑","寅","卯","辰","巳","午","未","申","酉","戌","亥"}
local N_MONTH = {"正月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","腊月"}
local JIANCHU = {"建","除","满","平","定","执","破","危","成","收","开","闭"}
-- 建除十二神 → 宜/忌（传统简化版，离线推算。与 cnlunar 可能略有出入，仅供参阅）
local JIANCHU_YI = {
    "出行 嫁娶 祭祀 祈福","沐浴 扫舍 解除 理发","纳财 祭祀 祈福 移徙",
    "修造 嫁娶 安床 出行","纳采 订盟 安床 嫁娶","捕捉 修造 嫁娶 立券",
    "破屋 求医 治病 馀事勿取","安床 祭祀 祈福 求嗣","嫁娶 开市 入学 纳财",
    "纳财 入仓 捕捉 纳畜","开市 交易 嫁娶 出行","筑堤 安葬 补垣 纳畜",
}
local JIANCHU_JI = {
    "开市 动土 安门","嫁娶 出行 安葬","动土 安葬 开仓",
    "词讼 出行 安葬","词讼 出行 开市","开市 移徙 入宅",
    "嫁娶 出行 动土","出行 登高 词讼","词讼 安门 安葬",
    "出行 安葬 开市","安葬 修造 动土","开市 出行 栽种",
}

local function lYearDays(y)
    local sum = 348
    for m = 1, 12 do
        local b = bit.lshift(1, 16 - m)
        if bit.band(lInfo(y), b) ~= 0 then sum = sum + 1 end
    end
    local leap = bit.band(lInfo(y), 0xf)
    if leap > 0 then
        if bit.band(lInfo(y), 0x10000) ~= 0 then sum = sum + 30 else sum = sum + 29 end
    end
    return sum
end
local function leapMonth(y) return bit.band(lInfo(y), 0xf) end
local function leapDays(y)
    if leapMonth(y) == 0 then return 0 end
    return bit.band(lInfo(y), 0x10000) ~= 0 and 30 or 29
end
local function monthDays(y, m)
    local b = bit.lshift(1, 16 - m)
    return bit.band(lInfo(y), b) ~= 0 and 30 or 29
end

local function solar2lunar(y, m, d)
    local base = os.time({year=1900, month=1, day=31, hour=0, min=0, sec=0})
    local obj  = os.time({year=y, month=m, day=d, hour=0, min=0, sec=0})
    local offset = math.floor(os.difftime(obj, base) / 86400)
    local i = 1900
    local temp
    while i < 2101 and offset > 0 do
        -- 注意：temp 必须在“减完当年天数”后立即保持为该年，不能先 i+1 再取，
        -- 否则退出循环时 offset<0 的补偿会加错年份（非春节日期全部偏移）。
        temp = lYearDays(i)
        offset = offset - temp
        i = i + 1
    end
    if offset < 0 then offset = offset + temp; i = i - 1 end
    local year = i
    local leap = leapMonth(year)
    local isLeap = false
    local month = 1
    while month < 13 and offset > 0 do
        if leap > 0 and month == (leap + 1) and not isLeap then
            month = month - 1
            isLeap = true
            temp = leapDays(year)
        else
            temp = monthDays(year, month)
        end
        if isLeap and month == (leap + 1) then isLeap = false end
        offset = offset - temp
        month = month + 1
    end
    if offset == 0 and leap > 0 and month == leap + 1 then
        if isLeap then isLeap = false else isLeap = true; month = month - 1 end
    end
    if offset < 0 then offset = offset + temp; month = month - 1 end
    local day = offset + 1
    return { year = year, month = month, day = day, isLeap = isLeap }
end

local function dayGanZhi(y, m, d)
    -- 基准日必须是甲子日：1899-12-22（1900-01-01 为甲戌，前推 10 天）。
    -- ★ 旧值 1899-12-19 是错的（那是辛酉日），整体偏移 3 位 →
    --   日干支与建除十二神全部错位（1949-10-01 应为甲子、2026-09-06 应为癸未）。
    local dd = math.floor(os.difftime(
        os.time({year=y, month=m, day=d, hour=0, min=0, sec=0}),
        os.time({year=1899, month=12, day=22, hour=0, min=0, sec=0})) / 86400)
    return GAN[(dd % 10) + 1] .. ZHI[(dd % 12) + 1], dd % 12
end

local function lunarText(l)
    local m = (l.isLeap and "闰" or "") .. N_MONTH[l.month]
    local n = l.day
    local s1 = {"日","一","二","三","四","五","六","七","八","九","十"}
    local dc
    if n <= 10 then dc = "初" .. s1[n + 1]
    elseif n < 20 then dc = "十" .. s1[n - 9]
    elseif n == 20 then dc = "二十"
    elseif n < 30 then dc = "廿" .. s1[n - 19]
    else dc = "三十" end
    return m .. dc
end

-- 前置声明（诊断段会给它赋真正实现；此前的调用在无 trace 阶段为空操作）
local trace

-- 本地算黄历（1900–2100 离线算法；网络失败/无网时作为兜底）
local function getLunarInfoLocal(t)
    t = t or os.date("*t")
    local l = solar2lunar(t.year, t.month, t.day)
    local gz, dz = dayGanZhi(t.year, t.month, t.day)
    -- 年干支按“农历年”（春节切换）计，避免元旦~春节之间误显示成来年干支
    local yearGZ = GAN[((l.year - 4) % 10) + 1] .. ZHI[((l.year - 4) % 12) + 1]
    -- 建除十二神：月支索引 = (月+1)%12（正月=寅=2）；日支索引 dz；建除序 = (dz - 月支) mod 12
    local monthZhi = (l.month + 1) % 12
    local jc = (dz - monthZhi) % 12
    if jc < 0 then jc = jc + 12 end
    -- 宜/忌整理：① 同一项同时出现在宜与忌（数据自相矛盾，如"宜出行+忌出行"）
    --   → 两侧都删，宁缺毋滥；② 各只保留前 4 项（2×2 网格正好填满）。
    local yt, jt = {}, {}
    for w in JIANCHU_YI[jc + 1]:gmatch("%S+") do yt[#yt + 1] = w end
    for w in JIANCHU_JI[jc + 1]:gmatch("%S+") do jt[#jt + 1] = w end
    local drop = {}
    for _, y in ipairs(yt) do
        for _, j in ipairs(jt) do
            if y == j then drop[y] = true end
        end
    end
    local y3, j3 = {}, {}
    for _, y in ipairs(yt) do
        if not drop[y] and #y3 < 4 then y3[#y3 + 1] = y end
    end
    for _, j in ipairs(jt) do
        if not drop[j] and #j3 < 4 then j3[#j3 + 1] = j end
    end
    if trace then
        trace("lunar local: gz=" .. gz .. " dz=" .. dz .. " monthZhi=" .. monthZhi
            .. " jc=" .. jc .. "(" .. JIANCHU[jc + 1] .. ")"
            .. " yi=[" .. table.concat(y3, " ") .. "] ji=[" .. table.concat(j3, " ") .. "]")
    end
    return {
        text = lunarText(l),
        ganzhi = gz,
        yearGZ = yearGZ,
        jianchu = JIANCHU[jc + 1],
        yi = table.concat(y3, " "),
        ji = table.concat(j3, " "),
    }
end

-- 黄历统一入口：优先拉公网 mu-jie.cc（已实测 200，返回日期/干支/生肖），
-- 拉不到/解析失败 → 退到本地算法。结果缓存到 settings，24 小时有效。
-- 建除十二神（推宜忌）始终本地算（无 key 接口基本都不给完整宜忌）。
function Weatherdash:getLunarInfo(t)
    t = t or os.date("*t")
    local net = self:fetchLunarNet(t.year, t.month, t.day) or {}
    local loc = getLunarInfoLocal(t)  -- 必返（本地不可能失败）
    return {
        text     = net.text     or loc.text,
        yearGZ   = net.yearGZ   or loc.yearGZ,
        ganzhi   = net.ganzhi   or loc.ganzhi,
        zodiac   = net.zodiac   or "",
        jianchu  = loc.jianchu,
        yi       = loc.yi,
        ji       = loc.ji,
    }
end

-- ============================================================
-- 天气数据：open-meteo（公网、无 Key）
-- ============================================================
-- WMO 天气代码 → 中文描述
local WMO_DESC = {
    [0]="晴", [1]="晴间多云", [2]="多云", [3]="多云",
    [45]="雾", [48]="雾凇",
    [51]="小毛毛雨",[53]="毛毛雨",[55]="大毛毛雨",[56]="冻毛毛雨",[57]="冻毛毛雨",
    [61]="小雨",[63]="中雨",[65]="大雨",[66]="冻雨",[67]="冻雨",
    [71]="小雪",[73]="中雪",[75]="大雪",[77]="雪粒",
    [80]="阵雨",[81]="阵雨",[82]="强阵雨",
    [85]="阵雪",[86]="强阵雪",
    [95]="雷阵雨",[96]="雷阵雨伴冰雹",[99]="强雷阵雨伴冰雹",
}
-- WMO 代码 → 图标类型（按 open-meteo 实际会返回的代码逐一映射）
-- 雨势三级（v3.3.9）：drizzle=毛毛雨/小雨（云+小点）、rain=中雨（雨丝）、
-- heavy=大雨/强阵雨（粗长雨丝）。此前 51 毛毛雨也配 fa-cloud-rain 大雨滴
-- 字形，上海"晴间多云 + 模型毛毛雨"的天气被画成连场大雨，故分级修正。
local WMO_ICON = {
    [0] = "sun", [1] = "partly", [2] = "cloud", [3] = "cloud",
    [45] = "fog", [48] = "fog",
    [51] = "drizzle", [53] = "drizzle", [55] = "drizzle",
    [56] = "drizzle", [57] = "drizzle",
    [61] = "drizzle", [63] = "rain", [65] = "heavy",
    [66] = "heavy", [67] = "heavy",
    [71] = "snow", [73] = "snow", [75] = "snow", [77] = "snow",
    [80] = "drizzle", [81] = "rain", [82] = "heavy",
    [85] = "snow", [86] = "snow",
    [95] = "thunder", [96] = "thunder", [99] = "thunder",
}
local function iconType(code)
    return WMO_ICON[code or 0] or "cloud"
end

-- 城市名 → 经纬度（open-meteo geocoding，公网无 Key，结果缓存到 settings）
function Weatherdash:geocode(city)
    local cache = self.settings:readSetting("geo_cache") or {}
    if cache[city] then return cache[city].lat, cache[city].lon end
    http.TIMEOUT = 15
    local url = GEOCODING .. "?name=" .. urlEncode(city) .. "&count=1&language=zh&format=json"
    local resp = {}
    local _, code = http.request{ url = url, sink = ltn12.sink.table(resp) }
    if code ~= 200 then return nil, nil end
    local json = getJSON()
    if not json then return nil, nil end
    local ok2, j = pcall(json.decode, table.concat(resp))
    if ok2 and j and j.results and j.results[1] then
        local r = j.results[1]
        local lat, lon = tonumber(r.latitude), tonumber(r.longitude)
        if lat and lon then
            cache[city] = { lat = lat, lon = lon }
            self.settings:saveSetting("geo_cache", cache)
            self.settings:flush()
            return lat, lon
        end
    end
    return nil, nil
end

-- 拉取天气（返回标准化表）
function Weatherdash:fetchWeather(lat, lon, unit)
    local ut = (unit == "F") and "fahrenheit" or "celsius"
    local url = string.format(
        "%s?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code"
        .. "&hourly=temperature_2m,weather_code&daily=sunrise,sunset"
        -- forecast_days=2：时序条要取「当前小时 +12h」的点，若只取 1 天，
        -- 过了中午 +12h 就超出当天 24 条被截断（表现为时序条只剩 9 小时）
        .. "&forecast_days=2&timezone=auto&temperature_unit=%s",
        OPEN_METEO, lat, lon, ut)
    http.TIMEOUT = 25
    local resp = {}
    local _, code = http.request{ url = url, sink = ltn12.sink.table(resp) }
    if code ~= 200 then return nil, "天气服务返回 HTTP " .. tostring(code) end
    local json = getJSON()
    if not json then return nil, "缺少 JSON 模块（json/dkjson/cjson）" end
    local ok2, j = pcall(json.decode, table.concat(resp))
    if not ok2 or type(j) ~= "table" then return nil, "天气数据解析失败" end
    local cur = j.current or {}
    local temp = tonumber(cur.temperature_2m)
    local wcode = tonumber(cur.weather_code)
    if not temp then return nil, "天气服务无温度数据" end

    local hrs = j.hourly or {}
    local times = hrs.time or {}
    local htemps = hrs.temperature_2m or {}
    local hcodes = hrs.weather_code or {}
    local now = os.time()
    local start_i = 1
    for i = 1, #times do
        local y, mo, d, h = times[i]:match("(%d+)%-(%d+)%-(%d+)T(%d+):")
        if y then
            local ts = os.time({year=tonumber(y), month=tonumber(mo), day=tonumber(d), hour=tonumber(h), min=0, sec=0})
            if ts and ts <= now then start_i = i end
        end
    end
    local fc = {}
    for k = 0, 12, 3 do
        local i = start_i + k
        if i <= #times then
            local h = times[i]:match("T(%d+):") or "?"
            fc[#fc + 1] = {
                time = h .. ":00",
                temp = math.floor(tonumber(htemps[i]) or 0),
                code = tonumber(hcodes[i]) or 0,
            }
        end
    end

    local sunrise, sunset = "", ""
    local dl = j.daily or {}
    if dl.sunrise and dl.sunrise[1] then sunrise = (dl.sunrise[1]:match("T(%d+:%d+)") or "") end
    if dl.sunset and dl.sunset[1] then sunset = (dl.sunset[1]:match("T(%d+:%d+)") or "") end

    return {
        temp = math.floor(temp),
        code = wcode or 0,
        desc = WMO_DESC[wcode] or "未知",
        forecast = fc,
        sunrise = sunrise,
        sunset = sunset,
        unit = unit,
    }
end

-- 拉取黄历（公网 https://api.mu-jie.cc/lunar，免费无 key，HTTPS）
-- 返回：{ text, yearGZ, ganzhi, zodiac, isLeap, fetched_at } 或 nil
-- 网络失败 / 设备无网 / JSON 异常：返回 nil → 调用方应退化到本地算法
local LUNAR_NET = "https://api.mu-jie.cc/lunar?date=%s"
local LUNAR_CACHE_TTL = 86400  -- 24h 内同日期命中缓存不再重拉
function Weatherdash:fetchLunarNet(y, m, d)
    local key = string.format("%04d-%02d-%02d", y, m, d)
    local cache = self.settings:readSetting("lunar_cache") or {}
    local hit = cache[key]
    if hit and (os.time() - (hit.fetched_at or 0)) < LUNAR_CACHE_TTL then
        return hit
    end
    http.TIMEOUT = 15
    local resp = {}
    local _, code = http.request{ url = string.format(LUNAR_NET, key), sink = ltn12.sink.table(resp) }
    if code ~= 200 then return nil end
    local json = getJSON()
    if not json then return nil end
    local ok, j = pcall(json.decode, table.concat(resp))
    if not (ok and j and j.code == 200 and j.data) then return nil end
    local D = j.data
    local text = (D.isLeap and "闰" or "") .. (D.IMonthCn or "") .. (D.IDayCn or "")
    if text == "" then return nil end
    cache[key] = {
        text = text,
        yearGZ = D.gzYear or "",
        ganzhi = D.gzDay or "",
        zodiac = D.Animal or "",
        isLeap = D.isLeap and true or false,
        fetched_at = os.time(),
    }
    pcall(function() self.settings:saveSetting("lunar_cache", cache); self.settings:flush() end)
    return cache[key]
end

-- 解析当前坐标（IP 定位或城市 geocoding）
function Weatherdash:resolveCoords()
    if self.my_lat and self.my_lon then
        return self.my_lat, self.my_lon
    end
    local lat, lon = self:geocode(self.my_city or DEFAULT_CITY)
    if lat and lon then return lat, lon end
    return DEFAULT_LAT, DEFAULT_LON
end

-- ============================================================
-- 本地渲染：Blitbuffer 绘制（不解码任何图片）
-- ============================================================
-- 字体：取一个可用字体（CJK 走 KOReader 内置回退）
local _faceCache = {}
local function face(size)
    if _faceCache[size] then return _faceCache[size] end
    local names = {"cfont", "ffont", "tfont", "infont"}
    local f
    for _, n in ipairs(names) do
        local ok, ff = pcall(function() return Font:getFace(n, size) end)
        if ok and ff then f = ff; break end
    end
    _faceCache[size] = f
    return f
end

-- 字体族：serif = 中文衬线（宋/书卷气，如 DroidSerifFallback / Noto Serif CJK），
-- pub = 出版字体（纯拉丁字形，如 Kindle 系统自带的 Bookerly / Caecilia）。
-- 两族均“探测到才用”，探测不到返回 nil → 调用方回落到默认 face(size)。
-- 新版本 KOReader 的 Font:getFace(name, size) 会对非 fontmap 名字自动全表搜索
-- 系统字体目录（kindle 原生字体在扫描范围内）；老版本不支持，则手动遍历
-- FontList:getFontList() 按文件名子串找绝对路径再加载。全程 pcall，绝不崩。
local _serifName, _pubName
local function tryLoadFont(name, size)
    local ok, f = pcall(Font.getFace, Font, name, size)
    if ok and f then return f end
    local okL, FontList = pcall(require, "fontlist")
    if okL and FontList and FontList.getFontList then
        local okP, paths = pcall(FontList.getFontList, FontList)
        if okP and type(paths) == "table" then
            for _, p in ipairs(paths) do
                if type(p) == "string" and p:find(name, 1, true) then
                    local ok2, f2 = pcall(Font.getFace, Font, p, size)
                    if ok2 and f2 then return f2 end
                end
            end
        end
    end
    return nil
end
local function familyFace(size, family)
    if not size or size <= 0 then return nil end
    if family == "serif" then
        if _serifName == nil then
            _serifName = false
            for _, n in ipairs({ "NotoSerifCJKsc", "DroidSerifFallback", "NotoSerifSC", "SourceHanSerifSC" }) do
                if tryLoadFont(n, size) then _serifName = n break end
            end
        end
        if _serifName then return tryLoadFont(_serifName, size) end
    elseif family == "pub" then
        if _pubName == nil then
            _pubName = false
            for _, n in ipairs({ "Bookerly", "Caecilia", "AmazonEmber", "Georgia" }) do
                if tryLoadFont(n, size) then _pubName = n break end
            end
        end
        if _pubName then return tryLoadFont(_pubName, size) end
    end
    return nil
end
local function faceFor(size, family)
    local f
    if family then f = familyFace(size, family) end
    if not f then f = face(size) end
    return f
end

-- ============================================================
-- 内置图标字体（fonts/fa-weather.ttf，Font Awesome Free Solid 子集）
-- ============================================================
-- 图标名 → Font Awesome 6 Free Solid 码点（与 tools/subset_fa.py 的 WANT 一致）
local FA_GLYPH = {
    sun     = 0xF185,  -- fa-sun
    moon    = 0xF186,  -- fa-moon（备用，暂未用）
    partly  = 0xF6C4,  -- fa-cloud-sun（晴间多云）
    cloud   = 0xF0C2,  -- fa-cloud
    fog     = 0xF75F,  -- fa-smog
    drizzle = 0xF0C2,  -- fa-cloud（小雨：字形兜底只画云，避免小雨显示成大雨；
                       --   fa-cloud-drizzle 0xF738 不在子集字体里）
    rain    = 0xF73D,  -- fa-cloud-rain（中雨）
    heavy   = 0xF740,  -- fa-cloud-showers-heavy（大雨/强阵雨）
    snow    = 0xF2DC,  -- fa-snowflake
    thunder = 0xF76C,  -- fa-cloud-bolt
}

-- 主文件所在目录（KOReader 用绝对路径 dofile 插件，source 形如 @/mnt/us/.../main.lua）
local _pluginDir = (function()
    local src = ""
    if debug and debug.getinfo then
        local s = debug.getinfo(1, "S")
        if s and s.source then src = tostring(s.source) end
    end
    src = src:gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$")
    if dir and dir ~= "" then return dir end
    return "./"
end)()

-- [诊断] 步骤追踪：崩溃（含 ffi 段错误）时 pcall 无效，靠此日志定位死在哪一步。
-- 写入「屏保目录」（与生成的壁纸 PNG 同目录，用户能在 Kindle USB 盘根 / koreader/screensaver 找到），
-- 找不到时回落到插件目录。每次生成重开日志，只保留最近一次运行。
local _traceLog
local function _traceDir()
    local ok, ds = pcall(function() return DataStorage:getDataDir() end)
    if ok and ds then return ds .. "/screensaver" end
    return "/mnt/us/koreader/screensaver"
end
-- 绑定到前置声明的 local trace（黄历推算等更早定义的函数也要能用它），
-- 因此这里不能写 `local function trace`（会创建新局部变量、前置声明永远为 nil）。
function trace(msg)
    if _traceLog == nil then
        local dir = _traceDir()
        pcall(function() os.execute('mkdir -p "' .. dir .. '" >/dev/null 2>&1') end)
        local ok_f, f = pcall(function() return io.open(dir .. "/weatherdash_trace.log", "w") end)
        if ok_f and f then
            _traceLog = f
        else
            local ok2, f2 = pcall(function() return io.open(_pluginDir .. "/weatherdash_trace.log", "w") end)
            if ok2 and f2 then _traceLog = f2 end
        end
    end
    if not _traceLog then return end
    pcall(function()
        _traceLog:write(os.date("%H:%M:%S") .. "  " .. tostring(msg) .. "\n")
        _traceLog:flush()
    end)
end

-- 图标字体候选路径（第一种按 main.lua 所在目录推断，其它兜底常见布局）
local _iconTtf
local function _pickIconFont()
    local cands = {
        _pluginDir .. "/fonts/fa-weather.ttf",
        "./plugins/Weatherdash.koplugin/fonts/fa-weather.ttf",
        "./fonts/fa-weather.ttf",
    }
    for _, p in ipairs(cands) do
        local f = io.open(p, "rb")
        if f then f:close(); return p end
    end
    return nil
end

local _iconFaceCache = {}
local function iconFace(size)
    if not size or size <= 0 then return nil end
    if _iconFaceCache[size] then return _iconFaceCache[size] end
    local f
    if not _iconTtf then _iconTtf = _pickIconFont() end
    if _iconTtf then
        local ok, ff = pcall(Font.getFace, Font, _iconTtf, size)
        if ok and ff then f = ff end
    end
    if not f then f = face(size) end
    _iconFaceCache[size] = f
    return f
end

-- 码点 → UTF-8 字符串（RenderText 走 utf8 迭代器）
local function utf8char(cp)
    cp = cp or 0
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    else
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    end
end

-- 把一个字形以“目标像素高度”画到 (cx,cy) 中心。
-- 用 getGlyph 实测位图尺寸做迭代校准（覆盖不同设备 DPI 缩放差异），
-- 再用 glyph 的 l/t/位图尺寸精确居中，而不是猜字号或基线。
local function drawGlyphCentered(bb, cx, cy, target_h, cp, color)
    local size = math.max(12, math.floor(target_h * 1.4))
    for _attempt = 1, 4 do
        local f = iconFace(size)
        if not f then return false end
        local okg, g = pcall(RenderText.getGlyph, RenderText, f, cp, false)
        if not (okg and g and g.bb) then return false end
        local gh = g.bb:getHeight()
        if not (gh and gh > 0) then return false end
        if math.abs(gh - target_h) <= math.max(2, target_h * 0.03) then
            local gw = g.bb:getWidth() or 0
            -- 渲染时位图起点 = (x + glyph.l, baseline - glyph.t)，所以：
            --   x      = cx - gw/2 - l
            --   baseline = cy + t - gh/2
            local x = math.floor(cx - gw / 2 - (g.l or 0))
            local baseline = math.floor(cy + (g.t or 0) - gh / 2)
            local ok2 = pcall(function()
                RenderText:renderUtf8Text(bb, x, baseline, f, utf8char(cp), false, false, color or C_BLACK)
            end)
            return ok2
        end
        -- 实测高度不匹配：按比例反推新字号再测一轮
        local new_size = math.floor(size * target_h / gh)
        if new_size == size then
            new_size = size + (target_h > gh and 1 or -1)
        end
        size = math.max(8, new_size)
    end
    return false
end

local function textWidth(size, str, bold, family)
    local f = faceFor(size, family)
    if not f then return #str * size * 0.6 end
    local ok, w = pcall(function()
        return RenderText:sizeUtf8Text(0, 100000, f, str, false, bold)
    end)
    if ok and w then return w.x end
    return #str * size * 0.6
end

local function drawText(bb, x, y, str, size, bold, color, family)
    local f = faceFor(size, family)
    if not f then return end
    local baseline = y + math.floor(size * 0.82)
    local fg = color or C_BLACK
    pcall(function()
        RenderText:renderUtf8Text(bb, x, baseline, f, str, false, bold, fg)
    end)
end
local function drawTextCenter(bb, cx, y, str, size, bold, color, family)
    local w = textWidth(size, str, bold, family)
    drawText(bb, math.floor(cx - w / 2), y, str, size, bold, color, family)
end

local function rect(bb, x, y, w, h, c)
    if w <= 0 or h <= 0 then return end
    pcall(function() bb:paintRect(x, y, w, h, c) end)
end
local function fillCircle(bb, cx, cy, r, c)
    cx, cy, r = math.floor(cx), math.floor(cy), math.floor(r)
    for y = cy - r, cy + r do
        local dy = y - cy
        local dx = math.floor(math.sqrt(r * r - dy * dy))
        rect(bb, cx - dx, y, dx * 2, 1, c)
    end
end
local function ring(bb, cx, cy, r, c, thick)
    thick = thick or 6
    cx, cy, r = math.floor(cx), math.floor(cy), math.floor(r)
    for y = cy - r, cy + r do
        local dy = y - cy
        local dx = math.floor(math.sqrt(r * r - dy * dy))
        if dx > 0 then
            rect(bb, cx - dx, y, thick, 1, c)
            rect(bb, cx + dx - thick, y, thick, 1, c)
        end
    end
end
local function hline(bb, x, y, len, c, w) rect(bb, x, y, len, w or 4, c) end
local function vline(bb, x, y, len, c, w) rect(bb, x, y, w or 4, len, c) end

-- ============================================================
-- 天气图标库（按 loeffner/WeatherLockscreen 思路：预置 PNG，运行时直接取用）
-- ============================================================
-- 把一张 PNG 灰度图解码成 Blitbuffer（只走 ffi/pic，不走 ImageWidget）。
-- Pic.color=false 强制灰度 8bpp，便于与画布 BB8 兼容 blitFrom。
local function _loadImageBB(path)
    trace("Pic decode: " .. tostring(path))
    local okc, Pic = pcall(require, "ffi/pic")
    if not (okc and Pic) then trace("FAIL no ffi/pic module"); return nil end
    pcall(function() Pic.color = false end)
    local ok2, doc = pcall(Pic.openDocument, path)
    if not (ok2 and doc) then trace("FAIL Pic.openDocument " .. tostring(path)); return nil end
    local bb = doc.image_bb
    if not bb then trace("FAIL doc.image_bb nil " .. tostring(path)) end
    -- （v3.3.3 曾在此按"BB1 理论"反相图标——crash log 实证本机是 8-bit
    --   BB（TYPE_BB8 存在），图标"白底黑字"在正常画布上直接 blit 即可，
    --   反相反而错，且对 Color8 结构体做 ==0 比较有风险。已移除。）
    return bb
end

-- 按 itype 和大图(L)/小图(S)找 PNG 路径（_pluginDir 已推断）
local function _pickIconLibFile(itype, big)
    local sfx = big and "L" or "S"
    local cands = {
        _pluginDir .. "/icons/" .. itype .. "_" .. sfx .. ".png",
        "./plugins/Weatherdash.koplugin/icons/" .. itype .. "_" .. sfx .. ".png",
        "./icons/" .. itype .. "_" .. sfx .. ".png",
    }
    for _, p in ipairs(cands) do
        local f = io.open(p, "rb")
        if f then f:close(); return p end
    end
    return nil
end

local _iconBBCache = {}
local function loadIconBB(itype, big)
    local key = itype .. (big and "_L" or "_S")
    if _iconBBCache[key] ~= nil then return _iconBBCache[key] end
    local path = _pickIconLibFile(itype, big)
    local bb
    if path then bb = _loadImageBB(path) end
    _iconBBCache[key] = bb  -- cache nil/false as false 以避免重试
    return bb
end

-- 天气图标：图标库 PNG 优先；无图/解码失败退回字形；再失败退回几何。
local function drawIcon(bb, cx, cy, r, itype)
    local big = (r or 0) >= 90
    local iconbb = loadIconBB(itype, big)
    if iconbb then
        local w, h = iconbb:getWidth(), iconbb:getHeight()
        local dx = math.floor(cx - w / 2)
        local dy = math.floor(cy - h / 2)
        pcall(function() bb:blitFrom(iconbb, dx, dy, 0, 0, w, h) end)
        return
    end
    -- 兜一：内置 FontAwesome 字形渲染
    local cp = FA_GLYPH[itype]
    if cp then
        local th = math.max(16, math.floor(r * 1.5))
        if drawGlyphCentered(bb, cx, cy, th, cp) then return end
    end
    -- 兜二：纯几何画法
    drawIconGeo(bb, cx, cy, r, itype)
end

local function drawIconGeo(bb, cx, cy, r, itype)
    if itype == "partly" then itype = "cloud" end
    if itype == "sun" then
        fillCircle(bb, cx, cy, r, C_BLACK)
        for a = 0, 315, 45 do
            local rad = math.rad(a)
            local x1 = cx + math.cos(rad) * (r * 1.15)
            local y1 = cy + math.sin(rad) * (r * 1.15)
            local x2 = cx + math.cos(rad) * (r * 1.55)
            local y2 = cy + math.sin(rad) * (r * 1.55)
            rect(bb, math.min(x1, x2), math.min(y1, y2), math.abs(x2 - x1) + 1, math.abs(y2 - y1) + 1, C_BLACK)
        end
    elseif itype == "partly" then
        fillCircle(bb, cx - r * 0.45, cy - r * 0.45, r * 0.5, C_BLACK)
        ring(bb, cx + r * 0.35, cy + r * 0.35, r * 0.6, C_BLACK, 7)
        rect(bb, cx - r * 0.25, cy + r * 0.35, r * 1.2, 7, C_BLACK)
    elseif itype == "cloud" or itype == "fog" then
        ring(bb, cx - r * 0.3, cy, r * 0.55, C_BLACK, 7)
        ring(bb, cx + r * 0.3, cy - r * 0.1, r * 0.6, C_BLACK, 7)
        rect(bb, cx - r * 0.7, cy, r * 1.4, 7, C_BLACK)
        if itype == "fog" then
            hline(bb, cx - r * 0.9, cy + r * 0.5, r * 1.8, C_BLACK, 5)
            hline(bb, cx - r * 0.7, cy + r * 0.8, r * 1.4, C_BLACK, 5)
        end
    elseif itype == "drizzle" then
        -- 小雨：云 + 小圆点雨滴（与图标库 drizzle PNG 同语义，v3.3.9 分级）
        ring(bb, cx - r * 0.25, cy - r * 0.1, r * 0.55, C_BLACK, 7)
        ring(bb, cx + r * 0.3, cy - r * 0.2, r * 0.55, C_BLACK, 7)
        rect(bb, cx - r * 0.7, cy + r * 0.1, r * 1.5, 7, C_BLACK)
        local dot = math.max(4, r * 0.08)
        fillCircle(bb, cx - r * 0.4, cy + r * 0.55, dot, C_BLACK)
        fillCircle(bb, cx, cy + r * 0.65, dot, C_BLACK)
        fillCircle(bb, cx + r * 0.4, cy + r * 0.55, dot, C_BLACK)
        fillCircle(bb, cx - r * 0.2, cy + r * 0.9, dot, C_BLACK)
        fillCircle(bb, cx + r * 0.2, cy + r * 0.9, dot, C_BLACK)
    elseif itype == "rain" or itype == "heavy" or itype == "thunder" then
        ring(bb, cx - r * 0.25, cy - r * 0.1, r * 0.55, C_BLACK, 7)
        ring(bb, cx + r * 0.3, cy - r * 0.2, r * 0.55, C_BLACK, 7)
        rect(bb, cx - r * 0.7, cy + r * 0.1, r * 1.5, 7, C_BLACK)
        if itype == "rain" then
            vline(bb, cx - r * 0.4, cy + r * 0.4, r * 0.7, C_BLACK, 6)
            vline(bb, cx, cy + r * 0.4, r * 0.7, C_BLACK, 6)
            vline(bb, cx + r * 0.4, cy + r * 0.4, r * 0.7, C_BLACK, 6)
        elseif itype == "heavy" then
            -- 大雨：4 条更粗更长的雨丝
            vline(bb, cx - r * 0.5, cy + r * 0.35, r * 0.9, C_BLACK, 7)
            vline(bb, cx - r * 0.17, cy + r * 0.35, r * 0.9, C_BLACK, 7)
            vline(bb, cx + r * 0.17, cy + r * 0.35, r * 0.9, C_BLACK, 7)
            vline(bb, cx + r * 0.5, cy + r * 0.35, r * 0.9, C_BLACK, 7)
        else
            rect(bb, cx - r * 0.2, cy + r * 0.4, r * 0.35, 6, C_BLACK)
            rect(bb, cx + r * 0.05, cy + r * 0.55, r * 0.35, 6, C_BLACK)
            rect(bb, cx - r * 0.2, cy + r * 0.7, r * 0.35, 6, C_BLACK)
        end
    elseif itype == "snow" then
        ring(bb, cx - r * 0.25, cy - r * 0.1, r * 0.55, C_BLACK, 7)
        ring(bb, cx + r * 0.3, cy - r * 0.2, r * 0.55, C_BLACK, 7)
        rect(bb, cx - r * 0.7, cy + r * 0.1, r * 1.5, 7, C_BLACK)
        fillCircle(bb, cx - r * 0.4, cy + r * 0.55, 7, C_BLACK)
        fillCircle(bb, cx, cy + r * 0.7, 7, C_BLACK)
        fillCircle(bb, cx + r * 0.4, cy + r * 0.55, 7, C_BLACK)
    else
        fillCircle(bb, cx, cy, r, C_BLACK)
    end
end

-- 宜/忌 框 v3：加高黑底白字居中表头（白字显示全）+ 下方 2×2 网格明细 + 细边框
-- 数据：body 是空格分隔的条目（≤4），超过 4 个截断；少于 4 个按行主序填空格。
local function drawBadge(bb, x, y, w, h, title, body)
    -- 拆分条目（最多 4 个，2×2 网格）
    local items = {}
    for wpart in body:gmatch("[^%s]+") do
        items[#items + 1] = wpart
        if #items >= 4 then break end
    end
    local header_h = 81      -- 黑底白字表头高度（v3.3.14：再+17px ≈ 半个表头字，kindle 上白字才顶格）
    local frame_w  = 3       -- 细边框厚度
    local body_y   = y + header_h
    local body_h   = h - header_h

    -- 1) 整框先填白（防止残留黑）
    rect(bb, x, y, w, h, C_WHITE)

    -- 2) 黑底表头
    rect(bb, x, y, w, header_h, C_BLACK)

    -- 3) 表头白字居中（字号 34，baseline 取表头中线偏下，视觉居中）
    -- 表头白字：baseline 取 header_h/2 + 字高一半（≈34*0.35），框内垂直居中（v3.3.15 微上提）
    drawTextCenter(bb, x + w / 2, y + header_h * 0.5 + 12, title, 34, true, C_WHITE, nil)

    -- 4) 2×2 网格明细（最多 4 项）
    local cell_w = w / 2
    local cell_h = body_h / 2
    for i = 1, #items do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local cx = x + col * cell_w + cell_w / 2
        local cy = body_y + row * cell_h + cell_h / 2
        -- baseline 下移约 size*0.35 让文字视觉居中
        drawTextCenter(bb, cx, cy + 10, items[i], 28, false, C_BLACK, nil)
    end

    -- 5) 细边框（四边）
    rect(bb, x, y, w, frame_w, C_BLACK)                              -- 顶
    rect(bb, x, y + h - frame_w, w, frame_w, C_BLACK)                -- 底
    rect(bb, x, y, frame_w, h, C_BLACK)                              -- 左
    rect(bb, x + w - frame_w, y, frame_w, h, C_BLACK)                -- 右
end

-- [诊断 v3.2.1] trace 定义见上方 _pluginDir 之后。

-- 主渲染：返回 Blitbuffer（1072×1448）
function Weatherdash:renderWallpaper(wx, lunar, cover_bb)
    trace("== renderWallpaper begin ==")
    resolveColors()  -- 取 COLOR_* 常量（Color8 结构体，仅赋值无运算，安全）
    local tb = 1
    pcall(function() tb = Blitbuffer.TYPE_BB8 or 1 end)
    trace("A tb=" .. tostring(tb))
    local ok, bb = pcall(function() return Blitbuffer.new(W, H, tb) end)
    trace("B new ok=" .. tostring(ok))
    if not ok or not bb then
        local ok2, bb2 = pcall(function() return Blitbuffer.new(W, H) end)
        trace("C new-no-type ok=" .. tostring(ok2))
        if not ok2 or not bb2 then trace("FAIL Blitbuffer.new"); return nil end
        bb = bb2
    end
    trace("canvas new ok (" .. W .. "x" .. H .. ")")
    rect(bb, 0, 0, W, H, C_WHITE)
    trace("canvas fill white ok")

    local mx = 70
    local t = os.date("*t")
    local dateStr = string.format("%04d年%02d月%02d日 星期%s", t.year, t.month, t.day,
        ({ "日","一","二","三","四","五","六" })[t.wday])

    drawTextCenter(bb, W / 2, 46, self.my_city or DEFAULT_CITY, 36, true)
    drawTextCenter(bb, W / 2, 114, dateStr, 26, false, C_DIM)

    local iconR = 90
    drawIcon(bb, W * 0.27, 350, iconR, iconType(wx.code))
    local tempStr = tostring(wx.temp) .. "°"
    local tempSize = 110
    local tw = textWidth(tempSize, tempStr, true, "pub")
    drawText(bb, W - mx - tw, 320, tempStr, tempSize, true, C_BLACK, "pub")
    drawText(bb, W - mx - textWidth(34, wx.desc, false), 460, wx.desc, 34, false)

    rect(bb, mx, 600, W - 2 * mx, 4, C_BLACK)
    trace("hero text+icon ok")

    local fc = wx.forecast or {}
    local colw = (W - 2 * mx) / 5
    local fy = 640
    for i = 1, #fc do
        local cxc = mx + colw * (i - 0.5)
        drawTextCenter(bb, cxc, fy, fc[i].time, 24, false, C_DIM)
        drawIcon(bb, cxc, fy + 80, 36, iconType(fc[i].code))
        drawTextCenter(bb, cxc, fy + 140, tostring(fc[i].temp) .. "°", 28, false)
    end
    trace("forecast strip ok (#" .. #fc .. ")")

    local lowerY = 880
    local coverBarY = nil  -- 封面模式阅读进度条顶部 y（nil=本次未画）
    if cover_bb then
        -- 先把封面区填白（即使缩放后两侧留白也是白底，不会透出 blitbuffer 初始黑）
        local boxw, boxh = W - 2 * mx, 420  -- 缩短 40（原本 460），给下方"日出/日落"让出一行
        rect(bb, mx, lowerY, boxw, boxh, C_WHITE)
        local sw, sh = cover_bb:getWidth(), cover_bb:getHeight()
        local scale = math.min(boxw / sw, boxh / sh)
        local draw_bb = cover_bb
        local freed = false
        if scale > 0 and scale ~= 1 then
            local dw, dh = math.max(1, math.floor(sw * scale)), math.max(1, math.floor(sh * scale))
            local ok_s, sbb = pcall(function() return cover_bb:scale(dw, dh) end)
            if ok_s and sbb then draw_bb = sbb; freed = true end
        end
        local dw, dh = draw_bb:getWidth(), draw_bb:getHeight()
        local dx = mx + math.floor((boxw - dw) / 2)
        local dy = lowerY + math.floor((boxh - dh) / 2)
        pcall(function() bb:blitFrom(draw_bb, dx, dy, 0, 0, dw, dh) end)
        if freed then pcall(function() draw_bb:free() end) end
        -- 边框贴着封面图本身一圈（不框整个白盒）
        local cfw = 3
        rect(bb, dx, dy, dw, cfw, C_BLACK)                          -- 顶
        rect(bb, dx, dy + dh - cfw, dw, cfw, C_BLACK)                -- 底
        rect(bb, dx, dy, cfw, dh, C_BLACK)                           -- 左
        rect(bb, dx + dw - cfw, dy, cfw, dh, C_BLACK)                -- 右
        -- 阅读进度条（v3.3.17 自安卓端 v2.9.x 搬运）：封面盒正下方、与封面图
        -- 同宽（左右边缘与封面对齐），细黑外框 + 实心黑填充 + 右侧百分比；
        -- 整体上移半字（+13 而非 +26）。拿不到进度（-1）则不画。
        local prog = self:readingProgressFor(self.last_cover_file)
        if prog >= 0 then
            local bar_h, bfw = 30, 3
            local by2 = lowerY + boxh + 13
            coverBarY = by2
            rect(bb, dx, by2, dw, bfw, C_BLACK)                          -- 外框·顶
            rect(bb, dx, by2 + bar_h - bfw, dw, bfw, C_BLACK)            -- 外框·底
            rect(bb, dx, by2, bfw, bar_h, C_BLACK)                       -- 外框·左
            rect(bb, dx + dw - bfw, by2, bfw, bar_h, C_BLACK)            -- 外框·右
            local fillw = math.floor((dw - 2 * bfw) * prog / 100 + 0.5)
            if fillw > 0 then
                rect(bb, dx + bfw, by2 + bfw, fillw, bar_h - 2 * bfw, C_BLACK)
            end
            local ps = tostring(prog) .. "%"
            local pw = textWidth(26, ps, true, "pub")
            local px = dx + dw + 18
            if px + pw > W - 10 then px = W - 10 - pw end                -- 极宽封面防溢出
            -- drawText 的 y 是字面顶部：baseline 目标 by2+bar_h/2+9 → y = 目标-0.82*26
            drawText(bb, px, by2 + bar_h / 2 + 9 - math.floor(26 * 0.82), ps, 26, true, C_BLACK, "pub")
        end
    else
        -- 黄历版：上排农历日期，下排「宜 / 忌」两块卡片。
        -- 建除十二神不再单独标出（仅作为推算宜忌表的内部索引），
        -- 标题回到简短的「宜」「忌」，更接近传统网页版风格。
        -- 字形优先用中文衬线（书卷气，接近出版排版），找不到回落默认字体。
        drawTextCenter(bb, W / 2, lowerY, lunar.text, 38, true, C_BLACK, "serif")
        local bw = (W - 3 * mx) / 2
        local by = lowerY + 92   -- 与上方农历日期留出呼吸（原来 58 太贴）
        drawBadge(bb, mx, by, bw, 257, "宜", lunar.yi)
        drawBadge(bb, mx * 2 + bw, by, bw, 257, "忌", lunar.ji)
    end
    trace("lower half ok (" .. (cover_bb and "cover" or "lunar") .. ")")

    local sr = wx.sunrise or ""
    local ss = wx.sunset or ""
    -- 日出/日落两种模式都画。
    --   · 黄历版：放在 H-150（封面之上的空地区）。
    --   · 封面版：放在封面盒正下方（封面盒已缩短到 420 高，不再压住书封）。
    if sr ~= "" or ss ~= "" then
        if cover_bb then
            if not coverBarY then
                -- 封面盒下方空间已让给阅读进度条（与安卓端封面版一致，
                -- 日出/日落信息在黄历模式仍显示），再画会压条/压页脚。
                drawTextCenter(bb, W / 2, lowerY + 420 + 18,
                    (sr ~= "" and ("日出 " .. sr) or "") .. "   " .. (ss ~= "" and ("日落 " .. ss) or ""),
                    20, false, C_DIM)
            end
        else
            drawTextCenter(bb, W / 2, H - 132,
                (sr ~= "" and ("日出 " .. sr) or "") .. "   " .. (ss ~= "" and ("日落 " .. ss) or ""),
                20, false, C_DIM)
        end
    end

    drawTextCenter(bb, W / 2, H - 76,
        "更新于 " .. _nowStamp() .. " · 数据 open-meteo", 18, false, C_DIM)
    trace("render done, returning bb")
    return bb
end

-- ============================================================
-- 书封提取（本地，返回 Blitbuffer；不解码显示）
-- ============================================================
function Weatherdash:readFileBytes(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function Weatherdash:getRecentBooks(maxn)
    maxn = maxn or 8
    local ok_lfs, lfs = pcall(function() return require("libs/libkoreader-lfs") end)
    local exists = function(p)
        if ok_lfs and lfs then return lfs.attributes(p, "mode") == "file" end
        local f = io.open(p, "rb")
        if f then f:close() return true end
        return false
    end
    local out = {}
    local add = function(file)
        if not file or type(file) ~= "string" then return end
        for _, v in ipairs(out) do if v.file == file then return end end
        if exists(file) then out[#out + 1] = { file = file, text = file:gsub(".*/", "") } end
    end
    local ok_rh, RH = pcall(function() return require("readhistory") end)
    if ok_rh and type(RH) == "table" and type(RH.hist) == "table" then
        for i = 1, #RH.hist do
            local e = RH.hist[i]
            if e and e.file and e.select_enabled ~= false then add(e.file) end
            if #out >= maxn then break end
        end
    end
    if #out == 0 then
        local path = DataStorage:getDataDir() .. "/history.lua"
        local ok_df, data = pcall(dofile, path)
        if ok_df and type(data) == "table" then
            table.sort(data, function(a, b) return (a.time or 0) > (b.time or 0) end)
            for _, v in ipairs(data) do
                if v and v.file then add(v.file) end
                if #out >= maxn then break end
            end
        end
    end
    if #out == 0 then
        add(G_reader_settings:readSetting("lastfile"))
    end
    return out
end

function Weatherdash:readerUI()
    local ok, UI = pcall(function() return require("apps/reader/readerui") end)
    if not ok or not UI then return nil end
    local ok_i, inst = pcall(function() return UI.instance end)
    if not ok_i or not inst then return nil end
    return inst
end

-- 阅读进度（v3.3.18 修复：v3.3.17 在真机读不到进度 → 进度条不画）：
--   ★ 根因：KOReader 的 ReadHistory 条目（buildEntry）只存 time/file/text/dim/
--     mandatory/select_enabled，**根本没有 percent 字段**（_flush 也只写 time/file），
--     所以读 e.percent 永远拿不到 → 返回 -1。安卓端是从微信读书 WRReader 的
--     ShelfItem.readProgress 取，插件端不可用同一来源。
--   ★ 正确来源：
--     1) 书正在打开（ui.document.file == file）→ 实时进度：优先当前页/总页数
--        （ui.view.state.page + ui.document:getPageCount()，锁屏时最新鲜）；
--        兜底 percent_finished（0~1）。
--     2) 书已关闭 → 读它的 DocSettings 侧车文件（.sdr/...lua）：
--        DocSettings:open(file):readSetting("percent_finished")（0~1）。
--   全部拿不到返回 -1（不画进度条）。所有访问包 pcall，结构差异不致命。
function Weatherdash:readingProgressFor(file)
    if not file or file == "" then
        trace("readingProgressFor: 空文件")
        return -1
    end
    local ui = self:readerUI()
    if ui then
        local cur = nil
        pcall(function() cur = ui.document and ui.document.file end)
        if cur == file then
            trace("readingProgressFor: 当前打开的书 → 取实时进度")
            -- (1) 当前页 / 总页数（最可靠，随翻页即时更新）
            local okp, pages = pcall(function() return ui.document:getPageCount() end)
            local okc, page = pcall(function() return ui.view.state.page end)
            if okp and type(pages) == "number" and pages > 0
                    and okc and type(page) == "number" and page >= 1 then
                local pct = (pages <= 1) and 100 or math.floor(100 * (page - 1) / (pages - 1) + 0.5)
                if pct < 0 then pct = 0 end
                if pct > 100 then pct = 100 end
                trace("readingProgressFor: 页式 " .. tostring(pct) .. "% (page=" .. page .. "/" .. pages .. ")")
                return pct
            end
            -- (2) 兜底 percent_finished（0~1，关书时写入，可能略旧）
            local okf, pf = pcall(function()
                return ui.doc_settings and ui.doc_settings:readSetting("percent_finished")
            end)
            if okf and type(pf) == "number" and pf >= 0 then
                local pct = math.floor(pf * 100 + 0.5)
                if pct < 0 then pct = 0 end
                if pct > 100 then pct = 100 end
                trace("readingProgressFor: percent_finished " .. tostring(pct) .. "%")
                return pct
            end
        end
    end
    -- (3) 关闭的书：读其 DocSettings 侧车（percent_finished，0~1）
    local okd, DocSettings = pcall(function() return require("docsettings") end)
    if okd and DocSettings then
        local oko, d = pcall(function() return DocSettings:open(file) end)
        if oko and d then
            local pf = nil
            pcall(function() pf = d:readSetting("percent_finished") end)
            if type(pf) == "number" and pf > 0 then
                local pct = math.floor(pf * 100 + 0.5)
                if pct < 0 then pct = 0 end
                if pct > 100 then pct = 100 end
                trace("readingProgressFor: 侧车 percent_finished " .. tostring(pct) .. "%")
                return pct
            end
            -- (4) 极旧版本：doc_page/doc_pages
            local pg, pgs = nil, nil
            pcall(function() pg = d:readSetting("doc_page") end)
            pcall(function() pgs = d:readSetting("doc_pages") end)
            if type(pg) == "number" and pg >= 1 and type(pgs) == "number" and pgs > 0 then
                local pct = math.floor(100 * (pg - 1) / (pgs - 1) + 0.5)
                if pct < 0 then pct = 0 end
                if pct > 100 then pct = 100 end
                trace("readingProgressFor: 侧车 doc_page " .. tostring(pct) .. "%")
                return pct
            end
        end
    end
    trace("readingProgressFor: 全部失败 → -1（不画进度条）")
    return -1
end

-- 把图片文件（png/jpg/webp/gif）解码为 Blitbuffer（强制灰度 BB8，匹配画布类型）。
-- 用 ffi/pic 而非 ImageWidget，避开定制版图片渲染崩出的路径。失败返回 nil。
local function loadImageBB(path)
    if not path or #path < 3 then return nil end
    trace("cover Pic decode: " .. tostring(path))
    local ok_p, Pic = pcall(require, "ffi/pic")
    if not ok_p or not Pic then trace("FAIL cover no ffi/pic"); return nil end
    local old = Pic.color
    Pic.color = false  -- 强制灰度，便于合成为 e-ink 屏保
    local ok, doc = pcall(function() return Pic.openDocument(path) end)
    Pic.color = old
    if ok and doc and doc.image_bb then return doc.image_bb end
    trace("FAIL cover Pic.openDocument " .. tostring(path))
    return nil
end

-- 返回 (bb, 说明) 或 (nil, 错误)
function Weatherdash:getCoverBB(file)
    local ui = self:readerUI()
    local doc = ui and ui.document
    local cur_file = doc and doc.file
    local bb, src

    local ok_ds, DocSettings = pcall(function() return require("docsettings") end)
    if ok_ds and DocSettings and DocSettings.findCustomCoverFile then
        local okc, cpath = pcall(DocSettings.findCustomCoverFile, DocSettings, file)
        if okc and type(cpath) == "string" then
            local b = self:readFileBytes(cpath)
            if b and #b > 8 then
                local dbb = loadImageBB(cpath)
                if dbb then return dbb, "自定义封面" end
            end
        end
    end

    local ok_fbi, FBI = pcall(function() return require("apps/filemanager/filemanagerbookinfo") end)
    if ok_fbi and type(FBI) == "table" and FBI.getCoverImage then
        local use_doc = (cur_file == file) and doc or nil
        local okc, r1, r2 = pcall(FBI.getCoverImage, FBI, use_doc, file)
        if okc then
            if type(r2) == "string" and r2 ~= "" then
                local b = self:readFileBytes(r2)
                if b and #b > 8 then
                    local dbb = loadImageBB(r2)
                    if dbb then return dbb, "封面文件" end
                end
            end
            bb = r1; if bb then src = "FileManagerBookInfo" end
        end
    end
    if not bb and ui and ui.bookinfo and ui.bookinfo.getCoverImage then
        local okc, r1, r2 = pcall(ui.bookinfo.getCoverImage, ui.bookinfo, (cur_file == file) and doc or nil, file)
        if okc then
            if type(r2) == "string" and r2 ~= "" then
                local b = self:readFileBytes(r2)
                if b and #b > 8 then
                    local dbb = loadImageBB(r2)
                    if dbb then return dbb, "封面文件" end
                end
            end
            bb = r1; if bb then src = "ReaderUI.bookinfo" end
        end
    end
    if not bb then
        local ok_fm, FM = pcall(function() return require("apps/filemanager/filemanager") end)
        if ok_fm and FM and FM.instance and FM.instance.bookinfo and FM.instance.bookinfo.getCoverImage then
            local okc, r1, r2 = pcall(FM.instance.bookinfo.getCoverImage, FM.instance.bookinfo, nil, file)
            if okc then
                if type(r2) == "string" and r2 ~= "" then
                    local b = self:readFileBytes(r2)
                    if b and #b > 8 then
                        local dbb = loadImageBB(r2)
                        if dbb then return dbb, "封面文件" end
                    end
                end
                bb = r1; if bb then src = "FileManager.bookinfo" end
            end
        end
    end
    if not bb and doc and cur_file == file and doc.getCoverPageImage then
        local okc, r = pcall(doc.getCoverPageImage, doc)
        if okc then bb = r end
        if bb then src = "document" end
    end
    if not bb then return nil, "未能提取封面" end
    return bb, src or "书内封面"
end

-- ============================================================
-- 写盘 / 应用
-- ============================================================
function Weatherdash:findScreensaverDir()
    local data = DataStorage:getDataDir()
    local candidates = {
        data .. "/screensaver",
        data .. "/../screensaver",
        "/mnt/us/koreader/screensaver",
    }
    for _, c in ipairs(candidates) do
        local ok, f = pcall(function() return io.open(c .. "/.wd_probe", "w") end)
        if ok and f then
            pcall(function() f:close() end)
            pcall(function() os.remove(c .. "/.wd_probe") end)
            return c
        end
    end
    local c = candidates[1]
    pcall(function() os.execute('mkdir -p "' .. c .. '" >/dev/null 2>&1') end)
    return c
end

-- 确保屏保根目录下自己的子目录存在且可写；建不出来就回落根目录（保证还能出图）
function Weatherdash:ensureSubDir(name)
    local root = self:findScreensaverDir()
    local sub = root .. "/" .. name
    pcall(function() os.execute('mkdir -p "' .. sub .. '" >/dev/null 2>&1') end)
    local ok, f = pcall(function() return io.open(sub .. "/.wd_probe", "w") end)
    if ok and f then
        pcall(function() f:close() end)
        pcall(function() os.remove(sub .. "/.wd_probe") end)
        return sub
    end
    return root
end

-- 取 KOReader 全局设置对象（G_reader_settings）：不同版本可能没挂全局，兜底自己打开
local function _grs()
    if type(G_reader_settings) == "table" and G_reader_settings.readSetting then
        return G_reader_settings
    end
    local dir
    local ok, d = pcall(function() return DataStorage:getSettingsDir() end)
    if ok and d then dir = d else dir = DataStorage:getDataDir() end
    return require("luasettings"):open(dir .. "/settings.reader.lua")
end

-- 当前屏保目录指向（字符串；未设置返回 nil）
local function _currentScreensaverDir()
    local v
    pcall(function() v = _grs():readSetting("screensaver_dir") end)
    return v
end

-- 把 KOReader 屏保目录指向某个子目录（weatherdash / dashwallpaper）
-- 同时处理前缀键：若用户单独设过「待机/关机」屏保目录（优先级高于通用键），一并向新目录改。
local function _setScreensaverDir(dir)
    return pcall(function()
        local G = _grs()
        G:saveSetting("screensaver_dir", dir)
        for _, p in ipairs({ "sleep_", "exit_" }) do
            if G:readSetting(p .. "screensaver_dir") ~= nil then
                G:saveSetting(p .. "screensaver_dir", dir)
            end
        end
        G:flush()
    end)
end

function Weatherdash:currentScreensaverTarget()
    return _currentScreensaverDir()
end

function Weatherdash:setScreensaverTarget(sub)
    local dir = self:ensureSubDir(sub)
    local ok = _setScreensaverDir(dir)
    return ok, dir
end

function Weatherdash:saveBB(bb)
    trace("saveBB: find screensaver dir")
    local dir = self:ensureSubDir(WD_SUBDIR)
    local out = dir .. "/" .. WD_OUTNAME
    trace("saveBB: writeToFile " .. tostring(out))
    local ok = pcall(function() return bb:writeToFile(out, "png") end)
    if not ok then trace("FAIL writeToFile"); return false, "写 PNG 失败" end
    -- 写成功即把屏保指向自己的文件夹（应用哪个插件，屏保就显示哪个）
    pcall(function() _setScreensaverDir(dir) end)
    trace("saveBB ok")
    return true, out
end

-- ============================================================
-- 主流程
-- ============================================================
function Weatherdash:applyWeather(interactive)
    if interactive then
        UIManager:show(InfoMessage:new{ text = "正在获取天气并生成本地壁纸：" .. (self.my_city or DEFAULT_CITY) .. "…" })
    end
    -- 记录「上次更新模式 = 黄历」，锁屏自动刷新沿用
    self.last_mode = "lunar"
    pcall(function()
        self.settings:saveSetting("last_mode", "lunar")
        self.settings:flush()
    end)
    UIManager:scheduleIn(0.1, function()
        trace("== applyWeather (lunar) ==")
        local lat, lon = self:resolveCoords()
        trace("resolveCoords -> " .. tostring(lat) .. "," .. tostring(lon))
        local wx, err = self:fetchWeather(lat, lon, self.unit or "C")
        if not wx then trace("FAIL fetchWeather: " .. tostring(err)); self:_fail(interactive, err); return end
        trace("weather ok: " .. tostring(wx.temp) .. "C code=" .. tostring(wx.code))
        local lunar = self:getLunarInfo(os.date("*t"))
        resolveColors()  -- 颜色按本机 BB 类型解析（运行期；勿放模块顶层/渲染函数内）
        local bb = self:renderWallpaper(wx, lunar, nil)
        if not bb then self:_fail(interactive, "本地合成壁纸失败"); return end
        local ok, msg = self:saveBB(bb)
        pcall(function() if bb.free then bb:free() end end)
        if not ok then self:_fail(interactive, msg); return end
        self:_ok(interactive, "已应用黄历天气壁纸", msg)
    end)
end

function Weatherdash:applyCoverWallpaper(file, name)
    if not file or file == "" then
        UIManager:show(InfoMessage:new{ text = "无法定位该书文件路径。" })
        return
    end
    -- 记录「上次更新模式 = 封面」，并记住所选书籍，锁屏自动刷新沿用
    self.last_mode = "cover"
    self.last_cover_file = file
    self.last_cover_name = name or ""
    pcall(function()
        self.settings:saveSetting("last_mode", "cover")
        self.settings:saveSetting("last_cover_file", file)
        self.settings:saveSetting("last_cover_name", name or "")
        self.settings:flush()
    end)
    UIManager:show(InfoMessage:new{ text = "正在获取天气并提取封面：\n" .. tostring(name or "") .. "\n（城市：" .. (self.my_city or DEFAULT_CITY) .. "）" })
    UIManager:scheduleIn(0.1, function()
        trace("== applyCoverWallpaper ==")
        local ok_p, cover_bb, src = pcall(function() return self:getCoverBB(file) end)
        if not ok_p or not cover_bb then
            trace("FAIL getCoverBB: " .. tostring(ok_p) .. "/" .. tostring(cover_bb))
            UIManager:show(InfoMessage:new{ text = "封面提取失败：\n" .. tostring(not ok_p and cover_bb or "未知错误") .. "\n该书可能没有内嵌封面图。" })
            return
        end
        trace("cover ok via " .. tostring(src or "?"))
        local lat, lon = self:resolveCoords()
        local wx, err = self:fetchWeather(lat, lon, self.unit or "C")
        if not wx then
            pcall(function() if cover_bb.free then cover_bb:free() end end)
            self:_fail(true, err)
            return
        end
        local lunar = self:getLunarInfo(os.date("*t"))
        resolveColors()  -- 颜色按本机 BB 类型解析（运行期）
        local bb = self:renderWallpaper(wx, lunar, cover_bb)
        pcall(function() if cover_bb.free then cover_bb:free() end end)
        if not bb then self:_fail(true, "本地合成封面壁纸失败"); return end
        local ok, msg = self:saveBB(bb)
        pcall(function() if bb.free then bb:free() end end)
        if not ok then self:_fail(true, msg); return end
        self:_ok(true, "已应用：最新天气 + 「" .. tostring(name or "") .. "」封面", msg)
    end)
end

function Weatherdash:_ok(interactive, title, path)
    self.last_auto_status = "成功 " .. _nowStamp()
    pcall(function()
        self.settings:saveSetting("last_auto_status", self.last_auto_status)
        self.settings:flush()
    end)
    if interactive then
        UIManager:show(InfoMessage:new{
            text = title .. "\n保存到：" .. (path or "") ..
                "\n\n让 Kindle 进入休眠即可看到。\n（若屏保不显示，请在 KOReader 设置里把屏保目录指向该路径。）",
        })
    end
end
function Weatherdash:_fail(interactive, msg)
    self.last_auto_status = "失败 " .. _nowStamp()
    pcall(function()
        self.settings:saveSetting("last_auto_status", self.last_auto_status)
        self.settings:flush()
    end)
    if interactive then
        UIManager:show(InfoMessage:new{ text = (msg or "失败") .. "\n请确认已联网（首次使用需联网拉取天气）。" })
    end
end

function Weatherdash:saveCity()
    pcall(function()
        self.settings:saveSetting("city", self.my_city)
        if self.my_lat and self.my_lon then
            self.settings:saveSetting("lat", self.my_lat)
            self.settings:saveSetting("lon", self.my_lon)
        else
            self.settings:saveSetting("lat", nil)
            self.settings:saveSetting("lon", nil)
        end
        self.settings:flush()
    end)
end

-- ============================================================
-- IP 自动定位（公网 ip-api.com，免费无 Key）
-- ============================================================
function Weatherdash:ipLocateAndApply()
    UIManager:show(InfoMessage:new{ text = "正在通过 IP 自动定位…" })
    UIManager:scheduleIn(0.1, function()
        http.TIMEOUT = 12
        local resp = {}
        local _, code = http.request{ url = "http://ip-api.com/json/?lang=zh-CN", sink = ltn12.sink.table(resp) }
        if code ~= 200 or #resp == 0 then
            UIManager:show(InfoMessage:new{ text = "IP 定位失败（HTTP " .. tostring(code) .. "），请确认已联网。" })
            return
        end
        local json = getJSON()
        if not json then UIManager:show(InfoMessage:new{ text = "IP 定位失败：缺少 JSON 模块。" }); return end
        local ok2, j = pcall(json.decode, table.concat(resp))
        if not ok2 or type(j) ~= "table" or j.status == "fail" then
            UIManager:show(InfoMessage:new{ text = "IP 定位失败：" .. (j and j.message or "解析失败") })
            return
        end
        self.my_city = j.city or DEFAULT_CITY
        self.my_lat = tonumber(j.lat)
        self.my_lon = tonumber(j.lon)
        self:saveCity()
        UIManager:show(InfoMessage:new{ text = "已定位到「" .. self.my_city .. "」\n坐标：" ..
            string.format("%.2f, %.2f", self.my_lat or 0, self.my_lon or 0) .. "\n\n正在生成对应壁纸…" })
        self:applyWeather(false)
    end)
end

-- ============================================================
-- 每日自动更新
-- ============================================================
function Weatherdash:shouldAutoRun()
    if not self.auto_enabled then return false end
    local today = os.date("%Y-%m-%d")
    if self.last_auto_date == today then return false end
    local hh = tonumber(os.date("%H")) or 0
    if hh < (tonumber(self.auto_hour) or 6) then return false end
    return true
end

-- 用「上次手动选择的模式」（黄历 / 封面）刷新壁纸，写入屏保目录。
-- 供：① 每次锁屏（onSuspend）② 每日自动更新轮询 ③ 菜单「立即更新一次」共用。
-- 返回 true/false；联网失败 / 取数失败 → 写状态、返回 false（绝不崩）。
function Weatherdash:updateUsingLastMode(interactive)
    -- 同一锁屏事件可能被重复触发，30 秒内只刷一次，避免重复联网
    local now_ts = os.time()
    if self.last_lock_ts and (now_ts - self.last_lock_ts) < 30 then
        return false
    end
    self.last_lock_ts = now_ts
    local ok, ran = pcall(function()
        local isOnline = true
        local ok_mgr, mgr = pcall(function() return require("ui/network/manager") end)
        if ok_mgr and mgr then
            local st, r = pcall(function()
                if mgr.isOnline and mgr:isOnline() then return true end
                if mgr.isWifiOn and mgr:isWifiOn() then return true end
                if mgr.isConnected and mgr:isConnected() then return true end
                return false
            end)
            if st then isOnline = r end
        end
        if not isOnline then
            self.last_auto_status = "待联网（" .. _nowStamp() .. "）"
            pcall(function() self.settings:saveSetting("last_auto_status", self.last_auto_status); self.settings:flush() end)
            return false
        end
        local lat, lon = self:resolveCoords()
        local wx, err = self:fetchWeather(lat, lon, self.unit or "C")
        if not wx then
            self.last_auto_status = "失败 " .. _nowStamp() .. "（" .. tostring(err) .. "）"
            pcall(function() self.settings:saveSetting("last_auto_status", self.last_auto_status); self.settings:flush() end)
            return false
        end
        local lunar = self:getLunarInfo(os.date("*t"))
        resolveColors()  -- 颜色按本机 BB 类型解析（运行期）
        -- 封面模式：按记忆的书重新提取封面；取不到则回落黄历
        local cover_bb
        if self.last_mode == "cover" and self.last_cover_file and self.last_cover_file ~= "" then
            local ok_p, cbb = pcall(function() return self:getCoverBB(self.last_cover_file) end)
            if ok_p and cbb then cover_bb = cbb else cover_bb = nil end
        end
        local bb = self:renderWallpaper(wx, lunar, cover_bb)
        if cover_bb and cover_bb.free then pcall(function() cover_bb:free() end) end
        if not bb then
            self.last_auto_status = "失败 " .. _nowStamp() .. "（合成失败）"
            pcall(function() self.settings:saveSetting("last_auto_status", self.last_auto_status); self.settings:flush() end)
            return false
        end
        local ok_s, msg = self:saveBB(bb)
        pcall(function() if bb.free then bb:free() end end)
        self._lastOut = msg
        if ok_s then
            self.last_auto_status = "成功 " .. _nowStamp()
            pcall(function() self.settings:saveSetting("last_auto_status", self.last_auto_status); self.settings:flush() end)
        end
        return ok_s
    end)
    if not ok then
        local detail = tostring(ran or "?")
        if #detail > 60 then detail = detail:sub(1, 60) .. "…" end
        self.last_auto_status = "异常：" .. detail .. " " .. _nowStamp()
        pcall(function() self.settings:saveSetting("last_auto_status", self.last_auto_status); self.settings:flush() end)
        if interactive then UIManager:show(InfoMessage:new{ text = "更新异常：\n" .. self.last_auto_status }) end
        return false
    end
    if interactive then
        if ran then
            UIManager:show(InfoMessage:new{ text = "已更新（" .. (self.last_mode == "cover" and "书籍封面" or "黄历") .. "模式）\n保存到：" .. (self._lastOut or "") .. "\n\n让设备休眠即可看到。" })
        else
            UIManager:show(InfoMessage:new{ text = "更新失败：\n" .. self.last_auto_status .. "\n请确认已联网（首次使用需联网拉取天气）。" })
        end
    end
    return ran
end

function Weatherdash:runAutoUpdate(force)
    local ok, ran = pcall(function()
        if not force and not self:shouldAutoRun() then return false end
        local today = os.date("%Y-%m-%d")
        self.last_auto_date = today
        pcall(function() self.settings:saveSetting("last_auto_date", today) end)
        return self:updateUsingLastMode(false)
    end)
    if not ok then
        local detail = tostring(ran or "?")
        if #detail > 60 then detail = detail:sub(1, 60) .. "…" end
        self.last_auto_status = "异常：" .. detail .. " " .. _nowStamp()
        pcall(function() self.settings:saveSetting("last_auto_status", self.last_auto_status); self.settings:flush() end)
        return false
    end
    return ran
end

function Weatherdash:autoSchedule(delay)
    UIManager:scheduleIn(delay or AUTO_CHECK_SECONDS, function()
        self:runAutoUpdate(false)
        self:autoSchedule(AUTO_CHECK_SECONDS)
    end)
end

function Weatherdash:onResume()
    UIManager:scheduleIn(3, function() self:runAutoUpdate(false) end)
    return false
end
-- 锁屏（休眠）触发：用上次选择的模式刷新一次壁纸（沿用 黄历 / 封面 选择）。
-- 受「自动更新」总开关控制；30 秒内重复触发由 updateUsingLastMode 内部去重。
function Weatherdash:onSuspend()
    if self.auto_enabled then
        pcall(function() self:updateUsingLastMode(false) end)
    end
    return false
end

-- ============================================================
-- 菜单
-- ============================================================
function Weatherdash:init()
    self.settings = LuaSettings:open(DataStorage:getDataDir() .. "/" .. SETTINGS_FILE)
    local ok = pcall(function()
        self.my_city   = self.settings:readSetting("city") or DEFAULT_CITY
        self.my_lat    = self.settings:readSetting("lat")
        self.my_lon    = self.settings:readSetting("lon")
        self.unit      = self.settings:readSetting("unit") or "C"
        if self.unit ~= "C" and self.unit ~= "F" then self.unit = "C" end
        self.auto_enabled  = self.settings:readSetting("auto_enabled")
        if self.auto_enabled == nil then self.auto_enabled = true end
        self.auto_hour     = tonumber(self.settings:readSetting("auto_hour")) or 6
        self.last_auto_date   = self.settings:readSetting("last_auto_date") or ""
        self.last_auto_status = self.settings:readSetting("last_auto_status") or ""
        -- 上次手动选择的更新模式（锁屏自动刷新沿用此模式）
        self.last_mode         = self.settings:readSetting("last_mode") or "lunar"
        self.last_cover_file   = self.settings:readSetting("last_cover_file") or ""
        self.last_cover_name   = self.settings:readSetting("last_cover_name") or ""
    end)
    if not ok then
        self.my_city = DEFAULT_CITY; self.my_lat = nil; self.my_lon = nil
        self.unit = "C"; self.auto_enabled = true; self.auto_hour = 6
        self.last_auto_date = ""; self.last_auto_status = ""
        self.last_mode = "lunar"; self.last_cover_file = ""; self.last_cover_name = ""
    end
    local reg_ok = pcall(function() self.ui.menu:registerToMainMenu(self) end)
    if not reg_ok then
        pcall(function() if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end end)
    end
    pcall(function() self:autoSchedule(8) end)
end

function Weatherdash:addToMainMenu(menu_items)
    menu_items.weatherdash = { text = "天气壁纸", sorting_hint = "more_tools",
        sub_item_table_func = function() return self:buildSubmenu() end }
end
function Weatherdash:addToReaderMenu(menu_items)
    menu_items.weatherdash = { text = "天气壁纸", sorting_hint = "more_tools",
        sub_item_table_func = function() return self:buildSubmenu() end }
end
function Weatherdash:addToFileManagerMenu(menu_items)
    menu_items.weatherdash = { text = "天气壁纸", sorting_hint = "more_tools",
        sub_item_table_func = function() return self:buildSubmenu() end }
end

function Weatherdash:buildSubmenu()
    local t = {}
    t[#t + 1] = { text = "应用黄历天气壁纸", callback = function() self:applyWeather(true) end }

    local cv = {}
    local ok_r, books = pcall(function() return self:getRecentBooks(8) end)
    if not ok_r or type(books) ~= "table" or #books == 0 then
        cv[#cv + 1] = { text = "（暂无最近阅读记录）", enabled = false }
    else
        for _, b in ipairs(books) do
            local f, name = b.file, b.text
            cv[#cv + 1] = { text = name, callback = function() self:applyCoverWallpaper(f, name) end }
        end
    end
    t[#t + 1] = { text = "应用书籍封面天气壁纸", sub_item_table = cv }

    local loc = {}
    loc[#loc + 1] = { text = "IP 自动定位", callback = function() self:ipLocateAndApply() end }
    local city_items = { { text = "恢复默认（" .. DEFAULT_CITY .. "）", callback = function()
        self.my_city = DEFAULT_CITY; self.my_lat, self.my_lon = nil, nil
        self:saveCity(); self:applyWeather(true) end } }
    for _, c in ipairs(CITY_CHOICES) do
        city_items[#city_items + 1] = { text_func = function() return c end,
            callback = function()
                self.my_city = c; self.my_lat, self.my_lon = nil, nil
                self:saveCity(); self:applyWeather(true) end }
    end
    loc[#loc + 1] = { text_func = function() return "我的城市（当前：" .. (self.my_city or DEFAULT_CITY) .. "）" end, sub_item_table = city_items }
    loc[#loc + 1] = { text_func = function()
        if self.my_lat and self.my_lon then return string.format("定位坐标：%.2f, %.2f", self.my_lat, self.my_lon) end
        return "未使用坐标（按城市名生成）" end, enabled = false }
    t[#t + 1] = { text_func = function() return "我的位置：" .. (self.my_city or DEFAULT_CITY) end, sub_item_table = loc }

    local unit_items = {
        { text = "摄氏度 °C", checked_func = function() return self.unit == "C" end,
            callback = function() self.unit = "C"; self.settings:saveSetting("unit", "C"); self.settings:flush(); self:applyWeather(true) end, radio = true },
        { text = "华氏度 °F", checked_func = function() return self.unit == "F" end,
            callback = function() self.unit = "F"; self.settings:saveSetting("unit", "F"); self.settings:flush(); self:applyWeather(true) end, radio = true },
    }
    t[#t + 1] = { text_func = function() return "温度单位：" .. self.unit end, sub_item_table = unit_items }

    local ut = {}
    ut[#ut + 1] = { text_func = function() return "自动更新：" .. (self.auto_enabled and "开" or "关") end,
        callback = function() self.auto_enabled = not self.auto_enabled; self.settings:saveSetting("auto_enabled", self.auto_enabled); self.settings:flush() end }
    local ht = {}
    for _, h in ipairs(AUTO_HOURS) do
        ht[#ht + 1] = { text_func = function() return string.format("%02d:00", h) end,
            callback = function() self.auto_hour = h; self.settings:saveSetting("auto_hour", h); self.settings:flush() end }
    end
    ut[#ut + 1] = { text_func = function() return "更新时间：" .. string.format("%02d:00", self.auto_hour) .. " 之后" end, sub_item_table = ht }
    ut[#ut + 1] = { text_func = function() return "上次更新：" .. (self.last_auto_status ~= "" and self.last_auto_status or "尚未执行") end,
        callback = function() UIManager:show(InfoMessage:new{ text = "上次自动更新：" .. (self.last_auto_status ~= "" and self.last_auto_status or "尚未执行") .. "\n今天：" .. os.date("%Y-%m-%d %H:%M") }) end }
    ut[#ut + 1] = { text_func = function()
        if self.last_mode == "cover" then
            local nm = (self.last_cover_name ~= "" and self.last_cover_name or "上次所选")
            local pg = self:readingProgressFor(self.last_cover_file)
            if pg >= 0 then nm = nm .. " · " .. pg .. "%" end
            return "锁屏刷新模式：书籍封面（" .. nm .. "）"
        end
        return "锁屏刷新模式：黄历（上次所选）"
    end, enabled = false }
    ut[#ut + 1] = { text = "立即更新一次", callback = function() self:updateUsingLastMode(true) end }
    t[#t + 1] = { text_func = function() return "每日自动更新：" .. (self.auto_enabled and "开" or "关") end, sub_item_table = ut }

    -- 组：屏保指向——两个插件各写各的文件夹，这里选屏保显示哪一个
    local st = {}
    st[#st + 1] = {
        text_func = function() return "天气壁纸（screensaver/" .. WD_SUBDIR .. "）" end,
        checked_func = function()
            local cur = _currentScreensaverDir() or ""
            return cur:find(WD_SUBDIR, 1, true) ~= nil
        end,
        callback = function()
            local ok, dir = self:setScreensaverTarget(WD_SUBDIR)
            UIManager:show(InfoMessage:new{ text = ok
                and ("屏保已指向天气壁纸：\n" .. dir .. "\n休眠即可看到。")
                or "切换失败，请到 KOReader 设置里手动选择屏保目录。" })
        end,
    }
    st[#st + 1] = {
        text_func = function() return "看板壁纸（screensaver/" .. DW_SUBDIR .. "）" end,
        checked_func = function()
            local cur = _currentScreensaverDir() or ""
            return cur:find(DW_SUBDIR, 1, true) ~= nil
        end,
        callback = function()
            local ok, dir = self:setScreensaverTarget(DW_SUBDIR)
            UIManager:show(InfoMessage:new{ text = ok
                and ("屏保已指向看板壁纸：\n" .. dir .. "\n（需先在「看板壁纸」插件里应用过一次）")
                or "切换失败，请到 KOReader 设置里手动选择屏保目录。" })
        end,
    }
    t[#t + 1] = {
        text_func = function()
            local cur = _currentScreensaverDir() or ""
            local name
            if cur:find(WD_SUBDIR, 1, true) then name = "天气壁纸"
            elseif cur:find(DW_SUBDIR, 1, true) then name = "看板壁纸"
            else name = "未设置" end
            return "屏保指向：" .. name
        end,
        sub_item_table = st,
    }

    t[#t + 1] = { text = "使用说明", callback = function()
        UIManager:show(InfoMessage:new{ text =
            "· 点「应用黄历天气壁纸」立即联网拉取天气，在设备本地\n"
            .. "  绘制成 PNG 写入屏保目录，休眠即可看到（下半区=黄历）。\n"
            .. "· 「应用书籍封面天气壁纸」：选最近读的书，自动提取\n"
            .. "  书内封面（本地 Blitbuffer，不解码显示），与天气在本地\n"
            .. "  合成一张壁纸（下半区=书籍封面）。\n"
            .. "· 完全不依赖任何私人服务器：天气来自 open-meteo（公网、\n"
            .. "  免费、无 Key），黄历由插件内置算法本地计算。\n"
            .. "· 「我的位置」：IP 自动定位 / 90+ 城市（open-meteo 解析坐标）。\n"
            .. "· 「温度单位」：切换 ℃ / ℉。\n"
            .. "· 「每日自动更新」：唤醒 / 休眠前 / 每 30 分钟轮询补做。\n"
            .. "· 每次锁屏（休眠）会按「上次选择的模式」刷新一次：\n"
            .. "  手动点过「黄历」或某本「封面」后，之后每次锁屏都沿用该模式\n"
            .. "  （封面模式会重新提取上次那本书的封面）。\n\n"
            .. "· 「屏保指向」：天气壁纸写在 screensaver/weatherdash/，\n"
            .. "  「看板壁纸」写在 screensaver/dashwallpaper/，两插件互不覆盖；\n"
            .. "  在这里选屏保显示哪一个（应用哪个插件就自动指向哪个）。\n\n"
            .. "数据来源：open-meteo（天气 / 地理编码，CC BY 4.0）+ 内置农历算法。\n"
            .. "本插件只写 PNG 不解码图片，故不会像图片模式那样崩出。\n\n"
            .. "若屏保不显示，请确认「屏保指向」选的是你想要的那个文件夹。" })
    end }
    return t
end

_mark("B end-ok")
return Weatherdash
