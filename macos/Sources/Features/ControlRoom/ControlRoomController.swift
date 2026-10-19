import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// The control room, as a tab among the terminal tabs
/// (`dev-docs/poltergeist/control-room.md`, 3.1).
///
/// **It is not a terminal controller, and its window is a terminal
/// window.** Every tab on macOS is a window of its own, joined to the others
/// by the system. This one has no surface tree, so it does not pretend to be
/// a `TerminalController` -- that class closes itself the moment its tree is
/// empty. But its window is loaded from the same nib as a terminal's, so it
/// is the same `TerminalWindow` subclass the person's titlebar style picked:
/// the tab bar is one bar, and `TerminalController.relabelTabs` -- which
/// casts the whole group to `[TerminalWindow]` and labels none of them if
/// one is not -- keeps working.
///
/// What is decided here on the supervisor's say and not yet the user's
/// (暂定), all of it in `ControlRoomRules`: it can be closed and comes back
/// from the menu; there is one in the application; it opens as the first tab
/// and stays wherever the person drags it.
final class ControlRoomController: NSWindowController, NSWindowDelegate, TabGroupCloseCoordinator.Controller {
    /// The one control room, while it is open.
    private(set) static var shared: ControlRoomController?

    private let ghostty: Ghostty.App
    let model: ControlRoomModel
    let detail = ControlRoomDetailContainer()

    /// The terminals work out between them whether a close is of one tab or
    /// of the window, through the coordinator of the group's first tab. The
    /// control room opens as that first tab, so it has to have one.
    let tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    override var windowNibName: NSNib.Name? {
        TerminalController.windowNibName(for: ghostty.config)
    }

    private var seen: ControlRoomSeenTracker?
    /// Watches which view has this window's keyboard: the frame on the
    /// right says whether its terminal does.
    private var watchingResponder: NSKeyValueObservation?
    private var watchingSelection: AnyCancellable?
    private var watchingList: AnyCancellable?

    /// Which terminal is on the right-hand side, and what has to happen to
    /// it next. Every change goes through `lend(_:)`.
    private var lending = ControlRoomLending()
    private let lender = ControlRoomLender.shared

    /// "Load Project" chosen here opens its list from here.
    private let projectPicker = ProjectPicker()

    /// Which cards are wholly on screen, as the list last said, and what
    /// the core was last told about where the person is (task 1505).
    private var cardsInSight: [String] = []
    private var presence = ControlRoomAlert.PresenceReporter()
    private var appActivity: [NSObjectProtocol] = []
    private var closing = false

