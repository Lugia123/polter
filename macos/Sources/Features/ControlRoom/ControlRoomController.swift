import AppKit
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

    init(_ ghostty: Ghostty.App, source: ControlRoomSnapshotSource, selection: String? = nil) {
        self.ghostty = ghostty
        self.model = ControlRoomModel(source: source, selection: selection)
        super.init(window: nil)
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
            let controller = ControlRoomController(ghostty, source: coreSource(ghostty))
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
            let controller = ControlRoomController(ghostty, source: coreSource(ghostty))
            shared = controller
            controller.showWindowSafely(nil)
        }
    }

    /// The core's snapshot, fetched when the core says it changed.
    fileprivate static func coreSource(_ ghostty: Ghostty.App) -> ControlRoomSnapshotSource {
        ControlRoomCoreSource { [weak ghostty] buffer, capacity in
            guard let app = ghostty?.app else { return 0 }
            return Int(ghostty_app_control_snapshot(app, buffer, UInt(capacity)))
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

        window.title = String(localized: "Control Room", comment: "总控台：窗口与标签页的标题")
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
        let controller = ControlRoomController.restored(
            appDelegate.ghostty,
            source: ControlRoomController.coreSource(appDelegate.ghostty),
            selection: kept?.selection)
        completionHandler(controller.window, nil)
    }
}

extension ControlRoomController {
    /// The control room the system is restoring; it becomes the one.
    fileprivate static func restored(
        _ ghostty: Ghostty.App, source: ControlRoomSnapshotSource, selection: String?
    ) -> ControlRoomController {
        let controller = ControlRoomController(ghostty, source: source, selection: selection)
        shared = controller
        return controller
    }
}
