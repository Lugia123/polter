import Foundation
import Testing

@testable import Ghostty

/// **The two rules the page is owed, held without a web view** (task 3098):
/// every `chat.ready` gets a `page.reset` (the empty page included), and
/// every `chat.loadOlder` gets a `page.prepend` (an empty one when there is
/// nothing older, and one carrying `error` when the read failed).
///
/// The bridge calls `ControlRoomChatTranscriptObligations`, so these are the
/// shipped rule and not a second copy of it. The real-machine defect was the
/// exception both rules used to have -- "a reset only when there are rows" --
/// and these cases are written so that exception is red.
struct ControlRoomChatTranscriptObligationsTests {
    typealias O = ControlRoomChatTranscriptObligations

    /// A state that has already sent its first reset: what a `page.update`
    /// after `chat.ready` sees.
    private func settled() -> O.State {
        var state = O.State()
        _ = O.ready(&state)
        return state
    }

    // MARK: - chat.ready

    /// **The empty page is a reset, not silence.** The old rule skipped it;
    /// on the real machine that was the only snapshot there ever was, so the
    /// host sent no `page.*` at all.
    @Test func testReadyIsAlwaysOneReset() {
        var state = O.State()
        #expect(O.ready(&state) == .reset)
        #expect(state.sentInitialReset)
    }

    /// The first update after ready is a reset **even with no rows**: the
    /// view is given its state before the feed has answered.
    @Test func testFirstUpdateWithNoRowsStillResets() {
        var state = O.State()
        let replies = O.update(
            &state, ids: [], lastIDs: [],
            hasEarlier: true, olderSettled: true, olderError: nil)
        #expect(replies == [.reset])
    }

    /// **`sentInitialReset`, not `lastIDs.isEmpty`.** After an empty reset
    /// the id list is still empty; a second empty update must send nothing,
    /// or an empty group resets once per SwiftUI pass.
    @Test func testSecondEmptyUpdateSendsNothing() {
        var state = settled()
        let replies = O.update(
            &state, ids: [], lastIDs: [],
            hasEarlier: true, olderSettled: true, olderError: nil)
        #expect(replies.isEmpty)
    }

    // MARK: - chat.loadOlder

    /// The scan reached the beginning with no rows: an empty prepend with
    /// `hasEarlier: false` **is** the answer (the page prints "start of
    /// history" and stops asking).
    @Test func testOlderAtTheBeginningIsAnsweredWithAnEmptyPrepend() {
        var state = settled()
        O.olderStarted(&state)
        let replies = O.update(
            &state, ids: ["m1"], lastIDs: ["m1"],
            hasEarlier: false, olderSettled: true, olderError: nil)
        #expect(replies == [.prepend(upTo: 0, hasEarlier: false, error: nil)])
        #expect(!state.awaitsOlder)
    }

    /// Still running: no answer yet, and the flag stays up so the settle
    /// that follows answers.
    @Test func testOlderStillRunningIsNotAnsweredYet() {
        var state = settled()
        O.olderStarted(&state)
        let replies = O.update(
            &state, ids: ["m1"], lastIDs: ["m1"],
            hasEarlier: true, olderSettled: false, olderError: nil)
        #expect(replies.isEmpty)
        #expect(state.awaitsOlder)
    }

    /// **A failed read is an explicit answer**, not "start of history":
    /// the empty prepend carries the host's reason.
    @Test func testOlderFailureCarriesItsReason() {
        var state = settled()
        O.olderStarted(&state)
        let replies = O.update(
            &state, ids: ["m1"], lastIDs: ["m1"],
            hasEarlier: true, olderSettled: true, olderError: "BadParams")
        #expect(replies == [.prepend(upTo: 0, hasEarlier: true, error: "BadParams")])
        #expect(!state.awaitsOlder)
    }

    /// **A failure outranks `hasEarlier: false`**: `reachedBeginning` is
    /// false for a failed scan, but the page must still say "could not read"
    /// rather than "start of history" (task 3098).
    @Test func testOlderFailureIsNotTheBeginning() {
        var state = settled()
        O.olderStarted(&state)
        let replies = O.update(
            &state, ids: ["m1"], lastIDs: ["m1"],
            hasEarlier: false, olderSettled: true, olderError: "BadParams")
        #expect(replies == [.prepend(upTo: 0, hasEarlier: true, error: "BadParams")])
    }

    /// Rows arrived in front: that prepend is the answer, and no extra empty
    /// one follows.
    @Test func testPrependedRowsAreTheAnswer() {
        var state = settled()
        O.olderStarted(&state)
        let replies = O.update(
            &state, ids: ["m0", "m1"], lastIDs: ["m1"],
            hasEarlier: true, olderSettled: true, olderError: nil)
        #expect(replies == [.prepend(upTo: 1, hasEarlier: true, error: nil)])
        #expect(!state.awaitsOlder)
    }

    /// Nothing to ask at all (the owner answered on the spot): the reply is
    /// the empty prepend, with the reason when the read failed.
    @Test func testOlderAnsweredOnTheSpot() {
        #expect(O.olderAnswered(hasEarlier: false, error: nil)
                == .prepend(upTo: 0, hasEarlier: false, error: nil))
        #expect(O.olderAnswered(hasEarlier: true, error: "gap")
                == .prepend(upTo: 0, hasEarlier: true, error: "gap"))
    }

    /// A live message and an older read that ended empty can land in one
    /// pass: the page is owed both, and the prepend is the older answer.
    @Test func testAppendAndOlderEndInOnePassAreTwoReplies() {
        var state = settled()
        O.olderStarted(&state)
        let replies = O.update(
            &state, ids: ["m1", "m2"], lastIDs: ["m1"],
            hasEarlier: false, olderSettled: true, olderError: nil)
        #expect(replies == [
            .append(from: 1),
            .prepend(upTo: 0, hasEarlier: false, error: nil),
        ])
        #expect(!state.awaitsOlder)
    }
}
