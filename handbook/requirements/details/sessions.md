# 会话细节

## SR-02.03 待答提醒与作答

- 已知限制：提问发生时手机未连接，这条提问无法补送；host 侧 pending 随 Agent Context 释放被撤销，App 侧无补救。
- 根因与排查见 `handbook/history/待答丢失根因.md`。
- 诊断日志：`HostEventHub` 的 `hub.ready`、`hub.waterfall`、`hub.cancelled`；启动带 `-DSHViewportProbe` 才落盘。

## SR-02.08 运行结束与待答通知

- App 存活时投递本地通知；手机不在线时由中转发送 APNs，推送里只有会话 id。
- 电脑端新开始的会话无法唤起 App；长时间未答的提问可能丢失。
- 「运行结束时提醒」与「需要确认时提醒」可分别关闭。
