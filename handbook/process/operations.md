# 日常操作

## 日报

日报只通过消息通道投递到 owner 收件箱（owner 2026-10-12 要求）。

- 用户说「发一份日报」即执行投递，不粘贴截图。按用户所指日期选择参数（owner 2026-10-14 要求）：「今天」→ `--date today`；「昨天」或「复盘刚结束的一天」→ `--date yesterday`（`--full-day` 是其简写）；指定某天 → `--date YYYY-MM-DD`。未指定日期时取用户当句所指日期，不要默认套用 `--full-day`，它表示昨天。
- 完整命令：`node scripts/dev/feedback.mjs report --days 30 <日期参数> --send`。收件账号取 `.env.local` 的 `DSH_ACCOUNT_ID`。定时任务见 `~/Library/LaunchAgents/com.jayanttang.dsh-daily-report.plist`，每天 00:02 汇报刚结束的一天，使用 `--full-day`。
- `--device` 已删除。传入它会报未知参数错误，不要将其理解为用法错误而改走群发。
- 报告文件名与通知标题取覆盖日（服务器 `today.day`，旧服务端用 `--date` 兜底）。
- 返回 `noticeId` 才算发送成功；会话中最多附一句结论。

## 对外发信审批

发给其他用户的信件必须先经 owner 审批（owner 2026-10-13 要求，强制；「信箱」指反馈通道）。

- 范围：`dsh-relay admin feedback-reply`（回信）、`feedback-notify`（通知），以及本机包装 `node scripts/dev/feedback.mjs reply|notify`、`report --send`；发给其他用户的邮件同理。删除线程（`feedback-delete`）不在审批范围内，owner 2026-10-13 决定只管发信，删除仍只依赖 `--yes`。
- 判定与流程：收件人中有任何一个不是 owner 本人（owner 账号为 `.env.local` 的 `DSH_ACCOUNT_ID`）时，先拟草稿并把全文与收件名单交给 owner；owner 明确同意后，发送时带 `--owner-approved "<owner 的原话>"`（`reply` / `notify` / `report --send` 均使用该开关）。不带该开关会被拒发（退出码 2）；获批的发送会在 `~/Library/Logs/dsh-feedback-approvals.log` 留一条 JSON 记录。
- 仅投递给 owner 自己账号的日报与自测不受此限，也不用带开关；预演（不带 `--yes` / `--send`，或带 `--dry-run`）随时可执行。
- 未经审批发出视为违规；收件人不确定时先询问，不得猜测。
- 发件存档（owner 2026-10-15 要求）：所有发给用户的信件（`reply` 回信、`notify` 单发或群发、`report --send` 给其他账号）发出后，必须同时在 owner 账号（`.env.local` 的 `DSH_ACCOUNT_ID`）的信件列表中保留一份存档，注明发送对象与发送人（owner 手发或系统代发）。`feedback.mjs` 已内置自动投递：发送成功后自动补一条「发件存档」通知，包含信件全文；仅发给 owner 自己的不存档。绕过包装脚本直接运行 `dsh-relay admin` 发信时，需手动补一份（`node scripts/dev/feedback.mjs notify --account <owner账号> --yes`）。存档收件人是 owner 本人，不需要再审批。

## 调试设备清理

调试配对的设备不得残留（2026-09-21 要求）。

- 为调试而配对的设备（用例、探针、手工跨设备检查）执行完后必须撤销；名称一律以 `DSH-` 开头（`DSH-Test` / `DSH-Probe` / `DSH-Sweep` 等），真实设备不使用该前缀。
- relay 通道用例的运行器会先执行 `sweep` 再配对，并在 `finally` 中撤销本次配对（`test/tools/run.mjs` + `scripts/dev/relay-devices.mjs`）。手工配对后，收尾执行一次 `node scripts/dev/relay-devices.mjs list`，列表中应只剩真实 iPhone。
- 存在残留时执行 `node scripts/dev/relay-devices.mjs sweep`，先加 `--dry-run` 确认将撤销哪些设备。