    init(_ ghostty: Ghostty.App, selection: String? = nil) {
        self.ghostty = ghostty
        // The list is only ever on screen while this tab is the one in
        // front, so the tab "showing" in its window is its own -- which no
        // terminal is in, so the glyph that breathes here is simply the
        // longest-waiting one.
        var ownTab: () -> String? = { nil }
        self.model = ControlRoomModel(
            feed: ControlRoomFeed.shared(ghostty), selection: selection, showing: { ownTab() })
        super.init(window: nil)
        ownTab = { [weak self] in
            self?.window.map { ControlRoomPulse.id(UInt64(UInt(bitPattern: ObjectIdentifier($0)))) }
        }

        // Looking at a row for a moment, with this in front, marks its
        // group seen. See `ControlRoomSeenTracker`.
        let actions = ControlRoomActions.core(ghostty)
        let tracker = ControlRoomSeenTracker(
            later: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
            isInFront: { [weak self] in self?.isInFront ?? false },
            markSeen: { [weak self] group in
                do {
                    // A group's row by its name, a lone terminal's by its
                    // terminal (`ControlRoomActions.seen(rowId:in:)`).
                    guard let act = ControlRoomActions.seen(rowId: group, in: self?.model.list?.rows ?? []) else { return }
                    try actions.perform(act)
                } catch {
                    Ghostty.logger.warning("control room: seen was refused: \(String(describing: error), privacy: .public)")
                }
            })
        seen = tracker

        watchingSelection = model.$selection
            .removeDuplicates()
            .sink { [weak self] _ in
                // After the change has landed, so the row read is the new one.
                DispatchQueue.main.async { self?.noteSelection() }
            }

        // The right-hand side follows the selection and the snapshot: a
        // supervisor that changed or went away arrives as a new list.
        watchingList = model.$list
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // The selected row may have stopped while it was being
                    // looked at (`ControlRoomSeenTracker.listChanged`).
                    self.seen?.listChanged(to: self.model.rowBeingLookedAt)
                    self.syncDetail()
                }
            }
        model.onCardsInSight = { [weak self] cards in
            self?.cardsInSight = cards
            self?.reportPresence()
        }
        // **The application coming to the front is its own moment** (task
        // 1531). Clicking back from another application makes this window
        // key before `NSApp.isActive` is true, and nothing else follows to
        // ask again -- so the control room stayed "behind" while in front.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            appActivity.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportPresence() }
            })
        }
        model.askForTerminal = { [weak self] in self?.lend(.askedFor) }
        model.goToSupervisor = { [weak self] in self?.goToSupervisor() }
        model.goToTerminal = { id in
            guard let view = ControlRoomLender.surface(for: id) else { return }
            view.window?.makeKeyAndOrderFront(nil)
            Ghostty.moveFocus(to: view)
        }
        model.perform = { try actions.perform($0) }
        // The group's "Project ›" menu, its banner and its question
        // (task 1713).
        ProjectLinkDesk.start(ghostty)
        model.projectHands = ProjectLinkDesk.shared
        // Selecting the row that is already selected changes nothing the
        // sink above would see, and still means the person is on it now.
        model.onChoose = { [weak self] in
            DispatchQueue.main.async { self?.noteSelection() }
        }
        lender.onReclaim = { [weak self] view in
            guard let terminal = ControlRoomLender.terminal(of: view) else { return }
            self?.lend(.reclaimed(terminal: terminal))
        }
        lender.onHomeGone = { [weak self] view in
            guard let self, let terminal = self.lending.loan?.terminal, self.lender.isLent(view) else { return }
            self.lend(.homeGone(terminal: terminal))
        }
    }

    /// A terminal tab in the group of tabs this one sits in; nil when it
    /// is alone in its window. Where a tab opened from here goes.
    var terminalTabBeside: NSWindow? {
        window?.tabGroup?.windows.first { $0.windowController is TerminalController }
    }

    /// Open a terminal as the first terminal tab of this window -- behind
    /// this one, or with `inFront` selected and given the keyboard: where `ControlRoomRules.newTab` sends a tab asked for
    /// while the control room is the only window there is.
    ///
    /// `TerminalController.newTab` cannot do it: it opens a tab beside a
    /// terminal's window and reads that terminal's controller for the rest.
    /// A terminal window whose title-bar style takes no tabs opens as a
    /// window of its own, as it does everywhere else.
    @discardableResult
    func newFirstTerminalTab(
        withBaseConfig config: Ghostty.SurfaceConfiguration?, inFront: Bool
    ) -> TerminalController? {
        guard let window else { return nil }
        let controller = TerminalController(ghostty, withBaseConfig: config)
        guard let tab = controller.window else { return controller }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Tabs join by identifier, and this window's is its own until a
        // terminal has been beside it.
        window.tabbingIdentifier = tab.tabbingIdentifier
        guard tab.tabbingMode != .disallowed, window.addTabbedWindowSafely(tab, ordered: .above) else {
            controller.showWindowSafely(nil)
            return controller
        }
        if inFront {
            window.tabGroup?.selectedWindow = tab
            controller.showWindowSafely(nil)
        }
        // Behind, its terminal is running already -- the surface was made
        // with the controller -- and the tab shows it when it is selected.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Self.relabel() }
        return controller
    }

    /// Whether the person can be looking at the list: this tab is the one
    /// in front in the window that has the keyboard, in the application
    /// that is active.
    private var isInFront: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow
    }

    private func noteSelection() {
        // A row the control room opened on by itself is not being looked
        // at until the person selects it.
        seen?.selectionChanged(to: model.rowBeingLookedAt)
        syncDetail()
    }

    /// Coming to the front with a row already selected is a chance to look
    /// at it that selecting it earlier, behind something else, was not.
    func windowDidBecomeKey(_ notification: Notification) {
        if restoredAndNotYetPlaced {
            restoredAndNotYetPlaced = false
            bringOnScreen()
        }
        noteSelection()
        giveListTheKeyboardIfNobodyHasIt()
        syncLentFocus()
        reportPresence()
        // And once more after this turn of the run loop: becoming key is
        // said before the activation it is part of has finished.
        DispatchQueue.main.async { [weak self] in self?.reportPresence() }
    }

    /// A window the system restored comes back with itself as first
    /// responder, so the arrow keys go nowhere until something is clicked
    /// (a real window, verify-cr-03; a control room opened from the menu
    /// starts with the list). The window holding the keyboard means nobody
    /// does: the list takes it (`ControlRoomRules.listTakesKeyboard`).
    private func giveListTheKeyboardIfNobodyHasIt() {
        guard let window, let content = window.contentView else { return }
        guard ControlRoomRules.listTakesKeyboard(firstResponderIsTheWindow: window.firstResponder === window) else { return }
        // The first key view under the content is the list: it is the one
        // focusable thing while no terminal has been clicked into.
        window.recalculateKeyViewLoop()
        window.selectKeyView(following: content)
    }

    func windowDidResignKey(_ notification: Notification) {
        syncLentFocus()
        reportPresence()
    }

    /// This tab going behind another, or coming back in front. A terminal
    /// is only borrowed while the person can see it here: behind another
    /// tab it would be a placeholder in its own tab for nobody's benefit --
    /// and that other tab may be the terminal's own.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        // Every time (task 1873): whether this flips, and how often, is
        // what decides whether a terminal goes back and forth.
        let raw = window?.occlusionState.rawValue ?? 0
        Ghostty.logger.notice("control room: occlusion 0x\(String(raw, radix: 16), privacy: .public) visible=\(self.isVisible) key=\(self.window?.isKeyWindow ?? false)")
        WindowOpsTally.count(.occlusionFlips)
        // In sight: borrow. Out of sight: give back, and say why.
        syncDetail()
        reportPresence()
    }

    // MARK: Where the person is

    /// Tell the core whether this is in front and which cards are on
    /// screen in it, when that changed: the control room's notifications
    /// are not sent about a card the person can see
    /// (`ghostty_app_control_presence`, `ControlNotify.zig`). "In front" is
    /// this window having the keyboard in the active application and not
    /// being covered -- this window's, not the application's.
    private func reportPresence() {
        let active = NSApp.isActive
        let key = window?.isKeyWindow ?? false
        let inFront = ControlRoomAlert.inFront(appActive: active, windowIsKey: key, closing: closing)
        let now = ControlRoomAlert.Presence.of(inFront: inFront, cards: cardsInSight)
        guard let json = presence.report(now), let app = ghostty.app else { return }
        // Only when it changed (`PresenceReporter`). The inputs ride along:
        // the eleventh round could not tell which of them was wrong.
        Ghostty.logger.info("control room: presence \(json, privacy: .public) (active=\(active) key=\(key) visible=\(self.isVisible) cards=\(self.cardsInSight.count))")
        var refusal = [CChar](repeating: 0, count: 64)
        let taken = json.withCString { ptr in
            ghostty_app_control_presence(app, ptr, UInt(strlen(ptr)), &refusal, UInt(refusal.count))
        }
        if !taken {
            Ghostty.logger.warning("control room: presence was refused: \(String(cString: refusal), privacy: .public)")
        }
    }

    private var isVisible: Bool {
        window?.occlusionState.contains(.visible) ?? false
    }

    // MARK: The supervisor's terminal

    /// Bring the right-hand side up to date with the selection and the
    /// snapshot. Which terminal is a group's supervisor is the core's word;
    /// whether a tab still holds it is looked up, not judged.
    private func syncDetail() {
        let group = model.selection
        // A group's supervisor, or the terminal itself for a row that is
        // one terminal on its own.
        let supervisor = group.flatMap { ControlRoomFeed.shared(ghostty).latest?.terminal(shownFor: $0) }
        let present = supervisor.map { ControlRoomLender.surface(for: $0) != nil } ?? false
        // Out of sight nothing is borrowed, but what the right side says
        // is still brought up to date (`ControlRoomLending.Event.outOfSight`).
        lend(isVisible
            ? .selected(group: group, supervisor: supervisor, present: present)
            : .outOfSight(group: group, supervisor: supervisor, present: present))
    }

    /// Return on the list (task 1551): the selected group's supervisor, in
    /// its own tab, with the keyboard. Shown here, it is taken back the way
    /// the placeholder's own button takes it (`reclaimed`); already back in
    /// its tab, that tab is brought forward. No supervisor, nothing.
    private func goToSupervisor() {
        if let terminal = lending.loan?.terminal {
            lend(.reclaimed(terminal: terminal))
            return
        }
        guard let group = model.selection,
              let supervisor = ControlRoomFeed.shared(ghostty).latest?.terminal(shownFor: group),
              let view = ControlRoomLender.surface(for: supervisor) else { return }
        view.window?.makeKeyAndOrderFront(nil)
        Ghostty.moveFocus(to: view)
    }

    /// Hand `event` to the lending and do what it says, in order.
    private func lend(_ event: ControlRoomLending.Event) {
        for effect in lending.handle(event) {
            // One line a move (task 1873): a move is rare when all is well,
            // and every one takes a terminal's view between windows.
            let raw = window?.occlusionState.rawValue ?? 0
            Ghostty.logger.notice("control room: lend \(String(describing: event), privacy: .public) -> \(String(describing: effect), privacy: .public) visible=\(self.isVisible) occlusion=0x\(String(raw, radix: 16), privacy: .public)")
            switch effect {
            case let .borrow(loan):
                WindowOpsTally.count(.borrow)
                borrow(loan)
            case let .giveBack(_, toHome, focus):
                WindowOpsTally.count(.giveBack)
                giveBack(toHome: toHome, focus: focus)
            }
        }
        if model.detail != lending.detail { model.detail = lending.detail }
    }

    private func borrow(_ loan: ControlRoomLending.Loan) {
        guard let view = ControlRoomLender.surface(for: loan.terminal) else {
            // Gone between being looked up and being taken.
            _ = lending.handle(.homeGone(terminal: loan.terminal))
            return
        }
        // Its pane draws the placeholder from here on.
        lender.markLent(view)

        // Sized to the right-hand side before the terminal is in it, so the
        // first size the terminal is told is the one it will keep.
        // It draws no drag handle here, whatever `drag-handle` says (task 1566).
        let host = NSHostingView(rootView: Ghostty.SurfaceWrapper(surfaceView: view)
            .environment(\.surfaceInControlRoom, true)
            .environmentObject(ghostty))
        host.frame = detail.bounds
        detail.host(host, for: loan.group)
        detail.layoutSubtreeIfNeeded()

        ControlRoomLender.setVisible(view, isVisible)
        // The keyboard stays where it is: the person is walking the list.
        // A click in the terminal takes it.
    }

    private func giveBack(toHome: Bool, focus: Bool) {
        guard let view = lender.lent else {
            detail.giveBack()
            return
        }
        // Give up the keyboard here first, so the terminal is told it lost
        // it before it is told anything by its own window.
        if view.isFirstResponder { window?.makeFirstResponder(nil) }
        view.focusDidChange(false)

        // Before it moves: the frame at the size of the right-hand side,
        // for the sentence that says it went back to be drawn over.
        model.frozen = ControlRoomLender.terminal(of: view).flatMap { terminal in
            ControlRoomLender.freeze(view).map { (terminal: terminal, frame: $0) }
        }

        detail.giveBack()
        // Its pane draws the terminal again from here on.
        lender.markReturned()
        if model.detailHasKeyboard { model.detailHasKeyboard = false }

        guard toHome, let home = BaseTerminalController.controller(owning: view) else { return }
        // Its own window hands it the keyboard once the view is back in
        // it, which is when its pane next draws and not now: a tab behind
        // this one draws later. `settle` is asked again when the view
        // arrives and when that window becomes key.
        lender.goingHome(view, wanted: focus)
        DispatchQueue.main.async { [weak home, weak view, lender] in
            guard let home, let view, let window = home.window, !lender.isLent(view) else { return }
            ControlRoomLender.setVisible(view, window.occlusionState.contains(.visible))
            lender.settle(view)
        }
    }

    /// The lent terminal has the keyboard only while this window does and
    /// the terminal is what is focused in it.
    private func syncLentFocus() {
        guard let view = lender.lent, let window else {
            if model.detailHasKeyboard { model.detailHasKeyboard = false }
            return
        }
        let has = window.isKeyWindow && view.isFirstResponder
        view.focusDidChange(has)
        if model.detailHasKeyboard != has { model.detailHasKeyboard = has }
    }

    /// The application is quitting: put the terminal back first, so that
    /// everything that runs at quit finds it in its own tab.
    func applicationWillTerminate() {
        lend(.closing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    // MARK: Opening

    /// What the menu item, the key binding and the command palette do: go
    /// to the control room, opening it if it is closed.
    static func show(_ ghostty: Ghostty.App) {
        let parent = TerminalController.preferredParent?.window
        let takesTabs = parent.map { $0.tabbingMode != .disallowed }

        switch ControlRoomRules.trigger(isOpen: shared != nil, parentTakesTabs: takesTabs) {
        case .select:
            shared?.select()

        case .openAsFirstTab:
            guard let parent else {
                shared = ControlRoomController(ghostty)
                return
            }
            openAsFirstTab(ghostty, of: parent, inFront: true)

        case .openInOwnWindow:
            let controller = ControlRoomController(ghostty)
            shared = controller
            controller.showWindowSafely(nil)
            controller.bringOnScreen()
        }
    }

    /// Open it as the first tab of `parent`'s group. `inFront: false` puts
    /// it there behind the tab that is selected, which keeps the keyboard
    /// (task 1581, at launch); otherwise it is selected and brought forward,
    /// as the menu item does.
    private static func openAsFirstTab(_ ghostty: Ghostty.App, of parent: NSWindow, inFront: Bool) {
        let controller = ControlRoomController(ghostty)
        shared = controller
        guard let window = controller.window else { return }
        let first = parent.tabGroup?.windows.first ?? parent
        let selected = first.tabGroup?.selectedWindow ?? parent
        // Tabs join by identifier; a window whose delegate is another
        // class does not get the terminals' identifier by default.
        window.tabbingIdentifier = first.tabbingIdentifier
        let added = first.addTabbedWindowSafely(window, ordered: .below)
        if !inFront {
            if added { first.tabGroup?.selectedWindow = selected }
            relabel()
            return
        }
        if added { first.tabGroup?.selectedWindow = window }
        controller.showWindowSafely(nil)
        controller.bringOnScreen()
        relabel()
    }

    /// What the application does about the control room as it starts
    /// (`ControlRoomRules.atLaunch`, task 1581), through the same opening as
    /// the menu item. `front` is the terminal window in front: the one the
    /// launch just opened for `.ownWindow`, a restored one for
    /// `.firstTabBehind`.
    static func atLaunch(_ ghostty: Ghostty.App, _ plan: ControlRoomRules.AtLaunch, front: NSWindow?) {
        guard shared == nil else { return }
        switch plan {
        case .nothing:
            return
        case .ownWindow:
            guard let front, front.tabbingMode != .disallowed else {
                // No tabs in this style: the menu item's own answer.
                show(ghostty)
                return
            }
            openAsFirstTab(ghostty, of: front, inFront: true)
        case .firstTabBehind:
            // A window of its own would come in front of what the person
            // left there; without tabs, it waits for the menu item.
            guard let front, front.tabbingMode != .disallowed else { return }
            openAsFirstTab(ghostty, of: front, inFront: false)
        }
    }

    /// Go to the control room with `group` selected: clicking a
    /// notification it raised (task 1505). Selecting it there is the
    /// person's doing -- they clicked to go to it.
    static func show(_ ghostty: Ghostty.App, selecting group: String) {
        show(ghostty)
        shared?.model.choose(group)
    }

    /// A window opened or restored partly off its screen is brought back
    /// onto it (`ControlRoomWindowSize.fitted`). Only then: where the
    /// person drags it afterwards is theirs.
    private func bringOnScreen() {
        guard let window else { return }
        ControlRoomWindowSize.bringOnScreen(window)
    }

    /// The system is restoring this window and has not placed it yet: it
    /// is brought onto its screen when it first has the keyboard, which is
    /// after the kept frame is back.
    private var restoredAndNotYetPlaced = false

    /// Bring the control room's window forward with its tab selected.
    private func select() {
        guard let window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The shortcut hints on the tabs number them by position, and a
    /// terminal controller is what writes them.
    private static func relabel() {
        TerminalController.all.forEach { $0.relabelTabs() }
    }

    // MARK: The window

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // Two strings: the title bar names the application too, the tab
        // has room only for the name.
        let name = String(localized: "Control Room", comment: "总控台：标签页上的名字")
        window.title = String(localized: "Polter — Control Room", comment: "总控台：窗口标题栏")
        window.tab.title = name
        // A terminal window with a title-bar font configured writes the
        // window's title onto the tab as an attributed string, which the
        // tab prefers to its plain title. Keep its attributes, change its
        // words.
        if let styled = window.tab.attributedTitle {
            let attributes = styled.length > 0 ? styled.attributes(at: 0, effectiveRange: nil) : [:]
            window.tab.attributedTitle = NSAttributedString(string: name, attributes: attributes)
        }
        let content = KeyForwardingHostingView(rootView: ControlRoomView(model: model, detail: detail))
        content.onKeyEquivalent = { [weak self] in self?.goToTab(for: $0) ?? false }
        watchingResponder = window.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncLentFocus() }
        }
        ControlRoomWindowSize.install(content, in: window)

        // All three are needed for the system to bring it back.
        window.isRestorable = true
        window.restorationClass = ControlRoomRestoration.self
        window.identifier = ControlRoomRestoration.identifier
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let group = window.tabGroup
        let tabbed = (group?.windows.count ?? 1) > 1
        ControlRoomRestoration.encode(ControlRoomRules.Restorable(
            selection: model.selection,
            tabbed: tabbed,
            inFront: !tabbed || group?.selectedWindow === window), into: state)
    }

    /// "Close All Windows": this one with them.
    static func closeWithAllWindows() {
        shared?.window?.close()
    }

    // MARK: Coming back after a restart

    private var rejoining: NSObjectProtocol?

    /// Go back into the group of terminal tabs it was a tab of, once the
    /// terminal windows have been restored (`ControlRoomRules.groupToRejoin`).
    /// Windows are restored before the application has finished launching,
    /// in no order this can rely on, so this waits for that moment and does
    /// not try while they are still arriving.
    fileprivate func rejoinAfterRestore(_ kept: ControlRoomRules.Restorable?) {
        guard kept?.tabbed == true else { return }
        // Restored into an application that is already up (it does not
        // happen today): there is no moment to wait for.
        if NSRunningApplication.current.isFinishedLaunching {
            DispatchQueue.main.async { [weak self] in self?.rejoin(kept) }
            return
        }
        rejoining = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let rejoining = self.rejoining { NotificationCenter.default.removeObserver(rejoining) }
            self.rejoining = nil
            // After the launch has settled what the restored windows are.
            DispatchQueue.main.async { self.rejoin(kept) }
        }
    }

    private func rejoin(_ kept: ControlRoomRules.Restorable?) {
        guard let window else { return }
        // One window per group of terminal tabs: its first tab.
        var firsts: [NSWindow] = []
        for controller in TerminalController.all {
            guard let terminal = controller.window else { continue }
            let first = terminal.tabGroup?.windows.first ?? terminal
            if first !== window, !firsts.contains(where: { $0 === first }) { firsts.append(first) }
        }
        let alone = (window.tabGroup?.windows.count ?? 1) <= 1
        guard let at = ControlRoomRules.groupToRejoin(
            wasTabbed: kept?.tabbed, alone: alone, frame: window.frame, groups: firsts.map(\.frame))
        else { return }
        let first = firsts[at]
        guard first.tabbingMode != .disallowed else { return }
        let selected = first.tabGroup?.selectedWindow ?? first
        window.tabbingIdentifier = first.tabbingIdentifier
        guard first.addTabbedWindowSafely(window, ordered: .below) else { return }
        // In front if it was; otherwise the tab the system restored in
        // front stays there.
        first.tabGroup?.selectedWindow = kept?.inFront == true ? window : selected
        Self.relabel()
    }

    func windowWillClose(_ notification: Notification) {
        // Closed is not in front: nothing on it is in sight any more.
        closing = true
        reportPresence()
        appActivity.forEach(NotificationCenter.default.removeObserver)
        appActivity = []
        lend(.closing)
        detail.giveBack()
        lender.onReclaim = nil
        lender.onHomeGone = nil
        if Self.shared === self { Self.shared = nil }
        // The tabs that remain move up one.
        DispatchQueue.main.async { Self.relabel() }
    }

    // MARK: Going to a tab by number

    /// "Go to tab N", pressed while this tab is selected. See
    /// `ControlRoomRules.tabIndex`.
    private func goToTab(for event: NSEvent) -> Bool {
        guard let window, let windows = window.tabGroup?.windows else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let pressed = ControlRoomRules.Chord(
            key: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags.intersection(relevant).rawValue)
        let shortcuts: [ControlRoomRules.Chord?] = (1...9).map { n in
            ghostty.config.keyboardShortcut(for: "goto_tab:\(n)").map {
                .init(key: String($0.key.character),
                      modifiers: NSEvent.ModifierFlags(swiftUIFlags: $0.modifiers).intersection(relevant).rawValue)
            }
        }
        guard let index = ControlRoomRules.tabIndex(for: pressed, shortcuts: shortcuts, tabCount: windows.count)
        else { return false }
        if windows[index] !== window {
            window.tabGroup?.selectedWindow = windows[index]
            windows[index].makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: Closing

    /// The system asking this tab's window to close. Never closes here: the
    /// answer comes back through the coordinator once it is known whether
    /// one tab or the whole window is going.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabGroupCloseCoordinator.windowShouldClose(sender) { [weak self] scope in
            guard let self, let window = self.window else { return }
            let terminals = (window.tabGroup?.windows ?? [])
                .compactMap { $0.windowController as? TerminalController }
            switch ControlRoomRules.closeRequest(
                wholeWindow: scope == .window,
                isFirstTab: window.isFirstWindowInTabGroup,
                terminalTabsBeside: terminals.count
            ) {
            case .closeSelf: window.close()
            case .askATerminalTab: terminals.first?.closeWindow(nil)
            case .leaveItToTheFirstTab: break
            }
        }
        return false
    }

    /// "Close" (the key that closes a split or, with one split, its tab)
    /// while this tab is selected: there are no splits here, so the tab.
    @IBAction func close(_ sender: Any?) {
        closeTab(sender)
    }

    /// "Close Tab" (and the key bound to it) while this tab is selected.
    @IBAction func closeTab(_ sender: Any?) {
        switch ControlRoomRules.closeTab() {
        case .close: window?.close()
        }
    }

    /// "Close Window" while this tab is selected.
    @IBAction func closeWindow(_ sender: Any?) {
        guard let window else { return }
        let terminals = (window.tabGroup?.windows ?? [])
            .compactMap { $0.windowController as? TerminalController }

        switch ControlRoomRules.closeWindow(terminalTabsBeside: terminals.count) {
        case .askATerminalTab:
            // It asks about every terminal in the group and then closes
            // every window in it, this one included.
            terminals.first?.closeWindow(sender)
        case .close:
            window.close()
        }
    }

    /// The tab bar's "+" while this tab is selected (task 1641): what "New
    /// Tab" does here. AppKit sends the button's click to the selected
    /// window's controller, and only `TerminalController` answered it, so
    /// with the control room in front the "+" was drawn and did nothing.
    override func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    /// "New Tab" while this tab is selected: a terminal tab, in this
    /// window and in front (`ControlRoomRules.newTab`, asked by the
    /// person). It used to go to the terminal window used last, and with
    /// none to a window of its own.
    @IBAction func newTab(_ sender: Any?) {
        let beside = terminalTabBeside
        let plan = ControlRoomRules.newTab(
            asker: nil,
            byPerson: true,
            controlRoomInFront: true,
            tabsBesideControlRoom: beside != nil,
            anyTerminalWindow: TerminalController.preferredParent != nil)
        switch plan {
        case .inFront(of: .controlRooms):
            if let beside {
                _ = TerminalController.newTab(ghostty, from: beside)
            } else {
                newFirstTerminalTab(withBaseConfig: nil, inFront: true)
            }
        case .inFront, .behind, .ownWindow, .refused:
            // The terminal window used last, as the menu item does anywhere.
            (NSApp.delegate as? AppDelegate)?.newTab(sender)
        }
    }

    // MARK: The Project menu

    /// The tab the terminal on the right-hand side belongs to; nil with
    /// none borrowed, or when no tab holds it any more.
    private var lentTerminalsTab: TerminalController? {
        lender.lent.flatMap { BaseTerminalController.controller(owning: $0) as? TerminalController }
    }

    /// "Save as Project" while this tab is selected: the control room is
    /// not a tab that can be saved, so what is saved is the tab of the
    /// terminal it is showing. Its panes are still in that tab's tree
    /// while one of them is drawn here.
    @IBAction func saveAsProject(_ sender: Any?) {
        lentTerminalsTab?.saveAsProject(sender)
    }

    /// "Load Project" while this tab is selected.
    @IBAction func loadProject(_ sender: Any?) {
        projectPicker.present(
            mode: .load,
            onLoad: { [weak self] entry in
                self?.openProject(entry)
            })
    }

    /// "Manage Projects" while this tab is selected: on the project of the
    /// terminal shown, when that tab is bound to one.
    @IBAction func manageProjects(_ sender: Any?) {
        openSettings(.projects(lentTerminalsTab?.boundProject))
    }

    /// Open `entry` as a tab. Where it goes, and that it comes in front,
    /// is `ControlRoomRules.loadedProjectTab`: the place every tab opened
    /// from the control room goes to, and in front because the person
    /// asked for it.
    private func openProject(_ entry: ProjectStore.Entry) {
        do {
            try loadProjectWhereTabsGo(entry)
        } catch {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Project Error", comment: "项目功能出错提醒标题")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK", comment: "项目功能出错提醒：确定按钮"))
            alert.beginSheetModal(for: window)
        }
    }

    /// Open `entry` where `ControlRoomRules.loadedProjectTab` says a
    /// project opened from the control room goes -- or, `orderedByCore`,
    /// where `ControlRoomRules.orderedProjectTab` says one the core ordered
    /// goes. Throws instead of reporting: a project the core asked for
    /// (`ProjectLinker`) has its failure told to the core, not put on a
    /// sheet.
    func loadProjectWhereTabsGo(_ entry: ProjectStore.Entry, orderedByCore: Bool = false) throws {
        let beside = terminalTabBeside
        let frontmost = TerminalController.preferredParent?.window
        let plan = orderedByCore
            ? ControlRoomRules.orderedProjectTab(
                controlRoomInFront: window?.isKeyWindow ?? false,
                tabsBesideControlRoom: beside != nil,
                anyTerminalWindow: frontmost != nil)
            : ControlRoomRules.loadedProjectTab(
                tabsBesideControlRoom: beside != nil,
                anyTerminalWindow: frontmost != nil)

        func home(_ which: ControlRoomRules.NewTab.Home) -> NSWindow? {
            switch which {
            case .askers: return nil
            // With no terminal tab beside it yet, this window itself: the
            // project's first tab becomes the first one beside it.
            case .controlRooms: return beside ?? window
            case .frontmost: return frontmost
            }
        }

        let parent: NSWindow?
        let inFront: Bool
        switch plan {
        case .refused:
            return
        case .ownWindow:
            parent = nil
            inFront = true
        case let .inFront(of: which):
            parent = home(which)
            inFront = true
        case let .behind(which):
            parent = home(which)
            inFront = false
        }

        try TerminalController.load(entry, ghostty: ghostty, into: parent, beside: frontmost, inFront: inFront)
    }
}

