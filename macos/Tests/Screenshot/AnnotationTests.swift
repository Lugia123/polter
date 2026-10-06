import Foundation
import Testing
@testable import Ghostty

/// The Windows host's `annot.rs` tests for the model, with the same
/// fixtures and the same numbers (`dev-docs/poltergeist/screenshot.md`,
/// 9.4 and 9.7).
struct AnnotationTests {
    private typealias Pt = PixelPoint
    private let it = ShotFixtures.item
    private let text = ShotFixtures.text
    private let number = ShotFixtures.number

    // MARK: Hitting

    @Test func aHollowRectangleIsHitOnItsOutlineNotItsInside() {
        let r = it(.rect(PixelRect(100, 100, 200, 100)))
        #expect(r.hit(Pt(100, 150), scale: 1))
        #expect(r.hit(Pt(200, 200), scale: 1))
        // Within reach outside the right edge.
        #expect(r.hit(Pt(303, 150), scale: 1))
        // The middle is not the rectangle.
        #expect(!r.hit(Pt(200, 150), scale: 1))
        #expect(!r.hit(Pt(310, 150), scale: 1))
    }

    @Test func anEllipseIsHitOnItsOutlineNotItsInside() {
        let e = it(.ellipse(PixelRect(100, 100, 200, 100)))
        #expect(e.hit(Pt(100, 150), scale: 1))
        #expect(e.hit(Pt(200, 100), scale: 1))
        #expect(!e.hit(Pt(200, 150), scale: 1))
        // The corner of its box is outside the ellipse.
        #expect(!e.hit(Pt(100, 100), scale: 1))
    }

    @Test func aLineIsHitAlongItsLengthWithinReach() {
        let l = it(.line(from: Pt(100, 100), to: Pt(300, 100)))
        #expect(l.hit(Pt(200, 100), scale: 1))
        // Four pixels off a thin line still counts.
        #expect(l.hit(Pt(200, 104), scale: 1))
        #expect(!l.hit(Pt(200, 105), scale: 1))
        // Past the end.
        #expect(!l.hit(Pt(306, 100), scale: 1))
        var thick = l
        thick.level = 4
        #expect(thick.hit(Pt(200, 105), scale: 1))
        // The reach is in points, so it doubles at 200%.
        #expect(l.hit(Pt(200, 108), scale: 2))
        let h = Annotation(shape: .highlighter([Pt(100, 100), Pt(300, 100)]), colour: 2, level: 3)
        #expect(h.hit(Pt(200, 112), scale: 1))
        #expect(!h.hit(Pt(200, 113), scale: 1))
    }

    @Test func aFreehandStrokeIsHitOnAnyOfItsSegments() {
        let p = it(.pen([Pt(0, 0), Pt(100, 0), Pt(100, 100)]))
        #expect(p.hit(Pt(50, 2), scale: 1))
        #expect(p.hit(Pt(98, 60), scale: 1))
        // Inside the corner it turns, but on neither segment.
        #expect(!p.hit(Pt(50, 50), scale: 1))
    }

    @Test func textNumbersAndMosaicsAreHitAnywhereInTheirBox() {
        let t = it(text(Pt(100, 100), "hello"))
        #expect(t.hit(Pt(120, 110), scale: 1))
        // Past its measured width of 50.
        #expect(!t.hit(Pt(151, 110), scale: 1))
        let n = it(number(1, Pt(100, 100), ""))
        #expect(Annotation.numberRadius(level: 1, scale: 1) == 14)
        #expect(n.hit(Pt(110, 110), scale: 1))
        #expect(!n.hit(Pt(120, 100), scale: 1))
        let withCaption = it(number(1, Pt(100, 100), "hello"))
        #expect(withCaption.hit(Pt(140, 100), scale: 1))
        let m = it(.mosaic(PixelRect(0, 0, 50, 50)))
        // A mosaic is solid.
        #expect(m.hit(Pt(25, 25), scale: 1))
        #expect(!m.hit(Pt(50, 25), scale: 1))
    }

    @Test func theTopmostAnnotationUnderThePointIsTheOneHit() {
        let items = [
            it(.mosaic(PixelRect(0, 0, 200, 200))),
            it(.line(from: Pt(0, 100), to: Pt(200, 100))),
            it(.rect(PixelRect(50, 50, 100, 100))),
        ]
        // The line, drawn over the mosaic.
        #expect(Annotation.hitTest(items, at: Pt(100, 100), scale: 1) == 1)
        // The rectangle's edge, drawn last.
        #expect(Annotation.hitTest(items, at: Pt(50, 100), scale: 1) == 2)
        #expect(Annotation.hitTest(items, at: Pt(20, 20), scale: 1) == 0)
        #expect(Annotation.hitTest(items, at: Pt(300, 300), scale: 1) == nil)
    }

