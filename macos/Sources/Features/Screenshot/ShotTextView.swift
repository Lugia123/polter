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

    /// A box with its layout settled before anything is typed in it.
    ///
    /// **The layout manager is asked for here, and that is the point.** A
    /// text view made with `init(frame:)` lays out with TextKit 2, and the
    /// first time anything asks it for `layoutManager` it rebuilds itself on
    /// TextKit 1, for good. The box is measured through the layout manager,
    /// so that rebuilding used to happen on the first change to the text --
    /// which for a new box is the first key, inside the input method's
    /// first `setMarkedText`, with the composition half recorded.
    convenience init(box frame: NSRect) {
        self.init(frame: frame)
        _ = layoutManager
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
        drawsBackground = true

        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: frame.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        documentView = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isToolbar?(point) == true { return nil }
        return super.hitTest(point)
    }

    /// The paper under the text, and under the part of the box below it.
    var paper: NSColor {
        get { backgroundColor }
        set {
            backgroundColor = newValue
            text.backgroundColor = newValue
        }
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
