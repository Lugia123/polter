import AppKit

/// What may be done to the text box while an input method is at work in it
/// (`dev-docs/poltergeist/screenshot.md`, 9.3; task 1110).
///
/// An input method composes by calling the text view -- `setMarkedText`
/// once for each key, `insertText` when the composition is accepted -- and
/// the view is halfway through its own bookkeeping for most of each call:
/// on the first key of a composition the characters are already in the text
/// while the marked range is still the empty one after them. The box used
/// to be placed again from inside those calls, and the first placing of a
/// box did more than move it (see `ShotTextView.init(box:)`): typed into an
/// empty box, pinyin `nihao` came out as `n你好`.
///
/// So there are two rules, and both are here so that they can be tested
/// without a window:
///
///  * **Nothing is done inside one of the input method's calls.** What
///    changed is noted, and the box is placed once, when the call is over
///    and the view's state is whole (`Gate`).
///  * **While a composition is open, only geometry moves.** The text, its
///    attributes and the selection belong to the input method until it is
///    done (`restyle`).
enum ShotTextInput {
    /// Holds back "the text changed" while the input method is calling.
    struct Gate {
        /// How many of the input method's calls are in progress: they nest
        /// (accepting a composition is an `insertText` that unmarks).
        private(set) var depth = 0
        /// Whether something changed that has not been acted on.
        private(set) var waiting = false

        /// One of the input method's calls begins.
        mutating func enter() { depth += 1 }

        /// The text or the caret changed. True when that is to be acted on
        /// now; false when it is noted for the end of the call.
        mutating func changed() -> Bool {
            guard depth > 0 else { return true }
            waiting = true
            return false
        }

        /// A call ended. True when it was the outermost and something
        /// changed during it: act on that now, once.
        mutating func leave() -> Bool {
            depth = max(depth - 1, 0)
            guard depth == 0, waiting else { return false }
            waiting = false
            return true
        }
    }

    /// How much of the text a new colour or size reaches.
    enum Restyle: Equatable {
        /// All of it: what is typed and what will be.
        case everything
        /// Only what will be typed. What is there is left as it is until
        /// the composition is over, and is restyled then.
        case typingOnly
    }

    /// A colour or a size was pressed while `composing` or not.
    static func restyle(composing: Bool) -> Restyle {
        composing ? .typingOnly : .everything
    }

    /// Whether the restyling that a composition held back is due: there is
    /// one, and the composition is over.
    static func restyleDue(held: Bool, composing: Bool) -> Bool {
        held && !composing
    }

    /// Whether a press on the overlay may take the keyboard from the text
    /// box. Not when it is a press on a colour or a size while a text is
    /// being typed: that press changes the text and the typing goes on.
    ///
    /// AppKit makes the view that is pressed the first responder before it
    /// sends it the press, and the box used to give the keyboard up and be
    /// handed it back a moment later. A text view that gives up the keyboard
    /// ends its input method's composition: the candidates went away, and
    /// the space that should have chosen one typed the letters instead
    /// (found on a real machine, task 1112). So the overlay says no, and the
    /// box never loses the keyboard at all.
    static func overlayTakesKeyboard(typing: Bool, pressRestyles: Bool) -> Bool {
        !(typing && pressRestyles)
    }
}

/// How the box shows a text of a given colour over a picture it does not
/// cover (`dev-docs/poltergeist/screenshot.md`, 9.8.11).
///
/// The box has no ground of its own, so white text over a white picture has
/// nothing to be seen against. What is being typed therefore wears a halo
/// of the opposite lightness, and the caret an edge of it; neither is in
/// the finished picture.
enum ShotTextLook {
    /// A colour's relative luminance, 0 to 1: each channel made linear, then
    /// weighed.
    static func luminance(_ c: ShotStyle.RGB) -> Double {
        func linear(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let g = ShotLook.Glass.self
        return g.lumaR * linear(c.r) + g.lumaG * linear(c.g) + g.lumaB * linear(c.b)
    }

    /// Whether what sets a text of colour `c` off is dark: for a light
    /// text. Of the nine colours only yellow and white are light.
    static func haloIsDark(for c: ShotStyle.RGB) -> Bool {
        luminance(c) >= ShotLook.TextBox.lightTextLuminance
    }

    /// The caret for a line `line` (its rectangle in whatever space the
    /// caller draws in) whose insertion point is at `x`: as wide as the
    /// data says, 1.08 of the font's size tall and never taller than the
    /// line, centred on it.
    static func caret(x: Double, lineTop: Double, lineHeight: Double, fontSize: Double, scale: Double) -> CGRect {
        let t = ShotLook.TextBox.self
        let height = min(fontSize * t.caretHeightEm, lineHeight)
        return CGRect(
            x: x, y: lineTop + (lineHeight - height) / 2, width: t.caretWidth * scale, height: height)
    }
}

/// The layout manager of the text box: it draws what is typed with a halo
/// around it (9.8.11), which is what makes white text readable over a white
/// picture while it is being typed.
///
/// The halo is two soft copies of the glyphs under the glyphs themselves --
/// a tight strong one and a wider faint one -- and it reaches the underline
/// of a composition too, which is drawn with the glyphs.
final class ShotHaloLayout: NSLayoutManager {
    /// The halo's colour, without its alpha; nil for none.
    var halo: NSColor?
    /// The characters an input method is composing, and the colour of the
    /// line drawn under them. The line is drawn here, with the glyphs, so
    /// that it is the same two points on every system and has the halo.
    var marked: NSRange?
    var ink: NSColor = .red

