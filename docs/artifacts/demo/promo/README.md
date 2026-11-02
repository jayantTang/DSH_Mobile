# README 动图生成工程

产出仓库首屏那张 20 秒的演示动图（`../dsh-mobile-demo.gif`）与同名 MP4。

开头是桌面 DSH：打开左下角「移动端连接」→ 点「登记」→ 面板出现二维码；左侧三条标注依次出现并停留。
随后手机从画面外靠近窗口里的二维码，扫码成功后桌面窗口退场，只剩手机，再走会话、文件、git 改动与提交历史。

画面**不是录屏**：手机界面按 `DSHTheme` 的 token 在 HTML/CSS 里重绘，这样才能精确控制
打字、下载进度、扫码框与镜头推进。

## 依赖

- Node.js ≥ 22，Playwright（`npm install` 后再 `npx playwright install chromium`）。
- `ffmpeg`、`gifsicle`（`brew install ffmpeg gifsicle`）。
- 字体用系统自带 PingFang SC 与 SF Pro；非 macOS 环境中文会回退，需要自备等价字体。

## 生成

```bash
npm install && npx playwright install chromium
node render.mjs --fps 24          # → frames/f00000.png …（2560×1600）
./encode.sh                       # → out/dsh-mobile-demo.gif / .mp4 / poster.jpg
cp out/dsh-mobile-demo.gif out/dsh-mobile-demo.mp4 ../
```

`render.mjs` 可加 `--times 1.0,3.4` 只出静帧，`--scale 1` 出半尺寸。若本机 Playwright
找不到浏览器，用 `CHROMIUM_PATH=<可执行文件> node render.mjs` 指过去。

## 结构

| 文件 | 作用 |
|---|---|
| `index.html` | 画布、桌面 DSH 窗口、连接器面板图、手机外框、App 页面与左侧文案 |
| `styles.css` | 设计 token（品牌蓝 `#4D6BFE`、暗底 `#07080C`）、手机与页面样式 |
| `scene.js` | 时间轴：`window.seek(t)` 是纯函数，任意时刻可复现；镜头关键帧在 `CAM`，手机节奏在 `WARP` |
| `render.mjs` | Playwright 逐帧截图 |
| `encode.sh` | ffmpeg 出 MP4、调色板 GIF，gifsicle 压到 7 MB 内 |
| `assets/panel-unreg.png` | 连接器面板「未登记」态的 1:1 渲染图（取自最新设计稿，未改布局与比例） |
| `assets/panel-reg.png` | 连接器面板「已登记」态的 1:1 渲染图；二维码已替换为 TestFlight 链接 |
| `assets/qr.png` | 指向 TestFlight 公开链接的二维码（`tools/make-qr.py` 可重生成） |
| `assets/app-icon.png` | 取自主 App 的 `AppIcon.appiconset/icon-1024.png` |

## 修改约定

- 文案在 `index.html`，节奏在 `scene.js` 的 `seek()`；改时间点时要同步改 `CAM`，否则镜头
  会对不上内容。
- 桌面段用绝对时间 `t`，手机段用 `tp`（由 `WARP` 压进后半段）；改手机节奏只动 `WARP`。
- 手机接近二维码的那段是 `#float` 的世界变换（约 4.2–7.4 秒），期间相机不参与；落位后才交给 `CAM`。
- 提交历史是文件页的第三个分页（`#paneHistory`）；分段控件位置 `pos` 由浏览→变更、变更→历史两段组成。
- 三条标注在 `#actAnnots`，时间点写在 `seek()` 的 `E.annots` 循环里；窗口在 6.7 秒后才退场。
- 连接器面板不是 HTML 重绘，而是 `assets/panel-*.png` 两张 1:1 渲染图：登记后从 241px 长到 509px，
  布局与比例跟设计稿一致；只有二维码内容被替换。
- 镜头推进用 `fx`/`fy`（屏幕内焦点，0–1）与 `ax`/`ay`（画布锚点）描述，缩放为 `z`。
- **不要给静止段加持续位移**（呼吸浮动、背景漂移）：GIF 会退化成整帧更新，体积翻倍。
- 数据沿用合成会话：`dsh-mobile-demo`、`export-2026-10.csv`、9 处 git 改动；不要换成真实项目。
- 产出上限：GIF ≤ 7 MB、960×600、12 fps；超了先降分辨率，再降帧率，最后才减时长。

重新生成二维码：

```bash
python3 -m pip install "qrcode[pil]"
python3 tools/make-qr.py
```
