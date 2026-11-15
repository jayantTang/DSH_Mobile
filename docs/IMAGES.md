# 图片能力

> 面向：实现者 · 状态：stable · 最近核对：2026-11-15

让 agent 能把图片送进对话、让用户在客户端（含 iOS）里看到并放大查看。

## 为什么是这样实现的

三条硬约束决定了设计，任何一条都不容绕过：

**1. 模型适配器是纯文本的。** 协议里 `ImageBlock` 对 user 和 assistant 内容都合法，
但注释写得很明确：

> assistant-side rendering is **forward compatibility** — the current production
> adapters declare **text-only output**, so only user messages may carry images.

也就是说 agent **无法自己输出图片**。`ImageBlock` 在 assistant 侧可用只是为将来留的口子。

**2. 客户端只能读图像附件。** `session/attachment` 按 id 读**归一化图像**；
没有按文件引用读回字节的 RPC。原图因此由连接器在电脑上读（它同时是 DSH 插件，
能拿到 `ctx.attachments`），不走 Host 的对外 RPC——见下面「预览与原图」。

**3. 图片进入会话的唯一通道是 prompt。** `PromptContentPart` 允许内联图片，
或引用一次已上传的 receipt（`{type:'file', receiptId}`；图像 receipt 进入消息时
就是那个图像）。连接器用后一种方式在发送前就知道预览的 `attachmentId`：

```ts
{ type: 'image', mediaType: 'image/png', data: '<base64>', name?: string }
```

Host 收到后把内联字节**提升为持久附件**，并顺带做归一化。

## 数据流

```
skill / 脚本
  │  截图 或 读取指定文件
  ▼
session/prompt  { content: [text, image(base64)] }
  │
  ▼
Host 归一化 ──── 转码（png/jpeg → webp，当更省字节时）
  │              按 maxImageDimension / maxImagePixels 降采样
  │              内容哈希去重 → attachmentId = sha256:<hex>
  ▼
会话日志：user/message（或排队时的 agent/inbox/spliced）携带 ImageBlock
  │
  ├──► 桌面客户端
  └──► 中转（DLP）──► iOS 客户端
                        │
                        ▼
              session/attachment { sessionId, attachmentId }
                        │
                        ▼
                  解码 → 缩略图 → 点开全屏查看
```

关键点：**中转传输的永远是归一化后的大小，不是源文件大小**。
发送 15.7 MB 的高熵 JPEG，实际存储和传输的是 2.8 MB。

## 预览与原图（两张附件，一份逻辑图片）

自 2026-11 起，一张会话图片最多对应**两份**附件：

| 变体 | 谁生成 | 存储 | 用途 |
|---|---|---|---|
| 预览 | Host 归一化（`fileUploads.uploadImageStream` → `attachments.saveImage`） | `ImageAttachmentRef`（内容哈希） | 列表、首次全屏、模型输入 |
| 原图（可选） | 手机/工具脚本的原始字节，**逐字节**保存（`attachments.saveFile`） | `FileAttachmentRef`（原始字节 sha256） | 用户点「查看原图/保存原图」时按需取回 |

口径：预览最长边 ≤ 2560、总像素 ≤ 4,000,000、JPEG/WebP；原图单张 ≤ 20 MB。
超过 20 MB、格式无法解码或无法安全保存时**按文件发送/下载**，绝不用预览冒充原图。

**关联登记在电脑上**：`$DSH_HOME/mobile-link/image-originals.jsonl`，一行一条
`{v, previewId, original:{attachmentId,name,bytes,mediaType}, savedAt, source}`。
键是预览的 `attachmentId`（内容哈希），所以不需要会话信息，也不需要客户端缓存：
重装 App、重新配对、换设备后，会话历史里的预览仍从 Host 取，原图仍按需取回。

连接器新增三个保留方法（`_link/`，不转发 Host）：

