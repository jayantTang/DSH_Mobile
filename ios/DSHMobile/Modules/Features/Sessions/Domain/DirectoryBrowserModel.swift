import DSHFoundation
import DSHConnectionAPI
import DSHCore
import DSHKit
import Foundation
import Observation

/// Walks the computer's directories for the new-session sheet.
///
/// The host walks its own filesystem and answers one level at a time
/// (`directoryPicker/list`), so the phone never joins path segments itself and
/// a network round trip is the only cost of a tap. Two things about that answer
/// shape this model:
///
/// - A listing carries its own ancestry (`crumbs`), so "go up" and "jump to an
///   ancestor" are both just another listing, and the browser holds no path
///   stack of its own that could disagree with the host.
/// - The host's browse backend lists **directories only**. Files are not part
///   of the answer at all, which is consistent: a session's working directory
///   cannot be a file.
@MainActor
@Observable
public final class DirectoryBrowserModel {
    public init() {}

    /// The level on screen, once one has been read.
    public private(set) var listing: HostDirectoryListing?
    public private(set) var isLoading = false
    /// Why the last attempt failed, if it did.
    public private(set) var failure: String?
    /// What the path field holds. Typing is the fast way to a deep directory,
    /// so the field is not merely a label: it is a jump target.
    public var pathDraft = ""

    private weak var store: (any ConnectionStatus)?

    public func attach(to store: any ConnectionStatus) {
        self.store = store
    }

    public var currentPath: String? { listing?.path }
    public var entries: [HostDirectoryEntry] { listing?.entries ?? [] }
    public var crumbs: [HostDirectoryEntry] { listing?.crumbs ?? [] }
    public var truncated: Bool { listing?.truncated ?? false }

    /// Whether "up" has anywhere to go.
    public var canGoUp: Bool { HostPath.canGoUp(from: listing?.path) }

    /// Reads the host's home directory, which is where a person starts.
    public func start() async {
        await open(nil)
    }

    /// Reads one level and shows it. `nil` asks the host for its home.
    public func open(_ path: String?) async {
        guard let client = store?.directoryHost else {
            failure = "尚未连接"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await client.directoryListing(path: path)
            listing = value
            pathDraft = value.path
            failure = nil
        } catch {
            // The level on screen stays where it was: a failed jump should not
            // also throw away the directory the user was looking at.
            failure = Self.describe(error)
        }
    }

    public func open(_ entry: HostDirectoryEntry) async {
        await open(entry.path)
    }

    public func goUp() async {
        guard let path = listing?.path, let parent = HostPath.parent(of: path) else { return }
        await open(parent)
    }

    /// Jumps to whatever the path field says.
    public func submitDraft() async {
        let trimmed = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await open(trimmed)
    }

    /// Creates one folder inside the level on screen and steps into it.
    @discardableResult
    public func createFolder(named name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let client = store?.directoryHost, let parent = listing?.path else {
            failure = "尚未连接"
            return nil
        }
        do {
            let created = try await client.createDirectory(parent: parent, name: trimmed)
            await open(created)
            return created
        } catch {
            failure = Self.describe(error)
            return nil
        }
    }

    /// A path as the desktop client would show it.
    public func displayPath(_ path: String) -> String {
        PathFormat.short(path, home: store?.hostHome ?? listing?.home)
    }

    /// The parent of an absolute path, or `nil` at the root.
    ///
    /// `/` is its own parent, and reporting that as one would let "up" turn
    /// into "reload the same level".
    // 「上一级是哪个目录」的判定搬进 DSHKit（`HostPath.parent`，有单测）。

    /// Turns the two failures a person can actually hit into something to act on.
    ///
    /// The host's own message names an internal capability (`the composed picker
    /// serves "native"`), which is true and useless on a phone: what the user
    /// needs to know is that this computer cannot be browsed from here.
    private static func describe(_ error: any Error) -> String {
        if let failure = error as? DSHRPCFailure {
            switch failure.code {
            case "directory-picker/unavailable":
                return "这台电脑的 DSH 没有挂目录浏览后端（browse），手机端无法浏览它的目录。可以先在电脑端把 profile 的 directory-picker 换成 browse，或从上面选一个已有工作区。"
            case "directory-picker/exists":
                return "已经有同名的文件夹了。"
            case "directory-picker/unreadable", "directory-picker/create-failed":
                return "这个目录读不了：\(failure.message)"
            default:
                break
            }
        }
        return LinkErrors.describe(error)
    }
}
