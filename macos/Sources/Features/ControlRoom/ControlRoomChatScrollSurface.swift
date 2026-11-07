import AppKit
import OSLog
import SwiftUI

/// **The list's window, as a scroll view that only produces the scroll**
/// (task 3016, the first slice; design v2 §21).
///
/// `NSScrollView` is kept as the **input device**: the wheel's phases and
/// momentum, natural scrolling, page keys and the accessibility scroll
/// action all come from it for free. What it scrolls is not the history --
/// its `documentView` is one fixed height and draws nothing -- and the
/// rendering is ours: a viewport-sized `NSHostingView` pinned at the clip
/// origin shows only the rows of the window, offset so their document
/// coordinates line up.
///
/// **Why the fixed document height matters**: the clip origin is the one
/// number the scroll view owns, and it is a point in a document whose height
/// never changes with the rows. Rows going in or out move no pixel of it,
/// which is what removes the compensation from this model.
///
/// **The first frame is the bottom** (design §14): the surface positions
/// itself once, at `startAt`, before anything is drawn, so a page that opens
/// following the newest row does not draw the top of the history first.
///
/// **What is not here yet** (later slices, design §13/§15/§16/§17): the
/// second truth `pinned` lives in `ControlRoomChatCamera.State` and is kept;
/// an anchor whose row is gone, the key of the height cache and the
/// normalisation of the offset inside a row are the next slice's.
struct ControlRoomChatScrollSurfaceView: NSViewRepresentable {
    /// The whole document's height in points, from `Layout.contentHeight`.
    var documentHeight: CGFloat
    /// The visible height, in points.
    var viewport: CGFloat
    /// The name of the coordinate space the rows report their frames in.
    var space: String
    /// The window's rows, already built.
    var content: AnyView
    /// **Where the window's first row is in the document**, in points. The
    /// content is laid out from 0 (the hosting view must contain what it
    /// lays out -- a top padding the size of the history is layout the
    /// viewport frame does not contain, and it is clipped away), so the rows
    /// report coordinates relative to the window and this is what turns them
    /// back into the document's.
    var base: CGFloat
    /// Where the surface puts itself the first time it has a size: the
    /// bottom while the page follows the newest row (design §14).
    var startAt: CGFloat?
    var onFrames: ([String: CGRect]) -> Void
    /// **The view changed the document's own frame** -- the geometry action,
    /// not "the content's height is different from last time". The caller uses
    /// it to tell a clamp AppKit made in response to a frame change from a
    /// reader's move: the first must not write the anchor, the second must.
    /// One call per actual change, and the caller clears it immediately.
    var onGeometry: () -> Void

    func makeNSView(context: Context) -> ControlRoomChatSurfaceClip {
        let view = ControlRoomChatSurfaceClip()
        view.space = space
        view.onFrames = onFrames
        view.onGeometry = onGeometry
        view.apply(
            documentHeight: documentHeight,
            viewport: viewport,
            base: base,
            content: content,
            startAt: startAt
        )
        return view
    }

    func updateNSView(_ view: ControlRoomChatSurfaceClip, context: Context) {
        view.space = space
        view.onFrames = onFrames
        view.onGeometry = onGeometry
        view.apply(
            documentHeight: documentHeight,
            viewport: viewport,
            base: base,
            content: content,
            startAt: startAt
        )
    }
}

