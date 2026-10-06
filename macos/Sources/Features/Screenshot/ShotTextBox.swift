import Foundation

/// Where the box somebody types a text into goes, and how big it is
/// (`dev-docs/poltergeist/screenshot.md`, 9.3). The Windows host's
/// `textbox.rs`, rule for rule and number for number.
///
/// The box is an opaque sheet over the picture and a view of its own:
/// whatever it covers cannot be seen or clicked. It was once four lines tall
/// whatever was in it and stopped only at the bottom of the display, so at
/// the largest size, opened low in the selection, it lay over the toolbar
/// and the colour row -- which are how the text being typed is given
/// another colour (task 1104).
///
///  * **As tall as what is in it**: one line to begin with, a line more for
///    each line it comes to hold. `line` is the height of one line in the
///    font the host draws with, which the host measures.
///  * **Inside the selection**: a new text starts no lower than one line
///    above the selection's bottom edge (`origin`), and its box stops
///    growing there (`rect`). What is typed past that scrolls in the box.
///  * **Clear of the toolbar**: the box ends above any toolbar rectangle it
///    would otherwise reach. Where one line cannot avoid it -- a text
///    opened for editing again that already sits there -- the host gives a
///    press on the toolbar to the toolbar (`onToolbar`).
enum ShotTextBox {
    /// The narrowest a box is, in ems of the font.
    static let minEms = 4
    /// And never narrower than this many points, for the smallest sizes.
    static let minWidth = 40

    /// The narrowest box for a font `fontPx` pixels tall.
    static func minWidth(fontPx: Int, scale: Double) -> Int {
        max(fontPx * minEms, ShotStyle.px(minWidth, scale: scale))
    }

    /// How many lines `text` is: one, and one more for each line break.
    static func lines(in text: String) -> Int {
        1 + text.filter { $0 == "\n" }.count
    }

    private static func overlapsAcross(_ r: PixelRect, x: Int, w: Int) -> Bool {
        r.x < x + w && r.right > x
    }

    /// Where a new text starts for a press at `click` inside `selection`:
    /// the press itself, pulled up and to the left just far enough that one
    /// line `line` tall and `minW` wide is inside the selection and above
    /// any of `keepClear` that lies inside it.
    ///
    /// A selection smaller than one line, or narrower than `minW`, cannot
    /// hold the box: the text then starts at the selection's own edge.
    static func origin(
        click: PixelPoint, line: Int, minW: Int, selection: PixelRect, keepClear: [PixelRect]
    ) -> PixelPoint {
        var bottom = selection.bottom
        for r in keepClear
        where r.y > selection.y && r.y < selection.bottom && overlapsAcross(r, x: selection.x, w: selection.w) {
            bottom = min(bottom, r.y)
        }
        let y = max(min(click.y, bottom - line), selection.y)
        let x = max(min(click.x, selection.right - minW), selection.x)
        return PixelPoint(x, y)
    }

    /// The box for a text at `at` holding `lines` lines of height `line`.
    ///
    /// Its width runs to the selection's right edge and is at least `minW`
    /// (stopped at the display's edge). Its height is a whole number of
    /// lines: as many as the text has, but no more than fit above the
    /// selection's bottom edge -- or the display's, for a text that is not
    /// in the selection at all -- and above the top of any of `keepClear`
    /// below it. Never less than one line.
    static func rect(
        at: PixelPoint, lines: Int, line: Int, minW: Int,
        selection: PixelRect, display: PixelRect, keepClear: [PixelRect]
    ) -> PixelRect {
        let line = max(line, 1)
        let w = max(min(max(selection.right - at.x, minW), display.right - at.x), 1)
        let inSelection = at.y >= selection.y && at.y < selection.bottom
        var limit = inSelection ? selection.bottom : display.bottom
        // Below the text's first row, or holding it: one that holds it
        // leaves no room at all, and the one line is all there is.
        for r in keepClear where r.bottom > at.y && overlapsAcross(r, x: at.x, w: w) {
            limit = min(limit, r.y)
        }
        let fit = max((limit - at.y) / line, 1)
        return PixelRect(at.x, at.y, w, min(max(lines, 1), fit) * line)
    }

    /// Whether a press at `p` is the toolbar's even though the box is
    /// there: the toolbar is asked first, always.
    static func onToolbar(_ p: PixelPoint, keepClear: [PixelRect]) -> Bool {
        keepClear.contains { $0.contains(p) }
    }
}
