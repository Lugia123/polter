import AppKit
import Combine
import SwiftUI
import GhosttyKit

/// The base class for all standalone, "normal" terminal windows. This sets the basic
/// style and configuration of the window based on the app configuration.
class TerminalWindow: NSWindow {
    /// Posted when a terminal window awakes from nib.
    static let terminalDidAwake = Notification.Name("TerminalWindowDidAwake")

    /// Posted when a terminal window will close
    static let terminalWillCloseNotification = Notification.Name("TerminalWindowWillClose")

    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    /// Reset split zoom button in titlebar
    private let resetZoomAccessory = NSTitlebarAccessoryViewController()

    /// Update notification UI in titlebar
    private let updateAccessory = NSTitlebarAccessoryViewController()

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()

    /// Sets up our tab context menu
    private var tabMenuObserver: NSObjectProtocol?

    /// Handles inline tab title editing for this host window.
    private(set) lazy var tabTitleEditor = TabTitleEditor(
        hostWindow: self,
        delegate: self
    )

    /// Whether this window supports the update accessory. If this is false, then views within this
    /// window should determine how to show update notifications.
    var supportsUpdateAccessory: Bool {
        // Native window supports it.
        true
    }

    /// Glass effect view for liquid glass background when transparency is enabled
    private var glassEffectView: NSView?

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
    }

    /// The dots of this tab's panes that have a colour, led by the
    /// supervisor's flag (task 1699). Set by the controller from its
    /// surfaces; the old one colour per tab is gone, not carried over
    /// (the user's ruling of 2026-10-18).
    var paneDots: TabDots.Drawn = TabDots.of([]) {
        didSet {
            guard paneDots != oldValue else { return }
            refreshTabAccessory()
        }
    }

    // MARK: NSWindow Overrides

    override var toolbar: NSToolbar? {
        didSet {
            DispatchQueue.main.async {
                // When we have a toolbar, our SwiftUI view needs to know for layout
                self.viewModel.hasToolbar = self.toolbar != nil
            }
        }
    }

    override func awakeFromNib() {
        // Notify that this terminal window has loaded
        NotificationCenter.default.post(name: Self.terminalDidAwake, object: self)

        // This is fragile, but there doesn't seem to be an official API for customizing
        // native tab bar menus.
        tabMenuObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(rawValue: "NSMenuWillOpenNotification"),
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self, let menu = n.object as? NSMenu else { return }
            self.configureTabContextMenuIfNeeded(menu)
        }

        // This is required so that window restoration properly creates our tabs
        // again. I'm not sure why this is required. If you don't do this, then
        // tabs restore as separate windows.
        tabbingMode = .preferred
        DispatchQueue.main.async {
            self.tabbingMode = .automatic
        }

        // All new windows are based on the app config at the time of creation.
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let config = appDelegate.ghostty.config

        // Setup our initial config
        derivedConfig = .init(config)

        // If there is a hardcoded title in the configuration, we set that
        // immediately. Future `set_title` apprt actions will override this
        // if necessary but this ensures our window loads with the proper
        // title immediately rather than on another event loop tick (see #5934)
        if let title = derivedConfig.title {
            self.title = title
        }

        // If window decorations are disabled, remove our title
        if !config.windowDecorations { styleMask.remove(.titled) }

        // NOTE: setInitialWindowPosition is NOT called here because subclass
        // awakeFromNib may add decorations (e.g. toolbar for tabs style) that
        // change the frame. It is called from TerminalController.windowDidLoad
        // after the window is fully set up.

        // If our traffic buttons should be hidden, then hide them
        if config.macosWindowButtons == .hidden {
            hideWindowButtons()
        }

        // Create our reset zoom titlebar accessory. We have to have a title
        // to do this or AppKit triggers an assertion.
        if styleMask.contains(.titled) {
            resetZoomAccessory.layoutAttribute = .right
            resetZoomAccessory.view = NSHostingView(rootView: ResetZoomAccessoryView(
                viewModel: viewModel,
                action: { [weak self] in
                    guard let self else { return }
                    self.terminalController?.splitZoom(self)
                }))
            addTitlebarAccessoryViewController(resetZoomAccessory)
            resetZoomAccessory.view.translatesAutoresizingMaskIntoConstraints = false

            // Create update notification accessory
            if supportsUpdateAccessory {
                updateAccessory.layoutAttribute = .right
                updateAccessory.view = NonDraggableHostingView(rootView: UpdateAccessoryView(
                    viewModel: viewModel,
                    model: appDelegate.updateViewModel
                ))
                addTitlebarAccessoryViewController(updateAccessory)
                updateAccessory.view.translatesAutoresizingMaskIntoConstraints = false
            }
        }

        // Setup the accessory view for tabs that shows our keyboard shortcuts,
        // zoomed state, etc. Note I tried to use SwiftUI here but ran into issues
        // where buttons were not clickable on macOS 15.
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        stackView.spacing = 4
        stackView.alignment = .centerY
        for item in TabAccessory.Item.allCases {
            stackView.addArrangedSubview(tabAccessoryView(for: item))
        }

        // The only assignment of this slot. Whatever else wants to be beside
        // the title is a `TabAccessory.Item` in this stack, not a second
        // writer (#67).
        tab.accessoryView = stackView
        refreshTabAccessory()

        // The tab's status glyph. One snapshot serves every window: this
        // listens to it and never asks the core for one of its own.
        tabStatusListening = ControlRoomFeed.shared(appDelegate.ghostty).listen { [weak self] _ in
            self?.refreshTabStatus()
        }

        // Get our saved level
        level = UserDefaults.ghostty.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    /// The alpha this window had when it was held invisible, while its tab
    /// is being dragged onto a pane (`TabIntoPane`); nil when it is not held.
    private var alphaBeforeTabDrop: CGFloat?

    /// Whether this window is held invisible because its tab is being
    /// dragged onto a pane. **AppKit sets the alpha back to 1 when it tears
    /// the tab off** (measured), which would show the torn-off window for
    /// a moment before it is taken apart; while held, that is ignored.
    var heldForTabDrop: Bool {
        get { alphaBeforeTabDrop != nil }
        set {
            guard newValue != heldForTabDrop else { return }
            if newValue {
                alphaBeforeTabDrop = super.alphaValue
                super.alphaValue = 0
            } else {
                let alpha = alphaBeforeTabDrop ?? 1
                alphaBeforeTabDrop = nil
                super.alphaValue = alpha
            }
        }
    }

    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set {
            if alphaBeforeTabDrop != nil {
                alphaBeforeTabDrop = newValue
            } else {
                super.alphaValue = newValue
            }
        }
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func sendEvent(_ event: NSEvent) {
        if tabTitleEditor.handleMouseDown(event) {
            return
        }

        if tabTitleEditor.handleRightMouseDown(event) {
            return
        }

        super.sendEvent(event)
    }

    override func close() {
        tabTitleEditor.finishEditing(commit: true)
        NotificationCenter.default.post(name: Self.terminalWillCloseNotification, object: self)
        super.close()
    }

    override func becomeKey() {
        super.becomeKey()
        resetZoomTabButton.contentTintColor = .controlAccentColor
    }

    override func resignKey() {
        super.resignKey()
        resetZoomTabButton.contentTintColor = .secondaryLabelColor
        tabTitleEditor.finishEditing(commit: true)
    }

    override func becomeMain() {
        super.becomeMain()

        // Its possible we miss the accessory titlebar call so we check again
        // whenever the window becomes main. Both of these are idempotent.
        if tabBarView != nil {
            tabBarDidAppear()
        } else {
            tabBarDidDisappear()
        }
        viewModel.isMainWindow = true

        // This tab is now the one in front, which can move the breathing
        // glyph to another tab of the group.
        (tabGroup?.windows ?? [self]).forEach { ($0 as? TerminalWindow)?.refreshTabStatus() }

        // And the selected tab's glass slides here from the tab that was.
        WindowTabChipSlide.selected(self)
    }

    override func resignMain() {
        super.resignMain()
        viewModel.isMainWindow = false
    }

    @discardableResult
    func beginInlineTabTitleEdit(for targetWindow: NSWindow) -> Bool {
        tabTitleEditor.beginEditing(for: targetWindow)
    }

    @objc private func renameTabFromContextMenu(_ sender: NSMenuItem) {
        let targetWindow = sender.representedObject as? NSWindow ?? self
        if beginInlineTabTitleEdit(for: targetWindow) {
            return
        }

        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.promptTabTitle()
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        // It takes an event loop cycle to merge all the windows so we set a
        // short timer to relabel the tabs (issue #1902)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalController?.relabelTabs()
        }
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // Tab bar is attached as a titlebar accessory view controller (layout bottom). We
        // can detect when it is shown or hidden by overriding add/remove and searching for
        // it. This has been verified to work on macOS 12 to 26
        if isTabBar(childViewController) {
            childViewController.identifier = Self.tabBarIdentifier
            tabBarDidAppear()
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        if let childViewController = titlebarAccessoryViewControllers[safe: index], isTabBar(childViewController) {
            tabBarDidDisappear()
        }

        super.removeTitlebarAccessoryViewController(at: index)
    }

    // MARK: Tab Bar

    /// This identifier is attached to the tab bar view controller when we detect it being
    /// added.
    static let tabBarIdentifier: NSUserInterfaceItemIdentifier = .init("_ghosttyTabBar")

    func isTabBar(_ childViewController: NSTitlebarAccessoryViewController) -> Bool {
        if childViewController.identifier == nil {
            // The good case
            if childViewController.view.contains(className: "NSTabBar") {
                return true
            }

            // When a new window is attached to an existing tab group, AppKit adds
            // an empty NSView as an accessory view and adds the tab bar later. If
            // we're at the bottom and are a single NSView we assume its a tab bar.
            if childViewController.layoutAttribute == .bottom &&
                childViewController.view.className == "NSView" &&
                childViewController.view.subviews.isEmpty {
                return true
            }

            return false
        }

        // View controllers should be tagged with this as soon as possible to
        // increase our accuracy. We do this manually.
        return childViewController.identifier == Self.tabBarIdentifier
    }

    private func tabBarDidAppear() {
        // Remove our reset zoom accessory. For some reason having a SwiftUI
        // titlebar accessory causes our content view scaling to be wrong.
        // Removing it fixes it, we just need to remember to add it again later.
        if let idx = titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) {
            removeTitlebarAccessoryViewController(at: idx)
        }

        // We don't need to do this with the update accessory. I don't know why but
        // everything works fine.
    }

    private func tabBarDidDisappear() {
        if styleMask.contains(.titled) {
            if titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) == nil {
                addTitlebarAccessoryViewController(resetZoomAccessory)
            }
        }
    }

    // MARK: Tab Accessory

    /// The Poltergeist mark shown beside this tab's title; empty for none.
    ///
    /// It is one item in the tab's accessory stack. Setting it shows or
    /// hides that item and leaves the rest of the stack alone.
    var poltergeistMark: String = "" {
        didSet {
            guard poltergeistMark != oldValue else { return }
            refreshTabAccessory()
        }
    }

    /// The project this tab is a page of; nil for none. Set by the tab's
    /// controller whenever it joins or leaves one. Shows or hides the
    /// project mark and leaves the rest of the stack alone.
    var projectOfTab: String? {
        didSet {
            guard projectOfTab != oldValue else { return }
            refreshTabAccessory()
        }
    }

    /// The colour of the project this tab is a page of (task 1796); `.none`
    /// for none, or a project not given one yet. Set by the tab's controller
    /// with `projectOfTab`.
    var projectColorOfTab: PaneColor = .none {
        didSet {
            guard projectColorOfTab != oldValue else { return }
            projectMarkView.color = projectColorOfTab
        }
    }

    /// The mark of a page of a project: two stacked pages, the size of the
    /// status glyph, in the project's colour and its glow (task 1796).
    private lazy var projectMarkView: ProjectMarkView = {
        let size = CGFloat(ControlRoomLook.WindowTab.glyph)
        let view = ProjectMarkView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        view.isHidden = true
        return view
    }()

    /// The label that draws the Poltergeist mark.
    private lazy var poltergeistMarkLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Self.smallFace.font
        label.alignment = .center
        label.isHidden = true
        return label
    }()

    /// The view for each thing in the tab's accessory stack. Exhaustive on
    /// purpose: a new `TabAccessory.Item` does not compile until it has a
    /// view here.
    private func tabAccessoryView(for item: TabAccessory.Item) -> NSView {
        switch item {
        case .paneDots: return paneDotsView
        case .projectMark: return projectMarkView
        case .poltergeistMark: return poltergeistMarkLabel
        case .keyEquivalent: return keyEquivalentLabel
        case .resetZoom: return resetZoomTabButton
        case .status: return tabStatusView
        }
    }

    /// What this tab's terminals want from the person, as the core's
    /// control-room snapshot gives it. Read from the snapshot everyone
    /// shares; this window never fetches one.
    private var tabStatus: ControlRoomPulse.TabStatus = .none {
        didSet {
            guard tabStatus != oldValue else { return }
            refreshTabAccessory()
        }
    }

    private lazy var tabStatusView: NSHostingView<ControlRoomGlyph> = {
        let view = NSHostingView(rootView: ControlRoomGlyph(
            shown: .none, size: CGFloat(ControlRoomLook.WindowTab.glyph)))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private var tabStatusListening: AnyCancellable?

    /// Work this tab's glyph out again from the snapshot already in hand.
    /// Called when a snapshot arrives and when the tab in front changes --
    /// which moves the breathing glyph without the core having said
    /// anything.
    func refreshTabStatus() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let group: AnyObject = tabGroup ?? self
        let front: NSWindow = tabGroup?.selectedWindow ?? self
        // The project mark is full on the tab in front, faded on the rest.
        projectMarkView.selected = front === self
        // The same three numbers the core is told for this window
        // (`Ghostty.App.poltergeistGrouping`).
        tabStatus = ControlRoomPulse.status(
            ofTab: ControlRoomPulse.id(UInt64(UInt(bitPattern: ObjectIdentifier(self)))),
            inWindow: ControlRoomPulse.id(UInt64(UInt(bitPattern: ObjectIdentifier(group)))),
            showing: ControlRoomPulse.id(UInt64(UInt(bitPattern: ObjectIdentifier(front)))),
            in: ControlRoomFeed.shared(appDelegate.ghostty).latest)
    }

    /// Make the accessory stack show what `TabAccessory` says it should.
    private func refreshTabAccessory() {
        poltergeistMarkLabel.stringValue = TabAccessory.markText(poltergeistMark)

        tabStatusView.rootView = ControlRoomGlyph(
            shown: tabStatus.shown, pulses: tabStatus.pulses,
            size: CGFloat(ControlRoomLook.WindowTab.glyph))

        projectMarkView.toolTip = projectOfTab.map(TabAccessory.projectMarkHelp)

        paneDotsView.rootView = TabPaneDotsView(drawn: paneDots, lit: highlightedTab)
        paneDotsView.toolTip = paneDots.isEmpty ? nil : TabDots.tip(paneDots)
        paneDotsView.setAccessibilityLabel(paneDots.isEmpty ? nil : TabDots.tip(paneDots))

        let visible = TabAccessory.visibleItems(.init(
            poltergeistMark: poltergeistMark,
            surfaceIsZoomed: surfaceIsZoomed,
            status: tabStatus.shown,
            project: projectOfTab,
            highlighted: highlightedTab,
            hasDots: !paneDots.isEmpty))
        for item in TabAccessory.Item.allCases {
            tabAccessoryView(for: item).isHidden = !visible.contains(item)
        }
    }

    // MARK: Highlight

    /// Whether `terminal_highlight` has lit a terminal of this tab (task
    /// 1689). Set by `PolterHighlight` and by nothing else.
    private var highlightedTab = false

    /// The pane dots beside the title, and the ring round them while a
    /// terminal of the tab is lit (`TabPaneDotsView`). Sized by its own
    /// content: the width is the dots', the height the tab glyph's.
    private lazy var paneDotsView: NSHostingView<TabPaneDotsView> = {
        let view = NSHostingView(rootView: TabPaneDotsView(drawn: paneDots, lit: false))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: CGFloat(ControlRoomLook.WindowTab.glyph) + 2 * CGFloat(ControlRoomLook.TabDots.ringGap + ControlRoomLook.TabDots.ring)).isActive = true
        view.isHidden = true
        return view
    }()

    /// The layer laid over this tab's own button while it is lit: a ground
    /// and an edge in the accent that breathe on the pane's curve. Added to
    /// the system's button and taken off again; nothing of the bar's own is
    /// changed.
    private var highlightTabLayer: CALayer?
    private weak var highlightTabButton: NSView?

    /// Light this tab, or stop. Safe to call again while lit: the bar is
    /// rebuilt when tabs come and go, and the layer follows the button that
    /// is this tab's now.
    func polterHighlightTab(_ on: Bool) {
        if highlightedTab != on {
            highlightedTab = on
            refreshTabAccessory()
        }
        guard on, let button = ownTabButton() else {
            highlightTabLayer?.removeFromSuperlayer()
            highlightTabLayer = nil
            highlightTabButton = nil
            return
        }
        if highlightTabButton === button, let layer = highlightTabLayer, layer.superlayer != nil {
            layer.frame = button.bounds.insetBy(dx: 1, dy: 1)
            return
        }
        highlightTabLayer?.removeFromSuperlayer()
        button.wantsLayer = true
        guard let host = button.layer else { return }
        let layer = CALayer()
        let accent = NSColor.controlAccentColor
        layer.frame = button.bounds.insetBy(dx: 1, dy: 1)
        layer.cornerRadius = 6
        layer.backgroundColor = accent.withAlphaComponent(ControlRoomLook.Highlight.tabGround).cgColor
        layer.borderColor = accent.cgColor
        layer.borderWidth = ControlRoomLook.Highlight.tabEdge
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.opacity = Float(PolterHighlightRules.breath(at: 0, reduceMotion: true))
        } else {
            let breathing = CAKeyframeAnimation(keyPath: "opacity")
            breathing.values = PolterHighlightRules.breathKeyframes()
            breathing.duration = ControlRoomLook.Highlight.breathPeriod
            breathing.repeatCount = .infinity
            breathing.calculationMode = .linear
            layer.add(breathing, forKey: "polter.highlight.breath")
        }
        host.addSublayer(layer)
        highlightTabLayer = layer
        highlightTabButton = button
    }

    /// This tab's button in the bar the person can see; nil when there is
    /// no bar (one tab) or the bar does not line up with the group.
    ///
    /// **The bar of the tab in front, not this window's own.** Every window
    /// of a tab group carries a bar, and only the selected one's is on
    /// screen: a layer put on this window's own bar vanished the moment
    /// another tab was chosen -- which is when it is needed (task 1689).
    /// `PolterHighlight` calls this again four times a second, so the layer
    /// follows the selection.
    private func ownTabButton() -> NSView? {
        guard let group = tabGroup, let index = group.windows.firstIndex(of: self) else { return nil }
        let shown = group.selectedWindow ?? self
        let buttons = shown.tabButtonsInVisualOrder()
        guard buttons.count == group.windows.count else { return nil }
        return buttons[index]
    }

    // MARK: Tab Key Equivalents

    var keyEquivalent: String? {
        didSet {
            // When our key equivalent is set, we must update the tab label.
            guard let keyEquivalent else {
                keyEquivalentLabel.attributedStringValue = NSAttributedString()
                return
            }

            // No font while the system has none, rather than a nil in
            // the attributes, which CoreText throws on (task 1805).
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            if let font = Self.smallFace.font { attributes[.font] = font }
            keyEquivalentLabel.attributedStringValue = NSAttributedString(
                string: "\(keyEquivalent) ",
                attributes: attributes)
        }
    }

    /// The label that has the key equivalent for tab views.
    private lazy var keyEquivalentLabel: NSTextField = {
        let label = NSTextField(labelWithAttributedString: NSAttributedString())
        label.setContentCompressionResistancePriority(.windowSizeStayPut, for: .horizontal)
        label.postsFrameChangedNotifications = true
        return label
    }()

    // MARK: Surface Zoom

    /// Set to true if a surface is currently zoomed to show the reset zoom button.
    var surfaceIsZoomed: Bool = false {
        didSet {
            // Show/hide our reset zoom button depending on if we're zoomed.
            // We want to show it if we are zoomed.
            refreshTabAccessory()

            DispatchQueue.main.async {
                self.viewModel.isSurfaceZoomed = self.surfaceIsZoomed
            }
        }
    }

    private lazy var resetZoomTabButton: NSButton = generateResetZoomButton()

    private func generateResetZoomButton() -> NSButton {
        let button = NSButton()
        button.isHidden = true
        button.target = terminalController
        button.action = #selector(TerminalController.splitZoom(_:))
        button.isBordered = false
        button.allowsExpansionToolTips = true
        button.toolTip = String(localized: "Reset Zoom", comment: "标签页右键菜单／标题栏")
        button.contentTintColor = isMainWindow ? .controlAccentColor : .secondaryLabelColor
        button.state = .on
        button.image = NSImage(named: "ResetZoom")
        button.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    // MARK: Title Text

    override var title: String {
        didSet {
            // Whenever we change the window title we must also update our
            // tab title if we're using custom fonts.
            tab.attributedTitle = attributedTitle
            guard title != oldValue else { return }

            syncWindowTitleAppearance()
        }
    }

    /// The faces this window falls back to (task 1805): made through
    /// `SafeFace`, which never keeps a nil and never hands one on.
    private static let smallFace = SafeFace(size: NSFont.smallSystemFontSize)
    static let titleBarFace = SafeFace(size: NSFont.systemFontSize, design: .titleBar)

    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? Self.titleBarFace.font
            tab.attributedTitle = attributedTitle

            // We need to call this every time the font is set,
            // after entering or exiting fullscreen, or other cases,
            // AppKit will reset the font.
            syncWindowTitleAppearance(font: font)
        }
    }

    // Find the array of NSTextField responsible for displaying the titlebar's title.
    // In fullscreen mode, there'll be two of them.
    private var titlebarTextFields: [NSTextField] {
        (titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")?
            .descendants(withClassName: "NSTextField")
            .compactMap { $0 as? NSTextField } ?? [])
            .filter({ $0.superview?.className == "NSTitlebarView" })
    }

    // Cancellables for the frame change of the text fields in the titlebar.
    private var titlebarTextFieldFrameCancellables = Set<AnyCancellable>()

    // Return a styled representation of our title property.
    var attributedTitle: NSAttributedString? {
        guard let titlebarFont = titlebarFont else { return nil }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titlebarFont,
            .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        return NSAttributedString(string: title, attributes: attributes)
    }

    var titlebarContainer: NSView? {
        // If we aren't fullscreen then the titlebar container is part of our window.
        if !styleMask.contains(.fullScreen) {
            return contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        // If we are fullscreen, the titlebar container view is part of a separate
        // "fullscreen window", we need to find the window and then get the view.
        for window in NSApplication.shared.windows {
            // This is the private window class that contains the toolbar
            guard window.className == "NSToolbarFullScreenWindow" else { continue }

            // The parent will match our window. This is used to filter the correct
            // fullscreen window if we have multiple.
            guard window.parent == self else { continue }

            return window.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        return nil
    }

    // MARK: Positioning And Styling

    /// Update titlebarTextField's size and font
    func syncWindowTitleAppearance(font: NSFont? = nil) {
        titlebarTextFields.forEach { field in
            if let font {
                field.font = font
            }
        }

        titlebarTextFieldFrameCancellables.removeAll()

        // macOS 15 doesn't seem to need to adjust the frame.
        //
        // When using custom font, we always expand the frame to
        // show the text properly.
        //
        // AppKit will relayout the frame when the font changes, that's
        // why we need this hack in the first place.
        guard #available(macOS 26.0, *), titlebarFont != nil else {
            return
        }

        titlebarTextFields.forEach { field in
            setWindowTitleFrameSize(field)
        }

        // We need to observe changes to make the frame correct in some cases:
        //
        // 1. Entering fullscreen mode.
        //    > Updating the frame when it's hidden doesn't seem to work.
        // 2. Exiting fullscreen mode.
        // 3. Resizing the window.
        // 3. Maybe more...

        titlebarTextFields.forEach { field in
            field.postsFrameChangedNotifications = true
            NotificationCenter.default
                .publisher(for: NSView.frameDidChangeNotification, object: field)
                .compactMap { $0.object as? NSTextField }
                .sink { [weak self] in
                    self?.setWindowTitleFrameSize($0)
                }
                .store(in: &titlebarTextFieldFrameCancellables)
        }
    }

    private func setWindowTitleFrameSize(_ textfield: NSTextField) {
        guard let superview = textfield.superview else { return }

        // Button group size estimate: 92.
        // Make the available space a little bit smaller.
        let fittingSize = textfield.sizeThatFits(superview.bounds.insetBy(dx: 92/2 + 6, dy: 0).size)
        // We make the frame a little bit higher so fixed-width fonts can
        // align center vertically as well.
        let properSize = CGSize(width: fittingSize.width, height: fittingSize.height * 1.1)

        guard textfield.frame.size != properSize else { return }
        textfield.frame.size = properSize
    }

    /// This is called by the controller when there is a need to reset the window appearance.
    func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // If our window is not visible, then we do nothing. Some things such as blurring
        // have no effect if the window is not visible. Ultimately, we'll have this called
        // at some point when a surface becomes focused.
        guard isVisible else { return }
        defer { updateColorSchemeForSurfaceTree() }

        // Basic properties
        appearance = surfaceConfig.windowAppearance
        hasShadow = surfaceConfig.macosWindowShadow

        // Window transparency only takes effect if our window is not native fullscreen.
        // In native fullscreen we disable transparency/opacity because the background
        // becomes gray and widgets show through.
        //
        // Also check if the user has overridden transparency to be fully opaque.
        let forceOpaque = terminalController?.isBackgroundOpaque ?? false
        if !styleMask.contains(.fullScreen) &&
            !forceOpaque &&
            (surfaceConfig.backgroundOpacity < 1 || surfaceConfig.backgroundBlur.isGlassStyle) {
            isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            backgroundColor = .white.withAlphaComponent(0.001)

            // We don't need to set blur when using glass
            if !surfaceConfig.backgroundBlur.isGlassStyle, let appDelegate = NSApp.delegate as? AppDelegate {
                ghostty_set_window_background_blur(
                    appDelegate.ghostty.app,
                    Unmanaged.passUnretained(self).toOpaque())
            }
        } else {
            isOpaque = true

            let backgroundColor = preferredBackgroundColor ?? NSColor(surfaceConfig.backgroundColor)
            self.backgroundColor = backgroundColor.withAlphaComponent(1)
        }
    }

    /// The preferred window background color. The current window background color may not be set
    /// to this, since this is dynamic based on the state of the surface tree.
    ///
    /// This background color will include alpha transparency if set. If the caller doesn't want that,
    /// change the alpha channel again manually.
    var preferredBackgroundColor: NSColor? {
        if let terminalController, !terminalController.surfaceTree.isEmpty {
            let surface: Ghostty.SurfaceView?

            // If our focused surface borders the top then we prefer its background color
            if let focusedSurface = terminalController.focusedSurface,
               let treeRoot = terminalController.surfaceTree.root,
               let focusedNode = treeRoot.node(view: focusedSurface),
               treeRoot.spatial().doesBorder(side: .up, from: focusedNode) {
                surface = focusedSurface
            } else {
                // If it doesn't border the top, we use the top-left leaf
                surface = terminalController.surfaceTree.root?.leftmostLeaf()
            }

            if let surface {
                let backgroundColor = surface.backgroundColor ?? surface.derivedConfig.backgroundColor
                let alpha = surface.derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
                return NSColor(backgroundColor).withAlphaComponent(alpha)
            }
        }

        let alpha = derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
        return derivedConfig.backgroundColor.withAlphaComponent(alpha)
    }

    func updateColorSchemeForSurfaceTree() {
        terminalController?.updateColorSchemeForSurfaceTree()
    }

    func setInitialWindowPosition(x: Int16?, y: Int16?) -> Bool {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard let x = x, let y = y else {
            return false
        }

        // Prefer the screen our window is being placed on otherwise our primary screen.
        guard let screen = screen ?? NSScreen.screens.first else {
            return false
        }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        setFrameOrigin(safeOrigin)
        return true
    }

    private func hideWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    deinit {
        if let observer = tabMenuObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Config

    struct DerivedConfig {
        let title: String?
        let backgroundBlur: Ghostty.Config.BackgroundBlur
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let windowCornerRadius: CGFloat

        init() {
            self.title = nil
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
            self.backgroundBlur = .disabled
            self.macosTitlebarStyle = .default
            self.windowCornerRadius = 16
        }

        init(_ config: Ghostty.Config) {
            self.title = config.title
            self.backgroundColor = NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.macosWindowButtons = config.macosWindowButtons
            self.backgroundBlur = config.backgroundBlur
            self.macosTitlebarStyle = config.macosTitlebarStyle

            // Set corner radius based on macos-titlebar-style
            // Native, transparent, and hidden styles use 16pt radius
            // Tabs style uses 20pt radius
            switch config.macosTitlebarStyle {
            case .tabs:
                self.windowCornerRadius = 20
            default:
                self.windowCornerRadius = 16
            }
        }
    }
}

