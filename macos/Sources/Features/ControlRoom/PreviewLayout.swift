import CoreGraphics
import Foundation

/// Where the terminal and the file preview go in one cell, when the preview
/// is open (task 2623, #2140 S2; the design's `INTERACTION.md` §一 宽窄,
/// `src/files.css`'s `.split > .cv` and `.split.over > .fp`).
///
/// **One rule, both hosts** (`dev-docs/poltergeist/control-room.md`, 3.5).
/// The Windows host has the same function in
/// `windows/control-room/src/preview_layout.rs`; the numbers are the data's
/// (`ControlRoomLook.Preview`), and `tools/control-room-hosts-agree.py`
/// holds the two to each other over
/// `src/poltergeist/testdata/preview_layout_cases.json`, line by line.
///
/// **The rule, in the order it gives way:**
///
///  1. Nothing is open: the terminal has the whole cell and there is no
///     preview.
///  2. A cell at least `cellMinWidthSideBySide` wide puts them side by side.
///     The preview wants what the divider was dragged to, or -- never
///     dragged -- half the cell (`previewDefaultFraction`). It is then held
///     between `previewMinWidth` and what leaves the terminal
///     `terminalMinWidth`. The terminal takes the rest, on the left.
///  3. A narrower cell has the preview **over** the terminal: the terminal
///     keeps the whole cell, and the preview starts `overlayLeftExpose` in,
///     leaving that much of the terminal in sight, dimmed, with `‹ 终端`
///     over it.
///
/// ⚠️ **No size is ever negative** (the supervisor's ruling of 2026-11-01,
/// task 2623). A cell narrower than `overlayLeftExpose` -- or a `cellW` that
/// is not a size at all -- is not a case the design drew, and a negative
/// width reaches `CGRect`/`iced` as a rectangle that is inside out. So
/// `cellW` is brought to zero or more on the way in, and the overlay's width
/// is held at zero or more on the way out.
///
/// **The widths are the whole of it.** The heights are the cell's, and
/// neither host is told one here: this says only where the two split a cell
/// across, which is the part the design states and the part that has to
/// agree.
enum PreviewLayout {
    typealias Look = ControlRoomLook

    /// Where the terminal and the preview go in one cell. `x` is measured
    /// from the cell's left edge, and `previewX` is where the preview
    /// starts: the terminal's width when they are side by side,
    /// `overlayLeftExpose` when it is over the terminal, and nowhere at all
    /// when it is not open.
    struct Split: Equatable {
        var terminalX: CGFloat
        var terminalWidth: CGFloat
        var previewX: CGFloat
        var previewWidth: CGFloat
        /// The preview is over the terminal rather than beside it.
        var overlay: Bool
    }

    /// `v` brought within `lo...hi`. **Never a trap**: the two on the wrong
    /// side of each other is a cell narrow enough to have made them so, and
    /// `lo` is what such a range means here -- the preview's least width is
    /// the one the design names. A `v` that is not a number at all means the
    /// same thing: `min(max(NaN, lo), hi)` is NaN in Swift, and a NaN width
    /// reaches `CGRect` as a rectangle nothing can be laid out in.
    static func clamped(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        if v.isNaN { return lo }
        if hi < lo { return lo }
        return min(max(v, lo), hi)
    }

    /// Where the terminal and the preview go in a cell `cellW` wide, with
    /// the preview open or not, and the width the divider was dragged to
    /// (`nil` for never dragged).
    static func split(cellW: CGFloat, open: Bool, draggedW: CGFloat?) -> Split {
        // A cell is a size. Anything else -- a negative, a NaN, an infinity
        // -- is a caller that has lost its place, and the rule below is only
        // written for sizes, so it is shown nothing rather than a cell turned
        // inside out. (`max(cellW, 0)` alone would not do it: `max(NaN, 0)`
        // is NaN, half of an infinity is still one, and `w - pw` would be
        // `inf - inf`.)
        let w = cellW.isFinite ? max(cellW, 0) : 0
        guard open else {
            return Split(terminalX: 0, terminalWidth: w, previewX: 0, previewWidth: 0, overlay: false)
        }
        if w >= CGFloat(Look.Preview.cellMinWidthSideBySide) {
            let want = draggedW ?? w * CGFloat(Look.Preview.previewDefaultFraction)
            let pw = clamped(want, CGFloat(Look.Preview.previewMinWidth),
                             w - CGFloat(Look.Preview.terminalMinWidth))
            return Split(terminalX: 0, terminalWidth: w - pw, previewX: w - pw, previewWidth: pw, overlay: false)
        }
        return Split(terminalX: 0, terminalWidth: w,
                     previewX: min(w, CGFloat(Look.Preview.overlayLeftExpose)),
                     previewWidth: max(0, w - CGFloat(Look.Preview.overlayLeftExpose)),
                     overlay: true)
    }
}