// MARK: NSMenuItemValidation

extension ControlRoomController: NSMenuItemValidation {
    /// Which of the Project menu's items can be chosen here is
    /// `ControlRoomRules.projectItemOffered`, and nothing else is decided:
    /// every other item this window answers to stays as it was.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let which: ControlRoomRules.ProjectItem
        switch item.action {
        case #selector(saveAsProject(_:)): which = .saveAs
        case #selector(loadProject(_:)): which = .load
        case #selector(manageProjects(_:)): which = .manage
        default: return true
        }
        return ControlRoomRules.projectItemOffered(which, lentTerminalHasTab: lentTerminalsTab != nil)
    }
}

/// The control room's content view. It sees key equivalents before the
/// menu does and offers them to the controller, which takes the ones that
/// only a terminal would otherwise have understood.
private final class KeyForwardingHostingView<Content: View>: NSHostingView<Content> {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Brings the control room back after a restart.
///
/// It keeps only that it was open and which group was selected
/// (`ControlRoomRules.Restorable`). Which tab group it was in is the
/// system's to restore, as it is for the terminal tabs: nothing here joins
/// it to anything.
final class ControlRoomRestoration: NSObject, NSWindowRestoration {
    static let identifier = NSUserInterfaceItemIdentifier(String(describing: ControlRoomRestoration.self))
    private static let key = "controlRoom"

