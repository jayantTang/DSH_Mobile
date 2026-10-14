import DSHKit
import Foundation

/// App 侧的探针接线（spec 023 的 S4-1）。
///
/// `MessageLayer` 搬进 DSHKit 之后，它不再认识 `ViewportProbe`（App 的调试仪器）与
/// `ProbeVariants`（读启动参数）。接线留在这里：**探针、启动参数、注入器配额都是 App 的东西**，
/// 数据层只收一个 `Probes` 值。
extension MessageLayer {

    /// 生产构建下 `Probes` 全默认（不落盘、不注入）；带 `-DSHViewportProbe` /
    /// `-DSHProbeFailPage` / `-DSHProbeEmptyPage` 启动时才生效。
    static func withAppProbes() -> MessageLayer {
        let failures = PageFailureInjector(remaining: ProbeVariants.failPageAttempts)
        return MessageLayer(probes: MessageLayer.Probes(
            failPageShouldInject: { failures.shouldFail() },
            emptyPageAttempts: ProbeVariants.emptyPageAttempts,
            failPageArmed: { ProbeVariants.failPageArmed },
            note: { kind, fields, force in
                await ViewportProbe.note(kind, fields, force: force)
            }
        ))
    }
}
