import Foundation
import Testing
@testable import Ghostty

/// Ten pixels a character wide, one font-height a line tall.
private struct FakeMeasure: TextMeasure {
    func size(of text: String, fontPx: Int) -> Annotation.PixelSize {
        let lines = text.components(separatedBy: "\n")
        return .init((lines.map(\.count).max() ?? 0) * 10, lines.count * fontPx)
    }
}

/// An editor and the hands that drive it. A class, so that a step and the
/// expectation about what it returned can be one line.
private final class Rig {
    typealias Pt = PixelPoint

    static let display = PixelRect(0, 0, 2560, 1440)
    /// A window to select, and the desktop behind it.
    static let window = PixelRect(400, 200, 900, 500)

    var editor: ShotEditor
    let measure = FakeMeasure()

    init(_ editor: ShotEditor) { self.editor = editor }

    /// Nothing selected yet.
    static func fresh() -> Rig {
        Rig(ShotEditor(
            displays: [.init(rect: display, scale: 1)],
            windows: [.init(id: 7, rect: window), .init(id: 1, rect: display)],
            prefs: ToolPrefs()))
    }

    /// With `window` selected.
    static func selected() -> Rig {
        let rig = fresh()
        rig.click(Pt(500, 300))
        if rig.editor.selection?.rect != window { Issue.record("the fixture's window is not selected") }
        return rig
    }

    /// With `window` selected, two rectangles drawn and the rectangle tool
    /// still in hand.
    static func withTwoRects() -> Rig {
        let rig = selected()
        rig.letter("R")
        rig.drag(Pt(500, 300), Pt(600, 380))
        rig.drag(Pt(700, 300), Pt(800, 380))
        return rig
    }

    @discardableResult
    func down(_ p: Pt, _ mods: ShotMods = []) -> ShotEditor.Effect {
        editor.pointerDown(at: p, mods: mods, measure: measure)
    }

    @discardableResult
    func move(_ p: Pt, _ mods: ShotMods = []) -> ShotEditor.Effect {
        editor.pointerMove(to: p, mods: mods)
    }

    @discardableResult
    func up(_ p: Pt) -> ShotEditor.Effect {
        editor.pointerUp(at: p)
    }

    /// Down and up at one place; what the press answered.
    @discardableResult
    func click(_ p: Pt, _ mods: ShotMods = []) -> ShotEditor.Effect {
        let effect = down(p, mods)
        up(p)
        return effect
    }

    @discardableResult
    func double(_ p: Pt, _ mods: ShotMods = []) -> ShotEditor.Effect {
        editor.doubleClick(at: p, mods: mods, measure: measure)
    }

    func drag(_ from: Pt, _ to: Pt, _ mods: ShotMods = []) {
        down(from, mods)
        move(Pt((from.x + to.x) / 2, (from.y + to.y) / 2), mods)
        move(to, mods)
        up(to)
    }

    @discardableResult
    func key(_ input: EditorKey.Input, _ mods: ShotMods = []) -> ShotEditor.Effect {
        editor.key(input, mods: mods, measure: measure).effect
    }

    @discardableResult
    func letter(_ c: Character) -> ShotEditor.Effect { key(.letter(c)) }

    @discardableResult
    func undo() -> ShotEditor.Effect { key(.letter("z"), [.command]) }

    @discardableResult
    func redo() -> ShotEditor.Effect { key(.letter("z"), [.command, .shift]) }

    @discardableResult
    func rightClick() -> ShotEditor.Effect { editor.rightClick() }

    /// Click a toolbar button.
    @discardableResult
    func press(_ button: ToolbarButton) -> ShotEditor.Effect {
        guard let r = editor.layout?.rect(of: button) else {
            Issue.record("\(button) is not on the toolbar")
            return .none
        }
        return click(Pt(r.x + 2, r.y + 2))
    }

    /// Press a button on the property row without letting the button up:
    /// what a click does while the text box is open.
    @discardableResult
    func touch(_ button: ToolbarButton) -> ShotEditor.Effect {
        guard let r = editor.layout?.rect(of: button) else {
            Issue.record("\(button) is not on the toolbar")
            return .none
        }
        return down(Pt(r.x + 1, r.y + 1))
    }

    /// Commit the open text box with `text` in it.
    @discardableResult
    func type(_ text: String) -> ShotEditor.Effect {
        if editor.textBox == nil { Issue.record("no text box is open") }
        return editor.endText(text, measure: measure)
    }

    /// What the host does when the box ends on its own, whether or not one
    /// is open.
    @discardableResult
    func end(_ text: String) -> ShotEditor.Effect {
        editor.endText(text, measure: measure)
    }

    var items: [Annotation] { editor.items }
    var shapes: [Annotation.Shape] { editor.items.map(\.shape) }

    /// Annotation `index`, or nil when there are not that many: a test that
    /// is wrong about how many there are should fail, not stop the run.
    func item(_ index: Int) -> Annotation? {
        editor.items.indices.contains(index) ? editor.items[index] : nil
    }

    func shape(_ index: Int) -> Annotation.Shape? { item(index)?.shape }

    func box(_ index: Int) -> PixelRect? {
        switch shape(index) {
        case let .rect(r), let .ellipse(r), let .mosaic(r): return r
        default: return nil
        }
    }

    func style(_ index: Int) -> [Int] { item(index).map { [$0.colour, $0.level] } ?? [] }
}

/// The Windows host's `editor.rs` tests, with the same fixtures and the
/// same numbers (`dev-docs/poltergeist/screenshot.md`, 3.2 and section 9).
/// Where they say Ctrl, this says Command.
struct ShotEditorTests {
    private typealias Pt = PixelPoint
    private let display = Rig.display
    private let window = Rig.window

    // MARK: Selecting

    @Test func aClickSelectsTheWindowUnderItAndADragARegion() {
        var rig = Rig.fresh()
        #expect(rig.move(Pt(500, 300)) == .repaint)
        #expect(rig.editor.hover?.display == 0)
        #expect(rig.editor.hover?.rect == window)
        #expect(rig.move(Pt(520, 310)) == .none, "still the same window")
        #expect(rig.move(Pt(2000, 1000)) == .repaint)
        #expect(rig.editor.hover?.rect == display)
        rig.click(Pt(500, 300))
        #expect(rig.editor.hover == nil, "nothing is offered once something is chosen")
        #expect(rig.editor.selection == .init(rect: window, display: 0, window: 7))
        #expect(rig.editor.tool == .select, "the tool a session starts with")

        rig = Rig.fresh()
        rig.drag(Pt(100, 100), Pt(300, 250))
        #expect(rig.editor.selection == .init(rect: PixelRect(100, 100, 200, 150), display: 0, window: nil))
    }

    @Test func aClickSelectsWhatIsUnderItEvenWithNoMouseMoveBefore() {
        let rig = Rig.fresh()
        // No move: `hover` was never set.
        rig.click(Pt(2000, 1000))
        #expect(rig.editor.selection == .init(rect: display, display: 0, window: 1))
    }

