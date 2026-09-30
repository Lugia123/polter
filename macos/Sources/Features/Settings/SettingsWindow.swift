import AppKit
import OSLog
import SwiftUI

/// What every section with unsaved state answers, so that switching
/// section, switching item, routing in from elsewhere and closing the window
/// all ask the same question the same way (settings.md §2.4).
@MainActor
protocol SettingsPane: AnyObject {
    var isDirty: Bool { get }
    /// Save. On failure the section shows why and returns false; the caller
    /// then stays where it is.
    func save() -> Bool
    func revert()
}

@MainActor
enum SettingsUnsaved {
    /// True when it is fine to leave `pane`: nothing unsaved, saved, or
    /// thrown away on request. False on Cancel or a failed save.
    static func confirmLeaving(
        _ pane: SettingsPane?,
        message: String = String(localized: "Save your changes?", comment: "设置窗口：离开前有未保存修改")
    ) -> Bool {
        guard let pane else { return true }
        return SettingsRules.mayLeave(
            dirty: pane.isDirty,
            ask: { ask(message) },
            save: pane.save,
            revert: pane.revert)
    }

    private static func ask(_ message: String) -> SettingsRules.UnsavedAnswer {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.", comment: "角色库：未保存修改的后果")
        alert.addButton(withTitle: String(localized: "Save", comment: "角色库：保存按钮"))
        alert.addButton(withTitle: String(localized: "Don't Save", comment: "角色库：丢弃修改"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "角色库：取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }
}

/// Open the settings window, or bring it forward and go to `route`.
/// `nil` means wherever it was last left.
@MainActor
func openSettings(_ route: SettingsRoute? = nil) {
    SettingsWindowController.shared.open(route)
}

/// What the settings window shows. Owned by the window controller and
/// dropped with the window, so a closed window holds no draft.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var section: SettingsSection
    @Published var search = "" {
        didSet {
            // A search stays in the section it is in while that has a match,
            // and otherwise goes to the first that has one (settings.md
            // §2.3).
            let next = SettingsRules.sectionForSearch(search, current: section) { [unowned self] in
                self.searchMatches(in: $0)
            }
            if let next, next != section { go(next) }
        }
    }

    let library: RoleLibrary
    let roles: RoleLibraryEditor
    let plugins: PluginsPane
    let projects: ProjectsModel
    let general = GeneralModel()

    init(section: SettingsSection, library: RoleLibrary, projects: ProjectsModel? = nil) {
        self.section = section
        self.library = library
        self.roles = RoleLibraryEditor(library: library)
        self.plugins = PluginsPane()
        plugins.reload()
        self.projects = projects ?? ProjectsModel()
        self.projects.reload()
    }

    /// The section whose unsaved state has to be settled before leaving it.
    var currentPane: SettingsPane? {
        switch section {
        case .roles: roles
        case .plugins: plugins
        case .projects, .general: nil
        }
    }

    /// Whether the search leaves anything in `section`'s list.
    private func searchMatches(in section: SettingsSection) -> Bool {
        switch section {
        case .roles:
            !RoleLibraryView.listing(library: library, editor: roles, query: search).visible.isEmpty
        case .plugins:
            !plugins.listing(query: search).visible.isEmpty
        case .projects:
            !projects.listing(query: search).visible.isEmpty
        case .general:
            false
        }
    }

    /// Show one plugin: go to the Plugins section, then to it, each asking
    /// about unsaved changes on the way out (settings.md §2.4).
    func goPlugin(_ key: String) {
        guard go(.plugins) else { return }
        plugins.select(key)
    }

    /// Switch section, asking first when the one being left has unsaved
    /// changes. False when the person cancelled.
    @discardableResult
    func go(_ next: SettingsSection) -> Bool {
        guard next != section else { return true }
        guard SettingsUnsaved.confirmLeaving(currentPane) else { return false }
        section = next
        UserDefaults.standard.set(next.rawValue, forKey: SettingsWindowController.lastSectionKey)
        return true
    }
}

/// The one settings window of the app (settings.md §2.1). It belongs to no
/// terminal window, so closing one of those leaves it alone.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "settings")

    static let autosaveName = "PolterSettings"
    static let lastSectionKey = "PolterSettingsLastSection"
    static let lastRoleKey = "PolterSettingsLastRole"

    private static let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]

    private var model: SettingsModel?

