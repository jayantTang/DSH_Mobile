import Foundation
import OSLog

/// 关键路径的统一性能标记。只记录，不参与业务判断。
///
/// 起止点由调用方给出；日志与 signpost 同名，方便 Instruments 和统一日志互相印证。
/// 名字用静态字符串，`OSSignposter.beginInterval` 不接受运行时拼接的字符串。
public enum PerformanceTrace {
    public enum Name: String {
        case sessionFirstContent = "session.first-content"
        case fileFirstPage = "file.first-page"
        case sendEcho = "send.echo"
    }

    public struct Token {
        let name: Name
        let state: OSSignpostIntervalState
        let started: CFAbsoluteTime
    }

    private static let subsystem = "com.jayanttang.dsh"
    private static let logger = Logger(subsystem: subsystem, category: "performance")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "performance")

    private static func label(_ name: Name) -> StaticString {
        switch name {
        case .sessionFirstContent: return "session.first-content"
        case .fileFirstPage: return "file.first-page"
        case .sendEcho: return "send.echo"
        }
    }

    public static func begin(_ name: Name) -> Token {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(label(name), id: id)
        logger.notice("perf.begin \(name.rawValue, privacy: .public)")
        return Token(name: name, state: state, started: CFAbsoluteTimeGetCurrent())
    }

    public static func end(_ token: Token) {
        let milliseconds = Int((CFAbsoluteTimeGetCurrent() - token.started) * 1000)
        signposter.endInterval(label(token.name), token.state)
        logger.notice("perf.end \(token.name.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }
}
