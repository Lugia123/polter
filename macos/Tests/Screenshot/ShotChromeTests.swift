import Foundation
import Testing
@testable import Ghostty

/// A toolbar cell's look and how it changes
/// (`dev-docs/poltergeist/screenshot.md`, 9.8.4 and 9.8.4.0).
struct ShotCellTests {
    private typealias State = ShotCell.State
    private typealias Look = ShotCell.Look

    @Test func theSixLooks() {
        #expect(ShotCell.look(for: State()) == Look())
        // Hover: a plain fill and a hairline, and nothing of the accent.
        #expect(ShotCell.look(for: State(hovered: true)) == Look(hover: 1, hairline: 1))
        // Pressed: the ring, the tinted fill, the ink in the accent.
        #expect(ShotCell.look(for: State(pressed: true)) == Look(down: 1, ring: 1, accent: 1))
        #expect(ShotCell.look(for: State(hovered: true, pressed: true)) == Look(down: 1, ring: 1, accent: 1))
        // Selected: the ring and the ink, no fill.
        #expect(ShotCell.look(for: State(selected: true)) == Look(ring: 1, accent: 1))
        // Selected and hovered: the fill comes back, the hairline does not.
        #expect(ShotCell.look(for: State(hovered: true, selected: true)) == Look(hover: 1, ring: 1, accent: 1))
        // Unavailable: nothing, whatever the mouse does.
        #expect(ShotCell.look(for: State(hovered: true, pressed: true, selected: true, enabled: false)) == Look(off: true))
    }

    @Test func doneIsQuietUntilItIsPressed() {
        // 9.8.4: like any other button at rest and under the pointer...
        #expect(ShotCell.look(for: State(isDone: true)) == Look())
        #expect(ShotCell.look(for: State(hovered: true, isDone: true)) == Look(hover: 1, hairline: 1))
        // ...and solid, with its ring, while it is held.
        #expect(ShotCell.look(for: State(pressed: true, isDone: true)) == Look(ring: 1, solid: 1))
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func hoverComesInFasterThanItGoesOut() {
        var fade = ShotCell.Fade()
        let t = ShotLook.TransitionMs.self
        fade.head(for: Look(hover: 1, hairline: 1), at: 10)
        #expect(near(fade.look(at: 10 + t.hoverIn / 2000).hover, 0.5))
        #expect(fade.look(at: 10 + t.hoverIn / 1000 + 0.001).hover == 1)
        #expect(fade.isMoving(at: 10.01) && !fade.isMoving(at: 11))
        fade.head(for: Look(), at: 20)
        #expect(near(fade.look(at: 20 + t.hoverOut / 2000).hover, 0.5))
        #expect(near(fade.look(at: 20 + t.hoverOut / 2000).hairline, 0.5))
        #expect(fade.look(at: 21).hover == 0)
        #expect(t.hoverIn < t.hoverOut)
    }

    @Test func aPressShowsAtOnceAndWhatItLeavesFades() {
        let t = ShotLook.TransitionMs.self
        // A tool: pressed, then selected. The ring never moves; the tint
        // goes over the release.
        var tool = ShotCell.Fade()
        tool.head(for: Look(down: 1, ring: 1, accent: 1), at: 5)
        #expect(tool.look(at: 5) == Look(down: 1, ring: 1, accent: 1), "on the frame of the press")
        tool.head(for: Look(ring: 1, accent: 1), at: 6)
        let half = tool.look(at: 6 + t.release / 2000)
        #expect(near(half.down, 0.5) && half.ring == 1 && half.accent == 1)
        #expect(tool.look(at: 7) == Look(ring: 1, accent: 1))

        // Undo: pressed, then let go. Everything goes over the release.
        var once = ShotCell.Fade()
        once.head(for: Look(down: 1, ring: 1, accent: 1), at: 5)
        once.head(for: Look(hover: 1, hairline: 1), at: 6)
        let mid = once.look(at: 6 + t.release / 2000)
        #expect(near(mid.down, 0.5) && near(mid.ring, 0.5) && near(mid.accent, 0.5))
        #expect(once.look(at: 7) == Look(hover: 1, hairline: 1))

        // A tool that stops being the tool: its ring goes over the shorter
        // time.
        var was = ShotCell.Fade(showing: Look(ring: 1, accent: 1))
        was.head(for: Look(), at: 9)
        #expect(near(was.look(at: 9 + t.deselect / 2000).ring, 0.5))
        #expect(was.look(at: 9 + t.deselect / 1000 + 0.001).ring == 0)
        #expect(t.press == 0 && t.deselect < t.release)
    }

    @Test func becomingUnavailableIsAtOnceAndSoIsEverythingWhenMotionIsReduced() {
        var fade = ShotCell.Fade(showing: Look(hover: 1, hairline: 1))
        fade.head(for: Look(off: true), at: 3)
        #expect(fade.look(at: 3) == Look(off: true))
        #expect(!fade.isMoving(at: 3))

        var still = ShotCell.Fade(still: true)
        still.head(for: Look(hover: 1, hairline: 1), at: 3)
        #expect(still.look(at: 3) == Look(hover: 1, hairline: 1))
        still.head(for: Look(), at: 4)
        #expect(still.look(at: 4) == Look())
    }
}

/// The canvas the furniture is painted on (9.8.4.1, 9.8.4.2, 9.8.6.2).
struct ShotCanvasTests {
    private typealias Shape = ShotCanvas.Shape
    private let red = ShotCanvas.Ink(r: 1, g: 0, b: 0, a: 1)

