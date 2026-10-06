import Foundation

/// How text measures in the font it will be drawn in. The app's is Core
/// Text; a test's is arithmetic.
protocol TextMeasure {
    /// The width and height of `text` (which may have several lines) at a
    /// font `fontPx` pixels tall.
    func size(of text: String, fontPx: Int) -> Annotation.PixelSize
}

/// The screenshot overlay as a state machine: what every click, drag and
/// key does, with no window in it (`dev-docs/poltergeist/screenshot.md`,
/// 3.2 and section 9). A port of the Windows host's `editor.rs`; see
/// `PixelGeometry.swift`.
///
/// The host forwards the mouse and the keyboard, draws what this holds,
/// and owns the one thing this cannot: the text box, a native control, so
/// that the input method works in it. Everything a person could find
/// surprising -- what a click on empty space does in each tool, what one
/// undo takes back, what the right button backs out of -- is decided here,
/// where it can be tested, and where the other host's behaviour can be
/// laid beside it rule for rule.
///
/// Coordinates are physical pixels in one space that holds every display,
/// each at its own place. `mods.command` is the key the specification
/// writes `cmd/ctrl`.
struct ShotEditor {
    struct Display: Equatable {
        var rect: PixelRect
        /// Pixels per point.
        var scale: Double
    }

    /// A window as it was when the screen was frozen, topmost first.
    struct Window: Equatable {
        var id: UInt64
        var rect: PixelRect
    }

    struct Selection: Equatable {
        var rect: PixelRect
        var display: Int
        /// The window this selection is, while it is still exactly that
        /// window.
        var window: UInt64?
    }

    /// The text being typed.
    struct TextBox: Equatable {
        /// Top left corner of the box.
        var at: PixelPoint
        /// What the box starts with: empty, or the text being edited again.
        var text: String
        var colour: Int
        var level: Int
        /// The annotation this edits, or nil for a new piece of text.
        var editing: Int?
        /// Whether it is a number's sentence rather than a text annotation.
        var caption: Bool
        /// Whether the number was placed by the same click that opened the
        /// box, so that the two are one step to undo.
        fileprivate var fresh: Bool
    }

    /// What the host has to do after an event.
    enum Effect: Equatable {
        case none
        case repaint
        /// A drag began: follow the pointer until the button comes up.
        case capture
        /// A drag ended.
        case release
        /// Close the overlay, touching nothing.
        case cancel
        /// Compose and deliver (`export`).
        case finish
        /// Long-screenshot mode was entered (`isLong`): open the selection
        /// to the live screen and start taking frames.
        case long
        /// Long-screenshot mode was left without finishing: stop taking
        /// frames and cover the selection again.
        case leaveLong
        /// Open the text box described by `textBox`.
        case openText
        /// The text box's colour or size changed; restyle it.
        case restyleText
        /// Read the text box, close it, and call `endText`.
        case commitText
    }

    private enum Drag {
        case none
        case pickRegion(down: PixelPoint)
        case resizeRegion(PixelHandle)
        case moveRegion(last: PixelPoint)
        /// A rectangle, ellipse, line, arrow or mosaic being drawn.
        case draw(start: PixelPoint)
        /// A pen or highlighter stroke being drawn.
        case stroke
        case moveItem(index: Int, last: PixelPoint, before: [Annotation], changed: Bool)
        case reshapeItem(index: Int, grip: Annotation.Grip, before: [Annotation], changed: Bool)
    }

    /// What leaves when the person is done.
    struct Export: Equatable {
        var selection: Selection
        var scale: Double
        /// Every annotation that reaches into the selection, in **screen**
        /// coordinates and drawing order, for composing the picture.
        var onScreen: [Annotation]
        /// The same annotations in **image** coordinates, for the sidecar
        /// and the pasted line.
        var onImage: [Annotation]
    }

