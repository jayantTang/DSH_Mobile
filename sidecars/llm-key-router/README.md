# llm-key-router —— 本机多 key 轮换代理

一把上游 key 会限流、会配额用尽，多把 key 又会把上游的 prompt 缓存打散。这个代理同时解决两件事：

- **同一个会话永远用同一把 key**（会话粘性）——上游的缓存是按账号算的，逐请求轮换等于每轮重算前缀；
- **只在必要时换 key**（失败才换、冷却、判死），换的时候客户端与手机端**看不见**。

链路：

```
DSH 会话 → dsh-llm-pi-ai(route: 公司网关) → http://127.0.0.1:8799/v1 → 上游网关（N 把 key）
```

## 会话身份从哪来

优先 `session_id` / `x-session-affinity` / `x-client-request-id` / `x-session-id` 头
（pi-ai 的 `compat.sendSessionAffinityHeaders` 会带，但该开关对自定义 route 是 withhold 的，
只有 pi-ai 自带目录里的厂商能开）。

都没有时退回**前缀指纹**：`md5(第一条 user 消息)`。只用第一条 user 消息是踩出来的：

- 带上 system 提示不行——DSH 的系统提示每轮都变（待处理项、时间、工具清单），指纹跟着变；
- 带上 model 也不行——会话中途换模型不该打断粘性。

代价：开头一模一样的两个会话共用一把 key。那只是共用，不影响正确性。

## 选键与换键

| 情况 | 行为 | 缓存代价 |
| --- | --- | --- |
| 会话有粘性且那把 key 可用 | 用它 | 0（前缀缓存持续命中） |
| 新会话 | 健康 key 轮转分摊 | 无（本来就没缓存） |
| 429 / 配额 | 该 key 冷却（`Retry-After` 优先），**整个会话**迁移 | 一次全量重算 |
| 5xx / 网络错 | 同一把先重试一次，仍失败才迁 | 尽量不丢 |
| 401 / 403 | 判死（上游停用的 key 会在首用时被标掉，如 `Consumer is forbidden.`） | — |
| 流式已开始输出 | 不换 key 重放，错误透给 DSH 的重试策略 | — |

请求体一个字不改、SSE 逐块透传：前缀只要差一个字节，上游缓存就作废。

## 用法

一个人用的一套（公司网关 + 多把 key）就长这样；这套配置只属于本机，
和 DSH Mobile 这个产品无关：App 不认识它，别的用户也不需要它。

```bash
# 1. 配置：~/.dsh/llm-key-router/config.json（照 config.example.json 抄）
# 2. 导入 key（一行一把，可「标签:key」；只写入本机 600 文件）
node scripts/dev/llm-router-setup.mjs keys ~/path/to/keys.txt
# 3. 起代理（前台）
node sidecars/llm-key-router/bin/llm-key-router.mjs start
# 4. 接到 DSH 上（写凭据 + 建 pi-ai route，模型清单从代理的 /v1/models 抓）
node scripts/dev/llm-router-setup.mjs wire
# 5. 常驻（开机自起、掉线自拉）
node scripts/dev/llm-router-setup.mjs agent install
# 看状态
node scripts/dev/llm-router-setup.mjs status
```

`status` 会给出每把 key 的状态、会话粘性命中/迁移次数、以及缓存命中 token ——
"多 key 有没有把缓存毁掉"这件事只认这个数字。

## 测试

```bash
cd sidecars/llm-key-router && npm test        # 12 项：粘性、分摊、冷却、判死、迁移、指纹
```
