import Foundation
import Testing

@testable import DSHKit

/// The take-once rule is the whole point of this type (015): the defect it
/// replaces was two readers both holding the same request, which pushed the same
/// session onto the navigation stack twice.
@Suite("Session request box")
struct SessionRequestBoxTests {

    @Test @MainActor func takingARequestClearsIt() {
        let box = SessionRequestBox()
        box.put(sessionId: "session-a")

        #expect(box.take()?.sessionId == "session-a")
        // The second reader must get nothing: this is what stops the double push.
        #expect(box.take() == nil)
        #expect(box.pending == nil)
    }

    @Test @MainActor func generationAdvancesWithEveryRequest() {
        let box = SessionRequestBox()
        let first = box.put(sessionId: "session-a")
        let second = box.put(sessionId: "session-b")

        #expect(first.generation == 1)
        #expect(second.generation == 2)
        #expect(box.generation == 2)
    }

    @Test @MainActor func theNewestRequestWins() {
        let box = SessionRequestBox()
        box.put(sessionId: "session-a")
        box.put(sessionId: "session-b")

        #expect(box.take()?.sessionId == "session-b")
        #expect(box.take() == nil)
    }

    /// A request that has been taken is gone for good — parking a new one is the
    /// only way to make the session openable again, and it arrives as a new
    /// generation so the view can tell the two apart.
    @Test @MainActor func aNewRequestForTheSameSessionIsANewGeneration() {
        let box = SessionRequestBox()
        let first = box.put(sessionId: "session-a")
        #expect(box.take()?.generation == first.generation)

        let second = box.put(sessionId: "session-a")
        #expect(second.generation > first.generation)
        #expect(box.take()?.generation == second.generation)
        #expect(box.take() == nil)
    }

    @Test @MainActor func anEmptyBoxTakesNothing() {
        let box = SessionRequestBox()
        #expect(box.take() == nil)
        #expect(box.generation == 0)
    }
}
