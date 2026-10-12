import DSHKit
import Foundation

/// 量一条「历史页」回包在手机上要花多少本机时间。
///
/// 四种口径对应四条实现路径，改前/改后各跑一次即可对照：
///
///   decode            一次 `[SessionRecord]` 解码 —— 真类型、真解码器（理想路径）
///   jsonValue         先解成 `JSONValue` —— 帧解码先落中间表示时要付的这份钱
///   viaJSONValue      `JSONValue` → 再 encode → 再 decode —— 当前 `LinkCarrier.unary` 的走法
///   viaSerialization  先 `JSONSerialization` 过一遍再 decode —— 「帧不解 JSONValue」这条路
///                     必须付的那份钱（它不像理想情况那样能省掉，这里如实量出来）
///
/// 用法：`history-page-bench <page.json> [iterations] [label]`

let arguments = CommandLine.arguments
guard arguments.count > 1, let data = FileManager.default.contents(atPath: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: history-page-bench <page.json> [iterations] [label]\n".utf8))
    exit(2)
}
let iterations = arguments.count > 2 ? (Int(arguments[2]) ?? 20) : 20
let label = arguments.count > 3 ? arguments[3] : URL(fileURLWithPath: arguments[1]).lastPathComponent

func milliseconds(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start) * 1000 / Double(iterations)
}

let decode = milliseconds {
    for _ in 0..<iterations { _ = try? JSONDecoder().decode([SessionRecord].self, from: data) }
}
let jsonValue = milliseconds {
    for _ in 0..<iterations { _ = try? JSONDecoder().decode(JSONValue.self, from: data) }
}
let viaJSONValue = milliseconds {
    for _ in 0..<iterations {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let encoded = try? JSONEncoder().encode(value) else { continue }
        _ = try? JSONDecoder().decode([SessionRecord].self, from: encoded)
    }
}
// App 收到一页之后要做的三件事，拆开量：
//   project  逐条把宿主事件投影成可渲染事件（含 reasoning/工具块解析）
//   reset    把一页记录折进时间线（行、分组、gap）
let projectCost = milliseconds {
    for _ in 0..<iterations {
        guard let records = try? JSONDecoder().decode([SessionRecord].self, from: data) else { continue }
        for record in records { _ = ChatEventDecoder.decode(record.event) }
    }
}
let resetCost = milliseconds {
    for _ in 0..<iterations {
        guard let records = try? JSONDecoder().decode([SessionRecord].self, from: data) else { continue }
        var timeline = ChatTimeline()
        timeline.reset(with: records)
    }
}
let viaSerialization = milliseconds {
    for _ in 0..<iterations {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { continue }
        _ = try? JSONDecoder().decode([SessionRecord].self, from: raw)
    }
}

// 机器可读一行，便于脚本汇总。
print(String(
    format: "PAGEBENCH\t%@\tbytes=%d\tdecode=%.2f\tproject=%.2f\treset=%.2f\tjsonValue=%.2f\tviaJSONValue=%.2f\tviaSerialization=%.2f",
    label, data.count, decode, projectCost, resetCost, jsonValue, viaJSONValue, viaSerialization
))
