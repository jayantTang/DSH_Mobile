#if canImport(UIKit)
// 与 `\.dshPadAdaptation` 同一条条件编译（macOS 上没有该环境键）。
import SwiftUI

/// 阅读宽度口径（pt）。中文 16pt 一行 35–45 字、英文 60–75 字符，对应 720–800；取 760。
public enum ReadingWidth {
    public static let prose: CGFloat = 760
    public static let form: CGFloat = 560
}

/// 阅读列：iPad 宽屏上把正文收进可读宽度并居中；其余情况**原样返回**。
///
/// 内部读 `\.dshPadAdaptation`，所以调用点不写 if。窄屏与 iPhone 横屏上它不改变任何像素
/// （`.frame(maxWidth:)` 本可以在窄屏上空转，但与"零变化"相比，直接不套更保险）。
public struct ReadingColumn<Content: View>: View {
    @Environment(\.dshPadAdaptation) private var pad
    private let width: CGFloat
    private let content: Content

    public init(_ width: CGFloat = ReadingWidth.prose, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    public var body: some View {
        if pad {
            content
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
#endif