| 方法 | 作用 |
|---|---|
| `_link/imageCommit` | 把手机暂存的预览/原图交给 Host：预览拿 receipt，原图存 file 并登记；超限原图改为返回 file receipt |
| `_link/imageOriginal` | 按预览 id 查原图元数据：`available` / `missing` / `cleaned` / `unsupported` |
| `_link/imageOriginalChunk` | 按区间读原图字节（默认 512 KiB，上限 1 MiB），手机拼完用 sha256 校验 |

`send_image` 工具走同一份索引（`source:'tool'`）：`saveImage(预览)` + `saveFile(原图)`；
工具结果里 `attachment` 仍是预览，新增的可选 `original` 只是元数据。

## 客户端（iOS）

| 组件 | 职责 |
|---|---|
| `AttachmentImages` | 按 `attachmentId` 拉**预览**字节、解码、LRU 缓存、飞行中去重、失败不重试 |
| `AttachmentImageVariants` | 原图的元数据与分片下载状态机：按需查、按需下、sha256 校验、失败不污染预览；`missing/cleaned/unsupported` 是终态，不重试 |
| `AttachmentThumbnail` | 按宽高比占位（避免加载完成时布局跳动），最长边限高；**打开全屏时才查原图** |
| `ImagePreview` | 全屏查看：捏合缩放 1–6x、双击 2.5x、拖拽平移；有原图时显示「原图 12.3 MB」/进度/重试，保存分「保存预览」「保存原图」；相册权限未授权时提示去设置 |
| 尺寸说明 | 切到原图后底部显示「原图 4288×2848」。预览上限是 2560/400 万像素，**两者在 1 倍全屏时看起来一样清楚**，差别只在放大后出现；尺寸与字节数是"确实换了、保存的是哪一份"唯一不靠主观观感的证据 |
| 双击倍率 | 双击放大到 **1 个图像像素 = 1 个屏幕像素**（2560 宽截图在 1206 宽屏幕上约 2.12×），再双击回到全屏。固定 2.5× 会越过 1:1（上采样），看起来"放大了还是糊"；任意捏合倍率都会重采样，这是物理结果，不是原图质量问题 |
| `WorkspaceImagePreviewView` | 工作区图片：列表缩略图，全屏读**原文件**字节，提供下载/分享，不重编码 |

**含图片的工具卡片默认展开**——截图是那条消息的重点，藏在折叠面板后面等于没有。
**列表滚动不会自动拉原图**：原图请求只由全屏里的显式点按触发。

## 发送方（两种形态）

### 插件：`send_image` 工具

`plugins/send-image/` —— 注册一个**原生工具**，agent 随时可调用：

```jsonc
// 参数
{ "file": "路径", "screenshot": true, "clipboard": true, "caption": "说明" }
```

**为什么插件比 skill 更可靠**：注册的工具**永远在模型的工具列表里**；
skill 需要先被发现和加载。对于一个「用户就是要看到这张图」的能力，
稳定在场比可发现性更重要。

工具内部复用同一个脚本（`skills/send-image/send-image.mjs`），
会话 id 取自 `exec.agent.sessionId`。

### 用户自己截：窗口内 `⌥⌘S`

同一个插件（`dsh-plugin-send-image`，不额外安装）还提供**用户侧**入口：在 DSH 窗口里按 `⌥⌘S`
或点输入区左侧的截图按钮，屏幕进入拖拽选区；选完的矩形**只作为待发送附件**出现在当前会话的
输入区，发送与否由用户决定。

- 只在 DSH 窗口聚焦时生效：网页客户端半边注册的是页面内快捷键，不做系统级全局热键。
- 键位可在「设置 → 快捷键」里改；插件只是提供一个默认值。
- 取消（`Esc`）不留文件、不提示；失败（最常见是屏幕录制权限没给运行 DSH 的那个程序）会显示
  可照做的提示。
