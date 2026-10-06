import Foundation
import Testing
@testable import Ghostty

/// The Windows host's `textbox.rs` tests, with the same fixtures and the
/// same numbers (`dev-docs/poltergeist/screenshot.md`, 9.3).
struct ShotTextBoxTests {
    private typealias Pt = PixelPoint
    private typealias Box = ShotTextBox

    /// A line of the annotation font is taller than its size; the hosts
    /// measure it. This is near what Noto Sans SC gives and is only a
    /// stand-in: nothing here depends on the ratio.
    private func line(of fontPx: Int) -> Int { (fontPx * 29 + 19) / 20 }

    private func bars(_ selection: PixelRect, _ display: PixelRect, _ scale: Double) -> [PixelRect] {
        let l = ShotToolbarGrid.layout(selection: selection, display: display, scale: scale, props: .font)
        return [l.bar] + (l.props.map { [$0] } ?? [])
    }

    private func within(_ inner: PixelRect, _ outer: PixelRect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y && inner.right <= outer.right && inner.bottom <= outer.bottom
    }

    /// The reading the Windows test machine brought back (task 1104): a
    /// 900x500 selection at 144 DPI, the largest size, opened at (1450,650).
    @Test func theBoxTheTestMachineMeasuredNoLongerReachesTheToolbar() {
        let scale = 1.5
        let display = PixelRect(0, 0, 2560, 1600)
        let selection = PixelRect(left: 1350, top: 300, right: 2250, bottom: 800)
        let keep = bars(selection, display, scale)
        let font = ShotStyle.fontPx(level: 4, scale: scale)
        #expect(font == 66)
        // What it was: four lines whatever was typed, 264 px, to y = 914,
        // over a toolbar that starts under the selection at 812.
        #expect(keep.first?.y == 812)
        #expect(650 + font * 4 > 812)

        let line = line(of: font)
        let minW = Box.minWidth(fontPx: font, scale: scale)
        let at = Box.origin(click: Pt(1450, 650), line: line, minW: minW, selection: selection, keepClear: keep)
        #expect(at == Pt(1450, 650), "there is room: the text starts where it was pressed")
        func box(_ lines: Int) -> PixelRect {
            Box.rect(at: at, lines: lines, line: line, minW: minW, selection: selection, display: display, keepClear: keep)
        }
        #expect(box(1) == PixelRect(1450, 650, 800, line))
        // It grows a line at a time and stops at the selection's bottom.
        #expect(box(2).h == min(2 * line, (800 - 650) / line * line))
        #expect(box(40).h == (800 - 650) / line * line)
        #expect(box(40).bottom <= selection.bottom)
        for r in keep { #expect(box(40).intersect(r) == nil) }
    }

    @Test func atEverySizeAndScaleTheBoxIsInTheSelectionWholeLinesTallAndOffTheToolbar() {
        var checked = 0
        for scale in [1.0, 1.5, 2.0] {
            let display = PixelRect(0, 0, 2560, 1600)
            // Under it, over it (no room under), and inside its bottom edge
            // (as tall as the display): the three places a toolbar goes.
            let selections = [
                PixelRect(left: 400, top: 300, right: 1300, bottom: 800),
                PixelRect(left: 400, top: 900, right: 1300, bottom: 1590),
                PixelRect(left: 400, top: 0, right: 1300, bottom: 1600),
            ]
            for selection in selections {
                let keep = bars(selection, display, scale)
                for level in 0..<ShotStyle.levels {
                    let font = ShotStyle.fontPx(level: level, scale: scale)
                    let line = line(of: font), minW = Box.minWidth(fontPx: font, scale: scale)
                    // Pressed at the top, in the middle, and on the last
                    // pixel row; and at the left, and on the last column.
                    for clickY in [selection.y, selection.y + selection.h / 2, selection.bottom - 1] {
                        for clickX in [selection.x, selection.x + selection.w / 2, selection.right - 1] {
                            let click = Pt(clickX, clickY)
                            // That press is the toolbar's, not a text.
                            if Box.onToolbar(click, keepClear: keep) { continue }
                            let at = Box.origin(click: click, line: line, minW: minW, selection: selection, keepClear: keep)
                            for typed in [1, 2, 3, 50] {
                                let b = Box.rect(
                                    at: at, lines: typed, line: line, minW: minW,
                                    selection: selection, display: display, keepClear: keep)
                                let what: Comment =
                                    "scale \(scale) selection \(selection) level \(level) click \(click) lines \(typed): \(b)"
                                #expect(within(b, selection), what)
                                #expect(b.h % line == 0, what)
                                #expect(b.h >= line && b.h <= typed * line, what)
                                #expect(b.w >= minW, what)
                                #expect(keep.allSatisfy { b.intersect($0) == nil }, what)
                                // One line where it was pressed, when it fits there.
                                if typed == 1, click.y + line <= selection.bottom,
                                   !keep.contains(where: { $0.y > click.y && $0.y < click.y + line }) {
                                    #expect(at.y == click.y, what)
                                    #expect(b.h == line, what)
                                }
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 1000, "the loops ran")
    }

    @Test func aNewTextIsPulledOnlyAsFarAsOneLineNeeds() {
        let selection = PixelRect(left: 100, top: 100, right: 700, bottom: 500)
        func origin(_ p: Pt, _ keep: [PixelRect] = [], in s: PixelRect? = nil) -> Pt {
            Box.origin(click: p, line: 30, minW: 120, selection: s ?? selection, keepClear: keep)
        }
        // Room: where it was pressed.
        #expect(origin(Pt(300, 200)) == Pt(300, 200))
        // On the bottom row: up by a line, less the row it was on.
        #expect(origin(Pt(300, 499)) == Pt(300, 470))
        #expect(origin(Pt(300, 470)) == Pt(300, 470))
        #expect(origin(Pt(300, 471)) == Pt(300, 470))
        // On the last column: left until the narrowest box fits.
        #expect(origin(Pt(699, 200)) == Pt(580, 200))
        // A toolbar inside the selection's bottom edge is the floor instead.
        #expect(origin(Pt(350, 430), [PixelRect(300, 440, 400, 50)]) == Pt(350, 410))
        // One outside it is not: the selection's edge already keeps clear.
        #expect(origin(Pt(350, 499), [PixelRect(300, 508, 400, 50)]) == Pt(350, 470))
        // A selection that cannot hold a line: its own corner.
        #expect(origin(Pt(140, 105), in: PixelRect(left: 100, top: 100, right: 150, bottom: 110)) == Pt(100, 100))
    }

    @Test func aTextEditedAgainOutsideTheSelectionStopsAtTheToolbarOrTheDisplay() {
        let display = PixelRect(0, 0, 1920, 1080)
        let selection = PixelRect(left: 100, top: 100, right: 700, bottom: 500)
        func box(_ at: Pt, _ lines: Int, _ keep: [PixelRect] = []) -> PixelRect {
            Box.rect(at: at, lines: lines, line: 30, minW: 120, selection: selection, display: display, keepClear: keep)
        }
        // Left behind above the selection when it was moved: the selection
        // is not its floor, the display is.
        #expect(box(Pt(200, 20), 99).h == (1080 - 20) / 30 * 30)
        // Beside the toolbar's top: it ends there.
        let bar = PixelRect(300, 508, 400, 40)
        #expect(box(Pt(350, 20), 99, [bar]).bottom == 20 + (508 - 20) / 30 * 30)
        #expect(box(Pt(350, 20), 99, [bar]).bottom <= bar.y)
        // A toolbar off to the side of the box is no floor.
        #expect(box(Pt(720, 20), 2, [PixelRect(900, 30, 100, 40)]).h == 60)
        // Sitting on the toolbar already: one line, and the press is the
        // toolbar's all the same.
        #expect(box(Pt(350, 520), 3, [bar]).h == 30)
        #expect(Box.onToolbar(Pt(360, 525), keepClear: [bar]))
        #expect(!Box.onToolbar(Pt(360, 560), keepClear: [bar]))
    }

    @Test func theWidthRunsToTheSelectionsEdgeAndIsNeverTooNarrowToTypeIn() {
        let display = PixelRect(0, 0, 1920, 1080)
        let selection = PixelRect(left: 100, top: 100, right: 700, bottom: 500)
        func width(_ at: Pt) -> Int {
            Box.rect(at: at, lines: 1, line: 30, minW: 120, selection: selection, display: display, keepClear: []).w
        }
        #expect(width(Pt(300, 200)) == 400)
        // Past the selection's right edge (a text left there): the least.
        #expect(width(Pt(690, 200)) == 120)
        // At the display's edge there is only what there is.
        #expect(width(Pt(1900, 200)) == 20)
        for (level, points) in ShotStyle.fonts.enumerated() {
            #expect(Box.minWidth(fontPx: ShotStyle.fontPx(level: level, scale: 1), scale: 1) == max(points * Box.minEms, 40))
        }
    }

    @Test func aLineBreakIsALine() {
        #expect(Box.lines(in: "") == 1)
        #expect(Box.lines(in: "abc") == 1)
        #expect(Box.lines(in: "a\nb") == 2)
        #expect(Box.lines(in: "a\n") == 2)
        #expect(Box.lines(in: "\n\n") == 3)
    }
}