/// The window's geometry, **without a view**: which rows are in it, where
/// each one starts in the document, and how tall the document is.
///
/// The heights are the ones the view has measured (`frames`) where it has
/// them and the feed's own estimate everywhere else. An estimate is only
/// ever a placeholder for a row no one has laid out; a row in the window is
/// measured the moment it is drawn, so the estimate never reaches a row the
/// reader can see for longer than a frame.
struct ControlRoomChatScrollSurface {
    /// The stack's own spacing, the same number the list is drawn with.
    static let spacing: CGFloat = 10
    /// The list's top padding, in document coordinates.
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 12
    /// A boundary mark (the two ends and a released run) is a hairline and a
    /// sentence; it is short and it is not measured by `frames`, which only
    /// carries messages.
    static let boundaryHeight: CGFloat = 30
    /// **Where an anchor's row is on the document, when that row has been
    /// drawn** (review K): **its own measured frame**, whose coordinates are
    /// the same ones the content was laid out in -- never the window's ruler,
    /// which accumulates estimates from the plan's first row.
    ///
    /// The algebra the whole slice turns on: the anchor's screen position is
    /// `frame.minY + offset − clip`, and the clip is set to exactly that, so
    /// it is `0` **whatever the rows above it are measured at**. With the
    /// window's ruler instead, the same expression carries the estimate error
    /// of every row between the window's first row and the anchor, and
    /// measuring any of them moves the pixels that are already on screen --
    /// the 2026-11-07 stuck red (the same anchor's target walked back and
    /// forth by 18–38 pt between frames).
    ///
    /// `fallback` is the window's ruler, for a row that has never been drawn
    /// (a jump into a page that has not arrived yet). It is the *only* place
    /// an estimate may decide a position.
    ///
    /// **A frame of no height is not a position.** `frames` arrives whole as a
    /// preference value, and a row the view has not really laid out yet
    /// reports one -- `framesArrived` (`:397`) and `cameraTopTick` (`:2312`)
    /// both refuse `height <= 1` for exactly this reason. Reading such a
    /// frame's `minY` would put the clip at a place nothing was drawn at, so
    /// this refuses it too and falls back, which is the honest answer for a
    /// row that has not been drawn.
    static let anchorFrameMinimumHeight: CGFloat = 1

    static func anchorDocumentY(
        frame: CGRect?,
        fallback: CGFloat,
        offset: Double
    ) -> Double {
        if let frame, frame.height > anchorFrameMinimumHeight {
            return Double(frame.minY) + offset
        }
        return Double(fallback) + offset
    }

    /// **How a hand's callback moves the anchor**: by the pixel difference
    /// against the clip this view already reconciled with. `nil` when there
    /// is no reference yet (the caller reads the clip absolutely then).
    ///
    /// **Never an absolute read while a reference exists**: the clip's y is
    /// only meaningful against the ruler that wrote it, and a page measured
    /// in re-scales the document under it -- the 2026-11-07 red, where one
    /// 40 pt step moved the anchor 45 rows because the same y was re-read
    /// against the new ruler.
    static func anchorMovement(seen: Double?, y: Double) -> Double? {
        guard let seen, seen.isFinite, y.isFinite else { return nil }
        return y - seen
    }

    /// **Where one row sits, for a reading about that row** (task 3016, the
    /// 2026-11-07 flutter): a height that changed is only something the
    /// person sees if the row is where they are looking. `at` is the row's
    /// plan index minus the anchor's -- **negative is above the anchor**,
    /// which is the side a change moves everything below it.
    ///
    /// `inside` and `onScreen` are two questions, not one: the window the
    /// surface draws is the viewport **plus its margin**, and the margin is
    /// what `window(at:viewport:)` spends its spare budget on. A row in the
    /// top margin is drawn, is inside the window, and is **not on the
    /// screen** -- and it is exactly the row whose changing height moves the
    /// picture below it. Reading `inside` as "the person saw it" would call
    /// those visible and send the next decision the wrong way.
    ///
    /// This exists as a value rather than as a sentence built at the log
    /// because the next decision hangs on it: changes that are all outside
    /// the screen mean the flutter is somewhere else and no layout change is
    /// owed. A sign the wrong way round would call every change above the
    /// anchor "below it" and read as ordinary -- the same log line, the
    /// opposite conclusion.
    struct Placement: Equatable {
        /// Rows between this one and the anchor; negative is above it.
        /// `nil` when there is no anchor to compare against.
        var at: Int?
        /// Whether the row is one the surface draws (the window).
        var inside: Bool
        /// Whether the row is one the person can actually see.
        var onScreen: Bool

