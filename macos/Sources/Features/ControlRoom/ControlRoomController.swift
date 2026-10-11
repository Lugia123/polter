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
    private var watchingSelection: AnyCancellable?

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
            markSeen: { group in
                do {
                    try actions.perform(.seen(group: group))
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
    }

    /// Whether the person can be looking at the list: this tab is the one
    /// in front in the window that has the keyboard, in the application
    /// that is active.
    private var isInFront: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow
    }

    private func noteSelection() {
        let row = model.list?.rows.first { $0.id == model.selection }
        seen?.selectionChanged(to: row)
    }

    /// Coming to the front with a row already selected is a chance to look
    /// at it that selecting it earlier, behind something else, was not.
    func windowDidBecomeKey(_ notification: Notification) {
        noteSelection()
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
            let controller = ControlRoomController(ghostty)
            shared = controller
            guard let window = controller.window, let parent else { return }
            let first = parent.tabGroup?.windows.first ?? parent
            // Tabs join by identifier; a window whose delegate is another
            // class does not get the terminals' identifier by default.
            window.tabbingIdentifier = first.tabbingIdentifier
            if first.addTabbedWindowSafely(window, ordered: .below) {
                first.tabGroup?.selectedWindow = window
            }
            controller.showWindowSafely(nil)
            relabel()

        case .openInOwnWindow:
            let controller = ControlRoomController(ghostty)
            shared = controller
            controller.showWindowSafely(nil)
        }
    }

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
        window.contentView = content

        // All three are needed for the system to bring it back.
        window.isRestorable = true
        window.restorationClass = ControlRoomRestoration.self
        window.identifier = ControlRoomRestoration.identifier
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        ControlRoomRestoration.encode(ControlRoomRules.Restorable(selection: model.selection), into: state)
    }

    func windowWillClose(_ notification: Notification) {
        detail.giveBack()
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

    /// "New Tab" while this tab is selected: a terminal tab, as anywhere.
    @IBAction func newTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newTab(sender)
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
        completionHandler(controller.window, nil)
    }
}

extension ControlRoomController {
    /// The control room the system is restoring; it becomes the one.
    fileprivate static func restored(_ ghostty: Ghostty.App, selection: String?) -> ControlRoomController {
        let controller = ControlRoomController(ghostty, selection: selection)
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