    /// The glyphs, and the line under a composition.
    private func drawInk(_ glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let marked, marked.length > 0, let container = textContainers.first else { return }
        let glyphs = glyphRange(forCharacterRange: marked, actualCharacterRange: nil)
        let shown = NSIntersectionRange(glyphs, glyphsToShow)
        guard shown.length > 0 else { return }
        let thick = CGFloat(ShotLook.TextBox.markedLine)
        // Far enough above the bottom of its line that the halo under it is
        // inside the box: the box is the view's whole drawing area, and a
        // line against its bottom edge lost the lower half of its halo --
        // which is the half that shows white-on-white (task 1198).
        let lift = (CGFloat(ShotLook.TextBox.haloFarSigma) * 1.6).rounded(.up)
        ink.setFill()
        enumerateEnclosingRects(
            forGlyphRange: shown, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in
            NSRect(
                x: rect.minX + origin.x, y: rect.maxY + origin.y - thick - lift, width: rect.width, height: thick
            ).fill()
        }
    }

    /// **No other line is drawn under anything.** An input method marks its
    /// composition with an underline of its own -- the system's, in its own
    /// colour -- and white on white that blue line was all that could be
    /// seen of the composition. The only line is the specified one, drawn
    /// above with the glyphs and with their halo.
    override func underlineGlyphRange(
        _ glyphRange: NSRange, underlineType underlineVal: NSUnderlineStyle, lineFragmentRect lineRect: NSRect,
        lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: NSPoint
    ) {}

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let halo, let ctx = NSGraphicsContext.current?.cgContext else {
            drawInk(glyphsToShow, at: origin)
            return
        }
        // A shadow's blur is in the bitmap's pixels whatever the context is
        // scaled by, and about twice the deviation it gives.
        let scale = abs(ctx.userSpaceToDeviceSpaceTransform.a)
        let t = ShotLook.TextBox.self
        for (sigma, alpha) in [(t.haloFarSigma, t.haloFarAlpha), (t.haloNearSigma, t.haloNearAlpha)] {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero, blur: CGFloat(2 * sigma) * scale,
                color: halo.withAlphaComponent(CGFloat(alpha)).cgColor)
            drawInk(glyphsToShow, at: origin)
            ctx.restoreGState()
        }
        drawInk(glyphsToShow, at: origin)
    }
}

/// The box a piece of text is typed in: a real text view, so that the input
/// method works in it (`dev-docs/poltergeist/screenshot.md`, 9.3).
///
/// Enter is a line break and is the view's own. Command+Enter and Esc end
/// the typing and keep what was typed; so does losing the keyboard -- except
/// to a press on a colour or a size, which is a change to this text. While
/// an input method is composing, Esc reaches the input method and not
/// `cancelOperation`, so it cancels the composition only.
final class ShotTextView: NSTextView {
    /// Called when the typing ends. May be called more than once for one
    /// box -- taking the box away makes it give up the keyboard, which asks
    /// again -- and whoever is called has to make the second call nothing.
    var onCommit: (() -> Void)?
    /// Asked when the keyboard is being given up: whether that is only the
    /// press of a colour or a size, which changes this text and hands the
    /// keyboard straight back, and so is not the end of the typing.
    var staysOpen: (() -> Bool)?
    /// Called when what is typed, or where the caret is, has changed: the
    /// box is as tall as its lines (`ShotTextBox`), and whoever placed it
    /// places it again. Never called from inside one of the input method's
    /// calls (`ShotTextInput.Gate`).
    var onChange: (() -> Void)?