        static func of(
            index: Int,
            anchor: Int?,
            window: Range<Int>,
            visible: Range<Int>
        ) -> Placement {
            Placement(
                at: anchor.map { index - $0 },
                inside: window.contains(index),
                onScreen: visible.contains(index)
            )
        }
    }

    /// **No window is bigger than this** (the criterion: 5 000 rows must
    /// instantiate at most forty). A viewport that needs more than forty rows
    /// to cover itself is smaller than the rows, and is served whole: the
    /// rows on screen are not a margin to be trimmed.
    static let windowLimit = 40

    struct Layout {
        /// The plan's ids, in document order.
        var ids: [String]
        /// Each id's height, aligned with `ids`.
        var heights: [CGFloat]
        /// **Which of those heights are measured** (aligned; empty means
        /// "all of them, as far as the window is concerned"). An unmeasured
        /// row's height is an estimate, and an estimate that is too tall
        /// stops the window before the screen does: the rows below are never
        /// drawn, so they are never measured, and the bottom of the screen is
        /// empty (review I, CE-1).
        ///
        /// **The cost of the rule below, said here**: when the rows the
        /// viewport itself needs number more than `windowLimit`, the window
        /// exceeds 40 -- the limit is a performance bound (5 000 rows must not
        /// instantiate 5 000), coverage is a correctness bound, and the worst
        /// case is the viewport's own row count plus half the spare margin on
        /// each side.
        var measured: [Bool] = []
        var spacing: CGFloat = ControlRoomChatScrollSurface.spacing
        var topPadding: CGFloat = ControlRoomChatScrollSurface.topPadding
        var bottomPadding: CGFloat = ControlRoomChatScrollSurface.bottomPadding
        var limit: Int = ControlRoomChatScrollSurface.windowLimit

        /// The document's y of a row's top.
        func top(of index: Int) -> CGFloat {
            guard !ids.isEmpty else { return topPadding }
            var y = topPadding
            for i in 0..<min(max(index, 0), ids.count) {
                y += max(0, heights[i]) + spacing
            }
            return y
        }

        /// The document's height: the last row's bottom plus the bottom
        /// padding.
        var contentHeight: CGFloat {
            guard !ids.isEmpty else { return topPadding + bottomPadding }
            let last = ids.count - 1
            return top(of: last) + max(0, heights[last]) + bottomPadding
        }

        /// **The row the viewport's top edge is in**: the last row whose top
        /// is at or above `y`. The gap below a row belongs to that row, the
        /// same rule `ControlRoomChatCamera.place` uses.
        func index(at y: CGFloat) -> Int {
            guard !ids.isEmpty else { return 0 }
            var cursor = topPadding
            for i in ids.indices {
                let height = max(0, heights[i])
                if cursor + height + spacing > y { return i }
                cursor += height + spacing
            }
            return ids.count - 1
        }

        /// **An item's slot**: its own height plus the stack's spacing below
        /// it. A point between two rows belongs to the row above, which is
        /// the rule `index(at:)` and the anchor's offset both use.
        func slotHeight(at index: Int) -> CGFloat {
            guard ids.indices.contains(index) else { return 1 }
            let own = max(0, heights[index])
            let gap = index < ids.count - 1 ? spacing : 0
            return max(1, own + gap)
        }

        /// **An anchor inside one slot** (design §17): the offset is walked
        /// into `[0, slotHeight)` one item at a time, at most `maxSteps`
        /// times. `nil` when it cannot be done -- the caller says so rather
        /// than writing a number that is thousands of points out of its row.
        func normalized(
            index: Int,
            offset: CGFloat,
            maxSteps: Int = 50
        ) -> (index: Int, offset: CGFloat)? {
            guard !ids.isEmpty else { return nil }
            var i = min(max(0, index), ids.count - 1)
            var value = offset
            for _ in 0..<maxSteps {
                let slot = slotHeight(at: i)
                if value < 0 {
                    guard i > 0 else { return (0, 0) }
                    i -= 1
                    value += slotHeight(at: i)
                    continue
                }
                if value >= slot {
                    guard i < ids.count - 1 else {
                        return (i, max(0, slot - 0.5))
                    }
                    value -= slot
                    i += 1
                    continue
                }
                return (i, value)
            }
            return nil
        }

