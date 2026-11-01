import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The file preview beside a terminal, in one pane (`PaneFramePreview`, task
/// 2634, #2140 M2).
///
/// **What is held to here, and what is not.** Where the two views go is
/// `PreviewLayout.split`'s, and it has its own tests (`PreviewLayoutTests`)
/// and the shared fixture the two hosts are held to
/// (`tools/control-room-hosts-agree.py`). A view layer answering the same
/// questions again would be a second copy of that rule, so nothing here says
/// what a width *is*. What is tested is the part that only exists in a view:
///
///  1. **The terminal is one view, in one place, through everything.** This
///     is task 1461's defect, and it is the one thing here that no assertion
///     about sizes or states could catch: a terminal's `NSView` outlives
///     SwiftUI's, and a choice between two views round it unmakes what was in
///     one and makes it again in the other. The pane is blank after that, and
///     every number is right.
///  2. **The terminal is given the width the split answered**, so a change of
///     state reaches it at all.
///  3. **The panel is told where it landed** -- beside the terminal or over
///     it -- because the design draws its two headers differently.
///
/// No application is started: the views are in a window that is never put on
/// screen, as `PaneFrameChromeTests` does it.
@MainActor
struct PaneFramePreviewTests {
    typealias Slot = PreviewSlot
    typealias Look = ControlRoomLook

    /// Stands for a terminal's own view: made once, never by SwiftUI.
    final class Terminal: NSView {}

    /// Stands for `SurfaceScrollView`: when it is made it takes the
    /// terminal's view for its own, from wherever that was.
    ///
    /// **It is drawn white.** One test reads the cell's pixels
    /// (`theDimmingIsDrawnOverTheTerminalItself`), and a reading needs
    /// something of a known colour to read: white is the terminal's, and what
    /// the dimming does to it is the measurement. Nothing else here cares
    /// what it looks like.
    final class Holder: NSView {
        init(_ terminal: NSView) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.cgColor
            addSubview(terminal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }
    }

    final class Count { var made = 0 }

    struct Hold: NSViewRepresentable {
        let terminal: NSView
        let count: Count

        func makeNSView(context: Context) -> Holder {
            count.made += 1
            return Holder(terminal)
        }

        func updateNSView(_ view: Holder, context: Context) {}
    }

    /// Every split the panel was handed: what it was told, and whether it was
    /// drawn at all.
    final class Log {
        var splits: [PreviewSlot.Layout.Split] = []
        func saw(_ split: PreviewSlot.Layout.Split) { splits.append(split) }
        var last: PreviewSlot.Layout.Split? { splits.last }
    }

    /// One cell's facts. An object because the view observes it: `@Published`
    /// is what makes a change to the store reach the view again, which is
    /// what a drag or the 「文件」button does in the app.
    final class Model: ObservableObject {
        @Published var store = Slot.Store()
        let terminal = Terminal()
        let count = Count()
        let log = Log()
    }

    /// One cell: a terminal, and the preview this file puts beside it.
    struct Cell: View {
        @ObservedObject var model: Model
        let cellW: CGFloat

        var body: some View {
            Hold(terminal: model.terminal, count: model.count)
                .panePreview(cell: "cell", store: $model.store) { split in
                    // Draws nothing: what the panel *is* is another file's
                    // business, and the design's own words (`‹ 终端`) are its
                    // and are translated there. A placeholder keeps these
                    // tests to the placement.
                    Sized(log: model.log, split: split)
                }
                .frame(width: cellW, height: 400)
        }
    }

    /// The placeholder, with the one side effect the tests read: what the
    /// panel was handed, each time it is drawn.
    struct Sized: View {
        let log: Log
        let split: PreviewSlot.Layout.Split

        var body: some View {
            Color.clear.onAppear { log.saw(split) }
        }
    }

    /// A cell in a window nobody sees, and a way to let SwiftUI catch up.
    final class Stage {
        let model: Model
        let window: NSWindow
        let host: NSHostingView<Cell>

        init(cellW: CGFloat = 1200) {
            let model = Model()
            self.model = model
            host = NSHostingView(rootView: Cell(model: model, cellW: cellW))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: cellW, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            settle()
        }

        func settle() {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            host.layoutSubtreeIfNeeded()
        }

        var store: Slot.Store { model.store }
        var terminal: Terminal { model.terminal }
        var count: Count { model.count }
        var log: Log { model.log }

        func change(_ what: (inout Slot.Store) -> Void) {
            var s = model.store
            what(&s)
            model.store = s
            settle()
        }

        /// The terminal is in no window: what a blank pane is.
        var lost: Bool { terminal.window !== window }

        /// What the terminal's holder was given, in points.
        var holderSize: CGSize? { terminal.superview?.frame.size }

        /// What the cell looks like where it is drawn: the brightness at one
        /// point of the cell, 0...1, or nil if it could not be drawn.
        ///
        /// **Drawn, and not described.** Nothing in a SwiftUI tree says
        /// whether a given layer was painted -- a `Rectangle` is not a view
        /// anybody can ask, and the branch that draws it is unreachable to
        /// every assertion about values. So the cell is rasterised, as it
        /// would be on screen, and the pixels are read: it is the only read
        /// that can see the difference between a dimming that is drawn and
        /// one that is not (`theDimmingIsDrawnOverTheTerminalItself`).
        ///
        /// The window is never put on screen; `cacheDisplay` draws the view
        /// as it stands, which is the same thing `PaneFrameChromeTests` asks
        /// of a frame.
        func drawnBrightness(atX x: CGFloat, y: CGFloat = 200) -> CGFloat? {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.colorAt(x: Int(x), y: Int(y))?.brightnessComponent
        }
    }

    // MARK: The reported case

    /// **The case this file exists for.** Opening the preview, dragging its
    /// divider, closing it, and opening it again -- the terminal is in the
    /// window through every step and its holder is never made a second time.
    ///
    /// ⚠️ A view layer that wrote `if open { … } else { … }` round the
    /// terminal would pass every assertion about widths and states in this
    /// file and blank the pane on the commonest action there is.
    @Test func theTerminalIsOneViewInOnePlaceThroughEverythingThePreviewDoes() {
        let stage = Stage()
        #expect(!stage.lost)
        let made = stage.count.made
        let holder = stage.terminal.superview

        stage.change { $0.set("cell", open: true) }
        #expect(!stage.lost, "opening the preview lost the terminal")
        #expect(stage.count.made == made, "opening the preview made a second holder")
        #expect(stage.terminal.superview === holder, "opening the preview moved the terminal")

        stage.change { $0.setDraggedW("cell", 700) }
        #expect(!stage.lost, "dragging the divider lost the terminal")
        #expect(stage.count.made == made, "dragging the divider made a second holder")
        #expect(stage.terminal.superview === holder, "dragging the divider moved the terminal")

        stage.change { $0.set("cell", open: false) }
        #expect(!stage.lost, "closing the preview lost the terminal")
        #expect(stage.count.made == made, "closing the preview made a second holder")
        #expect(stage.terminal.superview === holder, "closing the preview moved the terminal")

        stage.change { $0.set("cell", open: true) }
        #expect(!stage.lost, "reopening the preview lost the terminal")
        #expect(stage.count.made == made, "reopening the preview made a second holder")
        #expect(stage.terminal.superview === holder, "reopening the preview moved the terminal")
    }

    /// And the same in a cell too narrow to hold a divider, where the preview
    /// goes over the terminal instead of beside it: that is the other branch
    /// of the same view, and it must not make a second holder either.
    @Test func aCellTooNarrowToSplitStillKeepsTheTerminalInTheWindow() {
        let stage = Stage(cellW: CGFloat(Look.Preview.cellMinWidthSideBySide) - 1)
        let made = stage.count.made
        let holder = stage.terminal.superview
        stage.change { $0.set("cell", open: true) }
        #expect(!stage.lost, "opening a preview over the terminal lost it")
        #expect(stage.count.made == made, "opening a preview over the terminal made a second holder")
        #expect(stage.terminal.superview === holder)
        #expect(stage.log.last?.overlay == true)
    }

    // MARK: The width the terminal is given

    /// **The split's answer is what the terminal gets**, and not a number of
    /// this file's own: the width is asked from `PreviewSlot.split` and the
    /// same question is asked here.
    ///
    /// ⚠️ This is not a second copy of the rule. What is compared is the
    /// holder's frame against the *same call* the view makes -- so a view
    /// that worked a width out for itself, or ignored the one it was given,
    /// is red here, while `PreviewLayoutTests` stays the only place a width's
    /// value is written down.
    ///
    /// ⚠️ **Two cells, because the split has two shapes**, and only asking
    /// the wide one left the overlay branch with **no width assertion at
    /// all**. At and above `cellMinWidthSideBySide` the two are side by side
    /// and `terminalWidth = cellW - previewWidth`; under it the preview is
    /// over the terminal and `terminalWidth` is the whole cell. So a view
    /// that worked the width out as `cellW - previewWidth` is *the same
    /// number by definition* on the wide branch and a different one here --
    /// a mutant of that shape is invisible on 1200 and caught on 799. Missing
    /// cell is what the test seat's own floor found (task 2634,
    /// `evid/A2-floor-round5-SUMMARY.md` §三): its overlay fixture was the
    /// only thing that went red, on 40.0 against 799.0.
    @Test func theTerminalIsGivenTheWidthTheSplitAnswers() {
        for cellW in [CGFloat(1200), CGFloat(Look.Preview.cellMinWidthSideBySide) - 1] {
            let stage = Stage(cellW: cellW)
            for open in [false, true] {
                for dragged in [nil, 500, 900] as [CGFloat?] {
                    stage.change {
                        $0.set("cell", open: open)
                        $0.setDraggedW("cell", dragged)
                    }
                    // The same call the view makes, for this cell's width.
                    let want = stage.store.split("cell", cellW: cellW).terminalWidth
                    #expect(stage.holderSize?.width == want,
                            "cellW=\(cellW) open=\(open) dragged=\(String(describing: dragged))")
                }
            }
        }
    }

    // MARK: What the panel is told

    /// The panel is handed the split, so it can draw the header the design
    /// gives that shape: over the terminal it carries `‹ 终端` and drops the
    /// plugin name and the history arrows, and beside it the other way round.
    @Test func thePanelIsToldWhereItLanded() {
        let stage = Stage()
        stage.change { $0.set("cell", open: true) }
        #expect(stage.log.last?.overlay == false)
        #expect(stage.log.last?.previewWidth
                == stage.store.split("cell", cellW: 1200).previewWidth)

        let narrow = Stage(cellW: CGFloat(Look.Preview.cellMinWidthSideBySide) - 1)
        narrow.change { $0.set("cell", open: true) }
        #expect(narrow.log.last?.overlay == true)
    }

    /// A closed cell draws no panel at all: the preview is not there, rather
    /// than there and empty. (The store's own tests hold what a closed cell's
    /// split answers; this holds that the answer is acted on.)
    @Test func aClosedCellDrawsNoPanel() {
        let stage = Stage()
        #expect(stage.store.split("cell", cellW: 1200).previewWidth == 0)
        #expect(stage.log.splits.isEmpty, "a closed cell drew a panel")
        stage.change { $0.set("cell", open: true) }
        #expect(stage.store.split("cell", cellW: 1200).previewWidth > 0)
        #expect(!stage.log.splits.isEmpty, "an open cell drew no panel")
    }

    // MARK: The dimming over the terminal

    /// **Over the terminal, and only there.** Side by side the two are
    /// neighbours on the cell's own ground and nothing is laid over the
    /// terminal; it is when the preview *covers* it that the strip left in
    /// sight has to read as being behind rather than as a second terminal.
    ///
    /// ⚠️ **What this is not.** This holds the rule (`PaneFramePreviewRules
    /// .dims`), which is a value in and a `Bool` out. It does **not** hold the
    /// one line of the view that asks it: a `Rectangle` is drawn, not put in
    /// a tree, so nothing in this file can see whether that line ran. That
    /// line's floor is the read of it and the real machine, and it is said so
    /// rather than covered up -- the mutation that makes that branch
    /// unreachable is green here (`evid/dev-A2-floor-M5b-*`), and green there
    /// is the finding, not a pass. Worth the split because the *rule* can at
    /// least go red, which is more than the unnamed condition it replaced
    /// could.
    @Test func theTerminalIsDimmedOnlyUnderAPreviewOverIt() {
        func dims(open: Bool, cellW: CGFloat) -> Bool {
            var store = Slot.Store()
            store.set("cell", open: open)
            return PaneFramePreviewRules.dims(store.split("cell", cellW: cellW))
        }

        // Closed: no preview, and so nothing over the terminal.
        #expect(!dims(open: false, cellW: 1200))
        // Beside it: the two are neighbours, and the terminal is its own
        // ground with nothing laid over it.
        #expect(!dims(open: true, cellW: 1200))
        // Over it: the one shape the design draws with a scrim.
        #expect(dims(open: true, cellW: CGFloat(Look.Preview.cellMinWidthSideBySide) - 1))
        // And a cell with no room for a preview at all draws no preview, so
        // there is nothing to dim the terminal under.
        #expect(!dims(open: true, cellW: 0))
    }

    /// **And the dimming is drawn.** The rule above says *whether* there is
    /// one; this reads the cell to see that the view did anything about it.
    ///
    /// ⚠️ **Why a pixel and not an assertion about a value.** The branch that
    /// draws the scrim is `if PaneFramePreviewRules.dims(split) { Rectangle()
    /// … }`, and no assertion in this file can see whether that branch ran:
    /// a `Rectangle` is not a view anybody can ask, and the only value around
    /// it is the `split`, which is the same either way. A mutation making the
    /// condition `false` leaves every other test in this file green
    /// (`evid/dev-A2-floor-M5b-*`). The cell is therefore rasterised -- the
    /// terminal's holder is white, so what a layer over it does is a
    /// brightness -- and read at one point.
    ///
    /// The point is inside the `overlayLeftExpose` strip: with the preview
    /// over the terminal, that strip is the part of the terminal still in
    /// sight, which is exactly the part the design dims.
    @Test func theDimmingIsDrawnOverTheTerminalItself() throws {
        let narrow = Stage(cellW: CGFloat(Look.Preview.cellMinWidthSideBySide) - 1)
        let expose = CGFloat(Look.Preview.overlayLeftExpose)
        let inSight = expose / 4

        // Shut, with the same cell and the same point: the terminal is white
        // and nothing is over it. Without this the test would pass on a cell
        // that draws the scrim always.
        let shut = try #require(narrow.drawnBrightness(atX: inSight),
                                "the cell could not be drawn at all")
        #expect(shut > 0.99, "the terminal under nothing read \(shut), not white")

        narrow.change { $0.set("cell", open: true) }
        #expect(narrow.log.last?.overlay == true, "this cell is not the overlay shape")
        let drawn = try #require(narrow.drawnBrightness(atX: inSight))
        // ⚠️ **One literal, not a concatenation.** `#expect`'s message is a
        // `Comment`, which a string literal can be and a `+` of two cannot
        // (`cannot convert value of type 'String' to expected argument type
        // 'Comment?'`) -- caught by the floor's own A0 negative control, which
        // is what it is for.
        #expect(drawn < shut - 0.05,
                "the terminal reads \(drawn) under a preview over it and \(shut) with none: the dimming is not drawn")
    }

    // MARK: The divider's one piece of arithmetic

    /// **A coordinate flip, and not a rule.** The pointer's `x` is measured
    /// from the cell's left edge and the preview's width from its right, so
    /// the two differ by the cell's width and by nothing else. What the width
    /// may be is the band's, which is `PreviewSlot.dragged`'s and has its own
    /// tests.
    @Test func theDividerTurnsAPointerPositionIntoAPreviewWidth() {
        #expect(PaneFramePreviewRules.previewWidth(cellW: 1200, pointerX: 700) == 500)
        // Dragged hard left: the flip asks for the whole cell, and the band is
        // what leaves the terminal its least.
        #expect(PaneFramePreviewRules.previewWidth(cellW: 1200, pointerX: 0) == 1200)
        #expect(Slot.dragged(cellW: 1200, to: PaneFramePreviewRules.previewWidth(cellW: 1200, pointerX: 0))
                == 1200 - CGFloat(Look.Preview.terminalMinWidth))
        // Dragged past the right edge: the flip goes under the preview's
        // least, and the band holds it up.
        #expect(PaneFramePreviewRules.previewWidth(cellW: 1200, pointerX: 1300) == -100)
        #expect(Slot.dragged(cellW: 1200, to: PaneFramePreviewRules.previewWidth(cellW: 1200, pointerX: 1300))
                == CGFloat(Look.Preview.previewMinWidth))
    }
}