    @Test func aPressStartsADragAndTheReleaseEndsIt() {
        let rig = Rig.fresh()
        #expect(rig.down(Pt(100, 100)) == .capture)
        // Under the threshold it is still a click.
        #expect(rig.move(Pt(102, 101)) == .none)
        #expect(rig.editor.forming == nil)
        #expect(rig.move(Pt(300, 250)) == .repaint)
        #expect(rig.editor.forming?.rect == PixelRect(100, 100, 200, 150))
        #expect(rig.up(Pt(300, 250)) == .release)
        #expect(rig.editor.forming == nil)
        #expect(rig.editor.hover == nil)
        #expect(rig.up(Pt(300, 250)) == .none, "no drag, nothing to end")
    }

    @Test func aMouseTriggerOpensWithTheWindowUnderItSelected() {
        let displays = [ShotEditor.Display(rect: display, scale: 1)]
        let windows = [ShotEditor.Window(id: 7, rect: window)]
        var editor = ShotEditor(displays: displays, windows: windows, prefs: ToolPrefs(), preselect: Pt(500, 300))
        #expect(editor.selection?.window == 7)
        #expect(editor.windowRect(7) == window)
        #expect(editor.windowRect(8) == nil)
        editor = ShotEditor(displays: displays, windows: windows, prefs: ToolPrefs(), preselect: Pt(10, 10))
        #expect(editor.selection == nil, "nothing under the pointer")
    }

    @Test func inTheSelectToolTheSelectionCanBeMovedAndResizedEvenWithAnnotations() {
        let rig = Rig.selected()
        rig.letter("R")
        rig.drag(Pt(500, 300), Pt(600, 380))
        rig.letter("V")
        // Drag the inside: the selection moves, the annotation does not.
        rig.drag(Pt(900, 600), Pt(950, 650))
        #expect(rig.editor.selection?.rect == PixelRect(450, 250, 900, 500))
        #expect(rig.editor.selection?.window == nil, "it is no longer exactly that window")
        #expect(rig.box(0) == PixelRect(500, 300, 100, 80), "annotations are in screen coordinates")
        // Drag its bottom right handle.
        rig.drag(Pt(1350, 750), Pt(1250, 700))
        #expect(rig.editor.selection?.rect == PixelRect(450, 250, 800, 450))
        #expect(rig.items.count == 1)
    }

    @Test func resizingAWindowSelectionMakesItNoLongerThatWindow() {
        let rig = Rig.selected()
        #expect(rig.editor.selection?.window == 7)
        rig.drag(Pt(1300, 700), Pt(1200, 650))
        #expect(rig.editor.selection == .init(rect: PixelRect(400, 200, 800, 450), display: 0, window: nil))
    }

    @Test func theSelectionsHandlesAreNotLiveWhileADrawingToolIsInHand() {
        let rig = Rig.selected()
        rig.letter("R")
        // A drag starting exactly on the selection's top left corner draws.
        rig.drag(Pt(400, 200), Pt(500, 300))
        #expect(rig.editor.selection?.rect == window, "the selection did not move")
        #expect(rig.box(0) == PixelRect(400, 200, 100, 100))
    }

    @Test func clickingOutsideReselectsOnlyWhileNothingIsDrawn() {
        var rig = Rig.selected()
        rig.click(Pt(2000, 1000))
        #expect(rig.editor.selection?.rect == display, "picked again: the desktop")

        rig = Rig.selected()
        rig.letter("R")
        rig.drag(Pt(500, 300), Pt(600, 380))
        rig.letter("V")
        #expect(rig.click(Pt(2000, 1000)) == .none)
        #expect(rig.editor.selection?.rect == window, "with an annotation, a click outside does nothing")
    }

    // MARK: Drawing

    @Test func eachDrawingToolDrawsItsOwnShape() {
        let cases: [(Character, Annotation.Shape)] = [
            ("R", .rect(PixelRect(500, 300, 100, 80))),
            ("O", .ellipse(PixelRect(500, 300, 100, 80))),
            ("M", .mosaic(PixelRect(500, 300, 100, 80))),
            ("L", .line(from: Pt(500, 300), to: Pt(600, 380))),
            ("A", .arrow(from: Pt(500, 300), to: Pt(600, 380))),
        ]
        for (c, shape) in cases {
            let rig = Rig.selected()
            rig.letter(c)
            rig.drag(Pt(500, 300), Pt(600, 380))
            #expect(rig.shapes == [shape], "\(c)")
            #expect(rig.editor.selected == nil, "a new shape is not selected")
            #expect(rig.editor.tool == AnnotationTool(letter: c), "the tool stays in hand")
            #expect(rig.editor.live == nil)
        }
        let points = [Pt(500, 300), Pt(550, 340), Pt(600, 380)]
        for (c, shape) in [("P" as Character, Annotation.Shape.pen(points)), ("H", .highlighter(points))] {
            let rig = Rig.selected()
            rig.letter(c)
            rig.drag(Pt(500, 300), Pt(600, 380))
            #expect(rig.shapes == [shape], "\(c)")
        }
    }

    @Test func whatIsBeingDrawnShowsBeforeTheButtonComesUp() {
        let rig = Rig.selected()
        rig.letter("R")
        #expect(rig.down(Pt(500, 300)) == .capture)
        #expect(rig.editor.live == nil)
        #expect(rig.move(Pt(560, 340)) == .repaint)
        #expect(rig.editor.live?.shape == .rect(PixelRect(500, 300, 60, 40)))
        #expect(rig.items.isEmpty, "not an annotation until it is finished")
        rig.up(Pt(560, 340))

        rig.letter("P")
        #expect(rig.down(Pt(700, 300)) == .capture)
        #expect(rig.editor.live?.shape == .pen([Pt(700, 300)]))
        #expect(rig.move(Pt(700, 300)) == .none, "the pointer did not move")
        #expect(rig.move(Pt(710, 305)) == .repaint)
        #expect(rig.editor.live?.shape == .pen([Pt(700, 300), Pt(710, 305)]))
        rig.up(Pt(710, 305))

        rig.letter("H")
        rig.down(Pt(700, 400))
        #expect(rig.move(Pt(700, 400)) == .none)
        #expect(rig.move(Pt(710, 400)) == .repaint)
        #expect(rig.editor.live?.shape == .highlighter([Pt(700, 400), Pt(710, 400)]))
    }

    @Test func aShapeTakesItsToolsColourAndStep() {
        let rig = Rig.selected()
        rig.letter("R")
        rig.key(.digit(6)) // blue
        rig.key(.bracketRight) // one step thicker
        rig.drag(Pt(500, 300), Pt(600, 380))
        #expect(rig.style(0) == [5, 2])
        // The ellipse tool was not touched.
        rig.letter("O")
        rig.drag(Pt(700, 300), Pt(800, 380))
        #expect(rig.style(1) == [0, 1])
        #expect(rig.editor.prefs.colour(of: .rect) == 5, "and the rectangle tool remembers")
        #expect(rig.editor.current.colour == 0)
        rig.letter("R")
        #expect(rig.editor.current.colour == 5)
        #expect(rig.editor.current.level == 2)
    }