        /// **The document's y that puts a row in the middle of the viewport**
        /// (design §15, rule 3): a locate lands the message it found where a
        /// reader can read it, with half a screen of its neighbours on each
        /// side, not on the top edge.
        func centeredOrigin(of index: Int, viewport: CGFloat) -> CGFloat {
            guard ids.indices.contains(index) else { return 0 }
            let height = max(0, heights[index])
            let wanted = top(of: index) - max(0, (viewport - height) / 2)
            // **The clip can only go as far as the document's last scrollable
            // point.** A row near the end cannot be centred, and returning a
            // y past the end wrote an anchor that describes a place the clip
            // can never reach: the scroll clamps, the callback looks like the
            // view's own, and the difference correction is zero -- so the
            // wrong anchor never heals.
            return min(
                max(0, wanted),
                max(0, contentHeight - viewport)
            )
        }

        /// **The rows the person can see**: the ones the viewport covers from
        /// `origin` down, by the same rule `index(at:)` uses. **Not the
        /// window**: `window(at:viewport:)` adds a margin above and below,
        /// and a row in that margin is drawn without being on the screen --
        /// which is the reading that matters for a height that changed.
        func visibleRows(at origin: CGFloat, viewport: CGFloat) -> Range<Int> {
            guard !ids.isEmpty, viewport > 0 else { return 0..<0 }
            let top = max(0, origin)
            let first = index(at: top)
            let last = index(at: top + viewport - 0.001)
            return first..<(max(first, last) + 1)
        }

        /// **The rows the window is made of.** `origin` is the document's y
        /// at the viewport's top edge.
        ///
        /// The rows under the viewport are always all in it -- a window that
        /// leaves part of the screen empty is not a smaller window, it is a
        /// hole -- and **what is left of the limit is split evenly above and
        /// below**, so the window is centred on the viewport and the part of
        /// it the reader cannot see is the same on both sides.
        ///
        /// **A side with no room does not hand its share to the other**
        /// (the 2026-11-07 red: at the end of the document the whole budget
        /// went above, the window started two screens up, and half of the
        /// forty rows it drew were outside the viewport).
        func window(at origin: CGFloat, viewport: CGFloat) -> Range<Int> {
            guard !ids.isEmpty else { return 0..<0 }
            let top = max(0, origin)
            let height = max(1, viewport)
            var low = index(at: top)
            var high = index(at: top + height - 0.001) + 1
            if high <= low { high = low + 1 }
            guard high - low < limit else { return low..<high }

            let budget = max(0, limit - (high - low))
            if high < ids.count, !isMeasured(high) {
                // **The page below has never been drawn, so the margin
                // belongs there** (review I, CE-1). An unmeasured run may be
                // far denser than the estimate; the window would stop inside
                // the viewport, the rows that belong there would never be
                // drawn -- so never measured, so never corrected, and the
                // bottom of the screen stays empty. The top margin is worth
                // nothing here: those rows are the ones already on screen.
                // The whole spare goes below, they are drawn and measured in
                // this frame, and the next selection is centred again.
                high = min(ids.count, high + budget)
            } else {
                let half = budget / 2
                low -= min(half, low)
                high += min(half, ids.count - high)
            }
            return low..<high
        }

        /// Whether a row's height is a measurement rather than an estimate.
        /// An empty `measured` vector means every height is taken as
        /// measured (a caller that only has heights).
        func isMeasured(_ index: Int) -> Bool {
            guard measured.indices.contains(index) else { return true }
            return measured[index]
        }

