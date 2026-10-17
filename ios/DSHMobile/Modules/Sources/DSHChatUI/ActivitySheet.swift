#if os(iOS)
import DSHCore
import DSHDesign
import DSHKit
import SwiftUI

/// 活动面板（半屏 sheet）：运行中的任务与子智能体、已结束计数。
///
/// 018 §3：只读 `ActivityModel`（判定在 DSHKit 的 `ActivityStore`），这里不自行
/// 推断任何状态。停止是三级灰小字、无边框无底色，两段确认：第一下只变红，
/// 3 秒内再按一次才发请求；**不乐观改状态**，行等名单回流。
public struct ActivitySheet: View {
    let sessionId: String
    var onOpenSession: ((String) -> Void)?

    @MainActor private var activity: ActivityModel { .shared }
    /// 第一下按过的「停止」：3 秒内第二下才真发。
    @State private var armedStop: String?
    @State private var disarmTask: Task<Void, Never>?
    @State private var outputJob: Job?
    /// 「已结束」段是否展开（owner 2026-10-17）。
    @State private var showsSettled = false
    /// 无人值守截图用：`activity-output` 时自动展开第一个在跑任务的输出（DEBUG 钩子传入）。
    private let automation: String?

    public init(sessionId: String, onOpenSession: ((String) -> Void)? = nil, automation: String? = nil) {
        self.sessionId = sessionId
        self.onOpenSession = onOpenSession
        self.automation = automation
        // 截图入口（`-DSHOpenScreen activity-settled`）默认展开「已结束」，人用默认折叠。
        _showsSettled = State(initialValue: automation == "activity-settled")
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.loose) {
                    header
                    subtitle
                    if activity.lastKnown { lastKnownBanner }
                    if let notice = activity.notice {
                        Text(notice)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                            .accessibilityIdentifier("activity.notice")
                    }
                    runningSection
                    settledSection
                }
                .padding(.horizontal, DSHTheme.Spacing.loose)
                .padding(.vertical, DSHTheme.Spacing.standard)
            }
            .background(DSHTheme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $outputJob) { job in
                JobOutputView(sessionId: sessionId, job: job)
            }
        }
        .accessibilityIdentifier("activity.sheet")
        .onDisappear { activity.clearNotice() }
        .task {
            #if DEBUG
            // 名单可能比这张 sheet 晚到：最多等 10 秒，出现第一个在跑任务就推进输出页。
            if automation == "activity-settled" {
                showsSettled = true
                await activity.loadSettledJobs(sessionId: sessionId)
                return
            }
            guard automation == "activity-output" else { return }
            for _ in 0..<40 {
                if outputJob != nil { return }
                if let first = activity.liveJobs(sessionId: sessionId).first {
                    outputJob = first
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            #endif
        }
    }

    /// 设计稿（`018-ui-v2-b.png` ⑤）：左对齐小标题，不用导航栏的居中大标题。
    private var header: some View {
        Text("任务与子智能体")
            .font(DSHTheme.Typography.title)
            .foregroundStyle(DSHTheme.labelPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: some View {
        Text("关掉面板不影响它们继续跑；跑完了会推通知。")
            .font(DSHTheme.Typography.caption)
            .foregroundStyle(DSHTheme.labelSecondary)
    }

    private var lastKnownBanner: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 10, weight: .medium))
            Text("上次已知")
                .font(DSHTheme.Typography.micro)
        }
        .foregroundStyle(DSHTheme.labelTertiary)
        .accessibilityIdentifier("activity.lastKnown")
    }

    // MARK: - 运行中

    private var children: [SessionSummary] { activity.children(of: sessionId) }
    private var jobs: [Job] { activity.liveJobs(sessionId: sessionId) }

    @ViewBuilder
    private var runningSection: some View {
        PanelSection(String(localized: "运行中")) {
            VStack(spacing: DSHTheme.Spacing.hairline) {
                if children.isEmpty && jobs.isEmpty {
                    Text("没有正在运行的任务")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DSHTheme.Spacing.standard)
                        .background(DSHTheme.layer2, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                }
                ForEach(children) { child in
                    childRow(child)
                }
                ForEach(jobs) { job in
                    jobRow(job)
                }
            }
        }
    }

    private func childRow(_ child: SessionSummary) -> some View {
        let isContinuable = child.subagentMode == .continuable
        return VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "person.2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DSHTheme.brand)
                    .frame(width: 16)
                Text(child.subagentLabel ?? child.sessionId)
                    .accessibilityIdentifier("activity.row.\(child.sessionId)")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let since = child.subagentActiveSince {
                    elapsed(since: since)
                }
                if isContinuable {
                    stopControl(id: child.sessionId) {
                        Task {
                            await activity.stopSubagent(
                                childSessionId: child.sessionId,
                                parentSessionId: sessionId
                            )
                        }
                    }
                }
            }
            Text(isContinuable
                 ? String(localized: "子智能体 · 可持续")
                 : String(localized: "子智能体 · 一次性，随本轮一起结束"))
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .padding(.leading, 24)
            Button {
                onOpenSession?(child.sessionId)
            } label: {
                Text("打开子会话 ›")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.brand)
            }
            .buttonStyle(.plain)
            .padding(.leading, 24)
            .accessibilityIdentifier("activity.open.\(child.sessionId)")
        }
        .padding(DSHTheme.Spacing.standard)
        .background(DSHTheme.layer2, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        // 不在这层挂 identifier：容器上的 id 会下传给子元素，把里面的
        // 「停止」「打开子会话」的 id 覆盖掉（仓库既有坑）。行的锚点挂在标题上。
    }

    private func jobRow(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: Self.icon(for: job.kind))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DSHTheme.brand)
                    .frame(width: 16)
                Text(job.label)
                    .accessibilityIdentifier("activity.row.\(job.id)")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                elapsed(since: job.startedAt)
                stopControl(id: job.id) {
                    Task { await activity.killJob(sessionId: sessionId, jobId: job.id) }
                }
            }
            // 类型标识（owner 2026-10-17：看不出在跑的是任务还是子智能体）。
            Text("后台任务 · \(Self.statusText(job.status))")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .padding(.leading, 24)
            if let progress = job.progress, !progress.isEmpty {
                Text(progress)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
            } else if let detail = job.detail, !detail.isEmpty {
                Text(detail)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
            Button {
                outputJob = job
            } label: {
                Text("查看输出 ›")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.brand)
            }
            .buttonStyle(.plain)
            .padding(.leading, 24)
            .accessibilityIdentifier("activity.output.\(job.id)")
        }
        .padding(DSHTheme.Spacing.standard)
        .background(DSHTheme.layer2, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        
    }

    // MARK: - 已结束

    @ViewBuilder
    /// 已结束：默认折叠成一行；展开后逐条列出"哪些结束了、为什么结束"。
    ///
    /// owner 2026-10-17：点进来看得见"是已结束还是运行中"。明细不在名单帧里
    ///（帧只带活任务 + 计数），所以展开时向宿主读一次 `job/list`。
    private var settledSection: some View {
        let settled = activity.settledCount(sessionId: sessionId)
        let finishedChildren = activity.finishedChildren(parentSessionId: sessionId)
        if settled > 0 || !finishedChildren.isEmpty {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                HStack(spacing: DSHTheme.Spacing.tight) {
                    Button {
                        showsSettled.toggle()
                        if showsSettled { Task { await activity.loadSettledJobs(sessionId: sessionId) } }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showsSettled ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DSHTheme.labelTertiary)
                            Text("已结束 \(settled) 个")
                                .font(DSHTheme.Typography.caption)
                                .foregroundStyle(DSHTheme.labelSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("activity.settledToggle")
                    Spacer(minLength: 0)
                    Button {
                        activity.clearSettled(sessionId: sessionId)
                    } label: {
                        Text("清除")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.brand)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("activity.clearSettled")
                }

                if showsSettled {
                    // 首帧可能比连接早到（client 还没挂上），展开后补读一次。
                    Color.clear
                        .frame(height: 0)
                        .onAppear {
                            guard activity.settledJobs.isEmpty else { return }
                            Task { await activity.loadSettledJobs(sessionId: sessionId) }
                        }
                    if activity.isLoadingSettled {
                        Text("正在读取已结束的任务…")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                    ForEach(activity.settledJobs) { job in
                        Button {
                            outputJob = job
                        } label: {
                            settledRow(kind: "task", label: job.label,
                                       detail: job.detail ?? ActivitySheet.statusText(job.status),
                                       id: job.id,
                                       hint: "查看输出 ›")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(finishedChildren) { child in
                        Button {
                            onOpenSession?(child.sessionId)
                        } label: {
                            settledRow(kind: "child",
                                       label: child.subagentLabel ?? child.sessionId,
                                       detail: "子智能体 · 已结束",
                                       id: child.sessionId,
                                       hint: "打开子会话 ›")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(DSHTheme.Spacing.standard)
            .background(DSHTheme.layer2, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        }
    }

    private func settledRow(kind: String, label: String, detail: String, id: String, hint: String) -> some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: kind == "child" ? "person.2" : "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DSHTheme.labelTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .lineLimit(1)
                Text(detail)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                    .lineLimit(1)
                Text(hint)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.brand)
            }
            Spacer(minLength: 0)
            Text("已结束")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
        }
        .padding(.leading, 4)
        .accessibilityIdentifier("activity.settled.\\(id)")
    }

    /// 终态文案（与桌面端同一套说法）。
    static func statusText(_ status: JobStatus) -> String {
        switch status {
        case .completed: return String(localized: "已完成")
        case .killed: return String(localized: "已取消")
        case .failed: return String(localized: "已失败")
        case .stopping: return String(localized: "正在停止")
        case .running: return String(localized: "运行中")
        case .unknown: return String(localized: "已结束")
        }
    }

    // MARK: - Pieces

    private func elapsed(since: Double) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(ActivityDuration.clock(sinceMilliseconds: since))
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .monospacedDigit()
        }
    }

    /// 三级灰小字、无边框无底色。第一下只把字变红，3 秒内再按才发请求。
    private func stopControl(id: String, action: @escaping () -> Void) -> some View {
        let armed = armedStop == id
        return Button {
            if armed {
                armedStop = nil
                disarmTask?.cancel()
                action()
            } else {
                armedStop = id
                disarmTask?.cancel()
                disarmTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled, armedStop == id { armedStop = nil }
                }
            }
        } label: {
            Text(armed ? "再按一次停止" : "停止")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(armed ? DSHTheme.danger : DSHTheme.labelTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.stop.\(id)")
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "bash", "terminal": return "terminal"
        case "workflow": return "square.stack.3d.up"
        case "subagent": return "person.2"
        default: return "gearshape.2"
        }
    }
}

/// 已跑时长的显示：`mm:ss`，超过一小时给 `h:mm:ss`。
enum ActivityDuration {
    static func clock(sinceMilliseconds: Double, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince1970 * 1000 - sinceMilliseconds)
        let total = Int(elapsed / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
#endif
