import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 027 — `DSHSessionsDomain` 的测试夹具。
///
/// 被测对象是 `SessionListModel`（+ 冷启动扩展）与 `DirectoryBrowserModel`：它们都
/// 只通过 `LinkService` / `DSHClient` 说话，所以这一套夹具的作用就一条——把"宿主的
/// 回答"变成可编程的 JSON，把"手机的请求"变成可断言的记录。
///
/// 两条纪律：
///
/// * **不碰真实数据**：快照落盘目录由用例注入临时目录（`SessionListSnapshotStore(directory:)`），
///   每次跑完删掉；不做任何写 `Caches` 默认路径的事，除非被测代码不提供缝（见
///   `SessionListColdStartPrefetchTests` 的说明）。
/// * **不构造产品结构体**：`SessionSummary` / `Workspace` / `HostDirectoryListing` 都只有
///   合成解码器、没有公开逐字段构造器。夹具于是照**线上形状**写 JSON，让被测代码自己去解
///   ——这样解码一旦漂了，用例会红，而不是夹具先替它把字段名改对。

// MARK: - 临时目录

/// 一个用例独占的临时目录。
final class TempDirectory {
    let url: URL

    init(label: String) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-sessions-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 线上形状的 JSON 夹具

enum Wire {
    /// 一行 `session/list`。
    ///
    /// `asOfSeq` 恒写上（0 表示"宿主没报游标"，冷启动预取据此跳过）。
    static func session(
        _ id: String,
        updatedAt: Double,
        running: Bool = false,
        blank: Bool = false,
        cwd: String? = "/Users/me/proj",
        asOfSeq: Int = 0,
        origin: String? = nil,
        parent: String? = nil,
        title: String? = nil
    ) -> JSONValue {
        var projections: [String: JSONValue] = ["asOfSeq": .int(asOfSeq)]
        if let title { projections["values"] = .object(["title": .string(title)]) }

        var value: [String: JSONValue] = [
            "sessionId": .string(id),
            "updatedAt": .double(updatedAt),
            "running": .bool(running),
            "blank": .bool(blank),
            "projections": .object(projections),
        ]
        if let cwd { value["cwd"] = .string(cwd) }
        if let origin { value["origin"] = .string(origin) }
        if let parent { value["parentSessionId"] = .string(parent) }
        return .object(value)
    }

    /// 一个 `session/list` 回包。
    static func sessionList(_ sessions: [JSONValue]) -> JSONValue {
        .object(["items": .array(sessions)])
    }

    /// workspace 基线里的一条。
    static func workspace(
        _ id: String, path: String, title: String, sessions: [String]
    ) -> JSONValue {
        .object([
            "workspaceId": .string(id),
            "path": .string(path),
            "title": .string(title),
            "sessionIds": .array(sessions.map { .string($0) }),
        ])
    }

    /// `workspace/follow` 的第一帧（基线）。列表页只读它。
    static func baseline(_ workspaces: [JSONValue], archived: [String] = []) -> JSONValue {
        .object([
            "type": .string("baseline"),
            "value": .object([
                "items": .array(workspaces),
                "archivedSessionIds": .array(archived.map { .string($0) }),
            ]),
        ])
    }

    /// `workspace/archiveSession` 的回包：宿主返回整份归档集合。
    static func archivedSet(_ ids: [String]) -> JSONValue {
        .object(["archivedSessionIds": .array(ids.map { .string($0) })])
    }

    /// 一层 `directoryPicker/list`：祖先链照宿主的口径从根到本级。
    static func listing(
        path: String,
        home: String = "/Users/tester",
        entries: [(name: String, path: String)] = [],
        truncated: Bool = false
    ) -> JSONValue {
        let entryValues = entries.map { entry in
            JSONValue.object([
                "name": .string(entry.name),
                "path": .string(entry.path),
                "hidden": .bool(entry.name.hasPrefix(".")),
            ])
        }
        return .object([
            "path": .string(path),
            "home": .string(home),
            "crumbs": .array(crumbs(of: path)),
            "entries": .array(entryValues),
            "truncated": .bool(truncated),
        ])
    }

