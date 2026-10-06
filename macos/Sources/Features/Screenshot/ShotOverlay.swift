import AppKit

/// The window that covers one display with its frozen picture.
///
/// A non-activating panel: it takes the keyboard -- `Esc`, `Enter`, and the
/// text of an annotation, input method included -- without making this app
/// the active one. Whatever was in front when the hotkey was pressed is
/// still in front when the screenshot is done.
///
/// Not opaque, though it paints every pixel: a long screenshot opens a hole
/// in it where the selection is, and the system sends the mouse and the
/// scroll wheel over a clear part of a window to whatever is underneath.
final class ShotOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(display: ShotDisplay) {
        super.init(
            contentRect: display.screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // Above the menu bar and the Dock, which are part of the picture.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        setFrame(display.screen.frame, display: false)
    }
}

/// One display's frozen picture with everything the session has on it
/// (`dev-docs/poltergeist/screenshot.md`, 3.2 and section 9).
///
/// The view holds nothing of its own: it sends the mouse and the keyboard
/// to the session and draws what the session's editor holds. It is flipped,
/// so its coordinates are points from the top left of the display.
final class ShotOverlayView: NSView {
    /// Which display this is, in the session's order.
    let index: Int
    weak var session: ShotSession?

    init(index: Int, size: CGSize) {
        self.index = index
        super.init(frame: CGRect(origin: .zero, size: size))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// Yes, except for the one press that must not take the keyboard from
    /// the text box: a colour or a size, while a text is being typed
    /// (`ShotTextInput.overlayTakesKeyboard`).
    override var acceptsFirstResponder: Bool {
        guard let session else { return true }
        return ShotTextInput.overlayTakesKeyboard(typing: session.isTyping, pressRestyles: session.pressRestylesText())
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func mods(of event: NSEvent) -> ShotMods {
        ShotMods(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // The second press of a double click is a double click, and is sent
        // instead of a press.
        session?.pointerDown(
            at: location(of: event), on: index, mods: mods(of: event), double: event.clickCount % 2 == 0)
    }

    override func mouseDragged(with event: NSEvent) {
        session?.pointerMove(to: location(of: event), on: index, mods: mods(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        session?.pointerMove(to: location(of: event), on: index, mods: mods(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        session?.pointerUp(at: location(of: event), on: index)
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.rightClick(on: index)
    }

    override func cursorUpdate(with event: NSEvent) {
        session?.cursor(at: location(of: event), on: index).set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Everything is the session's, and what it does not use is
        // swallowed: nothing typed here should reach a menu or beep.
        session?.key(event, on: index)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let session else { return super.performKeyEquivalent(with: event) }
        // While text is being typed the text view gets its own keys.
        if session.isTyping { return super.performKeyEquivalent(with: event) }
        session.key(event, on: index)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        session?.draw(display: index, in: ctx)
    }
}
