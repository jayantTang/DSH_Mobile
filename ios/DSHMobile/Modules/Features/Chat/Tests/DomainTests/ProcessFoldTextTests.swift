@testable import DSHChatDomain
import DSHKit
import XCTest

/// 过程折叠的文案口径：与桌面 `TurnProcessNodeView` / `processTitle` /
/// `RunningStatus` 逐条对齐（设计 `20261025-过程折叠-对齐桌面` §2.1–§2.3）。
final class ProcessFoldTextTests: XCTestCase {

    // MARK: - 轮次行文案

    func test_completed_turn_shows_duration_in_minutes_and_seconds() {
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "completed", duration: 99),
                       "已完成，用时 1分39秒")
    }

    func test_completed_turn_shows_duration_in_seconds_only_below_a_minute() {
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "completed", duration: 18),
                       "已完成，用时 18秒")
    }

    func test_completed_turn_without_duration_says_only_completed() {
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "completed", duration: nil), "已完成")
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "completed", duration: 0), "已完成")
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: nil, duration: nil), "已完成")
    }

    func test_duration_is_floored_and_clamped_to_at_least_one_second() {
        // 桌面 `Math.max(1000, elapsed)`：不足一秒也不写 0秒。
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "completed", duration: 0.2),
                       "已完成，用时 1秒")
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "completed", duration: 1.7),
                       "已完成，用时 1秒")
    }

    func test_error_turn_says_failed_and_shows_no_duration() {
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "error", duration: 99), "处理失败")
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "failed", duration: nil), "处理失败")
    }

    func test_stopped_turn_says_stopped_and_shows_no_duration() {
        for reason in ["aborted", "interrupted", "cancelled", "canceled"] {
            XCTAssertEqual(ProcessFoldText.turnLabel(endReason: reason, duration: 12), "已停止", reason)
            XCTAssertTrue(ProcessFoldText.isStopped(reason), reason)
            XCTAssertFalse(ProcessFoldText.isFailed(reason), reason)
        }
    }

    func test_max_steps_is_a_normal_completion_and_never_mentions_the_step_cap() {
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "max-steps", duration: 12),
                       "已完成，用时 12秒")
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "max-steps", duration: nil), "已完成")
        XCTAssertFalse(ProcessFoldText.isStopped("max-steps"))
        XCTAssertFalse(ProcessFoldText.isFailed("max-steps"))
    }

    func test_unknown_end_reason_is_treated_as_a_normal_completion() {
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "done", duration: 5), "已完成，用时 5秒")
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: "unknown", duration: nil), "已完成")
    }

    // MARK: - 分组行标题

    func test_group_title_of_one_activity_class_has_no_count() {
        for count in [1, 3, 14] {
            XCTAssertEqual(ProcessFoldText.groupTitle([.read: count]), "已读取文件")
        }
        XCTAssertEqual(ProcessFoldText.groupTitle([.commands: 14]), "执行了命令")
    }

    func test_group_title_of_two_classes_joins_with_bing_and_shares_the_prefix_once() {
        XCTAssertEqual(ProcessFoldText.groupTitle([.read: 2, .search: 1]),
                       "已读取文件并搜索代码")
    }

    func test_group_title_of_two_classes_keeps_the_prefix_when_only_one_has_it() {
        // 桌面只在 first 与 second **都**以「已」开头时才切掉 second 的那一次。
        XCTAssertEqual(ProcessFoldText.groupTitle([.commands: 2, .read: 1]),
                       "执行了命令并已读取文件")
        XCTAssertEqual(ProcessFoldText.groupTitle([.edit: 2, .commands: 1]),
                       "修改了文件并执行了命令")
    }

    func test_group_title_of_three_classes_joins_with_commas_and_keeps_each_prefix() {
        // 桌面 `processTitle`：三类以上只做首字母小写，不去「已」前缀。
        XCTAssertEqual(ProcessFoldText.groupTitle([.commands: 3, .read: 2, .questions: 2]),
                       "执行了命令，已读取文件，向用户提出了问题")
    }

    func test_group_title_of_four_classes_ends_with_deng() {
        XCTAssertEqual(ProcessFoldText.groupTitle([.commands: 3, .read: 2,
                                                  .questions: 2, .search: 1]),
                       "执行了命令，已读取文件，向用户提出了问题等")
    }

    func test_group_title_without_activity_says_analysis_completed() {
        XCTAssertEqual(ProcessFoldText.groupTitle([:]), "已完成分析")
    }

    func test_group_title_ranks_by_count_and_is_deterministic_on_ties() {
        // 次数优先；同次数按活动类别的固定顺序，保证同一份数据每次渲染同一句。
        XCTAssertEqual(ProcessFoldText.groupTitle([.read: 1, .commands: 2]),
                       "执行了命令并已读取文件")
        XCTAssertEqual(ProcessFoldText.groupTitle([.read: 1, .commands: 1]),
                       "已读取文件并执行了命令")
    }

    func test_top_activity_follows_the_same_ranking() {
        XCTAssertEqual(ProcessFoldText.topActivity([.search: 1, .read: 4]), .read)
        XCTAssertNil(ProcessFoldText.topActivity([:]))
    }

    // MARK: - 运行中

    func test_running_group_title_reads_running_plus_the_current_command() {
        XCTAssertEqual(ProcessFoldText.runningGroupTitle(activity: .commands,
                                                          detail: "go test ./internal/relay"),
                       "正在运行命令 · go test ./internal/relay")
    }

    func test_running_group_title_without_a_detail_is_only_the_verb() {
        XCTAssertEqual(ProcessFoldText.runningGroupTitle(activity: .read, detail: ""),
                       "正在读取文件")
    }

    func test_running_group_title_without_an_activity_says_analysing() {
        XCTAssertEqual(ProcessFoldText.runningGroupTitle(activity: nil, detail: ""),
                       "正在分析请求")
    }

    func test_deep_diving_line_reports_the_elapsed_time() {
        XCTAssertEqual(ProcessFoldText.deepDivingText(elapsed: 12), "深度求索中，用时 12秒 ···")
        XCTAssertEqual(ProcessFoldText.deepDivingText(elapsed: 99), "深度求索中，用时 1分39秒 ···")
        XCTAssertEqual(ProcessFoldText.deepDivingText(elapsed: nil), "深度求索中")
    }

    // MARK: - 步骤卡（概要 v2）

    func test_a_step_card_names_thinking_and_keeps_tool_names() {
        XCTAssertEqual(ProcessFoldText.stepTitle(kind: .reasoning, name: "thinking"), "思考")
        XCTAssertEqual(ProcessFoldText.stepTitle(kind: .tools, name: "bash"), "bash",
                       "工具名是协议名，不翻译")
    }

    func test_a_step_card_shows_the_output_size_and_the_entry() {
        XCTAssertEqual(ProcessFoldText.stepOutputHint(bytes: 900, body: nil),
                       "输出 900 B · 点开查看")
        XCTAssertEqual(ProcessFoldText.stepOutputHint(bytes: 2048, body: .failed),
                       "输出加载失败 · 点按重试")
        XCTAssertEqual(ProcessFoldText.stepOutputHint(
            bytes: 900, body: .loaded(text: "BUILD OK", bytes: 8)),
                       "输出 900 B · 点开查看")
        XCTAssertEqual(ProcessFoldText.stepOutputHint(bytes: nil, body: .loading),
                       "输出 — · 点开查看", "大小未知不编一个 0")
    }

    func test_an_oversized_step_is_terminal_and_offers_no_retry() {
        XCTAssertEqual(ProcessFoldText.stepOutputHint(bytes: 4 * 1024 * 1024, body: .tooLarge),
                       "输出过大，无法在手机上展开")
    }

    func test_a_thinking_step_only_reports_its_size() {
        XCTAssertEqual(ProcessFoldText.thinkingStepHint(bytes: 1500), "思考 · 1.5 KB")
        XCTAssertEqual(ProcessFoldText.thinkingStepHint(bytes: nil), "思考 · —")
    }

    func test_byte_counts_are_readable_and_bounded() {
        XCTAssertEqual(ProcessFoldText.byteCountText(900), "900 B")
        XCTAssertEqual(ProcessFoldText.byteCountText(1024), "1.0 KB")
        XCTAssertEqual(ProcessFoldText.byteCountText(1536), "1.5 KB")
        XCTAssertEqual(ProcessFoldText.byteCountText(1024 * 1024), "1.0 MB")
        XCTAssertEqual(ProcessFoldText.byteCountText(nil), "—")
    }

    // MARK: - 活动图标

    func test_every_activity_has_a_visible_icon() {
        let icons = TimelineProcessActivity.allCases.map(ProcessFoldText.activityIcon)
        XCTAssertEqual(Set(icons).count, icons.count, "each activity needs its own glyph: \(icons)")
        XCTAssertFalse(icons.contains(""))
    }
}