    private var gate = ShotTextInput.Gate()
    /// The text itself. A text view made around a container does not keep
    /// what the container's layout manager belongs to.
    private var storage: NSTextStorage?

    /// A box with its layout settled before anything is typed in it.
    ///
    /// **It is built on TextKit 1 from the start, and that is the point.** A
    /// text view made with `init(frame:)` lays out with TextKit 2, and the
    /// first time anything asks it for `layoutManager` it rebuilds itself on
    /// TextKit 1, for good. The box is measured through the layout manager,
    /// so that rebuilding used to happen on the first change to the text --
    /// which for a new box is the first key, inside the input method's
    /// first `setMarkedText`, with the composition half recorded (task
    /// 1110). Made around its own layout manager there is nothing to
    /// rebuild -- and the layout manager is the one that draws the halo.
    convenience init(box frame: NSRect) {
        let storage = NSTextStorage()
        let manager = ShotHaloLayout()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        manager.addTextContainer(container)
        self.init(frame: frame, textContainer: container)
        self.storage = storage
        // No ground: the picture shows through (9.8.11).
        drawsBackground = false
    }

    /// The colour of what is typed. The halo, the caret's edge and the
    /// selection follow from it.
    var ink: ShotStyle.RGB = ShotStyle.colour(0) {
        didSet { dress() }
    }

    /// Everything about the box that depends on the ink and not on the
    /// text: what sets it off, how a selection and a composition show.
    private func dress() {
        let dark = ShotTextLook.haloIsDark(for: ink)
        let colour = NSColor(
            srgbRed: CGFloat(ink.r) / 255, green: CGFloat(ink.g) / 255, blue: CGFloat(ink.b) / 255, alpha: 1)
        (layoutManager as? ShotHaloLayout)?.halo = dark ? .black : .white
        (layoutManager as? ShotHaloLayout)?.ink = colour
        // The caret is drawn by the overlay, with an edge that shows on any
        // picture; the view's own would be a second one.
        insertionPointColor = .clear
        // A selection is the accent laid under the text, the same on both
        // hosts, not the system's selection colour.
        let accent = ShotLook.Colour.accent
        selectedTextAttributes = [
            .backgroundColor: NSColor(
                srgbRed: CGFloat(accent.r) / 255, green: CGFloat(accent.g) / 255, blue: CGFloat(accent.b) / 255,
                alpha: CGFloat(ShotLook.TextBox.selectionAlpha)),
        ]
        // A composition is the text in its own colour; the line under it
        // is the layout manager's (`ShotHaloLayout.marked`).
        markedTextAttributes = [.foregroundColor: colour]
        needsDisplay = true
    }

    /// Where the caret is, in this view's coordinates: the rectangle of its
    /// line and the x of the insertion point. Nil while something is
    /// selected -- then there is no caret.
    var caretPlace: (line: NSRect, x: CGFloat)? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        manager.ensureLayout(for: container)
        let origin = textContainerOrigin
        let length = (string as NSString).length
        let extra = manager.extraLineFragmentRect
        if manager.numberOfGlyphs == 0 || (selection.location >= length && !extra.isEmpty) {
            // An empty box, or after a line break at the end.
            let line = extra.isEmpty
                ? NSRect(x: 0, y: 0, width: bounds.width, height: manager.defaultLineHeight(for: font ?? .systemFont(ofSize: 12)))
                : extra
            return (line.offsetBy(dx: origin.x, dy: origin.y), origin.x + line.minX)
        }
        if selection.location >= length {
            // After the last character: the end of what its line holds.
            let glyph = manager.numberOfGlyphs - 1
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            return (line.offsetBy(dx: origin.x, dy: origin.y), origin.x + used.maxX)
        }
        let glyph = manager.glyphIndexForCharacter(at: selection.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let at = manager.location(forGlyphAt: glyph)
        return (line.offsetBy(dx: origin.x, dy: origin.y), origin.x + line.minX + at.x)
    }

    /// How many lines the view has laid out: a line break is one, and so is
    /// a line the view wrapped at its right edge.
    var laidOutLines: Int {
        let counted = ShotTextBox.lines(in: string)
        guard let manager = layoutManager, let container = textContainer, let font else { return counted }
        manager.ensureLayout(for: container)
        let pitch = manager.defaultLineHeight(for: font)
        guard pitch > 0 else { return counted }
        return max(Int((manager.usedRect(for: container).height / pitch).rounded()), counted)
    }