    @Test func aShapeKnowsHowFarAPointIsFromItsEdge() {
        let box = Shape(x: 10, y: 10, w: 40, h: 20, radius: 0)
        #expect(box.distance(30, 20) == -10)
        #expect(box.distance(10, 20) == 0)
        #expect(box.distance(55, 20) == 5)
        // A corner of a rounded shape is a quarter circle.
        let round = Shape(x: 0, y: 0, w: 40, h: 40, radius: 10)
        #expect(abs(round.distance(10, 10) + 10) < 1e-9, "the centre of the corner's circle")
        #expect(abs(round.distance(0, 0) - (200.0.squareRoot() - 10)) < 1e-9)
        #expect(Shape.circle(cx: 20, cy: 20, diameter: 16).distance(20, 20) == -8)
        #expect(box.grown(by: 2) == Shape(x: 8, y: 8, w: 44, h: 24, radius: 2))
    }

    @Test func aFillCoversWhatIsInsideAndHalfOfAPixelItCutsInHalf() {
        var canvas = ShotCanvas(width: 20, height: 20)
        // From x = 4.5: the pixel at 4 is half covered.
        canvas.fill(Shape(x: 4.5, y: 4, w: 10, h: 10, radius: 0), red)
        #expect(canvas.colour(8, 8).a == 1 && canvas.colour(8, 8).r == 255)
        #expect(canvas.colour(4, 8).a == 0.5)
        #expect(canvas.colour(3, 8).a == 0)
        #expect(canvas.colour(8, 3).a == 0 && canvas.colour(8, 14).a == 0)
    }

    @Test func aLineInsideAnEdgeIsAsThickAsItIsTold() {
        var canvas = ShotCanvas(width: 40, height: 40)
        canvas.strokeInside(Shape(x: 5, y: 5, w: 30, h: 30, radius: 0), thickness: 3, red)
        let across = (0..<40).map { canvas.colour($0, 20).a }
        #expect(across[4] == 0)
        #expect(across[5] == 1 && across[6] == 1 && across[7] == 1)
        #expect(across[8] == 0 && across[20] == 0)
        #expect(across[32] == 1 && across[34] == 1 && across[35] == 0)
        // Outside it: the same line on the other side of the edge.
        var out = ShotCanvas(width: 40, height: 40)
        out.strokeOutside(Shape(x: 5, y: 5, w: 30, h: 30, radius: 0), thickness: 2, red)
        #expect(out.colour(3, 20).a == 1 && out.colour(4, 20).a == 1)
        #expect(out.colour(5, 20).a == 0 && out.colour(2, 20).a == 0)
    }

