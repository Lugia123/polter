import AppKit

/// What an overlay tells the controller that owns it.
protocol ShotOverlayDelegate: AnyObject {
    /// The person started picking on this display; a selection on any other
    /// display is over.
    func overlayDidBeginSelection(_ view: ShotOverlayView)
    func overlayDidCancel(_ view: ShotOverlayView)
    func overlayDidFinish(_ view: ShotOverlayView)
}

/// The window that covers one display with its frozen picture.
///
/// A non-activating panel: it takes the keyboard -- `Esc`, `Enter`, and the
/// text of an annotation, input method included -- without making this app
/// the active one. Whatever was in front when the hotkey was pressed is
/// still in front when the screenshot is done.
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
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        setFrame(display.screen.frame, display: false)
    }
}

/// One display's frozen picture, the selection on it and the annotations on
/// the selection (`dev-docs/poltergeist/screenshot.md`, 3.2 and 3.3).
///
/// The view is flipped, so its coordinates are the ones `ShotGeometry`
/// works in: points, origin at the top left of the display.
final class ShotOverlayView: NSView, NSTextFieldDelegate, ShotToolbarDelegate {
    let display: ShotDisplay
    weak var delegate: ShotOverlayDelegate?

    /// The windows that were on this display, front to back, in this view's
    /// coordinates.
    private let windows: [ShotGeometry.Window]
    private let picture: NSImage

    private(set) var selection: CGRect?
    private(set) var source: ShotExport.Source = .region
    private(set) var annotations = ShotAnnotations()

    private var hover: (window: ShotGeometry.Window, visible: CGRect)?
    private var tool: ShotTool?
    private var color = ShotColor.palette[0]
    private var drag: Drag = .none
    /// A region being dragged out, before the button is released.
    private var pendingRegion: CGRect?
    /// A shape being drawn, before the button is released.
    private var pendingAnnotation: ShotAnnotation?

    private var editor: NSTextField?
    private var editing: Editing?
    private let toolbar = ShotToolbar()

    private enum Drag {
        case none
        case pick(start: CGPoint, dragging: Bool)
        case move(last: CGPoint)
        case resize(ShotGeometry.Handle)
        case shape(start: CGPoint)
        case stroke([CGPoint])
    }

    private enum Editing {
        /// A new text annotation whose top left is here.
        case text(at: CGPoint)
        /// The caption of the numbered marker that was just placed, which is
        /// the last annotation.
        case caption
    }

    // Sizes, in points. One place, so that what is drawn lines up.
    private static let handleSize: CGFloat = 8
    private static let borderWidth: CGFloat = 1.5
    private static let labelPadding: CGFloat = 6
    private static let labelGap: CGFloat = 4
    private static let dim: CGFloat = 0.45
    /// Shapes smaller than this are a slip of the hand, not an annotation.
    private static let minimumShape: CGFloat = 3

    init(display: ShotDisplay, windows: [ShotGeometry.Window]) {
        self.display = display
        self.windows = windows
        self.picture = NSImage(cgImage: display.image, size: display.frame.size)
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        toolbar.delegate = self
        toolbar.isHidden = true
        addSubview(toolbar)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: From the controller

    /// Select the window under `point`, as a click there would. Used when
    /// the screenshot was started by a double-click: the window that was
    /// clicked is already chosen when the overlay appears.
    func preselectWindow(at point: CGPoint) {
        guard selection == nil,
              let hit = ShotGeometry.window(at: point, in: windows, within: bounds) else { return }
        select(hit.visible, source: Self.source(of: hit.window))
    }

    /// Forget the selection and everything drawn on it.
    func clearSelection() {
        discardEditor()
        selection = nil
        source = .region
        annotations = ShotAnnotations()
        pendingRegion = nil
        pendingAnnotation = nil
        tool = nil
        drag = .none
        toolbar.isHidden = true
        needsDisplay = true
    }

    private static func source(of window: ShotGeometry.Window) -> ShotExport.Source {
        .init(kind: .window, app: window.app, title: window.title)
    }

    private func select(_ rect: CGRect, source: ShotExport.Source) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        selection = rect
        self.source = source
        hover = nil
        pendingRegion = nil
        layoutToolbar()
        needsDisplay = true
    }

    /// Whether the selection can still be moved and resized. Once something
    /// is drawn on it, it cannot: the drawing is placed relative to it.
    private var isAdjustable: Bool { tool == nil && annotations.isEmpty && editor == nil }

    // MARK: Mouse

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = location(of: event)
        commitEditor()

        guard let selection else {
            delegate?.overlayDidBeginSelection(self)
            drag = .pick(start: point, dragging: false)
            return
        }

