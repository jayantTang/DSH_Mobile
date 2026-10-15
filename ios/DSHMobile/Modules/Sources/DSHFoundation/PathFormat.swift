import Foundation

/// clients readable side by side.
public enum PathFormat {
    public static func short(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    public static func directory(_ path: String, home: String?) -> String {
        (short(path, home: home) as NSString).lastPathComponent
    }
}
