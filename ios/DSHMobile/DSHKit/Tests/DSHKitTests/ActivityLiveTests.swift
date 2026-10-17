import Foundation
import XCTest

import DSHKit

/// 018 T023：对**真实本机宿主**的只读集成用例。
///
/// 默认跳过（`swift test` 不加环境变量时全绿），显式打开才跑：
///
/// ```
/// cd ios/DSHMobile/DSHKit && DSH_LIVE_TESTS=1 swift test --filter ActivityLiveTests
/// ```
///
/// 边界（owner 本轮要求，也是 `AGENTS.md` §二.3）：
/// - **只读**：只开 `job/list` 流取一帧、只读 `session/list`、以及（连接器支持时）
///   读一次 `_link/jobRoster`；**不调用** `job/kill`、`subagents/interruptByParent`。
/// - **不写会话**：不发 prompt、不改名、不建会话。
/// - **不碰 `~/.dsh`**：只读 `~/.dsh/mobile-link/endpoint.json` 里的端点与 launch token。
/// - 宿主没在跑、没有可用会话时按"跳过"处理并写明原因（不是失败）。
final class ActivityLiveTests: XCTestCase {

    private struct EndpointFile: Decodable {
        let url: String
        let port: Int?
    }

    private var baseURL: URL!
    private var launchToken: String!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["DSH_LIVE_TESTS"] == "1" else {
            throw XCTSkip("设置 DSH_LIVE_TESTS=1 才跑对真实宿主的只读集成用例")
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/mobile-link/endpoint.json")
        guard let data = try? Data(contentsOf: path) else {
            throw XCTSkip("没有 \(path.path)（本机宿主没在跑）")
        }
        let endpoint = try JSONDecoder().decode(EndpointFile.self, from: data)
        guard let components = URLComponents(string: endpoint.url),
              let host = components.host,
              let port = components.port ?? endpoint.port,
              let url = URL(string: "http://\(host):\(port)")
        else {
            throw XCTSkip("端点 URL 解不出来：\(endpoint.url)")
        }
        guard let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
            throw XCTSkip("端点 URL 里没有 launch token")
        }
        baseURL = url
        launchToken = token
    }

    private func makeClient() -> DSHClient {
        DSHClient(carrier: HTTPCarrier(baseURL: baseURL, credential: .launchToken(launchToken), timeout: 30))
    }

    /// 连不上本机宿主是"这次跑不了"，不是"代码坏了"：转成 skip 并写明原因。
    private func isUnreachable(_ error: any Error) -> Bool {
        if error is URLError { return true }
        guard let transport = error as? DSHTransportError else { return false }
        switch transport {
        case .unreachable, .notConnected, .carrierClosed, .timedOut:
            return true
        default:
            return false
        }
    }

    /// 挑一条集成用例能安全读取的会话：绕开 `test/.quarantine.json` 里的（宿主打不开的那批）。
    private func pickSession(_ client: DSHClient) async throws -> SessionSummary {
        let value: SessionListValue
        do {
            value = try await client.sessions()
        } catch {
            if isUnreachable(error) {
                throw XCTSkip("本机宿主不可达（\(error.localizedDescription)）")
            }
            throw error
        }
        let usable = TestQuarantine.shared.usable(value.items)
        guard let session = usable.first(where: { !$0.isSubagent }) ?? usable.first else {
            throw XCTSkip("本机没有可用的会话（都在隔离名单里或列表为空）")
        }
        return session
    }

    // MARK: - job/list 一帧

    func testJobListYieldsOneReadableFrame() async throws {
        let client = makeClient()
        let session = try await pickSession(client)

        var frame: JobListFrame?
        do {
            for try await candidate in await client.jobList(sessionId: session.sessionId) {
                frame = candidate
                break  // 只取一帧：这条流没有自然结束，取到就走
            }
        } catch {
            if isUnreachable(error) { throw XCTSkip("本机宿主不可达（\(error.localizedDescription)）") }
            throw error
        }

        let rows = try XCTUnwrap(frame, "job/list 没吐任何一帧")
        XCTAssertEqual(rows.type, "rows")
        for job in rows.jobs {
            XCTAssertFalse(job.id.isEmpty)
            XCTAssertGreaterThan(job.startedAt, 0, "startedAt 是手机侧已跑时长的唯一基准")
            XCTAssertFalse(job.kind.isEmpty)
        }
        // 终态过滤是手机侧的事：rows 可以带终态任务，liveJobs 里不该有。
        XCTAssertTrue(rows.liveJobs.allSatisfy { $0.status.isLive })
    }

    // MARK: - session/list 里的子会话计时

    func testSessionListCarriesSubagentTiming() async throws {
        let client = makeClient()
        _ = try await pickSession(client)

        let value = try await client.sessions()
        let children = value.items.filter(\.isSubagent)
        guard !children.isEmpty else {
            throw XCTSkip("本机这一份 session/list 里没有子会话")
        }
        for child in children {
            XCTAssertNotNil(child.parentSessionId, "子会话必须能回指父会话")
            XCTAssertFalse(child.sessionId.isEmpty)
            // 计时投影是可选的（本轮没起过子智能体的历史会话没有）；有就必须自洽。
            guard let timing = child.subagentTiming else {
                XCTAssertFalse(child.isSubagentActive, "没有 timing 就不能算在跑")
                continue
            }
            if let active = timing.active {
                XCTAssertTrue(child.isSubagentActive)
                if let since = active.since {
                    XCTAssertGreaterThan(since, 0, "active.since 是已跑时长的基准")
                }
            } else {
                XCTAssertFalse(child.isSubagentActive)
            }
            if let settled = timing.settledMs {
                XCTAssertGreaterThanOrEqual(settled, 0)
            }
        }
    }

    // MARK: - 连接器的活动名单（能力位存在时）

    func testActivityRosterMatchesJobListWhenSupported() async throws {
        let client = makeClient()
        let handshake: LinkHandshake
        do {
            handshake = try await client.linkHandshake(
                client: LinkHandshakeRequest(clientName: "DSHKitTests", clientVersion: "live")
            )
        } catch {
            if isUnreachable(error) {
                throw XCTSkip("本机宿主不可达（\(error.localizedDescription)）")
            }
            // 直连通道上不一定有连接器的本地方法：这条通道测不了就如实跳过。
            throw XCTSkip("这条通道上没有连接器的 _link/hello：\(error.localizedDescription)")
        }
        guard handshake.supports(LinkHandshake.Capability.jobsRoster) else {
            throw XCTSkip("本机连接器还没声明 jobs-roster（连接器侧 Phase 2 未落地）")
        }

        let roster = try await client.activityRoster()
        XCTAssertGreaterThan(roster.at, 0, "名单必须带采样时刻（乱序保护靠它）")

        // 逐格与 job/list 对照：名单里的 running 必须能在宿主的任务表里看到，
        // 且不出现终态（`link-job-roster.md` §4 不变式 1）。只读核对，不 kill。
        for (sessionId, cell) in roster.sessions.prefix(3) {
            var frame: JobListFrame?
            for try await candidate in await client.jobList(sessionId: sessionId) {
                frame = candidate
                break
            }
            let rows = try XCTUnwrap(frame, "\(sessionId) 的 job/list 没吐帧")
            let known = Set(rows.jobs.map(\.id))
            for job in cell.running {
                XCTAssertTrue(job.status.isLive, "名单的 running 里不许出现终态：\(job.id) \(job.status)")
                XCTAssertTrue(known.contains(job.id), "名单里的 \(job.id) 在 job/list 里看不到")
            }
        }
    }
}
