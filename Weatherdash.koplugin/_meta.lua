-- Weatherdash._meta（KOReader 插件元数据）
-- 现代契约：直接 return 纯字符串 table，不调用 gettext
-- （部分定制版 KOReader 的全局 _ 是数值，直接 _() 会崩溃，故全插件零 gettext）。

return {
    name = "weatherdash",
    fullname = "Weatherdash 天气壁纸",
    description = "完全本地版天气壁纸 v3.3：天气直连 open-meteo（公网免费无 Key），黄历优先用公网 api.mu-jie.cc（免费无 Key）拉农历日期/干支，本地 1900–2100 农历算法作离线兜底。壁纸在设备端用 Blitbuffer 几何绘制（温度大字走出版字体 Bookerly/Caecilia 探测；黄历日期走中文衬线 CJK 探测如 DroidSerifFallback/NotoSerifCJKsc，找不到自动回落 NotoSans）。可选本地提取最近阅读书籍封面与天气合成为一张壁纸。无服务器依赖、零图片解码、零 gettext，适合精简/定制版 KOReader。",
    version = "3.3.18",
    min_api_version = "1.0.0",
}