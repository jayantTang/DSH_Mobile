import DSHConnectionAPI
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 027 — 列表快照：写盘的节流口径、它是哪台电脑的、以及冷启动首帧怎么用它。
///
/// 快照是"打开 App 立刻有东西看"的唯一来源，也是唯一会**反复写盘**的地方（每次
/// 宿主事件后的刷新都会走到 `saveSnapshot`）。这两件事都有代价：写多了是磁盘
/// churn，写错了（画上一台电脑的列表）是把另一台机器的历史当成现在的会话。
@MainActor
final class SessionListSnapshotTests: SessionsDomainTestCase {

    // MARK: - 指纹节流

    /// 内容没变不重写；内容一变就重写。
    func testSnapshotIsRewrittenOnlyWhenTheContentMoves() async throws {
        stubStandardList()

        await model.refresh()
        XCTAssertEqual(notes("snapshot.saved").count, 1, "the first successful refresh must write the snapshot")
        let first = try XCTUnwrap(snapshotStore.load(scope: scope))
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.workspaces.map(\.workspaceId), ["w1"])

        // 同样的内容再来一次：指纹相同 → 不写盘，落盘时间原地不动。
        await model.refresh()
        XCTAssertEqual(notes("snapshot.saved").count, 1, "identical content must not be written again")
        XCTAssertEqual(notes("snapshot.unchanged").count, 1)
        XCTAssertEqual(snapshotStore.load(scope: scope)?.savedAt, first.savedAt,
                       "the file on disk must be the one written by the first refresh")

        // 内容变了（一条会话的更新时间前进）：重写。
        stubSessions([
            Wire.session("s1", updatedAt: 9_000, asOfSeq: 100),
            Wire.session("s2", updatedAt: 2_000, asOfSeq: 90),
        ])
        await model.refresh()
        XCTAssertEqual(notes("snapshot.saved").count, 2, "moved content must be written")
        let second = try XCTUnwrap(snapshotStore.load(scope: scope))
        XCTAssertNotEqual(second.savedAt, first.savedAt)
        XCTAssertEqual(second.items.first(where: { $0.sessionId == "s1" })?.updatedAt, 9_000)
    }

    // MARK: - 一台电脑一份

    /// 换电脑：各写自己的一份；"清除缓存"只掉当前这一台。
    func testSnapshotIsKeptPerComputerAndClearingDropsOnlyTheActiveOne() async throws {
        let macA = TestFixtures.relayProfile(name: "Mac A")
        let macB = TestFixtures.relayProfile(name: "Mac B")
        pair(macA)
        stubStandardList()
        await model.refresh()

        let scopeA = macA.id.uuidString
        let scopeB = macB.id.uuidString
        XCTAssertNotNil(snapshotStore.load(scope: scopeA))

        // App 的切换路径（RootView）：先 forgetConnection，再换档案，模型被复用。
        // 这一句同时钉住"换电脑必须复位指纹"——否则 B 的内容与 A 相同时会跳过落盘。
        model.forgetConnection()
        pair(macB)
        await model.refresh()

        let snapshotB = try XCTUnwrap(snapshotStore.load(scope: scopeB),
                                     "a switch must leave the new computer its own snapshot")
        XCTAssertEqual(snapshotB.scope, scopeB)
        XCTAssertNotNil(snapshotStore.load(scope: scopeA), "the other computer's snapshot must survive")
        XCTAssertFalse(model.isShowingSnapshot, "rows that came back from the host are not a snapshot")

        // 新 scope 上的节流照旧：同样的内容第二次刷新不再写。
        let savedBefore = notes("snapshot.saved").count
        await model.refresh()
        XCTAssertEqual(notes("snapshot.saved").count, savedBefore,
                       "the throttle must still hold inside the new scope")

        model.clearCachedSnapshot()
        XCTAssertNil(snapshotStore.load(scope: scopeB), "clearing drops the active computer's snapshot")
        XCTAssertNotNil(snapshotStore.load(scope: scopeA), "clearing must not touch another computer's snapshot")
    }

    // MARK: - 冷启动首帧

    /// 冷启动先画这台电脑的快照，宿主数据回来后再以宿主为准。
    func testColdStartDrawsThisComputersSnapshotAndReconcilesWithTheHost() async throws {
        stubStandardList()
        await model.refresh()
        let callsAfterFirstRefresh = carrier.calls(to: "session/list").count

        // 重开 App：新模型、同一个快照目录、同一台电脑。
        let reopened = SessionListModel(snapshotStore: snapshotStore)
        let reopenedLink = FakeLinkService()
        reopenedLink.profiles = [profile]
        reopenedLink.activeProfile = profile
        reopenedLink.clientOverride = HostClientFactory.make(carrier: carrier)
        reopened.attach(to: reopenedLink, hub: hub)

        reopened.loadCachedList()
        XCTAssertTrue(reopened.isShowingSnapshot, "the cached rows must be labelled as such")
        XCTAssertEqual(reopened.phase, .loaded)
        XCTAssertEqual(reopened.groups.map(\.id), ["w1"])
        XCTAssertEqual(sessionIds(reopened.groups[0].sessions), ["s1", "s2"])
        XCTAssertTrue(reopened.archivedSessions.isEmpty)
        XCTAssertEqual(carrier.calls(to: "session/list").count, callsAfterFirstRefresh,
                       "drawing the snapshot must not ask the host anything")

        // 宿主回来了，而且那条会话已经不在列表里：屏幕换成宿主的回答。
        stubSessions([Wire.session("s2", updatedAt: 2_000, asOfSeq: 90)])
        await reopened.refresh()
        XCTAssertFalse(reopened.isShowingSnapshot, "host rows are not 'last time' data")
        XCTAssertEqual(sessionIds(reopened.groups[0].sessions), ["s2"])
        XCTAssertEqual(sessionIds(reopened.allSessions), ["s2"])

        // 别台电脑的快照不会被画出来。
        let otherMac = SessionListModel(snapshotStore: snapshotStore)
        let otherLink = FakeLinkService()
        let otherProfile = TestFixtures.relayProfile(name: "Other Mac")
        otherLink.profiles = [otherProfile]
        otherLink.activeProfile = otherProfile
        otherLink.clientOverride = HostClientFactory.make(carrier: carrier)
        otherMac.attach(to: otherLink, hub: hub)
        otherMac.loadCachedList()
        XCTAssertFalse(otherMac.isShowingSnapshot, "another computer's snapshot is not this one's history")
        XCTAssertTrue(otherMac.allSessions.isEmpty)
        XCTAssertTrue(otherMac.groups.isEmpty)
    }
    /// 028 缺陷6回归：换一台电脑后，即使内容指纹与旧电脑相同，也必须写新电脑的快照。
    func testSwitchingComputersStillWritesTheNewScopeSnapshot() async throws {
        stubStandardList()
        await model.refresh()
        let scopeA = scope
        XCTAssertNotNil(snapshotStore.load(scope: scopeA))

        // 换电脑：profile 换掉（新 id = 新 scope），宿主内容完全一样。
        let other = TestFixtures.relayProfile(name: "Other Mac")
        pair(other)
        await model.refresh()

        XCTAssertNotNil(snapshotStore.load(scope: scope),
                            "a fresh computer must get its own snapshot even when content matches the old one")
        XCTAssertNotEqual(scope, scopeA)
    }

}
