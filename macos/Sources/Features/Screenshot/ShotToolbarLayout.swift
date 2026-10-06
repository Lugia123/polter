import Foundation

/// Everything on the toolbar that can be pressed.
enum ToolbarButton: Equatable, Hashable {
    case tool(AnnotationTool)
    case undo
    case redo
    case long
    case cancel
    case done
    /// A colour swatch on the property row.
    case colour(Int)
    /// A step of thickness, font size or block size on the property row.
    case level(Int)
}

/// The two-row toolbar: where each button is, what it is called and what
/// its hover text says (`dev-docs/poltergeist/screenshot.md`, 9.1, 9.7 and
/// 9.8.2). A port of the Windows host's `toolbar.rs`; see
/// `PixelGeometry.swift`.
///
/// The first row is the tools and the commands; the second is the
/// properties of the current tool, or of the selected annotation. The two
/// rows are one plate, as wide as the first row whatever the second holds.
/// **Everything that can be pressed is a cell of the same size** -- a
/// colour and a step of a size as much as a tool -- on one grid. The
/// numbers are the generated `ShotLook.Size`, in points.
enum ShotToolbarGrid {
    static let button = Int(ShotLook.Size.button)
    static let gap = Int(ShotLook.Size.gap)
    static let groupGap = Int(ShotLook.Size.groupGap)
    static let padding = Int(ShotLook.Size.padding)
    /// Between the two rows: none, they are one plate.
    static let rowGap = Int(ShotLook.Size.rowGap)
    /// Between the selection and the toolbar.
    static let offset = Int(ShotLook.Size.offset)

    /// The gap between the rows in pixels. `ShotStyle.px` never gives less
    /// than one, which is right for a line and wrong for a gap of nothing.
    static func rowGapPx(_ scale: Double) -> Int {
        rowGap > 0 ? ShotStyle.px(rowGap, scale: scale) : 0
    }

    /// The first row's groups, left to right.
    static let row: [[ToolbarButton]] = [
        [.tool(.select)],
        [
            .tool(.rect), .tool(.ellipse), .tool(.line), .tool(.arrow), .tool(.pen),
            .tool(.highlighter), .tool(.text), .tool(.number), .tool(.mosaic),
        ],
        [.undo, .redo],
        [.long],
        [.cancel, .done],
    ]

    /// Where everything on the toolbar is, in the display's pixels.
    struct Layout: Equatable {
        /// The first row.
        var bar: PixelRect
        /// The property row, when it is shown: under the first, and as
        /// wide.
        var props: PixelRect?
        var buttons: [Placed]

        struct Placed: Equatable {
            var button: ToolbarButton
            var rect: PixelRect
        }

        func button(at p: PixelPoint) -> ToolbarButton? {
            buttons.first { $0.rect.contains(p) }?.button
        }

        /// Whether `p` is on the toolbar at all -- a click there is the
        /// toolbar's even between two buttons, not a stroke on the picture.
        func covers(_ p: PixelPoint) -> Bool {
            bar.contains(p) || (props?.contains(p) ?? false)
        }

        func rect(of button: ToolbarButton) -> PixelRect? {
            buttons.first { $0.button == button }?.rect
        }

        /// The plate: both rows when the second is showing, the first
        /// otherwise.
        var plate: PixelRect {
            guard let props else { return bar }
            return PixelRect(left: bar.x, top: bar.y, right: bar.right, bottom: props.bottom)
        }
    }

    /// The size both rows take together, in pixels: what is kept clear for
    /// the toolbar whether or not the property row is showing, so that
    /// picking a tool does not make it jump.
    static func footprint(scale: Double) -> (w: Int, h: Int) {
        func px(_ points: Int) -> Int { ShotStyle.px(points, scale: scale) }
        let buttons = row.map(\.count).reduce(0, +)
        let innerGaps = row.map { $0.count - 1 }.reduce(0, +)
        let width = px(padding) * 2 + buttons * px(button) + innerGaps * px(gap) + (row.count - 1) * px(groupGap)
        let rowHeight = px(button) + px(padding) * 2
        return (width, rowHeight * 2 + rowGapPx(scale))
    }

    /// Lay the toolbar out beside `selection` on `display`: below it, or
    /// above, or inside its bottom edge. `props` is which property row to
    /// show.
    static func layout(selection: PixelRect, display: PixelRect, scale: Double, props: AnnotationTool.Props) -> Layout {
        func px(_ points: Int) -> Int { ShotStyle.px(points, scale: scale) }
        let size = footprint(scale: scale)
        let origin = PixelGeometry.toolbarOrigin(for: selection, bar: size, within: display, gap: px(offset))
        let rowHeight = px(button) + px(padding) * 2

        var buttons: [Layout.Placed] = []
        var x = origin.x + px(padding)
        let y = origin.y + px(padding)
        for (g, group) in row.enumerated() {
            if g > 0 { x += px(groupGap) - px(gap) }
            for item in group {
                buttons.append(.init(button: item, rect: PixelRect(x, y, px(button), px(button))))
                x += px(button) + px(gap)
            }
        }
        let bar = PixelRect(origin.x, origin.y, size.w, rowHeight)

        var propsRect: PixelRect?
        if props != .none {
            let top = origin.y + rowHeight + rowGapPx(scale)
            var x = origin.x + px(padding)
            if props != .block {
                // A colour is a cell like any other; the swatch is drawn
                // smaller, inside it.
                for c in 0..<ShotStyle.colours.count {
                    buttons.append(.init(button: .colour(c), rect: PixelRect(x, top + px(padding), px(button), px(button))))
                    x += px(button) + px(gap)
                }
                x += px(groupGap) - px(gap)
            }
            for l in 0..<ShotStyle.levels {
                buttons.append(.init(button: .level(l), rect: PixelRect(x, top + px(padding), px(button), px(button))))
                x += px(button) + px(gap)
            }
            propsRect = PixelRect(origin.x, top, size.w, rowHeight)
        }
        return Layout(bar: bar, props: propsRect, buttons: buttons)
    }