    // MARK: Moving and reshaping

    @Test func movingKeepsEverythingButThePosition() {
        let before = Annotation(shape: number(3, Pt(10, 20), "x"), colour: 4, level: 2)
        #expect(before.moved(dx: 5, dy: -7) == Annotation(shape: number(3, Pt(15, 13), "x"), colour: 4, level: 2))
        #expect(it(.pen([Pt(0, 0), Pt(1, 1)])).moved(dx: 10, dy: 10).shape == .pen([Pt(10, 10), Pt(11, 11)]))
        #expect(it(.mosaic(PixelRect(1, 2, 3, 4))).moved(dx: 1, dy: 1).shape == .mosaic(PixelRect(2, 3, 3, 4)))
    }

    @Test func boxesHaveEightGripsLinesTwoAndTheRestNone() {
        let b = PixelRect(0, 0, 10, 10)
        for shape in [Annotation.Shape.rect(b), .ellipse(b), .mosaic(b)] {
            #expect(it(shape).grips.count == 8)
        }
        let l = it(.arrow(from: Pt(1, 2), to: Pt(30, 40)))
        #expect(l.grips.map(\.grip) == [.end(false), .end(true)])
        #expect(l.grips.map(\.at) == [Pt(1, 2), Pt(30, 40)])
        let stroke = [Pt(0, 0), Pt(9, 9)]
        for shape in [Annotation.Shape.pen(stroke), .highlighter(stroke), text(Pt(0, 0), "x"), number(1, Pt(0, 0), "")] {
            #expect(it(shape).grips.isEmpty)
        }
    }

    @Test func aGripReshapesOnlyWhatItHolds() {
        let r = it(.rect(PixelRect(100, 100, 200, 100)))
        #expect(r.grip(at: Pt(302, 198), reach: 4) == .box(.se))
        #expect(r.grip(at: Pt(200, 150), reach: 4) == nil)
        #expect(r.reshaped(.box(.se), to: Pt(350, 250)).shape == .rect(PixelRect(100, 100, 250, 150)))
        #expect(r.reshaped(.box(.w), to: Pt(50, 999)).shape == .rect(PixelRect(50, 100, 250, 100)))
        #expect(r.reshaped(.box(.n), to: Pt(0, -500)).shape == .rect(PixelRect(100, -500, 200, 700)))
        let a = it(.arrow(from: Pt(0, 0), to: Pt(10, 10)))
        #expect(a.reshaped(.end(true), to: Pt(50, 5)).shape == .arrow(from: Pt(0, 0), to: Pt(50, 5)))
        #expect(a.reshaped(.end(false), to: Pt(-5, -5)).shape == .arrow(from: Pt(-5, -5), to: Pt(10, 10)))
        // A grip that is not the shape's changes nothing.
        #expect(a.reshaped(.box(.n), to: Pt(99, 99)) == a)
        #expect(r.reshaped(.end(true), to: Pt(99, 99)) == r)
    }

    @Test func shiftMakesASquareAndSnapsALineToFortyFiveDegrees() {
        #expect(Annotation.squareCorner(from: Pt(100, 100), to: Pt(180, 130)) == Pt(180, 180))
        // Left and down.
        #expect(Annotation.squareCorner(from: Pt(100, 100), to: Pt(60, 190)) == Pt(10, 190))
        #expect(Annotation.squareCorner(from: Pt(100, 100), to: Pt(100, 100)) == Pt(100, 100))
        #expect(Annotation.snap45(from: Pt(0, 0), to: Pt(100, 8)) == Pt(100, 0))
        #expect(Annotation.snap45(from: Pt(0, 0), to: Pt(100, 90)) == Pt(95, 95))
        #expect(Annotation.snap45(from: Pt(0, 0), to: Pt(-5, -100)) == Pt(0, -100))
        #expect(Annotation.snap45(from: Pt(50, 50), to: Pt(50, 50)) == Pt(50, 50))
    }

