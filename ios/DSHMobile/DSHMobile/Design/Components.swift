import SwiftUI

/// A small filled status dot, used for connection and run state.
struct StatusDot: View {
    enum Level {
        case ok, busy, attention, error, idle
        /// Finished since this phone last showed it — a ring rather than a
        /// filled dot, so "waiting for you" and "working right now" are told
        /// apart at a glance and by shape, not only by colour.
        case unseen

        var color: Color {
            switch self {
            case .ok: return DSHTheme.success
            case .busy, .unseen: return DSHTheme.brand
            case .attention: return DSHTheme.attention
            case .error: return DSHTheme.danger
            case .idle: return DSHTheme.labelDimmed
            }
        }
    }

    let level: Level
    var size: CGFloat = 8
    /// Pulses while work is in flight, so a glance tells you it is alive.
    var animated: Bool = false

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(level == .unseen ? .clear : level.color)
            .overlay {
                if level == .unseen {
                    Circle().strokeBorder(level.color, lineWidth: 1.5)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                if animated {
                    Circle()
                        .stroke(level.color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 2.1 : 1)
                        .opacity(pulse ? 0 : 0.9)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }
            }
            .onAppear { if animated { pulse = true } }
            .accessibilityHidden(true)
    }
}

/// A compact label, used for counts and states.
struct Badge: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone {
        case neutral, brand, success, attention, danger

        var foreground: Color {
            switch self {
            case .neutral: return DSHTheme.labelSecondary
            case .brand: return DSHTheme.brand
            case .success: return DSHTheme.success
            case .attention: return DSHTheme.attention
            case .danger: return DSHTheme.danger
            }
        }

        var background: Color { foreground.opacity(0.13) }
    }

    var body: some View {
        Text(text)
            .font(DSHTheme.Typography.micro)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.background, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
    }
}

/// A hairline that matches the desktop client's panel separators.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(DSHTheme.border1)
            .frame(height: 1)
    }
}

/// A titled group of rows, echoing the desktop client's panel sections.
struct PanelSection<Content: View>: View {
    let title: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            if title != nil || accessory != nil {
                HStack(spacing: DSHTheme.Spacing.tight) {
                    if let title {
                        Text(title)
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .textCase(.uppercase)
                    }
                    Spacer(minLength: 0)
                    if let accessory { accessory }
                }
                .padding(.horizontal, DSHTheme.Spacing.loose)
            }
            content
        }
    }
}

/// The standard empty state: one line of why, one line of what to do.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (title: String, handler: () -> Void)?

    var body: some View {
        VStack(spacing: DSHTheme.Spacing.standard) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DSHTheme.labelTertiary)
            VStack(spacing: DSHTheme.Spacing.hairline) {
                Text(title)
                    .font(DSHTheme.Typography.bodyStrong)
                    .foregroundStyle(DSHTheme.labelPrimary)
                Text(message)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button(action.title, action: action.handler)
                    .buttonStyle(.borderedProminent)
                    .tint(DSHTheme.brand)
            }
        }
        .padding(DSHTheme.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The standard failure state, always offering a retry.
struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: DSHTheme.Spacing.standard) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DSHTheme.danger)
            Text(message)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(.bordered)
                    .tint(DSHTheme.brand)
            }
        }
        .padding(DSHTheme.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A thin determinate progress bar for context pressure.
struct PressureBar: View {
    let fraction: Double
    var height: CGFloat = 3

    private var tone: Color {
        switch fraction {
        case ..<0.5: return DSHTheme.usageLow
        case ..<0.8: return DSHTheme.usageMid
        default: return DSHTheme.usageHigh
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DSHTheme.border2)
                Capsule()
                    .fill(tone)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .accessibilityLabel("上下文占用 \(Int(fraction * 100))%")
    }
}

/// A tappable row used across the session list and pickers.
struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .fill(isSelected ? DSHTheme.brandSubtle : .clear)
            )
            .contentShape(Rectangle())
    }
}

/// Formats an absolute path relative to the host's home directory.
///
/// The desktop client abbreviates paths this way; matching it keeps the two
/// clients readable side by side.
enum PathFormat {
    static func short(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func directory(_ path: String, home: String?) -> String {
        (short(path, home: home) as NSString).lastPathComponent
    }
}

/// Formats token counts the way the desktop client does.
enum TokenFormat {
    static func compact(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1_000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}

/// A relative timestamp, kept short for dense rows.
enum RelativeTime {
    static func string(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3_600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3_600)) 小时前" }
        if interval < 604_800 { return "\(Int(interval / 86_400)) 天前" }
        // Only the long tail needs calendar-aware phrasing, so the formatter is
        // built here rather than shared: `RelativeDateTimeFormatter` is not
        // `Sendable`, and a shared instance would need synchronization for a
        // path this cold.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
