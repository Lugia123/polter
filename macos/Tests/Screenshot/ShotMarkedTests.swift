import Foundation
import Testing
@testable import Ghostty

/// How the selected annotation is marked and taken hold of
/// (`dev-docs/poltergeist/screenshot.md`, 9.8.11A). The Windows host's
/// `editor.rs` has the same rules.
struct ShotMarkedTests {
    private typealias Pt = PixelPoint

    /// Ten pixels a character wide, one font-height a line tall.
    private struct Measure: TextMeasure {
        func size(of text: String, fontPx: Int) -> Annotation.PixelSize {
            let lines = text.components(separatedBy: "\n")
            return .init((lines.map(\.count).max() ?? 0) * 10, lines.count * fontPx)
        }
    }

    /// A display at scale 2 with one selection on it and the editor ready.
    private final class Rig {
        var editor: ShotEditor
        let measure = Measure()
        let selection = PixelRect(200, 200, 1200, 600)

        init() {
            let display = PixelRect(0, 0, 2400, 1400)
            editor = ShotEditor(
                displays: [.init(rect: display, scale: 2)], windows: [.init(id: 1, rect: display)], prefs: ToolPrefs())
            drag(Pt(200, 200), Pt(1400, 800))
        }

        func drag(_ from: Pt, _ to: Pt) {
            _ = editor.pointerDown(at: from, mods: [], measure: measure)
            _ = editor.pointerMove(to: to, mods: [])
            _ = editor.pointerUp(at: to)
        }

        func click(_ p: Pt) {
            _ = editor.pointerDown(at: p, mods: [], measure: measure)
            _ = editor.pointerUp(at: p)
        }

        func pick(_ button: ToolbarButton) {
            guard let r = editor.layout?.rect(of: button) else { return }
            click(Pt(r.x + r.w / 2, r.y + r.h / 2))
        }

        /// Draw with `tool` from `from` to `to`, then take the select tool
        /// and click the shape at `at`.
        func draw(_ tool: AnnotationTool, _ from: Pt, _ to: Pt, select at: Pt) {
            pick(.tool(tool))
            drag(from, to)
            pick(.tool(.select))
            click(at)
        }
    }

    @Test func aBoxHasAFrameAndEightGripsOnTheFrame() throws {
        let rig = Rig()
        rig.draw(.rect, Pt(400, 300), Pt(700, 500), select: Pt(480, 300))
        let marked = try #require(rig.editor.marked)
        // The ink is the rectangle and half its line; the frame is four
        // points -- eight pixels here -- outside that.
        let ink = try #require(rig.editor.items.first).bounds(scale: 2)
        #expect(marked.ink == ink)
        #expect(marked.framed)
        let frame = ShotEditor.frame(of: ink, scale: 2)
        #expect(frame == PixelRect(ink.x - 8, ink.y - 8, ink.w + 16, ink.h + 16))
        #expect(marked.grips.map(\.at) == PixelHandle.all.map { $0.at(frame) })
        #expect(marked.grips.allSatisfy { $0.look == .normal })
        // The selection's own knobs are put away while an annotation is
        // selected: the two kinds are never on screen together.
        #expect(!rig.editor.knobs)
    }

    @Test func aLineHasTwoGripsOnItsEndsAndNoFrame() throws {
        let rig = Rig()
        rig.draw(.arrow, Pt(400, 500), Pt(700, 300), select: Pt(550, 400))
        let marked = try #require(rig.editor.marked)
        #expect(!marked.framed)
        #expect(marked.grips.map(\.at) == [Pt(400, 500), Pt(700, 300)])
    }

    @Test func whatCanOnlyBeMovedHasAFrameAndNoGrips() throws {
        let rig = Rig()
        rig.pick(.tool(.pen))
        _ = rig.editor.pointerDown(at: Pt(480, 300), mods: [], measure: rig.measure)
        for x in stride(from: 410, through: 600, by: 10) { _ = rig.editor.pointerMove(to: Pt(x, 400 + (x % 40)), mods: []) }
        _ = rig.editor.pointerUp(at: Pt(600, 400))
        rig.pick(.tool(.select))
        rig.click(Pt(500, 420))
        let marked = try #require(rig.editor.marked)
        #expect(marked.framed && marked.grips.isEmpty, "that is how it says it cannot be stretched")
    }

