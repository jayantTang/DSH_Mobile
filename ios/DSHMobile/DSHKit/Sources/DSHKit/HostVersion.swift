import Foundation

/// Compares the **connector** version (`_link/hello`'s `serverVersion`) against a
/// baseline — not the DSH host version, which is a different namespace.
///
/// Compares the host version a connector reports against a baseline.
///
/// The point of this type is the **unparseable** case, which is the whole reason
/// it is a separate, tested function rather than an inline string comparison:
/// `serverVersion` comes off the wire from whatever is on the other end, so it
/// can be missing, empty, a git describe, a build stamp, or a calendar version
/// we did not anticipate. When it cannot be read as numbers, the answer is
/// "not older" — an unreadable version must never produce a warning the user
/// cannot act on. A notice that fires on every unusual build is worse than no
/// notice, because it teaches the user to ignore the notice.
public enum HostVersion {

    /// Whether `reported` is older than `baseline`.
    ///
    /// Only the numeric, dot-separated prefix of each is considered, so
    /// `1.2.3-rc.1`, `1.2.3+build.7` and `1.2.3` all parse as `[1, 2, 3]`.
    /// A pre-release of the *same* numbers is **not** older: `0.1.5-rc.1` against
    /// a `0.1.5` baseline compares equal, so it does not warn. That is deliberate —
    /// a connector shipping a release candidate of the baseline the app was built
    /// against is not something to nag about, and ordering pre-releases properly
    /// (rc.1 < rc.2 < release) would need naming rules that are not ours to fix.
    ///
    /// Returns `false` whenever either side has no readable number.
    public static func isOlder(_ reported: String, than baseline: String) -> Bool {
        guard let lhs = numericComponents(reported), let rhs = numericComponents(baseline) else {
            return false
        }
        return compare(lhs, rhs) < 0
    }

    /// The leading `major[.minor[.patch…]]` numbers of a version string.
    ///
    /// Stops at the first character that is not a digit or a dot, which is what
    /// drops `-rc.1`, `+build`, and any suffix. Returns `nil` when there is no
    /// leading number at all (`"garbage"`, `""`, `"v"`).
    static func numericComponents(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.prefix { $0.isNumber || $0 == "." }
        guard prefix.contains(where: \.isNumber) else { return nil }
        let components = prefix.split(separator: ".", omittingEmptySubsequences: true)
        let numbers = components.compactMap { Int($0) }
        // Every component must be a plain non-negative integer: `1.x` is not a
        // version we understand, so we treat the whole thing as unreadable
        // rather than guessing at an interpretation.
        guard !numbers.isEmpty, numbers.count == components.count else { return nil }
        return numbers
    }

    /// Lexicographic comparison, treating a missing component as zero
    /// (`1.2` == `1.2.0`, so a baseline of `1.2.0` does not warn on `1.2`).
    static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}
