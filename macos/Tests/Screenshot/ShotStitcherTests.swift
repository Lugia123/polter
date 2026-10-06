import Foundation
import Testing
@testable import Ghostty

/// The Windows host's `stitch.rs` tests, with the same fixtures and the
/// same numbers (`dev-docs/poltergeist/screenshot.md`, 9.6 and 9.7).
struct ShotStitcherTests {
    private static let w = 16
    private static let h = 120
    private static let header = 10
    private static let footer = 6
    private static let view = h - header - footer

    private static func noise(rows: Int, seed: UInt64) -> [UInt8] {
        ShotFixtures.noise(pixels: rows * w, seed: seed)
    }

    private static func rows(_ bytes: [UInt8], _ from: Int, _ to: Int) -> [UInt8] {
        Array(bytes[(from * w * 4)..<(to * w * 4)])
    }

    /// A page with a fixed header and footer and a long scrolling body.
    private struct Page {
        let header = noise(rows: ShotStitcherTests.header, seed: 1)
        let body = noise(rows: 2000, seed: 2)
        let footer = noise(rows: ShotStitcherTests.footer, seed: 3)

        func frame(_ y: Int) -> [UInt8] {
            header + rows(body, y, y + view) + footer
        }

        func expected(_ y: Int) -> [UInt8] {
            header + rows(body, 0, y + view) + footer
        }
    }

    private func stitcher() -> ShotStitcher { ShotStitcher(width: Self.w, height: Self.h)! }

    @Test func scrollingDownAddsExactlyTheRowsThatCameIntoView() {
        let page = Page()
        var s = stitcher()
        let first = s.push(page.frame(0))
        #expect(first == .first)
        #expect(s.totalHeight == Self.h)
        let a = s.push(page.frame(30)), b = s.push(page.frame(75)), c = s.push(page.frame(76))
        #expect(a == .added(30))
        #expect(b == .added(45))
        #expect(c == .added(1))
        #expect(s.totalHeight == Self.h + 76)
        let picture = s.finish()
        #expect(picture?.width == Self.w)
        #expect(picture?.rgbx == page.expected(76))
    }

    @Test func theFixedHeaderAndFooterAreKeptOnce() {
        let page = Page()
        var s = stitcher()
        for y in [0, 40, 80, 120, 160] { _ = s.push(page.frame(y)) }
        let picture = s.finish()!.rgbx
        let count = picture.count / (Self.w * 4)
        #expect(count == Self.header + 160 + Self.view + Self.footer)
        func row(_ i: Int) -> [UInt8] { Self.rows(picture, i, i + 1) }
        #expect(row(0) == Self.rows(page.header, 0, 1))
        #expect(row(count - 1) == Self.rows(page.footer, Self.footer - 1, Self.footer))
        let copies = (0..<count).filter { row($0) == row(0) }.count
        #expect(copies == 1)
        #expect(picture == page.expected(160))
    }

