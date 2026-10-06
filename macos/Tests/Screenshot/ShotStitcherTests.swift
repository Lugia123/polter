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
}