    @Test func shiftConstrainsWhileDrawing() {
        let rig = Rig.selected()
        rig.letter("R")
        rig.drag(Pt(500, 300), Pt(600, 340), [.shift])
        #expect(rig.box(0) == PixelRect(500, 300, 100, 100), "a square")
        rig.letter("O")
        rig.drag(Pt(700, 300), Pt(730, 380), [.shift])
        #expect(rig.box(1) == PixelRect(700, 300, 80, 80), "a circle")
        rig.letter("L")
        rig.drag(Pt(500, 500), Pt(600, 506), [.shift])
        #expect(rig.shape(2) == .line(from: Pt(500, 500), to: Pt(600, 500)), "horizontal")
        rig.letter("M")
        rig.drag(Pt(900, 300), Pt(1000, 340), [.shift])
        #expect(rig.box(3) == PixelRect(900, 300, 100, 40), "a mosaic is not squared")
    }

    @Test func somethingTooSmallIsNotKeptAndIsNotAStep() {
        let rig = Rig.selected()
        rig.letter("R")
        rig.drag(Pt(500, 300), Pt(501, 400))
        rig.letter("L")
        rig.click(Pt(500, 300))
        rig.letter("P")
        rig.click(Pt(500, 300))
        #expect(rig.items.isEmpty)
        #expect(!rig.editor.canUndo)
    }

    @Test func aDrawingStartsOnlyInsideTheSelectionButMayRunOutOfIt() {
        let rig = Rig.selected()
        rig.letter("R")
        #expect(rig.down(Pt(100, 100)) == .none)
        rig.up(Pt(100, 100))
        rig.drag(Pt(100, 100), Pt(200, 200))
        #expect(rig.items.isEmpty, "started outside")
        rig.drag(Pt(1200, 600), Pt(1500, 900))
        #expect(rig.box(0) == PixelRect(1200, 600, 300, 300), "ran past the selection's corner at 1300,700")
    }

    // MARK: Selecting annotations

