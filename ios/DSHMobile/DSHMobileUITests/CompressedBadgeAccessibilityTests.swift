import CryptoKit
import XCTest

/// 「压缩版」标记必须进无障碍树（用例 TC-MOB-143 第 3 步 / IMG-CLI-09 的界面层断言）。
///
/// 为什么单独写成一条 XCUITest：SwiftUI 的无障碍元素不在 UIView 树里
/// （`UIHostingController.view.accessibilityElementCount()` 恒为 0，已实测），
/// 单测拿不到标识；而这条缺陷恰恰只在无障碍树里暴露——截图里标记是可见的。
///
/// 夹具在测试进程里现造：一份 `compressed: true`、没有 `preview` 子对象的镜像，
/// 外加它那份字节（文件名就是 sha256），通过 DEBUG 钩子
/// `-DSHFeedbackSeedMirror` 交给 App。不连真机、不碰真实会话。
final class CompressedBadgeAccessibilityTests: XCTestCase {

    private static let threadId = "th_a11y_compressed"
    private static let attachmentId = "fa_a11y_compressed"

    /// 本次运行造出来的夹具目录；用例结束即删（每跑一次一个新 UUID，不删会在 /tmp 里堆）。
    private var fixtureDirectory: URL?

    override func tearDownWithError() throws {
        if let directory = fixtureDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        fixtureDirectory = nil
        try super.tearDownWithError()
    }

    /// 1×1 的 PNG（能真的解码，缩略图路径也能走通）。
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 造夹具并返回镜像路径（宿主 `/tmp`，模拟器进程能读到，与既有用例同一口径）。
    private func makeFixture() throws -> String {
        let directory = URL(fileURLWithPath: "/tmp/dsh-a11y-compressed-\(UUID().uuidString)",
                            isDirectory: true)
        fixtureDirectory = directory
        let attachments = directory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)

        let digest = sha256Hex(Self.png)
        try Self.png.write(to: attachments.appendingPathComponent(digest))

        let now = 1_791_825_010_506
        let inbox: [String: Any] = [
            "threads": [[
                "threadId": Self.threadId,
                "subject": "只有预览的附件",
                "status": "replied",
                "createdAt": now - 506,
                "lastMessageAt": now,
                "teamUnread": 0,
                "mySide": "user",
                "messages": [[
                    "messageId": "msg_a11y_compressed",
                    "author": "owner",
                    "body": "这一份主对象就是预览",
                    "createdAt": now,
                    "attachments": [[
                        "attachmentId": Self.attachmentId,
                        "name": "preview.png",
                        "contentType": "image/png",
                        "byteSize": Self.png.count,
                        "sha256": digest,
                        "width": 1,
                        "height": 1,
                        "createdAt": now,
                        "compressed": true,
                    ]],
                ]],
            ]],
            "notices": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: inbox)
        let mirror = directory.appendingPathComponent("inbox.json")
        try data.write(to: mirror)
        return mirror.path
    }

    func testTheThreadBodyExposesTheCompressedBadgeIdentifier() throws {
        let mirror = try makeFixture()
        let app = XCUIApplication()
        app.launchArguments = ["-DSHOpenScreen", "feedback",
                               "-DSHFeedbackSeedMirror", mirror]
        app.launch()

        let center = app.descendants(matching: .any)["feedback.center"]
        XCTAssertTrue(center.waitForExistence(timeout: 40), "记录页没有出现")

        let row = app.descendants(matching: .any)["feedback.row.\(Self.threadId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "预置镜像里的那封信没有出现")
        row.tap()

        XCTAssertTrue(app.descendants(matching: .any)["feedback.thread"].waitForExistence(timeout: 15),
                      "信件详情没有出现")

        // 正文/列表的标记：这一条正是 2026-11-12 漏掉的那个。
        XCTAssertTrue(app.descendants(matching: .any)["feedback.attachment.compressed"]
            .waitForExistence(timeout: 10),
            "正文附件区没有「压缩版」的无障碍标识（被容器的 feedback.attachment.image 吞掉了？）")
        XCTAssertFalse(app.descendants(matching: .any)["feedback.attachment.original"].exists,
                       "只有预览的附件不该有原图入口")
    }
}
