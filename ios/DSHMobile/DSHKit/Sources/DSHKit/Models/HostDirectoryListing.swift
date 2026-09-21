import Foundation

/// One directory row in a host directory listing.
///
/// `path` is absolute and host-owned: clients jump with it directly and never
/// join segments themselves, because the host is the only side that knows the
/// platform's separator rules.
public struct HostDirectoryEntry: Sendable, Decodable, Hashable, Identifiable {
    public let name: String
    public let path: String
    /// Hidden by the host platform's convention (dot-prefixed on POSIX). The
    /// client owns whether such a row is shown.
    public let hidden: Bool

    public var id: String { path }
}

/// One directory level plus its ancestry, as `directoryPicker/list` reports it.
///
/// A listing is what makes the phone's directory browser possible at all: the
/// host walks its own filesystem, so no path travels back and forth as a
/// request to be interpreted.
public struct HostDirectoryListing: Sendable, Decodable, Hashable {
    /// Absolute path of the listed directory.
    public let path: String
    /// The host account's home directory, for the breadcrumb's "Home" anchor
    /// and for abbreviating displayed paths.
    public let home: String
    /// Ancestor chain from the filesystem root to the listed directory
    /// inclusive; every crumb is a jump target.
    public let crumbs: [HostDirectoryEntry]
    /// Direct child directories, name-sorted. The host's browse backend lists
    /// directories only — files are not part of this answer.
    public let entries: [HostDirectoryEntry]
    /// True when the host cut `entries` at its own bound: the level has more
    /// child directories than reported, and the missing rows are the sorted
    /// tail. The browser says so instead of looking complete.
    public let truncated: Bool
}