// MARK: SwiftUI View

extension TerminalWindow {
    class ViewModel: ObservableObject {
        @Published var isSurfaceZoomed: Bool = false
        @Published var hasToolbar: Bool = false
        @Published var isMainWindow: Bool = true

        /// Calculates the top padding based on toolbar visibility and macOS version
        fileprivate var accessoryTopPadding: CGFloat {
            if #available(macOS 26.0, *) {
                return hasToolbar ? 10 : 5
            } else {
                return hasToolbar ? 9 : 4
            }
        }
    }

    struct ResetZoomAccessoryView: View {
        @ObservedObject var viewModel: ViewModel
        let action: () -> Void

        var body: some View {
            if viewModel.isSurfaceZoomed {
                VStack {
                    Button(action: action) {
                        Image("ResetZoom")
                            .foregroundColor(viewModel.isMainWindow ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Reset Split Zoom", comment: "窗口标题栏／菜单"))
                    .frame(width: 20, height: 20)
                    Spacer()
                }
                // With a toolbar, the window title is taller, so we need more padding
                // to properly align.
                .padding(.top, viewModel.accessoryTopPadding)
                // We always need space at the end of the titlebar
                .padding(.trailing, 10)
            }
        }
    }

    /// A pill-shaped button that displays update status and provides access to update actions.
    struct UpdateAccessoryView: View {
        @ObservedObject var viewModel: ViewModel
        @ObservedObject var model: UpdateViewModel

        var body: some View {
            // We use the same top/trailing padding so that it hugs the same.
            UpdatePill(model: model)
                .padding(.top, viewModel.accessoryTopPadding)
                .padding(.trailing, viewModel.accessoryTopPadding)
        }
    }

}

// MARK: - Tab Context Menu

extension TerminalWindow {
    private static let closeTabsOnRightMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.closeTabsOnTheRightMenuItem")
    private static let changeTitleMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.changeTitleMenuItem")
    private static let tabColorSeparatorIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.tabColorSeparator")

    private static let tabColorPaletteIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.tabColorPalette")

    private static let agentSeparatorIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.agentSeparator")
    private static let agentSupervisorIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.agentSupervisor")
    private static let agentWatchIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.agentWatch")
    private static let agentHeldIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.agentHeld")
    private static let agentShieldIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.agentShield")
    private static let agentWorkersIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.agentWorkers")
    private static let agentAuthoriseIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.agentAuthorise")
    private static let agentPersonaIdentifier = PersonaMenu.itemIdentifier
    private static let agentMentionsIdentifier = MentionMenu.itemIdentifier

    private static let copyTerminalIDIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.copyTerminalID")
    private static let projectSeparatorIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.projectSeparator")
    private static let projectSaveAsIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.projectSaveAs")
    private static let projectForGroupIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.projectForGroup")
    private static let projectForGroupSeparatorIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.projectForGroupSeparator")
    private static let projectLoadIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.projectLoad")
    private static let projectAddToIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.projectAddTo")
    private static let projectTakeOutIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.projectTakeOut")

    func configureTabContextMenuIfNeeded(_ menu: NSMenu) {
        guard isTabContextMenu(menu) else { return }

        // Get the target from an existing menu item. The native tab context menu items
        // target the specific window/controller that was right-clicked, not the focused one.
        // We need to use that same target so validation and action use the correct tab.
        let targetWindow = menu.items
            .first { $0.action == NSSelectorFromString("performClose:") }
            .flatMap { $0.target as? NSWindow }
        let targetController = targetWindow.flatMap { $0.windowController as? TerminalController }

        // The control room's tab is not a terminal, so it gets none of the
        // items below. With no controller to aim them at they would go to
        // the first responder -- the *selected* tab's terminal -- and
        // "Make This Terminal a Supervisor" on the tab under the pointer
        // would act on a different one. Items left from an earlier opening
        // of this menu are taken out for the same reason.
        if targetWindow?.windowController is ControlRoomController {
            for item in menu.items.reversed() where Self.isOurTabMenuItem(item) {
                menu.removeItem(item)
            }
            return
        }

        // Close tabs to the right
        let item = Self.polterCloseTabsToTheRightItem(target: targetController)
        if menu.insertItem(item, after: NSSelectorFromString("performCloseOtherTabs:")) == nil,
           menu.insertItem(item, after: NSSelectorFromString("performClose:")) == nil {
            menu.addItem(item)
        }

        // Other close items should have the xmark to match Safari on macOS 26
        for menuItem in menu.items {
            if menuItem.action == NSSelectorFromString("performClose:") ||
                menuItem.action == NSSelectorFromString("performCloseOtherTabs:") {
                menuItem.setImageIfDesired(systemSymbolName: "xmark")
            }
        }

        polterAppendTabSections(to: menu, target: targetController)
    }

    /// "Close Tabs to the Right", for the tab `target` is.
    static func polterCloseTabsToTheRightItem(target: TerminalController?) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Close Tabs to the Right", comment: "标签页右键菜单／标题栏"), action: #selector(TerminalController.closeTabsOnTheRight(_:)), keyEquivalent: "")
        item.identifier = Self.closeTabsOnRightMenuItemIdentifier
        item.target = target
        item.setImageIfDesired(systemSymbolName: "xmark")
        return item
    }

    /// Every section this class adds to a tab's menu after the system's own
    /// items: the tab's title and colour, its project, and what an agent
    /// may do with its terminal. **The one builder for both menus** -- the
    /// tab's, and a pane's title and a stack's tab (task 1582,
    /// `TerminalController.polterPaneMenu`) -- so the two cannot drift.
    ///
    /// `copyIDs`: whether the tab's «Copy Terminal ID» is among them. A
    /// pane's menu has its own, for the pane, and leaves the tab's out.
    func polterAppendTabSections(to menu: NSMenu, target: TerminalController?, copyIDs: Bool = true) {
        appendTabModifierSection(to: menu, target: target, copyIDs: copyIDs)
        appendProjectSection(to: menu, target: target)
        appendAgentSection(to: menu, target: target)
    }

    /// One of the items this class adds to the tab's context menu, as
    /// opposed to the system's own. Every identifier we give one starts
    /// with one of these two.
    private static func isOurTabMenuItem(_ item: NSMenuItem) -> Bool {
        guard let identifier = item.identifier?.rawValue else { return false }
        return identifier.hasPrefix("com.mitchellh.ghostty.") || identifier.hasPrefix("com.lugia.polter.")
    }

    private func isTabContextMenu(_ menu: NSMenu) -> Bool {
        guard NSApp.keyWindow === self else { return false }

        // These selectors must all exist for it to be a tab context menu.
        let requiredSelectors: Set<String> = [
            "performClose:",
            "performCloseOtherTabs:",
            "moveTabToNewWindow:",
            "toggleTabOverview:"
        ]

        let selectorNames = Set(menu.items.compactMap { $0.action }.map { NSStringFromSelector($0) })
        return requiredSelectors.isSubset(of: selectorNames)
    }

    /// The per-terminal agent actions, on the tab that was right-clicked.
    ///
    /// The same three that are in the Agents menu and the terminal's own
    /// context menu. They belong here because each is about one terminal,
    /// and the tab strip is where you look when you are deciding *which*
    /// terminal -- picking the supervisor out of six tabs by clicking into
    /// each one first is the long way round.
    ///
    /// `target` is the right-clicked tab's controller, not the focused one,
    /// which is what makes this act on the tab under the pointer.
    private func appendAgentSection(to menu: NSMenu, target: TerminalController?) {
        menu.removeItems(withIdentifiers: [
            Self.agentSeparatorIdentifier,
            Self.agentSupervisorIdentifier,
            Self.agentWatchIdentifier,
            Self.agentHeldIdentifier,
            Self.agentShieldIdentifier,
            Self.agentWorkersIdentifier,
            Self.agentAuthoriseIdentifier,
            Self.agentPersonaIdentifier,
            Self.agentMentionsIdentifier,
        ])

        let separator = NSMenuItem.separator()
        separator.identifier = Self.agentSeparatorIdentifier
        menu.addItem(separator)

        let entries: [(String, String, Selector, NSUserInterfaceItemIdentifier)] = [
            (String(localized: "Make This Terminal a Supervisor",
                    comment: "标签页右键菜单：设为总管"),
             "eyeglasses",
             #selector(TerminalController.poltergeistSupervisor(_:)),
             Self.agentSupervisorIdentifier),
            (String(localized: "Supervise This Terminal",
                    comment: "标签页右键菜单：监督此终端"),
             "binoculars",
             #selector(TerminalController.poltergeistToggleWatch(_:)),
             Self.agentWatchIdentifier),
            (String(localized: "Keep Agents Out of This Terminal",
                    comment: "标签页右键菜单：护盾，任何 agent 都不许碰"),
             "lock",
             #selector(TerminalController.poltergeistToggleShielded(_:)),
             Self.agentShieldIdentifier),
            (String(localized: "Don't Start Workers in This Terminal",
                    comment: "标签页右键菜单：不在此终端开 worker；agent 仍可读、可发命令"),
             "apple.terminal",
             #selector(TerminalController.poltergeistToggleWorkersRefused(_:)),
             Self.agentWorkersIdentifier),
            (String(localized: "Let a Supervisor Answer Prompts Here",
                    comment: "标签页右键菜单：允许总管替此终端点授权框，含「不再询问」"),
             "hand.raised",
             #selector(TerminalController.poltergeistToggleAuthorise(_:)),
             Self.agentAuthoriseIdentifier),
        ]

        // Ticked when the terminal already is what the entry offers to make
        // it. An item that has been used has to read differently from one
        // that has not, or the only way to learn whether the last click
        // landed is to click it again.
        let surface = target?.focusedSurface
        for (title, symbol, action, identifier) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.identifier = identifier
            item.target = target
            item.setImageIfDesired(systemSymbolName: symbol)
            if identifier == Self.agentSupervisorIdentifier {
                item.state = surface?.poltergeistRole == .supervisor ? .on : .off
            } else if identifier == Self.agentWatchIdentifier {
                item.state = surface?.poltergeistRole == .watched ? .on : .off
            } else if identifier == Self.agentShieldIdentifier {
                item.state = (surface?.poltergeistShielded ?? false) ? .on : .off
            } else if identifier == Self.agentWorkersIdentifier {
                item.state = (surface?.poltergeistWorkersRefused ?? false) ? .on : .off
            } else if identifier == Self.agentAuthoriseIdentifier {
                item.state = (surface?.poltergeistMayAuthorise ?? false) ? .on : .off
            }
            menu.addItem(item)
        }

        // "Role ▸" sits with the four toggles because it is the same kind
        // of thing: one terminal, decided from the tab strip rather than by
        // clicking into each tab first. Built by `PersonaMenu` so this copy and
        // the terminal's own context menu cannot drift apart -- and pointed
        // at `target`, the right-clicked tab, not the focused one.
        let catalog = PersonaCatalog.shared
        catalog.reload()
        surface?.reloadPersonaFace()
        menu.addItem(PersonaMenu.makeItem(
            state: surface?.poltergeistPersonaState ?? .none,
            shielded: surface?.poltergeistShielded ?? false,
            personas: catalog.personas,
            personasKnown: catalog.isKnown,
            target: target))

        // The supervisor's direct-mentions switch. Same builder as the
        // terminal's own menu and the menu bar, same right-clicked `target`.
        menu.addItem(MentionMenu.makeItem(
            isSupervisor: surface?.poltergeistRole == .supervisor,
            allowed: surface?.poltergeistWorkerMentions ?? false,
            target: target))
    }

    private func appendTabModifierSection(to menu: NSMenu, target: TerminalController?, copyIDs: Bool) {
        menu.removeItems(withIdentifiers: [
            Self.tabColorSeparatorIdentifier,
            Self.changeTitleMenuItemIdentifier,
            Self.copyTerminalIDIdentifier,
            Self.tabColorPaletteIdentifier
        ])

        let separator = NSMenuItem.separator()
        separator.identifier = Self.tabColorSeparatorIdentifier
        menu.addItem(separator)

        // Rename Tab...
        let changeTitleItem = NSMenuItem(title: String(localized: "Rename Tab...", comment: "标签页右键菜单／标题栏"), action: #selector(TerminalWindow.renameTabFromContextMenu(_:)), keyEquivalent: "")
        changeTitleItem.identifier = Self.changeTitleMenuItemIdentifier
        changeTitleItem.target = self
        changeTitleItem.representedObject = target?.window
        changeTitleItem.setImageIfDesired(systemSymbolName: "pencil.line")
        menu.addItem(changeTitleItem)

        // The ids of the tab's terminals, for pasting to an agent (task
        // 1643): one is copied straight, several are a submenu.
        if copyIDs, let target, let copy = TerminalIDMenu.tabItem(for: target.surfaceTree.members()) {
            copy.identifier = Self.copyTerminalIDIdentifier
            menu.addItem(copy)
        }

        // The colour of one pane (task 1699): on a tab, the pane of it that
        // has focus; on a pane's title or a stack's tab, that pane, which
        // `polterPaneMenu` has just focused.
        let paletteItem = NSMenuItem()
        paletteItem.identifier = Self.tabColorPaletteIdentifier
        paletteItem.view = makePaneColorPaletteView(
            selectedColor: target?.focusedSurface?.poltergeistPaneColor ?? .none
        ) { [weak target] color in
            target?.setPaneColor(color)
        }
        menu.addItem(paletteItem)
    }

    /// "Save as Project" / "Load Project" for the right-clicked tab.
    ///
    /// Distinct from "Reopen Closed Tab" (`ClosedTabs`): that's a 20-entry
    /// undo stack keyed only by directory, for a tab you closed by
    /// accident. A project is named, captures the whole split tree, and is
    /// kept until you delete it.
    private func appendProjectSection(to menu: NSMenu, target: TerminalController?) {
        menu.removeItems(withIdentifiers: [
            Self.projectForGroupIdentifier,
            Self.projectForGroupSeparatorIdentifier,
            Self.projectSeparatorIdentifier,
            Self.projectSaveAsIdentifier,
            Self.projectLoadIdentifier,
            Self.projectAddToIdentifier,
            Self.projectTakeOutIdentifier,
        ])

        // The tab holds a group's supervisor: the menu's first item saves
        // it as that group's project (task 1713, §3.5).
        if let target, let group = ProjectLinkDesk.shared?.supervisorGroup(in: target) {
            let forGroup = NSMenuItem(
                title: ProjectLinkPlan.saveForGroupTitle(group),
                action: #selector(TerminalController.saveAsGroupProject(_:)),
                keyEquivalent: "")
            forGroup.identifier = Self.projectForGroupIdentifier
            forGroup.representedObject = group
            forGroup.target = target
            forGroup.setImageIfDesired(systemSymbolName: "square.and.arrow.down")
            let after = NSMenuItem.separator()
            after.identifier = Self.projectForGroupSeparatorIdentifier
            menu.insertItem(after, at: 0)
            menu.insertItem(forGroup, at: 0)
        }

        let separator = NSMenuItem.separator()
        separator.identifier = Self.projectSeparatorIdentifier
        menu.addItem(separator)

        let saveItem = NSMenuItem(
            title: String(localized: "Save as Project...", comment: "标签页右键菜单：另存为项目"),
            action: #selector(TerminalController.saveAsProject(_:)),
            keyEquivalent: "")
        saveItem.identifier = Self.projectSaveAsIdentifier
        saveItem.target = target
        saveItem.setImageIfDesired(systemSymbolName: "square.and.arrow.down")
        menu.addItem(saveItem)

        let loadItem = NSMenuItem(
            title: String(localized: "Load Project...", comment: "标签页右键菜单：加载项目"),
            action: #selector(TerminalController.loadProject(_:)),
            keyEquivalent: "")
        loadItem.identifier = Self.projectLoadIdentifier
        loadItem.target = target
        loadItem.setImageIfDesired(systemSymbolName: "square.and.arrow.up")
        menu.addItem(loadItem)

        // "Add to Project ▸": every project there is, and at the bottom the
        // way to make a new one of this tab. Offered -- by the tab's own
        // `validateMenuItem` -- only to a tab that is a page of none.
        let project = target?.boundProject
        let addItem = NSMenuItem(
            title: String(localized: "Add to Project", comment: "标签页右键菜单：加入项目（子菜单列出现有项目）"),
            action: nil,
            keyEquivalent: "")
        addItem.identifier = Self.projectAddToIdentifier
        let submenu = NSMenu()
        submenu.autoenablesItems = true
        for entry in ProjectStore.shared.list() {
            let item = NSMenuItem(
                title: entry.name,
                action: #selector(TerminalController.addToProject(_:)),
                keyEquivalent: "")
            item.representedObject = entry.name
            item.target = target
            submenu.addItem(item)
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        let newItem = NSMenuItem(
            title: String(localized: "Save as New Project...", comment: "标签页右键菜单·加入项目子菜单最下面：存为新项目"),
            action: #selector(TerminalController.saveAsProject(_:)),
            keyEquivalent: "")
        newItem.target = target
        submenu.addItem(newItem)
        // An item with a submenu is always enabled, whatever its menu
        // thinks of it; one with neither submenu nor action is not. So a
        // tab that is a page already gets the item without the submenu.
        if ProjectPageRules.offered(.addTo, pageOf: project) {
            addItem.submenu = submenu
        }
        menu.addItem(addItem)

        let takeOutItem = NSMenuItem(
            title: ProjectPageRules.takeOutTitle(project: project),
            action: #selector(TerminalController.takeOutOfProject(_:)),
            keyEquivalent: "")
        takeOutItem.identifier = Self.projectTakeOutIdentifier
        takeOutItem.target = target
        menu.addItem(takeOutItem)
    }
}

// MARK: - Inline Tab Title Editing

extension TerminalWindow: TabTitleEditorDelegate {
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        canRenameTabFor targetWindow: NSWindow
    ) -> Bool {
        targetWindow.windowController is BaseTerminalController
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        titleFor targetWindow: NSWindow
    ) -> String {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else {
            return targetWindow.title
        }

        return targetController.titleOverride ?? targetWindow.title
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        didCommitTitle editedTitle: String,
        for targetWindow: NSWindow
    ) {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.titleOverride = editedTitle.isEmpty ? nil : editedTitle
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        performFallbackRenameFor targetWindow: NSWindow
    ) {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.promptTabTitle()
    }

    func tabTitleEditor(_ editor: TabTitleEditor, didFinishEditing targetWindow: NSWindow) {
        // After inline editing, the first responder is the window itself.
        // Restore focus to the terminal surface so keyboard input works.
        guard let controller = windowController as? BaseTerminalController,
              let focusedSurface = controller.focusedSurface
        else { return }
        makeFirstResponder(focusedSurface)
    }
}
