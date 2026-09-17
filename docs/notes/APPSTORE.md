# App Store 上架

正式版的清单、现状与踩过的坑。TestFlight（给别人装）见 [`ENABLE-TRIAL.md`](ENABLE-TRIAL.md)；
这一页讲的是**上架到 App Store**——任何人搜得到、点一下就像普通 App 那样装。

## 现状（2026-09-17）

| 项 | 状态 |
| --- | --- |
| App 记录 | `DSH_Mobile` · `com.jayanttang.dsh` · 6813129188 |
| 版本 | **1.0** · `PREPARE_FOR_SUBMISSION`（可以提交） |
| 说明 / 关键词 / 支持网址 / 营销网址 | 已填（`scripts/dev/asc-store.mjs` 写的，文案也在那个脚本里） |
| 副标题 | 手机上的 DeepSeek Harness |
| 隐私政策网址 | `docs/PRIVACY.md` 的 raw 链接 |
| 分类 | 开发工具（`DEVELOPER_TOOLS`） |
| 审核备注 | 已填（含"审核时怎么测"的三步） |
| 出口合规 | 已在 Info.plist 声明 `ITSAppUsesNonExemptEncryption=false` |
| **截图** | **待补**（见下） |
| **年龄分级 / 定价与销售范围** | **待填**（只能网页上做） |
| **审核用演示邀请码** | **待铸**（提交前加进审核备注） |

一键查缺：

```bash
export ASC_KEY_ID=<KeyID> ASC_ISSUER_ID=<IssuerID>
node scripts/dev/asc-store.mjs status
```

## 还差什么（按顺序）

### 1. 截图（我可以生成，你挑）

`test/cases/current/15-上架截图.md` 会拍 4 张原图：转写、工作区文件、设置（脱敏）、连接页。
导出在 `test/runs/<运行>/shots/`。

App Store 只要求**按设备尺寸分组**，一组内部尺寸必须一致：

| 机型档 | 分辨率（竖屏） | 张数 |
| --- | --- | --- |
| 6.9"（iPhone 17 Pro Max / 16 Pro Max） | 1320×2868 | 3–10 张 |
| 6.5"（iPhone 11 Pro Max 一类） | 1242×2688 | 3–10 张 |
| 6.7"（iPhone 14 Plus 一类） | 1290×2796 | 3–10 张 |

模拟器是 iPhone 17 Pro，出图 **1206×2622**——与上面三档都不同。两个办法：
在 `test/tools/context.mjs` 换一台 6.9" 的模拟器再拍；或者用 `sips` 等比放到
1320×2868（会轻微插值，App Store 接受，但对齐像素更好）。

### 2. 还差两项（都只能网页做）

提交时 Apple 会一次性把所有缺项列出来（`associatedErrors` 里，逐条给详情）。
现在只剩两条：

- **隐私问卷**（App Store Connect → App 隐私 → "数据收集"）：选 **不收集数据** 即可。
  这是 API 上唯一做不到的一步（`appDataUsages` 那些资源没有公开的写入口），网页上约一分钟。
- **iPad 截图**：原工程声明支持 iPad（`TARGETED_DEVICE_FAMILY = "1,2"`），Apple 就要求
  12.9" iPad 截图。**已改成 iPhone-only**（`= 1`）——这个 App 就是手机客户端，
  声明支持 iPad 只会带来一份没人维护的截图要求。

已经用 API 完成的：年龄分级（整套问卷 26 项全部答"无"）、免费定价、内容版权声明
（不使用第三方内容）、审核联系人与备注、截图（iPhone 6.9"）、构建挂载。

> 年龄分级那个 PATCH 有三个坑：**必须一次给全整套问卷**（只给一个字段会回
> `You must provide a value for the attribute 'xxx'`）、布尔类与枚举类字段不能混
> （`Unexpected json type`）、`ageRatingOverride` 与 `ageRatingOverrideV2`
> 不能同时给（`AGE_RATING_OVERRIDE_V1_AND_V2_NOT_ALLOWED`）。

### 3. 审核用的演示环境（重要）

审核员没有你的电脑，**必须给一个能自己跑通的路径**，否则大概率被判"无法评估功能"而拒。
提交前：

```bash
# 在服务器上铸一个专用邀请码（比公开码 TTL 短一些，审核通过后撤销）
./admin.py --db /var/lib/dsh-relay/state.db invite-mint --note "App Review demo" \
  --count 1 --ttl-seconds 2592000 --relay wss://<你的站点>/dsh-link
```

把这个码与 `docs/ONBOARDING.md` 的链接写进**审核备注**（`ASC_REVIEW_NOTES_EXTRA`）：

```bash
ASC_REVIEW_NOTES_EXTRA="演示邀请码：XXXX-XXXX-XXXX-XXXX（一次性，30 天有效）；
电脑侧安装与配对步骤见 https://github.com/jayantTang/DSH_Mobile/blob/main/docs/ONBOARDING.md" \
  node scripts/dev/asc-store.mjs fill
```

审核通过后到服务器上 `invite-list --all` 找到它对应的 agent 并 `agent-disable`。

### 4. 提交

```bash
scripts/release/deploy-testflight.sh          # 归档 → 导出 → 上传（构建号会自动取时间）
node scripts/dev/asc-store.mjs status         # 确认构建已处理（VAL id）
```

然后在 App Store Connect → 版本页选这个构建 → **添加以供审核** → 提交。
第一次通常 1–3 天出结果。

## 两个 API 上的坑（已修在 asc-store.mjs 里）

- **说明 / 关键词 / 支持网址 / 营销网址在「版本本地化」上**（`appStoreVersionLocalizations`），
  不是版本本身；`promoText` 与 `reviewNotes` 又各自挂在别的资源上。写错地方都是 409
  `unknown attribute`。
- **分类挂在 `appInfos` 的关系上**，不是 `apps`（写 `apps` 会 409
  `unknown relationship`）；读也要从 `appInfos/<id>/relationships/primaryCategory` 读。
- `status` 命令早先读错过位置（把审核备注读成空），所以现在两边都从真实资源读。

## 上架 ≠ TestFlight

| | TestFlight | App Store |
| --- | --- | --- |
| 谁能装 | 拿到公开链接的人（上限 1 万） | 任何人 |
| 有效期 | 构建 90 天过期 | 不过期 |
| 审核 | 每个构建都审，通常 1–2 天 | 首次 1–3 天，后续更新也要审 |
| 收费 | 不支持内购 | 支持（抽 30%） |
| 定位风险 | 宽松 | 4.2（功能太薄）/ 2.5.2（下载执行代码）要看审核员怎么判 |

所以现在的顺序是：**TestFlight 先让人用起来 → 攒到反馈、把定位说清楚 → 再提正式版**。
真被拒也不是灾难（改完可重提），但被拒的理由会跟着这个 App 走，所以提交前把演示环境、
隐私说明、审核备注三样准备好，比事后解释划算。