    @Test func whatIsTooSmallToKeep() {
        #expect(it(.rect(PixelRect(0, 0, 1, 50))).isDegenerate)
        #expect(!it(.rect(PixelRect(0, 0, 2, 2))).isDegenerate)
        #expect(it(.mosaic(PixelRect(0, 0, 50, 1))).isDegenerate)
        #expect(it(.ellipse(PixelRect(0, 0, 1, 1))).isDegenerate)
        #expect(it(.line(from: Pt(1, 1), to: Pt(1, 1))).isDegenerate)
        #expect(!it(.line(from: Pt(1, 1), to: Pt(1, 2))).isDegenerate)
        #expect(it(.pen([Pt(1, 1)])).isDegenerate)
        #expect(!it(.highlighter([Pt(1, 1), Pt(2, 2)])).isDegenerate)
        #expect(it(text(Pt(0, 0), "  \n ")).isDegenerate)
        // A number with no sentence is still a number.
        #expect(!it(number(1, Pt(0, 0), "")).isDegenerate)
    }

    @Test func boundsTakeInTheStrokeAndTheCaption() {
        let r = Annotation(shape: .rect(PixelRect(100, 100, 50, 50)), colour: 0, level: 4)
        #expect(r.bounds(scale: 1) == PixelRect(95, 95, 60, 60))
        #expect(it(.mosaic(PixelRect(1, 2, 3, 4))).bounds(scale: 1) == PixelRect(1, 2, 3, 4))
        let n = it(number(1, Pt(100, 100), "hello"))
        #expect(Annotation.captionOrigin(at: Pt(100, 100), level: 1, scale: 1, captionHeight: 18) == Pt(119, 91))
        #expect(n.bounds(scale: 1) == PixelRect(left: 86, top: 86, right: 169, bottom: 114))
    }

    @Test func theNumbersCircleIsOneAndAHalfTimesTheFont() {
        // 18 px font: diameter 27, so a radius of 14 (13.5 rounded up).
        #expect(Annotation.numberRadius(level: 1, scale: 1) == 14)
        #expect(Annotation.numberRadius(level: 1, scale: 2) == 27)
        #expect(Annotation.numberRadius(level: 4, scale: 1) == 33)
    }

    // MARK: Numbering

    @Test func theNextNumberFollowsTheHighestAndDeletingOneDoesNotRenumber() {
        var items = [it(number(1, Pt(412, 96), "x")), it(.rect(PixelRect(0, 0, 5, 5)))]
        #expect(Annotation.nextNumber([]) == 1)
        #expect(Annotation.nextNumber(items) == 2)
        items.append(it(number(2, Pt(0, 0), "")))
        items.append(it(number(3, Pt(0, 0), "")))
        #expect(Annotation.nextNumber(items) == 4)
        // ② goes; ③ stays ③.
        items.remove(at: 2)
        #expect(Annotation.nextNumber(items) == 4)
        items.removeLast()
        #expect(Annotation.nextNumber(items) == 2)
    }

    @Test func aBoundingBoxIncludesBothEnds() {
        #expect(Annotation.bbox([Pt(10, 10), Pt(89, 30), Pt(40, 49)]) == PixelRect(10, 10, 80, 40))
        #expect(Annotation.bbox([Pt(5, 6)]) == PixelRect(5, 6, 1, 1))
        #expect(Annotation.bbox([]) == nil)
    }

    // MARK: Leaving

    @Test func annotationsOnTheScreenLandOnTheImageAndThoseOutsideAreLeftOut() {
        let selection = PixelRect(-3000, 100, 1280, 800)
        let onScreen = [
            it(number(1, Pt(-2588, 196), "x")),
            it(.rect(PixelRect(-2620, 180, 240, 44))),
            it(.pen([Pt(-2990, 110), Pt(-2911, 149)])),
            // Wholly to the left of the selection.
            it(.rect(PixelRect(-3500, 200, 100, 100))),
            // Hanging off its right edge: kept, with its true geometry.
            it(.ellipse(PixelRect(-1800, 200, 200, 100))),
            // Wholly below it.
            it(text(Pt(-2900, 1000), "below")),
        ]
        #expect(Annotation.exported(onScreen, selection: selection, scale: 1) == [
            it(number(1, Pt(412, 96), "x")),
            it(.rect(PixelRect(380, 80, 240, 44))),
            it(.pen([Pt(10, 10), Pt(89, 49)])),
            it(.ellipse(PixelRect(1200, 100, 200, 100))),
        ])
    }

    @Test func aStrokeThatOnlyTouchesTheSelectionWithItsThicknessIsStillExported() {
        let selection = PixelRect(100, 100, 200, 200)
        let near = Annotation(shape: .line(from: Pt(96, 150), to: Pt(96, 250)), colour: 0, level: 4)
        #expect(Annotation.exported([near], selection: selection, scale: 2).count == 1)
        var thin = near
        thin.level = 0
        #expect(Annotation.exported([thin], selection: selection, scale: 1).isEmpty)
    }
}