    @Test func aGripIsTakenWhereItIsDrawnAndTheShapeDoesNotJump() throws {
        let rig = Rig()
        rig.draw(.rect, Pt(400, 300), Pt(700, 500), select: Pt(480, 300))
        let before = try #require(rig.editor.items.first)
        guard case let .rect(was) = before.shape else {
            Issue.record("not a rectangle")
            return
        }
        // The south-east grip: on the frame, well outside the corner.
        let marked = try #require(rig.editor.marked)
        let grip = try #require(marked.grips.last { $0.at.x > was.right && $0.at.y > was.bottom }).at
        #expect(grip.x - was.right >= 8 && grip.y - was.bottom >= 8)
        // Pressed there and not moved: nothing changes.
        _ = rig.editor.pointerDown(at: grip, mods: [], measure: rig.measure)
        #expect(rig.editor.items.first == before)
        #expect(rig.editor.marked?.grips.contains { $0.look == .held } == true)
        // Moved by (30, 12): the corner moves by exactly that.
        _ = rig.editor.pointerMove(to: Pt(grip.x + 30, grip.y + 12), mods: [])
        guard case let .rect(now)? = rig.editor.items.first?.shape else {
            Issue.record("not a rectangle")
            return
        }
        #expect(now == PixelRect(was.x, was.y, was.w + 30, was.h + 12))
        #expect(rig.editor.reshapeTag == "\(now.w) × \(now.h)")
        _ = rig.editor.pointerUp(at: Pt(grip.x + 30, grip.y + 12))
        #expect(rig.editor.reshapeTag == nil)
        // A press on the shape's line away from any grip is not a press on
        // a grip: it carries the shape.
        let onLine = Pt(now.x + now.w / 4, now.y)
        _ = rig.editor.pointerDown(at: onLine, mods: [], measure: rig.measure)
        #expect(rig.editor.isMovingItem)
        _ = rig.editor.pointerUp(at: onLine)
    }

    @Test func theGripUnderThePointerIsHotAndGripsAreGoneWhileTheShapeIsCarried() throws {
        let rig = Rig()
        rig.draw(.rect, Pt(400, 300), Pt(700, 500), select: Pt(480, 300))
        let first = try #require(rig.editor.marked?.grips.first).at
        #expect(rig.editor.pointerMove(to: first, mods: []) == .repaint)
        #expect(rig.editor.marked?.grips.first?.look == .hot)
        #expect(rig.editor.marked?.grips.dropFirst().allSatisfy { $0.look == .normal } == true)
        // Off it again.
        #expect(rig.editor.pointerMove(to: Pt(900, 700), mods: []) == .repaint)
        #expect(rig.editor.marked?.grips.allSatisfy { $0.look == .normal } == true)
        // Carried: the frame stays, the grips are put away.
        _ = rig.editor.pointerDown(at: Pt(480, 300), mods: [], measure: rig.measure)
        _ = rig.editor.pointerMove(to: Pt(520, 330), mods: [])
        #expect(rig.editor.isMovingItem)
        let carried = try #require(rig.editor.marked)
        #expect(carried.framed && carried.grips.isEmpty)
        _ = rig.editor.pointerUp(at: Pt(520, 330))
        #expect(rig.editor.marked?.grips.count == 8)
    }

    @Test func aLinesTagIsItsAngleUpTheScreen() throws {
        let rig = Rig()
        rig.draw(.arrow, Pt(400, 500), Pt(700, 500), select: Pt(550, 500))
        // Take the far end and lift it to 45 degrees.
        _ = rig.editor.pointerDown(at: Pt(700, 500), mods: [], measure: rig.measure)
        _ = rig.editor.pointerMove(to: Pt(700, 200), mods: [])
        #expect(rig.editor.reshapeTag == "45°")
        _ = rig.editor.pointerMove(to: Pt(400, 200), mods: [])
        #expect(rig.editor.reshapeTag == "90°")
        _ = rig.editor.pointerMove(to: Pt(700, 800), mods: [])
        #expect(rig.editor.reshapeTag == "315°")
        _ = rig.editor.pointerUp(at: Pt(700, 800))
    }

