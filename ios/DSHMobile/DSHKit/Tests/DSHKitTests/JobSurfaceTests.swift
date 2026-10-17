import Foundation
import XCTest

@testable import DSHKit

/// 018 T016：宿主 job 面与连接器名单的线格式。
///
/// 帧样本照 `specs/018-mobile-activity-visibility/contracts/host-job-surface.md`
/// 的实测 JSON 写（那里标【live】）。这里钉三件事：三种 follow 帧、kill 的两种
/// outcome、以及请求体在线上到底长什么样——`job/*` 走 `{request: …}` 信封，
/// `subagents/interruptByParent` 是**扁平**参数且 `mode` 固定 `continuable`，
/// 混用会换回一个看起来像"操作失败"的 `gateway/arguments-invalid`。
final class JobSurfaceTests: XCTestCase {

    // MARK: - Carrier double

    /// 记录每一次调用（方法名 + 编码后的 args），并按脚本吐出流帧与 unary 载荷。
    private final class Recorder: DSHCarrier, @unchecked Sendable {
        struct Call {
            let method: String
            let args: [String: Any]
        }

        private let lock = NSLock()
        private var unaryCalls: [Call] = []
        private var streamCalls: [Call] = []

        /// method → 成功载荷（`value` 的 JSON）。
        var payloads: [String: String] = [:]
        /// method → 抛出的错误（优先于 `payloads`；宿主拒绝时走这条）。
        var failures: [String: any Error] = [:]
        /// endpoint → 依次吐出的帧 JSON。
        var scripts: [String: [String]] = [:]

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return unaryCalls
        }

