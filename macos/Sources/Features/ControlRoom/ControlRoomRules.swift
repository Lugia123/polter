import Foundation

/// The control room's decisions that need no window to make: what a trigger
/// does, where a new one goes, what closing it involves, and what is kept
/// across a restart.
///
/// Out of the controller so they can be tested without one. The controller
/// asks these and does what they say.
///
/// The three rulings marked 暂定 are the supervisor's and not yet the
/// user's: it can be closed; there is one in the application; it starts as
/// the first tab and is not pulled back when the person moves it.
enum ControlRoomRules {
    // MARK: One in the application

    enum Trigger: Equatable {
        /// It is open somewhere: go to it. Never a second one. (暂定)
        case select
        /// It is not open, and there is a terminal window that takes tabs:
        /// open it as that window's first tab. (暂定: first, and only at
        /// creation.)
        case openAsFirstTab
        /// It is not open, and there is nowhere to put a tab -- no terminal
        /// window, or one whose style has no tabs: open it in a window of
        /// its own.
        case openInOwnWindow
    }

    /// What the menu item, the key binding and the command palette entry
    /// all do.
    static func trigger(isOpen: Bool, parentTakesTabs: Bool?) -> Trigger {
        if isOpen { return .select }
        return parentTakesTabs == true ? .openAsFirstTab : .openInOwnWindow
    }

    // MARK: Closing

    enum CloseTab: Equatable {
        /// Close it. It holds no process and loses nothing: opening it
        /// again shows the same thing. (暂定: that it can be closed.)
        case close
    }

    /// Closing the control room's own tab. Never asks.
    static func closeTab() -> CloseTab { .close }

    enum CloseWindow: Equatable {
        /// There are terminal tabs beside it: closing the window is theirs
        /// to agree to, so the request goes to one of them, which runs the
        /// same confirmation it runs for itself.
        case askATerminalTab
        /// It is alone in its window: just close.
        case close
    }

    /// "Close Window" while the control room is the selected tab.
    static func closeWindow(terminalTabsBeside: Int) -> CloseWindow {
        terminalTabsBeside > 0 ? .askATerminalTab : .close
    }

    enum CloseRequest: Equatable {
        /// Close this tab and nothing else.
        case closeSelf
        /// The whole window is going: hand it to a terminal tab, which asks
        /// about every terminal in the group and then closes every window
        /// in it, this one included.
        case askATerminalTab
        /// The whole window is going and another tab is the one that
        /// answers for it; it will close this one too.
        case leaveItToTheFirstTab
    }

    /// What to do when the system asks this tab's window to close (the red
    /// button, the tab's own close button, "Close Other Tabs").
    ///
    /// The system asks every tab's window separately and does not say
    /// whether it is closing one tab or the window. The terminals settle
    /// that between them (`TabGroupCloseCoordinator`) and then **only the
    /// first tab in the group acts on "the window"** -- so when the control
    /// room is that first tab, which is where it opens, it has to be the
    /// one that acts, or the window never closes.
    static func closeRequest(wholeWindow: Bool, isFirstTab: Bool, terminalTabsBeside: Int) -> CloseRequest {
        guard wholeWindow else { return .closeSelf }
        guard isFirstTab else { return .leaveItToTheFirstTab }
        return terminalTabsBeside > 0 ? .askATerminalTab : .closeSelf
    }

    // MARK: Going to a tab by number

    /// A key and the modifiers held with it, in whatever form the caller
    /// compares them: the same form on both sides.
    struct Chord: Equatable {
        var key: String
        var modifiers: UInt
    }

    /// The tab a key press goes to, as an index into the group, or nil when
    /// the press is not one of the "go to tab N" shortcuts.
    ///
    /// The control room has no terminal in it, and "go to tab N" is a
    /// binding the core delivers to a terminal -- so on this tab the
    /// shortcut written on every other tab would do nothing. `shortcuts`
    /// is what the configuration binds for tabs 1, 2, 3… in that order (nil
    /// where one is unbound). A number past the last tab goes to the last,
    /// as it does from a terminal.
    static func tabIndex(for pressed: Chord, shortcuts: [Chord?], tabCount: Int) -> Int? {
        guard tabCount > 0 else { return nil }
        for (n, shortcut) in shortcuts.enumerated() {
            guard let shortcut, shortcut.modifiers == pressed.modifiers,
                  shortcut.key.caseInsensitiveCompare(pressed.key) == .orderedSame else { continue }
            return min(n, tabCount - 1)
        }
        return nil
    }

    // MARK: Across a restart

    /// What is kept: that it was open (the state existing at all), and
    /// which group was selected. Nothing else -- the list is the core's and
    /// is asked for again.
    struct Restorable: Codable, Equatable {
        static let currentVersion = 1

        var version: Int
        var selection: String?

        init(selection: String?) {
            self.version = Self.currentVersion
            self.selection = selection
        }

        func encoded() -> Data? {
            try? JSONEncoder().encode(self)
        }

        /// Nil for anything this build did not write: bytes that are not
        /// this, or a version from a later build. A control room that comes
        /// back without its selection is fine; one restored from a state it
        /// misread is not.
        static func decode(_ data: Data?) -> Restorable? {
            guard let data,
                  let state = try? JSONDecoder().decode(Restorable.self, from: data),
                  state.version == currentVersion else { return nil }
            return state
        }
    }

    /// The selection to start with after a restart: the one that was kept,
    /// if that group is still listed; otherwise none. A group that went
    /// away overnight must not leave a selection pointing at nothing.
    static func restoredSelection(_ kept: String?, in rows: [ControlRoomList.Row]) -> String? {
        guard let kept, rows.contains(where: { $0.id == kept }) else { return nil }
        return kept
    }

    /// What becomes of "new split" asked of a terminal.
    enum NewSplit: Equatable {
        /// Split it.
        case split
        /// Not done, and the person who pressed the key hears so.
        case refuseAloud
        /// Not done; whoever asked through the core is answered by the
        /// core, which opens a tab instead and says why.
        case refuseToTheCore
    }

    /// A terminal the control room has borrowed is not split: the new pane
    /// would open in its own tab, which is behind the control room, where
    /// the person who pressed the key cannot see it. `lent` is whether the
    /// control room has it; `answerWanted` is whether the request came with
    /// somewhere to write the answer (an agent's, through the core) rather
    /// than from a key.
    static func newSplit(lent: Bool, answerWanted: Bool) -> NewSplit {
        guard lent else { return .split }
        return answerWanted ? .refuseToTheCore : .refuseAloud
    }

    /// What is selected once a snapshot has arrived, and whose choice it
    /// is. `current` is what is selected already (after
    /// `restoredSelection`); `opening` is true for the first snapshot the
    /// control room sees since it was opened; `openOn` is the group the
    /// core says to start on.
    ///
    /// A selection that stands is never replaced. With none, the control
    /// room that has just opened starts on the core's group -- and that is
    /// nobody's choice: the person has not looked at that row by its being
    /// selected for them, so it does not count towards "seen". Later, with
    /// nothing selected, nothing is selected for them: the row they were
    /// on went away, and jumping to another would be a surprise.
    static func selection(current: String?, opening: Bool, openOn: String?) -> (id: String?, isThePersons: Bool) {
        if let current { return (current, true) }
        guard opening, let openOn else { return (nil, true) }
        return (openOn, false)
    }
}
