import CoreGraphics
import Foundation
import Testing

@testable import Ghostty

/// What one cell's preview remembers, and where the numbers it uses come
/// from (`PreviewSlot`).
///
/// The rule being held is `PreviewLayout.split`'s, and it has its own tests
/// in `PreviewLayoutTests`; what is tested here is the half that is easy to
/// get wrong without noticing -- that a cell's state survives the things it
/// should and does not survive the things it should not.
struct PreviewSlotTests {
    typealias Slot = PreviewSlot
    typealias Look = ControlRoomLook

    // MARK: A cell nobody has touched

    @Test func aCellNobodyHasTouchedIsClosedAndUndragged() {
        let store = Slot.Store()
        let s = store.state("cell")
        #expect(!s.open)
        #expect(s.draggedW == nil)
        #expect(s.rel == "")
        #expect(s.token == "")
        // Which is the same answer the split gives for a closed cell: the
        // terminal has the whole cell and there is no preview.
        #expect(store.split("cell", cellW: 1200).previewWidth == 0)
    }

    /// **The state of a cell nobody has touched is a value and not an
    /// optional.** A default that has to be unwrapped is a default a caller
    /// can forget, and "closed" is the answer for both a cell that was
    /// never opened and one that was opened and closed.
    @Test func anUnknownCellAndAClosedOneGiveTheSameAnswer() {
        var store = Slot.Store()
        store.set("cell", open: true)
        store.set("cell", open: false)
        #expect(store.state("cell") == Slot.Store().state("cell"))
    }

    // MARK: Opening and closing

    @Test func closingKeepsTheDraggedWidthAndTheFile() {
        var store = Slot.Store()
        store.set("cell", open: true)
        store.setDraggedW("cell", 500)
        store.setFile("cell", rel: "docs/a.md", token: String(repeating: "ab", count: 16))
        store.set("cell", open: false)

        let s = store.state("cell")
        #expect(!s.open)
        #expect(s.draggedW == 500)
        #expect(s.rel == "docs/a.md")
        // Which is what makes the design's 「再按一次「文件」按钮」 reopen the
        // same file where it was left rather than at the default.
        store.set("cell", open: true)
        #expect(store.split("cell", cellW: 1200).previewWidth == 500)
    }

    @Test func anOpenCellWithNothingPickedStillDrawsTheDefaultWidth() {
        var store = Slot.Store()
        store.set("cell", open: true)
        let s = store.state("cell")
        // Open with no file: the design's "先是这个终端工作目录的「最近改过」".
        #expect(s.open)
        #expect(s.rel == "")
        #expect(s.token == "")
        #expect(store.split("cell", cellW: 1200).previewWidth == 600)
    }

    // MARK: The width a drag is remembered at

    /// **What is stored is the drag, not what the cell clamped it to.** A
    /// cell dragged while narrow, then widened, has to follow the divider
    /// the person left -- so the stored number is the one they asked for,
    /// and the clamp happens against the width the cell has when it is
    /// drawn.
    @Test func whatIsStoredIsTheDragNotTheClamp() {
        var store = Slot.Store()
        store.set("cell", open: true)
        // In a cell of exactly 800 the band is one width: 440.
        let landed = Slot.dragged(cellW: 800, to: 700)
        #expect(landed == 440)
        store.setDraggedW("cell", 700)
        // Stored as asked...
        #expect(store.state("cell").draggedW == 700)
        // ...and in a cell of 800 the split still holds it at the band.
        #expect(store.split("cell", cellW: 800).previewWidth == 440)
        // ...while a wider cell gives it what it asked for. A store that
        // kept the clamp would answer 440 here too.
        #expect(store.split("cell", cellW: 1400).previewWidth == 700)
    }

    @Test func puttingTheDividerBackToTheDefaultIsNilAndNotHalfTheCell() {
        var store = Slot.Store()
        store.set("cell", open: true)
        store.setDraggedW("cell", 700)
        store.setDraggedW("cell", nil)
        #expect(store.state("cell").draggedW == nil)
        // Back to the default, which follows the cell: the difference
        // between nil and a stored 600 is exactly this test.
        #expect(store.split("cell", cellW: 1200).previewWidth == 600)
        #expect(store.split("cell", cellW: 1600).previewWidth == 800)
    }