    static func encode(_ state: ControlRoomRules.Restorable, into coder: NSCoder) {
        guard let data = state.encoded() else { return }
        coder.encode(data as NSData, forKey: key)
    }

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        guard identifier == Self.identifier,
              let appDelegate = NSApp.delegate as? AppDelegate,
              // The same switch the terminal windows obey.
              appDelegate.ghostty.config.windowSaveState != "never",
              // One in the application, restored or not.
              ControlRoomController.shared == nil
        else {
            completionHandler(nil, nil)
            return
        }

        let data = state.decodeObject(of: NSData.self, forKey: key) as Data?
        let kept = ControlRoomRules.Restorable.decode(data)
        // The kept selection is checked against the list when the first
        // snapshot arrives (`ControlRoomModel`): at this point in a launch
        // the core may not have one.
        let controller = ControlRoomController.restored(appDelegate.ghostty, selection: kept?.selection)
        controller.rejoinAfterRestore(kept)
        completionHandler(controller.window, nil)
    }
}

extension ControlRoomController {
    /// The control room the system is restoring; it becomes the one.
    fileprivate static func restored(_ ghostty: Ghostty.App, selection: String?) -> ControlRoomController {
        let controller = ControlRoomController(ghostty, selection: selection)
        controller.restoredAndNotYetPlaced = true
        shared = controller
        return controller
    }
}