    @Test func theGlowIsTheSpecificationsTable() {
        // 9.8.4.2: 0.40 x half of erfc(d / (sigma root 2)), both sides of
        // the edge. With sigma 2: 0.200, 0.123, 0.063, 0.027, 0.009.
        let want = [0.200, 0.123, 0.063, 0.027, 0.009]
        for (d, alpha) in want.enumerated() {
            let got = ShotLook.Colour.glow.a * ShotCanvas.tail(Double(d), sigma: ShotLook.Size.glowSigma)
            #expect(abs(got - alpha) < 0.0006, "at \(d) pt: \(got)")
        }
        // Painted: sigma 4 px, sampled where the pixel centres are.
        var canvas = ShotCanvas(width: 80, height: 80)
        let shape = Shape(x: 20, y: 20, w: 40, h: 40, radius: 0)
        canvas.glow(shape, sigma: 4, ShotCanvas.Ink(ShotLook.Colour.glow))
        let peak = ShotLook.Colour.glow.a
        #expect(abs(canvas.colour(19, 40).a - peak * ShotCanvas.tail(0.5, sigma: 4)) < 1e-9, "just outside")
        #expect(abs(canvas.colour(20, 40).a - peak * ShotCanvas.tail(0.5, sigma: 4)) < 1e-9, "just inside: the same")
        #expect(abs(canvas.colour(15, 40).a - peak * ShotCanvas.tail(4.5, sigma: 4)) < 1e-9)
        #expect(canvas.colour(5, 40).a == 0, "past three sigma there is nothing")
        #expect(canvas.colour(40, 40).a == 0, "nor in the middle of the cell")
    }

