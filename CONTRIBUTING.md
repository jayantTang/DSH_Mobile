# 参与开发

**English** · [中文](#中文) — Contributing (English)

We take patches, issues and case reports. The short version:

1. Open an issue first for anything larger than a typo — it saves a rewrite.
2. Run the checks before pushing: `npm test`, `npm run check:docs`, `npm run check:secrets`,
   plus `swift test` under `ios/DSHMobile/DSHKit` and `pytest` under `relay/`.
3. Behaviour changes come with a case (see `test/README.md`) and a report; UI changes come with a
   simulator screenshot.
4. Commit messages are written in Chinese in this repository — that is a convention, not a rule
   about who may contribute.

The Chinese section below has the same rules in more detail.

---
本仓库包含四部分：iOS App（SwiftUI）、协议层 Swift Package、电脑侧连接器（DSH 插件，Node ESM）
与公网中转（Python）。改动任一处的流程一致：本地测试 → 文档同步 → 提交。

## 环境

| 组件 | 需要 |
|---|---|
| `ios/DSHMobile/DSHKit` | macOS + Swift 工具链（`swift test` 可直接跑，无 UI 依赖） |
| `ios/DSHMobile/DSHMobile` | macOS + Xcode 16 以上 + 一个 iOS 17 以上的仿真器 |
| `plugins/*` | Node.js ≥ 22 |
| `relay/` | Python 3.12 |

## 测试

```bash
cd ios/DSHMobile/DSHKit && swift test        # 协议层
cd plugins/mobile-link  && npm test          # 连接器
cd plugins/send-image   && npm test
cd plugins/doubao-image && npm test
cd relay && .venv/bin/python -m pytest -q    # 中转
npm run check:secrets                        # 跟踪文件里没有本机真值
npm run check:docs                           # 文档结构、口吻与链接
```

单测通过不构成发布许可。涉及 App 界面、连接链路或中转行为的改动，必须在仿真器或真机上按
[`test/RULES.md`](test/RULES.md) 跑对应用例并出报告；CI 只覆盖「干净机器上无配置也能跑」的部分。

## 提交

- 提交信息用中文，写清**为什么**改；一次提交只做一件事。
- 改动 iOS 侧后需在仿真器实跑并截图确认，再考虑发布。
- 不得把本机真值写入跟踪文件：中转地址、连接器身份、App Store 凭据、开发者团队 ID 一律只存在于
  `.env.local`、`~/.dsh/` 或 `*.local.*`（均已 gitignore）。`npm run check:secrets` 会拦截。
- 发布产物（App 归档、OTA 目录、TestFlight 构建）由维护者按 [`docs/VERSIONING.md`](docs/VERSIONING.md)
  的流程产出，不接受来自 fork 的发布。

## 文档

- 面向使用者的文档在 `docs/`，面向维护者的记录不随仓库发布。
- 参考类文档用无人称陈述句；操作步骤用祈使句。同一概念只用一个词，术语见
  [`docs/GLOSSARY.md`](docs/GLOSSARY.md)。
- 新增文档需要包含一行读者与状态说明，格式见现有 `docs/*.md` 开头；`npm run check:docs` 会校验。
