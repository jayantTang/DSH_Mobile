---
name: send-image
description: 把图片送进当前会话发给用户看——截取屏幕、抓剪贴板里的图、或发送指定的图片文件。图片会经 Host 归一化后持久化，并作为**本次回答的工具结果**显示在用户的 DSH 客户端（含 iOS 手机端）里，用户可点开放大。适用于"把结果截图给我看""这个图发我""截个屏"这类要求。
whenToUse: 当用户要看某个视觉结果时使用——界面长什么样、图表/渲染效果、报错弹窗、设计稿对比、需要目视确认的中间产物；或用户明确说"发图给我""截图给我""这张图发过来"。也适用于你自己想用图片汇报而不是用文字描述的场景。
---

# 发送图片到会话

**核心能力**：把一张图片放进对话，用户在他的 DSH 客户端里**直接看到图**，可点开放大。

## 怎么发（首选）

**用 `send_image` 工具**（`plugins/send-image` 提供）：

```
send_image(file: "/tmp/render.png", caption: "渲染结果")
send_image(screenshot: true, caption: "当前界面")
send_image(clipboard: true)
```

图片会走 Host 的附件服务归一化并持久化，然后作为**这次工具调用的结果**画在会话里——
也就是出现在你自己这轮回答的卡片内。它**不是**一条用户消息，也不会触发新一轮回答。

## 为什么不能把它当 prompt 发

模型的输出是纯文本的，图片确实没法直接写在回答里；但这不等于"只能当 prompt 发"。
Host 的附件服务**可写**（`ctx.attachments.saveImage`），而工具结果可以携带图片内容块，
所有客户端（Web / iOS）都会在工具卡片里把它画出来。

旧做法是调用 `send-image.mjs` 把图片作为 `session/prompt` 提交，代价有两个，而且都很实在：

- 它以**用户消息**的身份出现，用户会以为是自己发的；
- 它会**开启新一轮回答**——你发出去的截图会把你自己再叫醒一次，等于自问自答。

所以那条路只在客户端渲染不了工具结果图片时才用（见下）。

## 脚本（`send-image.mjs`）的定位

脚本仍然负责**采集与校验**：`screencapture` / `pngpaste` 的坑、屏幕录制权限的提示、
格式与大小检查都写在它里面；`send_image` 工具会调用它、拿到一行 JSON 描述符
（`{path, name, mediaType, bytes, temporary}`），再自己去做附件与渲染。

```bash
S=~/.dsh/skills/send-image/send-image.mjs
node $S --file ~/Desktop/chart.png     # 只准备，打印 JSON 描述符，不进会话
node $S --screenshot                   # 同上（截图）
node $S --clipboard                    # 同上（剪贴板）
```

**兜底路径**（不推荐，只在客户端画不了工具结果图片时）：`--via-prompt` 会把图片作为
prompt 直接提交，需要 `$DSH_SESSION_ID`，并且会以用户消息的身份出现、触发新一轮回答。

## 什么时候用它

| 场景 | 做法 |
|---|---|
| 用户要看界面/渲染效果 | `send_image(file: <截图或产物路径>)` |
| 用户要"看一下现在屏幕" | `send_image(screenshot: true)` |
| 系统弹窗/报错需要目视确认 | 先把窗口切到前台，再 `send_image(screenshot: true)` |
| 用户给了图要你转发 | `send_image(file: <他给的路径>)` |

## 关键约定

- **先确认图片存在且非空**：脚本会拒绝空文件和超过 20 MB 的文件。命令返回非零时不要假装成功。
- **发送后要说明**：`caption` 写清这是什么，不要让用户猜。
- **不要滥用**：能用文字说清的就别发图。发图是为了让用户**目视确认**，不是替代文字结论。
- **截图会包含屏幕上的一切**：发送前想一想画面上有没有不该发的私密内容。
- **图片是异步到达的**：发出去不等于用户已经看过，他可能不在电脑前。

## 依赖

- `screencapture`（macOS 自带）
- `pngpaste`（仅剪贴板需要）：`brew install pngpaste`
- 屏幕录制授权（仅截图需要）：macOS 把它给**应用**，不是给脚本。
  若报 `could not create image from display`，是 DSH.app 没拿到授权 —— 在
  「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 DSH，然后**退出并重新打开 DSH.app**。
