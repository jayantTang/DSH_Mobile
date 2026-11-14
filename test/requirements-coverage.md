# 需求覆盖矩阵

> 面向：实现者 · 状态：IR-08 初版

机器校验：`node test/check-coverage.mjs`。表里的每个路径必须存在；`partial` 表示已有证据但还不足以判定该 SR 完全满足。

| SR | 状态 | 证据 | 缺口 |
|---|---|---|---|
| SR-08.01 重连与消息一致性 | covered | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelDisruptionTests.swift`、`ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelQueueTests.swift`、`ios/DSHMobile/DSHKit/Tests/DSHKitTests/LinkCarrierSocketLifecycleTests.swift`、`test/acceptance/07-relay-reconnect.md` | 已跑模拟器断链恢复；真机断网未单独注入 |
| SR-08.02 文件完整性 | covered | `ios/DSHMobile/DSHKit/Tests/DSHKitTests/RelayFileTransferTests.swift`、`ios/DSHMobile/DSHKit/Tests/DSHKitTests/WorkspaceFileCacheTests.swift` | 无 30 次真机大文件续传 |
| SR-08.03 撤销生效 | covered | `relay-go/internal/wsapi/wsapi_test.go` | 无反向验证其他设备不受影响 |
| SR-08.04 密钥与内容边界 | covered | `scripts/dev/check-diagnostics.test.mjs`、`relay-go/internal/hub/opacity_test.go`、`relay-go/internal/hub/debugconns_test.go`、`scripts/verify/check-relay-tls.mjs` | 明文拒绝由 Caddy/TLS 承担，未做自动化端口测试 |
| SR-08.05 关键路径性能基线 | covered | `ios/DSHMobile/DSHMobileUITests/PerformanceBaselineTests.swift`、`test/PERFORMANCE.md`、`test/check-performance.mjs` | 发送指标止于本地消息现身，不含服务端确认 |
| SR-08.06 通知语义 | covered | `ios/DSHMobile/DSHMobileTests/SessionAlertsTests.swift`、`relay-go/internal/wsapi/wsapi_test.go`、`relay-go/internal/push/push_test.go`、`scripts/verify/check-apns.mjs` | 真实 APNs 已由 relay 的 push-test 验证（status 200）；离线只允许丢失，不承诺必达 |

## 维护规则

- 新 SR 先在此表登记证据，再补测试。
- `partial` 不能当成“已覆盖”；补完证据后改为 `covered` 并写明测试命令。
- 测试删除或改名时同步更新本表，`check:coverage` 会因路径不存在而失败。
