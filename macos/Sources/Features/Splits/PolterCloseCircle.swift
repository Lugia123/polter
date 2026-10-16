import CoreGraphics

/// The close button on a split's title and on a stack's tab, as the window's
/// own tabs draw theirs on macOS (task 1642): at the left end, there only
/// while the pointer is over the title or the tab, a cross in a disc.
///
/// **What was read off the system's tab** (macOS 26, a terminal window's
/// native tab bar, poltertest, 2026-10-16, Retina screenshots): the button
/// is an 18 pt square 4 pt in from the tab's left end, centred in the 24 pt
/// tab. A disc 16 across fills while the pointer is on the button -- white
/// at 0.107 over a dark bar (68 -> 88 of 255), black at 0.064-0.073 over a
/// light one (249 -> 233, 220 -> 204) -- and deepens while it is held down,
/// white at 0.176 (68 -> 101) and black at 0.145 (249 -> 213). The cross is
/// 7.5 pt across where it is inked (15 px), its strokes about 1.1 pt (a row
/// through the centre crosses 3.3 px of ink, which a 45-degree stroke of
/// width w does at w x 1.41): white at about 0.97 (247) dark, black (0)
/// light, on the disc. The first build here drew 1.5 and read 4.5 px on
/// the same row, with 116 inked pixels to the system's 81. With the pointer on the tab and not the button the
/// system draws the cross with no disc, at about 0.6 of that ink.
///
/// **Where this differs, on purpose.** The system's tab centres its title,
/// so its bare cross is rarely over a letter; a pane's title and a stack
/// tab's name start at the left, where the button now is. So the disc is
/// always there while the button shows, at the system's "pointer on the
/// button" depth, and the text under it is cut away (`Hole`) rather than
/// drawn through a translucent disc. Pressed is the system's pressed depth.
/// The button's left edge is not 4 pt in from the tab's end: the disc's
/// left edge is on the text's, so it lines up with what it covers.
enum PolterCloseCircle {
    /// The button's square: the system tab's `_closeButton`.
    static let side: CGFloat = 18
    /// The disc in that square.
    static let disc: CGFloat = 16
    /// The box the cross's two strokes run corner to corner of; with the
    /// stroke's round ends it inks 7.5 across, as the system's does.
    static let cross: CGFloat = 6.4
    static let stroke: CGFloat = 1.1

    /// The button's square, in the coordinates of a band `height` tall
    /// whose text starts at `textLeading`: the disc's left edge on the
    /// text's, the square centred up and down.
    static func frame(textLeading: CGFloat, height: CGFloat) -> CGRect {
        let margin = (side - disc) / 2
        return CGRect(x: textLeading - margin, y: (height - side) / 2, width: side, height: side)
    }

    /// The disc of the button whose square is `frame`.
    static func disc(in frame: CGRect) -> CGRect {
        let margin = (side - disc) / 2
        return frame.insetBy(dx: margin, dy: margin)
    }

    /// How far past the disc's right edge the text under the button is cut
    /// away (task 1642).
    ///
    /// **A column, not a ring.** Cut round the disc, letters stuck out past
    /// the curve: at the disc's edge exactly the tip of a `/` and the foot of
    /// a `t` beside it showed, and with a 2.5 ring the curl of the `t`'s foot
    /// still sat as a speck at the baseline (poltertest, both themes). So the
    /// text is cut by a straight edge instead, the band's whole height, from
    /// its start to 2.5 past the disc -- nothing of the text is drawn to the
    /// left of where it starts, so that loses nothing else.
    static let knockout: CGFloat = 2.5

    /// What is cut out of the text in a band `bounds` with the button at
    /// `frame`: from the band's start to `knockout` past the disc, its whole
    /// height.
    static func hole(in bounds: CGRect, button frame: CGRect) -> CGRect {
        let right = disc(in: frame).maxX + knockout
        return CGRect(x: bounds.minX, y: bounds.minY, width: max(0, right - bounds.minX), height: bounds.height)
    }

    /// The two depths of the disc, and the cross's ink, per theme: (light,
    /// dark), each an opacity of black (light) or white (dark).
    static let discShown: (light: Double, dark: Double) = (0.07, 0.107)
    static let discPressed: (light: Double, dark: Double) = (0.145, 0.176)
    static let crossInk: (light: Double, dark: Double) = (1, 0.97)
}
