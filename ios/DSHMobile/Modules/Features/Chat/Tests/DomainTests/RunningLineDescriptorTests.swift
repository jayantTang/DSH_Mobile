import DSHKit
import XCTest

@testable import DSHChatDomain

final class RunningLineDescriptorTests: XCTestCase {
    func test_thinking_shows_steps_and_generated_chars() {
        let d = RunningLineDescriptor(stepCount: 12, activity: nil, detail: "", generatedChars: 328)
        XCTAssertEqual(d.text, "12 步 · 思考 328 字")
    }

    func test_command_shows_steps_and_preview() {
        let d = RunningLineDescriptor(stepCount: 12, activity: .commands,
                                      detail: "git status --short", generatedChars: 0)
        XCTAssertEqual(d.text, "12 步 · 命令 git status --short")
    }

    func test_no_detail_and_no_steps_stay_short() {
        XCTAssertEqual(RunningLineDescriptor(stepCount: 0, activity: .tools,
                                             detail: "", generatedChars: 0).text, "工具")
        XCTAssertEqual(RunningLineDescriptor(stepCount: 0, activity: nil,
                                             detail: "", generatedChars: 0).text, "思考中")
    }
}
