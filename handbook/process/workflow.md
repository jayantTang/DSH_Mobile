# 开发流程

先确认需求或根因，再实现，最后用证据验证；不设多角色分工。

- 出现 bug、用例失败或异常行为：先走 `systematic-debugging`，根因未定位不得提出修法。
- 声称「修好了 / 通过 / 可发布」之前：必须走 `verification-before-completion`。
- 小改动（单文件文档、纯配置、文案）：可简化验证，仍须过提交防线，并在汇报中说明理由。
- 跨任务交接使用文件与证据路径，不用口头描述。
- 技能源文件在 `skills/<name>/SKILL.md`；`.dsh/` 不入库，克隆后执行 `./scripts/install/link-project-skills.sh` 建立项目级链接。DSH 不监视该目录，修改 skill 后按环境文档重启。
- 改功能前先读 `handbook/requirements/` 对应条目；改测试与门禁前先读 `handbook/process/quality.md`。
