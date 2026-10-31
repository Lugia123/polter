import CoreGraphics
import Foundation
import Testing

@testable import Ghostty

/// Where the terminal and the file preview go in one cell (`PreviewLayout`):
/// the rule in the order it gives way, on numbers small enough to add up by
/// hand (task 2623, #2140 S2).
///
/// With the numbers as the data has them: a cell of at least 800 puts them
/// side by side, the preview wants half the cell and is held between 440 and
/// what leaves the terminal 360, and a narrower cell has the preview over
/// the terminal, 40 of it left in sight. No size is ever negative.
///
/// The same cases the two hosts print for each other, read from
/// `src/poltergeist/testdata/preview_layout_cases.json` and answered here
/// **by hand**: a case whose answer moved is red in this file, and not only
/// in `tools/control-room-hosts-agree.py`.
struct PreviewLayoutTests {
    typealias Layout = PreviewLayout
    typealias Look = ControlRoomLook
    typealias Split = Layout.Split

    private func at(_ cellW: CGFloat, _ open: Bool = true, _ draggedW: CGFloat? = nil) -> Split {
        Layout.split(cellW: cellW, open: open, draggedW: draggedW)
    }

    private func rect(_ s: Split) -> [CGFloat] {
        [s.terminalX, s.terminalWidth, s.previewX, s.previewWidth]
    }

    // MARK: The numbers these tests add up with

