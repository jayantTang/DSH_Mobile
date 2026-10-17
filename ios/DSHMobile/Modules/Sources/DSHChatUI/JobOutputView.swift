#if os(iOS)
import DSHCore
import DSHDesign
import DSHKit
import SwiftUI

/// 一个后台任务的输出页（018 §3）。
///
/// 命令固定在顶部，输出自己滚；`lossy` / `gapBefore` / `outputLost` 必须显式提示，
/// 空输出有明确空态。展开才订阅（`job/follow`），收起即退订。
public struct JobOutputView: View {
    let sessionId: String
    let job: Job

    @MainActor private var activity: ActivityModel { .shared }

    public init(sessionId: String, job: Job) {
        self.sessionId = sessionId
        self.job = job
    }

    public var body: some View {
        VStack(spacing: 0) {
            commandHeader
            Hairline()
            notices
            content(for: activity.outputFeed)
        }
        .background(DSHTheme.background)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("输出")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { activity.openOutput(sessionId: sessionId, job: job) }
        .onDisappear { activity.closeOutput() }
        .accessibilityIdentifier("activity.output.panel")
    }

    /// 命令固定顶部：滚输出时它不跟着走。
    private var commandHeader: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: ActivitySheet.icon(for: job.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DSHTheme.brand)
            Text(job.label)
                .font(DSHTheme.Typography.code)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.vertical, DSHTheme.Spacing.tight)
        .background(DSHTheme.layer1)
        .accessibilityIdentifier("activity.output.command")
    }

    @ViewBuilder
    private var notices: some View {
        if job.headOutputLost {
            warning("更早的输出已被丢弃")
        } else if activity.outputFeed?.outputLost == true {
            warning("更早的输出已被丢弃")
        }
        if activity.outputFeed?.isLossy == true {
            warning("中间有一段输出被丢弃")
        }
    }

    private func warning(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(DSHTheme.Typography.micro)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DSHTheme.labelSecondary)
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.vertical, DSHTheme.Spacing.hairline)
    }

    @ViewBuilder
    private func content(for feed: ActivityModel.OutputFeed?) -> some View {
        if let feed, !feed.chunks.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                    ForEach(Array(feed.chunks.enumerated()), id: \.offset) { _, chunk in
                        if chunk.gapBefore == true {
                            Text("中间有一段输出被丢弃")
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.labelTertiary)
                                .padding(.vertical, 2)
                        }
                        Text(chunk.text)
                            .font(DSHTheme.Typography.code)
                            .foregroundStyle(chunk.channel == .stderr ? DSHTheme.labelSecondary : DSHTheme.labelPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let detail = feed.detail, !detail.isEmpty {
                        Text(detail)
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .padding(.top, DSHTheme.Spacing.tight)
                    }
                }
                .padding(DSHTheme.Spacing.loose)
            }
            .defaultScrollAnchor(.bottom)
        } else if let error = feed?.error {
            ErrorStateView(message: error)
        } else if feed?.isFinished == true {
            EmptyStateView(
                icon: "text.alignleft",
                title: String(localized: "还没有输出"),
                message: String(localized: "这个任务没有产生任何输出。")
            )
        } else if feed?.hasOpened == true {
            // 开了流但暂时没有输出：不要一直转圈（owner 2026-10-17 报过"等了几秒仍在加载"）。
            EmptyStateView(
                icon: "text.alignleft",
                title: String(localized: "还没有输出"),
                message: String(localized: "任务还在跑，有输出会自动出现。")
            )
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