    private func changed() {
        if gate.changed() { onChange?() }
    }

    /// Run one of the input method's calls with the box left alone, and
    /// place it once afterwards if anything changed.
    private func inputCall(_ body: () -> Void) {
        gate.enter()
        body()
        // Where the composition is now, for the line under it.
        let range = markedRange()
        (layoutManager as? ShotHaloLayout)?.marked = hasMarkedText() && range.location != NSNotFound ? range : nil
        needsDisplay = true
        if gate.leave() { onChange?() }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputCall { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        inputCall { super.insertText(string, replacementRange: replacementRange) }
    }

    override func unmarkText() {
        inputCall { super.unmarkText() }
    }

    override func didChangeText() {
        super.didChangeText()
        changed()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { changed() }
    }

    override func cancelOperation(_ sender: Any?) {
        onCommit?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [36, 76].contains(event.keyCode), flags.contains(.command), !hasMarkedText() {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, staysOpen?() != true { onCommit?() }
        return resigned
    }
}

/// The text box as it sits on the overlay: the text view in a scroll view
/// with no scrollers, which is the size `ShotTextBox` gives the box.
///
/// The box stops growing at the selection's bottom edge and what is typed
/// past that scrolls in it, so that the line the caret is on is the one in
/// view (specification 9.3). The text view was once on the overlay itself,
/// cut to the box's size, with its own bounds moved by hand to do the
/// scrolling. A text view on its own is as tall as its text and makes
/// itself so again after every change, so that was setting its frame
/// against it each time; and on the test machine the caret's line was not
/// in view (task 1110). A clip view is what AppKit scrolls a text view in:
/// the view keeps its natural height, the clip is the box, and
/// `scrollRangeToVisible` does the rest -- for a deletion, an arrow key and
/// a text that fits again alike.
final class ShotTextScroll: NSScrollView {
    let text: ShotTextView
    /// Whether a point of the overlay (the superview's coordinates) is the
    /// toolbar's. A press there is not the box's even where the box lies
    /// over it: the toolbar is asked first, always (specification 9.3).
    var isToolbar: ((NSPoint) -> Bool)?

    init(box frame: NSRect) {
        text = ShotTextView(box: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        // No ground of its own: what is under the box is the picture, and
        // it shows (9.8.11).
        drawsBackground = false

        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: frame.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        documentView = text
        contentView.drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isToolbar?(point) == true { return nil }
        return super.hitTest(point)
    }

    /// The caret as the overlay draws it, in the coordinates this view's
    /// frame is in: nil when there is none, or when its line is scrolled
    /// out of the box.
    func caret(fontSize: CGFloat) -> CGRect? {
        guard let place = text.caretPlace else { return nil }
        let line = convert(place.line, from: text)
        let x = convert(NSPoint(x: place.x, y: place.line.minY), from: text).x
        // In this view's own coordinates, from its top edge, whichever way
        // up it is.
        let top = isFlipped ? line.minY : bounds.height - line.maxY
        let caret = ShotTextLook.caret(
            x: Double(x), lineTop: Double(top), lineHeight: Double(line.height), fontSize: Double(fontSize), scale: 1)
        guard caret.maxY > 0, caret.minY < bounds.height else { return nil }
        return caret.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// Put the box at `frame` and bring the caret's line into view. A text
    /// that fits again is back at the top without being asked: the text
    /// view shrinks to its text and the clip view does not scroll past it.
    ///
    /// **Geometry only**: nothing of the text, its attributes or the
    /// selection is touched, so this is safe while an input method is
    /// composing (`ShotTextInput`).
    func place(_ frame: NSRect) {
        if self.frame != frame {
            self.frame = frame
            // Never shorter than the box, so that a press anywhere in the
            // box is in the text.
            text.minSize = NSSize(width: 0, height: frame.height)
            text.sizeToFit()
        }
        text.scrollRangeToVisible(text.selectedRange())
    }

    /// The rectangle of the caret's line, in the text view's coordinates:
    /// what has to be in view.
    var caretLine: NSRect {
        guard let manager = text.layoutManager, let container = text.textContainer else { return .zero }
        manager.ensureLayout(for: container)
        let caret = text.selectedRange().location
        let extra = manager.extraLineFragmentRect
        if caret >= (text.string as NSString).length, !extra.isEmpty { return extra }
        guard manager.numberOfGlyphs > 0 else { return extra }
        let glyph = min(manager.glyphIndexForCharacter(at: caret), manager.numberOfGlyphs - 1)
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }
}
