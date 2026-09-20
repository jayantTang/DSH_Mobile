# 术语表

> 面向：使用者与实现者 · 状态：stable · 最近核对：2026-09-20

一个概念只用一个词。文档、代码注释与界面文案以此表为准。

| 术语 | 英文 / 标识 | 含义 |
|---|---|---|
| DSH | DeepSeek Harness | 在电脑上运行 agent 的宿主程序；本仓库是它的移动端 |
| host | DSH host | 一台运行 `dsh web` 的电脑，会话与工具的真实执行方 |
| 连接器 | connector / `dsh-plugin-mobile-link` | 电脑侧的 DSH 插件，向中转建立 WSS 并把请求转给本机 DSH |
| 中转 | relay / DLP | 公网主机上的转发服务，按 `agentId` 转发帧，不解析会话内容 |
| DLP | DSH Link Protocol v1 | 手机、中转与连接器之间的帧协议，见 `RELAY-PROTOCOL.md` |
| agentId | `agt_…` | 一台电脑在中转上的身份标识，配对与转发都以它为准 |
| 设备令牌 | device token | 配对后发给单台手机凭据，可在 App 内撤销 |
| 邀请码 | invite | 一次性、绑定单台电脑的登记凭据，用于把连接器登记到中转 |
| 配对 | pairing | 手机扫描电脑上的二维码、取得设备令牌的过程 |
| 会话 | session / `session-…` | DSH 里的一段对话；有工作目录、消息流与投影 |
| 投影 | projection | 宿主随会话下发的派生状态（标题、权限、上下文占用等） |
| 工作区 | workspace | DSH 登记的项目目录；会话按其工作目录归入工作区分组 |
| 子代理 | subagent | 由某个会话派生的独立会话，用于并行子任务 |
| 转写 | transcript | 会话的完整消息序列，即 App 的会话页面内容 |
