import Foundation

/// How one workspace file should be opened on the phone.
///
/// The wire carries no media type — `workspaceFiles/stat` answers with a path, a
/// version and a size — so a file's *name* is the only cheap signal there is.
/// Two consequences shape this type:
///
/// - A name is a first guess, never a verdict. An extension this build does not
///   know is tried as text, and the host answering `workspace-file/not-text`
///   moves the file to `preview` instead of dead-ending it. That is what keeps
///   the browser free of an allowlist that would have to be right about every
///   format a computer can hold.
/// - `preview` is deliberately the catch-all: the system preview decides what it
///   can draw, so a Keynote deck, a 7z archive or an exported font still opens
///   as *something* rather than as an error.
public enum WorkspaceFileKind: String, Sendable, Hashable, CaseIterable {
    /// Read line by line through `workspaceFiles/read`.
    case text
    /// Static markup handed to the web view: html and svg.
    case web
    /// A picture the app decodes itself, so it can be zoomed like a photograph.
    case image
    /// A document or a media file: fetched whole and handed to the system preview.
    case preview
    /// A format the system preview has nothing to draw for — an archive, a
    /// database, a keychain — so the app shows its own card instead.
    ///
    /// This is not the same as "unknown": QuickLook happily presents a nameless
    /// binary as "MacBinary 归档, 3.2 MB", which is a useful answer, while it
    /// draws an *empty white page* for a zip. The split is by what the system
    /// actually renders, and it is why the fallback card is reachable at all.
    case binary

    /// The kind a file name alone decides.
    ///
    /// Unknown extensions come back as `text` on purpose: the reader is the one
    /// path that fails *informatively* (`workspace-file/not-text`), which is the
    /// signal the caller reroutes on. Guessing `preview` for everything unknown
    /// would send a plain text file with an unusual suffix to QuickLook.
    public static func of(path: String) -> WorkspaceFileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if webExtensions.contains(ext) { return .web }
        if imageExtensions.contains(ext) { return .image }
        if cardExtensions.contains(ext) { return .binary }
        if previewExtensions.contains(ext) { return .preview }
        return .text
    }

    /// Markup the web view renders. Kept as it was before the previewer existed:
    /// an svg is a document, not a photograph, and it scales with the page.
    private static let webExtensions: Set<String> = ["html", "htm", "xhtml", "svg"]

    /// Formats the app decodes into a `UIImage` itself.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "ico",
    ]

    /// Formats that are never text, so there is no point spending a read on them,
    /// and that the system preview renders.
    ///
    /// Not exhaustive by design — anything missing here is tried as text and
    /// rerouted when the host refuses it. These are the ones common enough that
    /// the extra round trip and the "not UTF-8" moment would be a wasted step.
    private static let previewExtensions: Set<String> = [
        // Documents and books
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "rtf", "rtfd", "odt", "ods", "odp", "epub", "mobi",
        // Binaries the system still describes (a name, a type and a size)
        "o", "a", "so", "dylib", "exe", "dll", "bin", "dat", "wasm",
        // Media
        "mp3", "m4a", "wav", "aif", "aiff", "aac", "flac", "ogg", "opus",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "usdz", "usd", "glb", "gltf",
        // Design and font files
        "psd", "ai", "sketch", "fig", "woff", "woff2", "ttf", "otf", "eot", "icns",
    ]

    /// Formats the system preview draws *nothing* for.
    ///
    /// Measured, not assumed: a zip opened in QuickLook on iOS 26 is a blank white
    /// page, while the app's own card at least names the file, gives its exact
    /// size and offers the share sheet.
    private static let cardExtensions: Set<String> = [
        // Archives and packages
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg",
        "jar", "apk", "ipa", "xcarchive",
        // Databases
        "db", "sqlite", "sqlite3", "realm",
        // Credentials and provisioning
        "p12", "pfx", "cer", "der", "mobileprovision",
    ]
}
