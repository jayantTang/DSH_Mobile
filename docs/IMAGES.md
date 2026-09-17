# 图片能力

让 agent 能把图片送进对话、让用户在客户端（含 iOS）里看到并放大查看。

## 为什么是这样实现的

三条硬约束决定了设计，任何一条都不容绕过：

**1. 模型适配器是纯文本的。** 协议里 `ImageBlock` 对 user 和 assistant 内容都合法，
但注释写得很明确：

> assistant-side rendering is **forward compatibility** — the current production
> adapters declare **text-only output**, so only user messages may carry images.

也就是说 agent **无法自己输出图片**。`ImageBlock` 在 assistant 侧可用只是为将来留的口子。

**2. 附件服务是只读的。** 客户端只有 `session/attachment`（按 id 读字节），
**没有任何写入或注册端点**。谁都不能直接往附件库里塞图。

**3. 图片进入会话的唯一通道是 prompt。** `PromptContentPart` 允许内联图片：

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

## 客户端（iOS）

| 组件 | 职责 |
|---|---|
| `AttachmentImages` | 按 `attachmentId` 拉字节、解码、LRU 缓存（24 张）、飞行中去重、失败不重试 |
| `AttachmentThumbnail` | 按原图宽高比占位（避免加载完成时布局跳动），最长边限高 |
| `ImagePreview` | 全屏查看：捏合缩放 1–6x、双击 2.5x、拖拽平移、保存到相册 |

**含图片的工具卡片默认展开**——截图是那条消息的重点，藏在折叠面板后面等于没有。

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

**安装**：

```bash
./scripts/install/install-plugin.sh              # 注册 plugins/ 下的全部插件
./scripts/install/install-plugin.sh plugins/send-image   # 或只装一个
# 重启 DSH 后生效
```

脚本同时写**依赖链接**与 `dsh.profile.bundles`——两者必须一致：
只链接不登记会安装成功却永不加载，且不报错。
登记前脚本会先检查插件的 `dsh.bundle.patch` 与 `cordis.patch.yml` 是否存在：
缺了还登记会使**每次启动都报错退出**（连 DSH.app 一起打不开），所以宁可装不上。

**测试**：

```bash
cd plugins/send-image && npm test   # 11 个用例
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
- **`--screenshot` 需要屏幕录制授权，而且授权归 DSH.app**（不是脚本、不是 node）。
  macOS 只把新授权交给重新启动后的进程，所以「勾选 → 重开 DSH.app」缺一不可；
  app 用 ad-hoc 签名时授权还会随每次重建失效，构建脚本改成证书签名后才是一次性操作。
  失败时脚本会直接给出这句可执行的提示，DSH.app 菜单「DSH → 屏幕录制权限…」也能自查。
