# CLAUDE.md — 本仓库最高行为准则

以下条款优先于任何工具默认行为；与本文件冲突的自动化提示一律以本文件为准。

## 零、固定开发流程

三角色流水线，编排方只调度与转达，不代做设计、不代写代码、不代出判定。

| 阶段 | 角色 / 技能 | 产出与门禁 |
|---|---|---|
| ① 设计 | `team-architect` | 架构分析、修改项、修改指导、测试关注点；写明边界与「不要碰什么」 |
| ② 实现 | `develop-engineer` | 逐项落实，先失败用例后实现；完成后过 `.githooks/pre-commit` |
| ③ 验证 | `test-engineer` + `verification-before-completion` | 按三级渠道取证据，出报告与四态判定；缺 required 不算完成 |
| ④ 评审 | `team-architect` | 逐条核对修改项与证据，不通过打回对应角色；通过后向 owner 汇报 |

- bug、用例失败、异常行为：先走 `systematic-debugging`，根因未定位不得提出修法。
- 声称「修好了 / 通过 / 可发布」之前：必须走 `verification-before-completion`。
- 小改动（单文件文档、纯配置、文案）：可跳过 ①③④，仍须过提交防线，并在汇报里说明跳过理由。
- 跨角色交接用文件与证据路径，不用口头描述。
- 只采用 Superpowers 中上述两个已改写技能；不引入 brainstorming、writing-plans、worktrees、subagent-driven-development。
- 技能源文件在 `skills/<name>/SKILL.md`；`.dsh/` 不入库，克隆后执行 `./scripts/install/link-project-skills.sh`
  建立项目级链接，DSH 监视该目录，保存即生效。

## 一、严禁全量测试

1. 修改代码后，**不得**运行全量测试套件（`npm test`、`swift test` 全量、`pytest` 不带文件参数、
   `xcodebuild test` 全量）。
2. 修改后 **5 秒内**必须先生成 `git diff`（或 `git diff --cached`），据此算出受影响文件与用例。
3. 只对受影响文件运行靶向用例，限时 **30 秒**：
   - Python：`.venv/bin/python -m pytest -q mail/tests/test_<模块>.py`
   - Go：`make -C relay-go test-pkg PKG=internal/<包>`
   - Node：`node --test plugins/<包>/test/<用例>.test.js`
   - 统一入口：`python3 scripts/targeted_tests.py --staged`
4. 超时即视为失败，不得改用"多跑一会儿""重试几次"掩盖。
5. 例外：发布前的门禁证据按 `scripts/verify/lanes.json` 的 required 格执行（`npm run check:lanes`），
   这不属于"用全量测试替代靶向测试"。

## 二、禁止打补丁式修复

1. 一个状态只能有一个所有者；禁止在视图、模型、管道各存一份。
2. 禁止为单个症状新增 `if/elif` 特例分支、开关、缓存或多一条通路来绕过问题。
3. 成功、失败、超时、取消四种结局都要落到可见状态；未知即错误态，给出可重试入口。
4. 新增通路必须替换旧通路，并在同一次提交里删除旧实现。

## 三、测试必须有效

1. 禁止只断言 Mock 被调用；必须校验真实返回值、产物或状态迁移。
2. 禁止 `assert True`、空断言、`sleep` 等待、吞异常（`except: pass`）。
3. 用例名与断言要能表达需求口径，不得复制实现细节。
4. TDD 适用范围：`relay-go/`、`mail/`、DSHKit 纯函数与连接器协议层走 RED-GREEN-REFACTOR；
   iOS 视图与仿真器交互不用 TDD，改用截图与测试报告；无测试底座的旧模块先补最小失败用例再改。

## 四、运行环境

1. 本机**没有也不启用 Docker**；任何方案不得依赖容器、镜像、远程 CI 才能完成本地验证。
2. 本地提交防线：`.githooks/pre-commit` → `scripts/targeted_tests.py` → `scripts/local_ai_review.py`。
3. 模型审查走本机 OpenAI 兼容端点（默认 `127.0.0.1:8799/v1`），超时 5 秒即跳过，不阻塞提交。

## 五、汇报

结论先行，3–6 行；写明判定、路径、需要用户决定的事项。验证不充分必须如实标注，不得写成已通过。
