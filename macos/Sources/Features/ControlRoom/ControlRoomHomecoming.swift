import Foundation

/// The keyboard in a terminal's own tab after the control room gives the
/// terminal back (`dev-docs/poltergeist/control-room.md`, 12.5).
///
/// Giving back is saying "no longer lent"; the pane then takes the view
/// back when it next draws, which is not when it was said -- a tab behind
/// another draws later, and how much later is not ours to know. Its window
/// lost its first responder when the view left, so until the view is back
/// in it there is nothing to hand the keyboard to. **So this waits for the
/// view to arrive rather than for an amount of time**: `returned` says a
/// terminal is on its way home, and `settle` is asked every time something
/// happens that could finish the job -- the view moved into a window, or
/// its own window became the key one.
struct ControlRoomHomecoming: Equatable {
    /// What the terminal's own tab is like at the moment of asking.
    struct Home: Equatable {
        /// The view is in its own tab's window again.
        var attached: Bool
        /// Its tab still counts it as the pane that has the keyboard there.
        var isFocusedPane: Bool
        /// Nothing in that window has the keyboard: the first responder is
        /// the window itself.
        var keyboardIsUnclaimed: Bool
    }

    enum Step: Equatable {
        /// Make the terminal's own window the key one and bring it forward.
        case makeKey
        /// Hand that window's keyboard to the terminal.
        case takeKeyboard
    }

    /// Terminals on their way home, and whether the person asked for each
    /// one back (so it gets the keyboard and its window comes forward).
    private(set) var awaited: [String: Bool] = [:]

    /// The control room let go of `terminal` and its own tab is still
    /// there. `wanted` when the person asked for it back from its tab.
    mutating func returned(_ terminal: String, wanted: Bool) {
        awaited[terminal] = wanted
    }

    /// Borrowed again, or its tab went: it is not coming home.
    mutating func cancelled(_ terminal: String) {
        awaited[terminal] = nil
    }

    /// What to do for `terminal` now that its own tab is like `home`.
    /// Nothing until the view is back in its window; then once, and never
    /// again for that return.
    mutating func settle(_ terminal: String, home: Home) -> [Step] {
        guard let wanted = awaited[terminal], home.attached else { return [] }
        awaited[terminal] = nil
        if wanted { return [.makeKey, .takeKeyboard] }
        // Nobody asked for it: put the keyboard back where it was and
        // nowhere else. Another pane that took it meanwhile keeps it.
        return home.isFocusedPane && home.keyboardIsUnclaimed ? [.takeKeyboard] : []
    }

    /// Whether something done to a terminal -- zooming its pane, asking for
    /// it to be shown -- may bring its own window forward and give that
    /// window the keyboard. Not while it is lent: the person is looking at
    /// it in the control room, and the keyboard is there.
    static func homeComesForward(lent: Bool) -> Bool {
        !lent
    }

    /// Whether, after something changed the layout of a lent terminal's
    /// own tab, the pane that had the keyboard there is handed it again.
    /// Changing the layout rebuilds the panes, and the window's keyboard
    /// falls to nothing; ordinarily the terminal the action was about is
    /// focused next, which is not done for a lent one. So the pane that
    /// had it gets it back -- unless that pane is the lent terminal, whose
    /// keyboard is in the control room.
    static func focusedPaneKeepsKeyboard(focusedPaneIsLent: Bool) -> Bool {
        !focusedPaneIsLent
    }
}

/// Search bars that were open on a terminal when it moved.
///
/// A search bar takes the keyboard when it appears, which is right when
/// the person has just opened it and wrong when it appears only because
/// its terminal was put in another view. Each move notes the search that
/// was open; the next time that same search's bar appears it leaves the
/// keyboard alone, once. A search opened afterwards is another object and
/// is not held back.
struct ControlRoomMovedSearches<Search: AnyObject> {
    private struct Held { weak var search: Search? }
    private var held: [Held] = []

    /// `search` was open on a terminal that is being moved.
    mutating func moved(_ search: Search) {
        held.removeAll { $0.search == nil || $0.search === search }
        held.append(Held(search: search))
    }

    /// Whether the bar of `search`, appearing now, may take the keyboard.
    mutating func mayTakeKeyboard(_ search: Search) -> Bool {
        held.removeAll { $0.search == nil }
        guard let at = held.firstIndex(where: { $0.search === search }) else { return true }
        held.remove(at: at)
        return false
    }
}