        var streams: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return streamCalls
        }

        private func object<Args: Encodable>(_ args: Args) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(args))) as? [String: Any] ?? [:]
        }

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String,
            args: Args,
            as valueType: Value.Type
        ) async throws -> Value {
            let object = object(args)
            lock.withLock { unaryCalls.append(Call(method: method, args: object)) }
            if let failure = failures[method] { throw failure }
            guard let json = payloads[method] ?? payloads["*"] else {
                throw DSHRPCFailure(code: "test/no-payload", message: "no payload for \(method)")
            }
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        }

        func stream<Args: Encodable & Sendable>(
            endpoint: String,
            args: Args
        ) async -> AsyncThrowingStream<JSONValue, any Error> {
            let object = object(args)
            lock.withLock { streamCalls.append(Call(method: endpoint, args: object)) }
            let frames = scripts[endpoint] ?? []
            return AsyncThrowingStream { continuation in
                for frame in frames {
                    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8)) else {
                        continuation.finish(throwing: DSHTransportError.malformedResponse("bad script frame"))
                        return
                    }
                    continuation.yield(value)
                }
                continuation.finish()
            }
        }

        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}
    }

    private func client(_ recorder: Recorder) -> DSHClient {
        DSHClient(carrier: recorder)
    }

    // MARK: - 帧样本

    private let liveJobView = """
    {"id":"bash-2955","kind":"bash","label":"cd relay && .venv/bin/python -m pytest -q 2>&1 | tail -6",
     "owner":"session-c026df05-1111-2222-3333-444455556666","status":"running",
     "startedAt":1791815149814,"output":{"total":0,"earliest":0}}
    """

    private let settledJobView = """
    {"id":"bash-2955","kind":"bash","label":"cd relay && .venv/bin/python -m pytest -q 2>&1 | tail -6",
     "owner":"session-c026df05-1111-2222-3333-444455556666","status":"killed",
     "detail":"signal: SIGTERM; cancelled by the user","startedAt":1791815149814,
     "finishedAt":1791815180000,"output":{"total":1540,"earliest":0}}
    """

    // MARK: - job/list

    func testJobListYieldsWholeRowsFrames() async throws {
        let recorder = Recorder()
        recorder.scripts["job/list"] = [
            #"{"type":"rows","jobs":[\#(liveJobView)]}"#,
            #"{"type":"rows","jobs":[]}"#,
        ]

        var frames: [JobListFrame] = []
        for try await frame in await client(recorder).jobList(sessionId: "s1") {
            frames.append(frame)
        }

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].type, "rows")
        XCTAssertEqual(frames[0].jobs.map(\.id), ["bash-2955"])
        XCTAssertEqual(frames[0].jobs[0].kind, "bash")
        XCTAssertEqual(frames[0].jobs[0].startedAt, 1_791_815_149_814)
        XCTAssertEqual(frames[0].jobs[0].output.total, 0)
        XCTAssertTrue(frames[1].jobs.isEmpty, "整份替换：第二次 rows 可以把名单清空")
    }

    func testJobListRequestUsesRequestEnvelope() async throws {
        let recorder = Recorder()
        recorder.scripts["job/list"] = [#"{"type":"rows","jobs":[]}"#]

        for try await _ in await client(recorder).jobList(sessionId: "s1") {}

        let call = try XCTUnwrap(recorder.streams.first)
        XCTAssertEqual(call.method, "job/list")
        XCTAssertEqual(Set(call.args.keys), ["request"])
        let request = try XCTUnwrap(call.args["request"] as? [String: Any])
        XCTAssertEqual(Set(request.keys), ["sessionId"])
        XCTAssertEqual(request["sessionId"] as? String, "s1")
    }

    // MARK: - job/follow

    func testJobFollowDecodesThreeFrameTypesInOrder() async throws {
        let recorder = Recorder()
        recorder.scripts["job/follow"] = [
            #"{"type":"opened","job":\#(liveJobView),"from":0}"#,
            #"""
            {"type":"output","chunks":[
              {"at":0,"text":"collected 407 items\n","channel":"stdout"},
              {"at":24,"text":"warn: slow test\n","channel":"stderr","gapBefore":true}
             ],"next":48,"lossy":true}
            """#,
            #"{"type":"status","job":\#(settledJobView)}"#,
        ]

        var frames: [JobFollowFrame] = []
        for try await frame in await client(recorder).jobFollow(sessionId: "s1", jobId: "bash-2955") {
            frames.append(frame)
        }

        XCTAssertEqual(frames.count, 3)
        guard case .opened(let job, let from) = frames[0] else {
            return XCTFail("首帧必须是 opened，实际 \(frames[0])")
        }
        XCTAssertEqual(job.id, "bash-2955")
        XCTAssertTrue(job.isLive)
        XCTAssertEqual(from, 0)

        guard case .output(let chunks, let next, let lossy) = frames[1] else {
            return XCTFail("第二帧必须是 output，实际 \(frames[1])")
        }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].channel, .stdout)
        XCTAssertNil(chunks[0].gapBefore)
        XCTAssertEqual(chunks[1].gapBefore, true, "丢段要显式提示，不能靠猜")
        XCTAssertEqual(chunks[1].at, 24)
        XCTAssertEqual(next, 48)
        XCTAssertTrue(lossy)

        guard case .status(let settled) = frames[2] else {
            return XCTFail("末帧必须是 status，实际 \(frames[2])")
        }
        XCTAssertEqual(settled.status, .killed)
        XCTAssertEqual(settled.detail, "signal: SIGTERM; cancelled by the user")
        XCTAssertEqual(settled.elapsedMilliseconds(now: 0), 30_186, "结束的任务用 finishedAt - startedAt")
    }

    func testJobFollowRequestEnvelopeOmitsAbsentFields() async throws {
        let recorder = Recorder()
        let client = client(recorder)

        recorder.scripts["job/follow"] = []
        for try await _ in await client.jobFollow(jobId: "bash-1") {}

        recorder.scripts["job/follow"] = []
        for try await _ in await client.jobFollow(sessionId: "s1", jobId: "bash-1", from: 512) {}

        XCTAssertEqual(recorder.streams.count, 2)
        let first = try XCTUnwrap(recorder.streams.first?.args["request"] as? [String: Any])
        XCTAssertEqual(Set(first.keys), ["jobId"], "unowned 任务没有 sessionId；from 缺省即从最老字节开始")
        let second = try XCTUnwrap(recorder.streams.last?.args["request"] as? [String: Any])
        XCTAssertEqual(Set(second.keys), ["sessionId", "jobId", "from"])
        XCTAssertEqual(second["from"] as? Int, 512)
    }

    func testUndecodableFollowFrameDoesNotEndTheStream() async throws {
        let recorder = Recorder()
        recorder.scripts["job/follow"] = [
            #"{"type":"opened"}"#,                      // 缺 job：这一帧解不出
            #"{"type":"status","job":\#(settledJobView)}"#,
        ]

        var frames: [JobFollowFrame] = []
        for try await frame in await client(recorder).jobFollow(sessionId: "s1", jobId: "bash-2955") {
            frames.append(frame)
        }

        XCTAssertEqual(frames.count, 2)
        guard case .unknown(let type, _) = frames[0] else {
            return XCTFail("解不出的帧要降级成 unknown，实际 \(frames[0])")
        }
        XCTAssertEqual(type, "undecodable")
        guard case .status = frames[1] else {
            return XCTFail("unknown 之后流必须继续，实际 \(frames[1])")
        }
    }

    /// G8（`test-coverage.md` §2）：流内的 `error` 帧是"这次 follow 失败了"，
    /// 不是"这帧不认识"。降级成 `.unknown` 继续读会让输出面板一直等着一个
    /// 永远不会再来的 `status` 帧。
    func testFollowErrorFrameEndsTheStreamAndThrows() async throws {
        let recorder = Recorder()
        recorder.scripts["job/follow"] = [
            #"{"type":"opened","job":\#(liveJobView),"from":0}"#,
            #"{"type":"error","error":{"code":"job/not-found","message":"the job is gone","details":{"jobId":"bash-2955"}}}"#,
            #"{"type":"status","job":\#(settledJobView)}"#,   // 错误帧之后的一律不许再吐
        ]

        var frames: [JobFollowFrame] = []
        do {
            for try await frame in await client(recorder).jobFollow(sessionId: "s1", jobId: "bash-2955") {
                frames.append(frame)
            }
            XCTFail("error 帧必须让流以失败结束，不能正常收尾")
        } catch let error as DSHTransportError {
            guard case .streamFailed(let failure) = error else {
                return XCTFail("流内错误要以 streamFailed 上抛，实际 \(error)")
            }
            XCTAssertEqual(failure.code, "job/not-found")
            XCTAssertEqual(failure.message, "the job is gone")
            XCTAssertEqual(failure.details["jobId"]?.stringValue, "bash-2955")
        } catch {
            XCTFail("意外的错误类型：\(error)")
        }

        XCTAssertEqual(frames.count, 1, "error 帧不是可降级的 unknown：它之后不再吐帧")
        guard case .opened = frames[0] else {
            return XCTFail("错误之前的 opened 帧照常到达，实际 \(frames[0])")
        }
    }

    /// 有的转发层把错误字段直接铺在帧上（没有 `error` 信封）；同样要能识别。
    func testFollowErrorFrameWithFlatFieldsAlsoThrows() async throws {
        let recorder = Recorder()
        recorder.scripts["job/follow"] = [
            #"{"type":"error","code":"job/denied","message":"not your job"}"#,
        ]

        do {
            for try await _ in await client(recorder).jobFollow(sessionId: "s1", jobId: "bash-1") {}
            XCTFail("扁平形状的 error 帧同样要抛错")
        } catch let error as DSHTransportError {
            guard case .streamFailed(let failure) = error else {
                return XCTFail("实际 \(error)")
            }
            XCTAssertEqual(failure.code, "job/denied")
            XCTAssertEqual(failure.message, "not your job")
        } catch {
            XCTFail("意外的错误类型：\(error)")
        }
    }

    // MARK: - job/kill

    func testKillRequestedOutcome() async throws {
        let recorder = Recorder()
        recorder.payloads["job/kill"] = #"{"outcome":"requested"}"#

        let value = try await client(recorder).jobKill(sessionId: "s1", jobId: "bash-2955")

        XCTAssertEqual(value.outcome, .requested)
        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.method, "job/kill")
        XCTAssertEqual(Set(call.args.keys), ["request"])
        let request = try XCTUnwrap(call.args["request"] as? [String: Any])
        XCTAssertEqual(Set(request.keys), ["sessionId", "jobId"])
        XCTAssertEqual(request["jobId"] as? String, "bash-2955")
    }

    func testKillAlreadyFinishedOutcome() async throws {
        let recorder = Recorder()
        recorder.payloads["job/kill"] = #"{"outcome":"already-finished"}"#

        let value = try await client(recorder).jobKill(sessionId: "s1", jobId: "bash-2955")

        XCTAssertEqual(value.outcome, .alreadyFinished, "已结束不是错误：行按名单收敛并给一句提示")
    }

    func testKillUnknownOutcomeDoesNotThrow() async throws {
        let recorder = Recorder()
        recorder.payloads["job/kill"] = #"{"outcome":"queued-for-deletion"}"#

        let value = try await client(recorder).jobKill(sessionId: "s1", jobId: "bash-2955")

        XCTAssertEqual(value.outcome, .unknown("queued-for-deletion"))
    }

    /// G7（`test-coverage.md` §2）：宿主回 `job/not-found` 时不许静默成功。
    /// 调用方（`ActivityModel.killJob`）就是靠 `code` 决定"任务已不在列表里"这条提示的。
    func testKillNotFoundThrowsWithTheHostCodeAndMessage() async throws {
        let recorder = Recorder()
        recorder.failures["job/kill"] = DSHRPCFailure(
            code: "job/not-found",
            message: "job bash-2955 not found",
            details: .object(["sessionId": .string("s1"), "jobId": .string("bash-2955")])
        )

        do {
            _ = try await client(recorder).jobKill(sessionId: "s1", jobId: "bash-2955")
            XCTFail("看不到的任务与不存在的任务同码；不得当作停止成功")
        } catch let failure as DSHRPCFailure {
            XCTAssertEqual(failure.code, "job/not-found")
            XCTAssertEqual(failure.message, "job bash-2955 not found")
            XCTAssertEqual(failure.details["jobId"]?.stringValue, "bash-2955")
        } catch {
            XCTFail("错误必须保持 DSHRPCFailure 的形状，实际 \(error)")
        }

        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.method, "job/kill")
        let request = try XCTUnwrap(call.args["request"] as? [String: Any])
        XCTAssertEqual(request["jobId"] as? String, "bash-2955", "抛错之前请求确实发出去了")
    }

    // MARK: - subagents/interruptByParent

    func testSubagentInterruptUsesFlatArgsAndFixedMode() async throws {
        let recorder = Recorder()
        recorder.payloads["subagents/interruptByParent"] = #"{"accepted":true}"#

        let value = try await client(recorder).subagentInterrupt(
            childSessionId: "sub-child",
            parentSessionId: "s1"
        )

        XCTAssertTrue(value.accepted)
        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.method, "subagents/interruptByParent")
        XCTAssertEqual(
            Set(call.args.keys),
            ["childSessionId", "parentSessionId", "mode"],
            "这个端点是扁平参数，没有 {request: …} 信封"
        )
        XCTAssertNil(call.args["request"])
        XCTAssertEqual(call.args["mode"] as? String, "continuable", "宿主 schema 是字面量 continuable")
        XCTAssertEqual(call.args["childSessionId"] as? String, "sub-child")
        XCTAssertEqual(call.args["parentSessionId"] as? String, "s1")
    }

    // MARK: - _link/jobRoster

    func testActivityRosterUsesConnectorMethodWithEmptyArgs() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/jobRoster"] = """
        {"at":1791815149814,
         "sessions":{"session-c026df05-1111-2222-3333-444455556666":{
           "running":[{"id":"bash-2955","kind":"bash","label":"pytest -q","status":"running",
                       "startedAt":1791815149814,"outputTotal":0,
                       "owner":"session-c026df05-1111-2222-3333-444455556666"}],
           "settled":3}}}
        """

        let roster = try await client(recorder).activityRoster()

        XCTAssertEqual(roster.at, 1_791_815_149_814)
        let cell = try XCTUnwrap(roster.cell("session-c026df05-1111-2222-3333-444455556666"))
        XCTAssertEqual(cell.running.map(\.id), ["bash-2955"])
        XCTAssertEqual(cell.settled, 3)
        XCTAssertEqual(cell.running[0].output.total, 0)
        XCTAssertNil(roster.cell("session-not-in-roster"), "缺席 = 没有活，不是未知")

        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.method, DSHClient.jobsRosterMethod)
        XCTAssertEqual(call.method, "_link/jobRoster")
        XCTAssertTrue(call.args.isEmpty, "连接器本地方法的参数是空对象")
    }

    /// G9（`test-coverage.md` §2）：缺 `sessions` 键 ≠ 空名单。
    /// 解成 `[:]` 会让"这次读不出名单"显示成"没有活"，正是 `link-job-roster.md` §4
    /// 不变式 3 禁止的降级；抛错后调用方才能整块隐藏。
    func testRosterWithoutSessionsKeyThrowsInsteadOfDecodingAnEmptyList() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/jobRoster"] = #"{"at":1791815149814}"#

        do {
            let roster = try await client(recorder).activityRoster()
            XCTFail("缺 sessions 键不得解成空名单，实际拿到 \(roster.sessions.count) 格")
        } catch {
            XCTAssertTrue(error is DecodingError, "缺必填键要以解码失败上抛，实际 \(error)")
        }

        XCTAssertEqual(recorder.calls.map(\.method), ["_link/jobRoster"], "名单请求确实发出去了")

        // 显式的空对象是合法的"一份空名单"：键在，值空。
        let empty = try JSONDecoder().decode(
            ActivityRoster.self,
            from: Data(#"{"at":1,"sessions":{}}"#.utf8)
        )
        XCTAssertTrue(empty.sessions.isEmpty, "键存在但为空仍可解码，与缺键区分")
    }

    // MARK: - 名单解码

    func testRosterDecodesPartialSessionsAndEmptyRunning() throws {
        let json = """
        {"at":1791815149814,
         "sessions":{
           "s-partial":{"running":[{"id":"bash-1","kind":"bash","label":"a","status":"running",
                                    "startedAt":1,"outputTotal":12,"outputLost":true}],"settled":0},
           "s-empty":{"running":[],"settled":7}
         }}
        """

        let roster = try JSONDecoder().decode(ActivityRoster.self, from: Data(json.utf8))

        XCTAssertEqual(roster.sessions.count, 2)
        XCTAssertEqual(roster.cell("s-partial")?.running.count, 1)
        XCTAssertEqual(roster.cell("s-partial")?.running[0].outputLost, true)
        XCTAssertTrue(roster.cell("s-partial")?.running[0].headOutputLost == true, "outputLost 折进头部丢失判定")
        XCTAssertEqual(roster.cell("s-empty")?.running, [])
        XCTAssertEqual(roster.cell("s-empty")?.settled, 7, "只有已结算任务的会话靠 settled 报数")
        XCTAssertNil(roster.cell("s-absent"))
    }

    func testRosterToleratesUnknownFieldsAndUnknownStatus() throws {
        let json = """
        {"at":1,"brandNewTopLevelField":{"x":1},
         "sessions":{"s1":{"running":[
           {"id":"bash-1","kind":"bash","label":"a","status":"paused","startedAt":1,
            "outputTotal":0,"progress":"42%","futureField":[1,2]},
           {"id":"bash-2","kind":"bash","label":"b","status":"stopping","startedAt":2,"outputTotal":0}
         ],"settled":1,"anotherNewField":true}}}
        """

        let roster = try JSONDecoder().decode(ActivityRoster.self, from: Data(json.utf8))
        let cell = try XCTUnwrap(roster.cell("s1"))

        XCTAssertEqual(cell.running.map(\.id), ["bash-1", "bash-2"])
        XCTAssertEqual(cell.running[0].status, .unknown("paused"))
        XCTAssertFalse(cell.running[0].status.isLive, "不认识的状态不猜成在跑")
        XCTAssertEqual(cell.running[0].progress, "42%")
        XCTAssertEqual(cell.liveJobs.map(\.id), ["bash-2"], "终态/未知状态不进在跑集合")
    }

    func testBadJobRowIsDroppedNotTheWholeList() throws {
        let json = """
        {"at":1,"sessions":{"s1":{"running":[
          {"kind":"bash","label":"没有 id","status":"running","startedAt":1,"outputTotal":0},
          {"id":"bash-9","kind":"bash","label":"好的那一行","status":"running","startedAt":2,"outputTotal":0}
        ],"settled":0}}}
        """

        let roster = try JSONDecoder().decode(ActivityRoster.self, from: Data(json.utf8))

        XCTAssertEqual(roster.cell("s1")?.running.map(\.id), ["bash-9"], "单行坏数据只丢那一行")
    }

    func testLinkJobsFrameDecodesFromThePushValue() throws {
        let json = """
        {"at":1791815149900,"sessionId":"s1",
         "running":[{"id":"bash-2955","kind":"bash","label":"pytest -q","status":"stopping",
                     "startedAt":1791815149814,"outputTotal":40,"owner":"s1"}],
         "settled":4}
        """

        let frame = try JSONDecoder().decode(LinkJobsFrame.self, from: Data(json.utf8))

        XCTAssertEqual(LinkJobsFrame.frameType, "link/jobs")
        XCTAssertEqual(frame.sessionId, "s1")
        XCTAssertEqual(frame.at, 1_791_815_149_900)
        XCTAssertEqual(frame.settled, 4)
        XCTAssertEqual(frame.liveJobs.map(\.id), ["bash-2955"], "stopping 仍算在跑")
        XCTAssertEqual(frame.liveJobs[0].status, .stopping)
    }

    // MARK: - 会话行（子智能体计时 + agentAvailable）

    func testSessionRowCarriesSubagentTimingAndAgentAvailability() throws {
        let json = """
        {"sessionId":"sub-1","updatedAt":1791815149814,"running":true,"blank":false,
         "parentSessionId":"parent-1","origin":"subagent","agentAvailable":true,
         "projections":{"asOfSeq":12,"values":{
           "subagent":{"mode":"continuable","label":"审查契约","seq":3},
           "subagentTiming":{"settledMs":4200,"active":{"since":1791815140000,"through":1791815149800},
                             "lastTurnCompleted":false}}}}
        """

        let row = try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))

        XCTAssertTrue(row.isSubagent)
        XCTAssertEqual(row.agentAvailable, true)
        XCTAssertEqual(row.subagentLabel, "审查契约")
        XCTAssertEqual(row.subagentMode, .continuable)
        XCTAssertTrue(row.isSubagentActive)
        XCTAssertEqual(row.subagentActiveSince, 1_791_815_140_000)
        XCTAssertEqual(row.subagentTiming?.settledMs, 4200)
        XCTAssertEqual(row.subagentTiming?.lastTurnCompleted, false)
    }

    func testSessionRowWithoutTimingIsNotActive() throws {
        let json = """
        {"sessionId":"sub-2","updatedAt":1,"running":true,"blank":false,
         "parentSessionId":"parent-1","origin":"subagent",
         "projections":{"asOfSeq":1,"values":{"subagent":{"mode":"one-shot"}}}}
        """

        let row = try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))

        XCTAssertFalse(row.isSubagentActive, "老宿主没有 subagentTiming：不拿 running 猜")
        XCTAssertNil(row.agentAvailable)
        XCTAssertEqual(row.subagentMode, .oneShot)
    }
}
