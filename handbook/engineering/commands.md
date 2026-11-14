# 常用命令

全量测试入口仅用于发布门禁；日常改动按 `handbook/process/quality.md` 只运行靶向用例。

```bash
# 测试
cd ios/DSHMobile/DSHKit && swift test        # 协议层单测。
                                             # LiveIntegrationTests 中有一条依赖本机真实会话；
                                             # 选中迁移被拒的那条（session-9d676f2d…）会失败，不是回归
cd plugins/mobile-link && npm test           # 连接器单测
cd plugins/send-image && npm test            # 图片插件单测
cd plugins/doubao-image && npm test          # 图片插件单测
cd relay-go && make test                     # 中转（Go）；黑盒套件 make test-blackbox
cd mail && ../.venv/bin/python -m pytest -q   # 信件服务
./scripts/dev/verify-simulator.sh            # 仿真器启动 App 并截图

# 两级验证渠道（判定规则在 scripts/verify/lanes.json）
npm run lane:doctor                          # 两级自检：L1 同机隔离 / L2 Linux 容器
npm run lane:l1 -- run --scenario smoke       # 执行 L1，证据保存在 .lanes/runs/（已 gitignore）
npm run check:lanes -- --changed <file>       # 输出本次改动必须执行的级别与缺失项
                                             #（L2 仅对 host-web 必跑；L3 已废除）

# 构建 App
cd ios/DSHMobile && xcodebuild -scheme DSHMobile \
  -destination 'platform=iOS Simulator,name=DSH-Test' build

# 安装到本机：仅在首次安装或替换同名包（升级）时执行；插件源码改动走热更。
./scripts/install/install-all.sh

# 发布 App（OTA）
./scripts/release/deploy-ota.sh

# App Store（凭据在 .env.local：ASC_KEY_ID / ASC_ISSUER_ID，脚本自行读取）
node scripts/dev/asc.mjs builds              # 构建处理状态（只读）
node scripts/dev/asc-store.mjs status|fill   # 版本页元数据与审核备注
node scripts/dev/asc-submit.mjs status|submit # 上架收尾与提交审核
./scripts/release/deploy-testflight.sh       # 归档、导出、上传、提交审核

# 测试选择：清单在 test/suites.json
node test/select.mjs --req SR-03.06            # 按需求选套件
node test/check-performance.mjs --file /tmp/performance-device.log  # 性能硬门禁
node test/select.mjs --affected --run          # 按改动选择并执行

# 探针
node scripts/dev/dsh-probe.mjs mint-code     # 生成配对码
node scripts/dev/dsh-probe.mjs pick-images   # 挑选包含图片的会话

# 中转用量（在服务器上执行；记账见 relay-go/README.md「用量冲盘与撤销对账」）
ssh root@$DSH_OTA_HOST '/opt/dsh-relay-go/bin/dsh-relay admin \
  --db /var/lib/dsh-relay/state.db usage --days 7 --by account'
curl -s localhost:8787/stats | head -c 400   # 今日汇总（包含尚未冲盘的部分）

# 邀请码使用量与新设备（服务器上有 dsh-relay admin enrollments）
node scripts/dev/watch-enrolls.mjs --count     # 本地查看明细（含电脑名）
node scripts/dev/watch-enrolls.mjs --dry-run   # 试用 issue 上将发布的内容
# 自动评论：LaunchAgent com.jayanttang.dsh-enrolls 每 15 分钟执行一次
#（日志 ~/Library/Logs/dsh-enrolls.log；卸载 launchctl bootout gui/$UID/com.jayanttang.dsh-enrolls）
```