    @Test func theNumbersTheseTestsAddUpWith() {
        #expect(Look.Preview.cellMinWidthSideBySide == 800)
        #expect(Look.Preview.terminalMinWidth == 360)
        #expect(Look.Preview.previewMinWidth == 440)
        #expect(Look.Preview.overlayLeftExpose == 40)
        // Half, exactly: `0.5` is a binary fraction, so this compares equal
        // rather than within a tolerance. A data edit to 0.4999 is a
        // different number and is meant to fail here.
        #expect(Look.Preview.previewDefaultFraction == 0.5)
        // The threshold is the two least widths added up, which is where the
        // design's 800 comes from.
        #expect(Look.Preview.cellMinWidthSideBySide
                == Look.Preview.terminalMinWidth + Look.Preview.previewMinWidth)
    }

    // MARK: 1. Nothing is open

    @Test func closedIsTheWholeCellAndNoPreview() {
        for cellW in [CGFloat(0), 400, 800, 2000] {
            let s = at(cellW, false, 500)
            #expect(rect(s) == [0, cellW, 0, 0], "at \(cellW)")
            #expect(!s.overlay, "at \(cellW)")
        }
    }

    // MARK: 2. Side by side

    @Test func theThresholdIsTheLastCellThatCannotHoldBoth() {
        let under = at(799, true, nil)
        #expect(under.overlay, "799 is over the terminal, not beside it")
        #expect(under.terminalWidth == 799, "over the terminal it keeps the whole cell")
        #expect(rect(under) == [0, 799, 40, 759])

        let at800 = at(800, true, nil)
        #expect(!at800.overlay, "800 is the first cell that can hold both")
        // Half the cell is 400, under the preview's 440, so the preview gets
        // its least and the terminal keeps exactly its own.
        #expect(rect(at800) == [0, 360, 360, 440])

        #expect(rect(at(801, true, nil)) == [0, 361, 361, 440])
    }

    @Test func theDefaultIsHalfTheCell() {
        // Wide enough that neither least is reached: exactly half each way.
        #expect(rect(at(1600, true, nil)) == [0, 800, 800, 800])
        #expect(rect(at(1200, true, nil)) == [0, 600, 600, 600])
        #expect(rect(at(900, true, nil)) == [0, 450, 450, 450])
    }

    @Test func aDragIsHeldBetweenTheTwoLeastWidths() {
        #expect(rect(at(1200, true, 600)) == [0, 600, 600, 600])
        // Under the preview's least: the least. Above what leaves the
        // terminal its own: what is left.
        #expect(rect(at(1200, true, 360)) == [0, 760, 760, 440])
        #expect(rect(at(1200, true, -50)) == [0, 760, 760, 440])
        #expect(rect(at(1200, true, 841)) == [0, 360, 360, 840])
        #expect(rect(at(1200, true, 1e9)) == [0, 360, 360, 840])
        // A cell where the two bounds land on the same number: 800 - 360 =
        // 440 = the least the preview may be.
        for dragged in [CGFloat(0), 360, 440, 441, 1000] {
            #expect(rect(at(800, true, dragged)) == [0, 360, 360, 440], "dragged \(dragged)")
        }
    }

    @Test func theTwoWidthsAlwaysAddBackUpToTheCell() {
        for cellW in [CGFloat(800), 801, 1000, 1200, 3000] {
            for dragged in [nil, CGFloat(0), 360, 700, 1e6] as [CGFloat?] {
                let s = at(cellW, true, dragged)
                #expect(s.previewX == s.terminalWidth, "at \(cellW) dragged \(String(describing: dragged))")
                #expect(s.terminalWidth + s.previewWidth == cellW, "at \(cellW) dragged \(String(describing: dragged))")
                #expect(s.terminalWidth >= CGFloat(Look.Preview.terminalMinWidth))
                #expect(s.previewWidth >= CGFloat(Look.Preview.previewMinWidth))
            }
        }
    }

    // MARK: 3. Over the terminal

    @Test func overTheTerminalItLeavesFortyOfItInSight() {
        let s = at(400, true, nil)
        #expect(s.overlay)
        #expect(rect(s) == [0, 400, 40, 360])
        #expect(s.previewX + s.previewWidth == s.terminalWidth, "the preview ends at the cell's right edge")
        #expect(at(400, true, 700) == s, "a drag means nothing when the two are not side by side")
    }

    @Test func theDesignsNarrowCellReadsAsTheOverlayRule() {
        // The design's 03 (`2140/v2/src/metrics.json`): a cell of 424, the
        // preview from 40 in and 384 wide. The same numbers this rule gives.
        #expect(rect(at(424, true, nil)) == [0, 424, 40, 384])
    }

    // MARK: 4. No size is ever negative

    @Test func noSizeIsEverNegative() {
        for cellW in [CGFloat(-1e9), -1000, -5, -0, 0, 1, 39, 39.999, 40, 41, 799, 800, 1e9] {
            for open in [false, true] {
                for dragged in [nil, CGFloat(-1e9), 0, 1e9] as [CGFloat?] {
                    let s = at(cellW, open, dragged)
                    let where_ = "cellW \(cellW) open \(open) dragged \(String(describing: dragged))"
                    for (what, v) in [("terminalX", s.terminalX), ("terminalWidth", s.terminalWidth),
                                      ("previewX", s.previewX), ("previewWidth", s.previewWidth)] {
                        #expect(v >= 0, "\(what) is \(v) at \(where_)")
                        #expect(v.isFinite, "\(what) is \(v) at \(where_)")
                    }
                    // The preview ends at the cell's right edge either way:
                    // beside the terminal, the two add up to the cell; over
                    // it, the preview takes what the cell has past the
                    // inset. Never past it.
                    #expect(s.previewX + s.previewWidth <= max(cellW, 0) + 1e-9,
                            "the preview sticks out of the cell at \(where_)")
                    #expect(s.terminalX + s.terminalWidth <= max(cellW, 0) + 1e-9,
                            "the terminal sticks out of the cell at \(where_)")
                }
            }
        }
        // Narrower than what the preview leaves in sight: the width is held
        // at nothing and the preview starts at the cell's own right edge.
        #expect(rect(at(0, true, nil)) == [0, 0, 0, 0])
        #expect(rect(at(1, true, nil)) == [0, 1, 1, 0])
        #expect(rect(at(39, true, nil)) == [0, 39, 39, 0])
        #expect(rect(at(40, true, nil)) == [0, 40, 40, 0])
        #expect(rect(at(41, true, nil)) == [0, 41, 40, 1])
        // A cell width that is not a size: nothing to show, not a cell shown
        // backwards.
        #expect(at(-5, true, nil) == at(0, true, nil))
        #expect(at(-1000, true, 1000) == at(0, true, nil))
    }

    @Test func aRangeTheWrongWayRoundTakesTheLowerEnd() {
        #expect(Layout.clamped(500, 440, 840) == 500)
        #expect(Layout.clamped(0, 440, 840) == 440)
        #expect(Layout.clamped(1e9, 440, 840) == 840)
        #expect(Layout.clamped(500, 440, 360) == 440, "the range is empty; the lower end is what it means")
        #expect(Layout.clamped(-500, 440, 360) == 440)
        // A value that is not a number: `min(max(NaN, lo), hi)` is NaN in
        // Swift (`max` answers the other operand only in Rust), and a NaN
        // width is a rectangle nothing can be laid out in. A drag is not a
        // NaN; it is "not dragged".
        #expect(Layout.clamped(.nan, 440, 840) == 440, "a NaN takes the lower end")
        #expect(Layout.clamped(.nan, 440, 360) == 440, "even when the range is empty")
    }

    /// A cell width or a dragged width that is not a size at all -- a NaN, an
    /// infinity: the guard leaves four finite, non-negative sizes.
    ///
    /// ⚠️ The pair of cases that are **not** the same on the two hosts unless
    /// each says so out loud: `f64::max(NaN, 0.0)` is `0.0` in Rust, but
    /// `max(NaN, 0)` is `NaN` in Swift; and an infinity passes any
    /// `max(·, 0)` guard, then half of it is still an infinity and `w - pw`
    /// is `inf - inf` = NaN. The fixture's 31 cells hold no such input, so
    /// `tools/control-room-hosts-agree.py` cannot catch either: this test and
    /// its Rust twin are the only places it is held.
    @Test func aCellThatIsNotASizeShowsNothingRatherThanANan() {
        for (what, cellW) in [("a NaN cell", CGFloat.nan), ("an infinite cell", .infinity)] {
            for dragged in [nil, CGFloat(500)] as [CGFloat?] {
                let s = at(cellW, true, dragged)
                let where_ = "\(what), dragged \(String(describing: dragged))"
                for (field, v) in [("terminalX", s.terminalX), ("terminalWidth", s.terminalWidth),
                                   ("previewX", s.previewX), ("previewWidth", s.previewWidth)] {
                    #expect(v.isFinite && v >= 0, "\(field) is \(v) for \(where_)")
                }
            }
        }
        // A dragged width that is not a number, in a cell that is one: the
        // same rule as an empty range -- the preview takes its least and the
        // terminal keeps the rest. It deliberately does **not** mean "never
        // dragged": that is what `nil` is for, and reading it as such would
        // be a second rule in each host.
        #expect(at(1200, true, .nan) == at(1200, true, -1))
        #expect(at(1200, true, .nan).previewWidth == CGFloat(Look.Preview.previewMinWidth))
        #expect(at(800, true, .nan) == at(800, true, nil))
    }

    // MARK: The case list both hosts print

    /// The cases `preview_layout_cases.json` holds, as the two hosts and
    /// `tools/control-room-hosts-agree.py` read them.
    private static func cases() throws -> [(String, CGFloat, Bool, CGFloat?)] {
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("src/poltergeist/testdata/preview_layout_cases.json")
        let data = try Data(contentsOf: path)
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = top?["cases"] as? [[String: Any]]
        return try #require(list).map { c in
            let name = try #require(c["case"] as? String)
            let cellW = try #require((c["cell_w"] as? NSNumber)?.doubleValue)
            let open = try #require(c["open"] as? Bool)
            let dragged = (c["dragged_w"] as? NSNumber)?.doubleValue
            return (name, CGFloat(cellW), open, dragged.map { CGFloat($0) })
        }
    }

    /// What each of those cases makes, worked out from the rule and written
    /// down **by hand** -- not read from the file, so that an answer that
    /// moved is red here and not only where the two hosts are compared.
    private static let want: [String: ([CGFloat], Bool)] = [
        "closed-800": ([0, 800, 0, 0], false),
        "closed-799": ([0, 799, 0, 0], false),
        "open-799-default": ([0, 799, 40, 759], true),
        "open-800-default": ([0, 360, 360, 440], false),
        "open-801-default": ([0, 361, 361, 440], false),
        "open-800-drag-at-min": ([0, 360, 360, 440], false),
        "open-800-drag-below": ([0, 360, 360, 440], false),
        "open-800-drag-default": ([0, 360, 360, 440], false),
        "open-800-drag-at-max": ([0, 360, 360, 440], false),
        "open-800-drag-above": ([0, 360, 360, 440], false),
        "open-800-drag-1000": ([0, 360, 360, 440], false),
        "open-1200-drag-840": ([0, 360, 360, 840], false),
        "open-1200-drag-841": ([0, 360, 360, 840], false),
        "open-1200-drag-360": ([0, 760, 760, 440], false),
        "open-1200-drag-none": ([0, 600, 600, 600], false),
        "open-720-drag-360": ([0, 720, 40, 680], true),
        "open-361-none": ([0, 361, 40, 321], true),
        "open-360-none": ([0, 360, 40, 320], true),
        "open-400-none": ([0, 400, 40, 360], true),
        "open-399-none": ([0, 399, 40, 359], true),
        "open-neg-drag": ([0, 560, 560, 440], false),
        "open-huge-drag": ([0, 360, 360, 640], false),
        "open-zero-cell": ([0, 0, 0, 0], true),
        "open-zero-cell-drag": ([0, 0, 0, 0], true),
        "open-1-none": ([0, 1, 1, 0], true),
        "open-39-none": ([0, 39, 39, 0], true),
        "open-40-none": ([0, 40, 40, 0], true),
        "open-41-none": ([0, 41, 40, 1], true),
        "open-neg-cell": ([0, 0, 0, 0], true),
        "design-03-read": ([0, 424, 40, 384], true),
        "open-neg-cell-1000": ([0, 0, 0, 0], true),
    ]

    @Test func everyCaseTheTwoHostsPrintIsTheRule() throws {
        let cases = try Self.cases()
        #expect(cases.count == Self.want.count, "the fixture and this test's table are not the same case list")
        for (name, cellW, open, dragged) in cases {
            let expected = try #require(Self.want[name],
                                        "\(name) is in the fixture and not in this table: what it makes has not been written down")
            let s = Layout.split(cellW: cellW, open: open, draggedW: dragged)
            #expect(rect(s) == expected.0, "\(name): cellW \(cellW) open \(open) dragged \(String(describing: dragged))")
            #expect(s.overlay == expected.1, "\(name): cellW \(cellW) open \(open)")
        }
    }
}
