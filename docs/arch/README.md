# 代码架构快照

> 面向：实现者 · 状态：stable（2026-10-11 建立，v003 起支持三级下钻与流程视图）

这份目录保存 DSH Mobile 的**自动生成**架构快照：把仓库里各模块、各文件之间的实际依赖扫出来，
渲染成离线可看的交互页面，用来回答"现在的架构长什么样、谁依赖谁、哪里成环、关键流程走了哪些文件"。
手绘的架构说明在 [ARCHITECTURE.md](../ARCHITECTURE.md)，那份讲设计意图，这份讲代码实际状态。

## 怎么生成

```bash
npm run arch                        # 生成下一版（v001、v002…）
npm run arch -- --note "重构会话列表"  # 给这一版记一句话
npm run arch -- --version v003      # 指定版本目录（已存在则覆盖）
npm run arch -- --json              # 只打印汇总，不写文件
```

生成后打开 `docs/arch/index.html`。浏览器停在这里刷新即最新；全量生成目前约 3 秒。

真实调用关系（谁调用了谁）来自另一条独立的命令，它要跑 `sourcekit-lsp` 与后台索引，是分钟级：

```bash
npm run arch:deep          # 增量分析 DSHKit / RelayKit，写 docs/arch/deep.json
npm run arch:deep -- --force   # 忽略缓存全量重跑
```

`npm run arch` 只读这份缓存并内联进页面，所以快路径不依赖 sourcekit-lsp。缓存按文件内容 hash 增量：
改一个文件只重分析一个文件。`deep.json` 是派生产物，可以不入库（页面已经把数据固化进当时那一版）。

## 三级下钻怎么看

| 层级 | 怎么看 | 能看到什么 |
|---|---|---|
| 模块图 | 打开就是 | 各模块之间的依赖、分层、循环依赖与全局形状 |
| 文件级 | 点任意模块节点 | 该模块内部文件之间的依赖；被引用的模块外文件以虚线框标出 |
| 声明级 | 再点任意文件 | 该文件的类型、协议、继承与协议实现（可点着跳到定义文件）、函数清单（带行号） |
| 真实调用 | 同上，面板下半部分 | 该文件往外发出的真实调用与谁调用了它，带函数名与行号。来自 sourcekit-lsp 的语义索引，不是靠名字猜的；仅覆盖 DSHKit / RelayKit 两个 SPM target |

左侧面包屑可以随时回到上一层。选中文件后，与它无关的边会淡出，便于在密图里看清一条链。

## 流程视图

`docs/arch/flows/*.json` 是**手写**的关键链路定义，每一步绑定真实文件与符号：

```json
{
  "id": "send-message",
  "title": "发送一条消息",
  "description": "可选，一段说明",
  "steps": [
    { "id": "model", "label": "ChatModel 组装乐观行",
      "file": "ios/DSHMobile/DSHMobile/Features/Chat/ChatModel.swift", "symbol": "ChatModel", "kind": "logic" }
  ],
  "edges": [["model", "client", "RPC"]]
}
```

`file` 与 `symbol` 会被扫描器校验：文件不存在、或该文件里找不到这个符号，页面就把这一步标红并写出原因。
这是流程文档不烂掉的机制——代码改名后跑一次 `npm run arch` 就会暴露，而不是等人发现图过期。

## 目录约定

| 路径 | 内容 | 是否变化 |
|---|---|---|
| `index.html` | **最新一版**快照 | 每次生成都覆盖 |
| `latest.json` | 最新版本号、时间、commit | 每次生成都覆盖 |
| `vNNN/index.html` | 该版本的归档副本 | 生成后不再变 |
| `vNNN/client.js` | 该版本的交互脚本，随版本冻结 | 同上 |
| `vNNN/graph.json` | 原始扫描结果（模块、文件、声明、边、流程） | 同上 |
| `vNNN/diff.json` | 与上一版的模块依赖边增删 | 同上 |

`vNNN/graph.json` 是逐版对比的依据，"与上一版相比"一节读的就是它。

## 页面怎么读

- 顶部固定显示 commit、分支、生成时间、未提交改动数：**先确认这几个值再看图**，否则可能在看旧快照。
- 模块图**按部署角色分带**，这是看这张图的第一层信息（语言是实现细节，放在节点副标题里）：

