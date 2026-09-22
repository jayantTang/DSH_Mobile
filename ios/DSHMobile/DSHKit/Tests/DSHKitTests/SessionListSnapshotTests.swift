import Foundation
import Testing

@testable import DSHKit

/// The list snapshot is what makes a cold start show rows instead of a spinner,
/// so the parts worth pinning down are the ones that decide *whether an old file
/// may still be shown*: round-tripping, the 30-day window, and clearing.
@Suite("Session list snapshot")
struct SessionListSnapshotTests {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func summary(_ id: String, title: String, updatedAt: Double = 1_700_000_000_000) -> SessionSummary {
        let json = """
        {"sessionId":"\(id)","updatedAt":\(updatedAt),"running":false,"blank":false,
         "projections":{"asOfSeq":12,"values":{"title":"\(title)"}}}
        """
        return try! JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    private func workspace(_ id: String) -> Workspace {
        let json = """
        {"workspaceId":"\(id)","path":"/tmp/\(id)","title":"\(id)","sessionIds":["s-1"]}
        """
        return try! JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    }

    @Test("a snapshot survives a round trip")
    func roundTrip() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionListSnapshotStore(directory: dir)

        // savedAt 必须是"现在"：30 天窗口之外的一律当过期丢掉（这条规则本身另有测试）。
        store.save(SessionListSnapshot(
            savedAt: Date(),
            items: [summary("s-1", title: "定位跳白"), summary("s-2", title: "另一个")],
            workspaces: [workspace("19_dsh_iosapp")],
            archivedSessionIds: ["s-9"]
        ))

        let loaded = store.load()
        #expect(loaded?.items.count == 2)
        #expect(loaded?.items.first?.displayTitle == "定位跳白")
        #expect(loaded?.items.first?.asOfSeq == 12)
        #expect(loaded?.workspaces.first?.workspaceId == "19_dsh_iosapp")
        #expect(loaded?.archivedSessionIds == ["s-9"])
    }

    @Test("a snapshot older than the window is dropped, not shown")
    func staleSnapshotIsDeleted() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let store = SessionListSnapshotStore(directory: dir, now: { saved })

        store.save(SessionListSnapshot(
            savedAt: saved, items: [summary("s-1", title: "旧")], workspaces: [], archivedSessionIds: []))

        // 31 天后再打开：不能把一个月前的列表当成今天的。
        let later = SessionListSnapshotStore(
            directory: dir, now: { saved.addingTimeInterval(31 * 24 * 60 * 60) })
        #expect(later.load() == nil)
        // 而且已经删掉了，不会每次启动都白读一遍。
        let fresh = SessionListSnapshotStore(directory: dir, now: { saved })
        #expect(fresh.load() == nil)

        // 29 天时仍然可用（窗口边界内）。
        let inside = SessionListSnapshotStore(
            directory: dir, now: { saved.addingTimeInterval(29 * 24 * 60 * 60) })
        store.save(SessionListSnapshot(
            savedAt: saved, items: [summary("s-2", title: "还在")], workspaces: [], archivedSessionIds: []))
        #expect(inside.load()?.items.first?.sessionId == "s-2")
    }

    @Test("an unreadable snapshot is discarded rather than shown")
    func corruptSnapshotIsCleared() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session-list.json")
        try? Data("not json".utf8).write(to: file)

        let store = SessionListSnapshotStore(directory: dir)
        #expect(store.load() == nil)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("clearing removes it")
    func clear() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionListSnapshotStore(directory: dir)
        store.save(SessionListSnapshot(
            savedAt: Date(), items: [summary("s-1", title: "x")], workspaces: [], archivedSessionIds: []))
        #expect(store.load() != nil)
        store.clear()
        #expect(store.load() == nil)
    }
}
