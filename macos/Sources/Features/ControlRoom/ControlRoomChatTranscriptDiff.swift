import Foundation

/// **How a list of row ids changed between two updates** (task 3084).
///
/// The chat page's bridge sends the smallest message that makes the page
/// agree with the host: `page.append` for rows gained at the end,
/// `page.prepend` for rows gained at the front, and `page.reset` for
/// anything else -- a window that slid, another map, a reload.
///
/// **This is not the scroll model.** It was the native list's anchor
/// classifier when that list also needed it to tell "the window slid" from
/// "these are all new"; the anchor and its camera went with that list
/// (design v3 §七), and the one reader left is the page bridge, so the rule
/// lives beside the page contract it serves.
enum ControlRoomChatTranscriptDiff {
    /// What a row list did between two of its states.
    ///
    /// **`moved` is the sliding window**: rows left the document at one end
    /// and others came in at either end. It is *not* `replaced` -- the rows
    /// the page is holding are the same rows, and a replacement would make
    /// it build the whole list again. `replaced` is kept for a window that
    /// really is another map: a locate's around page, a session change, a
    /// restart.
    enum Change: Equatable {
        case none
        /// Rows went in front, nothing else changed.
        case prepended
        /// Rows went on the end, nothing else changed.
        case appended
        /// The window slid or was trimmed: a contiguous run is still there,
        /// the ends are not what they were.
        case moved
        /// Another map: no contiguous run of the old rows is in the new.
        case replaced
    }

    /// **Which of the five things happened to the list.** A contiguous run
    /// of the old rows surviving in the new one, with the rest added or
    /// removed at the ends, is a window move -- **not a replacement**.
    ///
    /// Row ids are unique within a list, which is what makes the run easy
    /// to find: the first and the last old id still in the new list bound
    /// it, and everything outside it must be an end.
    static func change(from old: [String], to new: [String]) -> Change {
        if old == new { return .none }
        if old.isEmpty { return new.isEmpty ? .none : .appended }
        guard !new.isEmpty else { return .replaced }
        let present = Set(new)
        guard let oldStart = old.firstIndex(where: present.contains),
              let oldEnd = old.lastIndex(where: present.contains),
              let newStart = new.firstIndex(of: old[oldStart]),
              let newEnd = new.firstIndex(of: old[oldEnd])
        else { return .replaced }
        let kept = Array(old[oldStart...oldEnd])
        guard newEnd - newStart + 1 == kept.count,
              Array(new[newStart...newEnd]) == kept
        else { return .replaced }
        // A row that left the middle of the kept run is not a window move:
        // the surviving ids would bound a run that no longer matches.
        let addedFront = newStart
        let addedBack = new.count - 1 - newEnd
        let droppedFront = oldStart
        let droppedBack = old.count - 1 - oldEnd
        if addedFront == 0, droppedFront == 0, droppedBack == 0, addedBack > 0 {
            return .appended
        }
        if addedBack == 0, droppedBack == 0, droppedFront == 0, addedFront > 0 {
            return .prepended
        }
        return .moved
    }
}

/// **What the bridge owes the page, as a value** (task 3098).
///
/// The page's two rules -- every `chat.ready` gets a `page.reset`, every
/// `chat.loadOlder` gets a `page.prepend` -- were conditions in the bridge,
/// and a condition in a `WKWebView` delegate is a rule no test can hold. The
/// decision is here, plain values in and a list of replies out; the bridge
/// only builds the JSON. **This is the one implementation**: the bridge calls
/// it, so a test here is a test of the shipped rule, not a second copy.
enum ControlRoomChatTranscriptObligations {
    /// One message the page is owed.
    enum Reply: Equatable {
        /// The whole document.
        case reset
        /// The rows from `from` on, one `page.append` each.
        case append(from: Int)
        /// The rows before `upTo` in one `page.prepend`. `upTo == 0` is the
        /// empty answer (the beginning, or a read that failed).
        case prepend(upTo: Int, hasEarlier: Bool, error: String?)
    }

    struct State: Equatable {
        /// **Not `lastIDs.isEmpty`.** An empty first screen is a valid reset,
        /// and after it the id list is still empty; keying the first reset
        /// off it would reset once per update on an empty group. "The one
        /// reset a ready page is owed has been sent" is the condition the
        /// diff actually needs.
        var sentInitialReset = false
        /// A `chat.loadOlder` whose answer has not gone out yet.
        var awaitsOlder = false
    }

    /// `chat.ready`: one reset, always -- the empty page included.
    static func ready(_ state: inout State) -> Reply {
        state.sentInitialReset = true
        return .reset
    }

    /// A `chat.loadOlder` the owner answered on the spot: nothing to ask.
    static func olderAnswered(hasEarlier: Bool, error: String?) -> Reply {
        .prepend(upTo: 0, hasEarlier: hasEarlier, error: error)
    }

    /// A `chat.loadOlder` that started a scan: the answer is a later update.
    static func olderStarted(_ state: inout State) {
        state.awaitsOlder = true
    }

    /// One `update`, as the replies it owes. More than one is possible: a
    /// live message can be appended in the same pass that answers an older
    /// request with "this is the beginning".
    static func update(
        _ state: inout State,
        ids: [String],
        lastIDs: [String],
        hasEarlier: Bool,
        olderSettled: Bool,
        olderError: String?
    ) -> [Reply] {
        if !state.sentInitialReset {
            state.sentInitialReset = true
            return [.reset]
        }
        var replies: [Reply] = []
        var answeredOlder = false
        switch ControlRoomChatTranscriptDiff.change(from: lastIDs, to: ids) {
        case .none:
            break
        case .appended:
            replies.append(.append(from: lastIDs.count))
        case .prepended:
            replies.append(.prepend(
                upTo: ids.count - lastIDs.count,
                hasEarlier: hasEarlier,
                error: nil))
            answeredOlder = true
        case .moved, .replaced:
            replies.append(.reset)
            answeredOlder = true
        }
        if state.awaitsOlder {
            if answeredOlder {
                state.awaitsOlder = false
            } else if olderSettled, olderError != nil {
                // **A failure is not the beginning**, whatever `hasEarlier`
                // says: the page must print the reason, not "start of
                // history" (task 3098).
                state.awaitsOlder = false
                replies.append(.prepend(upTo: 0, hasEarlier: true, error: olderError))
            } else if !hasEarlier {
                // The scan reached the beginning and brought no rows: the
                // empty prepend **is** the answer (`CONTRACT.md` §3.2).
                state.awaitsOlder = false
                replies.append(.prepend(upTo: 0, hasEarlier: false, error: nil))
            } else if olderSettled {
                // Stopped without reaching the beginning and without a
                // failure to name (cancelled): still an answer, never
                // silence.
                state.awaitsOlder = false
                replies.append(.prepend(upTo: 0, hasEarlier: true, error: nil))
            }
        }
        return replies
    }
}
