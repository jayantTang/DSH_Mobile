import Foundation

/// A scratch `UserDefaults` domain for a test case.
///
/// Two shipped types keep preferences (`ConnectionStore` the saved pairings,
/// `SessionAlertPrefs` the notification switches). A case must never exercise
/// them through `.standard`: whatever it writes outlives the run and the next
/// case starts from it — and on a developer's machine that domain is not empty.
/// `SessionAlertPrefs` already takes its store as a parameter, so this is all
/// the isolation it needs.
///
/// Two rules keep it honest:
///
/// * the suite name is **fixed per label**, not random. `UserDefaults` writes a
///   plist into `~/Library/Preferences` for every suite it opens, and cfprefsd
///   re-creates it after a delete, so a random name would leave one empty file
///   behind per case, run after run. A fixed name reuses the same file.
/// * the domain is wiped on the way **in** and on the way out, so a shared name
///   still means "empty at the start of every case", including after a case
///   that failed halfway.
///
/// Test-only: no product target depends on `DSHTestingSupport`.
public struct IsolatedDefaults {
    /// The suite this instance uses. Fixed per label, e.g. `dsh.tests.alerts`.
    public let suiteName: String
    /// A store backed by `suiteName` alone.
    public let defaults: UserDefaults

    public init(label: String) {
        let name = "dsh.tests.\(label)"
        guard let suite = UserDefaults(suiteName: name) else {
            // Opening a named suite only fails for a couple of system domains a
            // test run is never in; falling back to `.standard` quietly would
            // poison the next case, so refuse loudly instead.
            preconditionFailure("could not open an isolated UserDefaults suite named \(name)")
        }
        suiteName = name
        defaults = suite
        defaults.removePersistentDomain(forName: name)
    }

    /// Wipes every value this suite wrote. Call from `tearDown`, whichever way
    /// the case ended — the next case wipes again on construction.
    public func removeDomain() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
    }
}