    @Test func theSelectToolSelectsByTheStrokeAndDragsToMove() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        rig.click(Pt(500, 340))
        #expect(rig.editor.selected == 0, "clicked the first rectangle's left edge")
        rig.click(Pt(550, 340))
        #expect(rig.editor.selected == nil, "its inside is not it")
        rig.drag(Pt(700, 340), Pt(720, 350))
        #expect(rig.editor.selected == 1)
        #expect(rig.box(1) == PixelRect(720, 310, 100, 80))
        #expect(rig.editor.selection?.rect == window, "the selection region did not move with it")
    }

    @Test func commandClickSelectsWithAnyToolInHand() {
        let rig = Rig.withTwoRects()
        #expect(rig.editor.tool == .rect)
        #expect(rig.click(Pt(500, 340), [.command]) == .capture)
        #expect(rig.editor.selected == 0)
        #expect(rig.items.count == 2, "and did not draw a third")
        #expect(rig.editor.tool == .rect)
        // Command+click on nothing lets go of it, and still draws nothing.
        #expect(rig.click(Pt(900, 600), [.command]) == .repaint)
        #expect(rig.editor.selected == nil)
        #expect(rig.items.count == 2)
        #expect(rig.click(Pt(900, 600), [.command]) == .none, "nothing was selected to let go of")
        // Shift is not the key.
        rig.click(Pt(500, 340), [.shift])
        #expect(rig.editor.selected == nil)
    }

    @Test func aSelectedBoxIsReshapedByItsHandlesAndALineByItsEnds() {
        var rig = Rig.withTwoRects()
        rig.letter("V")
        rig.click(Pt(500, 340))
        rig.drag(Pt(600, 380), Pt(650, 420)) // its bottom right handle
        #expect(rig.box(0) == PixelRect(500, 300, 150, 120))

        rig = Rig.selected()
        rig.letter("A")
        rig.drag(Pt(500, 300), Pt(600, 300))
        rig.letter("V")
        rig.click(Pt(550, 300))
        rig.drag(Pt(600, 300), Pt(620, 360)) // its tip
        #expect(rig.shapes == [.arrow(from: Pt(500, 300), to: Pt(620, 360))])
    }

    @Test func aGripIsInReachSixPointsAway() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        rig.click(Pt(500, 340))
        // Six pixels off the bottom right handle still takes it; the
        // rectangle follows the pointer exactly.
        rig.drag(Pt(606, 386), Pt(650, 420))
        #expect(rig.box(0) == PixelRect(500, 300, 150, 120))
        // Seven is the selection's inside: the selection moves instead.
        rig.undo()
        rig.click(Pt(500, 340))
        rig.drag(Pt(607, 387), Pt(617, 397))
        #expect(rig.box(0) == PixelRect(500, 300, 100, 80))
        #expect(rig.editor.selection?.rect == PixelRect(410, 210, 900, 500))
    }

    @Test func thePropertyRowShowsTheSelectedAnnotationsProperties() {
        let rig = Rig.withTwoRects()
        #expect(rig.editor.props == .stroke)
        rig.letter("M")
        rig.drag(Pt(900, 300), Pt(1000, 400))
        #expect(rig.editor.props == .block)
        rig.letter("V")
        #expect(rig.editor.props == AnnotationTool.Props.none, "the select tool with nothing selected has no row")
        #expect(rig.editor.layout?.props == nil)
        rig.click(Pt(500, 340))
        #expect(rig.editor.props == .stroke, "a rectangle is selected")
        rig.click(Pt(950, 350))
        #expect(rig.editor.props == .block, "the mosaic is selected")
        // Even with another tool in hand, a command-selected annotation's
        // row shows.
        rig.letter("T")
        #expect(rig.editor.props == .font)
        rig.click(Pt(950, 350), [.command])
        #expect(rig.editor.props == .block)
    }

    @Test func aColourOrStepGoesToTheSelectedAnnotationAndNotToTheTool() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        rig.click(Pt(500, 340))
        rig.key(.digit(4)) // green
        rig.key(.bracketLeft) // one step thinner
        #expect(rig.style(0) == [3, 0])
        #expect(rig.style(1) == [0, 1])
        #expect(rig.editor.prefs.colour(of: .rect) == 0, "the tool's memory is its own")
        #expect(rig.editor.prefs.level(of: .rect) == 1)
        #expect(rig.editor.current.colour == 3)
        #expect(rig.editor.current.level == 0)
        // The toolbar's swatches and steps do the same as the keys.
        rig.press(.colour(8))
        rig.press(.level(4))
        #expect(rig.style(0) == [8, 4])
        // The same again is not a change, and not a step.
        #expect(rig.press(.colour(8)) == .none)
        #expect(rig.press(.level(4)) == .none)
        rig.undo()
        #expect(rig.style(0) == [8, 0])
    }

    @Test func theStepsStopAtTheEnds() {
        let rig = Rig.selected()
        rig.letter("R")
        for _ in 0..<9 { rig.key(.bracketRight) }
        #expect(rig.editor.prefs.level(of: .rect) == 4)
        #expect(rig.key(.bracketRight) == .none, "already at the top")
        for _ in 0..<9 { rig.key(.bracketLeft) }
        #expect(rig.editor.prefs.level(of: .rect) == 0)
        #expect(rig.key(.bracketLeft) == .none, "already at the bottom")
        rig.letter("V")
        #expect(rig.key(.bracketRight) == .none, "the select tool has no steps")
        #expect(rig.key(.digit(3)) == .none, "nor a colour")
        #expect(rig.editor.prefs == { var p = ToolPrefs(); p.setLevel(0, of: .rect); return p }())
    }

    @Test func aMosaicHasStepsButNoColour() {
        let rig = Rig.selected()
        rig.letter("M")
        #expect(rig.key(.digit(5)) == .none)
        #expect(rig.editor.prefs.colour(of: .mosaic) == 0)
        rig.key(.bracketRight)
        #expect(rig.editor.prefs.level(of: .mosaic) == 2)
        rig.drag(Pt(500, 300), Pt(600, 400))
        rig.letter("V")
        rig.click(Pt(550, 350))
        #expect(rig.editor.selected == 0)
        #expect(rig.key(.digit(5)) == .none, "nor does a selected one")
        #expect(rig.item(0)?.colour == 0)
        #expect(!rig.editor.canRedo && rig.items.count == 1)
        #expect(rig.editor.layout?.rect(of: .colour(0)) == nil)
    }

    @Test func deleteRemovesTheSelectedAnnotationAndArrowsNudgeIt() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        #expect(rig.key(.delete) == .none, "nothing is selected")
        #expect(rig.key(.right) == .none)
        rig.click(Pt(700, 340))
        rig.key(.right)
        rig.key(.up, [.shift])
        #expect(rig.box(1) == PixelRect(701, 290, 100, 80))
        #expect(rig.key(.delete) == .repaint)
        #expect(rig.items.count == 1)
        #expect(rig.editor.selected == nil)
        #expect(rig.box(0) == PixelRect(500, 300, 100, 80), "the other one is untouched")
    }

    // MARK: Undo, redo

    @Test func everyKindOfChangeIsOneStepAndComesBack() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        let drawn = rig.items

        rig.drag(Pt(500, 340), Pt(540, 360)) // move: several pointer moves, one step
        let moved = rig.items
        rig.drag(Pt(640, 400), Pt(700, 450)) // reshape by its bottom right handle
        let reshaped = rig.items
        rig.key(.digit(2)) // colour
        let coloured = rig.items
        rig.key(.bracketRight) // step
        let stepped = rig.items
        rig.key(.left) // nudge
        let nudged = rig.items
        rig.key(.delete)
        #expect(rig.items.count == 1)
        #expect(Set([drawn, moved, reshaped, coloured, stepped, nudged].map { "\($0)" }).count == 6, "six different states")

        for expected in [nudged, stepped, coloured, reshaped, moved, drawn] {
            #expect(rig.undo() == .repaint)
            #expect(rig.items == expected)
            #expect(rig.editor.selected == nil)
        }
        rig.undo()
        #expect(rig.items.count == 1, "the second rectangle's drawing")
        rig.undo()
        #expect(rig.items.isEmpty)
        #expect(rig.undo() == .none, "nothing left to undo")

        // And forwards again.
        rig.redo()
        #expect(rig.redo() == .repaint)
        #expect(rig.items == drawn)
        rig.redo()
        #expect(rig.items == moved)
    }

    @Test func undoAndRedoLetGoOfTheSelectedAnnotationAndUndoEachOther() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        rig.click(Pt(500, 340))
        rig.key(.right)
        #expect(rig.editor.selected == 0)
        #expect(rig.undo() == .repaint)
        #expect(rig.editor.selected == nil, "what was selected may not be there any more")
        #expect(rig.box(0) == PixelRect(500, 300, 100, 80))
        rig.click(Pt(700, 340))
        #expect(rig.redo() == .repaint)
        #expect(rig.editor.selected == nil)
        #expect(rig.box(0) == PixelRect(501, 300, 100, 80))
        // What was redone can be undone again.
        #expect(rig.undo() == .repaint)
        #expect(rig.box(0) == PixelRect(500, 300, 100, 80))
        #expect(rig.items.count == 2, "one step back from the redone nudge, not two")
        #expect(rig.editor.canRedo)
    }

    @Test func drawingLetsGoOfTheSelectedAnnotation() {
        let rig = Rig.withTwoRects()
        rig.click(Pt(500, 340), [.command])
        #expect(rig.editor.selected == 0)
        rig.drag(Pt(900, 300), Pt(950, 350))
        #expect(rig.items.count == 3)
        #expect(rig.editor.selected == nil)
        // A click outside the selection draws nothing, but it lets go too,
        // and says so: the grips have to leave the screen.
        rig.click(Pt(500, 340), [.command])
        #expect(rig.editor.selected == 0)
        #expect(rig.click(Pt(100, 100)) == .repaint)
        #expect(rig.editor.selected == nil)
        #expect(rig.click(Pt(100, 100)) == .none, "with nothing selected there is nothing to repaint")
        #expect(rig.items.count == 3)
    }

    @Test func aNewChangeForgetsWhatCouldHaveBeenRedone() {
        let rig = Rig.withTwoRects()
        rig.undo()
        #expect(rig.editor.canRedo)
        rig.drag(Pt(900, 300), Pt(950, 350))
        #expect(!rig.editor.canRedo)
        #expect(rig.redo() == .none)
        #expect(rig.items.count == 2)
    }

    @Test func movingOrReshapingForgetsWhatCouldHaveBeenRedone() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        rig.undo()
        #expect(rig.editor.canRedo)
        rig.drag(Pt(500, 340), Pt(540, 360))
        #expect(!rig.editor.canRedo)
    }

    @Test func aClickThatMovesNothingIsNotAStep() {
        let rig = Rig.withTwoRects()
        rig.letter("V")
        rig.undo()
        rig.click(Pt(500, 340)) // select only
        #expect(rig.editor.selected == 0)
        #expect(rig.editor.canRedo, "selecting is not a change")
        #expect(rig.items.count == 1)
        // Nor is taking hold of a grip and letting it go where it was.
        rig.down(Pt(600, 380))
        #expect(rig.move(Pt(600, 380)) == .none)
        rig.up(Pt(600, 380))
        #expect(rig.editor.canRedo)
        rig.undo()
        #expect(rig.items.isEmpty, "one step back is the drawing, not a move that never happened")
    }

    @Test func theToolbarsUndoAndRedoAreTheKeys() {
        let rig = Rig.withTwoRects()
        rig.press(.undo)
        #expect(rig.items.count == 1)
        rig.press(.redo)
        #expect(rig.items.count == 2)
    }

    // MARK: Text

    @Test func theTextToolMakesANewPieceAtEveryClick() {
        let rig = Rig.selected()
        rig.letter("T")
        #expect(rig.click(Pt(500, 300)) == .openText)
        #expect(rig.editor.textBox?.at == Pt(500, 300))
        #expect(rig.editor.textBox?.editing == nil)
        #expect(rig.editor.textBox?.caption == false)
        #expect(rig.type("first") == .repaint)
        // The tool is still in hand: the next click is the next piece.
        #expect(rig.click(Pt(500, 400)) == .openText)
        rig.type("second\nline")
        #expect(rig.shapes == [
            .text(at: Pt(500, 300), text: "first", size: .init(50, 18)),
            .text(at: Pt(500, 400), text: "second\nline", size: .init(60, 36)),
        ])
    }

    @Test func aTextStartedOnTheSelectionsLastRowsIsPulledUpAndItsBoxStaysInside() {
        // The window is y 200..700 and x 400..1300; the fake's line is the
        // font's height, 18 px at the default size and 44 at the largest.
        let rig = Rig.selected()
        rig.letter("T")
        #expect(rig.click(Pt(500, 699)) == .openText)
        #expect(rig.editor.textBox?.at == Pt(500, 682), "one line above the bottom edge")
        #expect(rig.editor.textRect(lines: 1, measure: rig.measure) == PixelRect(500, 682, 800, 18))
        // There is no room under it: more lines scroll, the box does not grow.
        #expect(rig.editor.textRect(lines: 5, measure: rig.measure) == PixelRect(500, 682, 800, 18))
        // A bigger size is a taller line, and the text moves up to hold it.
        #expect(rig.touch(.level(4)) == .restyleText)
        #expect(rig.editor.textBox?.at == Pt(500, 656))
        #expect(rig.editor.textBox?.level == 4)
        let box = rig.editor.textRect(lines: 1, measure: rig.measure)
        #expect(box == PixelRect(500, 656, 800, 44))
        #expect(rig.editor.textKeepClear.count == 2)
        #expect(rig.editor.textKeepClear.allSatisfy { box?.intersect($0) == nil },
                "the toolbar is under the selection, the box is in it")
        // What is kept is where it was typed.
        rig.type("low")
        #expect(rig.shapes == [.text(at: Pt(500, 656), text: "low", size: .init(30, 44))])
    }

    @Test func theBoxIsAsTallAsItsLinesUntilTheSelectionsBottomEdge() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        rig.touch(.level(4))
        #expect(rig.editor.textBox?.at == Pt(500, 300), "there was room: it did not move")
        #expect(rig.editor.textRect(lines: 1, measure: rig.measure) == PixelRect(500, 300, 800, 44))
        #expect(rig.editor.textRect(lines: 3, measure: rig.measure) == PixelRect(500, 300, 800, 132))
        // 400 px to the bottom edge is nine lines of 44 and a bit: nine.
        #expect(rig.editor.textRect(lines: 99, measure: rig.measure) == PixelRect(500, 300, 800, 396))
        #expect(rig.editor.textRect(lines: 1, measure: rig.measure)?.h
            == rig.editor.textLine(level: 4, measure: rig.measure))
    }

    @Test func aTextEditedAgainStaysWhereItIsWhateverItsSizeBecomes() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 690))
        #expect(rig.editor.textBox?.at == Pt(500, 682))
        rig.type("first")
        rig.letter("V")
        #expect(rig.double(Pt(510, 688)) == .openText)
        rig.touch(.level(4))
        // Its place is the annotation's, which other things were drawn
        // around: one line, even though that line now ends below the edge.
        #expect(rig.editor.textBox?.at == Pt(500, 682))
        #expect(rig.editor.textBox?.editing == 0)
        #expect(rig.editor.textRect(lines: 3, measure: rig.measure) == PixelRect(500, 682, 800, 44))
    }

    @Test func aClickOutsideTheBoxCommitsAndDoesNothingElse() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        #expect(rig.down(Pt(800, 500)) == .commitText)
        #expect(rig.editor.textBox != nil, "the host reads the box and then calls endText")
        let over = rig.editor.layout?.rect(of: .tool(.arrow)) ?? PixelRect(0, 0, 0, 0)
        #expect(rig.move(Pt(over.x + 3, over.y + 3)) == .none, "nothing follows the pointer while the box is open")
        #expect(rig.editor.hoverButton == nil)
        rig.end("kept")
        #expect(rig.items.count == 1)
        #expect(rig.editor.textBox == nil, "that click did not open another box")
        // A tool button under the click is not pressed either.
        rig.click(Pt(500, 400))
        #expect(rig.press(.tool(.rect)) == .commitText)
        #expect(rig.editor.tool == .text)
    }

    /// Closing a native text control makes it give up the keyboard, and a
    /// host that commits on losing the keyboard is called again from inside
    /// its own commit, with a box it has already emptied. The Windows host
    /// lost every text that way.
    @Test func aSecondCommitOfTheSameBoxDoesNothing() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        #expect(rig.end("typed") == .repaint)
        #expect(rig.end("") == .none)
        #expect(rig.shapes == [.text(at: Pt(500, 300), text: "typed", size: .init(50, 18))])
        rig.undo()
        #expect(rig.items.isEmpty, "and it was one step, not two")

        // The same for a number's sentence, where the second call would
        // otherwise find the number and blank it.
        rig.letter("N")
        rig.click(Pt(600, 300))
        rig.end("this one")
        #expect(rig.end("") == .none)
        #expect(rig.shapes == [.number(n: 1, at: Pt(600, 300), text: "this one", size: .init(80, 18))])

        // And for a text edited again.
        rig.letter("V")
        rig.double(Pt(630, 300))
        #expect(rig.editor.textBox?.editing == 0)
        rig.end("that one")
        #expect(rig.end("") == .none)
        #expect(rig.shapes == [.number(n: 1, at: Pt(600, 300), text: "that one", size: .init(80, 18))])
        #expect(rig.end("anything") == .none, "with no box open there is nothing to end")
    }

    @Test func nothingTypedIsNothingMade() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        rig.type("   \r\n ")
        #expect(rig.items.isEmpty)
        #expect(!rig.editor.canUndo)
    }

    @Test func whatWasTypedIsTrimmedAndItsLineEndsAreMadePlain() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        rig.type("  one\r\ntwo \n")
        #expect(rig.shapes == [.text(at: Pt(500, 300), text: "one\ntwo", size: .init(30, 36))])
    }

    @Test func colourAndSizeChangedWhileTypingApplyToTheWholePiece() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        // While the box has the keyboard the host does not send keys here;
        // the property row is clicked instead.
        #expect(rig.touch(.colour(5)) == .restyleText)
        #expect(rig.touch(.level(3)) == .restyleText)
        #expect(rig.editor.textBox?.colour == 5)
        #expect(rig.editor.textBox?.level == 3)
        #expect(rig.editor.current.colour == 5)
        #expect(rig.editor.current.level == 3)
        rig.type("big")
        #expect(rig.style(0) == [5, 3])
        #expect(rig.shapes == [.text(at: Pt(500, 300), text: "big", size: .init(30, 32))])
        #expect(rig.editor.prefs.colour(of: .text) == 5, "and the tool remembers")
        #expect(rig.editor.prefs.level(of: .text) == 3)
        #expect(rig.editor.prefs.colour(of: .number) == 0, "the number tool is another tool")
    }

    @Test func onlyAColourOrASizeIsPressedWithoutEndingTheText() throws {
        let rig = Rig.selected()
        rig.letter("T")
        let layout = try #require(rig.editor.layout)
        func inside(_ button: ToolbarButton) throws -> Pt {
            let r = try #require(layout.rect(of: button))
            return Pt(r.x + 1, r.y + 1)
        }
        // Nothing is being typed: there is no text for a press to change.
        #expect(!rig.editor.restylesText(at: try inside(.colour(5))))

        rig.click(Pt(500, 300))
        #expect(rig.editor.textBox != nil)
        // What the host asks when the box is about to lose the keyboard.
        #expect(rig.editor.restylesText(at: try inside(.colour(5))))
        #expect(rig.editor.restylesText(at: try inside(.level(3))))
        #expect(!rig.editor.restylesText(at: try inside(.tool(.rect))), "another tool ends the text")
        #expect(!rig.editor.restylesText(at: try inside(.undo)))
        #expect(!rig.editor.restylesText(at: try inside(.done)))
        #expect(!rig.editor.restylesText(at: Pt(800, 500)), "so does a press on the picture")
        // And the press agrees with the answer, each way.
        #expect(rig.down(try inside(.undo)) == .commitText)
        #expect(rig.editor.textBox != nil, "the box is the host's to close")
        #expect(rig.down(try inside(.colour(5))) == .restyleText)
    }

    @Test func twoQuickPressesOnTheRowWhileTypingAreTwoPressesAndTheTextStaysOpen() throws {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        let layout = try #require(rig.editor.layout)
        let swatch = try #require(layout.rect(of: .colour(5)))
        let step = try #require(layout.rect(of: .level(3)))
        // The host sends the second of two quick presses as a double click.
        #expect(rig.down(Pt(swatch.x + 1, swatch.y + 1)) == .restyleText)
        #expect(rig.double(Pt(swatch.x + 1, swatch.y + 1)) == .restyleText)
        #expect(rig.double(Pt(step.x + 1, step.y + 1)) == .restyleText)
        #expect(rig.editor.textBox?.colour == 5)
        #expect(rig.editor.textBox?.level == 3)
        rig.type("still here")
        #expect(rig.style(0) == [5, 3])
    }

    @Test func doubleClickingATextEditsItAgain() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        rig.type("first")
        rig.letter("V")
        #expect(rig.double(Pt(510, 305)) == .openText)
        #expect(rig.editor.textBox?.at == Pt(500, 300))
        #expect(rig.editor.textBox?.text == "first")
        #expect(rig.editor.textBox?.editing == 0)
        #expect(rig.editor.selected == 0)
        #expect(rig.double(Pt(510, 305)) == .commitText, "a double click while typing is a click outside")
        rig.type("changed")
        #expect(rig.shapes == [.text(at: Pt(500, 300), text: "changed", size: .init(70, 18))])
        // One step back is the text as it was; another is no text.
        rig.undo()
        #expect(rig.shapes == [.text(at: Pt(500, 300), text: "first", size: .init(50, 18))])
        rig.undo()
        #expect(rig.items.isEmpty)
    }

    @Test func doubleClickingANumberEditsItsSentenceWhereTheSentenceIs() {
        let rig = Rig.selected()
        rig.letter("N")
        rig.click(Pt(500, 300))
        let opened = rig.editor.textBox?.at
        rig.type("this one")
        rig.letter("V")
        #expect(rig.double(Pt(500, 300)) == .openText)
        #expect(rig.editor.textBox?.caption == true)
        #expect(rig.editor.textBox?.text == "this one")
        #expect(rig.editor.textBox?.at == opened, "the box opens where the sentence was typed")
        #expect(rig.editor.props == .font)
        rig.type("this one")
        // Double clicking a shape with no words takes hold of it.
        rig.letter("R")
        rig.drag(Pt(700, 300), Pt(800, 380))
        rig.letter("V")
        #expect(rig.double(Pt(700, 340)) == .capture)
        #expect(rig.editor.textBox == nil)
    }

    @Test func aNumbersSentenceOfSeveralLinesOpensAgainAtItsOwnHeight() {
        let rig = Rig.selected()
        rig.letter("N")
        rig.click(Pt(500, 300))
        rig.type("one\ntwo")
        rig.letter("V")
        rig.double(Pt(500, 300))
        #expect(rig.editor.textBox?.at
            == Annotation.captionOrigin(at: Pt(500, 300), level: 1, scale: 1, captionHeight: 36))
        #expect(rig.editor.textBox?.at
            != Annotation.captionOrigin(at: Pt(500, 300), level: 1, scale: 1, captionHeight: 18))
    }

    @Test func aColourPickedWhileEditingATextAgainBecomesThatTextsColour() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        rig.type("first")
        rig.letter("V")
        rig.double(Pt(510, 305))
        rig.touch(.colour(6))
        rig.touch(.level(3))
        // The row marks what the box has, which is not yet the text's own.
        #expect(rig.editor.current.colour == 6)
        #expect(rig.editor.current.level == 3)
        #expect(rig.item(0)?.colour == 0)
        rig.touch(.level(1))
        rig.type("first")
        #expect(rig.item(0)?.colour == 6, "same words, new colour: that is a change")
        rig.undo()
        #expect(rig.item(0)?.colour == 0, "and a step")
    }

    @Test func editingATextDownToNothingDeletesItAndLeavingItAloneIsNoStep() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        rig.type("first")
        rig.letter("V")
        rig.double(Pt(510, 305))
        rig.type("first")
        rig.undo()
        #expect(rig.items.isEmpty, "the untouched edit was not a step; this undo took the text's creation")
        rig.redo()
        rig.double(Pt(510, 305))
        rig.type("")
        #expect(rig.items.isEmpty)
        #expect(rig.editor.selected == nil)
        rig.undo()
        #expect(rig.items.count == 1, "and deleting it that way is undone like any other")
    }

    @Test func aNumberAndItsSentenceAreOneStep() {
        let rig = Rig.selected()
        rig.letter("N")
        #expect(rig.click(Pt(500, 300)) == .openText)
        #expect(rig.items.count == 1, "the circle is there while its sentence is typed")
        #expect(rig.editor.textBox?.caption == true)
        #expect(rig.editor.textBox?.editing == 0)
        #expect(rig.editor.textBox?.at
            == Annotation.captionOrigin(at: Pt(500, 300), level: 1, scale: 1, captionHeight: 18))
        rig.type("this one")
        rig.click(Pt(600, 300))
        rig.type("")
        #expect(rig.shapes == [
            .number(n: 1, at: Pt(500, 300), text: "this one", size: .init(80, 18)),
            .number(n: 2, at: Pt(600, 300), text: "", size: .zero),
        ])
        rig.undo()
        #expect(rig.items.count == 1)
        rig.undo()
        #expect(rig.items.isEmpty, "two numbers, two steps")
        #expect(!rig.editor.canUndo)
    }

    @Test func aSelectedTextsSizeIsMeasuredAgainWhenItsStepChanges() {
        let rig = Rig.selected()
        rig.letter("T")
        rig.click(Pt(500, 300))
        rig.type("abc")
        rig.letter("N")
        rig.click(Pt(700, 300))
        rig.type("abcd")
        rig.click(Pt(900, 300))
        rig.type("")
        rig.letter("V")
        rig.click(Pt(510, 305))
        rig.key(.bracketRight)
        #expect(rig.shape(0) == .text(at: Pt(500, 300), text: "abc", size: .init(30, 24)))
        rig.click(Pt(700, 300))
        rig.key(.bracketRight)
        #expect(rig.shape(1) == .number(n: 1, at: Pt(700, 300), text: "abcd", size: .init(40, 24)))
        // A number with no sentence has nothing to measure.
        rig.click(Pt(900, 300))
        rig.key(.bracketRight)
        #expect(rig.shape(2) == .number(n: 2, at: Pt(900, 300), text: "", size: .zero))
        #expect(rig.item(2)?.level == 2)
    }

    // MARK: Stepping back

    @Test func theRightButtonStepsBackInTheSpecifiedOrder() {
        let rig = Rig.withTwoRects()
        rig.letter("T")
        rig.click(Pt(900, 600))
        #expect(rig.rightClick() == .commitText, "1. out of the text box")
        rig.end("note")
        rig.click(Pt(500, 340), [.command])
        #expect(rig.editor.selected == 0)
        #expect(rig.rightClick() == .repaint, "2. let go of the annotation")
        #expect(rig.editor.selected == nil)
        #expect(rig.editor.tool == .text)
        #expect(rig.rightClick() == .repaint, "3. put the tool down")
        #expect(rig.editor.tool == .select)
        #expect(rig.rightClick() == .none, "with annotations it goes no further")
        #expect(rig.items.count == 3)
        #expect(rig.editor.selection != nil)
    }

    @Test func withNothingDrawnTheRightButtonClearsTheSelectionAndThenCancels() {
        let rig = Rig.selected()
        #expect(rig.rightClick() == .release)
        #expect(rig.editor.selection == nil)
        #expect(rig.rightClick() == .cancel)
        // A region still being dragged out is let go of the same way.
        rig.down(Pt(100, 100))
        rig.move(Pt(300, 250))
        #expect(rig.editor.forming != nil)
        #expect(rig.rightClick() == .release)
        #expect(rig.editor.forming == nil)
        #expect(rig.up(Pt(300, 250)) == .none, "and the drag is over")
        #expect(rig.editor.selection == nil)
    }

    // MARK: The toolbar

    @Test func theToolbarTakesTheClickAndThePictureDoesNot() throws {
        let rig = Rig.selected()
        #expect(rig.press(.tool(.rect)) == .repaint)
        #expect(rig.editor.tool == .rect)
        // Between two buttons: the toolbar swallows it; nothing is drawn.
        let r = try #require(rig.editor.layout?.rect(of: .tool(.rect)))
        #expect(rig.down(Pt(r.right + 1, r.y + 3)) == .none)
        rig.up(Pt(r.right + 1, r.y + 3))
        rig.drag(Pt(r.right + 1, r.y + 3), Pt(r.right + 60, r.y + 60))
        #expect(rig.items.isEmpty)
        #expect(rig.press(.done) == .finish)
        #expect(rig.press(.cancel) == .cancel)
        #expect(rig.press(.long) == .long)
    }

    /// With the whole display selected the toolbar is inside the selection,
    /// where a click that missed its buttons would otherwise be a click on
    /// the picture.
    @Test func aToolbarInsideTheSelectionStillTakesItsClicks() throws {
        let rig = Rig.fresh()
        rig.click(Pt(2000, 1000))
        #expect(rig.editor.selection?.rect == display)
        let pen = try #require(rig.editor.layout?.rect(of: .tool(.pen)))
        #expect(display.contains(Pt(pen.x, pen.y)))
        // A double click on a button presses it; it does not finish.
        #expect(rig.double(Pt(pen.x + 2, pen.y + 2)) == .repaint)
        #expect(rig.editor.tool == .pen)
        rig.letter("V")
        #expect(rig.double(Pt(pen.right + 1, pen.y + 3)) == .none, "nor does one between two buttons")
        // Between two buttons nothing is drawn and nothing is moved.
        rig.letter("R")
        #expect(rig.down(Pt(pen.right + 1, pen.y + 3)) == .none)
        rig.up(Pt(pen.right + 1, pen.y + 3))
        rig.drag(Pt(pen.right + 1, pen.y + 3), Pt(pen.right + 60, pen.y - 200))
        #expect(rig.items.isEmpty)
    }

    @Test func pickingAToolLetsGoOfTheSelectedAnnotation() {
        let rig = Rig.withTwoRects()
        rig.click(Pt(500, 340), [.command])
        #expect(rig.editor.selected == 0)
        #expect(rig.letter("O") == .repaint)
        #expect(rig.editor.selected == nil)
        #expect(rig.editor.tool == .ellipse)
    }

    @Test func thePointerOverAButtonIsWhatTheTooltipFollows() throws {
        let rig = Rig.selected()
        let r = try #require(rig.editor.layout?.rect(of: .tool(.arrow)))
        #expect(rig.move(Pt(r.x + 3, r.y + 3)) == .repaint)
        #expect(rig.editor.hoverButton == .tool(.arrow))
        #expect(rig.move(Pt(r.x + 5, r.y + 5)) == .none, "still the same button")
        rig.move(Pt(900, 500))
        #expect(rig.editor.hoverButton == nil)
    }

    @Test func keysForToolsMeanNothingBeforeThereIsASelection() {
        let rig = Rig.fresh()
        #expect(rig.letter("R") == .none)
        #expect(rig.editor.tool == .select)
        #expect(rig.key(.digit(3)) == .none)
        #expect(rig.key(.bracketRight) == .none)
        #expect(rig.editor.prefs == ToolPrefs())
        #expect(rig.key(.enter) == .none)
        #expect(rig.key(.escape) == .cancel)
        #expect(rig.editor.key(.letter("r"), mods: [], measure: FakeMeasure()).key == .tool(.rect), "what it was taken for")
    }

    @Test func aDoubleClickFinishesOnlyInTheSelectToolOnEmptySelection() {
        let rig = Rig.withTwoRects()
        #expect(rig.double(Pt(900, 600)) == .capture, "with a tool in hand it is a second click")
        rig.up(Pt(900, 600))
        // Command held makes a click a selecting one, not a finishing one.
        #expect(rig.double(Pt(900, 600), [.command]) == .none)
        rig.letter("V")
        #expect(rig.double(Pt(900, 600)) == .finish)
        #expect(rig.double(Pt(500, 340)) == .capture, "on a rectangle it grabs the rectangle")
        rig.up(Pt(500, 340))
        // Outside the selection, with annotations: it lets go of the
        // rectangle and does nothing more -- no picking again, no finish.
        #expect(rig.double(Pt(100, 100)) == .repaint)
        #expect(rig.editor.selected == nil)
        #expect(rig.double(Pt(100, 100)) == .none)
        #expect(rig.editor.selection?.rect == window)
    }

    @Test func aDoubleClickOnTheToolbarOrBeforeASelectionIsAClick() {
        var rig = Rig.selected()
        let r = rig.editor.layout?.rect(of: .tool(.pen))
        #expect(rig.double(Pt((r?.x ?? 0) + 2, (r?.y ?? 0) + 2)) == .repaint)
        #expect(rig.editor.tool == .pen)

        rig = Rig.fresh()
        #expect(rig.double(Pt(500, 300)) == .capture)
        rig.up(Pt(500, 300))
        #expect(rig.editor.selection?.rect == window)
    }

    // MARK: Export

    @Test func whatLeavesIsWhatReachesIntoTheSelectionMosaicsFirst() throws {
        let rig = Rig.selected()
        rig.letter("R")
        rig.drag(Pt(500, 300), Pt(600, 380))
        rig.letter("M")
        rig.drag(Pt(700, 300), Pt(800, 380))
        rig.letter("A")
        rig.drag(Pt(1200, 600), Pt(1500, 900)) // runs out of the selection
        // Shrink the selection so the first rectangle is wholly outside it.
        rig.letter("V")
        rig.drag(Pt(400, 450), Pt(650, 450)) // its west handle
        #expect(rig.editor.selection?.rect == PixelRect(650, 200, 650, 500))

        let x = try #require(rig.editor.export())
        #expect(x.selection.rect == PixelRect(650, 200, 650, 500))
        #expect(x.scale == 1)
        #expect(x.onScreen.map(\.shape) == [
            .mosaic(PixelRect(700, 300, 100, 80)),
            .arrow(from: Pt(1200, 600), to: Pt(1500, 900)),
        ], "the mosaic is drawn first, in screen coordinates")
        // For the sidecar: image coordinates, in the order they were made.
        #expect(x.onImage.map(\.shape) == [
            .mosaic(PixelRect(50, 100, 100, 80)),
            .arrow(from: Pt(550, 400), to: Pt(850, 700)),
        ], "true geometry, past the edge")
        #expect(rig.items.count == 3, "the one outside is still there if the selection grows back")
        #expect(Rig.fresh().editor.export() == nil, "nothing selected, nothing to leave")
    }

    @Test func mosaicsAreDrawnFirstWhateverOrderTheyWereMadeIn() {
        let rig = Rig.withTwoRects()
        rig.letter("M")
        rig.drag(Pt(900, 300), Pt(1000, 400))
        #expect(rig.editor.drawOrder.map(\.index) == [2, 0, 1])
        #expect(rig.editor.drawOrder.map(\.item.shape) == [
            .mosaic(PixelRect(900, 300, 100, 100)),
            .rect(PixelRect(500, 300, 100, 80)),
            .rect(PixelRect(700, 300, 100, 80)),
        ])
        // And that is the order they leave in for the picture; the file
        // keeps the order they were made in.
        #expect(rig.editor.export()?.onScreen.map(\.shape) == rig.editor.drawOrder.map(\.item.shape))
        #expect(rig.editor.export()?.onImage.map(\.shape) == [
            .rect(PixelRect(100, 100, 100, 80)),
            .rect(PixelRect(300, 100, 100, 80)),
            .mosaic(PixelRect(500, 100, 100, 100)),
        ])
    }

    // MARK: Long screenshots

    @Test func enteringLongModeClearsTheAnnotationsAsOneStep() {
        let rig = Rig.withTwoRects()
        rig.click(Pt(500, 340), [.command])
        rig.editor.clearAnnotations()
        #expect(rig.items.isEmpty)
        #expect(rig.editor.selected == nil)
        rig.undo()
        #expect(rig.items.count == 2)
        // With nothing to clear it is not a step.
        let empty = Rig.selected()
        empty.editor.clearAnnotations()
        #expect(!empty.editor.canUndo)
    }

    @Test func longModeClearsTheAnnotationsAndAnswersOnlyToItsThreeButtons() {
        let rig = Rig.withTwoRects()
        #expect(rig.press(.long) == .long)
        #expect(rig.editor.isLong)
        #expect(rig.items.isEmpty, "a long screenshot carries no annotations")
        #expect(rig.editor.props == AnnotationTool.Props.none)
        #expect(rig.editor.tool == .select)
        // Nothing can be drawn, selected or chosen.
        #expect(rig.letter("R") == .none)
        #expect(rig.editor.tool == .select)
        #expect(rig.click(Pt(500, 340)) == .none, "a click in the live selection is not ours")
        #expect(rig.double(Pt(900, 600)) == .none, "nor does a double click finish")
        rig.drag(Pt(900, 600), Pt(950, 650))
        #expect(rig.editor.selection?.rect == window, "nor does a drag move the selection")
        #expect(rig.press(.tool(.pen)) == .none)
        #expect(rig.press(.undo) == .none)
        #expect(rig.undo() == .none)
        #expect(rig.items.isEmpty && rig.editor.isLong)
        // The three that work.
        #expect(rig.press(.done) == .finish)
        #expect(rig.press(.cancel) == .cancel)
        #expect(rig.key(.enter) == .finish)
        #expect(rig.key(.escape) == .cancel)
    }

    @Test func leavingLongModeGivesTheAnnotationsBackToUndo() {
        let rig = Rig.withTwoRects()
        rig.press(.long)
        #expect(rig.rightClick() == .leaveLong, "the right button steps back out of it")
        #expect(!rig.editor.isLong)
        #expect(rig.items.isEmpty)
        rig.undo()
        #expect(rig.items.count == 2, "entering was one step, and undo takes it back")
        // The button toggles too.
        rig.press(.long)
        #expect(rig.press(.long) == .leaveLong)
        #expect(!rig.editor.isLong)
    }

    @Test func longModeNeedsASelection() {
        let rig = Rig.fresh()
        #expect(rig.editor.enterLong() == .none)
        #expect(!rig.editor.isLong)
    }

    @Test func sizesFollowTheDisplayTheSelectionIsOn() {
        let displays = [
            ShotEditor.Display(rect: display, scale: 1),
            ShotEditor.Display(rect: PixelRect(2560, 0, 3840, 2160), scale: 2),
        ]
        let windows = [ShotEditor.Window(id: 9, rect: PixelRect(3000, 200, 1600, 1000))]
        let rig = Rig(ShotEditor(displays: displays, windows: windows, prefs: ToolPrefs(), preselect: Pt(3100, 300)))
        #expect(rig.editor.scale == 2)
        #expect(Rig.fresh().editor.scale == 1, "before there is a selection")
        #expect(rig.editor.layout?.rect(of: .done)?.w == 56)
        rig.letter("T")
        rig.click(Pt(3100, 300))
        rig.type("abc")
        #expect(rig.shapes == [.text(at: Pt(3100, 300), text: "abc", size: .init(30, 36))], "18 points at 200%")
    }

    @Test func aDragStaysOnTheDisplayItStartedOn() {
        let displays = [
            ShotEditor.Display(rect: display, scale: 1),
            ShotEditor.Display(rect: PixelRect(2560, 0, 3840, 2160), scale: 2),
        ]
        let rig = Rig(ShotEditor(displays: displays, windows: [], prefs: ToolPrefs()))
        rig.drag(Pt(2400, 100), Pt(2700, 300))
        #expect(rig.editor.selection == .init(rect: PixelRect(2400, 100, 160, 200), display: 0, window: nil))
    }
}