    // MARK: Names

    /// The nine colours' names, in palette order. Msgids of
    /// `src/input/screenshot.zig`.
    static let colourNames = ["Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Black", "White"]

    /// A button's name: the English msgid, which the host translates.
    /// `props` is the property row that is showing, which is what a step
    /// button is a step *of*.
    static func name(of button: ToolbarButton, props: AnnotationTool.Props) -> String {
        switch button {
        case .tool(.select): return "Select"
        case .tool(.rect): return "Rectangle"
        case .tool(.ellipse): return "Ellipse"
        case .tool(.line): return "Straight Line"
        case .tool(.arrow): return "Arrow"
        case .tool(.pen): return "Pen"
        case .tool(.highlighter): return "Highlighter"
        case .tool(.text): return "Text"
        case .tool(.number): return "Number"
        case .tool(.mosaic): return "Mosaic"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .long: return "Long Screenshot"
        case .cancel: return "Cancel"
        case .done: return "Done"
        case let .colour(c): return colourNames[((c % colourNames.count) + colourNames.count) % colourNames.count]
        case .level:
            switch props {
            case .font: return "Font Size"
            case .block: return "Block Size"
            case .stroke, .none: return "Thickness"
            }
        }
    }

    /// The key that does what the button does, as it is written on a Mac
    /// keyboard; nil when there is none.
    static func shortcut(of button: ToolbarButton) -> String? {
        switch button {
        case let .tool(t): return String(t.letter)
        case .undo: return "⌘Z"
        case .redo: return "⇧⌘Z"
        case .cancel: return "Esc"
        case .done: return "Enter"
        case let .colour(c): return "\(c + 1)"
        case .long, .level: return nil
        }
    }

    /// The hover text: `Rectangle (R)`, or just the name when no key does
    /// it. `translate` turns the English name into the app's language.
    static func tooltip(for button: ToolbarButton, props: AnnotationTool.Props, translate: (String) -> String) -> String {
        let name = translate(name(of: button, props: props))
        guard let key = shortcut(of: button) else { return name }
        return "\(name) (\(key))"
    }
}

/// What a key means to the editor.
enum EditorKey: Equatable {
    /// Leave without a trace.
    case cancel
    /// Take the selection as it is.
    case finish
    case undo
    case redo
    /// Pick up a tool.
    case tool(AnnotationTool)
    /// The n-th colour, counted from 0.
    case colour(Int)
    /// One step thinner or smaller (-1), or thicker or larger (+1).
    case step(Int)
    /// Delete the selected annotation.
    case delete
    /// Move the selected annotation by this many pixels.
    case nudge(dx: Int, dy: Int)
    case ignored

    /// A key as the host saw it, without the host's key codes.
    enum Input: Equatable {
        case escape, enter, delete
        case left, right, up, down
        case bracketLeft, bracketRight
        /// A letter, either case.
        case letter(Character)
        /// A digit key, top row or number pad.
        case digit(Int)
        case other
    }

    /// What `input` with `mods` held means (9.2). `command` is the key the
    /// specification calls `cmd/ctrl`.
    ///
    /// Undo and redo need **exactly** their modifiers; the arrows take
    /// shift and nothing else; every other key means something only with
    /// nothing held, so that a chord meant for something else is not read
    /// as a tool.
    static func of(_ input: Input, mods: ShotMods, hasSelection: Bool) -> EditorKey {
        let mods = mods.intersection(.all)
        let plain = mods.isEmpty
        let shiftOnly = mods == [.shift]
        let step = shiftOnly ? 10 : 1

        switch input {
        case .escape:
            return .cancel
        case .enter:
            return hasSelection && plain ? .finish : .ignored
        case .letter("z") where mods == [.command], .letter("Z") where mods == [.command]:
            return .undo
        case .letter("z") where mods == [.command, .shift], .letter("Z") where mods == [.command, .shift]:
            return .redo
        case .left where plain || shiftOnly: return .nudge(dx: -step, dy: 0)
        case .right where plain || shiftOnly: return .nudge(dx: step, dy: 0)
        case .up where plain || shiftOnly: return .nudge(dx: 0, dy: -step)
        case .down where plain || shiftOnly: return .nudge(dx: 0, dy: step)
        default:
            break
        }
        guard plain else { return .ignored }

        switch input {
        case .delete: return .delete
        case .bracketLeft: return .step(-1)
        case .bracketRight: return .step(1)
        case let .digit(n) where (1...9).contains(n): return .colour(n - 1)
        case let .letter(c): return AnnotationTool(letter: c).map(EditorKey.tool) ?? .ignored
        default: return .ignored
        }
    }
}