        /// The document's average row, for turning a screen into rows.
        var averageHeight: CGFloat {
            guard !ids.isEmpty else { return 0 }
            let total = heights.reduce(0) { $0 + max(0, $1) }
                + spacing * CGFloat(max(0, ids.count - 1))
            return total / CGFloat(ids.count)
        }
    }
}

// MARK: - The view

/// A flipped document: its y grows downward, so the clip origin is a
/// document coordinate measured from the top.
final class ControlRoomChatFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// **Where a wheel goes, said out loud** (task 3016 1a, the 2026-11-07
/// real-machine red: six minutes of synthetic wheels, page keys and AX
/// scrolls moved nothing and wrote no line). One line per gesture, from
/// whichever view received it, so a run can tell the two failures apart that
/// look identical on screen:
///
/// * `target=hosting` and then `target=scrollview`: the wheel reached the
///   app and the hosting view would have eaten it -- the forward below is
///   what makes it scroll;
/// * no line at all: the wheel never reached this view hierarchy, and the
///   problem is outside the list.
@MainActor
enum ControlRoomChatSurfaceWheel {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-surface"
    )
    private static var lastSpoke: TimeInterval = 0

    static func note(_ target: String, _ event: NSEvent) {
        let began = event.phase.contains(.began)
            || event.momentumPhase.contains(.began)
        let plain = event.phase.isEmpty && event.momentumPhase.isEmpty
        let now = ProcessInfo.processInfo.systemUptime
        // A gesture speaks once: on its `began`, or -- for a plain mouse
        // wheel, which has no phases -- once a second.
        guard began || (plain && now - lastSpoke > 1) else { return }
        lastSpoke = now
        log.notice(
            "scroll: enter target=\(target, privacy: .public) dy=\(event.scrollingDeltaY, privacy: .public) dx=\(event.scrollingDeltaX, privacy: .public) phase=\(event.phase.rawValue, privacy: .public) momentum=\(event.momentumPhase.rawValue, privacy: .public) precise=\(event.hasPreciseScrollingDeltas ? 1 : 0, privacy: .public)"
        )
    }
}

/// **The hosting view is a plain `NSView`: its `scrollWheel` is not the
/// scroll view's, and by default the event stops here.** Log it and hand it
/// to the enclosing scroll view -- the same act as the wheel having landed
/// there, with its phases and momentum untouched.
final class ControlRoomChatSurfaceHosting: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ControlRoomChatSurfaceHosting is made in code")
    }

    override func scrollWheel(with event: NSEvent) {
        ControlRoomChatSurfaceWheel.note("hosting", event)
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The scroll view itself, so the same gesture can be seen arriving at the
/// device it was meant for.
final class ControlRoomChatSurfaceScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        ControlRoomChatSurfaceWheel.note("scrollview", event)
        super.scrollWheel(with: event)
    }
}

/// **The `NSScrollView` as an input device** (design §21): a document of one
/// fixed height that draws nothing, a viewport-sized hosting view pinned at
/// the clip origin, and the window's content offset by the origin so its
/// document coordinates line up.
final class ControlRoomChatSurfaceClip: NSView {
    private let scrollView = ControlRoomChatSurfaceScrollView()
    private let document = ControlRoomChatFlippedView()
    private let hostClip = NSView()
    private var host: NSHostingView<AnyView>?
    private var content = AnyView(EmptyView())
    private var observer: NSObjectProtocol?
    private var renderedOrigin: CGFloat = .nan
    private var renderedBase: CGFloat = .nan
    private var base: CGFloat = 0
    private var positioned = false
    private var documentHeight: CGFloat = 0
    private var viewport: CGFloat = 0
    private var pendingStart: CGFloat?