    // MARK: The band a divider may be dragged in

    @Test func theBandIsTheDesignsTwoLeastWidthsApart() {
        typealias P = Look.Preview
        // A cell at the threshold: the band is one width, the preview's
        // least, because that is exactly where the terminal's least is met.
        let atThreshold = Slot.dragBand(cellW: CGFloat(P.cellMinWidthSideBySide))
        #expect(atThreshold != nil)
        #expect(atThreshold == CGFloat(P.previewMinWidth)...CGFloat(P.previewMinWidth))

        // Wider: the band runs from the preview's least to what leaves the
        // terminal its least.
        let wide = Slot.dragBand(cellW: 1200)
        #expect(wide == CGFloat(P.previewMinWidth)...(1200 - CGFloat(P.terminalMinWidth)))

        // **No band at all under the threshold**, because there is no
        // divider drawn there: the preview is over the terminal, and a
        // drag in a cell with no divider is not a drag that means anything.
        #expect(Slot.dragBand(cellW: CGFloat(P.cellMinWidthSideBySide) - 1) == nil)
        #expect(Slot.dragged(cellW: 400, to: 200) == nil)
    }

    /// A cell that is not a size at all, and one too narrow to hold a
    /// divider. `PreviewLayout` answers the first by showing nothing; the
    /// band says there is nothing to drag, rather than a range built out of
    /// NaN -- a `ClosedRange` with NaN in it is a range no comparison can
    /// reach.
    @Test func acellThatIsNotASizeAndANarrowOneHaveNoBand() {
        let tooNarrow = CGFloat(Look.Preview.cellMinWidthSideBySide) - 1
        for cellW in [CGFloat.nan, .infinity, -.infinity, -100, 0, tooNarrow] {
            #expect(Slot.dragBand(cellW: cellW) == nil, "at \(cellW)")
            #expect(Slot.dragged(cellW: cellW, to: 100) == nil, "at \(cellW)")
        }
    }

    @Test func aDragInsideTheBandLandsWhereItWasPut() {
        #expect(Slot.dragged(cellW: 1400, to: 700) == 700)
        // Past either end: the end.
        #expect(Slot.dragged(cellW: 1400, to: 10) == 440)
        #expect(Slot.dragged(cellW: 1400, to: 5000) == 1040)
    }

    // MARK: Two cells

    @Test func twoCellsKeepTheirOwnState() {
        var store = Slot.Store()
        store.set("a", open: true)
        store.set("b", open: true)
        store.setDraggedW("a", 500)
        store.setDraggedW("b", 900)
        #expect(store.split("a", cellW: 1600).previewWidth == 500)
        #expect(store.split("b", cellW: 1600).previewWidth == 900)
        store.set("a", open: false)
        #expect(!store.state("a").open)
        #expect(store.state("b").open)
    }

    /// A cell that is gone takes its state with it, so a cell that comes
    /// back is one that has never been dragged. Nothing calls this for a
    /// cell that is merely **not drawn** -- a tab behind another keeps its
    /// previews (the design: 切回 frontend，它的预览还在).
    @Test func forgettingACellForgetsEverythingAboutIt() {
        var store = Slot.Store()
        store.set("cell", open: true)
        store.setDraggedW("cell", 700)
        let token = String(repeating: "cd", count: 16)
        store.setFile("cell", rel: "a.md", token: token)

        // ⚠️ **The token is the return value, and it is the only reason
        // `forget` returns anything at all.** A caller that drops it never
        // asks the core for `files_close`, so the ticket stays in the core's
        // ledger until the cap pushes somebody else's out -- and that
        // symptom appears nowhere near this file. Nothing asserted the
        // return value at first, which meant changing `-> String` back to
        // `-> Void`, or dropping the `?? ""`, kept every test green while
        // closing nothing. Caught by the test seat; pinned here.
        #expect(store.forget("cell") == token)

        // Everything is gone...
        #expect(store.state("cell") == Slot.Store().state("cell"))
        #expect(store.split("cell", cellW: 1200).previewWidth == 0)

        // ...and a cell that was never there has nothing to give back. `""`
        // is what a caller hands `PreviewTicket.close`, which asks the core
        // about nothing rather than about somebody else's ticket.
        #expect(store.forget("cell") == "")
    }
}
