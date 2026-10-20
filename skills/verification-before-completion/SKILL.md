---
name: verification-before-completion
description: 在声称“修好了 / 通过 / 没问题 / 可以发布”之前使用。按三级验证渠道取证据，缺 required 证据不算完成；测试必须有报告与判定，未跑到的步骤不得写成通过。
whenToUse: 当你要给 owner 汇报完成、提交改动、发版、或说“验证过了”时；也包括测试工程师出报告、架构师评审前核对证据。纯文档改动不适用。
---

# 完成前验证

没有证据就说没验证；没验证不得写成通过。

改写自 obra/superpowers 的 `verification-before-completion`（MIT），判定口径以本仓库 `scripts/verify/lanes.json`、`test/RULES.md` 与 `test/REPORT-CONTRACT.md` 为准。

## 一、先定该跑哪几级

```bash
npm run check:lanes -- --changed <file>
```

- `required` 格缺证据即不算完成，退出码 1。
- L3 跑不了必须写 `L3: 未跑 — <理由>`，不得静默跳过。
- 证据落 `.lanes/runs/`，四态：pass / fail / blocked / not-run。

## 二、测试要有报告才算完成

顺序固定：`run` → 逐张看标注图 → `scaffold` → 填 `review.md` → `report --verdict …`。

- 只跑了用例、没写评审、没出报告，一律不得汇报为「测试通过」。
- 汇报只给三样：判定（四态）+ 报告路径 + 需要 owner 决定的事。

## 三、iOS 改动

- 必须在仿真器实跑并逐屏截图核对，不能只凭编译通过（`ios-sim-testing`）。
- 改一处颜色或间距，顺带排查同类元素在列表、会话、设置、代码块等界面的表现。

## 四、与提交防线的关系

`.githooks/pre-commit` 的靶向测试只回答「本次提交有没有打断受影响用例」，耗时上限 30 秒；
它不构成完成证据。两者都要过：提交防线保证不倒退，lanes 与测试报告证明真的达成需求。

## 五、禁止的写法

- 只跑单测就说「通过」。
- 用全量测试替代 lanes 判定（CLAUDE.md 亦禁止全量测试）。
- 用 Mock 的自证代替真实行为验证。
- 把未执行、被跳过、blocked 的步骤写成通过。
- 用「应该没问题」「基本可用」代替判定。

## 六、产出

判定 + 证据路径 + 需要 owner 决定的事项（2–4 个选项，标注代价）。不确定的部分单独列出，不用结论覆盖。
