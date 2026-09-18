import XCTest

@testable import DSHKit

/// The parser behind every patch the app renders. It is deliberately forgiving —
/// a patch with no `diff --git` header still has to render — so what matters is
/// that a real `git diff` comes out with the right line numbers and kinds.
final class UnifiedDiffTests: XCTestCase {

    private let patch = """
    diff --git a/src/app.js b/src/app.js
    index 111..222 100644
    --- a/src/app.js
    +++ b/src/app.js
    @@ -1,4 +1,5 @@
     line one
    -line two
    +line two (changed)
    +line two and a half
     line three
     line four
    """

    func testARealPatchParsesWithNumbersAndKinds() {
        let parsed = UnifiedDiff.parse(patch)

        XCTAssertFalse(parsed.isEmpty)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertEqual(parsed.files[0].displayPath, "src/app.js")
        XCTAssertEqual(parsed.additions, 2)
        XCTAssertEqual(parsed.deletions, 1)

        let lines = parsed.files[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .added, .context, .context])
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].newNumber, 2)
        XCTAssertEqual(lines[4].oldNumber, 3, "删除一行、加两行之后，旧行号与新行号不再同步")
        XCTAssertEqual(lines[4].newNumber, 4)
    }

    func testAnUntrackedFileShownAsAnAdditionCountsEveryLineAsAdded() {
        // What `git diff --no-index /dev/null <path>` produces.
        let addition = """
        diff --git a/notes.txt b/notes.txt
        new file mode 100644
        index 000..333
        --- /dev/null
        +++ b/notes.txt
        @@ -0,0 +1,2 @@
        +第一行
        +第二行
        """
        let parsed = UnifiedDiff.parse(addition)
        XCTAssertEqual(parsed.additions, 2)
        XCTAssertEqual(parsed.deletions, 0)
        XCTAssertTrue(parsed.files[0].isNew)
    }

    func testAPatchWithoutGitHeadersStillRenders() {
        let bare = """
        @@ -1 +1 @@
        -old
        +new
        """
        let parsed = UnifiedDiff.parse(bare)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.deletions, 1)
    }

    func testNoPatchAtAllIsEmptyRatherThanWrong() {
        XCTAssertTrue(UnifiedDiff.parse("").isEmpty)
        XCTAssertTrue(UnifiedDiff.parse("just some text\nwith no hunks\n").isEmpty)
    }

    func testARenameWithNoLineChangesHasNothingToDraw() {
        // `git diff` prints headers only when a file was renamed and not edited.
        // There are no lines to draw, so the parse is empty on purpose — the
        // "已重命名 旧 → 新" line comes from the status entry, not from here.
        let rename = """
        diff --git a/旧 名.md b/新 名.md
        similarity index 100%
        rename from 旧 名.md
        rename to 新 名.md
        """
        XCTAssertTrue(UnifiedDiff.parse(rename).isEmpty)
    }

    func testARenameWithEditsKeepsBothPaths() {
        let rename = """
        diff --git a/old.md b/new.md
        similarity index 90%
        rename from old.md
        rename to new.md
        index 111..222 100644
        --- a/old.md
        +++ b/new.md
        @@ -1 +1 @@
        -旧内容
        +新内容
        """
        let parsed = UnifiedDiff.parse(rename)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertEqual(parsed.files[0].oldPath, "a/old.md")
        XCTAssertEqual(parsed.files[0].newPath, "b/new.md")
        XCTAssertEqual(parsed.files[0].displayPath, "new.md")
        XCTAssertEqual(parsed.additions, 1)
    }
}
