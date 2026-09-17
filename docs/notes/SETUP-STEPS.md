# 逐个操作的指引

按顺序做，每步都有「做完怎么确认」。四步一共约 15 分钟。

已经做完、不需要你操作的：README 与配图、三个包的 npm 元数据与发布脚本、三个上游目录的 PR
分支生成脚本、TestFlight 的导出配置、试用路径的记录。**这些都在仓库里，`git pull` 就是最新的。**

---

## 第 1 步：给仓库加 topics 与 description（2 分钟，零成本，收益最直接）

打开 https://github.com/jayantTang/DSH_Mobile

### 1.1 改 Description

点右上角 **About** 那行右边的 ⚙️（齿轮），把 **Description** 换成下面这段，然后 Save：

```
在 iPhone 上远程使用电脑的 DeepSeek Harness：WSS 经公网中转，4G/5G 可用，电脑不需要公网 IP。Native iOS client for remote DSH sessions.
```

### 1.2 加 Topics

同一个 ⚙️ 弹窗里的 **Topics** 框，逐个粘贴（每输入一个按回车确认）：

```
dsh
dsh-plugin
deepseek-harness
ios
iphone
ipados
swiftui
remote-control
self-hosted
agent
relay
websocket
```

**`dsh-plugin` 是关键的那个**：`dsh-plugin-radar`（1470 star）和 `Oh-My-DSH` 都按这个 topic
自动发现新仓库，8 小时内收录，不需要 PR、不需要 fork。

### 1.3 确认

```bash
curl -s https://api.github.com/repos/jayantTang/DSH_Mobile \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['description']); print(d['topics'])"
```

应看到新描述与 12 个 topic。**8 小时后**再跑一次下面这条，应该能搜到自己：

```bash
curl -s "https://raw.githubusercontent.com/AdamPlatin123/dsh-plugin-radar/main/PLUGINS-ALL.md" \
  | grep -c "jayantTang/DSH_Mobile"
```

返回 `0` 说明还没扫到（正常，等下一轮）；返回 ≥1 就是已经收录。

---

## 第 2 步：三个上游仓库各 Fork 一次（1 分钟）

没有 GitHub token 就建不了 fork，所以这一步只能点。三个页面各点一次右上角 **Fork** →
**Create fork**：

1. https://github.com/AdamPlatin123/dsh-plugin-radar
2. https://github.com/Dominic789654/awesome-deepseek-harness
3. https://github.com/Anil-matcha/awesome-dsh-plugin

### 确认

```bash
for r in dsh-plugin-radar awesome-deepseek-harness awesome-dsh-plugin; do
  printf '%s: ' "$r"
  curl -s -o /dev/null -w "%{http_code}\n" "https://api.github.com/repos/jayantTang/$r"
done
```

三个都返回 `200` 就齐了（`404` = 还没 fork 成功）。

---

## 第 3 步：生成并推送三个 PR（3 分钟）

```bash
cd ~/Bspace/project/19_dsh_iosapp

# 先干跑：生成分支并打印将插入的那一行，不推送
scripts/release/ecosystem-pr.sh all
```

**先看 diff**：每条都应该是「+1 行」，位置分别是 `PLUGINS.md` 的 `📡 远程渠道` 表、
`awesome-deepseek-harness` 的 `UI / Clients` 一节、`awesome-dsh-plugin` 的
`### Remote Access & Mobile` 一节。如果哪条报「找不到锚点」，说明上游当天改了结构，
停下来告诉我，别手工插。

确认无误后推送，并把脚本打印的三个链接逐个打开：

```bash
scripts/release/ecosystem-pr.sh all --push
```

每个链接是 GitHub 的 compare 页面，点 **Create pull request** 即可（标题与正文已经提交在
commit 里，页面会自己带出来）。三个 PR 的注意点：

| 仓库 | 标题 | 额外动作 |
| --- | --- | --- |
| dsh-plugin-radar | `docs: 登记 dsh-mobile-link` | 右侧勾选 **Allow edits from maintainers**（PR 模板要求） |
| awesome-deepseek-harness | `Add DSH_Mobile to UI / Clients` | 无 |
| awesome-dsh-plugin | `Add DSH Mobile (iOS client + relay) to the list` | 无 |

