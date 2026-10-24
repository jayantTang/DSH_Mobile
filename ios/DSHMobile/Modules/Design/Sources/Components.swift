import SwiftUI

/// A small filled status dot, used for connection and run state.
public struct StatusDot: View {
    public enum Level {
        case ok, busy, attention, error, idle
        /// Finished since this phone last showed it.
        ///
        /// Green, and the only green in the list: blue means "working right
        /// now", green means "done, and you have not looked". It used to be a
        /// blue ring, which differed from the running dot by shape alone —
        /// nobody reads a ring as a different state, and the green that used to
        /// mark *read* rows made the list a wall of green with no signal left.
        case unseen

        var color: Color {
            switch self {
            case .ok: return DSHTheme.success
            case .busy: return DSHTheme.brand
            case .unseen: return DSHTheme.success
            case .attention: return DSHTheme.attention
            case .error: return DSHTheme.danger
            case .idle: return DSHTheme.labelDimmed
            }
        }
    }

    public let level: Level
    public var size: CGFloat = 8
    public init(level: Level, size: CGFloat = 8, animated: Bool = false) {
        self.level = level
        self.size = size
        self.animated = animated
    }
    /// Pulses while work is in flight, so a glance tells you it is alive.
    public var animated: Bool = false

    @State private var pulse = false

    public var body: some View {
        Circle()
            .fill(level.color)
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
public struct Badge: View {
    public let text: String
    public var tone: Tone = .neutral
    public init(text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public enum Tone {
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

    public var body: some View {
        // `text` is a `String`, so `Text(text)` would be verbatim and never reach
        // Localizable.strings — every badge would read Chinese on an English
        // phone. Looking the value up (and falling back to it unchanged) keeps
        // data-shaped badges (`Badge(text: ref)`, byte counts) behaving the same.
        Text(String(localized: String.LocalizationValue(text)))
            .font(DSHTheme.Typography.micro)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.background, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
    }
}

/// A hairline that matches the desktop client's panel separators.
public struct Hairline: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(DSHTheme.border1)
            .frame(height: 1)
    }
}

/// A titled group of rows, echoing the desktop client's panel sections.
public struct PanelSection<Content: View>: View {
    public let title: String?
    public var accessory: AnyView?
    @ViewBuilder var content: Content

    public init(_ title: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    public var body: some View {
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
public struct EmptyStateView: View {
    public let icon: String
    public let title: String
    public let message: String
    public var action: (title: String, handler: () -> Void)?
    public init(icon: String, title: String, message: String, action: (title: String, handler: () -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
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
public struct ErrorStateView: View {
    public let message: String
    public var retry: (() -> Void)?
    public init(message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
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
public struct PressureBar: View {
    public let fraction: Double
    public var height: CGFloat = 3
    public init(fraction: Double, height: CGFloat = 3) {
        self.fraction = fraction
        self.height = height
    }

    private var tone: Color {
        switch fraction {
        case ..<0.5: return DSHTheme.usageLow
        case ..<0.8: return DSHTheme.usageMid
        default: return DSHTheme.usageHigh
        }
    }

    public var body: some View {
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
public struct SelectableRow<Content: View>: View {
    public let isSelected: Bool
    @ViewBuilder var content: Content

    public init(isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    public var body: some View {
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
/// Formats token counts the way the desktop client does.
public enum TokenFormat {
    public static func compact(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1_000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}

/// A relative timestamp, kept short for dense rows.
public enum RelativeTime {
    public static func string(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "刚刚") }
        if interval < 3_600 { return String(localized: "\(Int(interval / 60)) 分钟前") }
        if interval < 86_400 { return String(localized: "\(Int(interval / 3_600)) 小时前") }
        if interval < 604_800 { return String(localized: "\(Int(interval / 86_400)) 天前") }
        // Only the long tail needs calendar-aware phrasing, so the formatter is
        // built here rather than shared: `RelativeDateTimeFormatter` is not
        // `Sendable`, and a shared instance would need synchronization for a
        // path this cold.
        //
        // The locale is **not** set: pinning `zh_Hans_CN` here made an English
        // phone read "3周前" for anything older than a week. `SettingsModel`
        // already records that same lesson ("the row read on an English phone
        // used to say「3分钟前」"); `Locale.current` is what the four short
        // branches above get through `String(localized:)`, so this branch now
        // agrees with them instead of contradicting them.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