    var space = ""
    var onFrames: (([String: CGRect]) -> Void)?
    /// Called the moment `document.frame` really changes (see the
    /// representable's note). Never called when the height is the same.
    var onGeometry: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        document.frame = .zero
        scrollView.documentView = document
        addSubview(scrollView)

        hostClip.wantsLayer = true
        hostClip.layer?.masksToBounds = true
        document.addSubview(hostClip)

        let hosting = ControlRoomChatSurfaceHosting(rootView: AnyView(EmptyView()))
        // **The frame is ours**: the hosting view is the viewport, not the
        // content, so it must not size itself to what it is handed.
        hosting.sizingOptions = []
        hosting.frame = .zero
        hostClip.addSubview(hosting)
        host = hosting

        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.clipMoved()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ControlRoomChatSurfaceClip is made in code")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// **Where the reader is, in the document's coordinates**, as far as the
    /// scroll view knows now. The view's own truth (`ControlRoomChatCamera`)
    /// is written from this, never the other way round.
    var origin: CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    func apply(
        documentHeight: CGFloat,
        viewport: CGFloat,
        base: CGFloat,
        content: AnyView,
        startAt: CGFloat?
    ) {
        self.documentHeight = documentHeight
        self.viewport = viewport
        self.content = content
        self.base = base
        if let startAt { pendingStart = startAt }
        syncGeometry()
        // **The content changed, so the root is rebuilt even when the
        // origin did not**: this is the one place a new window is handed in.
        renderedOrigin = .nan
        renderedBase = .nan
        syncRoot(origin: origin)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        syncGeometry()
        syncRoot(origin: origin)
    }

    /// **The hosting view is the viewport, pinned at the clip origin**
    /// (design §21). Its content is the window, laid out in document
    /// coordinates and offset by `-origin`, so a row's own `GeometryReader`
    /// still reports the document's y.
    private func syncGeometry() {
        guard scrollView.frame.height > 0 else { return }
        let width = max(1, scrollView.contentSize.width)
        let clipHeight = max(0, viewport > 0 ? viewport : scrollView.contentSize.height)
        // **The document never becomes shorter than the part of it that is
        // already on screen.** A page measured in re-scales every row above
        // the viewport; the document's bottom can drop by thousands of points
        // under a clip that is sitting near it, and `NSScrollView` answers a
        // shorter document by clamping the origin -- a clamp the view did not
        // ask for, moving the pixels the anchor names (the 2026-11-07 red:
        // 10 745 → 8 080 with no rows change at all). The floor keeps the
        // clip where it is until the next projection, which then moves it by
        // the anchor's own delta -- and by then the real bottom is under it
        // again, so no empty page is reachable.
        let live = scrollView.contentView.bounds.origin.y
        let height = max(documentHeight, live + clipHeight)
        if abs(document.frame.width - width) > 0.5
            || abs(document.frame.height - height) > 0.5 {
            document.frame = NSRect(x: 0, y: 0, width: width, height: height)
            // **This exact moment is the one a clamp may be read as a hand**:
            // the frame just changed value, AppKit answers by moving the clip,
            // and that callback is the view's doing. Saying so here -- and
            // only here -- is what keeps "the content got taller" (which also
            // changes the number) from being treated the same way.
            onGeometry?()
        }
        if abs(hostClip.frame.width - width) > 0.5 {
            hostClip.frame.size.width = width
        }
        if abs(hostClip.frame.height - clipHeight) > 0.5 {
            hostClip.frame.size.height = clipHeight
        }
        if let host, abs(host.frame.width - width) > 0.5
            || abs(host.frame.height - clipHeight) > 0.5 {
            host.frame.size = NSSize(width: width, height: clipHeight)
        }
        // **The first frame is the bottom** (design §14): before anything is
        // drawn, put the clip where the page opens. One positioning, not a
        // rule; the camera owns every later one.
        if !positioned, clipHeight > 1, height > clipHeight + 1 {
            positioned = true
            if let start = pendingStart {
                pendingStart = nil
                scroll(to: start)
            }
        }
    }