- 两种宿主（官方桌面版 / 命令行 web 版）共用同一份实现，由插件包一起发布；插件可随时启用或
  禁用，入口随插件的生命期出现与消失，不需要重启宿主或刷新页面。

**安装**：

```bash
./scripts/install/install-plugin.sh              # 注册 plugins/ 下的全部插件
./scripts/install/install-plugin.sh plugins/send-image   # 或只装一个
# 重启 DSH 后生效
```

脚本同时写**依赖链接**与 `dsh.profile.bundles`——两者必须一致：
只链接不登记会安装成功却永不加载，且不报错。
登记前脚本会先检查插件的 `dsh.bundle.patch` 与 `cordis.patch.yml` 是否存在：
缺了还登记会使**每次启动都报错退出**（连运行 DSH 的那个程序一起打不开），所以宁可装不上。

**测试**：

```bash
cd plugins/send-image && npm test   # 47 个用例（2026-10-12 实测）
```

### Skill 形态（保留）

脚本本身也能直接被 agent 通过 bash 调用，skill 文档负责告诉它何时该用。



`skills/send-image/`，安装到 `~/.dsh/skills/send-image/`：

```bash
S=~/.dsh/skills/send-image/send-image.mjs
node $S --screenshot
node $S --file ~/Desktop/chart.png --caption "渲染结果"
node $S --clipboard
```

会话由 `$DSH_SESSION_ID` 自动确定（Harness 注入给每个工具调用），无需手动传 id。

## 本机实际配置的上限

读取自 `session/list` 的 `imageLimits` 投影：

| 项 | 值 |
|---|---|
| `maxImageBytes` | 20 MB |
| `maxImagesPerMessage` | 20 |
| `maxMessageImageBytes` | 200 MB |
| `maxImagePixels` | 64 MP |
| `maxImageDimension` | 8192 |
| `mediaTypes` | png, jpeg, webp, gif |

`send-image.mjs` 的本地守卫与之对齐（20 MB）：超过上限的图，Host 会**整条 prompt 拒绝**，
用户得到的是一次失败的对话而不是可处理的信息，所以要在发送前就说清楚。

## 实测结论

| 场景 | 结果 |
|---|---|
| 内联图片 → 持久附件 | 16 KB PNG → 归一化为 3.4 KB webp |
| 大图降采样 | 4000×3000 → 1773×2364，611 KB → 165 KB |
| 高熵大图 | 2000×2000，15.7 MB 源 → 2.8 MB 附件 |
| 中转取回（233 KB） | **逐字节一致** |
| 中转取回（2.8 MB） | **逐字节一致**，1.2 秒 |
| 中转下渲染 + 放大 | UI 用例通过（`DSH_VIA_RELAY=1`） |

## 调试

```bash
# 找含图片的会话
node scripts/dev/dsh-probe.mjs pick-images

# 直接对比直连与中转的附件字节
node /tmp/relaybytes.mjs

# 查看某会话的图片块
node /tmp/durableimg.mjs
```

## 已知限制

- **agent 无法主动"画"图**：它只能调用 skill 把已有图片或截图送进会话。
  真正让模型生成图片需要适配器支持图像输出，目前协议只是预留。
- **图片以 user 角色到达**：因为唯一通道是 prompt。客户端按普通消息渲染，
  与用户自己发的图在视觉上无法区分，靠随图文字说明来源。
- **`--clipboard` 需要 `pngpaste`**（`brew install pngpaste`）。
- **`--screenshot` 需要屏幕录制授权，而且授权归运行 DSH 的那个程序**（不是脚本、不是 node）。
  macOS 只把新授权交给重新启动后的进程，所以「勾选 → 重开运行 DSH 的那个程序」缺一不可；
  app 用 ad-hoc 签名时授权还会随每次重建失效，构建脚本改成证书签名后才是一次性操作。
  失败时脚本会直接给出这句可执行的提示，官方桌面版的菜单里也能自查屏幕录制权限。