| 带 | 子块 | 配色 |
|---|---|---|
| iOS 侧（iPhone App） | App 壳与装配（App target 剩余：App/Support/Debug）；**Domain 层**（`Modules/Sources/*Domain` 与 `*API`，禁 UI）；**Feature UI 层**（`*UI`）；Core / Design / Foundation / 测试支撑；协议与数据层（DSHKit）；中转客户端（RelayKit） | 蓝 / 橙 / 青 |
| 中转（公网主机） | `relay/` | 紫 |
| 电脑侧 DSH（连接器与插件） | `plugins/`、`skills/`、`sidecars/`；`plugin/mobile-link` 是**连接器** | 绿 |
| 仓库工程（不进产品链路） | `scripts/`、`test/tools` | 灰 |

025/026 模块化重构后，iOS 业务代码住进 `ios/DSHMobile/Modules/`（本地 SPM 包，按 Feature 拆 Domain/UI 两层），
App target 只剩壳与装配；模块间的编译期边界由 `scripts/dev/check-module-boundaries.mjs`（`npm run check:module-boundaries`）守护，
本页负责把实际依赖画出来供人看，两者互补。

  链路是 `iPhone App → WSS → 中转 → WSS → 连接器 → 127.0.0.1 → dsh web`。
- 工具条可按角色过滤（全部 / iOS 侧 / 中转 / 电脑侧 DSH / 仓库工程），可关掉启发式边，可只看环。
- 工具条左侧的「模块图 | 流程」是视图切换，与角色过滤不是一回事：流程视图下角色过滤不适用，因此不显示。
- 图例：

| 线型 | 含义 | 可靠性 |
|---|---|---|
| 实线灰 | Swift `import` 自有模块、SPM target 依赖、JS/Python 相对 import | 权威 |
| 蓝实线 | 继承与协议实现（`class X: Y`） | 语法明确，可信 |
| 黄虚线 | Swift 跨目录、跨文件的**类型引用** | 启发式，会漏也会误，可关掉 |
| 红虚线 | 循环依赖（Tarjan 强连通分量） | 权威 |
| 虚线框节点 | 本模块引用到的模块外文件 | 权威（由引用推出） |

## 已知误差与边界

1. **启发式边不可当结论用。** 靠"类型名唯一声明在某个文件"推断引用，已剔除注释、字符串，
   并要求类型出现在类型标注、泛型、构造调用等语法位置；但泛型参数遮蔽、同名局部变量仍可能误判。
   每条启发式边都带具体类型名，用于人工判断。
2. **调用关系只在 DSHKit / RelayKit 上有。** 面板里的"真实调用"来自 sourcekit-lsp，覆盖这两个 SPM target；
   App target 与 JS/Python 侧还没有。页面只收跨文件调用，同文件内的调用不展示。
   目标符号改名后 `npm run arch:deep` 没重跑时，页面会把这些边标成"目标符号已改名"。
3. **结构性不可能的边直接丢弃。** 例如库模块反向依赖 App target；丢弃条数记在 `meta.droppedEdges`。
4. **Swift App target 不在 SPM 里。** `swift package describe` 只能覆盖 DSHKit / RelayKit 两个 target，
   App 的边界来自 Xcode target 与目录约定。
5. **没有依赖连线的文件不画**，只在节点说明里计数，避免子图退化成文件清单。
6. 数字会漂。文件数、行数、边数都随代码变化，引用时以页面上标注的 commit 为准。

## 后续方向

调用图已接入（见上表），数据流与其余入口的可行性在 2026-10-11 实测过：

| 路线 | 实测结果 | 结论 |
|---|---|---|
| `sourcekit-lsp`（Xcode 自带） | DSHKit 的 `MessagePipeline` 查引用返回 10 处真实位置；文件必须先 `didOpen`，且后台索引要跑完才能查到跨文件引用 | **已接入**：`npm run arch:deep` 用 `callHierarchy/outgoingCalls` 取真实调用，61 个文件得 2222 条仓库内调用（跨文件 627 条），缓存增量 |
| 同上，App target（`ios/DSHMobile/DSHMobile`） | 语法级 `documentSymbol` 能用，语义级 `references` 超时 | 缺 Xcode 工程的编译参数；要先用 `xcode-build-server` 之类生成 `compile_commands.json` 才谈得上 |
| `Joern`（`swiftsrc2cpg`） | 本机既没有 Joern 也没有 JVM | 要先装 JDK 与 Joern 本体（约 1 GB），再建 CPG（分钟级、吃内存），成本明显高于上一条 |
| JS / Python 侧调用关系 | 未测 | JS 可用 `dependency-cruiser` 的规则加 `madge`；Python 可用 `pydeps` 或 `import-linter`，都比 sourcekit-lsp 便宜 |

互锁层同样未动：把选出的依赖边转成 CI 断言，接 [scripts/verify/lanes.json](../../scripts/verify/lanes.json)
的渠道体系，不另起一套。
