# 发布

用户可见的版本策略与 TestFlight 定义见 `handbook/requirements/` 的 SR-04.01 至 SR-04.03；本文件写发布操作与工程约束。

## 打 tag 与 Release

每次对外发布（iOS 构建、连接器 npm 包、中转）完成后立即打语义化 tag：`ios-vX.Y.Z` / `mobile-link-vX.Y.Z` / `relay-vX.Y.Z`。同一次发布只打一个 tag，tag 必须指向实际构建所用提交，不得指向事后补交的提交。

同时补 GitHub Release 说明，固定四段：变更（用户可感知的改动）、影响范围（需要升级的组件与兼容性）、升级方式（命令或步骤）、已知问题（未修项与规避）。不写「若干优化」「体验提升」这类无信息量的句子。

顺序固定：打 tag → 写 Release → 通知用户安装。缺 tag 或缺 Release 的发布视为未完成。

tag 与 Release 不得出现 OTA 地址；分发策略见 `handbook/requirements/requirements.md` 的 SR-04.01。

## 开发版 OTA

开发改动验证通过后一律直接发布开发版 OTA（`./scripts/release/deploy-ota.sh`），无需事先询问。TestFlight 与 App Store 发布版只在用户主动要求时更新，用户确认满意后会主动提出（2026-09-21 要求）。

## TestFlight

「发布 TestFlight」指上传、加入 Public beta 组、提交外部测试审核；审核通过后外部测试者可通过公开链接下载。只上传不提交审核不算发布。

`scripts/release/deploy-testflight.sh` 会执行归档、导出、上传、等待处理、加入分组并提交审核；只需上传、不提交审核时使用 `--no-submit`。版本号按 `handbook/requirements/requirements.md` 的 SR-04.02 执行。同步口径见 `handbook/history/上架流程.md`。

## 性能门禁

TestFlight 的导出、上传与提审会先执行 `node test/check-performance.mjs --file ${DSH_PERF_LOG:-/tmp/performance-device.log}`；样本不足或 p95 超标直接拒绝。`--archive-only` 只编译，不受此门禁影响。样本由真机性能驱动生成，不能用模拟器文件替代。

## 签名

分发签名使用本机手工流程：云签名被 Apple 拒绝（`Cloud signing permission error`），脚本优先使用 `~/Library/Keychains/dshbuild.keychain-db` 中的 Apple Distribution 证书与 `ios/DSHMobile/ExportOptions-manual.plist` 导出；证书与描述文件由 `node scripts/release/asc-dist-signing.mjs cert|profile` 准备。
