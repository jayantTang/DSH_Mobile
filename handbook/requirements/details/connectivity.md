# 连接细节

## SR-01.01 开放登记

- 开放登记 `POST /agents/enroll`；同一来源每小时最多 5 次，超限返回 `enroll/rate-limited`。
- 带 `inviteCode` 的请求走历史兼容路径，新用户不经过。
- 运营侧可用 `dsh-relay admin agent-register` 预置或轮换身份。

## SR-01.03 扫码配对

- 中转只存配对码哈希；连接器把持久码记在 `~/.dsh/mobile-link/pair-code.json`（0600）。
- 面板复用同一张码；点「重新生成」才换码；换码不作废已配对设备。
- 旧浏览器页面 `GET /mobile-link/qr` 已删除。

## SR-01.05 设备列表与撤销

- `GET /devices` 返回含离线设备的全量列表；App 设置页与连接器面板都可撤销。
- 设备令牌长期有效，随 `/pair/refresh` 轮换。

## SR-01.06 仅经公网中转

- App 连接页只保留中转配对；`dsh://direct` 仅 DEBUG 参数。

## SR-01.10 账户设备上限

- 一个账户最多 8 台已配对客户端（iOS 与 Web 合计）；到顶时先撤销一台再配对。
