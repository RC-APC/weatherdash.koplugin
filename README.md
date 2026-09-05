# Weatherdash · KOReader 天气壁纸

把**实时天气**变成 Kindle / KOReader 设备的**休眠屏保壁纸**：
竖屏大图上，上半屏是城市、日期、天气大图标、超大当前温度与 5 小时预测，
下半屏可二选一展示 **当日黄历（农历 + 宜/忌）** 或 **最近阅读书籍封面**。

全链路使用**免费无 Key** 的数据源（open-meteo 天气、ip-api 定位、cnlunar 黄历），
渲染全部发生在**你自己的服务端**（本地或云端都行），Kindle 端插件**只下载字节、
写屏保目录，绝不解码图片**——因此在图片渲染路径易崩的精简/定制版 KOReader 上
也不会闪退。

<p align="center">
  <img src="docs/sample_lunar.png" width="300" alt="黄历版"/>
  <img src="docs/sample_cover.png" width="300" alt="书籍封面版"/>
</p>

## 特性

- 🖼 **e-ink 友好版式**：默认 1072×1448（Kindle Paperwhite 4，6″ 300ppi），灰阶几何图标 + 大字排版；分辨率可在渲染器里一行改
- ☀️ **左大图标 + 右超大温度** + 宽松间距的"多云 24~31°"描述行
- ⏱ **未来 12 小时预测条**（现在 + 每 3h ×5 点，时间 / 大图标 / 温度）
- 📅 **黄历下半屏**：农历日期（楷体大字）+ 「宜 / 忌」窄徽章行
- 📚 **书籍封面下半屏**：Kindle 端上传最近阅读的书封 → 云端取**最新天气**合成（POST 无缓存）
- 🌐 **90+ 中英城市**内置坐标；也支持 `lat/lon` 直传任意地点；IP 自动定位（中文城市名）
- 🌡 ℃ / ℉ 一键切换（服务端以华氏直接返回）
- 🔁 每日自动更新（唤醒 / 休眠前 / 前台 30 分钟轮询三处补做）
- 🛡 零图片解码 + 零 gettext 依赖（KOReader 插件安全路径）
- 🔌 单插件文件结构、中文菜单、is_doc_only=false（主页/文件浏览器/阅读三上下文可见）

## 架构

```
┌─ Kindle (KOReader) ──────────────────────────────┐      ┌─ 你的服务器 ────────────────────────┐
│ Weatherdash.koplugin                             │ HTTP │ wallpaper_service (Python)          │
│  菜单：                                          │  GET │  /wallpaper?theme=weather           │
│   · 应用黄历天气壁纸  ──────────────────────────┼──►──│     &city=上海&unit=C              │
│   · 应用书籍封面天气壁纸：                       │      │   ├ 查城市坐标表 / geocoding         │
│      选最近读的书 → 提取封面（不解码）──POST────┼──►──│   ├ open-meteo 实时天气（无 Key）    │
│   · 我的位置 / 温度单位 / 每日自动更新           │      │   ├ cnlunar 当日黄历                 │
│                                                │      │   └ Pillow 渲染 PNG ──► 返回字节      │
│  校验 PNG 魔数 → 写 screensaver/dashwallpaper.png│◄─────┼─────────────────────────────────────── │
└──────────────────────────────────────────────────┘      └─────────────────────────────────────┘
        ↑ 休眠时由 KOReader 帧缓冲显示（不经过图片解码，故安全）
```

两种"下半屏"由**请求方式**决定，互不覆盖、随时切换：

| 动作 | 请求 | 下半屏 |
|---|---|---|
| 菜单「应用黄历天气壁纸」 | `GET` | 黄历（农历 + 宜/忌） |
| 菜单「应用书籍封面天气壁纸」→ 点书 | `POST`（body = 封面 PNG/JPEG） | 书籍封面（每次向云端取最新天气再合成） |

## 仓库结构

```
weatherdash/
├── wallpaper_service/            # 云端渲染服务（可本地跑 / 可部署）
│   ├── app.py                    # HTTP 服务：GET /wallpaper、POST 封面合成、/where
│   ├── make_wallpaper.py         # 渲染器 + 命令行出图（--city 直接出预览）
│   ├── weather.py                # WMO 天气码 → 中文描述 等
│   ├── requirements.txt          # Pillow / requests / cnlunar
│   └── fonts/                    # 见 README：放入 simhei.ttf / simkai.ttf（可选）
├── koplugin/
│   └── Weatherdash.koplugin/     # KOReader 端插件（main.lua + _meta.lua）
├── docs/                         # 截图
├── README.md
└── LICENSE
```

## 快速开始

### 0) 准备字体（可选，推荐）

中文字体有版权、不入库。若本机已装任意 CJK 字体（Windows / macOS 自带即满足）可跳过。
Linux 服务器建议放开源或正版字体到 `wallpaper_service/fonts/`，详见 [`fonts/README.md`](wallpaper_service/fonts/README.md)。

### 1) 本地起服务

```bash
cd wallpaper_service
pip install -r requirements.txt
python app.py --port 8000
# 另开终端验证：
curl "http://127.0.0.1:8000/wallpaper?theme=weather&city=上海&unit=C" -o lunar.png   # 黄历版
curl -X POST --data-binary @cover.jpg -H "Content-Type: image/jpeg" \
     "http://127.0.0.1:8000/wallpaper?theme=weather&city=上海" -o cover.png        # 封面版
```

