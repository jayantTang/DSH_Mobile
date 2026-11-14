# 连接细节

## 1.1.1 登记

- 开放登记 `POST /agents/enroll`；同一来源每小时最多 5 次，超限返回 `enroll/rate-limited`。
- 带 `inviteCode` 的请求走历史兼容路径，新用户不经过。
- 运营侧可用 `dsh-relay admin agent-register` 预置或轮换身份。

## 1.2.1 配对码

- 中转只存配对码哈希；连接器把持久码记在 `~/.dsh/mobile-link/pair-code.json`（0600）。
- 面板复用同一张码；点「重新生成」才换码；换码不作废已配对设备。
- 旧浏览器页面 `GET /mobile-link/qr` 已删除。

## 1.3.1 设备

- `GET /devices` 返回含离线设备的全量列表；App 设置页与连接器面板都可撤销。
- 设备令牌长期有效，随 `/pair/refresh` 轮换。

## 1.4.1 直连

- App 连接页只保留中转配对；`dsh://direct` 仅 DEBUG 参数。
