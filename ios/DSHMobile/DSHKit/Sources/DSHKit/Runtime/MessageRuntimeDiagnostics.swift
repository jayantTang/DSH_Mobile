import Foundation

/// 数据层运行诊断的公开接线点。
///
/// `SessionPipeline` 已收成模块内部类型，App 不能再直接持有它；这里只转发两条
/// sink，保持 `DIAGNOSTICS` 构建的接线方式不变。
public enum MessageRuntimeDiagnostics {
    public static var traceSink: (@Sendable (String) -> Void)? {
        get { SessionPipeline.traceSink }
        set { SessionPipeline.traceSink = newValue }
    }

    public static var metricsSink: (@Sendable ([String: String]) -> Void)? {
        get { SessionPipeline.metricsSink }
        set { SessionPipeline.metricsSink = newValue }
    }
}