// MARK: - The core, for everything above

extension ControlRoomFeed {
    private static var forApp: ControlRoomFeed?

    /// The one feed in the application: the control room's list and every
    /// terminal window's tab glyph listen to this, so the core is asked
    /// once per change however many windows are open.
    static func shared(_ ghostty: Ghostty.App) -> ControlRoomFeed {
        if let forApp { return forApp }
        let feed = ControlRoomFeed { [weak ghostty] buffer, capacity in
            guard let app = ghostty?.app else { return 0 }
            return Int(ghostty_app_control_snapshot(app, buffer, UInt(capacity)))
        }
        forApp = feed
        return feed
    }
}

extension ControlRoomActions {
    /// Actions carried out by the core. Calling this is being the person:
    /// the core has no field for who is asking.
    static func core(_ ghostty: Ghostty.App) -> ControlRoomActions {
        ControlRoomActions { [weak ghostty] json in
            guard let app = ghostty?.app else { return "NoCore" }
            var refusal = [CChar](repeating: 0, count: 64)
            let done = json.withUnsafeBytes { bytes in
                ghostty_app_control_act(
                    app, bytes.bindMemory(to: CChar.self).baseAddress, UInt(bytes.count),
                    &refusal, UInt(refusal.count))
            }
            return done ? nil : String(cString: refusal)
        }
    }
}
