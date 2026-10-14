import Foundation

/// **会话运行时门面**：App 使用 DSHKit 的唯一入口（spec 023 FR-002 / SC-002）。
///
/// ## 为什么要有它
///
/// DSHKit 今天把整个实现都摊成了 `public`（1,129 个符号 / 137 个类型），App 52 个文件任意穿
/// 四层（client / store / pipeline / carrier）。实测：49 个"外部无人引用"的类型候选里有 26 个被
/// DSHKit 自己的 public 方法面钉住——**不先把方法面收进来，public 面就永远收不窄**
/// （证据：`specs/023-app-dshkit-boundary/baseline-public.md`）。
///
/// ## 形状（不会变的四条）
///
/// 1. **一个协议 + 一组只读模型**：五组能力都挂在这个协议的扩展里，App 侧只保留一个依赖点。
/// 2. `@MainActor` + `AnyObject`：门面活在主线程上，实现体是引用类型。
/// 3. **实现体不导出**：`SessionRuntimeHost` 是 `internal`，App 只能通过
///    `makeSessionRuntime(...)` 构造（见 `SessionRuntimeHost.swift`）。
/// 4. **不变量**（每条都有单测，见 `DSHKitTests/SessionRuntimeTests.swift`）：
///    视图只读、失败不等于到头、行身份稳定、单飞、依赖注入而非读全局。
///
/// ## 五组能力与它们各自的落地批次
///
/// | 组 | 能力 | 落地批次 |
/// |---|---|---|
/// | `Session` | 打开/关闭会话、订阅行与事件、发送与改写、发送文件、回答宿主提问、页内检索、翻更早 | S1 起逐块搬入 |
/// | `List` | 会话列表快照与增量、冷启动预取、列表动作、模型目录 | S3 |
/// | `Files` | 工作区文件列表/读取/下载、Git 状态与 diff/log、上传 | S3 |
/// | `Settings` | 设置描述与改写、权限档位、默认模型、agent preset、skill 列表 | S3 |
/// | `Link` | 连接/断开、状态流、诊断、配对、中转设备、反馈 | S2（本文件的 `transport` 是它的第一块） |
///
/// 每组在自己的批次里**新增一个 `SessionRuntime+<组>.swift` 扩展文件**再往里加成员；
/// 现在只有一个空壳时不预先建空文件（空扩展是噪声，也不产生任何判据）。
@MainActor
public protocol SessionRuntime: AnyObject {

    /// `Link` 组的第一块：当前传输状态。
    ///
    /// 只读快照，视图直接渲染；退避级别、版本兼容判定都只有一份实现（022 的裁定：
    /// 稳定存活才清零、探活连续两次失败才改判）。
    var transport: TransportStateSnapshot { get }
}
