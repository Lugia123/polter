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

    // MARK: At launch (task 1581)

    /// What the application does about the control room as it starts
    /// (`polter-control-room-at-launch`). The Windows host's
    /// `rules::at_launch`; the two are held to one table by their tests.
    enum AtLaunch: Equatable {
        /// As before the setting existed.
        case nothing
        /// Nothing was restored: one window, the control room its first tab
        /// and an empty terminal its second, with the control room in front.
        case ownWindow
        /// Terminals were restored and the control room was not: it goes
        /// first among the front window's tabs, behind the tab that is in
        /// front, which keeps the keyboard. No terminal is added.
        case firstTabBehind
    }

    /// - `enabled`: `polter-control-room-at-launch`.
    /// - `restoredTerminals`: terminal windows the launch restored.
    /// - `roomRestored`: the control room was among what it restored.
    /// - `initialWindow`: `initial-window`; with nothing restored and this
    ///   off, the application opens no window, and this setting does not
    ///   make it.
    static func atLaunch(enabled: Bool, restoredTerminals: Int, roomRestored: Bool, initialWindow: Bool) -> AtLaunch {
        if !enabled || roomRestored { return .nothing }
        if restoredTerminals > 0 { return .firstTabBehind }
        return initialWindow ? .ownWindow : .nothing
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

    /// What is kept: that it was open (the state existing at all), which
    /// group was selected, and whether it was a tab among terminal tabs
    /// and the one in front. Nothing else -- the list is the core's and is
    /// asked for again.
    struct Restorable: Codable, Equatable {
        static let currentVersion = 1

        var version: Int
        var selection: String?
        /// It was a tab beside terminal tabs, not a window of its own. Nil
        /// in a state written before this was kept: then it stays wherever
        /// the system puts it.
        var tabbed: Bool?
        /// It was the tab in front in its group.
        var inFront: Bool?

        init(selection: String?, tabbed: Bool? = nil, inFront: Bool? = nil) {
            self.version = Self.currentVersion
            self.selection = selection
            self.tabbed = tabbed
            self.inFront = inFront
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

    /// Which of the restored groups of terminal tabs the control room goes
    /// back into, as an index into `groups`; nil to stay a window of its
    /// own.
    ///
    /// The system puts restored windows back into their tab groups by a
    /// name the windows share, and the control room's window does not get
    /// the terminals' name on its own (it is given it when it is opened as
    /// a tab) -- so it comes back alone, in the place its group was. Tabs
    /// of one group are one frame, so "its group" is the one restored to
    /// the frame the control room was restored to. With no such group --
    /// those tabs were closed before the restart, or it was a window of
    /// its own -- it stays alone.
    static func groupToRejoin(wasTabbed: Bool?, alone: Bool, frame: CGRect, groups: [CGRect]) -> Int? {
        guard wasTabbed == true, alone else { return nil }
        return groups.firstIndex(of: frame)
    }

    /// The selection to start with after a restart: the one that was kept,
    /// if that group is still listed; otherwise none. A group that went
    /// away overnight must not leave a selection pointing at nothing.
    static func restoredSelection(_ kept: String?, in rows: [ControlRoomList.Row]) -> String? {
        guard let kept, rows.contains(where: { $0.id == kept }) else { return nil }
        return kept
    }

    /// What the Dock icon's badge says; nil for no badge.
    ///
    /// The number is the core's `needs_me` -- terminals that cannot move
    /// until the person does something, each counted once, by the core --
    /// written as it came. None waiting is no badge. With nobody waiting,
    /// the badge is whatever it was before this number existed: how many
    /// windows rang their bell, when the person asked for that (`bells` is
    /// that text, already made). 暂定: waiting comes before bells and the
    /// two are never added together -- they count different things.
    /// Whether the list should take the keyboard when the control room
    /// becomes the key window. Only when the window itself is first
    /// responder, which is nobody: a terminal the person clicked into, the
    /// list itself, a text field -- all of those keep it.
    static func listTakesKeyboard(firstResponderIsTheWindow: Bool) -> Bool {
        firstResponderIsTheWindow
    }

    static func dockBadge(needsMe: Int?, bells: String?) -> String? {
        guard let needsMe, needsMe != 0 else { return bells }
        return String(needsMe)
    }

    /// What becomes of "new split" asked of a terminal.
    enum NewSplit: Equatable {
        /// Split it.
        case split
        /// Not done, and the person who pressed the key hears so.
        case refuseAloud
    }

    /// `lent` is whether the control room has borrowed the terminal;
    /// `answerWanted` is whether the request came with somewhere to write
    /// the answer (an agent's, through the core) rather than from a key.
    ///
    /// **A key pressed on a borrowed terminal is refused**: the new pane
    /// would open in the terminal's own tab, behind the control room,
    /// where the person who pressed it cannot see it.
    ///
    /// **An agent's request is carried out.** The terminal never left its
    /// tab's split tree -- only its view is on the control room's right --
    /// so the split is made there, in its own tab, as it would have been.
    /// It used to be refused too, and the core then opened a tab instead:
    /// a supervisor the person was watching in the control room opened
    /// every worker as a new tab, three in a row on a real window (the
    /// user, 2026-10-13: "it always opens a new tab"). An agent does not
    /// need to see the pane it asked for, and the person finds it where
    /// the supervisor's other panes are.
    static func newSplit(lent: Bool, answerWanted: Bool) -> NewSplit {
        guard lent else { return .split }
        return answerWanted ? .split : .refuseAloud
    }

    /// Whether a new split takes the keyboard in its window. Not when the
    /// terminal it was split from is in the control room: that window is
    /// behind, and the terminal that would be told it lost the keyboard is
    /// the one the person may be typing into on the control room's right.
    static func newSplitTakesKeyboard(fromLent lent: Bool) -> Bool {
        !lent
    }

    /// What becomes of "new tab" asked of a terminal whose window may not
    /// take one.
    enum NewTabAnswer: Equatable {
        /// Go on and open it.
        case open
        /// Not opened; whoever asked through the core is told so, and the
        /// person is shown nothing -- they did not ask.
        case refuseToTheCore(String)
        /// Not opened; the person pressed the key and is told why.
        case tellThePerson
    }

    /// `homeTakesTabs` is whether the terminal's own window is an ordinary
    /// terminal window (the quick terminal is not); `decorations` is
    /// whether windows have a title bar to put tabs in; `answerWanted` is
    /// whether the request came with somewhere to write the answer (an
    /// agent's, through the core) rather than from a key.
    ///
    /// **A window that takes no tabs used to answer an agent with a dialog
    /// on the person's screen and "done"**, so `terminal_open` came back ok
    /// with no terminal. A borrowed terminal is refused to the core even
    /// with no answer wanted: its window is behind the control room, and a
    /// dialog about it would be about something the person cannot see.
    static func newTabAnswer(lent: Bool, homeTakesTabs: Bool, decorations: Bool, answerWanted: Bool) -> NewTabAnswer {
        if homeTakesTabs, decorations { return .open }
        let why = decorations
            ? "the terminal's own window takes no tabs"
            : "tabs are off: windows have no decorations"
        if answerWanted || lent { return .refuseToTheCore(why) }
        return .tellThePerson
    }

    /// A group the person has just made is selected once the core lists
    /// it -- not before: the list that is on screen when the answer comes
    /// back may be the one from before the group existed, and a selection
    /// that names no row is dropped (`restoredSelection`). `awaited` is the
    /// name they gave it; the answer is that name when a row has it.
    static func madeGroupToSelect(_ awaited: String?, in rows: [ControlRoomList.Row]) -> String? {
        guard let awaited, rows.contains(where: { $0.id == awaited }) else { return nil }
        return awaited
    }

    /// Where a tab the core asked for goes.
    enum NewTab: Equatable {
        /// Beside the terminal it was asked from, and in front: what a key
        /// and a menu item have always done.
        case inFront(of: Home)
        /// In a terminal window, as a tab of it, **without being brought in
        /// front**: the person is looking at the control room and stays
        /// there.
        case behind(Home)
        /// In a window of its own: there is no terminal window to put a
        /// tab in, and the control room is not where the person is.
        case ownWindow
        /// Not opened, and the core is told so. Nothing holds the terminal
        /// it was asked from.
        case refused

        enum Home: Equatable {
            /// The window of the terminal the tab was asked from -- its own
            /// tab's, wherever its view is at the moment.
            case askers
            /// The window the control room is a tab of: among the terminal
            /// tabs it sits with, and with none there yet, as the first
            /// one beside it.
            case controlRooms
            /// The terminal window the person used last.
            case frontmost
        }
    }

    /// `asker` is the terminal the tab was asked from, when there is one:
    /// whether the control room has borrowed it, and whether a terminal
    /// window still holds it. With no asker the request came from the
    /// application itself -- the control room starting a supervisor is one --
    /// and the three facts after it say where there is room.
    ///
    /// **A borrowed terminal's tab goes into its own window, behind.** Its
    /// view is in the control room's window, which takes no terminal tabs;
    /// asking that window for a tab opened nothing at all and answered
    /// "done" (the supervisor's `terminal_open`, 2026-10-13).
    ///
    /// **The control room alone on screen takes the tab into its own
    /// window.** This answered `.ownWindow` -- "no terminal window to put a
    /// tab in" -- and starting a supervisor from a control room that was the
    /// only window put it in a second window (the user, 2026-10-13). The
    /// control room's window does take terminal tabs; what it lacked was
    /// anybody adding the first one.
    ///
    /// **A tab the person asked for comes in front.** `byPerson` is a key
    /// or a menu item; false is the application's own -- the control room
    /// starting a supervisor, an agent's `terminal_open`. "Behind" is for
    /// those: the person pressing New Tab on the control room is asking to
    /// go to that tab, and it goes into the control room's own window
    /// rather than whichever terminal window was used last.
    static func newTab(
        asker: (lent: Bool, hasHome: Bool)?,
        byPerson: Bool,
        controlRoomInFront: Bool,
        tabsBesideControlRoom: Bool,
        anyTerminalWindow: Bool
    ) -> NewTab {
        if let asker {
            guard asker.hasHome else { return .refused }
            return asker.lent ? .behind(.askers) : .inFront(of: .askers)
        }
        if controlRoomInFront {
            // The application's own, asked while the person is on the
            // control room, goes into the control room's window and stays
            // behind -- wherever else there is a terminal window. It used
            // to go to that other window and come in front there, which
            // took the person off the control room they had just pressed
            // "Start Supervisor" on.
            if !byPerson { return .behind(.controlRooms) }
            if tabsBesideControlRoom || !anyTerminalWindow { return .inFront(of: .controlRooms) }
        }
        return anyTerminalWindow ? .inFront(of: .frontmost) : .ownWindow
    }

    // MARK: The Project menu

    /// The three items of the Project menu.
    enum ProjectItem: Equatable, CaseIterable {
        case saveAs
        case load
        case manage
    }

    /// Whether an item of the Project menu can be chosen while the control
    /// room is the window with the keyboard.
    ///
    /// All three were greyed there, and for no reason anybody wrote down:
    /// the items go to whoever in the window answers to them, and in the
    /// control room's window nobody did (the user, 2026-10-13: "I cannot
    /// load a project"). This is the reason, written down.
    ///
    /// Loading and managing need no terminal: a project opens as a new tab
    /// (`newTab` says where), and the list of projects is the
    /// application's. Saving saves a tab, and the control room is not one
    /// that can be saved -- so it saves the tab of the terminal it has
    /// borrowed, and with none borrowed, or one whose tab is gone, there is
    /// nothing to save.
    static func projectItemOffered(_ item: ProjectItem, lentTerminalHasTab: Bool) -> Bool {
        switch item {
        case .load, .manage: return true
        case .saveAs: return lentTerminalHasTab
        }
    }

    /// Where a project the person loaded from the control room's menu
    /// opens, and that it comes in front.
    ///
    /// The place is `newTab`'s, asked with nothing as the asker: among the
    /// terminal tabs the control room sits with when there are any, else in
    /// the terminal window used last, else -- no terminal window anywhere --
    /// as the first tab beside the control room. **It is
    /// never left behind.** "Behind" is for a tab an agent asked for while
    /// the person is looking at the control room; this one the person
    /// chose themselves, and a project that opened where they cannot see
    /// it reads as a menu item that did nothing (the user, 2026-10-13).
    static func loadedProjectTab(tabsBesideControlRoom: Bool, anyTerminalWindow: Bool) -> NewTab {
        newTab(
            asker: nil,
            // It was chosen from the control room's own menu.
            byPerson: true,
            controlRoomInFront: true,
            tabsBesideControlRoom: tabsBesideControlRoom,
            anyTerminalWindow: anyTerminalWindow)
    }

    /// Whether opening a tab brings the application in front of whatever
    /// the person is using.
    ///
    /// A tab the person asked for -- a key, a menu item, the Dock's menu --
    /// does, as it always has. One an agent asked for does not: with the
    /// application behind another, the tab opens where it would have and
    /// the application stays behind. It used to come forward every time,
    /// taking the keyboard from whatever the person was typing into, each
    /// time an agent opened a terminal for itself.
    ///
    /// `answerWanted` is whether the request came with somewhere to write
    /// an answer: an agent's does and a key press's does not
    /// (`apprt.action.NewTab.result`).
    static func newTabActivates(answerWanted: Bool, appIsActive: Bool) -> Bool {
        !answerWanted || appIsActive
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

    // MARK: Return on the list

    /// Who a Return pressed in the left-hand side is for (task 1554).
    enum ReturnOwner: Equatable {
        /// The text box with the keyboard -- the new group's name, or any
        /// other: the box submits it, nothing else happens.
        case text
        /// The list itself: go to the selected group's supervisor (#1551).
        case list
        /// Neither: not answered here.
        case nobody
    }

    /// **A text box first, always.** The list's own focus says true while
    /// the keyboard is anywhere inside it -- the name field is inside it --
    /// so "the list has the keyboard" alone took the Return from the field
    /// and went to a supervisor instead of making the group (#1554).
    static func returnOwner(textHasKeyboard: Bool, listHasKeyboard: Bool, hasSelection: Bool) -> ReturnOwner {
        if textHasKeyboard { return .text }
        if listHasKeyboard && hasSelection { return .list }
        return .nobody
    }
}
