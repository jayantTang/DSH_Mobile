# 会话细节

## 2.2.1 待答

- 已知限制：提问发生时手机未连接，这条提问无法补送；host 侧 pending 随 Agent Context 释放被撤销，App 侧无补救。
- 根因与排查见 `handbook/history/待答丢失根因.md`。
- 诊断日志：`HostEventHub` 的 `hub.ready`、`hub.waterfall`、`hub.cancelled`；启动带 `-DSHViewportProbe` 才落盘。