    @Test func insideASelectedHollowShapeIsStillTheShapesAHandThatCarriesIt() throws {
        for kind in [AnnotationTool.rect, AnnotationTool.ellipse] {
            let rig = Rig()
            rig.draw(kind, Pt(400, 300), Pt(700, 500), select: Pt(400, 400))
            #expect(rig.editor.selected != nil)
            let inside = Pt(550, 400)
            // Off the line, well inside: a hand, and a press carries it.
            #expect(rig.editor.cursor(at: inside, mods: []) == .move, "\(kind)")
            if kind == .rect { #expect(rig.editor.cursor(at: Pt(480, 300), mods: []) == .move, "and on its line, still") }
            // Outside it (a corner of the ellipse's box is outside it).
            #expect(rig.editor.cursor(at: Pt(1000, 400), mods: []) != .move)
            if kind == .ellipse { #expect(rig.editor.cursor(at: Pt(405, 305), mods: []) != .move, "the box's corner") }
            let before = rig.editor.items[0]
            _ = rig.editor.pointerDown(at: inside, mods: [], measure: rig.measure)
            #expect(rig.editor.isMovingItem, "\(kind)")
            _ = rig.editor.pointerMove(to: Pt(600, 450), mods: [])
            _ = rig.editor.pointerUp(at: Pt(600, 450))
            #expect(rig.editor.items[0] != before, "carried")
            #expect(rig.editor.selection != nil && rig.editor.items.count == 1)
        }
    }

    @Test func somethingDrawnInsideASelectedShapeStillWinsOverIt() throws {
        let rig = Rig()
        rig.draw(.rect, Pt(400, 300), Pt(900, 700), select: Pt(400, 500))
        rig.pick(.tool(.line))
        rig.drag(Pt(500, 400), Pt(700, 400))
        rig.pick(.tool(.select))
        rig.click(Pt(400, 500))
        // On the line inside: an arrow (a press would select it), not the
        // big shape's hand.
        #expect(rig.editor.cursor(at: Pt(600, 400), mods: []) == .arrow)
        _ = rig.editor.pointerDown(at: Pt(600, 400), mods: [], measure: rig.measure)
        _ = rig.editor.pointerUp(at: Pt(600, 400))
        #expect(rig.editor.selected == 1)
    }

    @Test func thePointerSaysWhatAPressWouldDo() throws {
        let rig = Rig()
        // Nothing selected, the select tool: the selection's knobs.
        #expect(rig.editor.knobs)
        #expect(rig.editor.cursor(at: Pt(200, 200), mods: []) == .diagonal)
        #expect(rig.editor.cursor(at: Pt(1400, 200), mods: []) == .antiDiagonal)
        #expect(rig.editor.cursor(at: Pt(800, 200), mods: []) == .upDown)
        #expect(rig.editor.cursor(at: Pt(200, 500), mods: []) == .leftRight)
        #expect(rig.editor.cursor(at: Pt(800, 500), mods: []) == .tool)

        rig.draw(.rect, Pt(400, 300), Pt(700, 500), select: Pt(480, 300))
        rig.pick(.tool(.rect))
        rig.drag(Pt(900, 300), Pt(1100, 500))
        rig.pick(.tool(.select))
        rig.click(Pt(480, 300))
        let grips = try #require(rig.editor.marked?.grips.map(\.at))
        // In `PixelHandle.all`'s order: nw, ne, se, sw, n, e, s, w.
        #expect(rig.editor.cursor(at: grips[0], mods: []) == .diagonal)
        #expect(rig.editor.cursor(at: grips[1], mods: []) == .antiDiagonal)
        #expect(rig.editor.cursor(at: grips[2], mods: []) == .diagonal)
        #expect(rig.editor.cursor(at: grips[3], mods: []) == .antiDiagonal)
        #expect(rig.editor.cursor(at: grips[4], mods: []) == .upDown)
        #expect(rig.editor.cursor(at: grips[5], mods: []) == .leftRight)
        // On the selected shape's line: it can be carried. On another's: a
        // press would select it.
        #expect(rig.editor.cursor(at: Pt(480, 300), mods: []) == .move)
        #expect(rig.editor.cursor(at: Pt(900, 400), mods: []) == .arrow)
        // Over the toolbar: an arrow.
        let bar = try #require(rig.editor.layout).plate
        let cell = try #require(rig.editor.layout?.rect(of: .undo))
        #expect(rig.editor.cursor(at: Pt(cell.x + 3, cell.y + 3), mods: []) == .arrow)
        // And a hand on the plate between its cells, which carries it.
        #expect(rig.editor.cursor(at: Pt(bar.x + 3, bar.y + 3), mods: []) == .move)
        // With an annotation selected the selection's knobs are away, so
        // its corner is nothing special.
        #expect(rig.editor.cursor(at: Pt(1400, 800), mods: []) == .tool)

        // Another tool: its own pointer everywhere -- unless the key that
        // selects is held.
        rig.pick(.tool(.pen))
        #expect(rig.editor.cursor(at: Pt(900, 400), mods: []) == .tool)
        #expect(rig.editor.cursor(at: Pt(900, 400), mods: [.command]) == .arrow)
    }
}