        if let tool {
            guard selection.contains(point) else { return }
            switch tool {
            case .rect, .arrow:
                drag = .shape(start: point)
            case .pen:
                drag = .stroke([point])
            case .text:
                beginEditing(.text(at: point), fieldOrigin: point)
            case .number:
                annotations.add(.number(annotations.nextNumber, at: point, text: "", color: color))
                beginEditing(.caption, fieldOrigin: ShotRenderer.captionOrigin(forNumberAt: point))
                needsDisplay = true
            }
            return
        }

        if event.clickCount == 2, selection.contains(point) {
            delegate?.overlayDidFinish(self)
            return
        }
        guard isAdjustable else { return }

        if let handle = ShotGeometry.handle(at: point, on: selection) {
            drag = .resize(handle)
        } else if selection.contains(point) {
            drag = .move(last: point)
        } else {
            // A press outside starts over.
            self.selection = nil
            toolbar.isHidden = true
            drag = .pick(start: point, dragging: false)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        switch drag {
        case .none:
            return

        case let .pick(start, dragging):
            guard dragging || ShotGeometry.isDrag(from: start, to: point) else { return }
            drag = .pick(start: start, dragging: true)
            hover = nil
            pendingRegion = ShotGeometry.rect(from: start, to: point, within: bounds)

        case let .move(last):
            guard let selection else { return }
            self.selection = ShotGeometry.move(
                selection,
                by: CGSize(width: point.x - last.x, height: point.y - last.y),
                within: bounds)
            drag = .move(last: point)
            layoutToolbar()

        case let .resize(handle):
            guard let selection else { return }
            self.selection = ShotGeometry.resize(selection, dragging: handle, to: point, within: bounds)
            // A resized window is no longer that window.
            source = .region
            layoutToolbar()

        case let .shape(start):
            guard let selection, let tool else { return }
            let end = ShotGeometry.clamp(point, to: selection)
            pendingAnnotation = tool == .rect
                ? .rect(ShotGeometry.rect(from: start, to: end, within: selection), color: color)
                : .arrow(from: start, to: end, color: color)

        case var .stroke(points):
            guard let selection else { return }
            points.append(ShotGeometry.clamp(point, to: selection))
            drag = .stroke(points)
            pendingAnnotation = .pen(points, color: color)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = location(of: event)
        defer {
            drag = .none
            pendingRegion = nil
            pendingAnnotation = nil
            needsDisplay = true
        }

        switch drag {
        case let .pick(_, dragging):
            if dragging, let region = pendingRegion {
                select(region, source: .region)
            } else if let hit = ShotGeometry.window(at: point, in: windows, within: bounds) {
                select(hit.visible, source: Self.source(of: hit.window))
            } else {
                // A click on the bare desktop: the whole display.
                select(bounds, source: .region)
            }

        case .shape, .stroke:
            if let pendingAnnotation, Self.isWorthKeeping(pendingAnnotation) {
                annotations.add(pendingAnnotation)
                toolbar.canUndo = true
            }

        case .move, .resize:
            layoutToolbar()

        case .none:
            break
        }
    }

    private static func isWorthKeeping(_ annotation: ShotAnnotation) -> Bool {
        switch annotation {
        case let .rect(rect, _):
            return rect.width >= minimumShape && rect.height >= minimumShape
        case let .arrow(from, to, _):
            return max(abs(to.x - from.x), abs(to.y - from.y)) >= minimumShape
        case let .pen(points, _):
            return points.count >= 2
        case .text, .number:
            return true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard selection == nil, case .none = drag else { return }
        let hit = ShotGeometry.window(at: location(of: event), in: windows, within: bounds)
        if hit?.visible != hover?.visible {
            hover = hit
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil {
            hover = nil
            needsDisplay = true
        }
    }

    /// The right button goes back one step: out of a text field, then out of
    /// the selection, then out of the screenshot.
    override func rightMouseDown(with event: NSEvent) {
        if editor != nil {
            discardEditor()
        } else if selection != nil {
            clearSelection()
        } else {
            delegate?.overlayDidCancel(self)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // Escape
            delegate?.overlayDidCancel(self)
        case 36, 76: // Return, Enter
            if selection != nil { delegate?.overlayDidFinish(self) }
        case 6 where flags.contains(.command) && !flags.contains(.shift): // z
            undo()
        default:
            // Swallowed: nothing typed here should reach a menu or beep.
            break
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While text is being typed the field editor gets its own keys.
        guard editor == nil, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    // MARK: Toolbar

    func toolbar(_ toolbar: ShotToolbar, didChoose tool: ShotTool?) {
        commitEditor()
        self.tool = tool
        needsDisplay = true
    }

    func toolbar(_ toolbar: ShotToolbar, didChoose color: ShotColor) {
        self.color = color
        editor?.textColor = color.nsColor
    }

    func toolbarDidUndo(_ toolbar: ShotToolbar) { undo() }
    func toolbarDidCancel(_ toolbar: ShotToolbar) { delegate?.overlayDidCancel(self) }

    func toolbarDidFinish(_ toolbar: ShotToolbar) {
        commitEditor()
        delegate?.overlayDidFinish(self)
    }

    private func undo() {
        if editor != nil {
            // The marker whose caption was being typed goes with it.
            let wasCaption: Bool
            if case .caption = editing { wasCaption = true } else { wasCaption = false }
            discardEditor()
            if wasCaption { annotations.undo() }
        } else {
            annotations.undo()
        }
        toolbar.canUndo = !annotations.isEmpty
        needsDisplay = true
    }

    private func layoutToolbar() {
        guard let selection else {
            toolbar.isHidden = true
            return
        }
        let size = toolbar.fittingSize
        let placed = ShotGeometry.toolbar(size: size, for: selection, within: bounds)
        toolbar.frame = CGRect(origin: placed.origin, size: size)
        toolbar.canUndo = !annotations.isEmpty
        toolbar.isHidden = false
    }

    // MARK: Typing

    private func beginEditing(_ what: Editing, fieldOrigin: CGPoint) {
        guard let selection else { return }
        let font = ShotRenderer.textFont
        let height = ceil(font.ascender - font.descender) + 4
        let width = max(80, min(320, selection.maxX - fieldOrigin.x))

        let field = NSTextField(frame: CGRect(
            x: fieldOrigin.x, y: fieldOrigin.y, width: width, height: height))
        field.font = font
        field.textColor = color.nsColor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)
        editor = field
        editing = what
        window?.makeKey()
        window?.makeFirstResponder(field)
    }

    /// Keep what was typed.
    private func commitEditor() {
        guard let editor, let editing else { return }
        let text = ShotExport.oneLine(editor.stringValue)
        // Where the field drew its text, so the annotation does not jump
        // when the field goes away.
        let origin = CGPoint(x: editor.frame.minX + 2, y: editor.frame.minY)
        removeEditor()

        switch editing {
        case .text:
            guard !text.isEmpty else { break }
            annotations.add(.text(at: origin, text, color: color))
        case .caption:
            if case let .number(n, at, _, color)? = annotations.items.last {
                annotations.replaceLast(with: .number(n, at: at, text: text, color: color))
            }
        }
        toolbar.canUndo = !annotations.isEmpty
        needsDisplay = true
    }

    /// Drop what was typed. A numbered marker stays, without a caption.
    private func discardEditor() {
        guard editor != nil else { return }
        removeEditor()
        needsDisplay = true
    }

    private func removeEditor() {
        editor?.delegate = nil
        editor?.removeFromSuperview()
        editor = nil
        editing = nil
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitEditor()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            discardEditor()
            return true
        }
        return false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        picture.draw(
            in: bounds, from: .zero, operation: .copy, fraction: 1,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])

        // Everything but the part that will be kept is dimmed.
        let lit = pendingRegion ?? selection ?? hover?.visible
        let shade = NSBezierPath(rect: bounds)
        if let lit { shade.append(NSBezierPath(rect: lit)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(Self.dim).setFill()
        shade.fill()

        guard let lit else { return }

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: lit.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2))
        border.lineWidth = Self.borderWidth
        border.stroke()

        guard let selection, pendingRegion == nil else {
            if let pendingRegion { drawSizeLabel(for: pendingRegion) }
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        ShotRenderer.draw(annotations.items)
        if let pendingAnnotation { ShotRenderer.draw(pendingAnnotation) }
        NSGraphicsContext.restoreGraphicsState()

        if isAdjustable {
            for handle in ShotGeometry.Handle.allCases {
                let center = ShotGeometry.point(of: handle, on: selection)
                let square = CGRect(
                    x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2,
                    width: Self.handleSize, height: Self.handleSize)
                NSColor.white.setFill()
                NSBezierPath(rect: square).fill()
                NSColor.controlAccentColor.setStroke()
                let edge = NSBezierPath(rect: square)
                edge.lineWidth = 1
                edge.stroke()
            }
        }

        drawSizeLabel(for: selection)
    }

    /// The selection's size in pixels of the saved image, above its top
    /// left corner, or just inside it when there is no room above.
    private func drawSizeLabel(for rect: CGRect) {
        let pixels = ShotGeometry.pixelRect(rect, scale: display.scale, imageSize: display.imageSize)
        let text = NSAttributedString(
            string: "\(Int(pixels.width)) × \(Int(pixels.height))",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.white,
            ])
        let size = text.size()
        let box = CGSize(width: size.width + Self.labelPadding * 2, height: size.height + Self.labelPadding)
        var origin = CGPoint(x: rect.minX, y: rect.minY - Self.labelGap - box.height)
        if origin.y < bounds.minY { origin.y = rect.minY + Self.labelGap }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - box.width))

        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: box), xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: origin.x + Self.labelPadding, y: origin.y + Self.labelPadding / 2))
    }
}
