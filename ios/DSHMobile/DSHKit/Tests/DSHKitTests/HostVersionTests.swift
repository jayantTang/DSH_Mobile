import Testing
@testable import DSHKit

/// The comparison behind the "your computer's connector is out of date" notice.
///
/// The load-bearing cases are the ones that must **not** warn: an unreadable
/// version, and a release candidate of the baseline. A notice that fires when it
/// should not is worse than a missing one — it spends the user's attention on
/// something they cannot act on.
struct HostVersionTests {

    @Test func lowerPatchIsOlder() {
        #expect(HostVersion.isOlder("0.1.4", than: "0.1.5"))
    }

    @Test func lowerMinorIsOlder() {
        #expect(HostVersion.isOlder("0.0.9", than: "0.1.5"))
    }

    @Test func equalIsNotOlder() {
        #expect(!HostVersion.isOlder("0.1.5", than: "0.1.5"))
    }

    @Test func higherIsNotOlder() {
        #expect(!HostVersion.isOlder("0.2.0", than: "0.1.5"))
        #expect(!HostVersion.isOlder("1.0.0", than: "0.1.5"))
    }

    @Test func unparseableIsNeverOld() {
        // The whole reason this is a tested function: `serverVersion` comes off
        // the wire, so anything can be in it. None of these may warn.
        for reported in ["", "garbage", "alpha", "v", "  ", "x.y.z", "1.x"] {
            #expect(!HostVersion.isOlder(reported, than: "0.1.5"), "reported=\(reported)")
        }
        // A baseline we cannot read must not warn either.
        #expect(!HostVersion.isOlder("0.0.1", than: "unreleased"))
    }

    @Test func suffixesAreIgnored() {
        // A pre-release of the same numbers compares equal, so it does not warn:
        // an rc of the baseline is close enough that nagging would be noise.
        #expect(!HostVersion.isOlder("0.1.5-rc.1", than: "0.1.5"))
        // But a pre-release whose numbers are genuinely lower is still older.
        #expect(HostVersion.isOlder("0.1.5-rc.1", than: "0.1.6"))
        // Build metadata is not part of the comparison.
        #expect(!HostVersion.isOlder("0.1.5+build.9", than: "0.1.5"))
        #expect(HostVersion.isOlder("0.1.4-rc.3", than: "0.1.5-rc.1"))
    }

    @Test func missingComponentsCountAsZero() {
        // `1.2` is `1.2.0`: a `1.2.0` baseline must not warn on `1.2`.
        #expect(!HostVersion.isOlder("1.2", than: "1.2.0"))
        #expect(HostVersion.isOlder("1.2", than: "1.2.1"))
    }
}
