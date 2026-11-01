import CoreGraphics
import SwiftUI

/// The two things about a pane preview that are **not** `PreviewLayout`'s and
/// are stated here once, so that each has one reader:
///
///  * where a pointer puts the divider, as the width of the preview -- a
///    coordinate flip, not a rule;
///  * whether the terminal behind a preview is dimmed -- the design's
///    `--scrim`.
///
/// Neither is a second opinion about a width. What the width *is* is
/// `PreviewLayout.split`'s, and it is held to the Windows host line by line;
/// what the preview may be *dragged* to is `PreviewSlot.dragged`'s band.
enum PaneFramePreviewRules {
    typealias Split = PreviewLayout.Split

    /// The width of the preview when the divider is dragged to `pointerX` in
    /// a cell `cellW` wide.
    ///
    /// **A coordinate flip, and not a rule.** `x` is measured from the cell's
    /// left edge and a preview's width from its right, so the two differ by
    /// the cell's width and by nothing else. What that width may be is
    /// `PreviewSlot.dragged`'s band; what is stored is what the drag asked for
    /// (`PreviewSlot` says why the clamp is not stored). Neither of those is
    /// here, and this adds no third answer to them.
    static func previewWidth(cellW: CGFloat, pointerX: CGFloat) -> CGFloat {
        cellW - pointerX
    }

    /// The terminal behind the preview is dimmed.
    ///
    /// **Over the terminal, and only there.** Side by side the two are
    /// neighbours on the cell's own ground and nothing is laid over the
    /// terminal; it is when the preview *covers* it that the strip left in
    /// sight has to read as being behind rather than as a second terminal
    /// (the design's `src/files.css`: `.split.over > .cv::after` draws the
    /// scrim, `.split > .cv` draws none).
    ///
    /// ⚠️ **Named, because it is asked once.** Written inline in the view it
    /// was a condition nothing could see: a mutation that made the whole
    /// branch unreachable left every test green (`evid/dev-A2-floor-M5-*`, the
    /// floor of task 2634). A rule with a name has one place to be wrong in
    /// and one place to be read from.
    static func dims(_ split: Split) -> Bool {
        split.overlay && split.previewWidth > 0
    }

    /// The box the divider is dragged by, either side of the hairline.
    ///
    /// ⚠️ **Not a layout number, and not the design's.** The design draws the
    /// line and says nothing about how it is grabbed (`src/files.css`:
    /// `.split > .fp { box-shadow: inset .5px 0 0 var(--sep) }` -- a
    /// hairline, and half a point is not a target). So it is the same box the
    /// split view's own divider is dragged by
    /// (`SplitView.splitterInvisibleSize`), the way `PaneFrameSplit`'s
    /// `dividerWidth` is the same *line* as that one's
    /// (`SplitView.splitterVisibleSize`): dragging either kind of divider is
    /// then the same act, and neither number is a second opinion about where
    /// anything goes.
    static let hitWidth: CGFloat = 6
}

/// The file preview beside a terminal, inside one pane (task 2634, #2140 M2;
/// the design's `INTERACTION.md` §一 终端格里的预览, and `src/files.css`'s
/// `.split > .cv` / `.split.over > .fp`).
///
/// **Where the two go is not decided here.** `PreviewSlot.split` answers it,
/// which is `PreviewLayout.split` -- the one rule the macOS and the Windows
/// host share, held line by line to
/// `src/poltergeist/testdata/preview_layout_cases.json`. This puts the two
/// views where that answer says and adds nothing: not a minimum, not a
/// subtraction, not a rounding. A host that worked a width out for itself is
/// the second copy `PreviewLayout` exists to prevent, and a view layer
/// reading the same numbers back would only be a third.
///
/// **The terminal is one view, in one place, behind no `if`.** Opening the
/// preview moves the terminal's *frame*; it never chooses between two views.
/// See `PaneFrameChrome`: a terminal's `NSView` outlives SwiftUI's, and a
/// choice here is two places in SwiftUI's tree, which unmakes what was in one
/// and makes it again in the other -- a blank pane, on splitting a tab that
/// had one terminal in it (task 1461). What is put here is a `ZStack`, whose
/// children are the terminal, the dimming, the panel and the divider; the
/// terminal is one of them and stays the same one.
///
/// **Values in, a view out.** No application, no core, no surface, no
/// terminal, no lender: a cell is a `String`, the state is
/// `PreviewSlot.Store`, and the thing drawn beside the terminal is handed in.
/// That is what lets every decision in this file run in
/// `tools/mac-logic-tests`, in a window that is never put on screen --
/// `PaneFramePreviewTests` holds the terminal to it, the way
/// `PaneFrameChromeTests` holds a frame to it.
struct PaneFramePreview<Panel: View>: ViewModifier {
    typealias Look = ControlRoomLook
    typealias Slot = PreviewSlot
    typealias Split = PreviewLayout.Split

