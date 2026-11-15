# 分发细节

## SR-04.02 TestFlight 阶段版本号固定 1.0

- `MARKETING_VERSION` / `CFBundleShortVersionString` 固定 `1.0`；每次发布只递增 `CURRENT_PROJECT_VERSION` / `CFBundleVersion`，格式 `yyyyMMdd.HHmm`。
- 营销版本只在 App Store 正式发版时升。

## SR-04.03 发布包含提交外部测试审核

- `scripts/release/deploy-testflight.sh` 自动等待处理、加入 Public beta 组、提交外部测试审核；`--no-submit` 只上传。
- OTA 仅内部开发使用，不得对外暴露。

## SR-04.04 连接器源码改动热更

- 热更只覆盖插件源码（`plugins/*/lib/*.js` 及其引用文件）；`package.json` 版本替换、`cordis.patch.yml` 配置与 skill 不在热更范围，改这三类仍需重启。
- 首次开启热更本身要重启一次（配置在启动时读入）；之后保存源码由宿主重载插件，连接器重载会重连一次手机链路，App 不需要重装。
- 验证不看日志猜测：`node scripts/dev/plugin-hmr.mjs status` 为 on，且改动前后 DSH 进程 PID 不变、行为变化可见。