    let displays: [Display]
    let windows: [Window]
    /// The window under the pointer while nothing is selected yet.
    private(set) var hover: (display: Int, rect: PixelRect)?
    /// A region being dragged out, before the button comes up.
    private(set) var forming: (rect: PixelRect, display: Int)?
    private(set) var selection: Selection?
    private(set) var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private(set) var tool: AnnotationTool = .select
    private(set) var prefs: ToolPrefs
    private(set) var selected: Int?
    private var drag: Drag = .none
    /// The annotation being drawn.
    private(set) var live: Annotation?
    private(set) var textBox: TextBox?
    private(set) var hoverButton: ToolbarButton?
    /// Whether a long screenshot is being taken: the selection shows the
    /// live screen, and nothing can be drawn.
    private(set) var isLong = false

    /// A new session over frozen `displays` and `windows`. `preselect` is
    /// where a mouse trigger happened: the window there starts selected.
    init(displays: [Display], windows: [Window], prefs: ToolPrefs, preselect: PixelPoint? = nil) {
        self.displays = displays
        self.windows = windows
        self.prefs = prefs
        if let preselect { selection = window(at: preselect) }
    }

    // MARK: Reading

    /// The bounds window `id` had when the screen was frozen.
    func windowRect(_ id: UInt64) -> PixelRect? {
        windows.first { $0.id == id }?.rect
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// The scale of the display the selection is on (1 before there is one).
    var scale: Double {
        guard let selection, displays.indices.contains(selection.display) else { return 1 }
        return displays[selection.display].scale
    }

    /// The annotations in the order they are drawn: mosaics first (9.5),
    /// then the rest as made. Each with its index in `items`.
    var drawOrder: [(index: Int, item: Annotation)] {
        func isMosaic(_ item: Annotation) -> Bool {
            if case .mosaic = item.shape { return true }
            return false
        }
        let indexed = items.enumerated().map { (index: $0.offset, item: $0.element) }
        return indexed.filter { isMosaic($0.item) } + indexed.filter { !isMosaic($0.item) }
    }

    /// Which property row is showing: the text being typed's, else the
    /// selected annotation's, else the current tool's.
    var props: AnnotationTool.Props {
        if let textBox { return textBox.caption ? AnnotationTool.number.props : AnnotationTool.text.props }
        if let selected, items.indices.contains(selected) { return items[selected].props }
        return tool.props
    }

    /// The colour and step the property row marks as current.
    var current: (colour: Int, level: Int) {
        if let textBox { return (textBox.colour, textBox.level) }
        if let selected, items.indices.contains(selected) { return (items[selected].colour, items[selected].level) }
        return (prefs.colour(of: tool), prefs.level(of: tool))
    }

    /// Where the toolbar is, once there is a selection.
    var layout: ShotToolbarGrid.Layout? {
        guard let selection, displays.indices.contains(selection.display) else { return nil }
        let display = displays[selection.display]
        return ShotToolbarGrid.layout(
            selection: selection.rect, display: display.rect, scale: display.scale, props: props)
    }

    private func display(at p: PixelPoint) -> Int? {
        displays.firstIndex { $0.rect.contains(p) }
    }

    private func window(at p: PixelPoint) -> Selection? {
        guard let display = display(at: p),
              let hit = PixelGeometry.pickWindow(windows.map(\.rect), at: p, within: displays[display].rect) else {
            return nil
        }
        return Selection(rect: hit.visible, display: display, window: windows[hit.index].id)
    }

    // MARK: History

    /// Remember the annotations as they are, before changing them: one
    /// step for undo. Anything new also forgets what could have been
    /// redone.
    private mutating func checkpoint() {
        undoStack.append(items)
        redoStack.removeAll()
    }

    private mutating func undo() -> Effect {
        guard let previous = undoStack.popLast() else { return .none }
        redoStack.append(items)
        items = previous
        selected = nil
        return .repaint
    }

    private mutating func redo() -> Effect {
        guard let next = redoStack.popLast() else { return .none }
        undoStack.append(items)
        items = next
        selected = nil
        return .repaint
    }

    // MARK: Tools

    private mutating func setTool(_ tool: AnnotationTool) -> Effect {
        self.tool = tool
        selected = nil
        return .repaint
    }

    /// Change the colour of whatever the property row is showing: the text
    /// being typed, else the selected annotation, else the current tool. A
    /// selected annotation's change does not touch the tool's memory.
    private mutating func setColour(_ colour: Int) -> Effect {
        let colour = min(max(colour, 0), ShotStyle.colours.count - 1)
        if var box = textBox {
            box.colour = colour
            textBox = box
            prefs.setColour(colour, of: box.caption ? .number : .text)
            return .restyleText
        }
        if let i = selected, items.indices.contains(i) {
            if items[i].props == .block || items[i].colour == colour { return .none }
            checkpoint()
            items[i].colour = colour
            return .repaint
        }
        if tool.props == .none || tool.props == .block { return .none }
        prefs.setColour(colour, of: tool)
        return .repaint
    }

    /// The height of one line of text at `level`, as the host draws it.
    func textLine(level: Int, measure: TextMeasure) -> Int {
        max(measure.size(of: "M", fontPx: ShotStyle.fontPx(level: level, scale: scale)).h, 1)
    }

    /// What the text box has to stay off: both rows of the toolbar as they
    /// are while a text is typed (`ShotTextBox`).
    var textKeepClear: [PixelRect] {
        guard let selection, displays.indices.contains(selection.display) else { return [] }
        let display = displays[selection.display]
        let l = ShotToolbarGrid.layout(
            selection: selection.rect, display: display.rect, scale: display.scale, props: .font)
        return [l.bar] + (l.props.map { [$0] } ?? [])
    }

    /// Where the open text box is, for a text of `lines` lines
    /// (specification 9.3; `ShotTextBox.rect` for the rule). Nil with no
    /// box open.
    func textRect(lines: Int, measure: TextMeasure) -> PixelRect? {
        guard let box = textBox, let selection, displays.indices.contains(selection.display) else { return nil }
        let display = displays[selection.display]
        let minW = ShotTextBox.minWidth(
            fontPx: ShotStyle.fontPx(level: box.level, scale: display.scale), scale: display.scale)
        return ShotTextBox.rect(
            at: box.at, lines: lines, line: textLine(level: box.level, measure: measure), minW: minW,
            selection: selection.rect, display: display.rect, keepClear: textKeepClear)
    }

    /// Where a new text starts for a press at `p`: the press, pulled into
    /// the selection far enough for one line (`ShotTextBox.origin`).
    private func textOrigin(_ p: PixelPoint, level: Int, measure: TextMeasure) -> PixelPoint {
        guard let selection else { return p }
        let minW = ShotTextBox.minWidth(fontPx: ShotStyle.fontPx(level: level, scale: scale), scale: scale)
        return ShotTextBox.origin(
            click: p, line: textLine(level: level, measure: measure), minW: minW,
            selection: selection.rect, keepClear: textKeepClear)
    }

    private mutating func setLevel(_ level: Int, measure: TextMeasure) -> Effect {
        let level = min(max(level, 0), ShotStyle.levels - 1)
        if var box = textBox {
            // A text that is new keeps to the selection at its new size
            // too: a bigger line may no longer fit where it was started.
            // One edited again, or a number's sentence, stays where it is.
            if box.editing == nil, !box.caption { box.at = textOrigin(box.at, level: level, measure: measure) }
            box.level = level
            textBox = box
            prefs.setLevel(level, of: box.caption ? .number : .text)
            return .restyleText
        }
        if let i = selected, items.indices.contains(i) {
            if items[i].level == level { return .none }
            checkpoint()
            items[i].level = level
            // Text takes a different amount of room at a different size.
            let font = ShotStyle.fontPx(level: level, scale: scale)
            switch items[i].shape {
            case let .text(at, text, _):
                items[i].shape = .text(at: at, text: text, size: measure.size(of: text, fontPx: font))
            case let .number(n, at, text, _) where !text.isEmpty:
                items[i].shape = .number(n: n, at: at, text: text, size: measure.size(of: text, fontPx: font))
            default:
                break
            }
            return .repaint
        }
        if tool.props == .none { return .none }
        prefs.setLevel(level, of: tool)
        return .repaint
    }

    /// One step down or up from the current one, stopping at the ends.
    private mutating func stepLevel(by: Int, measure: TextMeasure) -> Effect {
        if props == .none { return .none }
        let now = current.level
        let next = min(max(now + by, 0), ShotStyle.levels - 1)
        if next == now { return .none }
        return setLevel(next, measure: measure)
    }

    /// Into long-screenshot mode: the annotations go (its result carries
    /// none), as one step that undo brings back once the mode is left.
    mutating func enterLong() -> Effect {
        guard selection != nil else { return .none }
        clearAnnotations()
        tool = .select
        live = nil
        drag = .none
        isLong = true
        return .long
    }

    private mutating func leaveLong() -> Effect {
        isLong = false
        return .leaveLong
    }

    private mutating func press(_ button: ToolbarButton, measure: TextMeasure) -> Effect {
        if isLong {
            // Only the three that mean something while frames are taken.
            switch button {
            case .long: return leaveLong()
            case .cancel: return .cancel
            case .done: return .finish
            default: return .none
            }
        }
        switch button {
        case let .tool(t): return setTool(t)
        case .undo: return undo()
        case .redo: return redo()
        case .long: return enterLong()
        case .cancel: return .cancel
        case .done: return .finish
        case let .colour(c): return setColour(c)
        case let .level(l): return setLevel(l, measure: measure)
        }
    }

    // MARK: Mouse

    /// Whether a press at `p` changes the text being typed and leaves it
    /// being typed: a colour or a size in the property row (9.3). Any other
    /// press while typing ends it.
    ///
    /// **The host asks this too, before the press arrives.** A native text
    /// control gives up the keyboard to whatever was clicked, and a host
    /// that ends the text on losing the keyboard would end it here -- in its
    /// old colour -- before `pointerDown` was ever called, leaving the
    /// swatch to change nothing but the tool's memory.
    func restylesText(at p: PixelPoint) -> Bool {
        guard textBox != nil, !isLong, let button = layout?.button(at: p) else { return false }
        switch button {
        case .colour, .level: return true
        default: return false
        }
    }

    /// The left button went down at `p`.
    mutating func pointerDown(at p: PixelPoint, mods: ShotMods, measure: TextMeasure) -> Effect {
        if isLong {
            // The selection is the live screen and clicks in it are not
            // ours; of the overlay, only the toolbar answers.
            guard let button = layout?.button(at: p) else { return .none }
            return press(button, measure: measure)
        }
        if textBox != nil {
            // A click outside the box keeps what was typed. That is all
            // this click does: the next one starts something new.
            if restylesText(at: p), let button = layout?.button(at: p) {
                return press(button, measure: measure)
            }
            return .commitText
        }
        guard let sel = selection else {
            drag = .pickRegion(down: p)
            return .capture
        }
        if let layout {
            if let button = layout.button(at: p) { return press(button, measure: measure) }
            if layout.covers(p) { return .none }
        }

        let scale = self.scale
        let reach = ShotStyle.px(6, scale: scale)
        if tool == .select || mods.contains(.command) {
            // The selected annotation's own grips come first: they sit on
            // top of everything, including other annotations.
            if let i = selected, items.indices.contains(i), let grip = items[i].grip(at: p, reach: reach) {
                drag = .reshapeItem(index: i, grip: grip, before: items, changed: false)
                return .capture
            }
            if let i = Annotation.hitTest(items, at: p, scale: scale) {
                selected = i
                drag = .moveItem(index: i, last: p, before: items, changed: false)
                return .capture
            }
            let had = selected != nil
            selected = nil
            if tool != .select {
                // Cmd+click on nothing, with a drawing tool in hand.
                return had ? .repaint : .none
            }
            switch PixelGeometry.hit(sel.rect, at: p, grip: reach) {
            case let .handle(h):
                drag = .resizeRegion(h)
                return .capture
            case .inside:
                drag = .moveRegion(last: p)
                return .capture
            case .outside:
                // Outside with nothing drawn: choose again. With
                // annotations that would be a way to lose them all by a
                // slip.
                if items.isEmpty {
                    selection = nil
                    hover = window(at: p).map { ($0.display, $0.rect) }
                    drag = .pickRegion(down: p)
                    return .capture
                }
                return had ? .repaint : .none
            }
        }

        // Outside the selection nothing is drawn, but an annotation that was
        // selected is let go of, and its grips have to go from the screen.
        let held = selected != nil
        selected = nil
        guard sel.rect.contains(p) else { return held ? .repaint : .none }
        let colour = prefs.colour(of: tool), level = prefs.level(of: tool)
        switch tool {
        case .pen:
            live = Annotation(shape: .pen([p]), colour: colour, level: level)
        case .highlighter:
            live = Annotation(shape: .highlighter([p]), colour: colour, level: level)
        case .text:
            textBox = TextBox(
                at: textOrigin(p, level: level, measure: measure),
                text: "", colour: colour, level: level, editing: nil, caption: false, fresh: false)
            return .openText
        case .number:
            // The circle and the sentence typed after it are one step.
            checkpoint()
            let n = Annotation.nextNumber(items)
            items.append(Annotation(shape: .number(n: n, at: p, text: "", size: .zero), colour: colour, level: level))
            let at = Annotation.captionOrigin(
                at: p, level: level, scale: scale, captionHeight: ShotStyle.fontPx(level: level, scale: scale))
            textBox = TextBox(
                at: at, text: "", colour: colour, level: level, editing: items.count - 1, caption: true, fresh: true)
            return .openText
        default:
            live = nil
            drag = .draw(start: p)
            return .capture
        }
        drag = .stroke
        return .capture
    }

    /// The shape a drag from `start` to `end` draws with the current tool.
    private func drawn(from start: PixelPoint, to end: PixelPoint, shift: Bool) -> Annotation? {
        let colour = prefs.colour(of: tool), level = prefs.level(of: tool)
        let corner = shift ? Annotation.squareCorner(from: start, to: end) : end
        let tip = shift ? Annotation.snap45(from: start, to: end) : end
        let shape: Annotation.Shape
        switch tool {
        case .rect: shape = .rect(.spanning(start, corner))
        case .ellipse: shape = .ellipse(.spanning(start, corner))
        case .mosaic: shape = .mosaic(.spanning(start, end))
        case .line: shape = .line(from: start, to: tip)
        case .arrow: shape = .arrow(from: start, to: tip)
        default: return nil
        }
        return Annotation(shape: shape, colour: colour, level: level)
    }

    /// The pointer moved to `p`.
    mutating func pointerMove(to p: PixelPoint, mods: ShotMods) -> Effect {
        if textBox != nil { return .none }
        switch drag {
        case .none:
            if selection != nil {
                let over = layout?.button(at: p)
                if over == hoverButton { return .none }
                hoverButton = over
                return .repaint
            }
            let next = window(at: p).map { (display: $0.display, rect: $0.rect) }
            if next?.display == hover?.display && next?.rect == hover?.rect { return .none }
            hover = next

        case let .pickRegion(down):
            if !PixelGeometry.isDrag(from: down, to: p) { return .none }
            // Confined to the display the drag started on.
            guard let d = display(at: down) else { return .none }
            forming = PixelGeometry.dragSelection(from: down, to: p, within: displays[d].rect).map { ($0, d) }

        case let .resizeRegion(handle):
            if var sel = selection {
                sel.rect = PixelGeometry.resize(sel.rect, dragging: handle, to: p, within: displays[sel.display].rect)
                sel.window = nil
                selection = sel
            }

        case let .moveRegion(last):
            drag = .moveRegion(last: p)
            if var sel = selection {
                sel.rect = PixelGeometry.move(
                    sel.rect, by: PixelPoint(p.x - last.x, p.y - last.y), within: displays[sel.display].rect)
                sel.window = nil
                selection = sel
            }

        case let .draw(start):
            live = drawn(from: start, to: p, shift: mods.contains(.shift))

        case .stroke:
            guard var item = live else { break }
            switch item.shape {
            case var .pen(points):
                if points.last == p { return .none }
                points.append(p)
                item.shape = .pen(points)
            case var .highlighter(points):
                if points.last == p { return .none }
                points.append(p)
                item.shape = .highlighter(points)
            default:
                break
            }
            live = item

        case let .moveItem(index, last, before, _):
            let dx = p.x - last.x, dy = p.y - last.y
            if dx == 0 && dy == 0 { return .none }
            drag = .moveItem(index: index, last: p, before: before, changed: true)
            items[index] = items[index].moved(dx: dx, dy: dy)

        case let .reshapeItem(index, grip, before, _):
            let next = items[index].reshaped(grip, to: p)
            if next == items[index] { return .none }
            drag = .reshapeItem(index: index, grip: grip, before: before, changed: true)
            items[index] = next
        }
        return .repaint
    }

    /// The left button came up at `p`.
    mutating func pointerUp(at p: PixelPoint) -> Effect {
        let ended = drag
        drag = .none
        switch ended {
        case .none:
            return .none
        case .pickRegion:
            if let forming {
                selection = Selection(rect: forming.rect, display: forming.display, window: nil)
            } else {
                // A click: the window under it, as it was frozen. Asked of
                // the click's own position, not taken from `hover`, which
                // is only as fresh as the last mouse move.
                selection = window(at: p)
            }
            forming = nil
            hover = nil
        case .resizeRegion, .moveRegion:
            break
        case .draw, .stroke:
            let made = live
            live = nil
            if let made, !made.isDegenerate {
                checkpoint()
                items.append(made)
            }
        case let .moveItem(_, _, before, changed), let .reshapeItem(_, _, before, changed):
            // One drag is one step, however many moves it was made of.
            if changed {
                undoStack.append(before)
                redoStack.removeAll()
            }
        }
        return .release
    }

    /// A double click at `p` (the host sends this instead of the second
    /// button-down).
    mutating func doubleClick(at p: PixelPoint, mods: ShotMods, measure: TextMeasure) -> Effect {
        if isLong { return pointerDown(at: p, mods: mods, measure: measure) }
        // While typing, the second of two quick clicks is a click: two
        // swatches tried one after the other must not end the text.
        if textBox != nil { return pointerDown(at: p, mods: mods, measure: measure) }
        guard let sel = selection else { return pointerDown(at: p, mods: mods, measure: measure) }
        if layout?.covers(p) == true { return pointerDown(at: p, mods: mods, measure: measure) }

        if tool == .select || mods.contains(.command) {
            let scale = self.scale
            if let i = Annotation.hitTest(items, at: p, scale: scale) {
                // Text is edited again where it stands; so is a number's
                // sentence.
                let item = items[i]
                let at: PixelPoint, text: String, caption: Bool
                switch item.shape {
                case let .text(textAt, body, _):
                    (at, text, caption) = (textAt, body, false)
                case let .number(_, numberAt, body, size):
                    let h = size.h > 0 ? size.h : ShotStyle.fontPx(level: item.level, scale: scale)
                    at = Annotation.captionOrigin(at: numberAt, level: item.level, scale: scale, captionHeight: h)
                    (text, caption) = (body, true)
                default:
                    return pointerDown(at: p, mods: mods, measure: measure)
                }
                selected = i
                textBox = TextBox(
                    at: at, text: text, colour: item.colour, level: item.level,
                    editing: i, caption: caption, fresh: false)
                return .openText
            }
            if tool == .select && sel.rect.contains(p) { return .finish }
        }
        // With a drawing tool in hand it is just the second of two clicks.
        return pointerDown(at: p, mods: mods, measure: measure)
    }

    /// The text box closed with `text` in it. Call after `.commitText`, and
    /// when the box ends itself (Cmd+Enter, Esc, losing the keyboard).
    ///
    /// **A second call for the same box does nothing.** Closing a native
    /// text control makes it give up the keyboard, and a host that commits
    /// on losing the keyboard is then called again from inside its own
    /// commit, with a box that has already been emptied. The box is taken
    /// here first, so that second call finds none and cannot end the text
    /// with an empty string in place of what was typed.
    mutating func endText(_ text: String, measure: TextMeasure) -> Effect {
        guard let box = textBox else { return .none }
        textBox = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let font = ShotStyle.fontPx(level: box.level, scale: scale)
        let size = text.isEmpty ? Annotation.PixelSize.zero : measure.size(of: text, fontPx: font)

        if let i = box.editing {
            guard items.indices.contains(i) else { return .repaint }
            var next = items[i]
            next.colour = box.colour
            next.level = box.level
            switch next.shape {
            case let .number(n, at, _, _):
                next.shape = .number(n: n, at: at, text: text, size: size)
            case let .text(at, _, _):
                next.shape = .text(at: at, text: text, size: size)
            default:
                return .repaint
            }
            if next == items[i] { return .repaint }
            // A number just placed already made its step; anything else
            // that changes is a step of its own.
            if !box.fresh { checkpoint() }
            if next.isDegenerate {
                // A text edited down to nothing is deleted.
                items.remove(at: i)
                selected = nil
            } else {
                items[i] = next
            }
        } else if !text.isEmpty {
            checkpoint()
            items.append(Annotation(
                shape: .text(at: box.at, text: text, size: size), colour: box.colour, level: box.level))
        }
        return .repaint
    }

    /// The right button: step back once (9.4). Out of the text box, then
    /// out of a selected annotation, then out of the tool, then -- only
    /// when nothing has been drawn -- out of the selection, then out of the
    /// screenshot. **With annotations it stops before the selection**, so a
    /// stray right click cannot take them all.
    mutating func rightClick() -> Effect {
        if isLong { return leaveLong() }
        if textBox != nil { return .commitText }
        if selected != nil {
            selected = nil
            return .repaint
        }
        if tool != .select { return setTool(.select) }
        if !items.isEmpty { return .none }
        if selection != nil || forming != nil {
            selection = nil
            forming = nil
            live = nil
            drag = .none
            hoverButton = nil
            return .release
        }
        return .cancel
    }

    // MARK: Keys

    /// A key went down while the overlay (not the text box) had the
    /// keyboard. Returns what the key was taken for, for the log, and what
    /// to do.
    mutating func key(_ input: EditorKey.Input, mods: ShotMods, measure: TextMeasure) -> (key: EditorKey, effect: Effect) {
        let key = EditorKey.of(input, mods: mods, hasSelection: selection != nil)
        let effect: Effect
        switch key {
        case .cancel:
            effect = .cancel
        case .finish:
            effect = .finish
        // While frames are taken nothing else is a command.
        case _ where isLong:
            effect = .none
        case .undo:
            effect = undo()
        case .redo:
            effect = redo()
        // Tools, colours and sizes mean nothing before there is a selection
        // to use them on.
        case .tool where selection == nil, .colour where selection == nil, .step where selection == nil:
            effect = .none
        case let .tool(t):
            effect = setTool(t)
        case let .colour(c):
            effect = setColour(c)
        case let .step(by):
            effect = stepLevel(by: by, measure: measure)
        case .delete:
            if let i = selected, items.indices.contains(i) {
                selected = nil
                checkpoint()
                items.remove(at: i)
                effect = .repaint
            } else {
                selected = nil
                effect = .none
            }
        case let .nudge(dx, dy):
            if let i = selected, items.indices.contains(i) {
                checkpoint()
                items[i] = items[i].moved(dx: dx, dy: dy)
                effect = .repaint
            } else {
                effect = .none
            }
        case .ignored:
            effect = .none
        }
        return (key, effect)
    }

    // MARK: Export

    /// Remove every annotation, as one step that undo brings back
    /// (entering long-screenshot mode, whose result carries none).
    mutating func clearAnnotations() {
        if !items.isEmpty {
            checkpoint()
            items.removeAll()
        }
        selected = nil
    }

    /// What leaves: the selection, and the annotations that reach into it.
    func export() -> Export? {
        guard let selection else { return nil }
        let scale = self.scale
        let onScreen = drawOrder.map(\.item).filter { $0.bounds(scale: scale).intersect(selection.rect) != nil }
        return Export(
            selection: selection, scale: scale, onScreen: onScreen,
            onImage: Annotation.exported(items, selection: selection.rect, scale: scale))
    }
}
