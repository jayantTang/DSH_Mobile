# 发布

用户可见的版本策略与 TestFlight 定义见 `handbook/requirements/` 的 SR-04.01 至 SR-04.03；本文件写发布操作与工程约束。

## 打 tag 与 Release

每次对外发布（iOS 构建、连接器 npm 包、中转）完成后立即打语义化 tag：`ios-vX.Y.Z` / `mobile-link-vX.Y.Z` / `relay-vX.Y.Z`。同一次发布只打一个 tag，tag 必须指向实际构建所用提交，不得指向事后补交的提交。

同时补 GitHub Release 说明，固定四段：变更（用户可感知的改动）、影响范围（需要升级的组件与兼容性）、升级方式（命令或步骤）、已知问题（未修项与规避）。不写「若干优化」「体验提升」这类无信息量的句子。

顺序固定：打 tag → 写 Release → 通知用户安装。缺 tag 或缺 Release 的发布视为未完成。

tag 与 Release 不得出现 OTA 地址；分发策略见 `handbook/requirements/requirements.md` 的 SR-04.01。

## 发布审批

对外发布前先经 owner 明确同意，不得先发布后补报。范围包括 iOS TestFlight 与 App Store、连接器 npm 包、中转二进制、公共服务配置变更；提交给 owner 的内容至少写清版本、变更、影响范围与回滚方案，获批后把同意时间与原话写进发布记录。开发版 OTA 仍按下一节无需询问。

连接器源码在本机 profile 里是 `link:` 链接，保存后会在宿主热更中立即生效；改连接器行为等同于改本机正在运行的服务，改完按 `handbook/process/operations.md` 的「本机连接器刷新」验证。

## 开发版 OTA

开发改动验证通过后一律直接发布开发版 OTA（`./scripts/release/deploy-ota.sh`），无需事先询问。TestFlight 与 App Store 发布版只在用户主动要求时更新，用户确认满意后会主动提出（2026-09-21 要求）。

## 中转部署与自动回滚

中转是公共服务，刷新必须走 `./scripts/release/deploy-relay.sh`，不得手工 `scp` 二进制后裸 `systemctl restart`。

- 脚本先在一次性端口与一次性库上冒烟新二进制；留档当前 `dsh-relay` 与 `build.json` 到 `bin/history/<version>/`；备份数据库；替换后等目标 `relayVersion` 健康，再观察 60 秒。
- 观察期内连续 3 次健康检查失败，或服务自行重启（`NRestarts` 增长），必须自动回滚到上一份二进制与 `build.json` 并重启，不得只重试。
- 替换前的任何失败都不得重启服务；自动回滚失败时按 `relay-go/deploy/README.md` §5 从留档手工恢复，并向 owner 报告，不得连续盲重启。
- 部署后核对 `/healthz` 的 `relayVersion` 与 `build`、`systemctl is-active`、`NRestarts`、panic/5xx、连接器与设备自动重连；把留档路径与库备份写进发布记录。

## TestFlight

「发布 TestFlight」指上传、加入 Public beta 组、提交外部测试审核；审核通过后外部测试者可通过公开链接下载。只上传不提交审核不算发布。

`scripts/release/deploy-testflight.sh` 会执行归档、导出、上传、等待处理、加入分组并提交审核；只需上传、不提交审核时使用 `--no-submit`。版本号按 `handbook/requirements/requirements.md` 的 SR-04.02 执行。同步口径见 `handbook/history/上架流程.md`。

## TestFlight 更新说明（每次必做）

测试者更新时看到的「更新说明」（ASC 的 `whatsNew`，即 `scripts/dev/asc-beta.mjs` 的 `WHATS_TO_TEST`）每次发版都要改写，属发布的一部分；不改就是上一版的旧话（2026-11-15 连漏三版）。

- 只写**与上一个 TestFlight 构建相比用户能感知的变化**，用编号列出；内部重构、测试、文档不写。末尾写一条组件版本要求（如连接器升到 0.8.1 及以上）。
- 文案先交 owner 审批，同意后才刷新；不得先刷新后补报。
- 刷新后回读确认两语言都为「已是最新」，再提交外部测试审核。
- `WHATS_TO_TEST_BUILD` 与本次构建号必须一致；不一致时 `prepare` / `submit` 直接报错，防止旧文案被推到新构建上。

## 性能样本（不是门禁）

owner 2026-11-15 决定：发布级基线尚未建立，`test/performance/check-performance.mjs` 不再作为 TestFlight 的发布门禁，`deploy-testflight.sh` 不调用它。SR-08.05 本身要求「基线未建立前不得设置硬门禁」，此前把绝对阈值当硬门禁与需求冲突。

需要复核时手工跑 `node test/performance/check-performance.mjs --file /tmp/performance-device.log`；样本仍只认真机，模拟器文件不能替代。基线建立并按基线阈值定门禁后，再决定是否接回发布流程。

## 签名

分发签名使用本机手工流程：云签名被 Apple 拒绝（`Cloud signing permission error`），脚本优先使用 `~/Library/Keychains/dshbuild.keychain-db` 中的 Apple Distribution 证书与 `ios/DSHMobile/ExportOptions-manual.plist` 导出；证书与描述文件由 `node scripts/release/asc-dist-signing.mjs cert|profile` 准备。
