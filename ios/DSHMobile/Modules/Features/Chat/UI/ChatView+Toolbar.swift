#if os(iOS)
@_exported import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHDesign
import DSHFoundation
import DSHKit
import SwiftUI

// MARK: - Toolbar（自 ChatView.swift 拆出，026 P4）
//
// 扩展里的成员与主文件同模块，`private` 降为 internal 才能跨文件访问；
// 工具栏只读 model/store 状态，不改交互逻辑。

extension ChatView {
    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // 018 §2：入口常驻。owner 2026-10-17：原来是个"有活才出现"的蓝点，
            // 任务一结束按钮就没了，已结束的任务与子智能体再也看不到；而且蓝点看不出
            // 它代表什么。改为一个固定的列表图标（=任务清单），有活时在旁边加计数。
            if isActivityEntryVisible {
                Button {
                    isShowingActivity = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(activity.activeCount > 0 ? DSHTheme.brand : DSHTheme.labelSecondary)
                            .accessibilityIdentifier("chat.running")
                        if activity.activeCount > 0 {
                            Text("\(activity.activeCount)")
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.brand)
                                .monospacedDigit()
                                .accessibilityIdentifier("chat.activity.count")
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.activity")
                .accessibilityLabel("任务与子智能体")
            } else if model.isRunning {
                StatusDot(level: .busy, size: 7, animated: true)
                    .accessibilityIdentifier("chat.running")
                    .accessibilityLabel("运行中")
            }

            Button {
                isSearching = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityIdentifier("chat.search")
            .accessibilityLabel("在本会话里搜索")

            Button {
                isShowingInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityIdentifier("chat.info")
            .accessibilityLabel("会话信息")
            .popover(isPresented: $isShowingInfo, arrowEdge: .top) {
                SessionInfoPopover(model: model, home: store.hostHome)
                    .presentationCompactAdaptation(.popover)
            }

            Menu {
                Button {
                    isShowingModelPicker = true
                } label: {
                    Label("选择模型", systemImage: "cpu")
                }
                if let session = model.session, let onOpenFiles {
                    Button {
                        onOpenFiles(session)
                    } label: {
                        Label("工作区文件", systemImage: "folder")
                    }
                }
                Divider()
                Button {
                    renameText = model.session?.displayTitle ?? ""
                    isRenaming = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button {
                    // The fork lands as a new session; the list picks it up from
                    // the host's session-added event, so nothing else to do here.
                    Task { _ = await model.fork() }
                } label: {
                    Label("从此处分叉", systemImage: "arrow.triangle.branch")
                }
                if let onOpenWeb, let base = store.activeBaseURL {
                    Divider()
                    Button {
                        onOpenWeb(base)
                    } label: {
                        Label("用网页界面打开", systemImage: "safari")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("chat.more")
            .accessibilityLabel("更多")
        }
    }
}
#endif
