import AppKit
import OSLog

/// The words the overlay shows, in the app's language. The keys are the
/// English msgids `src/input/screenshot.zig` names, so that both hosts say
/// the same thing.
enum ShotWords {
    static func translate(_ msgid: String) -> String {
        Bundle.main.localizedString(forKey: msgid, value: msgid, table: nil)
    }
}

protocol ShotSessionDelegate: AnyObject {
    /// Cancelled: nothing was written and the clipboard is as it was.
    func sessionDidCancel(_ session: ShotSession)
    func sessionDidFinish(_ session: ShotSession, with result: ShotSession.Result)
}

/// One screenshot from the frozen screen to the composed image: the
/// overlays, the editor that decides what every click and key does, and the
/// two things the editor cannot own -- the text box and the frames of a long
/// screenshot (`dev-docs/poltergeist/screenshot.md`, 3.2 and section 9).
///
/// Everything here runs on the main thread.
final class ShotSession {
    /// What a finished screenshot is.
    struct Result {
        /// The picture, with everything that must not leave already gone
        /// from it.
        var image: ComposedImage
        /// The annotations in the image's own pixels, for the sidecar and
        /// the pasted line. Empty for a long screenshot.
        var items: [Annotation]
        var isLong: Bool
        var scale: Double
        /// The display it was taken on: its index, and its size in pixels.
        var display: Int
        var displaySize: Annotation.PixelSize
        /// The selection in that display's own pixels.
        var selection: PixelRect
        /// The window the selection is, when it still is exactly that
        /// window, and that window's bounds in the display's own pixels.
        var window: ShotWindow?
        var windowRect: PixelRect?
        /// Whether a copy also goes to the Downloads folder: the person
        /// pressed Save rather than Done.
        var saveCopy = false
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: String(describing: ShotSession.self)
    )

    /// How often a long screenshot takes a frame.
    static let longInterval: TimeInterval = 0.12
    /// How often the picture is drawn again while something on it is on
    /// its way somewhere: a window coming into focus, a button lighting up.
    private static let frameInterval: TimeInterval = 1.0 / 120

    weak var delegate: ShotSessionDelegate?

    private let displays: [ShotDisplay]
    private let space: ShotScreenSpace
    private let frozen: [FrozenImage]
    private let windows: [UInt64: ShotWindow]
    private(set) var editor: ShotEditor
    private let measure = ShotTextMeasure()
    private var overlays: [(window: ShotOverlayWindow, view: ShotOverlayView)] = []

    /// Each display's picture out of focus, made once when the screen was
    /// frozen (`ShotBlur`): the small sharp copy the glass is cut from, and
    /// the whole picture as it is shown outside the selection. Nil for a
    /// display when the system is asked to reduce transparency -- then
    /// nothing is blurred and the outside is only darkened.
    ///
    /// Also nil until it has been made. Making it is waited for, briefly,
    /// when the screen is frozen -- an optimised build is done well inside
    /// the wait -- and a build that is not done by then shows the outside
    /// darkened and puts the glass in when it arrives (`blurWait`).
    private var prepared: [ShotBlur.Prepared?]
    private var outside: [CGImage?]
    /// How long freezing the screen waits for the out-of-focus pictures:
    /// three frames, the same on both hosts. Measured on a 3600 x 2338
    /// display: 33 ms optimised, 1.7 s in a debug build, where waiting
    /// would be a hotkey that seems not to have worked.
    static let blurWait: TimeInterval = ShotLook.Glass.waitMs / 1000

    /// The out-of-focus pictures as they come in from the queue that makes
    /// them.
    private final class Soft: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [Int: (ShotBlur.Prepared, CGImage)] = [:]

        func put(_ index: Int, _ prepared: ShotBlur.Prepared, _ image: CGImage) {
            lock.lock()
            made[index] = (prepared, image)
            lock.unlock()
        }

