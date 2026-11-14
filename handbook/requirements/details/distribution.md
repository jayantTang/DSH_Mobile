# 分发细节

## 4.2.1 版本号

- `MARKETING_VERSION` / `CFBundleShortVersionString` 固定 `1.0`；每次发布只递增 `CURRENT_PROJECT_VERSION` / `CFBundleVersion`，格式 `yyyyMMdd.HHmm`。
- 营销版本只在 App Store 正式发版时升。

## 4.3.1 发布

- `scripts/release/deploy-testflight.sh` 自动等待处理、加入 Public beta 组、提交外部测试审核；`--no-submit` 只上传。
- OTA 仅内部开发使用，不得对外暴露。