    @Test func aFrameThatDidNotMoveAddsNothing() {
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(0))
        let still = s.push(page.frame(0))
        #expect(still == .unchanged)
        _ = s.push(page.frame(20))
        let stillAgain = s.push(page.frame(20))
        #expect(stillAgain == .unchanged)
        #expect(s.finish()?.rgbx == page.expected(20))
    }

    @Test func scrollingBackAndDownAgainNeitherRepeatsNorTears() {
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(0))
        let down = s.push(page.frame(50))
        let back1 = s.push(page.frame(20))
        let back2 = s.push(page.frame(5))
        #expect(down == .added(50))
        #expect(back1 == .back)
        #expect(back2 == .back)
        // Going back loses nothing.
        #expect(s.totalHeight == Self.h + 50)
        let seen = s.push(page.frame(40))
        let more = s.push(page.frame(70))
        #expect(seen == .seen)
        #expect(more == .added(20))
        #expect(s.finish()?.rgbx == page.expected(70))
    }

    @Test func aFrameScrolledTooFarToOverlapIsDroppedNotJoined() {
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(0))
        _ = s.push(page.frame(30))
        let tooFar = s.push(page.frame(30 + Self.view))
        #expect(tooFar == .lost)
        #expect(s.totalHeight == Self.h + 30)
        // Ten rows of overlap is under the least that is believed.
        let barely = s.push(page.frame(30 + Self.view - 10))
        #expect(barely == .lost)
        // Twenty is more than an eighth of the band (13) and still under
        // the twenty-four rows that are the least believed.
        let twenty = s.push(page.frame(30 + Self.view - 20))
        #expect(twenty == .lost)
        let recovered = s.push(page.frame(60))
        #expect(recovered == .added(30))
        #expect(s.finish()?.rgbx == page.expected(60))
    }

    @Test func aPageThatRepeatsIsTakenToHaveMovedTheLeastAndDownwards() {
        // Twenty rows, over and over: scrolled down by ten it lines up at a
        // shift of 10, 30, 50 and 70 -- and, the period being twice the
        // scroll, scrolling *up* by ten looks exactly the same.
        let period = Self.noise(rows: 20, seed: 31)
        var body: [UInt8] = []
        for _ in 0..<20 { body.append(contentsOf: period) }
        func frame(_ y: Int) -> [UInt8] { Self.rows(body, y, y + Self.h) }
        var s = stitcher()
        _ = s.push(frame(0))
        let step = s.push(frame(10))
        // The smallest shift, and down before up: the least that could be
        // wrong is added.
        #expect(step == .added(10))
        #expect(s.totalHeight == Self.h + 10)
    }

    @Test func theFooterIsTheLastFramesNotTheFirsts() {
        // A status bar that is still while the first two frames are taken
        // and has changed by the third: a clock, a scroll position.
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(0))
        _ = s.push(page.frame(30))
        let later = Self.noise(rows: Self.footer, seed: 41)
        let third = page.header + Self.rows(page.body, 60, 60 + Self.view) + later
        let step = s.push(third)
        #expect(step == .added(30))
        #expect(s.finish()?.rgbx == page.header + Self.rows(page.body, 0, 60 + Self.view) + later)
    }

    @Test func contentThatChangedRatherThanScrolledIsDropped() {
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(0))
        _ = s.push(page.frame(30))
        let other = page.header + Self.noise(rows: Self.view, seed: 77) + page.footer
        let changed = s.push(other)
        #expect(changed == .lost)
        #expect(s.finish()?.rgbx == page.expected(30))
    }

    /// Forty rows of text, a hundred and forty blank ones, more text.
    private static func bodyWithABlankStretch() -> [UInt8] {
        var body = noise(rows: 40, seed: 5)
        for _ in 0..<(140 * w) { body.append(contentsOf: [200, 200, 200, 0]) }
        body.append(contentsOf: noise(rows: 200, seed: 6))
        return body
    }

    @Test func aBlankStretchIsNotTrustedToSayHowFarItMoved() {
        let body = Self.bodyWithABlankStretch()
        func frame(_ y: Int) -> [UInt8] { Self.rows(body, y, y + Self.h) }
        var s = stitcher()
        _ = s.push(frame(0))
        let blank = s.push(frame(80))
        #expect(blank == .lost)
        #expect(s.totalHeight == Self.h)
        let small = s.push(frame(20))
        #expect(small == .added(20))
        #expect(s.finish()?.rgbx == Self.rows(body, 0, 20 + Self.h))
    }

    @Test func whiteSpaceUnderTheTextIsNotMistakenForAFixedFooter() {
        let body = Self.bodyWithABlankStretch()
        func frame(_ y: Int) -> [UInt8] { Self.rows(body, y, y + Self.h) }
        var s = stitcher()
        _ = s.push(frame(0))
        let a = s.push(frame(20)), b = s.push(frame(30))
        #expect(a == .added(20))
        #expect(b == .added(10))
        for y in [50, 70, 85, 100, 130] {
            let step = s.push(frame(y))
            let fine: Bool
            switch step {
            case .added, .lost: fine = true
            default: fine = false
            }
            #expect(fine, "y = \(y) gave \(step)")
        }
        // Whatever was joined is the page, unbroken.
        let picture = s.finish()!.rgbx
        #expect(picture == Array(body[..<picture.count]))
    }

    @Test func aRealFooterUnderWhiteSpaceKeepsOnlyItsFirmPart() {
        var body = Self.noise(rows: 40, seed: 5)
        for _ in 0..<(140 * Self.w) { body.append(contentsOf: [200, 200, 200, 0]) }
        let footer = Self.noise(rows: 6, seed: 8)
        func frame(_ y: Int) -> [UInt8] { Self.rows(body, y, y + Self.h - 6) + footer }
        var s = stitcher()
        _ = s.push(frame(0))
        let step = s.push(frame(30))
        #expect(step == .added(30))
        // The page down to where it was scrolled, and the footer once.
        #expect(s.finish()?.rgbx == Self.rows(body, 0, 30 + Self.h - 6) + footer)
    }

    @Test func aHeaderWithAFlatEdgeIsStillAHeader() {
        var header = Self.noise(rows: 6, seed: 21)
        for _ in 0..<(10 * Self.w) { header.append(contentsOf: [40, 40, 40, 0]) }
        let body = Self.noise(rows: 600, seed: 22)
        func frame(_ y: Int) -> [UInt8] { header + Self.rows(body, y, y + Self.h - 16) }
        var s = stitcher()
        _ = s.push(frame(0))
        let a = s.push(frame(2)), b = s.push(frame(40)), c = s.push(frame(90))
        #expect(a == .added(2))
        // The padding was not taken for scrolling page.
        #expect(b == .added(38))
        #expect(c == .added(50))
        #expect(s.finish()?.rgbx == header + Self.rows(body, 0, 90 + Self.h - 16))
    }

    @Test func aCaretBlinkingInTheOverlapDoesNotLoseTheFrame() {
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(0))
        var blink = page.frame(30)
        for i in ((Self.header + 5) * Self.w * 4)..<((Self.header + 6) * Self.w * 4) { blink[i] ^= 0xFF }
        let step = s.push(blink)
        #expect(step == .added(30))
    }

    @Test func withNoFixedBandsTheWholeFrameScrolls() {
        let body = Self.noise(rows: 600, seed: 9)
        func frame(_ y: Int) -> [UInt8] { Self.rows(body, y, y + Self.h) }
        var s = stitcher()
        _ = s.push(frame(0))
        let a = s.push(frame(50)), b = s.push(frame(110))
        #expect(a == .added(50))
        #expect(b == .added(60))
        #expect(s.finish()?.rgbx == Self.rows(body, 0, 110 + Self.h))
    }

    @Test func itStopsAtTheHeightLimitAndKeepsWhatFitted() {
        let tall = 256
        let body = Self.noise(rows: ShotStitcher.maxHeight + 2000, seed: 11)
        func frame(_ y: Int) -> [UInt8] { Self.rows(body, y, y + tall) }
        var s = ShotStitcher(width: Self.w, height: tall)!
        _ = s.push(frame(0))
        var y = 0
        var last = ShotStitcher.Step.first
        while y + 200 + tall <= ShotStitcher.maxHeight + 1500, last != .full {
            y += 200
            last = s.push(frame(y))
        }
        #expect(last == .full)
        #expect(s.isFull)
        #expect(s.totalHeight == ShotStitcher.maxHeight)
        // The first 20000 rows, unbroken.
        #expect(s.finish()?.rgbx == Self.rows(body, 0, ShotStitcher.maxHeight))
        let after = s.push(frame(y + 100))
        #expect(after == .full)
        #expect(s.totalHeight == ShotStitcher.maxHeight)
    }

    @Test func theThumbnailIsThePictureInProportionWithinItsBox() {
        let page = Page()
        var s = stitcher()
        #expect(s.thumbnail(maxWidth: 8, maxHeight: 100) == nil)
        _ = s.push(page.frame(0))
        let one = s.thumbnail(maxWidth: 8, maxHeight: 100)!
        #expect(one.width == 8)
        #expect(one.height == 60)
        #expect(one.rgbx.count == 8 * 60 * 4)
        for y in [40, 80, 120] { _ = s.push(page.frame(y)) }
        let tall = s.thumbnail(maxWidth: 8, maxHeight: 60)!
        #expect(tall.width == 4)
        #expect(tall.height == 60)
        let whole = s.finish()!.rgbx
        #expect(Array(tall.rgbx[..<4]) == Array(whole[..<4]))
        let lastSource = 59 * 240 / 60
        let at = 59 * 4 * 4
        #expect(Array(tall.rgbx[at..<(at + 4)]) == Array(whole[(lastSource * Self.w * 4)..<(lastSource * Self.w * 4 + 4)]))
        #expect(Array(tall.rgbx[(at + 4)..<(at + 8)])
            == Array(whole[(lastSource * Self.w * 4 + 16)..<(lastSource * Self.w * 4 + 20)]))
        let roomy = s.thumbnail(maxWidth: 500, maxHeight: 5000)!
        #expect(roomy.width == 16)
        #expect(roomy.height == 240)
    }

    @Test func oneFrameAloneIsThePicture() {
        let page = Page()
        var s = stitcher()
        #expect(s.finish() == nil)
        #expect(s.totalHeight == 0)
        _ = s.push(page.frame(0))
        #expect(s.finish()?.rgbx == page.frame(0))
    }

    @Test func aFrameOfAnotherSizeIsIgnored() {
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(0))
        let short = s.push(Array(page.frame(0)[..<(Self.w * 4 * (Self.h - 1))]))
        let empty = s.push([])
        #expect(short == .wrongSize)
        #expect(empty == .wrongSize)
        #expect(ShotStitcher(width: 0, height: 10) == nil)
        #expect(ShotStitcher(width: 10, height: 0) == nil)
    }

    @Test func scrollingBackBeforeAnythingWasAddedIsNotAPlaceToGo() {
        let page = Page()
        var s = stitcher()
        _ = s.push(page.frame(50))
        // There is nothing above the first frame.
        let back = s.push(page.frame(20))
        #expect(back == .lost)
        let down = s.push(page.frame(80))
        #expect(down == .added(30))
        let picture = s.finish()!.rgbx
        #expect(Self.rows(picture, Self.header, Self.header + 5) == Self.rows(page.body, 50, 55))
    }

    @Test func aBandKeepsItsFirmPartAndGivesUpItsFlatInnerEdge() {
        let rows: [UInt64] = [7, 7, 7, 1, 2]
        // The two distinct rows and one of the alike ones.
        #expect(ShotStitcher.firm(rows: 5) { rows[$0] } == 3)
        // Alike all through: not a band.
        #expect(ShotStitcher.firm(rows: 5) { _ in 7 } == 0)
        #expect(ShotStitcher.firm(rows: 1) { _ in 7 } == 0)
        #expect(ShotStitcher.firm(rows: 0) { _ in 7 } == 0)
        let distinct: [UInt64] = [1, 2, 3]
        #expect(ShotStitcher.firm(rows: 3) { distinct[$0] } == 3)
    }

    @Test func theRowHashIgnoresTheFourthByte() {
        let a: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0]
        let b: [UInt8] = [1, 2, 3, 255, 4, 5, 6, 9]
        let c: [UInt8] = [1, 2, 3, 0, 4, 5, 7, 0]
        #expect(ShotStitcher.rowHashes(a, width: 2) == ShotStitcher.rowHashes(b, width: 2))
        #expect(ShotStitcher.rowHashes(a, width: 2) != ShotStitcher.rowHashes(c, width: 2))
        #expect(ShotStitcher.rowHashes(a, width: 1).count == 2)
    }
    // MARK: Only steady frames (9.7)

    /// `page` scrolled to `y`, caught before the strip that just came into
    /// view was painted to the bottom: its last `unpainted` rows are still
    /// the window's blank ground.
    private func halfPainted(_ page: Page, _ y: Int, unpainted: Int) -> [UInt8] {
        var f = page.frame(y)
        let end = (Self.header + Self.view) * Self.w * 4
        for i in (end - unpainted * Self.w * 4)..<end { f[i] = 0xff }
        return f
    }

    /// What a capture timer sees of an application that scrolls `by` rows
    /// at a time and paints the exposed strip late: after each scroll one
    /// frame with `unpainted` rows still blank, then the finished frame
    /// three times over.
    private func latePainter(_ page: Page, by: Int, scrolls: Int, unpainted: Int) -> [[UInt8]] {
        var frames = [[UInt8]](repeating: page.frame(0), count: 3)
        for n in 1...scrolls {
            frames.append(halfPainted(page, n * by, unpainted: unpainted))
            frames += [[UInt8]](repeating: page.frame(n * by), count: 3)
        }
        return frames
    }

    private func blankRows(_ picture: [UInt8]) -> Int {
        let row = Self.w * 4
        return stride(from: 0, to: picture.count, by: row).filter { start in
            stride(from: start, to: start + row, by: 4).allSatisfy {
                picture[$0] == 0xff && picture[$0 + 1] == 0xff && picture[$0 + 2] == 0xff
            }
        }.count
    }

    /// The other host's defect 3, first form: the picture came out the
    /// right height with every line in it, and with bands of blank rows
    /// across half a line of text. Two blank rows are inside what lining up
    /// forgives, so the frames after a half-painted one are joined to it
    /// and its blank rows stay.
    @Test func aFrameCaughtHalfPaintedLeavesNoBlankRowsInThePicture() throws {
        let page = Page()
        let frames = latePainter(page, by: 20, scrolls: 6, unpainted: 2)
        // What `push` alone does with them -- the defect, kept as the
        // statement of what `offer` is for.
        var raw = stitcher()
        for f in frames { _ = raw.push(f) }
        #expect(raw.totalHeight == Self.h + 120, "the height was right on the test machine too")
        let torn = try #require(raw.finish()).rgbx
        #expect(blankRows(torn) > 0, "this sequence no longer shows the defect")
        #expect(torn != page.expected(120), "this sequence no longer shows the defect")

        var s = stitcher()
        let steps = frames.map { s.offer($0) }
        #expect(!steps.contains(.lost), "\(steps)")
        #expect(steps.filter { $0 == .added(20) }.count == 6, "\(steps)")
        let picture = try #require(s.finish()).rgbx
        #expect(blankRows(picture) == 0)
        #expect(picture == page.expected(120))
    }

    /// Defect 3, second form: a few notches were joined and nothing after
    /// them, most frames dropped, and the picture ended in blank rows. With
    /// more rows unpainted than lining up forgives, no later frame lines up
    /// with the half-painted one, and it stays the frame everything is
    /// compared against.
    @Test func aFrameCaughtHalfPaintedDoesNotStopThePictureGrowing() throws {
        let page = Page()
        let frames = latePainter(page, by: 20, scrolls: 6, unpainted: 12)
        var raw = stitcher()
        let lost = frames.filter { raw.push($0) == .lost }.count
        #expect(lost > frames.count / 2, "only \(lost) of \(frames.count) dropped: this sequence no longer shows the defect")
        #expect(raw.totalHeight == Self.h + 20, "it stuck after the first notch")
        #expect(blankRows(try #require(raw.finish()).rgbx) == 12, "and ended in the blank rows")

        var s = stitcher()
        let steps = frames.map { s.offer($0) }
        #expect(!steps.contains(.lost), "\(steps)")
        #expect(s.totalHeight == Self.h + 120)
        #expect(try #require(s.finish()).rgbx == page.expected(120))
    }

    /// The rule itself: a frame counts when it is the one offered just
    /// before it, and only then.
    @Test func onlyAFrameSeenTwiceRunningIsJoined() throws {
        let page = Page()
        var s = stitcher()
        let one = s.offer(page.frame(0))
        #expect(one == .moving)
        #expect(s.totalHeight == 0, "one capture alone is not a picture yet")
        let two = s.offer(page.frame(0))
        #expect(two == .first)
        // Scrolling: every frame differs from the one before, none joined.
        let scrolling = [5, 12, 20].map { s.offer(page.frame($0)) }
        #expect(scrolling == [.moving, .moving, .moving])
        #expect(s.totalHeight == Self.h)
        // It stops: the second look at the same frame joins it.
        let stopped = [s.offer(page.frame(30)), s.offer(page.frame(30))]
        #expect(stopped == [.moving, .added(30)])
        // Still there: nothing new, and not "moving".
        let still = s.offer(page.frame(30))
        #expect(still == .unchanged)
        // A frame seen twice, but not twice running, is not steady.
        let apart = [s.offer(page.frame(40)), s.offer(page.frame(50)), s.offer(page.frame(40))]
        #expect(apart == [.moving, .moving, .moving])
        #expect(s.totalHeight == Self.h + 30)
        let again = s.offer(page.frame(40))
        #expect(again == .added(10))
        // A frame of another size is still said to be that.
        let short = s.offer(Array(page.frame(0).dropFirst(4)))
        #expect(short == .wrongSize)
        // ...and it was not remembered: the next real frame is compared
        // with the last real one.
        let after = s.offer(page.frame(40))
        #expect(after == .unchanged)
        #expect(try #require(s.finish()).rgbx == page.expected(40))
    }

    /// `frame` with the columns `columns` replaced by something that is the
    /// same in every frame and different in every row: the window's border
    /// and what lies outside it, caught inside the selection.
    private func withStill(_ frame: [UInt8], _ columns: [Int]) -> [UInt8] {
        var frame = frame
        let edge = Self.noise(rows: frame.count / (Self.w * 4), seed: 99)
        for y in 0..<(frame.count / (Self.w * 4)) {
            for x in columns {
                let at = (y * Self.w + x) * 4
                frame.replaceSubrange(at..<(at + 4), with: edge[at..<(at + 4)])
            }
        }
        return frame
    }

    /// `picture` without the columns `columns`.
    private func without(_ picture: [UInt8], _ columns: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<(picture.count / 4) where !columns.contains(i % Self.w) {
            out.append(contentsOf: picture[(i * 4)..<(i * 4 + 4)])
        }
        return out
    }

    /// #1096 (the other host's test machine, Notepad and Edge, the
    /// selection's left edge on the window's border): 204 frames, 69
    /// dropped, 600 px tall. Two frames a notch apart were the same in 799
    /// columns of 800 once lined up, and differed in every row of the one
    /// that does not scroll.
    @Test func aColumnThatDoesNotScrollDoesNotLoseEveryFrame() throws {
        let body = Self.noise(rows: 600, seed: 9)
        func frame(_ y: Int) -> [UInt8] { withStill(Self.rows(body, y, y + Self.h), [0]) }
        var s = stitcher()
        let steps = [0, 30, 75, 76, 40, 110].map { s.push(frame($0)) }
        #expect(steps == [.first, .added(30), .added(45), .added(1), .back, .added(34)])
        #expect(s.totalHeight == Self.h + 110, "one frame and everything it moved by")
        let picture = try #require(s.finish()).rgbx
        #expect(without(picture, [0]) == without(Self.rows(body, 0, 110 + Self.h), [0]), "the page, unbroken")
        // The still column is in the picture as the frames showed it: the
        // first frame's, then under it the rows each later frame added.
        #expect(Self.rows(picture, 0, Self.h) == frame(0))

        // And off a live screen, where each frame is seen twice.
        var live = stitcher()
        let offered = [0, 0, 30, 30, 75, 75].map { live.offer(frame($0)) }.filter { $0 != .moving }
        #expect(offered == [.first, .added(30), .added(45)])
        #expect(live.totalHeight == Self.h + 75)
    }

    @Test func stillColumnsBesideAFixedHeaderAndFooter() throws {
        // A bar across the top and one across the bottom, and at both sides
        // a strip that does not scroll, through the bars as well.
        let page = Page()
        let sides = [0, Self.w - 2, Self.w - 1]
        var s = stitcher()
        let steps = [0, 40, 95].map { s.push(withStill(page.frame($0), sides)) }
        #expect(steps == [.first, .added(40), .added(55)])
        #expect(s.totalHeight == Self.h + 95)
        let picture = try #require(s.finish()).rgbx
        #expect(without(picture, sides) == without(page.expected(95), sides), "the bars once, the page unbroken")
    }

    @Test func aStillColumnDoesNotMakeFramesWithNothingInCommonJoin() {
        let body = Self.noise(rows: 900, seed: 9)
        func frame(_ y: Int) -> [UInt8] { withStill(Self.rows(body, y, y + Self.h), [0]) }
        var s = stitcher()
        _ = s.push(frame(0))
        // Before anything was joined, and after.
        let before = s.push(frame(Self.h))
        #expect(before == .lost)
        let joined = s.push(frame(30))
        #expect(joined == .added(30))
        let after = [s.push(frame(30 + Self.h)), s.push(frame(30 + Self.h - 20))]
        #expect(after == [.lost, .lost], "twenty rows in common are too few, as they always were")
        // Another page altogether behind the same border.
        let other = s.push(withStill(Self.noise(rows: Self.h, seed: 77), [0]))
        #expect(other == .lost)
        #expect(s.totalHeight == Self.h + 30, "nothing was added")
        let on = s.push(frame(60))
        #expect(on == .added(30), "and it goes on from the last good frame")
    }

    @Test func aStillColumnDoesNotMakeAFrameThatDidNotMoveJoinTwice() {
        let body = Self.noise(rows: 600, seed: 9)
        func frame(_ y: Int) -> [UInt8] { withStill(Self.rows(body, y, y + Self.h), [0]) }
        var s = stitcher()
        _ = s.push(frame(0))
        let same = s.push(frame(0))
        #expect(same == .unchanged)
        #expect(s.totalHeight == Self.h)
        _ = s.push(frame(20))
        let again = (0..<3).map { _ in s.push(frame(20)) }
        #expect(again == [.unchanged, .unchanged, .unchanged])
        let offered = [s.offer(frame(20)), s.offer(frame(20))]
        #expect(offered == [.moving, .unchanged], "the first look `offer` has had at it, then the second")
        #expect(s.totalHeight == Self.h + 20)
    }

    /// Why a column is left out only when *no* row of it changed. Lines of
    /// text that are all alike, numbered down the side: scrolled by three
    /// lines every column of the text is unchanged, and the numbers -- which
    /// are unchanged in nine rows of ten -- are all that says it was three
    /// lines and not one. Leaving out columns that are *mostly* unchanged
    /// would leave them out too.
    @Test func aColumnThatChangedInAFewRowsIsStillEvidence() {
        let line = Self.noise(rows: 10, seed: 51)
        let numbers = Self.noise(rows: 60, seed: 52)
        var body: [UInt8] = []
        for _ in 0..<60 { body += line }
        for n in 0..<60 {
            // One pixel of each line, in column 0, is that line's own.
            let at = (n * 10 + 4) * Self.w * 4
            body.replaceSubrange(at..<(at + 4), with: numbers[(n * Self.w * 4)..<(n * Self.w * 4 + 4)])
        }
        var s = stitcher()
        _ = s.push(Self.rows(body, 0, Self.h))
        let step = s.push(Self.rows(body, 30, 30 + Self.h))
        #expect(step == .added(30))
        #expect(s.finish()?.rgbx == Self.rows(body, 0, 30 + Self.h))
    }

    @Test func theColumnsLeftOutAreTheOnesNoRowChangedIn() {
        // Four pixels wide, three rows: column 1 the same throughout,
        // column 2 different in one row, column 3 different only in its
        // fourth byte, which is not part of the picture.
        let before = (0..<(3 * 4 * 4)).map { UInt8($0) }
        var now = before
        for y in 0..<3 {
            now[(y * 4) * 4] ^= 1
            now[(y * 4 + 3) * 4 + 3] ^= 1
        }
        now[(4 + 2) * 4 + 1] ^= 1
        #expect(ShotStitcher.stillColumns(before, now, width: 4, rows: 0..<3) == [false, true, false, true])
        // Only the rows asked about.
        #expect(ShotStitcher.stillColumns(before, now, width: 4, rows: 2..<3) == [false, true, true, true])
        // With nothing left out the hashes are the whole rows'.
        let whole = ShotStitcher.rowHashes(now, width: 4)
        let none = [Bool](repeating: false, count: 4)
        #expect(ShotStitcher.movingHashes(now, width: 4, rows: 1..<3, still: none) == Array(whole[1..<3]))
        #expect(ShotStitcher.movingHashes(now, width: 4, rows: 0..<3, still: [false, true, false, true]) != whole)
    }
}