> 不开服务也能直接出图（联网取真实数据，适合预览 / CI）：

```bash
python make_wallpaper.py --city 上海 --unit C --out preview.png      # 黄历版
python make_wallpaper.py --city 上海 --cover cover.jpg --out c.png   # 封面版
python make_wallpaper.py --lat 31.23 --lon 121.47 --no-lunar         # 任意坐标、纯天气
```

### 2) 部署到公网（可选，供 Kindle 远程使用）

任意能跑 Python 的 PaaS（Render / Railway / Fly.io 等）或 VPS + nginx 反代均可：
上传 `wallpaper_service/` 整目录，声明启动命令 `python app.py`、监听环境变量 `PORT`。
成功后你会得到一个公网地址，例如 `https://your-host.example`。

### 3) Kindle / KOReader 安装插件

1. **改服务地址**：编辑 `koplugin/Weatherdash.koplugin/main.lua` 顶部常量：

   ```lua
   local SERVICE_BASE = "https://your-host.example/wallpaper?theme=weather"  -- ← 改成你的地址
   ```

2. 把 `Weatherdash.koplugin` 整个目录拷到 Kindle：

   ```
   /mnt/us/koreader/plugins/Weatherdash.koplugin/
   ```

3. **彻底重启** KOReader（不是插件管理页刷新）。
4. 主页菜单 → **更多工具 → 天气壁纸**，点「应用黄历天气壁纸」；
   让 Kindle 休眠即可看到壁纸。
5. 若屏保不显示：KOReader → 设置 → 屏保 → 来源选"图片"，目录指向写入路径
   （默认 `koreader/screensaver/`，文件名 `dashwallpaper.png`）。

> ⚠️ **MiuRead 等定制版 KOReader 用户必读**：本插件类已带 `is_doc_only = false`，
> 若从插件管理页可见但菜单找不到入口，请确认插件已勾选 ☑ 且**完全重启**了 KOReader。

## API

基地址：`/wallpaper`（或便捷路径 `/weather`）

| 方法 | 路径/参数 | 说明 |
|---|---|---|
| GET | `/wallpaper?theme=weather&city=上海&unit=C` | 黄历天气壁纸 PNG（默认主题，theme 可省略） |
| GET | `/weather?lat=31.23&lon=121.47&unit=F` | 便捷路径；lat/lon 优先于 city |
| POST | `/wallpaper?theme=weather&city=上海`（body=封面图字节） | 天气+书封合成 PNG（**每次重新拉最新天气，无缓存**） |
| GET | `/where?city=上海&unit=C` | 该城市天气 JSON（调试用） |
| GET | `/` | 服务说明 |

参数：

| 参数 | 说明 | 默认 |
|---|---|---|
| `city` | 中文/英文城市名（内置 90+ 坐标，未知城市自动 geocoding） | 上海 |
| `lat` / `lon` | 直接指定坐标（优先于 city） | — |
| `unit` | `C` / `F` | `C` |
| `theme` | 目前仅 `weather`；`THEMES` 扩展点见下 | `weather` |

## 自定义

- **分辨率**：`make_wallpaper.py` 顶部 `TARGET_W / TARGET_H`。
- **字型**：天气壁纸默认楷体（`kai=True`），找不到回退黑体。改 `_load_font(size, kai=...)`。
- **城市表**：`app.py` 的 `_CITY_RAW` 追加 `("城市名","English",lat,lon)` 即可；不追加也能靠 geocoding。
- **扩展列表式主题**：`app.py` 顶部 `THEMES` 注释里有完整模板（加一个"看板"类主题只需填
  `title/sections_url/bundled/fallback`，渲染自动走 `render_sections`）。
- **每日自动更新时段**：插件 `main.lua` 里 `AUTO_HOURS`。

## 常见问题

| 现象 | 处理 |
|---|---|
| 壁纸出方块/空白 | 服务端缺 CJK 字体 → 看 `fonts/README.md` |
| 下载提示"云端未生成" | 先 curl 你的服务地址确认返回 PNG；检查 city 参数编码 |
| 封面模式报"未能提取封面" | 该书无内嵌封面缓存；改用「应用黄历天气壁纸」 |
| 插件可见但菜单无入口 | 确认 ☑ 勾选 + 完全重启；检查是否 MiuRead 版需要 `is_doc_only=false`（本插件已内置） |
| 想用官方原版 KOReader | 本插件基于官方插件 API，通用 KOReader 亦可使用（仅封面提取用到 bookinfo API，适配多级回退） |

## 数据源与致谢

- 天气：[open-meteo.com](https://open-meteo.com)（CC BY 4.0，免费无 Key）
- IP 定位：[ip-api.com](https://ip-api.com)（免费非商用；本服务仅在 `我的位置→IP 自动定位` 时调用）
- 黄历：[cnlunar](https://pypi.org/project/cnlunar/)（MIT）
- 插件机制与屏保：KOReader 官方 `coverimage.koplugin` 的思路（封面编码走 Blitbuffer 安全路径）

## License

[MIT](LICENSE)。注意：仓库**不包含**中文字体文件，请自行准备可合法分发的字体。
