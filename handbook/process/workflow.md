# 开发流程

先确认需求或根因，再实现，最后用证据验证；不设多角色分工。

- 出现 bug、用例失败或异常行为：先走 `systematic-debugging`，根因未定位不得提出修法。
- 声称「修好了 / 通过 / 可发布」之前：必须走 `verification-before-completion`。
- 小改动（单文件文档、纯配置、文案）：可简化验证，仍须过提交防线，并在汇报中说明理由。
- 跨任务交接使用文件与证据路径，不用口头描述。
- 技能源文件在 `skills/<name>/SKILL.md`；`.dsh/` 不入库，克隆后执行 `./scripts/install/link-project-skills.sh` 建立项目级链接。DSH 不监视该目录，修改 skill 后按环境文档重启。
- 改功能前先读 `handbook/requirements/` 对应条目；改测试与门禁前先读 `handbook/process/quality.md`。

## 需求关键层审批

`handbook/requirements/` 下的 `product.md`、`requirements.md` 与 `details/*.md` 是需求关键层，变更必须经 owner 批准。

1. 改完先跑 `npm run check:requirements`：校验编号、层级、AR 父级、必填字段、细节文档引用与链接。有冲突先修，不提交给 owner。
2. 把改动 diff 与自审输出交给 owner；owner 明确同意后，以 owner 原话记录：
   `npm run approve:requirements -- --owner-approved "<owner 的原话>"`
3. `git commit` 时 pre-commit 校验暂存区文件 hash 与审批记录；任何改动导致 hash 变化，必须重新审批。
4. 审批台账在 `handbook/history/approvals.jsonl`（不入库）。程序只校验结构与 hash，语义冲突仍需 owner 阅读。