    private func syncRoot(origin: CGFloat) {
        guard let host else { return }
        // The clip's own origin is the only number the offset may be built
        // from: a value from the SwiftUI state a body pass ago would be the
        // document coordinate the content had before the scroll.
        let live = scrollView.contentView.bounds.origin.y
        hostClip.frame.origin = NSPoint(x: 0, y: live)
        // **Only the part of the window above the viewport is hidden**, and
        // that is a small number of points (the window is trimmed around the
        // viewport): the content is laid out inside the hosting view's own
        // frame, never a history's length above it.
        let offset = max(0, live - base)
        guard live != renderedOrigin || base != renderedBase else { return }
        renderedOrigin = live
        renderedBase = base
        host.rootView = AnyView(ControlRoomChatSurfaceRoot(
            base: base,
            offset: offset,
            viewport: viewport,
            space: space,
            content: content,
            onFrames: { [weak self] value in
                self?.onFrames?(value)
            }
        ))
    }

    private func clipMoved() {
        syncRoot(origin: origin)
    }

    /// One programmatic scroll. The clip is the document's own y, so this is
    /// the same act as a wheel event and the view's callback it causes is
    /// recognised by the expectations `ControlRoomChatScrollHandle` keeps.
    func scroll(to y: CGFloat) {
        let maximum = max(0, document.frame.height - scrollView.contentSize.height)
        let target = min(max(0, y), maximum)
        guard abs(target - scrollView.contentView.bounds.origin.y) > 0.5 else {
            return
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        syncRoot(origin: target)
    }
}

/// The hosted tree's root: the window, its coordinate space, and the frames
/// preference.
///
/// ⚠️ **A hosted view is a separate SwiftUI tree and preferences do not
/// cross the host boundary** -- `RowFramesPreference` arrives here and
/// nowhere else, so the read must sit in this root and be handed back out.
struct ControlRoomChatSurfaceRoot: View {
    /// The document's y of the content's first row.
    var base: CGFloat
    /// How far into the window the viewport's top edge is, in points. **A
    /// row's height at most** (the window is built around the viewport):
    /// larger than that the hosting view would be asked to draw what it does
    /// not contain, and the clip would take it away.
    var offset: CGFloat
    /// The visible height: the window is pinned to a frame this tall at the
    /// top, so its layout origin cannot be anywhere else.
    var viewport: CGFloat
    var space: String
    var content: AnyView
    var onFrames: ([String: CGRect]) -> Void

    var body: some View {
        content
            // **Inside the hosting view's own frame**: the rows are laid out
            // from 0, so the window the frame contains is the window that is
            // drawn. A top padding the length of the history is layout the
            // frame does not contain, and it is clipped away entirely (the
            // 2026-11-07 real-machine red: forty rows rendered, none seen).
            // **The window keeps its own height**: a fixed-height frame
            // would otherwise compress the rows to fit the viewport (a
            // `Text` given less height truncates), and the rows on screen
            // would be the right ones drawn wrong.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // **A root taller than the hosting view is not a viewport any
            // more**: without this the window (taller than one screen) would
            // be placed by the host's own rule for oversized content, and the
            // rows would start somewhere this view did not choose.
            .frame(height: max(0, viewport), alignment: .top)
            .coordinateSpace(name: space)
            .onPreferenceChange(RowFramesPreference.self) { value in
                guard base != 0 else {
                    onFrames(value)
                    return
                }
                // **The rows report the window's coordinates; every reader of
                // `frames` speaks the document's.** One shift, here.
                var shifted: [String: CGRect] = [:]
                shifted.reserveCapacity(value.count)
                for (id, rect) in value {
                    shifted[id] = rect.offsetBy(dx: 0, dy: base)
                }
                onFrames(shifted)
            }
            // **Outside the coordinate space**: a row's frame is then its
            // layout position, not the position after the scroll.
            .offset(y: -offset)
    }
}
