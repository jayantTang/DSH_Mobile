# 仓库约定

## 部署地址

仓库中一律使用 `relay.example.com` 占位符。真值放在本机且被 gitignore 的文件中：`.env.local`（发布脚本、插件、探针）与 `ios/DSHMobile/Config.local.xcconfig`（App 构建时注入 Info.plist）。修改地址时不得写回被跟踪的文件。

## 素材

真实截图（含设备名、家目录、会话画面）不入库，规则见 `.gitignore` 末尾。App 图标与 Asset Catalog 图片是构建输入，必须保留在仓库中。

## DSH 自带模块解析

插件不 vendor `ws` / `@deepseek-ai/cordis`，而是从 DSH 安装目录解析。解析阶梯固定为 `DSH_INSTALL_DIR` → 模块自身 → `$DSH_HOME/profiles/web` → PATH 上的 `dsh` → `npm root -g`，不得写死 Homebrew 等绝对路径。

该逻辑共四处实现：doubao-image 的 `lib/dsh-install.mjs`、mobile-link 的 `test/dsh-install.js`、`docs/artifacts/samples/capture.mjs`，以及 `plugins/mobile-link/lib/ws.js` 的 `candidateAnchors`。插件包需要能单独安装，前三处必须各保留一份，修改一处时同步另外两处。

第四处 `plugins/mobile-link/lib/ws.js` 是唯一随 npm 发布并真正生效的实现（该包 `files` 包含 `lib/`），与前三处有意不同：缺少 `DSH_INSTALL_DIR`、`which dsh`、`npm root -g` 三个锚点，多一个 `process.argv[1]`。它运行在用户机器上，修改锚点集合会改变已发布插件的解析行为，当前有意保留。该差异与四处锚点由 `test/contract/dsh-install-ladder.json` 记账，`npm run check:contracts` 按该文件做文本级比对。

## 文档

`docs/` 只放对外文档（协议、架构、配对、图片、样例）。过程记录与历史放在 `handbook/history/`（不入库），内部用例放在 `test/cases/`（已 gitignore），公开用例模板放在 `test/examples/`。

随仓库发布的文档由 `npm run check:docs` 校验：H1 唯一；首段不超过 240 字（中文）或 320 字符（英文）；参考类文档不得出现「你/我们/其实/赶紧」等口语；相对链接必须可达；不得出现真实家目录。新增 `docs/*.md` 须同时登记进 `scripts/dev/check-docs.mjs` 的清单。面向使用者的操作指引（`docs/ONBOARDING.md`、`docs/PRIVACY.md`、`CONTRIBUTING.md`、`SECURITY.md`、`CHANGELOG.md`）在口吻白名单内，允许第二人称。

## sidecars

`sidecars/` 是本机个人工具，不属于产品（2026-09-24 要求：个人工具不得影响 DSH Mobile 用户）。例如 `sidecars/llm-key-router`（个人模型接入的多 key 轮换代理与公司网关）。它不得放入 `plugins/`：`install-plugin.sh` 会把 `plugins/*` 全部注册进 profile，缺少 bundle patch 的目录会导致每次启动失败；产品侧（`ios/`、`plugins/`、`relay-go/`、`docs/`、`package.json`）也不得引用它。配置与 key 只放在本机 `~/.dsh/` 下。

## 提交与发布记录

提交信息使用中文，写明原因；一次提交只做一件事。发布记录（App、连接器、中转的版本组合）在 `handbook/history/发布记录/` 内部维护，不随仓库发布。

## App 本地化

- 字面量即键：代码中写中文（`Text("会话")`、`String(localized: "已连接")`），翻译放在 `ios/DSHMobile/DSHMobile/en.lproj/Localizable.strings`。
- 必须同时维护 `zh-Hans.lproj/Localizable.strings`（中文键对应中文值）。工程开发语言是 `en`，只添加 en 会导致中文设备回退为英文（曾出现该问题）。
- 带数字或插值的键是格式串：`"\(count) 个会话"` 的键写作 `"%lld 个会话"`，`String` 插值为 `%@`。
- 平台或宿主下发的文案（如权限档位名）也要经过 `String(localized:)`：认识的词条翻译，不认识的按原样显示。
- 验证方式：执行 `xcrun simctl launch … -AppleLanguages '(en)' -AppleLocale en_US` 查看英文，不带参数查看中文，两边都要截图确认。
- 修改文案前后执行 `npm run check:i18n`（`scripts/dev/check-localization.mjs`，离线，耗时小于 1 秒）：检查双向缺键、重复键（iOS 会静默以后者覆盖前者）、硬编码残留，以及「键在表中但调用点未走本地化」。退出码 0 表示无未豁免发现，1 表示存在未豁免发现，2 表示工具自身错误。
- 新增文案分三步：① 源文件写字面量（`Text("…")` / `String(localized: "…")`）；② 在 `en.lproj` 与 `zh-Hans.lproj` 各加一条（插值键写成 `%lld` / `%@`）；③ 执行 `npm run check:i18n` 直到退出码 0。
- 确实无法本地化的内容（后台待办、表值出口已本地化）加入 `scripts/dev/localization-exemptions.json`，每条必须写 `reason`（缺少 reason 时检查器退出码 2）。设置页不允许 `unlocalized-binding` 豁免，唯一例外是 `SettingsLabels` 的三张字典表，该限制由检查器强制执行。
