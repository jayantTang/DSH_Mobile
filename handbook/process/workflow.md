# 开发流程

先确认需求或根因，再实现，最后用证据验证；不设多角色分工。

- 出现 bug、用例失败或异常行为：先走 `systematic-debugging`，根因未定位不得提出修法。
- 声称「修好了 / 通过 / 可发布」之前：必须走 `verification-before-completion`。
- 小改动（单文件文档、纯配置、文案）：可简化验证，仍须过提交防线，并在汇报中说明理由。
- 跨任务交接使用文件与证据路径，不用口头描述。
- 技能源文件在 `skills/<name>/SKILL.md`；`.dsh/` 不入库，克隆后执行 `./scripts/install/link-project-skills.sh` 建立项目级链接。DSH 不监视该目录，修改 skill 后按环境文档重启。
- 改功能前先读 `handbook/requirements/` 对应条目；改测试与门禁前先读 `handbook/process/quality.md`。

## 需求先行与审批

任何产品功能或行为的修改、新增诉求，先做需求影响审查，再决定是否进入实现。

1. 对照 `handbook/requirements/requirements.md` 找出相关 IR/SR/AR。
2. **冲突**：现有需求与诉求矛盾或不允许该行为时，停止实现，列出冲突点与可选处理，交 owner 决策；未决策前不改代码。
3. **空白**：没有对应需求时，先补 IR/SR/AR 与必要的 details；跑 `npm run review:requirements`，冲突自己修；自审通过后只把变更清单交 owner，owner 同意保存后运行 `npm run approve:requirements -- --owner-approved "<owner 的原话>"` 并提交需求。
4. **已覆盖**：需求已允许该行为时，不改需求，按对应条目实现。
5. 只有需求门槛通过（需求已批准保存，或确认无需改需求）后，才改实现；提交时 pre-commit 校验需求审批 hash。
6. 实现完成后逐条对照需求验收；实现与需求不一致时停止，向 owner 汇报，由 owner 决定改需求还是改实现，不得自行放宽需求。

审批台账在 `handbook/history/approvals.jsonl`（不入库）。程序只校验结构与 hash，语义冲突由 owner 决策。

## 发布与部署

实现通过验证后按 `handbook/process/release.md` 执行：对外发布先经 owner 明确同意；中转走受控脚本，失败自动回滚；本机连接器源码改动按热更链路验证。部署失败或触发回滚时，先恢复服务再复盘，不得连续盲重启。