    @Test func aShadowGoesUnderWhatIsThere() {
        var canvas = ShotCanvas(width: 60, height: 60)
        let shape = Shape(x: 20, y: 20, w: 20, h: 20, radius: 0)
        canvas.fill(shape, red)
        canvas.shadow(of: shape, dy: 4, sigma: 3, ShotCanvas.Ink(r: 0, g: 0, b: 0, a: 0.5))
        // Under the shape nothing changed; below it there is shadow.
        #expect(canvas.colour(30, 30).r == 255 && canvas.colour(30, 30).a == 1)
        let below = canvas.colour(30, 42)
        #expect(below.r == 0 && below.a > 0.2 && below.a <= 0.5)
        #expect(canvas.colour(30, 58).a < 0.01)
    }
}

/// Plates and cells (9.8.3, 9.8.4, 9.8.6.2; criteria 9.8.13 B, C, D).
struct ShotChromeTests {
    private func flat(_ v: UInt8) throws -> ShotChrome.Glass {
        var bytes = [UInt8](repeating: 255, count: 400 * 300 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = v
            bytes[i + 1] = v
            bytes[i + 2] = v
        }
        let picture = try #require(ShotBlur.Picture(width: 400, height: 300, rgbx: bytes))
        return ShotChrome.Glass(prepared: try #require(ShotBlur.prepare(picture, scale: 2)), origin: PixelPoint(0, 0), scale: 2)
    }

    private func plate(_ glass: ShotChrome.Glass?, opaque: Bool = false) -> (canvas: ShotCanvas, at: (Int, Int)) {
        let rect = PixelRect(100, 100, 200, 80)
        var painted = ShotChrome.canvas(for: rect, scale: 2)
        ShotChrome.plate(
            into: &painted.canvas, rect: rect, origin: painted.origin, radius: ShotLook.Size.plateRadius,
            on: .init(scale: 2, glass: glass, access: .init(opaque: opaque)))
        return (painted.canvas, (rect.x - painted.origin.x, rect.y - painted.origin.y))
    }

    @Test func aPlateIsDarkGlassOnAnythingAndOpaqueWhenAskedToBe() throws {
        // 9.8.3: over white about #3E4041, over black about #131415.
        let onWhite = plate(try flat(255))
        let w = onWhite.canvas.colour(onWhite.at.0 + 100, onWhite.at.1 + 40)
        #expect(abs(w.r - 0x3E) <= 3 && abs(w.g - 0x40) <= 3 && abs(w.b - 0x41) <= 3 && w.a == 1, "\(w)")
        let onBlack = plate(try flat(0))
        let b = onBlack.canvas.colour(onBlack.at.0 + 100, onBlack.at.1 + 40)
        #expect(abs(b.r - 0x13) <= 3 && abs(b.g - 0x14) <= 3 && abs(b.b - 0x15) <= 3, "\(b)")

        // Transparency reduced: the opaque ground and a one-point edge.
        let plain = plate(try flat(255), opaque: true)
        let p = plain.canvas.colour(plain.at.0 + 100, plain.at.1 + 40)
        #expect(p.r == 0x3D && p.g == 0x3F && p.b == 0x40 && p.a == 1)
        let edge = plain.canvas.colour(plain.at.0 + 100, plain.at.1)
        #expect(edge.r == 0x8E && edge.g == 0x8F && edge.b == 0x90)
        // No glass yet: the same opaque plate rather than nothing.
        let early = plate(nil)
        #expect(early.canvas.colour(early.at.0 + 100, early.at.1 + 40).r == 0x3D)
    }

    @Test func aPlateHasAShadowBelowItAndRoundCorners() throws {
        let made = plate(try flat(255))
        let c = made.canvas
        // The corner pixel of the rectangle is outside the rounded plate.
        #expect(c.colour(made.at.0, made.at.1).a < 0.5)
        // Under the plate: shadow, darker than at its side.
        let under = c.colour(made.at.0 + 100, made.at.1 + 80 + 6).a
        let beside = c.colour(made.at.0 - 6, made.at.1 + 40).a
        #expect(under > beside && under > 0.1)
        // And it has ended before the canvas does.
        #expect(c.colour(made.at.0 + 100, c.height - 1).a < 0.02)
        #expect(c.colour(0, made.at.1 + 40).a < 0.02)
    }

    @Test func whatEachButtonShows() {
        #expect(ShotChrome.content(of: .tool(.select), props: .none) == .icon("select"))
        #expect(ShotChrome.content(of: .tool(.highlighter), props: .stroke) == .icon("highlighter"))
        #expect(ShotChrome.content(of: .undo, props: .none) == .icon("undo"))
        #expect(ShotChrome.content(of: .long, props: .none) == .icon("long"))
        #expect(ShotChrome.content(of: .done, props: .none) == .icon("done"))
        #expect(ShotChrome.content(of: .colour(5), props: .stroke) == .swatch(ShotStyle.colour(5)))
        // A step is a dot, a T or a chequerboard, by what it is a step of.
        #expect(ShotChrome.content(of: .level(0), props: .stroke) == .dot(3))
        #expect(ShotChrome.content(of: .level(4), props: .stroke) == .dot(15))
        #expect(ShotChrome.content(of: .level(0), props: .font) == .icon("font1"))
        #expect(ShotChrome.content(of: .level(4), props: .font) == .icon("font5"))
        #expect(ShotChrome.content(of: .level(0), props: .block) == .blocks(6))
        #expect(ShotChrome.content(of: .level(4), props: .block) == .blocks(2))
        // Every icon a button asks for exists.
        for tool in AnnotationTool.allCases { #expect(ShotLook.icon(tool.name) != nil, "\(tool.name)") }
    }

    private func cell(_ content: ShotChrome.Content, _ look: ShotCell.Look, opaque: Bool = false) -> ShotCanvas {
        // A 56 px cell at (20, 20) of an 96 px canvas, scale 2.
        var canvas = ShotCanvas(width: 96, height: 96)
        ShotChrome.cell(
            into: &canvas, rect: PixelRect(20, 20, 56, 56), origin: PixelPoint(0, 0), content: content,
            look: look, on: .init(scale: 2, glass: nil, access: .init(opaque: opaque)))
        return canvas
    }

    @Test func theRingIsThreePixelsOfTheAccentAndItGlows() {
        let c = cell(.dot(8), ShotCell.Look(ring: 1, accent: 1))
        let accent = ShotLook.Colour.accent
        // Across the left edge, half way down: three pixels of ring.
        for x in 20..<23 {
            let p = c.colour(x, 48)
            #expect(p.r == Int(accent.r) && p.g == Int(accent.g) && p.b == Int(accent.b) && p.a > 0.99, "x=\(x): \(p)")
        }
        // Outside it the glow, in the accent, fading; gone by ten pixels.
        #expect(c.colour(19, 48).a > 0.1 && c.colour(19, 48).b == 255)
        #expect(c.colour(17, 48).a < c.colour(19, 48).a)
        #expect(c.colour(8, 48).a < 0.01)
        // Inside it too, and the dot in the middle is the accent's.
        #expect(c.colour(24, 48).a > 0.05 && c.colour(24, 48).a < 0.25)
        let dot = c.colour(48, 48)
        #expect(dot.r == Int(accent.r) && dot.b == Int(accent.b) && dot.a == 1)
        // With transparency reduced: the ring, and no glow.
        let plain = cell(.dot(8), ShotCell.Look(ring: 1, accent: 1), opaque: true)
        #expect(plain.colour(21, 48).a > 0.99 && plain.colour(19, 48).a == 0 && plain.colour(24, 48).a == 0)
    }

    @Test func hoverIsNeutralAndAPressIsBlue() {
        let hover = cell(.dot(3), ShotCell.Look(hover: 1, hairline: 1))
        let h = hover.colour(40, 40)
        #expect(h.r == 255 && h.g == 255 && h.b == 255, "white, thin: nothing of the accent")
        #expect(abs(h.a - ShotLook.Colour.hover.a) < 1e-9)
        #expect(hover.colour(19, 48).a == 0, "and no glow outside it")
        #expect(hover.colour(20, 48).a > h.a, "the hairline on its edge")
        let down = cell(.dot(3), ShotCell.Look(down: 1, ring: 1, accent: 1))
        let d = down.colour(40, 40)
        #expect(d.b > d.r, "tinted with the accent: \(d)")
        #expect(down.colour(21, 48).a > 0.99)
        // "Done" held down: solid accent, and its tick is white.
        let solid = cell(.icon("done"), ShotCell.Look(ring: 1, solid: 1))
        let s = solid.colour(30, 30)
        #expect(s.r == Int(ShotLook.Colour.accent.r) && s.b == 255 && s.a == 1)
        let ink = (20..<76).flatMap { y in (20..<76).map { solid.colour($0, y) } }
        #expect(ink.contains { $0.r == 255 && $0.g == 255 && $0.b == 255 }, "a white tick")
    }

    @Test func aSwatchKeepsItsColourAndWhatCannotBePressedIsFaint() {
        // Selected: the cell has the ring, the swatch is still red.
        let red = cell(.swatch(ShotStyle.colour(0)), ShotCell.Look(ring: 1, accent: 1))
        let middle = red.colour(48, 48)
        #expect(middle.r == 0xE6 && middle.g == 0x28 && middle.b == 0x28)
        // 16 pt across: 32 px, so 16 px from the middle is its edge and
        // there are at least 8 px of nothing between it and the ring.
        #expect(red.colour(48 - 15, 48).r == 0xE6)
        for x in 24...30 { #expect(red.colour(x, 48).r != 0xE6, "x=\(x)") }
        // Unavailable: the icon at a third of the ink, nothing else.
        let off = cell(.icon("undo"), ShotCell.Look(off: true))
        let alphas = (20..<76).flatMap { y in (20..<76).map { off.colour($0, y).a } }
        #expect(abs(alphas.max()! - ShotLook.Colour.inkOff.a) < 0.01)
        #expect(off.colour(21, 48).a == 0)
    }

    @Test func theFiveStepsOfEachKindGrow() {
        func inked(_ content: ShotChrome.Content) -> Int {
            let c = cell(content, ShotCell.Look())
            return (0..<96).reduce(0) { n, y in n + (0..<96).filter { c.colour($0, y).a > 0.5 }.count }
        }
        let dots = (0..<5).map { inked(ShotChrome.content(of: .level($0), props: .stroke)) }
        let fonts = (0..<5).map { inked(ShotChrome.content(of: .level($0), props: .font)) }
        #expect(dots == dots.sorted() && Set(dots).count == 5, "\(dots)")
        #expect(fonts == fonts.sorted() && Set(fonts).count == 5, "\(fonts)")
        // A chequerboard of n squares a side: the squares get bigger.
        let c6 = cell(.blocks(6), ShotCell.Look()), c2 = cell(.blocks(2), ShotCell.Look())
        func run(_ c: ShotCanvas) -> Int {
            // The first run of ink along the row just under the frame's top.
            var n = 0
            for x in 0..<96 {
                if c.colour(x, 40).a > 0.9 { n += 1 } else if n > 0 { break }
            }
            return n
        }
        #expect(run(c2) > run(c6) * 2, "\(run(c2)) and \(run(c6))")
    }
}