    /// Which cell this is: the key the store keeps its state under. In the app
    /// it is the surface's id; here it is a name and nothing else.
    var cell: String

    /// Every cell's state. **A `Binding` and not a copy**: whether a preview
    /// is open, and where its divider was dragged to, outlive the cell being
    /// redrawn, and a drag is a write.
    @Binding var store: Slot.Store

    /// The panel itself, told where it landed. Drawing it is the panel's job;
    /// which of the two shapes it is, is this one's -- and the design gives
    /// the two different headers: over the terminal it carries `‹ 终端` at its
    /// left end and drops the plugin name and the history arrows; beside it,
    /// the other way round (`src/files.css`, `.split.over .fh .back` against
    /// `.split.over .fh .by, .hb { display: none }`).
    var panel: (Split) -> Panel

    @Environment(\.colorScheme) private var scheme

    /// The cell's own coordinates: the pointer's `x` is measured from the
    /// cell's left edge, which is the one thing the gesture needs and cannot
    /// get from a local space.
    private static var space: String { "poltergeist.pane-preview" }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let cellW = geometry.size.width
            let split = store.split(cell, cellW: cellW)
            ZStack(alignment: .topLeading) {
                // The terminal. One view, one place, whatever the preview is
                // doing: closing the preview gives it the whole cell back,
                // opening it side by side takes its share, and a preview over
                // it leaves it its own size (the design: 盖上去时，终端的尺寸
                // 不变).
                content
                    .frame(width: max(0, split.terminalWidth), height: geometry.size.height,
                           alignment: .topLeading)
                    .offset(x: split.terminalX)
                // Over the terminal: the terminal is left in sight dimmed. It
                // is a dimming and not a lid -- the design's `--scrim` over
                // the whole of `.cv`, with the panel covering all of it but
                // the `overlayLeftExpose` at the left. What stays in sight is
                // the terminal and it stays reachable, so this layer takes no
                // click of its own, and the way out is the panel's own
                // `‹ 终端`. **Whether there is one at all is
                // `PaneFramePreviewRules.dims`'s** and is asked there, so that
                // it is one answer with a name rather than a condition that
                // lives only inside a view.
                if PaneFramePreviewRules.dims(split) {
                    Rectangle()
                        .fill(Look.theme(scheme).previewScrim.color)
                        .frame(width: max(0, split.terminalWidth), height: geometry.size.height,
                               alignment: .topLeading)
                        .allowsHitTesting(false)
                }
                // The panel. `previewWidth > 0` is "the preview is open" in
                // the terms the layout already keeps: a closed cell's split
                // answers nothing to draw, and a cell too narrow to hold one
                // answers a width of zero rather than a negative one.
                if split.previewWidth > 0 {
                    panel(split)
                        .frame(width: split.previewWidth, height: geometry.size.height,
                               alignment: .topLeading)
                        .offset(x: split.previewX)
                }
                // The divider, where the two meet, and only where there is one
                // to drag: side by side, with the preview open. Under the
                // threshold there is no divider -- the preview is over the
                // terminal, and a drag in a cell with no divider is not a drag
                // that means anything (`PreviewSlot.dragBand`).
                if split.previewWidth > 0, !split.overlay, Slot.dragBand(cellW: cellW) != nil {
                    divider(cellW: cellW, split: split, height: geometry.size.height)
                }
            }
            .frame(width: cellW, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
        }
    }

    /// The line the two are divided by, and the only thing in the cell that
    /// takes a drag.
    @ViewBuilder
    private func divider(cellW: CGFloat, split: Split, height: CGFloat) -> some View {
        Rectangle()
            .fill(Look.theme(scheme).line.color)
            .frame(width: CGFloat(Look.Line.hairline), height: height)
            .frame(width: PaneFramePreviewRules.hitWidth, height: height)
            .contentShape(Rectangle())
            .offset(x: split.previewX - PaneFramePreviewRules.hitWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        store.setDraggedW(cell, PaneFramePreviewRules.previewWidth(cellW: cellW,
                                                                             pointerX: value.location.x))
                    }
            )
    }
}

extension View {
    /// A file preview beside this view, in one cell of a split.
    ///
    /// **The wiring, and not a rule.** The app passes the surface's id, its
    /// store and a panel that says `GhosttyKit`; every decision the modifier
    /// makes is made from those three.
    func panePreview<Panel: View>(
        cell: String,
        store: Binding<PreviewSlot.Store>,
        @ViewBuilder panel: @escaping (PreviewLayout.Split) -> Panel
    ) -> some View {
        modifier(PaneFramePreview(cell: cell, store: store, panel: panel))
    }
}
