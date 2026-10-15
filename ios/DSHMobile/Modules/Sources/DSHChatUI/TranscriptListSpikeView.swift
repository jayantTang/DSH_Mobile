#if os(iOS)
import DSHKit
import SwiftUI
import UIKit
import DSHChatDomain

/// Phase 0 的 spike 屏（spec 008）：只做两件事——
/// **插入 50 行**与**在插入的同时定位一次**，看位移与崩溃。
///
/// 为什么单独一屏而不直接改转写页：spike 是闸门，闸门要能在不牵扯会话/取页的前提下跑。
/// 数据是合成的（200 行起步、每 1.5 秒往上插 50 行），行视图沿用现有 SwiftUI 行视图
/// （`UIHostingConfiguration` 包一层），与真宿主同一条代码路径。
struct TranscriptListSpikeView: View {
    var body: some View {
        TranscriptListSpikeRepresentable()
            .overlay(alignment: .topLeading) {
                Text("list host spike")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    // 标识挂在 SwiftUI 的 `Text` 上：它是真正进了无障碍树的元素，
                    // 挂在外层 `UIViewRepresentable` 或裸 `UIView` 上 XCUITest 都看不到
                    // （实测两轮：20261008-222001、20261008-222038 的第 1 步都失败）。
                    .accessibilityIdentifier("spike.list")
            }
    }
}

private struct TranscriptListSpikeRepresentable: UIViewRepresentable {

    func makeUIView(context: Context) -> TranscriptListHost {
        let host = TranscriptListHost()
        // 标识挂在**宿主这个 UIView** 上：SwiftUI 的 `.accessibilityIdentifier` 套在
        // `UIViewRepresentable` 外面时，XCUITest 看不到里面的 UIView（实测 20261008-222001 第 1 步失败）。
        host.accessibilityIdentifier = "spike.list"
        host.makeRow = { item in
            AnyView(
                VStack(alignment: .leading, spacing: 2) {
                    Text("row \(item.seq)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(repeating: "内容 \(item.seq) ", count: 4))
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
        host.onDiagnostic = { name, fields in
            ChatProbe.probeNote?(name, fields, true)
        }
        context.coordinator.start(host)
        return host
    }

    func updateUIView(_ uiView: TranscriptListHost, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var task: Task<Void, Never>?
        private var nextSeq = 2000

        func start(_ host: TranscriptListHost) {
            // 起始 200 行（seq 2001…2200，越大越新）；之后每轮往上插更早的 50 行（seq 更小）。
            host.apply(.setRows((2001...2200).sorted().map(Self.item(seq:)), anchorId: nil))
            task = Task { @MainActor in
                // 先把视口放到"最新"那一头（seq 最小 = 最旧在最上，最大 = 最新在最下）。
                for round in 1...12 {
                    try? await Task.sleep(for: .milliseconds(1500))
                    if Task.isCancelled { return }
                    let anchor = host.currentAnchorId
                    let incoming = (0..<50).map { Self.item(seq: self.nextSeq - $0) }
                    self.nextSeq -= 50
                    ChatProbe.probeNote?("spike.round", [
                        "round": String(round),
                        "anchor": anchor ?? "-",
                        "incoming": String(incoming.count),
                    ], true)
                    // **故意并发**：插入之后立刻定位一次——007 的崩溃正是在这种时序下出现的。
                    host.prepend(incoming, reason: "spike")
                    if let anchor { host.scrollTo(id: anchor, animated: false) }

                    // spike D：每 3 轮做一次"回收最老的 100 行 → 再水合回来"，
                    // 比较锚点 y 与一个样本行的高（判据：两者都不变，±1pt）。
                    if round % 3 == 0, let anchor {
                        let sample = host.rows[host.rows.count / 2].id
                        let yBefore = host.screenY(of: anchor)
                        let hBefore = host.rowHeight(of: sample)
                        let victims = host.rows.prefix(100).map(\.id)
                        let items = incoming + host.rows.prefix(50).compactMap(\.item)
                        host.reclaim(ids: Array(victims))
                        host.rehydrate(items: items)
                        let yAfter = host.screenY(of: anchor)
                        let hAfter = host.rowHeight(of: sample)
                        ChatProbe.probeNote?("spike.rehydrate", [
                            "round": String(round),
                            "yDelta": String(format: "%.1f", (yAfter ?? 0) - (yBefore ?? 0)),
                            "hDelta": String(format: "%.1f", (hAfter ?? 0) - (hBefore ?? 0)),
                            "rows": String(victims.count),
                        ], true)
                    }
                }
                ChatProbe.probeNote?("spike.done", ["rows": String(host.rows.count)], true)
            }
        }

        /// 合成一条记录：与单测里的造法一致，走真实的 `TimelineItem` 折叠路径。
        static func item(seq: Int) -> TimelineItem {
            let json = """
            {"type":"user/message","seq":\(seq),"time":1789276358732,
             "data":{"content":[{"type":"text","text":"row \(seq)"}],
                     "source":{"kind":"user","rpcId":"r\(seq)"},"role":"user","id":"m\(seq)"}}
            """
            let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
            var timeline = ChatTimeline()
            timeline.apply(event)
            return timeline.items.last!
        }
    }
}
#endif
