import XCTest

@testable import DSHKit

/// git 失败分类与分页合并的用例（spec 023 / S3a）。
///
/// 这两块原来在 App 里、且**一条测试都没有**：分类表是"错误码 → 界面状态与话术"的判定，
/// 分页规则是"reset 与续读"的判定。搬进 DSHKit 的直接收益就是它们第一次有了断言。
final class GitFailureClassifierTests: XCTestCase {

    private func kind(_ code: String) -> GitFailureKind {
        GitFailureClassifier.classify(code: code, message: "宿主原文")
    }

    func testKnownGitCodesMapToTheirOwnKind() {
        XCTAssertEqual(kind("git/not-a-repo"), .notARepository)
        XCTAssertEqual(kind("git/no-commits"), .emptyRepository)
        XCTAssertEqual(kind("git/unavailable"), .gitUnavailable)
        XCTAssertEqual(kind("git/too-large"), .tooLarge)
        XCTAssertEqual(kind("git/timed-out"), .timedOut)
    }

    func testHostMessageSurvivesForNotFoundAndBadRequest() {
        // 这两种要把宿主的原文透给用户，不能被折成固定话术。
        XCTAssertEqual(kind("git/not-found"), .message("宿主原文"))
        XCTAssertEqual(kind("git/bad-request"), .message("宿主原文"))
    }

    func testGatewayCodesMeanTheConnectorIsTooOld() {
        for code in ["gateway/bad-response", "gateway/not-found", "unknown",
                     "gateway/unknown-method", "host/unavailable"] {
            XCTAssertEqual(kind(code), .unsupported, "\(code) 应当是「连接器太旧」，不是 git 问题")
        }
    }

    func testUnknownCodesFallBackToTheHostMessage() {
        // 不认识的码**不许**伪装成已知种类：把原文透出去，界面上才看得见真相。
        XCTAssertEqual(kind("git/some-new-code"), .message("宿主原文"))
        XCTAssertEqual(kind("git/"), .message("宿主原文"))
    }

    func testTransportErrorsAreNotClassified() {
        struct Boom: Error {}
        XCTAssertNil(GitFailureClassifier.classify(Boom()),
                     "传输类失败要由调用方按「电脑不应答」处理，不能被装扮成「不是仓库」")
    }

    func testDSHRPCFailureIsClassifiedThroughItsCode() {
        let failure = DSHRPCFailure(code: "git/not-a-repo", message: "nope")
        XCTAssertEqual(GitFailureClassifier.classify(failure), .notARepository)
    }

    // MARK: - 分页

    /// `GitCommit` 只有 `init(from:)`（它是宿主 JSON 的 DTO，没有 memberwise init），
    /// 所以夹具走一次解码——只给 `sha`，其余字段由解码器的默认值补上。
    private func commit(_ sha: String) -> GitCommit {
        let json = #"{"sha":"\#(sha)"}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(GitCommit.self, from: Data(json.utf8))
    }

    func testResetReplacesTheWholePage() {
        let merged = GitLogPaging.merge([commit("a"), commit("b")], page: [commit("c")], reset: true)
        XCTAssertEqual(merged.map(\.sha), ["c"])
    }

    func testAppendKeepsWhatWasThereAndAddsThePage() {
        let merged = GitLogPaging.merge([commit("a"), commit("b")], page: [commit("c"), commit("d")], reset: false)
        XCTAssertEqual(merged.map(\.sha), ["a", "b", "c", "d"])
    }

    func testSkipFollowsTheSameSwitchAsMerge() {
        // 两条规则必须始终一致：reset 时从头（0），续读时从已有条数之后。
        let existing = [commit("a"), commit("b"), commit("c")]
        XCTAssertEqual(GitLogPaging.skip(existing: existing, reset: true), 0)
        XCTAssertEqual(GitLogPaging.skip(existing: existing, reset: false), 3)
        XCTAssertEqual(GitLogPaging.skip(existing: [], reset: false), 0)
    }

    func testEmptyPageIsHarmless() {
        XCTAssertEqual(GitLogPaging.merge([commit("a")], page: [], reset: false).map(\.sha), ["a"])
        XCTAssertEqual(GitLogPaging.merge([commit("a")], page: [], reset: true).count, 0)
    }
}
