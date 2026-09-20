import Foundation

/// How the session list orders what it shows.
///
/// Pure on purpose: "running first, then what finished while you were away" is
/// the whole feature, and it is the part a UI run cannot check honestly — a list
/// looks the same whichever way it was sorted unless you happen to be watching
/// the right two rows. Here it is a function with tests.
///
/// The rules, in the order they apply:
///
/// 1. Groups that contain something running come before groups that do not.
/// 2. Inside a group, rows sort by state: running, finished-unseen,
///    finished-seen, blank last.
/// 3. Ties break on `updatedAt`, newest first.
///
/// This deliberately parts ways with the desktop sidebar's saved workspace
/// order: on a phone the list answers "is anything happening?" before it
/// answers "where did I file that?".
public enum SessionListOrder {

    /// Groups with a running member first; everything else by latest activity.
    ///
    /// - Parameters:
    ///   - groups: each group's members, already in whatever order the caller
    ///     had them; members are re-sorted by ``members(_:states:updatedAt:)``.
    ///   - isRunning: whether one session is running.
    ///   - activity: the group's most recent activity, for tie-breaking.
    public static func groups<G>(
        _ groups: [G],
        isRunning: (G) -> Bool,
        activity: (G) -> Double
    ) -> [G] {
        groups.sorted { left, right in
            let leftRunning = isRunning(left)
            let rightRunning = isRunning(right)
            if leftRunning != rightRunning { return leftRunning }
            return activity(left) > activity(right)
        }
    }

    /// Rows inside one group: by state rank, then newest first.
    public static func members<S>(
        _ sessions: [S],
        state: (S) -> SessionRowState,
        updatedAt: (S) -> Double
    ) -> [S] {
        sessions.sorted { left, right in
            let leftRank = state(left).rank
            let rightRank = state(right).rank
            if leftRank != rightRank { return leftRank < rightRank }
            return updatedAt(left) > updatedAt(right)
        }
    }
}
