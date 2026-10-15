import Foundation

/// A scratch `UserDefaults` domain owned by one test case.
///
/// Two shipped types keep preferences (`ConnectionStore` the saved pairings,
/// `SessionAlertPrefs` the notification switches). A case must never exercise
/// them through `.standard`: whatever it writes outlives the run and the next
/// case starts from it — and on a developer's machine that domain is not empty.
/// `SessionAlertPrefs` already takes its store as a parameter, so this is all
/// the isolation it needs; `removeDomain()` is what makes forgetting to clean
/// up impossible.
///
/// Test-only: no product target depends on `DSHTestingSupport`.
public struct IsolatedDefaults {
    /// The suite this instance owns. Unique per instance.
    public let suiteName: String
    /// A store backed by `suiteName` alone.
    public let defaults: UserDefaults

    public init(label: String = "case") {
        let name = "dsh.tests.\(label).\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else {
            // Opening a named suite only fails for a couple of system domains a
            // test run is never in; falling back to `.standard` quietly would
            // poison the next case, so refuse loudly instead.
            preconditionFailure("could not open an isolated UserDefaults suite named \(name)")
        }
        suiteName = name
        defaults = suite
    }

    /// Wipes every value this suite wrote and removes its file.
    ///
    /// Call from `tearDown`, whichever way the case ended.
    public func removeDomain() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        let plist = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
