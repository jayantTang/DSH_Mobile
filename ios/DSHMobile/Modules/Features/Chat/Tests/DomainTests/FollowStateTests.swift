import DSHChatDomain
import XCTest

/// 025 T022 — the follow/reading state machine (`ChatModel+Follow`).
///
/// Two states, one threshold, and one rule for what happens to messages that
/// arrive while the reader is away from the bottom. All of it is reachable on a
/// bare `ChatModel()` — no store, no link, no session — which is the whole point
/// of keeping the transitions in the domain layer.
@MainActor
final class FollowStateTests: XCTestCase {

    private var model: ChatModel!

    override func setUp() {
        super.setUp()
        model = ChatModel()
    }

    override func tearDown() {
        model = nil
        super.tearDown()
    }

    // MARK: - A model nobody has opened anything in

    func test_a_new_model_is_following_an_empty_transcript() {
        XCTAssertEqual(model.followState, .atBottom)
        XCTAssertEqual(model.unreadWhileReading, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.activity, .idle)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isCatchingUpTail)
        XCTAssertFalse(model.tailSyncInFlight)
        XCTAssertFalse(model.isLoadingOlder)
        XCTAssertFalse(model.hasOlder)
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.olderFailure)
        XCTAssertNil(model.session)
        XCTAssertNil(model.store)
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.steerNext)
        XCTAssertTrue(model.timeline.items.isEmpty)
    }

    func test_without_a_window_loaded_search_cannot_extend_and_adds_nothing() async {
        // Nothing has been read yet, so there is no older boundary to page
        // from: the panel must be able to tell "not loaded" from "nothing
        // more", and both entry points say so instead of returning a page.
        XCTAssertFalse(model.canExtendSearch)
        let extended = await model.extendSearchHistory()
        XCTAssertFalse(extended)
        XCTAssertFalse(model.commitSearchHistory())
    }

    func test_without_a_link_the_reader_pages_see_nothing() async {
        let hits = await model.localUserInputHits(query: "needle")
        XCTAssertTrue(hits.isEmpty)
        let synced = await model.userInputsSynced()
        XCTAssertFalse(synced)
        XCTAssertNil(model.address)
        XCTAssertTrue(model.pendingPrompts.isEmpty)
    }

    // MARK: - The threshold

    func test_the_follow_threshold_is_the_documented_distance() {
        XCTAssertEqual(ChatModel.followBottomThreshold, 48)
    }

    func test_geometry_within_the_threshold_keeps_following() {
        for distance in [CGFloat(0), 1, 47, ChatModel.followBottomThreshold] {
            model.noteFollowGeometry(distance: distance, draggingUp: false)
            XCTAssertEqual(model.followState, .atBottom, "distance \(distance) should still follow")
        }
    }

    func test_geometry_beyond_the_threshold_starts_reading() {
        for distance in [ChatModel.followBottomThreshold + 0.5, 100, 4_000] {
            model.noteFollowGeometry(distance: distance, draggingUp: false)
            XCTAssertEqual(model.followState, .reading, "distance \(distance) should stop following")
        }
    }

    func test_a_finger_dragging_up_starts_reading_even_at_the_bottom() {
        // The geometry can still read "at the bottom" for a frame while the
        // reader is already pulling the transcript up: the drag decides.
        model.noteFollowGeometry(distance: 0, draggingUp: true)

        XCTAssertEqual(model.followState, .reading)
    }

    func test_coming_back_within_the_threshold_resumes_following() {
        model.noteFollowGeometry(distance: 500, draggingUp: false)
        XCTAssertEqual(model.followState, .reading)

        model.noteFollowGeometry(distance: 10, draggingUp: false)
        XCTAssertEqual(model.followState, .atBottom)
    }

    func test_coming_back_clears_the_unread_count() {
        model.noteFollowGeometry(distance: 500, draggingUp: false)
        model.noteTailArrivals(4)
        XCTAssertEqual(model.unreadWhileReading, 4)

        model.noteFollowGeometry(distance: 0, draggingUp: false)

        XCTAssertEqual(model.unreadWhileReading, 0)
    }

    // MARK: - Unread counting

    func test_arrivals_are_counted_only_while_reading() {
        model.noteTailArrivals(5)
        XCTAssertEqual(model.unreadWhileReading, 0, "what is on screen is not unread")

        model.noteFollowGeometry(distance: 500, draggingUp: false)
        model.noteTailArrivals(5)

        XCTAssertEqual(model.unreadWhileReading, 5)
    }

    func test_arrivals_accumulate_and_ignore_empty_batches() {
        model.noteFollowGeometry(distance: 500, draggingUp: false)

        model.noteTailArrivals(2)
        model.noteTailArrivals(3)
        XCTAssertEqual(model.unreadWhileReading, 5)

        model.noteTailArrivals(0)
        model.noteTailArrivals(-7)
        XCTAssertEqual(model.unreadWhileReading, 5)
    }

    func test_jumping_to_the_bottom_clears_the_count_without_a_link() async {
        model.noteFollowGeometry(distance: 500, draggingUp: false)
        model.noteTailArrivals(3)

        await model.jumpToLatest()

        XCTAssertEqual(model.followState, .atBottom)
        XCTAssertEqual(model.unreadWhileReading, 0)
        XCTAssertFalse(model.isCatchingUpTail, "no pipeline means there is nothing to catch up")
    }

    // MARK: - Forced transitions

    func test_opening_a_session_restarts_following_at_the_bottom() {
        // A cold entry is meant to land at the newest message, even though a
        // jump made inside a transcript forces the opposite.
        model.noteFollowGeometry(distance: 500, draggingUp: false)
        model.noteTailArrivals(9)

        model.noteFollowResetForOpen()

        XCTAssertEqual(model.followState, .atBottom)
        XCTAssertEqual(model.unreadWhileReading, 0)
    }

    func test_jumping_into_history_forces_reading() {
        // Otherwise the next arriving message drags the reader off the row they
        // just jumped to.
        model.noteJumpToReading()

        XCTAssertEqual(model.followState, .reading)
    }

    func test_sending_your_own_message_snaps_back_to_the_bottom() {
        model.noteFollowGeometry(distance: 500, draggingUp: false)
        model.noteTailArrivals(2)

        model.noteWantsBottom()

        XCTAssertEqual(model.followState, .atBottom)
        XCTAssertEqual(model.unreadWhileReading, 0)
    }

    // MARK: - Reconciliation without a link

    func test_syncing_the_tail_without_a_link_is_a_no_op() async {
        await model.syncTailWithHost(reason: "reconnect")

        XCTAssertFalse(model.tailSyncInFlight)
        XCTAssertFalse(model.isCatchingUpTail)
    }

    func test_reopening_after_a_reconnect_without_a_link_is_a_no_op() async {
        await model.reopenAfterReconnect()

        XCTAssertNil(model.session)
        XCTAssertEqual(model.phase, .idle)
    }
}
