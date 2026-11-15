# AGENTS.md — 开发入口

> DSH 常驻加载本文件。完整规范在 `handbook/`，本文件只放红线、路由与最常用命令。

## 红线

1. 不得使用 owner 的现有会话做输入测试。临时会话用 `DSH-` 前缀，执行完用 `dsh-probe cleanup` 删除。
2. 不得运行全量测试。日常只跑受影响靶向用例；发布门禁按 `handbook/process/quality.md` 执行。
3. 不得向用户暴露 OTA 地址与安装页。面向用户的升级指引只写 TestFlight。
4. 对外发信前先审批。收件人含任何一个非 owner 时，先拟全文与名单交 owner，明确同意后才发。
5. 修复问题不得打补丁。先定状态归属，禁止用特例、开关、缓存或多条通路绕过症状。
6. iOS 改动必须先在仿真器实跑并截图确认后才发布；视觉改动逐屏核对。
7. 不得删除或改写 `~/.dsh/` 下的真实会话；单测、一次性探针与故障注入脚本一律把 `DSH_HOME` 指向临时目录，不得用真实身份；本机连接器刷新工具只允许写 `mobile-link/rollback/` 快照。
8. 需求关键层变更先跑 `npm run review:requirements`，冲突自己修；只把通过自审的变更交 owner。owner 同意后用 `npm run approve:requirements` 记录；pre-commit 缺记录会拒绝提交。
9. 任何产品功能或行为的修改、新增诉求，先做需求影响审查：与现有需求冲突时交 owner 决策；需求空白时先补需求并审批；需求门槛通过后才改实现。实现与需求不一致时停止并汇报，不得自行放宽。
10. 中转、连接器 npm、iOS TestFlight/App Store 与公共服务配置对外发布前，先经 owner 明确同意；中转刷新必须走 `scripts/release/deploy-relay.sh` 的冒烟、留档、备份与失败自动回滚，不得手工裸替换。

## 路由

| 任务 | 先读 |
|---|---|
| 任何修改或新增诉求 | 先按 `handbook/process/workflow.md` 做需求影响审查；冲突交 owner，空白先补需求 |
| 改用户可见功能 | `handbook/requirements/requirements.md` 对应条目、`handbook/requirements/details/` |
| 设计、实现、验证流程 | `handbook/process/workflow.md` |
| 测试、门禁、完成判定 | `handbook/process/quality.md` |
| 发布、tag、部署、TestFlight | `handbook/process/release.md` |
| 日报、信件、设备清理 | `handbook/process/operations.md` |
| 架构、双宿主、修改原则 | `handbook/engineering/architecture.md` |
| 环境、重启、热更 | `handbook/engineering/environment.md` |
| 仓库约定、本地化 | `handbook/engineering/conventions.md` |
| 完整命令 | `handbook/engineering/commands.md` |

## 常用命令

```bash
python3 scripts/targeted_tests.py --staged
npm run check:lanes -- --changed <file>
cd ios/DSHMobile && xcodebuild -scheme DSHMobile \
  -destination 'platform=iOS Simulator,name=DSH-Test' build
./scripts/dev/verify-simulator.sh
npm run restart -- --resume "继续…"
./scripts/release/deploy-ota.sh
./scripts/release/deploy-relay.sh --version go-X.Y.Z
./scripts/release/deploy-testflight.sh
```

## 本机与历史

- 本机凭据与路径：`AGENTS.local.md`（本机覆盖，不入库）。
- 历史记录：`handbook/history/`（不入库，不作规范来源）。
- 需求关键层变更需 owner 逐条确认后落盘。
