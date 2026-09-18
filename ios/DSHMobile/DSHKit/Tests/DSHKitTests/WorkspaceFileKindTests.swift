import XCTest

@testable import DSHKit

/// What a name decides, and what it deliberately leaves open.
///
/// The mapping is a first guess only — a file it cannot place is read as text and
/// rerouted when the Host refuses it — so the cases worth pinning down are the
/// families that must never be sent to the text reader, and the plain text that
/// must never be sent to QuickLook.
final class WorkspaceFileKindTests: XCTestCase {

    func testMarkupGoesToTheWebView() {
        XCTAssertEqual(WorkspaceFileKind.of(path: "report.html"), .web)
        XCTAssertEqual(WorkspaceFileKind.of(path: "a/b/report.HTM"), .web)
        XCTAssertEqual(WorkspaceFileKind.of(path: "diagram.svg"), .web)
    }

    func testPicturesAreDecodedByTheApp() {
        XCTAssertEqual(WorkspaceFileKind.of(path: "shot.png"), .image)
        XCTAssertEqual(WorkspaceFileKind.of(path: "media/01-s01-sessions.jpg"), .image)
        XCTAssertEqual(WorkspaceFileKind.of(path: "IMG_0001.HEIC"), .image)
        XCTAssertEqual(WorkspaceFileKind.of(path: "scan.tiff"), .image)
    }

    func testFormatsThatAreNeverTextSkipTheReader() {
        for name in ["a.pdf", "a.docx", "a.xlsx", "a.key", "a.mp4", "a.bin"] {
            XCTAssertEqual(WorkspaceFileKind.of(path: name), .preview, name)
        }
    }

    func testFormatsTheSystemPreviewDrawsNothingForGetTheAppsCard() {
        // QuickLook draws an empty white page for a zip; a card that names the
        // file and gives its exact size is strictly more useful.
        for name in ["a.zip", "a.tar.gz", "a.7z", "a.dmg", "a.sqlite", "a.p12", "backup.ipa"] {
            XCTAssertEqual(WorkspaceFileKind.of(path: name), .binary, name)
        }
    }

    func testTextAndUnknownNamesStillGetRead() {
        // Unknown on purpose: the reader is the path that fails informatively,
        // and `workspace-file/not-text` is what reroutes the file to QuickLook.
        for name in ["main.swift", "notes.md", "data.json", "Dockerfile", "LICENSE", "x.woof"] {
            XCTAssertEqual(WorkspaceFileKind.of(path: name), .text, name)
        }
    }

    func testALeadingDotIsNotAnExtension() {
        XCTAssertEqual(WorkspaceFileKind.of(path: ".gitignore"), .text)
        XCTAssertEqual(WorkspaceFileKind.of(path: "dir/.env"), .text)
    }
}