    /// 一个绝对路径的祖先链（从根到本级），每条都是宿主会给的跳转目标。
    private static func crumbs(of path: String) -> [JSONValue] {
        let parts = path.split(separator: "/").map(String.init)
        var current = ""
        return parts.map { part in
            current += "/" + part
            return JSONValue.object([
                "name": .string(part),
                "path": .string(current),
                "hidden": .bool(part.hasPrefix(".")),
            ])
        }
    }
}

// MARK: - 用例基类

/// 一条用例的装配：假链路 + 假传输 + 临时快照目录 + 探针笔记。
@MainActor
class SessionsDomainTestCase: XCTestCase {

    /// 被测代码发出去的 RPC 记录（方法名 + 编码后的参数）。
    var carrier: FakeCarrier!
    /// 被测代码看到的链路（`clientOverride` 指向同一个假传输）。
    var fake: FakeLinkService!
    /// `attach` 要的事件中枢；这些用例不发事件，只借它占位。
    var hub: HostEventHub!
    var temp: TempDirectory!
    var snapshotStore: SessionListSnapshotStore!
    var model: SessionListModel!
    /// 当前这台"电脑"的档案；`scope` 由它派生。
    var profile: ConnectionProfile!
    /// 被测代码自己报上来的诊断（`probeNote`）。
    var notes: [ProbeNote] = []

    struct ProbeNote {
        let kind: String
        let fields: [String: String]
    }

    override func setUp() {
        super.setUp()
        carrier = FakeCarrier()
        fake = FakeLinkService()
        hub = HostEventHub()
        temp = TempDirectory(label: "case")
        snapshotStore = SessionListSnapshotStore(directory: temp.url)
        notes = []
        model = SessionListModel(snapshotStore: snapshotStore)
        model.probeNote = { [weak self] kind, fields, _ in
            self?.notes.append(ProbeNote(kind: kind, fields: fields))
        }
        pair(TestFixtures.relayProfile())
    }

    override func tearDown() async throws {
        model?.stop()
        hub?.stop()
        model = nil
        hub = nil
        fake = nil
        carrier = nil
        profile = nil
        snapshotStore = nil
        temp?.remove()
        temp = nil
        try await super.tearDown()
    }

    // MARK: - 装配

    /// 把模型接到一台"电脑"上。
    func pair(_ profile: ConnectionProfile) {
        self.profile = profile
        fake.profiles = [profile]
        fake.activeProfile = profile
        fake.clientOverride = DSHClient(carrier: carrier)
        model.attach(to: fake, hub: hub)
    }

    /// 当前 scope（= 档案 id；连接器未登记 agent id 时的口径）。
    var scope: String { profile.id.uuidString }

    // MARK: - 宿主的回答

    func stubSessions(_ sessions: [JSONValue]) {
        carrier.unaryResponses["session/list"] = .success(Wire.sessionList(sessions))
    }

    func stubWorkspaces(_ workspaces: [JSONValue], archived: [String] = []) {
        carrier.streamResponses["workspace/follow"] = [Wire.baseline(workspaces, archived: archived)]
    }

    /// 一台最常见的电脑：一份会话列表 + 一个 workspace 基线。
    func stubStandardList() {
        stubSessions([
            Wire.session("s1", updatedAt: 3_000, asOfSeq: 100),
            Wire.session("s2", updatedAt: 2_000, asOfSeq: 90),
        ])
        stubWorkspaces([Wire.workspace("w1", path: "/Users/me/proj", title: "proj", sessions: ["s1", "s2"])])
    }

    // MARK: - 小工具

    func sessionIds(_ sessions: [SessionSummary]) -> [String] {
        sessions.map(\.sessionId)
    }

    func notes(_ kind: String) -> [ProbeNote] {
        notes.filter { $0.kind == kind }
    }
}