    init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(_ route: SettingsRoute?) {
        let library = RoleLibrary.shared
        library.reload()

        if let window, let model {
            Self.logger.info("settings: route \(String(describing: route), privacy: .public) to open window \(window.windowNumber) model=\(ObjectIdentifier(model).debugDescription, privacy: .public)")
            if window.isMiniaturized { window.deminiaturize(nil) }
            if let route { apply(route, to: model, fresh: false) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let last = UserDefaults.standard.string(forKey: Self.lastSectionKey)
            .flatMap(SettingsSection.init(rawValue:)) ?? .roles
        let model = SettingsModel(section: route?.section ?? last, library: library)
        self.model = model
        apply(route ?? SettingsRoute(section: last), to: model, fresh: true)

        // The minimum goes through SwiftUI. Set on the window directly it
        // lasted until the first layout, after which the hosting view put the
        // window's minimum back to its root view's (0x0 content, a 0x32
        // frame), whatever `sizingOptions` said. So the root view carries it,
        // converted from the frame size §2.2 gives, and `.minSize` lets the
        // hosting controller pass it on. The frame size stays ours: no
        // `.preferredContentSize`.
        let minContent = NSWindow.contentRect(
            forFrameRect: CGRect(origin: .zero, size: SettingsRules.minimumSize),
            styleMask: Self.style).size
        let host = NSHostingController(rootView: SettingsRootView(
            model: model, library: library, editor: model.roles, plugins: model.plugins,
            projects: model.projects, minimumContent: minContent))
        host.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: host)
        window.title = String(localized: "Polter Settings", comment: "设置窗口：窗口标题")
        window.styleMask = Self.style
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The green button zooms rather than going full screen. A zoomed
        // frame is an ordinary frame: autosaved as it is and reopened as it
        // was, so "it was maximised when closed" cannot come back as a flag
        // with a normal-sized window under it (#896 D1 on Windows).
        window.collectionBehavior.insert(.fullScreenNone)
        window.delegate = self
        place(window)
        window.setFrameAutosaveName(Self.autosaveName)
        self.window = window
        // Through the controller, not only the window: NSWindowController
        // keeps a `contentViewController` of its own and puts it into any
        // window it is given. Left over from the last window, it put that
        // window's view -- its model, its role draft -- into this one, and
        // routes then changed a model nobody was looking at.
        contentViewController = host
        Self.logger.info("settings: opened window \(window.windowNumber) route=\(String(describing: route), privacy: .public) model=\(ObjectIdentifier(model).debugDescription, privacy: .public)")

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The saved frame if there is one and its title bar is still on a
    /// screen; otherwise the first-open size, capped at 90% of the screen,
    /// centred.
    private func place(_ window: NSWindow) {
        let titleBar = window.frame.height - window.contentLayoutRect.height
        if window.setFrameUsingName(Self.autosaveName),
           SettingsRules.isReachable(window.frame, titleBar: titleBar, screens: NSScreen.screens.map(\.visibleFrame)) {
            return
        }
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            window.setContentSize(SettingsRules.firstSize)
            window.center()
            return
        }
        window.setFrame(SettingsRules.firstFrame(in: area), display: false)
    }

    private func apply(_ route: SettingsRoute, to model: SettingsModel, fresh: Bool) {
        guard model.go(route.section) else { return }
        switch route.section {
        case .roles:
            let choice = SettingsRules.roleToSelect(
                item: route.item,
                fresh: fresh,
                last: UserDefaults.standard.string(forKey: Self.lastRoleKey),
                roles: model.library.catalog.roles.map(\.key))
            if case .select(let key) = choice { model.roles.select(key) }
        case .plugins:
            model.plugins.reload()
            model.plugins.select(SettingsRules.pluginToSelect(
                item: route.item,
                current: model.plugins.selection,
                fresh: fresh,
                keys: model.plugins.plugins.map(\.key)))
        case .projects:
            // A route that names nothing leaves an open window where it is.
            if fresh || route.item != nil { model.projects.route(to: route.item) } else { model.projects.reload() }
        case .general:
            model.general.route(to: route.item, fresh: fresh)
        }
    }

    var isOpen: Bool { window != nil }

    /// Where the window is, for a test: its section, and the General
    /// group when that is the section. Nil when it is closed.
    var shown: (section: SettingsSection, group: GeneralGroup?)? {
        guard let model else { return nil }
        return (model.section, model.section == .general ? model.general.group : nil)
    }

    /// Go to a General group as a click would, for a test.
    func selectGeneralGroup(_ group: GeneralGroup) {
        model?.general.select(group)
    }

    /// The configuration was reloaded: what the General section shows is
    /// read again where it is (Advanced's error list follows the app's
    /// config by itself).
    func configChanged() {
        model?.general.reloadForm()
    }

    /// Asked before the app quits: the settings window's unsaved changes
    /// are asked about like any other leaving (settings.md §2.4, #896 D3).
    /// True when quitting may go on.
    func mayQuit() -> Bool {
        guard window != nil else { return true }
        return SettingsUnsaved.confirmLeaving(model?.currentPane)
    }

    // MARK: NSWindowDelegate

    /// The minimum again, for a live resize: the window's own `minSize` is
    /// the hosting view's to keep, and this does not depend on it.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        SettingsRules.clamped(frameSize)
    }

    /// Plugins change behind the window's back -- an agent configures one,
    /// its copy fails, a directory is dropped in -- so what the Plugins
    /// section shows is read again whenever the window comes forward. A
    /// draft being edited is kept.
    func windowDidBecomeKey(_ notification: Notification) {
        model?.plugins.reload()
        // The config file may have been edited by hand (§7.3).
        model?.general.reloadForm()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        SettingsUnsaved.confirmLeaving(model?.currentPane)
    }

    func windowWillClose(_ notification: Notification) {
        Self.logger.info("settings: window \((notification.object as? NSWindow)?.windowNumber ?? -1) closing")
        if let key = model?.roles.selection {
            UserDefaults.standard.set(key, forKey: Self.lastRoleKey)
        }
        model = nil
        contentViewController = nil
        window = nil
    }

    // MARK: First responder

    /// ⌘W and File ▸ Close Window. Esc deliberately does not close the
    /// window: long text and input methods use it (settings.md §2.3).
    @IBAction func close(_ sender: Any?) {
        window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }
}
