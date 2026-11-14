# 测试与质量

## 两级验证渠道

测试按两级验证渠道执行，按改动类型判定所需级别（2026-10-08 起；L3 已于 2026-10-31 废除）。

- 判定规则只有一份：`scripts/verify/lanes.json`（隔离强度 × 被测对象）。需要调整判定时修改矩阵，不得在脚本中新增第二份规则；矩阵与渠道入口不一致时，`npm run check:contracts` 会报错。
- 每次改动执行 `npm run check:lanes -- --changed <file>`，它会输出必须执行的级别与缺失的证据。`required` 格缺证据即不算完成；退出码 0 表示证据齐备，1 表示缺证据或 blocked，2 表示工具自身故障。
- 所有 required 格必须声明 `scenarios`。`check:lanes` 按 `verdict.scenario` 过滤，`npm run test:scripts` 的矩阵用例会拦截未绑定场景的新 required 格。L1 已按对象绑定（protocol → protocol-tests；ios-unit → ios-unit-tests），不得用同渠道其它场景的通过结果充当证据。
- 两级渠道的前提与补救见 `scripts/verify/README.md`。某级不可用时必须如实报告 blocked（原因与下一步），不得静默跳过。
- L2 仅对 host-web 必跑（owner 2026-10-31 调整）。plugin 与 mail 的单测由 CI 的 Ubuntu 作业覆盖，本机 L2 对这两类改为可选复核。host-web 的 L2 证据绑定 `plugin-install-hot` 场景，不得用 `mail-tests` 等其它场景的判定充当证据。
- L3 已废除（owner 2026-10-31）：桌面宿主与从零启用改为发布前人工验收，不得写成自动化通过。
- 证据保存在 `.lanes/runs/`（已 gitignore），判定为 pass / fail / blocked / not-run 四态，与 `test/RULES.md` 一致。
- 验证渠道不改变检查次序：快速检查仍先于完整验证；两级渠道只回答「在哪一级环境取得证据」。

## 全量测试

修改后禁止全量测试。

- 不得运行全量套件（`npm test`、`swift test` 全量、不带文件参数的 `pytest`、`xcodebuild test` 全量）。日常只对受影响文件运行靶向用例，限时 30 秒。
- 修改后 5 秒内先生成 `git diff`（或 `git diff --cached`），据此确定受影响文件与用例。
- 靶向入口：Python `.venv/bin/python -m pytest -q mail/tests/test_<模块>.py`；Go `make -C relay-go test-pkg PKG=internal/<包>`；Node `node --test plugins/<包>/test/<用例>.test.js`；统一入口 `python3 scripts/targeted_tests.py --staged`。
- 超时即视为失败，不得以延长等待或重复执行掩盖。
- 例外：发布前门禁证据按 `scripts/verify/lanes.json` 的 required 格执行（`npm run check:lanes`），不属于用全量测试替代靶向测试；门禁检查不受 30 秒限制。

## 测试有效性

- 不得只断言 Mock 被调用，必须校验真实返回值、产物或状态迁移。
- 不得使用 `assert True`、空断言、`sleep` 等待或吞异常（`except: pass`）。
- 用例名与断言要表达需求口径，不得复制实现细节。
- TDD 适用范围：`relay-go/`、`mail/`、DSHKit 纯函数与连接器协议层走 RED-GREEN-REFACTOR；iOS 视图与仿真器交互不用 TDD，改用截图与测试报告；无测试底座的旧模块先补最小失败用例再修改。

## 完成定义

执行完用例不算完成，必须写出报告并给出判定。顺序固定为 `run` → 逐张查看标注图 → `scaffold` → 填写 `review.md` → `report --verdict …`。未写评审、被 lint 判为「报告不完整」，或只执行未判定，均不得汇报为「测试通过」。汇报测试结果只给三项：四态判定、报告路径、待用户决定的事项。

用例与报告口径以 `test/RULES.md`、`test/REPORT-CONTRACT.md` 为准。