        func take() -> [Int: (ShotBlur.Prepared, CGImage)] {
            lock.lock()
            defer { lock.unlock() }
            return made
        }
    }
    /// Which part of each display is sharp, on its way from one answer to
    /// the next (`ShotVeil`).
    private var fades: [ShotVeil.Fade]
    /// The display the pointer was last seen on.
    private var pointerDisplay: Int?
    /// What was on each display, other than the picture, the last time it
    /// was asked to paint: the next change repaints these and what replaces
    /// them, and nothing else.
    private var painted: [[PixelRect]]
    private var paintedState: PaintState?
    private var frameTimer: Timer?

    /// What the system was asked to do for the person looking: with
    /// transparency reduced or contrast increased the plates are opaque
    /// and nothing is blurred (9.8.10). Read once, when the screen is
    /// frozen.
    private let access: ShotChrome.Access
    private let still: Bool
    /// Where the pointer was last seen, in the editor's pixels: where the
    /// tag of a shape being reshaped goes.
    private var pointer: PixelPoint?
    /// The labels each display had on it the last time it was painted --
    /// the size, the hover text, the status, the tag. Over them the pointer
    /// is an arrow, as it is over the toolbar.
    private(set) var labelRects: [[PixelRect]] = []
    /// Whether the text box's caret is in the showing half of its blink.
    private var caretOn = true
    private var caretTimer: Timer?
    /// Until when the magnifier says "Copied" where the colour's text is.
    private var copiedUntil: TimeInterval = 0
    /// The modifiers held at the last move of the pointer.
    private var lastMods: ShotMods = []
    /// The toolbar button the mouse went down on and is still down on.
    private var pressed: ToolbarButton?
    /// "Cancel" or "done", held down: what the editor will be told when it
    /// is let go.
    private var held: (button: ToolbarButton, at: PixelPoint, mods: ShotMods)?
    /// Each toolbar cell's look, on its way to what the editor says it is.
    private var cellFades: [ToolbarButton: ShotCell.Fade] = [:]
    /// The toolbar as it was last painted, kept while nothing about it
    /// changes: its plate (which is cut from the picture and is the costly
    /// part), and the plate with its cells on.
    private struct PlateKey: Equatable {
        var display: Int
        var plate: PixelRect
        var props: PixelRect?
        var glass: Bool
    }
    private var plateCache: (key: PlateKey, painted: ShotChrome.Painted)?
    private struct ToolbarPicture {
        var key: PlateKey
        var cells: [ShotChrome.Cell]
        var props: AnnotationTool.Props
        var image: CGImage
    }
    private var toolbarCache: ToolbarPicture?
    /// What time it is, in seconds. The system's clock, except in a test
    /// that paints a display into a bitmap and wants a fade over with.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// How the session turns the wheel for a long screenshot and where it
    /// puts the pointer to do it: the system's, except in a test that
    /// scrolls a made-up page.
    struct Scroller {
        /// Whether the system lets this app post wheel events. Asked
        /// without asking the person: the system's own prompt must not
        /// appear in the middle of a screenshot.
        var trusted: () -> Bool
        var pointer: () -> CGPoint
        var park: (CGPoint) -> Void
        /// Scroll the page under the pointer down by this many points.
        var wheel: (Int) -> Void

        static let system = Scroller(
            trusted: { AXIsProcessTrusted() },
            pointer: { CGEvent(source: nil)?.location ?? .zero },
            park: { CGWarpMouseCursorPosition($0) },
            wheel: { points in
                // Down the page: the content moves up, which is a negative
                // wheel.
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: -Int32(points), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            })
    }
    var scroller = Scroller.system
    /// Where frames of the live screen come from, when not from the screen.
    var frameSource: ((_ selection: PixelRect) -> ShotFrameSource)?
    /// How long a scroll is given before the first look, and how far apart
    /// the looks are while the page has not held still.
    var autoSettle: TimeInterval = 0.12
    var autoLook: TimeInterval = 0.06
    private static let autoLooks = 10
    /// Bumped whenever the program's scrolling is over, so that a step
    /// still waiting for its frame knows it is not wanted.
    private var autoGeneration = 0
    /// Where the pointer was before it was put on the selection to scroll.
    private var pointerBefore: CGPoint?
    /// Where the program scrolls: the middle of the selection, in the
    /// system's global points.
    private var scrollCentre = CGPoint.zero

    /// Everything the editor holds that is not where the sharp part is.
    /// While only the selection moves this does not change, and then only
    /// the part of the display that moved is painted again.
    private struct PaintState: Equatable {
        var items: [Annotation]
        var live: Annotation?
        var selected: Int?
        var tool: AnnotationTool
        var prefs: ToolPrefs
        var textBox: ShotEditor.TextBox?
        var hoverButton: ToolbarButton?
        var hoverGrip: Annotation.Grip?
        var isLong: Bool
        var canUndo: Bool
        var canRedo: Bool
    }

    /// The text box, while one is open.
    private var typing: ShotTextScroll?
    var isTyping: Bool { typing != nil }
    /// A colour or a size was pressed while an input method was composing:
    /// what is in the box is restyled when the composition is over
    /// (`ShotTextInput.restyle`).
    private var restyleHeld = false

    /// The overlay that last had the keyboard, and the watch that gives it
    /// back (`ShotKeyHold`).
    private var keyOverlay = 0
    private var keyWatch: NSObjectProtocol?

    /// A long screenshot being taken.
    private struct Long {
        var stitcher: ShotStitcher
        var capture: ShotFrameSource
        /// Taking frames on a clock, for the person who scrolls by hand.
        /// False while the program scrolls: it takes a frame after each
        /// step.
        var ticking = false
        /// The program scrolls, and has not decided to stop. Nil when the
        /// person scrolls (`denied`) or after it has stopped.
        var auto: ShotAutoScroll?
        /// The program could not be allowed to scroll (no Accessibility
        /// permission), so it is the person who does.
        var denied = false
        /// What the last frame that said something was.
        var last: ShotStitcher.Step = .unchanged
        var frames = 0
        var lost = 0
        /// Frames held back because the screen was still changing.
        var moving = 0
    }
    private var long: Long?

    /// The mosaics as they were last painted, so that a repaint which did
    /// not change them does not compute them again.
    private struct MosaicPatch {
        var items: [Annotation]
        var display: Int
        var rect: PixelRect
        var image: CGImage
    }
    private var mosaicCache: MosaicPatch?

    /// Nil when a display's picture could not be read.
    ///
    /// `blurWait` is how long to wait here for the out-of-focus pictures;
    /// a test that paints into a bitmap waits for as long as it takes.
    init?(
        displays: [ShotDisplay], windows: [ShotWindow], prefs: ToolPrefs,
        blurWait: TimeInterval = ShotSession.blurWait, access: ShotChrome.Access? = nil
    ) {
        let space = ShotScreenSpace(displays.map {
            .init(frame: $0.frame, pixels: .init($0.image.width, $0.image.height))
        })
        var frozen: [FrozenImage] = []
        // With transparency reduced nothing is blurred: the outside is the
        // picture darkened, as it was before there was any glass (9.8.10).
        let workspace = NSWorkspace.shared
        // (`access` is given by a test that wants to see what the system's
        // settings would do without changing them.)
        let glass = access.map { !$0.opaque } ?? !(workspace.accessibilityDisplayShouldReduceTransparency
            || workspace.accessibilityDisplayShouldIncreaseContrast)
        self.access = ShotChrome.Access(opaque: !glass)
        self.still = workspace.accessibilityDisplayShouldReduceMotion
        let started = ProcessInfo.processInfo.systemUptime
        let soft = Soft()
        let making = DispatchGroup()
        for (i, display) in displays.enumerated() {
            guard let bytes = ShotRenderer.rgbx(of: display.image),
                  let picture = FrozenImage(rect: space.displays[i].rect, rgbx: bytes) else { return nil }
            frozen.append(picture)
            guard glass else { continue }
            let width = display.image.width, height = display.image.height, scale = space.displays[i].scale
            DispatchQueue.global(qos: .userInteractive).async(group: making) {
                guard let whole = ShotBlur.Picture(width: width, height: height, rgbx: bytes),
                      let prepared = ShotBlur.prepare(whole, scale: scale),
                      let image = ShotRenderer.image(of: prepared.outside) else { return }
                soft.put(i, prepared, image)
            }
        }
        let inTime = making.wait(timeout: .now() + blurWait) == .success
        let made = soft.take()
        self.prepared = displays.indices.map { made[$0]?.0 }
        self.outside = displays.indices.map { made[$0]?.1 }
        let took = (ProcessInfo.processInfo.systemUptime - started) * 1000
        Self.logger.info("screenshot: \(displays.count, privacy: .public) display(s) frozen; glass=\(glass, privacy: .public); out-of-focus pictures ready when the picture went up=\(made.count, privacy: .public) of \(glass ? displays.count : 0, privacy: .public), \(Int(took), privacy: .public) ms after the pixels were asked for")
        let motion = workspace.accessibilityDisplayShouldReduceMotion
            ? 0 : ShotLook.TransitionMs.windowSwitch / 1000
        self.fades = displays.map { _ in ShotVeil.Fade(duration: motion) }
        self.painted = displays.map { _ in [] }
        self.labelRects = displays.map { _ in [] }
        self.displays = displays
        self.space = space
        self.frozen = frozen
        self.windows = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.editor = ShotEditor(
            displays: space.displays,
            windows: space.windows(windows.map { .init(id: $0.id, frame: $0.frame) }),
            prefs: prefs)
        if glass, !inTime {
            // Not ready: the outside is darkened until they are, and then
            // every display is painted again with its glass.
            making.notify(queue: .main) { [weak self] in
                guard let self else { return }
                let made = soft.take()
                self.prepared = self.displays.indices.map { made[$0]?.0 }
                self.outside = self.displays.indices.map { made[$0]?.1 }
                let late = (ProcessInfo.processInfo.systemUptime - started) * 1000
                Self.logger.info("screenshot: the out-of-focus pictures arrived \(Int(late), privacy: .public) ms after the pixels were asked for (\(made.count, privacy: .public) of \(self.displays.count, privacy: .public)); until now the outside was only darkened")
                for overlay in self.overlays { overlay.view.needsDisplay = true }
            }
        }
    }

    // MARK: Showing and closing

    func show() {
        for (i, display) in displays.enumerated() {
            let view = ShotOverlayView(index: i, size: display.screen.frame.size)
            view.session = self
            let window = ShotOverlayWindow(display: display)
            window.contentView = view
            overlays.append((window, view))
        }
        // The overlay under the pointer takes the keyboard.
        let mouse = NSEvent.mouseLocation
        let under = overlays.first(where: { $0.window.frame.contains(mouse) }) ?? overlays.first
        pointerDisplay = overlays.firstIndex(where: { $0.window.frame.contains(mouse) })
        // The first frame is already the right one: nothing fades in when
        // the screen is frozen (9.8.7). That includes the window under the
        // pointer: it is asked of where the pointer is now, not of where it
        // was when it last moved -- until then the editor knew of no
        // pointer, and the blue frame waited for the first mouse move
        // (task 1196, 6).
        seedPointer(atCocoa: mouse)
        settleFocus()
        for overlay in overlays { overlay.window.orderFrontRegardless() }
        under?.window.makeKey()
        under?.window.makeFirstResponder(under?.view)
        if let under, let index = overlays.firstIndex(where: { $0.window === under.window }) { keyOverlay = index }
        keyWatch = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.windowBecameKey(window)
        }
    }

    /// The pointer is at `mouse`, in the system's screen coordinates
    /// (`NSEvent.mouseLocation`: points, origin at the bottom left of the
    /// primary display, y upwards): the editor is told, as though the
    /// pointer had just moved there.
    func seedPointer(atCocoa mouse: CGPoint, primaryHeight: CGFloat? = nil) {
        let height = primaryHeight ?? NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: mouse.x, y: height - mouse.y)
        guard let p = space.pixel(ofGlobal: global), let index = space.display(at: global) else { return }
        pointer = p
        pointerDisplay = index
        _ = editor.pointerMove(to: p, mods: [])
    }

    /// A window of this application became key while the picture is up: if
    /// it is one behind the picture, the keyboard goes back to the overlay
    /// (`ShotKeyHold`).
    ///
    /// The overlay is a non-activating panel, so making it key takes
    /// nothing from another application. Its first responder is still what
    /// it was -- the text box, while one is open -- because a window keeps
    /// its first responder when it stops being key.
    private func windowBecameKey(_ window: NSWindow) {
        if let index = overlays.firstIndex(where: { $0.window === window }) {
            keyOverlay = index
            return
        }
        guard overlays.indices.contains(keyOverlay) else { return }
        let overlay = overlays[keyOverlay]
        let became = ShotKeyHold.Window(level: window.level.rawValue, isModal: NSApp.modalWindow != nil)
        guard ShotKeyHold.takesBack(from: became, overlayLevel: overlay.window.level.rawValue) else { return }
        Self.logger.info("screenshot: window \(window.windowNumber, privacy: .public) became key behind the picture; the keyboard goes back to the overlay (typing=\(self.isTyping, privacy: .public))")
        overlay.window.makeKey()
        if let typing, typing.window === overlay.window, overlay.window.firstResponder !== typing.text {
            overlay.window.makeFirstResponder(typing.text)
        }
        // Whoever made that window key may not be done with it: look again
        // when they are.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overlays.indices.contains(self.keyOverlay),
                  let key = NSApp.keyWindow, !self.overlays.contains(where: { $0.window === key }) else { return }
            let again = ShotKeyHold.Window(level: key.level.rawValue, isModal: NSApp.modalWindow != nil)
            let overlay = self.overlays[self.keyOverlay]
            if ShotKeyHold.takesBack(from: again, overlayLevel: overlay.window.level.rawValue) {
                overlay.window.makeKey()
            }
        }
    }

    /// Take everything down. The frozen pictures go with this object.
    private func close() {
        endAutoScroll()
        long = nil
        frameTimer?.invalidate()
        frameTimer = nil
        caretTimer?.invalidate()
        caretTimer = nil
        // Before the overlays go: the window that becomes key when they do
        // is the one that should have the keyboard.
        if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
        keyWatch = nil
        if let typing {
            self.typing = nil
            typing.text.onCommit = nil
            typing.text.staysOpen = nil
            typing.text.onChange = nil
            typing.isToolbar = nil
            typing.removeFromSuperview()
        }
        for overlay in overlays {
            overlay.view.session = nil
            overlay.window.orderOut(nil)
            overlay.window.contentView = nil
        }
        overlays = []
    }

    /// The tool memory as it is now, to be saved for the next screenshot.
    var prefs: ToolPrefs { editor.prefs }

    /// Put every display's sharp part where the editor has it, with nothing
    /// on its way: the frame when the screen is frozen, and what a test
    /// that paints into a bitmap asks for before it looks.
    func settleFocus() {
        let now = clock()
        for i in fades.indices {
            fades[i].set(focus(on: i), at: now - 1)
            fades[i].settle(at: now)
            painted[i] = extents(on: i)
        }
    }

    /// What display `index` shows sharp, as the editor has it now.
    private func focus(on index: Int) -> ShotVeil.Focus {
        ShotVeil.focus(
            display: index, whole: space.displays[index].rect,
            selection: editor.selection.map { (display: $0.display, rect: $0.rect) },
            forming: editor.forming.map { (display: $0.display, rect: $0.rect) },
            hover: editor.hover,
            pointerDisplay: pointerDisplay)
    }

    /// The rectangles on display `index` that hold something other than
    /// the picture itself: the sharp part's edge, the selection's size, the
    /// toolbar and what hangs under it. Generous rather than exact -- a
    /// rectangle too large costs a little copying, one too small leaves
    /// last frame's toolbar on screen.
    private func extents(on index: Int) -> [PixelRect] {
        let scale = space.displays[index].scale
        func px(_ points: Double) -> Int { Int((points * scale).rounded(.up)) }
        var rects = fades[index].touched
        if let box = textBoxExtent(on: index) { rects.append(box) }
        if let plate = magnifierPlate(on: index) {
            let m = ShotChrome.margins(scale: scale)
            rects.append(PixelRect(
                left: plate.x - m.x, top: plate.y - m.top, right: plate.right + m.x, bottom: plate.bottom + m.bottom))
        }
        if let forming = editor.forming, forming.display == index {
            // The size of the region being dragged out, where it will be
            // once it is a selection.
            let r = forming.rect
            rects.append(PixelRect(left: r.x - px(8), top: r.y - px(40), right: r.x + px(260), bottom: r.y + px(40)))
        }
        if let selection = editor.selection, selection.display == index {
            // The size, above the selection or just inside its top edge.
            let r = selection.rect
            rects.append(PixelRect(left: r.x - px(8), top: r.y - px(40), right: r.x + px(260), bottom: r.y + px(40)))
            if let layout = editor.layout {
                // Both rows whether or not the second is showing, the
                // shadow around them, and room below for the hover text,
                // the missing-font line and a long screenshot's status.
                let bar = layout.bar
                let a = ShotLook.Annotation.self
                rects.append(PixelRect(
                    left: bar.x - px(a.dirtyShadowX), top: bar.y - px(a.dirtyShadowTop),
                    right: bar.right + px(a.dirtyShadowX) + px(240),
                    bottom: bar.bottom + px(ShotLook.Size.button + 2 * ShotLook.Size.padding) + px(120)))
            }
        }
        return rects
    }

    /// Something changed: paint what has to be painted again.
    ///
    /// When all that changed is where the sharp part is -- a selection
    /// being dragged out, moved or resized, the pointer going from one
    /// window to another -- that is the old and the new place of it and of
    /// what follows it around, and the rest of the display is left alone
    /// (9.8.8). Anything else paints the whole display.
    private func repaint() {
        let now = clock()
        let state = PaintState(
            items: editor.items, live: editor.live, selected: editor.selected, tool: editor.tool,
            prefs: editor.prefs, textBox: editor.textBox, hoverButton: editor.hoverButton, hoverGrip: editor.hoverGrip,
            isLong: editor.isLong,
            canUndo: editor.canUndo, canRedo: editor.canRedo)
        let onlyMoved = state == paintedState && long == nil
        paintedState = state
        headCells(at: now)
        for i in fades.indices {
            let before = painted[i]
            fades[i].settle(at: now)
            fades[i].set(focus(on: i), at: now)
            let after = extents(on: i)
            painted[i] = after
            // No overlay when a display is painted into a bitmap by a test.
            guard overlays.indices.contains(i) else { continue }
            let whole = space.displays[i].rect
            let ring = ShotStyle.px(Int(ShotLook.Annotation.dirtyRing), scale: space.displays[i].scale)
            if onlyMoved {
                if let dirty = ShotVeil.dirty(before + after, ring: ring, within: whole) {
                    overlays[i].view.setNeedsDisplay(space.local(dirty, on: i))
                }
            } else {
                overlays[i].view.needsDisplay = true
            }
        }
        runFrames()
    }

    /// What the editor knows about a toolbar button now.
    private func cellState(of button: ToolbarButton) -> ShotCell.State {
        let current = editor.current
        var state = ShotCell.State()
        switch button {
        case let .tool(t):
            state.selected = editor.tool == t && !editor.isLong
            state.enabled = !editor.isLong
        case let .colour(c):
            state.selected = c == current.colour
            state.enabled = !editor.isLong
        case let .level(l):
            state.selected = l == current.level
            state.enabled = !editor.isLong
        case .undo: state.enabled = editor.canUndo && !editor.isLong
        case .redo: state.enabled = editor.canRedo && !editor.isLong
        case .long: state.selected = editor.isLong
        case .save: break
        case .cancel: break
        case .done: state.isDone = true
        }
        state.hovered = editor.hoverButton == button
        state.pressed = pressed == button
        return state
    }

    /// Send every cell of the toolbar towards the look the editor gives it.
    private func headCells(at now: TimeInterval) {
        guard let layout = editor.layout else {
            cellFades = [:]
            return
        }
        var next: [ToolbarButton: ShotCell.Fade] = [:]
        for placed in layout.buttons {
            let look = ShotCell.look(for: cellState(of: placed.button))
            // A cell that was not there a moment ago is simply as it is.
            var fade = cellFades[placed.button] ?? ShotCell.Fade(showing: look, still: still)
            fade.head(for: look, at: now)
            next[placed.button] = fade
        }
        cellFades = next
    }

    private func anythingMoving(at now: TimeInterval) -> Bool {
        fades.contains { $0.isMoving(at: now) } || cellFades.values.contains { $0.isMoving(at: now) }
    }

    /// Keep painting while a window is coming into focus or going out of
    /// it, or a button is lighting up, and stop when nothing is on its way
    /// any more.
    private func runFrames() {
        let now = clock()
        guard !overlays.isEmpty, anythingMoving(at: now) else {
            frameTimer?.invalidate()
            frameTimer = nil
            return
        }
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func frame() {
        let now = clock()
        for (i, overlay) in overlays.enumerated() where fades.indices.contains(i) {
            let whole = space.displays[i].rect
            // Whatever is on its way: the windows changing focus, and the
            // toolbar when a cell of it is.
            var moving = fades[i].isMoving(at: now) ? fades[i].touched : []
            if cellFades.values.contains(where: { $0.isMoving(at: now) }),
               let selection = editor.selection, selection.display == i, let layout = editor.layout {
                let m = ShotChrome.margins(scale: space.displays[i].scale)
                let plate = layout.plate
                moving.append(PixelRect(
                    left: plate.x - m.x, top: plate.y - m.top, right: plate.right + m.x, bottom: plate.bottom + m.bottom))
            }
            if let dirty = ShotVeil.dirty(moving, ring: 0, within: whole) {
                overlay.view.setNeedsDisplay(space.local(dirty, on: i))
            }
            fades[i].settle(at: now)
        }
        if !anythingMoving(at: now) {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    // MARK: The magnifier

    /// The pointer's pixel on display `index` while the magnifier is up
    /// there.
    private func magnifierPointer(on index: Int) -> PixelPoint? {
        guard editor.showsMagnifier, pointerDisplay == index, let pointer,
              space.displays.indices.contains(index), space.displays[index].rect.contains(pointer) else { return nil }
        return pointer
    }

    /// Where the magnifier's plate is on display `index` now, nil when it is
    /// not up.
    func magnifierPlate(on index: Int) -> PixelRect? {
        guard let p = magnifierPointer(on: index) else { return nil }
        let scale = space.displays[index].scale
        let font = ShotRenderer.uiFont(scale: scale)
        let m = ShotMagnifier.Metrics(
            scale: scale, textHeight: Int((CTFontGetAscent(font) + CTFontGetDescent(font)).rounded(.up)))
        return ShotMagnifier.place(
            pointer: p, plate: (m.plateWidth, m.plateHeight),
            offset: ShotStyle.px(Int(ShotLook.Size.magnifierOffset), scale: scale), display: space.displays[index].rect)
    }

    /// Cmd+C while the magnifier is up: the colour of the pixel under the
    /// pointer, as `#RRGGBB`, onto the clipboard. The screenshot goes on.
    /// Returns whether there was anything to copy.
    @discardableResult
    func copyColour(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let index = pointerDisplay, let p = magnifierPointer(on: index),
              let colour = frozen[index].colour(at: p) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(ShotMagnifier.hex(colour), forType: .string)
        Self.logger.info("screenshot: the colour \(ShotMagnifier.hex(colour), privacy: .public) was copied")
        let flash = ShotLook.TransitionMs.copiedFlash / 1000
        copiedUntil = clock() + flash
        repaint()
        // Back to the colour's text when the flash is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + flash) { [weak self] in
            guard let self, !self.overlays.isEmpty else { return }
            self.repaint()
        }
        return true
    }

    // MARK: From the views

    func pointerDown(at local: CGPoint, on index: Int, mods: ShotMods, double: Bool) {
        guard displays.indices.contains(index) else { return }
        if overlays.indices.contains(index) {
            let window = overlays[index].window
            if !window.isKeyWindow, typing == nil {
                window.makeKey()
                window.makeFirstResponder(overlays[index].view)
            }
        }
        pointerDisplay = index
        let p = space.pixel(ofLocal: local, on: index)
        pointer = p
        // The button the press is on shows it for as long as it is held
        // (9.8.4). Looked up before the editor acts: a press may be the one
        // that takes the toolbar away.
        if let button = editor.layout?.button(at: p), cellState(of: button).enabled {
            pressed = button
            if button == .cancel || button == .done || button == .save {
                // These two end the screenshot, so they act when the button
                // is let go, over the same button: pressed, they show it
                // (9.8.4), and a press that slides off them is taken back.
                held = (button, p, mods)
                repaint()
                return
            }
        }
        let effect = double
            ? editor.doubleClick(at: p, mods: mods, measure: measure)
            : editor.pointerDown(at: p, mods: mods, measure: measure)
        perform(effect)
    }

    func pointerMove(to local: CGPoint, on index: Int, mods: ShotMods) {
        let p = space.pixel(ofLocal: local, on: index)
        pointer = p
        lastMods = mods
        if pointerDisplay != index {
            // Onto another display: with no window under the pointer the
            // editor has nothing to say, and the display is all sharp.
            pointerDisplay = index
            repaint()
        }
        let effect = editor.pointerMove(to: p, mods: mods)
        perform(effect)
        // The magnifier follows the pointer whether or not the editor has
        // anything to say about the move.
        if effect == .none, editor.showsMagnifier { repaint() }
        cursor(at: local, on: index).set()
    }

    func pointerUp(at local: CGPoint, on index: Int) {
        let was = pressed
        pressed = nil
        if let held {
            self.held = nil
            if editor.layout?.button(at: space.pixel(ofLocal: local, on: index)) == held.button {
                // Now it is pressed, as far as the editor is concerned.
                perform(editor.pointerDown(at: held.at, mods: held.mods, measure: measure))
            } else {
                repaint()
                return
            }
        }
        perform(editor.pointerUp(at: space.pixel(ofLocal: local, on: index)))
        // Letting go of a button is something to paint even when the
        // editor has nothing to say about it.
        if was != nil { repaint() }
    }

    func rightClick(on index: Int) {
        perform(editor.rightClick())
    }

    func key(_ event: NSEvent, on index: Int) {
        key(
            EditorKey.Input.of(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers),
            mods: ShotMods(event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }

    /// A key, as the editor reads keys: what the keyboard path does once
    /// the event has been read, and what a test calls.
    func key(_ input: EditorKey.Input, mods: ShotMods) {
        if ShotMagnifier.isCopyKey(input, mods: mods), copyColour() { return }
        let before = editor.items.count
        let (key, effect) = editor.key(input, mods: mods, measure: measure)
        Self.logger.debug("screenshot: key \(String(describing: input), privacy: .public) mods=\(mods.rawValue, privacy: .public) annotations=\(before, privacy: .public) -> \(String(describing: key), privacy: .public)")
        perform(effect)
    }

    /// The pointer at a point of a display (9.8.11A.4): an arrow over the
    /// toolbar and the labels, what the editor says everywhere else.
    func cursor(at local: CGPoint, on index: Int) -> NSCursor {
        let p = space.pixel(ofLocal: local, on: index)
        if labelRects.indices.contains(index), labelRects[index].contains(where: { $0.contains(p) }) { return .arrow }
        switch editor.cursor(at: p, mods: lastMods) {
        case .tool: return .crosshair
        case .arrow: return .arrow
        case .move: return editor.isMovingItem || editor.isMovingToolbar ? .closedHand : .openHand
        case .upDown: return .resizeUpDown
        case .leftRight: return .resizeLeftRight
        case .diagonal: return Self.diagonal(northWest: true)
        case .antiDiagonal: return Self.diagonal(northWest: false)
        }
    }

    /// The pointer for dragging a corner. The system has had one that is
    /// public since macOS 15; before that there is none, and the cross
    /// stands in.
    private static func diagonal(northWest: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            return .frameResize(position: northWest ? .topLeft : .topRight, directions: .all)
        }
        return .crosshair
    }

    /// Do what the editor asked for.
    private func perform(_ effect: ShotEditor.Effect) {
        switch effect {
        case .none:
            break
        case .repaint, .capture, .release:
            // AppKit keeps sending a drag to the view it started in, so
            // there is no capture to take or give back.
            repaint()
        case .cancel:
            cancel()
        case .finish:
            finish()
        case .save:
            finish(saveCopy: true)
        case .long:
            startLong()
        case .leaveLong:
            stopLong()
        case .openText:
            openText()
        case .restyleText:
            restyleText()
        case .commitText:
            commitText()
        }
    }

    private func cancel() {
        close()
        delegate?.sessionDidCancel(self)
    }

    // MARK: The text box

    /// The text box as it is now, for a test that paints it.
    var textBoxView: ShotTextScroll? { typing }

    /// Give the box the colour and size of `box`. `reach` is how much of it:
    /// while an input method is composing, only what will be typed and the
    /// box itself -- the text that is there is the input method's
    /// (`ShotTextInput.restyle`).
    private func style(
        _ typing: ShotTextScroll, as box: ShotEditor.TextBox, scale: Double, reach: ShotTextInput.Restyle
    ) {
        let view = typing.text
        let fontPx = ShotStyle.fontPx(level: box.level, scale: scale)
        let font = ShotFont.font(size: CGFloat(fontPx) / CGFloat(scale)) as NSFont
        let ink = NSColor(cgColor: ShotRenderer.colour(ShotStyle.colour(box.colour))) ?? .red
        if reach == .everything {
            view.font = font
            view.textColor = ink
            // The halo, the caret's edge, how a selection and a composition
            // show: all from the ink. Left alone while an input method is
            // composing, like the text itself.
            view.ink = ShotStyle.colour(box.colour)
        }
        view.typingAttributes = [.font: font, .foregroundColor: ink]
        if reach == .everything, let storage = view.textStorage, storage.length > 0 {
            storage.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// Open a text view for the text the editor is about to take.
    private func openText() {
        guard let box = editor.textBox, let selection = editor.selection,
              displays.indices.contains(selection.display) else {
            // The editor has a box the host cannot show: end it, empty.
            perform(editor.endText("", measure: measure))
            return
        }
        let index = selection.display
        let scale = editor.scale
        // As tall as what is in it and inside the selection (`ShotTextBox`).
        // It was `fontPx * 4` whatever was typed, stopped only by the
        // display: at the largest size, low in the selection, it lay over
        // the toolbar (task 1104).
        guard let rect = editor.textRect(lines: ShotTextBox.lines(in: box.text), text: box.text, measure: measure) else {
            perform(editor.endText("", measure: measure))
            return
        }

        let typing = ShotTextScroll(box: space.local(rect, on: index))
        let view = typing.text
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.focusRingType = .none
        restyleHeld = false
        style(typing, as: box, scale: scale, reach: .everything)
        view.string = box.text
        // The caret after what is already there.
        view.setSelectedRange(NSRange(location: (box.text as NSString).length, length: 0))
        view.onCommit = { [weak self] in self?.commitText() }
        view.staysOpen = { [weak self] in self?.pressRestylesText() ?? false }
        view.onChange = { [weak self] in self?.textChanged() }
        typing.isToolbar = { [weak self] point in
            guard let self else { return false }
            return ShotTextBox.onToolbar(self.space.pixel(ofLocal: point, on: index), keepClear: self.editor.textKeepClear)
        }

        self.typing = typing
        // (No overlay when a display is painted into a bitmap by a test:
        // the box is then a view with no window, which is enough to lay
        // out and to draw.)
        if overlays.indices.contains(index) {
            let overlay = overlays[index]
            overlay.view.addSubview(typing)
            overlay.window.makeKey()
            overlay.window.makeFirstResponder(view)
        }
        showCaret()
        // A text opened again may have more lines than the box has room
        // for, or have wrapped: place it for what it holds.
        fitText()
        repaint()
    }

    /// Whether the event being delivered is a press the editor answers by
    /// changing the text being typed (a colour, a size).
    ///
    /// AppKit makes the view that was clicked the first responder *before*
    /// it sends it the press, so the text view is asked to give up the
    /// keyboard first. Ending the text there meant the press found no box:
    /// the piece kept its old colour and only the tool's memory changed
    /// (task 1098). `restyleText` gives the keyboard back.
    func pressRestylesText() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let index = overlays.firstIndex(where: { $0.window === event.window }) else { return false }
        let local = overlays[index].view.convert(event.locationInWindow, from: nil)
        return editor.restylesText(at: space.pixel(ofLocal: local, on: index))
    }

    /// The text's colour or size changed while it is being typed: the box
    /// follows, so that what is seen while typing is what will be drawn.
    private func restyleText() {
        guard let typing, let box = editor.textBox else { return }
        // With a composition open, what is in the box is left alone and
        // restyled when the composition is over (`textChanged`).
        let reach = ShotTextInput.restyle(composing: typing.text.hasMarkedText())
        restyleHeld = reach == .typingOnly
        style(typing, as: box, scale: editor.scale, reach: reach)
        typing.window?.makeFirstResponder(typing.text)
        // Another size is another line height, and for a new text possibly
        // another place (`ShotEditor.setLevel`).
        fitText()
        repaint()
    }

    /// What is typed, or where the caret is, changed. Never called from
    /// inside one of the input method's calls (`ShotTextInput.Gate`).
    private func textChanged() {
        if let typing, let box = editor.textBox,
           ShotTextInput.restyleDue(held: restyleHeld, composing: typing.text.hasMarkedText()) {
            restyleHeld = false
            style(typing, as: box, scale: editor.scale, reach: .everything)
        }
        fitText()
        // The frame and the caret are the overlay's to draw, and both go
        // where the text goes. A caret that has just moved is showing.
        showCaret()
        repaint()
    }

    // MARK: The caret

    /// How long the caret shows and how long it does not, in seconds: the
    /// system's, as every text field on the machine blinks.
    private static var blink: (on: TimeInterval, off: TimeInterval) {
        let defaults = UserDefaults.standard
        func period(_ key: String) -> TimeInterval {
            let ms = defaults.double(forKey: key)
            return ms > 0 ? ms / 1000 : 0.56
        }
        return (period("NSTextInsertionPointBlinkPeriodOn"), period("NSTextInsertionPointBlinkPeriodOff"))
    }

    /// Show the caret now and start it blinking from here.
    private func showCaret() {
        caretTimer?.invalidate()
        caretTimer = nil
        caretOn = true
        guard typing != nil, !overlays.isEmpty else { return }
        scheduleCaret()
    }

    private func scheduleCaret() {
        let blink = Self.blink
        let timer = Timer(timeInterval: caretOn ? blink.on : blink.off, repeats: false) { [weak self] _ in
            guard let self, self.typing != nil else { return }
            self.caretOn.toggle()
            self.paintTextBox()
            self.scheduleCaret()
        }
        RunLoop.main.add(timer, forMode: .common)
        caretTimer = timer
    }

    /// The text box and what the overlay draws around it, in the editor's
    /// pixels: its frame, grown by the dashed line and the caret's edge.
    private func textBoxExtent(on index: Int) -> PixelRect? {
        guard let typing, let selection = editor.selection, selection.display == index else { return nil }
        let scale = space.displays[index].scale
        let a = space.pixel(ofLocal: typing.frame.origin, on: index)
        let b = space.pixel(ofLocal: CGPoint(x: typing.frame.maxX, y: typing.frame.maxY), on: index)
        let ring = Int(((ShotLook.TextBox.offset + ShotLook.TextBox.line + 2) * scale).rounded(.up))
        return PixelRect(left: a.x - ring, top: a.y - ring, right: b.x + ring, bottom: b.y + ring)
    }

    /// Paint the text box's part of its display again.
    private func paintTextBox() {
        guard let selection = editor.selection, overlays.indices.contains(selection.display),
              let extent = textBoxExtent(on: selection.display) else { return }
        overlays[selection.display].view.setNeedsDisplay(space.local(extent, on: selection.display))
    }

    /// Put the box where `ShotEditor.textRect` says it goes for what is in
    /// it now: a line taller for each line, never past the selection's
    /// bottom edge. Past that the text scrolls in the box, so that the line
    /// the caret is on is the one in view (`ShotTextScroll.place`). Geometry
    /// only, so it is safe while an input method is composing.
    private func fitText() {
        guard let typing, let selection = editor.selection else { return }
        // The box's width follows what is in it, and how many lines the
        // text wraps to follows the box's width: place it for the lines
        // there are without wrapping, look again, and place it for those.
        // Settled in one or two turns -- the width only stops following the
        // text at the selection's edge, and that is where a line wraps.
        var lines = ShotTextBox.lines(in: typing.text.string)
        for _ in 0..<4 {
            guard let rect = editor.textRect(lines: lines, text: typing.text.string, measure: measure) else { return }
            typing.place(space.local(rect, on: selection.display))
            let laid = typing.text.laidOutLines
            if laid == lines { break }
            lines = laid
        }
    }

    /// Close the text box and hand what was typed to the editor, which
    /// decides what it becomes (nothing, if nothing was typed).
    ///
    /// **Called again from inside itself**: taking the view away makes it
    /// give up the keyboard, and giving up the keyboard commits. So the view
    /// is taken out of `typing` and the text is given to the editor
    /// *before* the view is touched. The second call then finds no view and
    /// an editor with no box, and `endText` with no box does nothing --
    /// rather than ending the text with an empty string, which is how the
    /// other host once lost everything typed.
    private func commitText() {
        guard let typing else {
            // No view. If the editor still has a box, it is one that failed
            // to open; with none this is the second call, and nothing.
            if editor.textBox != nil { perform(editor.endText("", measure: measure)) }
            return
        }
        self.typing = nil
        restyleHeld = false
        caretTimer?.invalidate()
        caretTimer = nil
        let view = typing.text
        view.onCommit = nil
        view.staysOpen = nil
        view.onChange = nil
        typing.isToolbar = nil
        let effect = editor.endText(view.string, measure: measure)
        let window = typing.window
        let owner = typing.superview
        typing.removeFromSuperview()
        if let window, let owner { window.makeFirstResponder(owner) }
        perform(effect)
        repaint()
    }

    // MARK: Long screenshots

    /// Enter long-screenshot mode (the editor already has): open the
    /// selection to the live screen and start taking frames.
    ///
    /// The overlay is drawn with a hole where the selection is. What is
    /// under the hole shows -- the live page -- and the mouse over the hole
    /// is not this window's at all, so the wheel scrolls the application
    /// underneath with nothing forwarded and nothing to get wrong. The
    /// frames are taken with the overlays left out, so a toolbar that had
    /// to sit inside a selection as tall as the display is not in them.
    private func startLong() {
        guard let selection = editor.selection, displays.indices.contains(selection.display),
              let stitcher = ShotStitcher(width: selection.rect.w, height: selection.rect.h) else {
            Self.logger.error("screenshot: a long screenshot could not be started")
            return
        }
        let capture: ShotFrameSource
        if let frameSource {
            capture = frameSource(selection.rect)
        } else if let displayID = ShotCapture.displayID(of: displays[selection.display].screen) {
            capture = ShotLiveCapture(
                displayID: displayID,
                region: space.local(selection.rect, on: selection.display),
                pixels: .init(selection.rect.w, selection.rect.h),
                overlayNumbers: overlays.map(\.window.windowNumber))
        } else {
            Self.logger.error("screenshot: a long screenshot could not be started")
            return
        }
        var taking = Long(stitcher: stitcher, capture: capture)
        if scroller.trusted() {
            // The program scrolls to the bottom, a step at a time.
            taking.auto = ShotAutoScroll()
            long = taking
            Self.logger.info("screenshot: long screenshot started, frames of \(selection.rect.w, privacy: .public)x\(selection.rect.h, privacy: .public); the program scrolls")
            beginAutoScroll(selection)
        } else {
            // No permission to turn the wheel: the person does, as before,
            // and frames are taken on a clock.
            taking.denied = true
            taking.ticking = true
            long = taking
            scheduleTick(generation: autoGeneration)
            Self.logger.info("screenshot: long screenshot started, frames of \(selection.rect.w, privacy: .public)x\(selection.rect.h, privacy: .public) every \(Int(Self.longInterval * 1000), privacy: .public) ms; the person scrolls (no Accessibility permission)")
        }
        repaint()
    }

    /// Leave long-screenshot mode without finishing: cover the selection
    /// again.
    private func stopLong() {
        guard let long else { return }
        endAutoScroll()
        self.long = nil
        Self.logger.info("screenshot: long screenshot left without finishing: \(long.frames, privacy: .public) frame(s), \(long.lost, privacy: .public) dropped, \(long.stitcher.totalHeight, privacy: .public) px discarded")
        repaint()
    }

    /// Put the pointer on the middle of the selection -- where the wheel
    /// goes -- and take the first frame; the scrolling starts from it.
    private func beginAutoScroll(_ selection: ShotEditor.Selection) {
        let display = displays[selection.display]
        let region = space.local(selection.rect, on: selection.display)
        scrollCentre = CGPoint(x: display.frame.minX + region.midX, y: display.frame.minY + region.midY)
        pointerBefore = scroller.pointer()
        scroller.park(scrollCentre)
        let generation = autoGeneration
        steadyFrame(generation: generation) { [weak self] first in
            guard let self, generation == self.autoGeneration else { return }
            guard first == .first else {
                // A region that never holds still (a video, a spinner) is
                // not scrolled: nothing could be joined to it. The first
                // frame it gave is the picture.
                self.autoStopped(.lost)
                return
            }
            self.autoStep(generation: generation)
        }
    }

    /// One step: scroll, give the page a moment, take a frame, decide.
    private func autoStep(generation: Int) {
        guard generation == autoGeneration, let taking = long, taking.auto != nil,
              let selection = editor.selection else { return }
        let display = space.displays[selection.display]
        // Back on the selection each time: the wheel goes to whatever is
        // under the pointer, and the person may have moved it.
        scroller.park(scrollCentre)
        scroller.wheel(ShotAutoScroll.step(height: selection.rect.h, scale: display.scale))
        DispatchQueue.main.asyncAfter(deadline: .now() + autoSettle) { [weak self] in
            guard let self, generation == self.autoGeneration else { return }
            self.steadyFrame(generation: generation) { step in
                guard generation == self.autoGeneration, var taking = self.long, var auto = taking.auto else { return }
                let stop = auto.record(step, full: taking.stitcher.isFull)
                taking.auto = auto
                self.long = taking
                // The height so far, in the status line.
                self.repaint()
                if let stop {
                    self.autoStopped(stop)
                } else {
                    self.autoStep(generation: generation)
                }
            }
        }
    }

    /// Take frames until one is the same as the one before it, and say what
    /// joining it did. A region still moving after every look is `.lost`:
    /// nothing could be joined. The frame goes to the stitcher, and the
    /// counts the status line and the log show are kept.
    private func steadyFrame(generation: Int, looks: Int = 0, then: @escaping (ShotStitcher.Step) -> Void) {
        guard let capture = long?.capture else { return }
        capture.frame { [weak self] frame in
            guard let self, generation == self.autoGeneration, var taking = self.long else { return }
            guard let frame else {
                then(.lost)
                return
            }
            let step = taking.stitcher.offer(frame)
            taking.frames += 1
            if step == .lost { taking.lost += 1 }
            if step == .moving { taking.moving += 1 }
            taking.last = step == .unchanged || step == .moving ? taking.last : step
            self.long = taking
            guard step == .moving else {
                then(step)
                return
            }
            guard looks + 1 < Self.autoLooks else {
                then(.lost)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.autoLook) {
                self.steadyFrame(generation: generation, looks: looks + 1, then: then)
            }
        }
    }

    /// The program has scrolled as far as it will: the bottom, the height
    /// limit, or a page it cannot follow. The picture is what was joined.
    private func autoStopped(_ stop: ShotAutoScroll.Stop) {
        let height = long?.stitcher.totalHeight ?? 0
        Self.logger.info("screenshot: automatic scrolling stopped at \(String(describing: stop), privacy: .public), \(height, privacy: .public) px joined")
        if stop == .lost {
            ShotToast.show(ShotWords.translate("The page could not be followed any further, so the picture ends here."))
        }
        finish()
    }

    /// The program's scrolling is over, or never was: nothing still waiting
    /// for a frame is wanted, and the pointer goes back where it was.
    private func endAutoScroll() {
        autoGeneration += 1
        if let pointerBefore {
            scroller.park(pointerBefore)
            self.pointerBefore = nil
        }
        if long?.auto != nil { long?.auto = nil }
    }

    /// Take a frame every `longInterval` while the person scrolls. Stopped by
    /// `endAutoScroll` (every way out of the mode goes through it), which
    /// bumps the generation.
    private func scheduleTick(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longInterval) { [weak self] in
            guard let self, generation == self.autoGeneration, self.long?.ticking == true else { return }
            self.longTick()
            self.scheduleTick(generation: generation)
        }
    }

    /// Take one frame of the selection as it is on the live screen and hand
    /// it to the stitcher: the person is scrolling.
    private func longTick() {
        guard let capture = long?.capture else { return }
        capture.frame { [weak self] frame in
            guard let self, let frame, var long = self.long else { return }
            // Only a frame seen twice running is joined: one caught half
            // painted is `.moving` and waits for the next.
            let step = long.stitcher.offer(frame)
            long.frames += 1
            if step == .lost { long.lost += 1 }
            if step == .moving { long.moving += 1 }
            // What the hint shows follows the last frame that said
            // something: a frame that is unchanged, or still moving, does
            // not clear "scroll slower".
            let shown = step == .unchanged || step == .moving ? long.last : step
            var changed = shown != long.last
            if case .added = step { changed = true }
            // The status line also changes on the frame that makes it say
            // the region keeps changing.
            if step == .moving, long.moving == ShotStitcher.restlessAfter, long.stitcher.isRestless(held: long.moving) {
                changed = true
            }
            if step == .full && long.last != .full {
                Self.logger.info("screenshot: long screenshot reached the \(ShotStitcher.maxHeight, privacy: .public) px limit; no more is added")
                long.ticking = false
            }
            long.last = shown
            self.long = long
            if changed { self.repaint() }
        }
    }

    // MARK: Finishing

    /// Done: compose the image and hand it over.
    private func finish(saveCopy: Bool = false) {
        commitText()
        guard let export = editor.export(), frozen.indices.contains(export.selection.display) else { return }
        let taken = long
        long = nil
        if let taken {
            Self.logger.info("screenshot: long screenshot finished: \(taken.frames, privacy: .public) frame(s), \(taken.lost, privacy: .public) dropped for want of overlap, \(taken.moving, privacy: .public) held back (still moving), \(taken.stitcher.totalHeight, privacy: .public) px tall")
            if taken.stitcher.neverSteady {
                Self.logger.info("screenshot: long screenshot: the region never held still for two frames in a row, so nothing was joined; the picture is the first frame taken, \(taken.stitcher.height, privacy: .public) px tall")
            }
        }
        close()

        let index = export.selection.display
        let image: ComposedImage?
        if let taken {
            // Stitched frames carry no annotations and need no composing.
            image = taken.stitcher.finish().flatMap { ComposedImage(width: $0.width, rgbx: $0.rgbx) }
        } else {
            image = ShotRenderer.compose(
                frozen: frozen[index], selection: export.selection.rect, items: export.onScreen, scale: export.scale)
        }
        guard let image else {
            Self.logger.error("screenshot: the selection could not be composed; nothing written")
            delegate?.sessionDidCancel(self)
            return
        }

        let window = export.selection.window.flatMap { windows[$0] }
        let display = space.displays[index].rect
        delegate?.sessionDidFinish(self, with: Result(
            image: image,
            items: taken == nil ? export.onImage : [],
            isLong: taken != nil,
            scale: export.scale,
            display: index,
            displaySize: .init(display.w, display.h),
            selection: space.displayLocal(export.selection.rect, on: index),
            window: window,
            // The window's own bounds, not the part of it on the screen:
            // that part is `selection`. An agent's capture of the same
            // window records the same rectangle (11).
            windowRect: window
                .flatMap { space.wholePixels(ofGlobal: $0.frame, on: index) }
                .map { space.displayLocal($0, on: index) },
            saveCopy: saveCopy))
    }

    // MARK: Drawing

    /// The mosaics on display `index` as a patch of picture, computed from
    /// the frozen original -- including the one being dragged out, so its
    /// size is chosen by what it hides.
    private func mosaics(on index: Int, scale: Double) -> (rect: PixelRect, image: CGImage)? {
        func isMosaic(_ item: Annotation) -> Bool {
            if case .mosaic = item.shape { return true }
            return false
        }
        let items = (editor.items + (editor.live.map { [$0] } ?? [])).filter(isMosaic)
        guard !items.isEmpty else {
            mosaicCache = nil
            return nil
        }
        if let cache = mosaicCache, cache.items == items, cache.display == index { return (cache.rect, cache.image) }

        let display = space.displays[index].rect
        var union: PixelRect?
        for item in items {
            guard let part = item.bounds(scale: scale).intersect(display) else { continue }
            union = union.map {
                PixelRect(
                    left: min($0.x, part.x), top: min($0.y, part.y),
                    right: max($0.right, part.right), bottom: max($0.bottom, part.bottom))
            } ?? part
        }
        guard let rect = union,
              let composed = ComposedImage(
                frozen: frozen[index], selection: rect, items: items, scale: scale, redact: []),
              let image = composed.cgImage() else { return nil }
        mosaicCache = MosaicPatch(items: items, display: index, rect: composed.rect, image: image)
        return (composed.rect, image)
    }

    /// Paint display `index`. `ctx` is the view's: points, from the top
    /// left.
    func draw(display index: Int, in ctx: CGContext) {
        guard displays.indices.contains(index) else { return }
        let display = space.displays[index]
        let whole = display.rect
        let scale = display.scale
        func cg(_ r: PixelRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        // From here one unit is one pixel, in the editor's coordinates.
        ctx.scaleBy(x: 1 / CGFloat(scale), y: 1 / CGFloat(scale))
        ctx.translateBy(x: -CGFloat(whole.x), y: -CGFloat(whole.y))

        // What is in focus on this display: the selection, the region being
        // dragged, or the window under the pointer -- or all of it, when the
        // pointer is here and over no window. The rest is out of focus.
        let selection = editor.selection.flatMap { $0.display == index ? $0.rect : nil }
        let forming = editor.forming.flatMap { $0.display == index ? $0.rect : nil }
        let hover = editor.selection == nil && editor.forming == nil
            ? editor.hover.flatMap { $0.display == index ? $0.rect : nil } : nil
        let focus = selection ?? forming ?? hover
        let hole = long != nil ? selection : nil
        let now = clock()
        let layers = fades.indices.contains(index) ? fades[index].layers(at: now) : []

        if let soft = outside.indices.contains(index) ? outside[index] : nil {
            // The picture out of focus, and the sharp picture over it
            // wherever it shows. Nothing is blurred here: both pictures were
            // made when the screen was frozen (9.8.8).
            ShotRenderer.draw(soft, in: cg(whole), of: ctx)
            for layer in layers {
                ctx.saveGState()
                ctx.clip(to: cg(layer.rect))
                ctx.setAlpha(CGFloat(layer.alpha))
                ShotRenderer.draw(displays[index].image, in: cg(whole), of: ctx)
                ctx.restoreGState()
            }
            if let selection, let patch = mosaics(on: index, scale: scale) {
                ctx.saveGState()
                ctx.clip(to: cg(selection))
                ShotRenderer.draw(patch.image, in: cg(patch.rect), of: ctx)
                ctx.restoreGState()
            }
        } else {
            // Transparency reduced: the picture, darkened outside the focus.
            ShotRenderer.draw(displays[index].image, in: cg(whole), of: ctx)
            if selection != nil, let patch = mosaics(on: index, scale: scale) {
                ShotRenderer.draw(patch.image, in: cg(patch.rect), of: ctx)
            }
            ctx.saveGState()
            ctx.addRect(cg(whole))
            for layer in layers where layer.alpha >= 1 { ctx.addRect(cg(layer.rect)) }
            ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(ShotLook.Colour.outsideDimOpaque.a)))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        if let selection {
            func isMosaic(_ item: Annotation) -> Bool {
                if case .mosaic = item.shape { return true }
                return false
            }
            var drawn = editor.drawOrder.filter { !isMosaic($0.item) }
            if let live = editor.live, !isMosaic(live) { drawn.append((index: Int.max, item: live)) }
            func annotations() {
                ShotRenderer.draw(
                    drawn, in: ctx, scale: scale, hideTextOf: editor.textBox?.editing,
                    highlighter: ShotRenderer.blendedHighlighter(in: ctx))
            }
            // Inside the selection as they will be in the picture. What
            // reaches outside it is cut off when the picture is made, and is
            // drawn faint to say so (9.8.11A.5): still there to be seen and
            // carried back, not part of what leaves.
            ctx.saveGState()
            ctx.clip(to: cg(selection))
            annotations()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addRect(cg(whole))
            ctx.addRect(cg(selection))
            ctx.clip(using: .evenOdd)
            ctx.setAlpha(CGFloat(ShotLook.Annotation.outsideOpacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            annotations()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // A long screenshot: the selection is the live screen.
        if let hole {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(cg(hole))
            ctx.restoreGState()
        }

        let accent = ShotRenderer.ink(ShotLook.Colour.accent)
        if let selection {
            // The selection's edge: a line just outside it.
            let line = ShotStyle.px(Int(ShotLook.Size.selectionLine), scale: scale)
            ShotRenderer.frame(
                PixelRect(selection.x - line, selection.y - line, selection.w + 2 * line, selection.h + 2 * line),
                accent, thickness: line, in: ctx)
        } else if let focus {
            // The window that a click would take, or the region being
            // dragged out.
            let line = ShotStyle.px(Int(forming != nil ? ShotLook.Size.selectionLine : ShotLook.Size.windowLine), scale: scale)
            ShotRenderer.frame(focus, accent, thickness: line, in: ctx)
        }
        // The size of what is being dragged out is shown while it is
        // dragged, not only after the button comes up (task 1196, 8).
        if labelRects.indices.contains(index) { labelRects[index] = [] }

        // Everything from here on is glass, cut from this display's picture.
        let glass = (prepared.indices.contains(index) ? prepared[index] : nil).map {
            ShotChrome.Glass(prepared: $0, origin: whole.origin, scale: scale)
        }
        let surface = ShotChrome.Surface(scale: scale, glass: glass, access: access)
        // The magnifier is the last thing painted, over everything, whichever
        // way this function leaves (declared before the others, so run after
        // them: with the clip they set gone).
        defer {
            if let p = magnifierPointer(on: index), frozen.indices.contains(index) {
                ShotRenderer.drawMagnifier(
                    frozen: frozen[index], pointer: p, copied: now < copiedUntil, display: whole, on: surface, in: ctx)
            }
        }
        guard let sized = selection ?? forming else { return }
        var labels: [PixelRect] = []
        defer { if labelRects.indices.contains(index) { labelRects[index] = labels } }
        if selection == nil {
            ctx.saveGState()
            ctx.addRect(cg(whole))
            ctx.addRect(cg(sized))
            ctx.clip(using: .evenOdd)
            labels.append(drawSizeLabel(of: sized, whole: whole, surface: surface, in: ctx))
            ctx.restoreGState()
            return
        }
        guard let selection else { return }

        if long == nil {
            if let marked = editor.marked {
                // The selected annotation: a dashed frame round what can be
                // framed, square grips on what can be reshaped. Over every
                // annotation, whichever of them it is.
                if marked.framed { ShotRenderer.drawFrame(round: marked.ink, on: surface, in: ctx) }
                for grip in marked.grips { ShotRenderer.drawGrip(at: grip.at, look: grip.look, on: surface, in: ctx) }
                if let tag = editor.reshapeTag, let pointer, whole.contains(pointer) {
                    // What it measures now, beside the pointer.
                    let off = ShotStyle.px(Int(ShotLook.Annotation.tagOffset), scale: scale)
                    labels.append(ShotRenderer.label(
                        [.words(tag)], style: .size, at: PixelPoint(pointer.x + off, pointer.y + off), within: whole,
                        on: surface, in: ctx))
                }
            } else if editor.knobs {
                // Otherwise the selection's own handles, round, while the
                // select tool is what the mouse is. The two kinds are never
                // on screen together.
                for handle in PixelHandle.all { ShotRenderer.drawKnob(at: handle.at(selection), scale: scale, in: ctx) }
            }
        }

        drawTextBox(on: index, in: ctx)

        // Everything from here is furniture beside the selection, and its
        // shadows stop at the selection's edge: what is inside is the
        // picture and nothing else, down to the pixel. (Furniture that has
        // nowhere to go but inside -- the toolbar of a selection as tall as
        // the display -- is drawn whole, below.)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addRect(cg(whole))
        ctx.addRect(cg(selection))
        ctx.clip(using: .evenOdd)

        labels.append(drawSizeLabel(of: selection, whole: whole, surface: surface, in: ctx))

        guard let layout = editor.layout else { return }
        if layout.plate.intersect(selection) != nil {
            // Inside the selection: there was no room beside it. Back to
            // the clip the furniture's own was put on top of.
            ctx.restoreGState()
            ctx.saveGState()
        }
        drawToolbar(layout, on: index, surface: surface, at: now, in: ctx)

        // Under the toolbar, one below another: the line that says the font
        // is missing, the hover text, a long screenshot's status.
        let gap = ShotStyle.px(Int(ShotLook.Size.tipOffset), scale: scale)
        var below = layout.plate.bottom + gap
        if !ShotFont.isAvailable {
            let words = ShotWords.translate("The annotation font is missing, so the system font is used.")
            let plate = ShotRenderer.label(
                [.words(words)], style: .tip, at: PixelPoint(layout.plate.x, below), within: whole,
                on: surface, in: ctx)
            labels.append(plate)
            below = plate.bottom + gap
        }
        if let button = editor.hoverButton, let r = layout.rect(of: button), cellState(of: button).enabled {
            var parts: [ShotRenderer.LabelPart] = [
                .words(ShotWords.translate(ShotToolbarGrid.name(of: button, props: editor.props))),
            ]
            if let key = ShotToolbarGrid.shortcut(of: button) { parts.append(.key(key)) }
            let plate = ShotRenderer.label(
                parts, style: .tip, at: PixelPoint(r.x, below), within: whole, on: surface, in: ctx)
            labels.append(plate)
            below = plate.bottom + gap
        }
        if let long {
            labels.append(drawLongStatus(
                long, at: PixelPoint(layout.plate.x, below), selection: selection, display: whole,
                surface: surface, in: ctx))
        }
    }

    /// The size of a selection, or of a region being dragged out, in pixels
    /// of the image: above its top left corner, or just inside it when there
    /// is no room above.
    private func drawSizeLabel(
        of selection: PixelRect, whole: PixelRect, surface: ShotChrome.Surface, in ctx: CGContext
    ) -> PixelRect {
        let scale = surface.scale
        let parts: [ShotRenderer.LabelPart] = [.words("\(selection.w) × \(selection.h)")]
        let label = ShotRenderer.labelSize(parts, style: .size, scale: scale)
        let offset = ShotStyle.px(Int(ShotLook.Size.sizeLabelOffset), scale: scale)
        let y = selection.y - whole.y >= label.h + offset
            ? selection.y - label.h - offset
            : selection.y + ShotStyle.px(Int(ShotLook.Size.sizeLabelInset), scale: scale)
        return ShotRenderer.label(parts, style: .size, at: PixelPoint(selection.x, y), within: whole, on: surface, in: ctx)
    }

    /// What the overlay draws for the text box, which has no ground of its
    /// own (9.8.11): a dashed line around it that reads as dashes on any
    /// picture, and the caret.
    private func drawTextBox(on index: Int, in ctx: CGContext) {
        guard let typing, let selection = editor.selection, selection.display == index else { return }
        let scale = space.displays[index].scale
        let t = ShotLook.TextBox.self
        let a = space.pixel(ofLocal: typing.frame.origin, on: index)
        let b = space.pixel(ofLocal: CGPoint(x: typing.frame.maxX, y: typing.frame.maxY), on: index)
        let line = ShotStyle.px(Int(t.line), scale: scale)
        let off = ShotStyle.px(Int(t.offset), scale: scale)
        let dash = CGFloat(ShotStyle.px(Int(t.dash), scale: scale))
        // The middle of a line `line` wide whose inner edge is `off` out
        // from the box.
        let out = CGFloat(off) - CGFloat(line) / 2 + CGFloat(line)
        let frame = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: -out, dy: -out)
        ctx.saveGState()
        // Whole pixels, hard edges: a dash is a dash.
        ctx.setShouldAntialias(false)
        ctx.setLineWidth(CGFloat(line))
        // Dark all the way round, then light over every other piece: dark
        // and light end to end. On a light picture the dark pieces read,
        // on a dark one the light, and the rhythm is the same.
        ctx.setStrokeColor(ShotRenderer.ink(ShotLook.Colour.boxDark))
        ctx.stroke(frame)
        ctx.setStrokeColor(ShotRenderer.ink(ShotLook.Colour.boxLight))
        ctx.setLineDash(phase: dash, lengths: [dash, dash])
        ctx.stroke(frame)
        ctx.restoreGState()

        // The caret: the ink, with an edge of the opposite lightness so that
        // it shows on a picture of its own colour.
        guard caretOn, let box = editor.textBox else { return }
        let fontPt = CGFloat(ShotStyle.fontPx(level: box.level, scale: scale)) / CGFloat(scale)
        guard let caret = typing.caret(fontSize: fontPt) else { return }
        let ink = ShotStyle.colour(box.colour)
        let top = space.pixel(ofLocal: caret.origin, on: index)
        let width = max(ShotStyle.px(Int(t.caretWidth), scale: scale), 1)
        let height = max(Int((caret.height * CGFloat(scale)).rounded()), 1)
        let edge = ShotStyle.px(Int(t.caretEdge), scale: scale)
        let body = PixelRect(top.x, top.y, width, height)
        let dark = ShotTextLook.haloIsDark(for: ink)
        ShotRenderer.fill(
            PixelRect(body.x - edge, body.y - edge, body.w + 2 * edge, body.h + 2 * edge),
            ShotRenderer.ink(dark ? ShotLook.Colour.caretEdgeDark : ShotLook.Colour.caretEdgeLight), in: ctx)
        ShotRenderer.fill(body, ShotRenderer.colour(ink), in: ctx)
    }

    /// The toolbar: its plate, kept until it moves, and its cells as they
    /// look at `now`.
    private func drawToolbar(
        _ layout: ShotToolbarGrid.Layout, on index: Int, surface: ShotChrome.Surface, at now: TimeInterval,
        in ctx: CGContext
    ) {
        let key = PlateKey(display: index, plate: layout.plate, props: layout.props, glass: surface.glass != nil)
        let cells = layout.buttons.map { placed in
            ShotChrome.Cell(
                button: placed.button, rect: placed.rect,
                look: cellFades[placed.button]?.look(at: now) ?? ShotCell.look(for: cellState(of: placed.button)))
        }
        func place(_ image: CGImage, of painted: ShotChrome.Painted) {
            ShotRenderer.draw(
                image,
                in: CGRect(
                    x: painted.origin.x, y: painted.origin.y,
                    width: painted.canvas.width, height: painted.canvas.height),
                of: ctx)
        }
        let plate: ShotChrome.Painted
        if let cache = plateCache, cache.key == key {
            plate = cache.painted
        } else {
            plate = ShotChrome.toolbarPlate(layout, on: surface)
            plateCache = (key, plate)
        }
        if let cache = toolbarCache, cache.key == key, cache.cells == cells, cache.props == editor.props {
            place(cache.image, of: plate)
            return
        }
        let painted = ShotChrome.toolbar(over: plate, cells: cells, props: editor.props, on: surface)
        guard let image = ShotRenderer.image(of: painted.canvas) else { return }
        toolbarCache = ToolbarPicture(key: key, cells: cells, props: editor.props, image: image)
        place(image, of: painted)
    }

    /// The sentence under the long screenshot's height, as a msgid, or nil
    /// for none. **"Scroll slower" is there from the first frame that could
    /// not be joined**: `last` is that frame's answer and is kept until a
    /// frame that adds something, so the person scrolling by hand is told
    /// while it is happening and not when the picture ends.
    private static func longHint(of long: Long, selectionHeight: Int) -> String? {
        switch long.last {
        case _ where long.stitcher.isRestless(held: long.moving):
            return "The picture keeps changing, so nothing can be added."
        case .lost: return "Scroll slower"
        case .full: return "The height limit was reached."
        case _ where long.auto != nil:
            return "Scrolling down… Enter keeps what is joined so far, Esc cancels."
        default:
            guard long.stitcher.totalHeight <= selectionHeight else { return nil }
            return long.denied
                ? "Scrolling for you needs the Accessibility permission, so scroll down slowly by hand."
                : "Scroll down slowly. What comes into view is added at the bottom."
        }
    }

    /// The hint now, for a test.
    var longHint: String? {
        guard let long, let selection = editor.selection else { return nil }
        return Self.longHint(of: long, selectionHeight: selection.rect.h)
    }

    /// Under the toolbar: how tall the picture is so far and what the last
    /// frame meant; and beside the selection, a small copy of the picture.
    private func drawLongStatus(
        _ long: Long, at: PixelPoint, selection: PixelRect, display: PixelRect,
        surface: ShotChrome.Surface, in ctx: CGContext
    ) -> PixelRect {
        let scale = surface.scale
        // A dot, what this is, how tall it has become, and what to do.
        var parts: [ShotRenderer.LabelPart] = [
            .dot, .words(ShotWords.translate("Long Screenshot")), .words("\(long.stitcher.totalHeight) px"),
        ]
        if let hint = Self.longHint(of: long, selectionHeight: selection.h) {
            parts.append(.words(ShotWords.translate(hint), dim: true))
        }
        let plate = ShotRenderer.label(parts, style: .status, at: at, within: display, on: surface, in: ctx)

        // The preview: right of the selection, or left of it, or not at all.
        let gap = ShotStyle.px(12, scale: scale)
        let width = ShotStyle.px(120, scale: scale)
        let x: Int
        if selection.right + gap + width <= display.right {
            x = selection.right + gap
        } else if selection.x - gap - width >= display.x {
            x = selection.x - gap - width
        } else {
            return plate
        }
        let room = max(display.h - gap * 2, 1)
        guard let thumb = long.stitcher.thumbnail(maxWidth: width, maxHeight: room),
              let image = ComposedImage(width: thumb.width, rgbx: thumb.rgbx)?.cgImage() else { return plate }
        let top = max(min(max(selection.y, display.y + gap), display.bottom - gap - thumb.height), display.y)
        ShotRenderer.draw(image, in: CGRect(x: x, y: top, width: thumb.width, height: thumb.height), of: ctx)
        ShotRenderer.frame(
            PixelRect(x - 1, top - 1, thumb.width + 2, thumb.height + 2),
            ShotRenderer.ink(ShotLook.Colour.accent), thickness: 1, in: ctx)
        return plate
    }
}