> 雷达那份 PR 模板的自检清单里有一条「package.json 用 `@dsh-external/*` scope」——
> 我们的包没有 scope，也不打算为一条清单改名（改名会毁掉
> `dsh plugin add dsh-plugin-mobile-link` 这个安装路径）。在 PR 的「备注」里写一句说明即可。

---

## 第 4 步：发到 npm（5 分钟）

发布必须用官方源——本机 registry 指向 npmmirror（只读镜像），所以登录时要显式指定。

```bash
# 1. 登录（要输用户名、密码、以及 2FA 验证码，如果开了两步验证）
npm login --registry=https://registry.npmjs.org

# 2. 干跑一遍：核对元数据、跑测试、打印将被打包的文件、检查是否重名
cd ~/Bspace/project/19_dsh_iosapp
scripts/release/publish-plugins.sh

# 3. 真的发布
scripts/release/publish-plugins.sh --publish
```

### 确认

```bash
for p in dsh-plugin-mobile-link dsh-plugin-send-image dsh-plugin-doubao-image; do
  printf '%s → ' "$p"
  npm view "$p" version 2>/dev/null || echo "(还没上去)"
done
```

三个都打印出版本号就成了。**然后走一次真实安装路径**（这是唯一能证明包没打错的检查）：

```bash
dsh plugin --profile web add dsh-plugin-mobile-link
```

装完之后**要重启 DSH 才生效**（连接器跑在 DSH 进程里）。重启后确认：

```bash
PORT=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.dsh/desktop-shell/endpoint.json')))['port'])")
curl -s "http://127.0.0.1:$PORT/mobile-link/status"   # 应显示已连接与设备列表
```

⚠️ **本机现在装的是本地路径版**，`~/.dsh/profiles/web/package.json` 里这三行是
`link:` 到你的 checkout：

```json
"dsh-plugin-mobile-link": "link:/Users/…/plugins/mobile-link",
"dsh-plugin-send-image": "link:/Users/…/plugins/send-image",
"dsh-plugin-doubao-image": "link:/Users/…/plugins/doubao-image"
```

改成 npm 版之后，同一个包会同时以「link 依赖」和「npm 依赖」存在，profile 的 bundles 列表里
也只会认一个名字但解析到两份代码。**开发本机建议保留 link**（改代码即生效，不用每次发版），
正式发布只在干净环境验一次 npm 安装即可。要改用 npm 版，先把上面三行删掉再 `dsh plugin add`。

---

## 第 5 步：让别人能试（这步要你先做一个决定）

`docs/notes/ENABLE-TRIAL.md` 里写全了。要点：

- **公共中转今天就能开**：服务器上铸邀请码 → 发给对方 → 他跑一行 `enroll` → 你不需要任何操作。
  但**现在没有按账号的流量与连接上限**，所以别把邀请码发到公开帖子下面。
- **TestFlight 缺 Apple Distribution 证书**（本机只有 Development 身份、描述文件 0 个），
  导出配置我已经写好，会员到位后一条命令归档上传。

### 要你回答的一件事

公共中转的邀请码**现在就铸 10 个**（默认 7 天有效，不续就自动过期，可随时撤销），
还是**等限额做完再铸**？

- 选「现在铸」：我立刻在服务器上执行，把 10 个码给你，你只发给信得过的人；
- 选「等限额」：我先在 `relay` 里加上每 agent 连接数上限与每设备每日字节上限（约半天），
  之后再铸。

---

## 做完之后的检查表

- [ ] 第 1 步：topics 与 description 已改，API 能查到
- [ ] 第 2 步：三个 fork 都存在（HTTP 200）
- [ ] 第 3 步：三个 PR 已开，雷达那份勾了 Allow edits
- [ ] 第 4 步：三个包在 npm 上能 `view`，并已用 `dsh plugin add` 真实装过一次
- [ ] 第 5 步：决定已做（铸码 / 先做限额）
- [ ] 8 周后看：中转上的实名设备数、clone 数、雷达是否收录（star 放最后看）
