import AppKit
import OSLog
import SwiftUI

/// The group chat's messages, drawn natively (task 2791, #2791; the demand
/// and Markdown wiring, task 2800 C2b-1; history, header and reading state,
/// task 2969 B; the anchor model, task 3016's second slice).
///
/// **A view and nothing else.** It is handed the feed it draws and asks
/// nobody for anything: where a batch comes from, which group it is about,
/// and when to ask again are the feed's. That is deliberate -- a view that
/// also fetched would be untestable without a core, and "it drew nothing"
/// and "the request failed" would look the same.
///
/// ⚠️ **Instantiated is not the same as resident.** Five hundred messages
/// may be in the feed's window while only the rows SwiftUI actually makes
/// are on screen; those rows announce themselves (`onAppear`/`onDisappear`)
/// and only they ask the Markdown store for a parse. An empty live answer
/// that changes nothing therefore never turns a drawn row back into text.
///
/// **The truth is the row at the viewport's top edge and how far into it**
/// (task 3016, the anchor model): `camera.place` names it, `camera.pinned`
/// says whether the viewport follows the newest row. **The clip origin is a
/// projection of that, never a second copy**: a hand writes the anchor
/// (`scrolled`), and every layout change -- a page in, a row measured, a
/// width change -- puts the clip back where the anchor says it belongs
/// (`syncClip`). There is no compensation: a row going in above the viewport
/// does not move the pixels the anchor names, so what moves is the anchor's
/// document y and the clip with it, in the same pass. **New messages follow
/// while `pinned`**; away from the bottom they raise the "jump to latest"
/// pill instead.
struct ControlRoomNativeChatView: View {
    typealias Look = ControlRoomLook

    @ObservedObject var feed: ControlRoomChatFeed
    /// The search hit the window was located to, when a search result was
    /// picked. Its offsets are what marks the matched text inside the
    /// message (`ControlRoomChatDisplayHighlight`), not just the row.
    var locatedHit: ControlRoomChatSearch.Hit?
    var onReference: ((ControlRoomChatData.Message, String?) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    @StateObject private var scroll = ControlRoomChatScrollHandle()
    @State private var frames: [String: CGRect] = [:]
    /// **Every row height the window has measured, kept across windows**
    /// (design §16). `frames` is the window's map -- it is replaced whenever
    /// the window moves -- while this is the document's: a row that has been
    /// laid out once is never estimated again, so scrolling does not re-drive
    /// the same estimates and the anchor's document y stops drifting. A width
    /// change makes every height stale and clears it.
    @State private var heights: [String: CGFloat] = [:]
    /// **The truth about where the reader is** (task 3016):
    /// `ControlRoomChatCamera.State` holds the place, whether the viewport is
    /// pinned to the bottom, and the projection still owed. Nothing else in
    /// this view is allowed to be a second copy of that truth.
    @State private var camera = ControlRoomChatCamera.State()
    @State private var lastIDs: [String] = []
    /// The pixels, projected from the camera (or the bottom) on every change
    /// and never read as the truth. The index bar reads the same numbers.
    @State private var offsetY: CGFloat = 0
    /// **The y the view itself asked the clip to go to, and when**: the
    /// callback it causes is the view's, not a hand's, even when a wheel is
    /// inside its 0.3 s window (the 2026-11-07 red: the auto-scroll raised
    /// the wheel signal every 30 ms, so every projection's own callback was
    /// read as a scroll and wrote the bottom into the anchor).
    /// **The clip's y that the anchor was last reconciled with.**
    ///
    /// Every move is a **difference against this**, never an absolute read of
    /// the clip: the clip's y is only meaningful against the ruler that wrote
    /// it, and a page measured in re-scales the whole document under it. Read
    /// absolutely, the same y becomes a row a screen and a half away -- the
    /// 2026-11-07 red: one 40 pt step moved the anchor 45 rows, and the page
    /// left the bottom by itself. `nil` means "no reference": the next move
    /// is absolute (a jump, a rebase, a page's first projection).
    @State private var clipSeen: Double?
    /// **The ruler `clipSeen` belongs to.** The clip's y is a pixel in a
    /// document whose row heights change when a page is measured; a delta
    /// across two rulers is not the reader's movement. When the epoch has
    /// moved since `clipSeen`, this tick is not used for the anchor at all --
    /// the reference is re-baselined and the next tick is clean.
    @State private var clipSeenRuler: UInt64 = 0
    /// Bumped whenever the row heights (measured or estimated) or the plan
    /// change under the clip.
    @State private var rulerEpoch: UInt64 = 0
    /// The last movement a reader's callback produced, for the logs.
    @State private var lastAnchorDelta: Double = 0
    /// **Which branch the reader's last callback took.** Instrumentation for
    /// the pull-back red: a tick that wrote no anchor is what lets `syncClip`
    /// undo it, and this field names it in one reading.
    @State private var lastReaderBranch = "-"
    /// The reference the last `syncClip` compared against, for its log line.
    @State private var lastSyncSeen: Double?
    /// The last `content:` line, so it is written once per change.
    @State private var lastRulerLine = ""
    /// The last `bottoms:` line written, so it is one per change (the reading
    /// is a comparison of four heights, not a per-frame trace).
    @State private var lastBottomsLine = ""
    /// The last `contentHeight` written, for the `ruler:` line: only a jump
    /// worth explaining is printed (the 2026-11-07 entry run: 11414 -> 14742
    /// in one pass, and back).
    @State private var lastRulerHeight: Double = 0
    /// **The estimate is taken once and then never changes** (the 2026-11-07
    /// entry run, `ruler:`: `measured=27 estimated=166 estimate=64` and then
    /// `estimate=46` with nothing else different -- 166 rows x 18 = 2988 of
    /// the 3328 pt jump the person sees).
    ///
    /// `measuredRowHeight` is a **median over the rows drawn right now**, and
    /// the sample is bimodal: 46 for a settled row, 64 for one still showing
    /// its "formatting" line. Every conversion moves the median between those
    /// two modes, and every unmeasured row in the document is multiplied by
    /// it. **The two families are not two kinds of message** -- they are the
    /// same rows in two forms, which is why splitting the estimate by shape
    /// cannot help here, and a mean would still move with the sample and would
    /// be pulled up by the tall rows. So: the first sample big enough to mean
    /// anything is the answer, and after that the number stops.
    @State private var rowHeightEstimateSettled = false
    /// **How many passes the publisher has run**, so a sample that never
    /// settles (a page still streaming in) still freezes eventually.
    @State private var rowHeightEstimatePasses = 0
    /// The debug injector is armed once per surface (`CHAT_INJECT_*`).
    @State private var debugInjectionArmed = false
    /// The debug jump is armed once per surface (`CHAT_JUMP_*`).
    @State private var debugJumpArmed = false
    /// **The bar's high-water mark, in points** (design §23.3): the deepest
    /// the reader has ever been, measured from the newest message. **Only ever
    /// grows** -- reaching 100 keeps 100, and coming back to the newest does
    /// not shrink it. Reset when the map is replaced (a different group is a
    /// different document).
    @State private var barReached: Double = 0
    /// **The first valid reading is taken as it is**, not `max`ed against a
    /// zero: `max(0, depth)` publishes whatever the very first frame
    /// computed, and the first frame's document is not the one that settles
    /// (the 2026-11-08 entry: `totalP` 11574 and then 1008, one bar that
    /// jumped backwards as soon as it appeared).
    @State private var barReachedSeeded = false
    /// **A landing screen is showing placeholders** (design §26). Set only by
    /// `jump(to:)` -- a scroll never sets it, which is what keeps the
    /// placeholders off the scrolling path; cleared the moment the screen's
    /// rows are all settled, or by the cap.
    @State private var placeholdersOn = false
    /// Invalidates the cap queued for an earlier landing.
    @State private var placeholderToken: UInt64 = 0
    /// How many drawn rows make an estimate worth freezing.
    private static let estimateFreezeSample = 10
    /// The cap: after this many passes the estimate freezes whatever it is.
    private static let estimateFreezePasses = 60
    /// **The document's frame was set by this view, this tick.** Not "the
    /// content's height differs from last time" -- that is true on every tick
    /// a page grows in, and gating on it swallowed six reader steps in a row
    /// when a group opened (the 2026-11-07 red: 240 pt of wheel, no movement
    /// at all). Set by the surface at the moment it assigns the frame, cleared
    /// by the first callback that reads it.
    @State private var geometryJustChanged = false
    @State private var viewportH: CGFloat = 0
    @State private var contentH: CGFloat = 0
    @State private var newBelow = false
    /// Bumped when the map is replaced rather than extended. The index bar
    /// reads it to abandon a drag that was aimed at the old map.
    @State private var mapEpoch: UInt64 = 0
    /// **How many times a continuous gesture has reached the loaded top with
    /// earlier history still available** (the criterion-2 instrument). Logged
    /// only on entering that state, not on every callback.
    @State private var topHits = 0
    @State private var atLoadedTop = false
    /// The probe has found the scroll view and is listening to its clip view.
    @State private var handleAttached = false
    @State private var visible = false
    /// Invalidates the quiet checks queued by earlier wheel events.
    @State private var quietToken: UInt64 = 0
    /// How many `bounds:` lines have been written, and the last judgement --
    /// **the first twenty are always written** (the red is in the first few
    /// callbacks of a page), after that only when the judgement changes.
    @State private var boundsLines = 0
    @State private var lastBoundsSeen = ""
    /// **A decision and the reader's own movement must not disagree.** The
    /// 2026-11-06 red walked a reader towards the oldest while they scrolled
    /// towards the newest, and nothing said so. Consecutive ticks that take
    /// older rows in while the actual offset grows are counted; once the run
    /// reaches `disagreeTicksBeforeSaying` it is logged with both numbers.
    @State private var lastReadOffset: Double = 0
    @State private var disagreeRun = 0
    private static let disagreeTicksBeforeSaying = 3
    /// **A locate's landing is driven by the rows, not by `locateEpoch`
    /// alone** (R2-1): the epoch moves when the request starts, before the
    /// target's around window exists, so the rows change is the second half.
    /// The key is the locate, not the anchor: picking the same result again
    /// must land again.
    @State private var landedLocate: String?
    /// A located window's way out is a change of map first (R1-8).
    @State private var pendingReturnToLatest = false
    /// The located mark's own opacity: 1 is the steady highlight. Breathed
    /// twice when a locate arrives, and then left alone (task 2999 ④).
    /// **Opacity only**: the mark is drawn behind and beside the row, never
    /// laid out, so the breathing cannot move the list.
    @State private var locatedGlow: Double = 1
    /// Which breathing is playing, so a step queued for an older locate
    /// cannot move a newer mark.
    @State private var glowToken: UInt64 = 0
    /// The locate whose mark has already breathed: **the locate, not the
    /// anchor's name**. `locate()` bumps the feed's generation for every
    /// attempt, so picking the same result again is a new key and plays
    /// again, while the around answer (which publishes the same anchor a
    /// moment later) is the same one.
    @State private var breathedLocate: String?
    /// **How many rows the window has instantiated right now** (the 1a
    /// criterion): the rows' own `onAppear`/`onDisappear` tally, not a count
    /// computed from the plan.
    @State private var renderedRows = 0
    /// **The debug self-scroll** (`CHAT_AUTO_SCROLL`), nil unless the
    /// environment asked for it. A test instance cannot drive the list with a
    /// synthetic wheel in some environments (the 2026-11-07 real-machine red:
    /// `CGEventPost`, page keys and the AX scroll action all reached nothing),
    /// so the app has to be able to scroll itself.
    @State private var auto: ControlRoomChatAutoScroll?

    /// The coordinate space the rows report their frames in. **The surface's
    /// hosted tree names it** (`ControlRoomChatSurfaceRoot`); the rows here
    /// read it.
    static let space = "poltergeist.chat.rows"
    /// **A camera with no row is said out loud** (R1-4): "I do not know yet"
    /// and "I know it is gone" must not look the same in a log either.
    private static let cameraLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-camera"
    )
    /// **The criterion-2 instrument** (task 3016): one line when a gesture
    /// reaches the loaded top with earlier history still out. A reading is
    /// counted from these lines, not judged by eye.
    private static let flowLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-flow"
    )
    /// **The window's own instrument**: a decision that takes older rows in
    /// while the reader moves towards the newest, said out loud with both
    /// numbers (the 2026-11-06 red's canary).
    private static let windowLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-window"
    )
    /// **The index bar's own trace** (the person's debugging aid, 2026-11-06):
    /// one line per *change* of what the bar draws, so a reading beside
    /// `chat-window` can tell "the bar is moving" from "the feed's rows are".
    private static let barLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-bar"
    )
    /// **The window's own instrument** (task 3016 1a): one line per change of
    /// what the surface draws -- how many rows this frame instantiated, the
    /// first and the last of them, the document's height and the viewport's
    /// place. A reading is counted from these lines, not judged by eye.
    private static let surfaceLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-surface"
    )
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var body: some View {
        let theme = Look.theme(scheme)
        let plan = listPlan
        let indexByID = rowIndexByID
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { geometry in
                let viewport = max(0, geometry.size.height)
                let layout = scrollLayout(plan)
                let documentHeight = documentBottom(plan: plan, layout: layout)
                let origin = windowOrigin(
                    plan: plan,
                    layout: layout,
                    documentHeight: documentHeight,
                    viewport: viewport
                )
                let window = layout.window(at: origin, viewport: viewport)
                surface(
                    theme: theme,
                    plan: plan,
                    layout: layout,
                    documentHeight: documentHeight,
                    window: window,
                    viewport: viewport
                )
                .onChange(of: geometry.size.width) { _ in
                    // **R1-12: the frames are the old width's.** A projection
                    // against them would scroll to a wrong place and the arriving
                    // frames would scroll a second time -- two visible movements.
                    // Clear them; the new frames are what the projection waits
                    // for. **They are also what the window's heights are keyed
                    // by** (design §16): a width change makes every measured
                    // height stale, so none of them may survive it.
                    frames = [:]
                    heights = [:]
                    rulerEpoch &+= 1
                    syncClip("width")
                }
                // **One line per change of what the window draws** (the
                // criterion's instrument): how many rows this frame instantiated,
                // the first and last of them, the document's height and where the
                // viewport is. `rendered` is the rows' own `onAppear`/`onDisappear`
                // tally, not a count computed here.
                .onChange(of: windowAnchors(plan: plan, layout: layout, window: window)) { _ in
                    // The window must contain the anchor; if it does not, the
                    // projection that follows will read the clip against the
                    // wrong rows. One line per change, and silence is the
                    // healthy state.
                    guard let place = camera.place,
                          let index = plan.firstIndex(where: {
                              $0.id == Self.planID(place.id)
                          }),
                          !window.contains(index)
                    else { return }
                    Self.windowLog.notice(
                        "window: anchor-out id=\(place.id, privacy: .public) anchor=\(index, privacy: .public) window=\(window.lowerBound, privacy: .public)..\(window.upperBound, privacy: .public) offset=\(Int(self.offsetY), privacy: .public) origin=\(Int(origin), privacy: .public)"
                    )
                }
                .onChange(of: viewportSignature(
                    rows: feed.rows.count,
                    layout: layout,
                    documentHeight: documentHeight,
                    window: window,
                    origin: origin
                )) { _ in
                    sayViewport(
                        rows: feed.rows.count,
                        layout: layout,
                        documentHeight: documentHeight,
                        window: window,
                        origin: origin
                    )
                }
                // **A document that has just been measured taller is a new
                // bottom**, and a pinned page follows it: the pin's target is
                // `content − viewport` and that number has just moved. Async,
                // because the surface applies the new document height in this
                // same update and the clamp needs it.
                .onChange(of: documentHeight) { _ in
                    guard camera.pinned else { return }
                    DispatchQueue.main.async { syncClip("document") }
                }
                .overlay(alignment: .trailing) {
                    // **The test instance's own switch** (the person's
                    // debugging aid): the bar is hidden so a scroll reading is
                    // about the list, not the bar.
                    if ProcessInfo.processInfo.environment["CHAT_NO_INDEX_BAR"] == nil {
                        indexBar(theme, height: geometry.size.height)
                    }
                }
            }
            // **A located window keeps its own way out.** Its bottom is the
            // end of the around window, not the newest message, so the pill
            // has to return the page to the live tail. The condition is the
            // located state, not `atBottom`: reading the middle of a located
            // window leaves `atBottom` false too, and the two mean different
            // things.
            if isLocated || !atBottom {
                jumpPill(theme)
            }
        }
        .onAppear {
            visible = true
            startAutoScrollIfAsked()
            lastIDs = feed.rows.map(\.id)
            // **A page always opens on the newest message** (task 3002, the
            // person's ruling of 2026-11-06). The list is a fixed-height
            // frame over a stream, not a document with a remembered bookmark.
            // **It is one word now** (task 3016): `pinned` is the truth, and
            // there is no landing action that could fail and be lost.
            camera = ControlRoomChatCamera.State(place: nil, pinned: true)
            clipSeen = nil
            newBelow = false
            pendingReturnToLatest = false
            landedLocate = nil
            syncClip("appear")
            // A page that opens already located: the mark may breathe once
            // the row is measured and under the viewport, which is what the
            // frames preference and the bounds callbacks ask below.
            breatheLocatedIfInView()
        }
        .onDisappear {
            visible = false
            auto?.cancelled = true
            // **Every queued ticket belongs to the page that left** (A2 S2):
            // a quiet check or an owed projection arranged before the page
            // went away must not run on it, nor on the page that replaces it.
            quietToken &+= 1
        }
        // **A locate has two moments** (R2-1). `locateEpoch` moves when the
        // request starts, before the target's around window exists; the rows
        // change that lands the window is the second. `jumpToLocate` is keyed
        // on both so a repeated pick of the same result lands again and a
        // context page appended afterwards does not pull the reader back.
        .onChange(of: feed.locateEpoch) { _ in
            jumpToLocate(feed.locatedAnchor)
        }
        .onChange(of: feed.rows) { rows in
            // **Rows changing is not the reader moving.** The anchor keeps
            // the row it names; if that row is gone it says so and picks the
            // nearest one; either way the clip is put back where the anchor
            // says it belongs -- which is what makes an insertion above the
            // viewport a non-event for the person looking at it.
            rulerEpoch &+= 1
            let change = rowsChanged(rows)
            // **A locate is a deliberate change of map, not a lost anchor**
            // (review E, MF4): the target is written by `jumpToLocate` before
            // anything may call the anchor lost, or every locate would say
            // `anchor: lost` and do an extra read on its way to the right
            // row.
            jumpToLocate(feed.locatedAnchor)
            rebaseAnchor("\(change)")
            syncClip("rows")
        }
        // **A page landing in an apron is a reason to look again** (review C,
        // M6): a reader parked at the loaded edge cannot produce a scroll
        // callback, and without this the page would sit in the apron until
        // they moved. Async, because this fires inside a view update and the
        // step changes `rows`.
        .onChange(of: feed.aboveCount) { _ in
            DispatchQueue.main.async { maintainWindow(fromInput: false) }
        }
        .onChange(of: feed.belowCount) { _ in
            DispatchQueue.main.async { maintainWindow(fromInput: false) }
        }
        // **A viewport that has just become real** (0 → positive, or a new
        // size) projects the camera again: the bottom target depends on it.
        .onChange(of: viewportH) { height in
            guard height > 0 else { return }
            syncClip("viewport")
            publishViewportRows()
            // **A size that has just become real is a new unit** (review C,
            // M5): the margin is in screens, and every threshold moved.
            // Async, because this runs inside a view update and the step
            // changes `rows`.
            DispatchQueue.main.async { maintainWindow(fromInput: false) }
        }
    }

    /// **The rows' frames, measured inside the hosted window.** The preference
    /// is read by the container's root (`ControlRoomChatSurfaceRoot`) because
    /// **a hosted view is a separate SwiftUI tree and preferences do not
    /// cross the host boundary**; this is the same answer handed back out.
    ///
    /// The frames are in **document coordinates**: the content's top padding
    /// puts the window's first row where the document has it.
    private func framesArrived(_ value: [String: CGRect]) {
        guard value != frames else { return }
        frames = value
        let estimateBefore = feed.rowHeightEstimate
        var measuredChanged = false
        var changed: [(String, Double, Double)] = []
        for (id, frame) in value where frame.height > 1 {
            if let old = heights[id], abs(old - Double(frame.height)) > 0.5 {
                measuredChanged = true
                changed.append((id, old, Double(frame.height)))
            } else if heights[id] == nil {
                measuredChanged = true
                changed.append((id, -1, Double(frame.height)))
            }
            heights[id] = Double(frame.height)
        }
        publishRowHeightEstimate(order: feed.rows.map(\.id))
        if measuredChanged || abs(estimateBefore - feed.rowHeightEstimate) > 0.5 {
            rulerEpoch &+= 1
        }
        // **Is the ruler itself shaking?** (the 2026-11-07 stuck red: the same
        // anchor's absolute projection moved back and forth between frames, with
        // the document height unchanged -- so a row's height above the anchor
        // was being re-measured to different values). One line per frame that
        // changed a height, naming up to eight rows; the counts are the reading.
        let rowsNow = listPlan
        let layoutNow = scrollLayout(rowsNow)
        if !changed.isEmpty {
            // **Where each changed height sits** (task 3016, the 2026-11-07
            // flutter): a height that changed is only something the person
            // sees if the row is on screen. `at` is the row's plan index minus
            // the anchor's -- negative is above the anchor, where a change
            // moves the whole picture below it -- and `in` says whether the
            // row is inside the window the surface draws. A run of changes
            // that are all `in=0` means the flutter is not this, and no
            // layout change is owed.
            let documentNow = documentBottom(plan: rowsNow, layout: layoutNow)
            let originNow = windowOrigin(
                plan: rowsNow,
                layout: layoutNow,
                documentHeight: documentNow,
                viewport: viewportH
            )
            let windowNow = layoutNow.window(at: originNow, viewport: viewportH)
            let visibleNow = layoutNow.visibleRows(at: originNow, viewport: viewportH)
            let anchorIndex = camera.place.flatMap { place in
                rowsNow.firstIndex(where: { $0.id == Self.planID(place.id) })
            }
            let sample = changed.prefix(8).map { entry -> String in
                let line = "\(entry.0):\(Int(entry.1))->\(Int(entry.2))"
                guard let index = rowsNow.firstIndex(where: {
                    $0.id == Self.planID(entry.0)
                }) else {
                    return "\(line) at=? in=?"
                }
                let placement = ControlRoomChatScrollSurface.Placement.of(
                    index: index,
                    anchor: anchorIndex,
                    window: windowNow,
                    visible: visibleNow
                )
                let at = placement.at.map { String($0) } ?? "?"
                let inside = placement.inside ? 1 : 0
                let onScreen = placement.onScreen ? 1 : 0
                return "\(line) at=\(at) in=\(inside) on=\(onScreen)"
            }.joined(separator: " ")
            Self.windowLog.notice(
                "heights: changed=\(changed.count, privacy: .public) \(sample, privacy: .public) frames=\(value.count, privacy: .public) rows=\(self.feed.rows.count, privacy: .public) est=\(Int(self.feed.rowHeightEstimate), privacy: .public)"
            )
        }
        if abs(estimateBefore - feed.rowHeightEstimate) > 0.5 {
            Self.windowLog.notice(
                "est: \(Int(estimateBefore), privacy: .public) -> \(Int(self.feed.rowHeightEstimate), privacy: .public) measured=\(self.frames.count, privacy: .public) rows=\(self.feed.rows.count, privacy: .public)"
            )
        }
        // **The two "content heights" side by side**, once per change: the
        // anchor is placed by `layout.contentHeight`'s ruler, while the pin and
        // the log read `documentBottom`; if one shakes and the other does not,
        // that is where a same-anchor move comes from.
        let contentLine = "est=\(Int(layoutNow.contentHeight)) doc=\(Int(documentBottom(plan: rowsNow, layout: layoutNow))) rows=\(rowsNow.count)"
        if contentLine != lastRulerLine {
            lastRulerLine = contentLine
            Self.windowLog.notice("content: \(contentLine, privacy: .public)")
        }
        // **The four heights that are supposed to be one number** (design
        // §24, the 2026-11-07 entry jump): the bottom this view computes
        // (`doc`), the ruler's total (`contentH`), the height the surface's
        // scroll document really has (`surfaceDoc`), and the last message's
        // own drawn bottom (`lastY`). `pad` is the bottom padding between
        // `lastY` and the end of the document.
        //
        // **Steady state is all four agreeing.** While the page is still
        // measuring they may differ; the line says which one arrives first
        // and by how much -- the reading that decides who may win, instead of
        // taking the ruler away and finding out.
        let lastY = lastMessageBottom(rowsNow)
        let surfaceDoc = scroll.documentHeight.map { Int($0) } ?? -1
        let bottoms = "doc=\(Int(documentBottom(plan: rowsNow, layout: layoutNow))) contentH=\(Int(layoutNow.contentHeight)) surfaceDoc=\(surfaceDoc) lastY=\(Int(lastY)) pad=\(Int(ControlRoomChatScrollSurface.bottomPadding))"
        if bottoms != lastBottomsLine {
            lastBottomsLine = bottoms
            Self.windowLog.notice("bottoms: \(bottoms, privacy: .public)")
        }
        // **A jump in the ruler, and what it was made of** (the 2026-11-07
        // entry run: `contentH` went 11414 -> 14742 -> 11388, two families
        // ~3300 apart). `measured` and `estimated` are the two halves
        // `scrollLayout` fills: a row with a usable `heights[id]` and a row
        // with the feed's single estimate. Which of them moved says whether a
        // row changed height or the ruler changed its mind about all the rest.
        let contentNow = Double(layoutNow.contentHeight)
        if lastRulerHeight > 0, abs(contentNow - lastRulerHeight) > 500 {
            let measuredRows = layoutNow.measured.filter { $0 }.count
            let estimatedRows = layoutNow.measured.filter { !$0 }.count
            Self.windowLog.notice(
                "ruler: from=\(Int(self.lastRulerHeight), privacy: .public) to=\(Int(contentNow), privacy: .public) measured=\(measuredRows, privacy: .public) estimated=\(estimatedRows, privacy: .public) heights=\(self.heights.count, privacy: .public) frames=\(self.frames.count, privacy: .public) estimate=\(Int(self.feed.rowHeightEstimate), privacy: .public)"
            )
        }
        lastRulerHeight = contentNow
        // **A measured row moves the document under the anchor**: rows above
        // the viewport that were estimated are now exact, so the anchor's own
        // y has moved by the difference. The clip is put back there -- the
        // picture does not move because the number that names it did.
        syncClip("frames")
        // The located row may have just been measured: that is one of the
        // two moments its mark may breathe (task 2999 ④).
        breatheLocatedIfInView()
        publishViewportRows()
        endPlaceholdersIfSettled()
    }

    // MARK: - Rows and frames

    private func rowFrames(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RowFramesPreference.self,
                value: [id: proxy.frame(in: .named(Self.space))]
            )
        }
    }

    private func needsDivider(_ index: Int) -> Bool {
        let previous = index > 0 ? feed.rows[index - 1].message.atMs : nil
        guard index < feed.rows.count else { return false }
        return ControlRoomChatPresentation.needsDayDivider(
            previous: previous,
            current: feed.rows[index].message.atMs
        )
    }

    /// Who a row is from, in the shape the rule compares (task 2999 ①).
    private func speaker(_ index: Int) -> ControlRoomChatPresentation.Speaker {
        let message = feed.rows[index].message
        return ControlRoomChatPresentation.Speaker(
            author: ControlRoomChatPresentation.authorText(
                author: message.author, fromSelf: message.fromSelf),
            role: message.role,
            channel: message.channel,
            summary: message.summary
        )
    }

    /// Whether the speaker above this row is not the speaker of this row.
    private func needsSpeakerRule(_ index: Int) -> Bool {
        guard index > 0, index < feed.rows.count else { return false }
        return ControlRoomChatPresentation.needsSpeakerRule(
            previous: speaker(index - 1),
            current: speaker(index)
        )
    }

    /// A hairline across the row's width where the speaker changes, with
    /// more air above it than two messages from one speaker have between
    /// them. Same hairline as the day divider and the boundaries.
    private func speakerRule(_ theme: Look.Theme) -> some View {
        line(theme)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }

    /// The real list: messages and the released runs, decided once so the
    /// view cannot draw two rows next to each other that were not neighbours.
    private var listPlan: [ControlRoomChatPresentation.ListRow] {
        ControlRoomChatPresentation.listRows(
            order: feed.rows.map(\.id),
            // **A released run is only drawn where the window ends.**
            trimmedBefore: feed.trimmedBeforeAtEdge,
            trimmedAfter: feed.trimmedAfterAtEdge,
            atStart: feed.reachedBeginning,
            // **The end mark is not drawn while following** (review C, M7):
            // a pinned list that ends on "this is the end" puts a mark under
            // the last message that the person reads as something below it.
            // **Both end marks are drawn, following or not** (the person's
            // own words: "滚到顶写一条到头了，向下也是，提示到底了"). The
            // earlier rule hid the newest mark while the page followed the
            // newest row, on the theory that a mark under the last message
            // reads as something below it; that is a matter of taste and the
            // person has now said which one they want.
            atEnd: feed.reachedEnd
        )
    }

    private var rowIndexByID: [String: Int] {
        var index: [String: Int] = [:]
        index.reserveCapacity(feed.rows.count)
        for (offset, row) in feed.rows.enumerated() {
            index[row.id] = offset
        }
        return index
    }

    // MARK: - The window's surface (task 3016, design v2)

    /// **The document's geometry, from the heights the view knows**: the rows
    /// it has measured (`frames`, keyed by message id) and the feed's own
    /// estimate for the rest.
    ///
    /// A boundary mark (the two ends, a released run) is not a message and no
    /// measurement covers it, so it keeps its own short height.
    private func scrollLayout(
        _ plan: [ControlRoomChatPresentation.ListRow]
    ) -> ControlRoomChatScrollSurface.Layout {
        let estimate = max(1, feed.rowHeightEstimate)
        var measured = [CGFloat]()
        var known = [Bool]()
        measured.reserveCapacity(plan.count)
        known.reserveCapacity(plan.count)
        for item in plan {
            switch item {
            case let .message(id):
                if let height = heights[id], height > 1 {
                    measured.append(height)
                    known.append(true)
                } else {
                    measured.append(estimate)
                    known.append(false)
                }
            case .start, .end, .gap:
                measured.append(ControlRoomChatScrollSurface.boundaryHeight)
                known.append(false)
            }
        }
        return ControlRoomChatScrollSurface.Layout(
            ids: plan.map(\.id), heights: measured, measured: known
        )
    }

    /// **Where the window starts.** Following the newest row means the
    /// document's end, whether or not a callback has said so yet (design
    /// §14): the first frame is then the last rows, never the top of the
    /// history.
    ///
    /// **Reading history means the clip origin**, which is the only place
    /// the reader's own movement is written; the camera's projection is not
    /// an input here any more than it is to the window's decisions.
    private func windowOrigin(
        plan: [ControlRoomChatPresentation.ListRow],
        layout: ControlRoomChatScrollSurface.Layout,
        documentHeight: CGFloat,
        viewport: CGFloat
    ) -> CGFloat {
        if camera.pinned { return max(0, documentHeight - viewport) }
        // **The window is placed by the anchor's y in *this* ruler, never by
        // `offsetY`.** The clip's y was written by the previous layout; after
        // a page is measured in the two are different numbers, and a window
        // asked for at the old y covered rows the viewport is not looking at
        // (the 2026-11-07 red: window 941…980 while the viewport's top was
        // p:995, and the anchor then fell out of the window entirely).
        //
        // **The invariant this keeps**: `index(at: origin) <= anchor index`,
        // and the window always contains the anchor and the viewport.
        if let place = camera.place,
           let index = plan.firstIndex(where: { $0.id == Self.planID(place.id) }) {
            // **The ruler, not the row's frame -- and this is a rule, not a
            // preference** (the 2026-11-07 deadlock: the auto-scroll stopped
            // at step 10 with `from=9763 to=9549 delta=-214` repeating
            // forever). This function's answer decides **which rows are
            // drawn**; `frames` is what comes back from drawing them. Reading
            // the frame here closes the loop
            //
            //     windowOrigin → rowTop → frames → drawn rows → windowOrigin
            //
            // and because `rowTop` answers from the ruler for a row with no
            // frame, the loop sits on a two-valued branch: the anchor's row
            // has a frame in one window and not in the other, `anchorY` moves
            // 214 pt, the window moves with it, and both states are stable
            // enough to repeat. The `margin=9680` the window spends makes the
            // cost of the ruler's one-line error **zero**; the cost of the
            // loop is the whole feature.
            //
            // **A function whose answer becomes its own next input must not
            // read what that input produces.**
            let y = Double(layout.top(of: index)) + place.offset
            return min(max(0, CGFloat(y)), max(0, documentHeight - viewport))
        }
        return max(0, CGFloat(offsetY))
    }

    /// **The document's bottom, from the rows themselves once they have been
    /// laid out** (the 2026-11-07 real-machine red: pinned with
    /// `offset + viewport == docH`, the newest row in the window and off the
    /// screen).
    ///
    /// `Layout` can only estimate: its heights are the messages' own frames,
    /// and **a message's frame does not include the day divider or the
    /// speaker's rule drawn above it**. Inside the window those are real
    /// points, so the estimate runs short by every one of them and the last
    /// rows fall below the viewport exactly when the reader is at the newest
    /// end. The last message's measured bottom is the document's, and it
    /// arrives one frames pass after the window first draws it.
    ///
    /// The plan's last item is the end mark only when the list is not
    /// following the newest row, and then the mark's own height stands in.
    /// **The last message's own drawn bottom**, or `-1` when that row has no
    /// usable frame. Reading only: it is what §24.3 would use, printed beside
    /// the ruler so the two can be compared before either is allowed to
    /// decide.
    private func lastMessageBottom(
        _ plan: [ControlRoomChatPresentation.ListRow]
    ) -> CGFloat {
        guard let index = plan.lastIndex(where: {
            if case .message = $0 { return true }
            return false
        }), case let .message(id) = plan[index],
            let frame = frames[id],
            frame.height > ControlRoomChatScrollSurface.anchorFrameMinimumHeight
        else { return -1 }
        return Double(frame.maxY)
    }

    private func documentBottom(
        plan: [ControlRoomChatPresentation.ListRow],
        layout: ControlRoomChatScrollSurface.Layout
    ) -> CGFloat {
        let padding = ControlRoomChatScrollSurface.bottomPadding
        guard let last = plan.last else { return layout.contentHeight }
        switch last {
        case let .message(id):
            guard let frame = frames[id] else { return layout.contentHeight }
            return max(layout.contentHeight, Double(frame.maxY) + padding)
        case .end, .gap:
            // **The mark has no frame of its own, but the message above it
            // does**: the document ends at that message's measured bottom
            // plus everything the window's ruler puts below it (the stack's
            // spacing, the mark, the bottom padding). Without this the
            // document is an estimate short by the dividers' worth exactly
            // when the reader is looking at the newest end.
            guard let index = plan.lastIndex(where: {
                if case .message = $0 { return true }
                return false
            }), case let .message(id) = plan[index], let frame = frames[id]
            else { return layout.contentHeight }
            let below = layout.contentHeight
                - layout.top(of: index)
                - layout.heights[index]
            return max(layout.contentHeight, Double(frame.maxY) + below)
        case .start:
            return layout.contentHeight
        }
    }

    /// **The surface and the rows it draws.** The window is the only thing
    /// this list renders (design v2 §二): five thousand rows and a hundred
    /// cost the same, because only the rows in the window are ever made.
    private func surface(
        theme: Look.Theme,
        plan: [ControlRoomChatPresentation.ListRow],
        layout: ControlRoomChatScrollSurface.Layout,
        documentHeight: CGFloat,
        window: Range<Int>,
        viewport: CGFloat
    ) -> some View {
        let indexByID = rowIndexByID
        let items = Array(plan[window])
        let content = VStack(spacing: ControlRoomChatScrollSurface.spacing) {
            ForEach(items, id: \.id) { item in
                rowItem(item, theme: theme, indexByID: indexByID)
                    .onAppear { renderedRows += 1 }
                    .onDisappear { renderedRows = max(0, renderedRows - 1) }
            }
            // **The released-run edge is only drawn where the plan ends**: a
            // located window's way out is below its last row, not below
            // whatever this window happens to end on.
            if window.upperBound == plan.count {
                contextNewerBoundary(theme)
            }
        }
        // **No top padding** (the 2026-11-07 real-machine red: forty rows
        // rendered, none on screen). A padding the length of the history puts
        // the rows' *layout* far outside the viewport-sized hosting view, and
        // the clip takes them all away -- `.offset` moves what is drawn, not
        // where it is laid out. The window starts at 0 and the surface
        // reports the rows' frames shifted by `base`.
        .padding(.bottom, ControlRoomChatScrollSurface.bottomPadding)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ControlRoomChatScrollProbe(
            handle: scroll,
            onAttach: { attached in
                handleAttached = attached
                // **R1-6: the probe attaching is a projection trigger.** A
                // rebuilt host finds its scroll view again and the camera is
                // projected from scratch.
                if attached {
                    // The scroll view is back: the clip is put where the
                    // anchor says it belongs.
                    syncClip("attach")
                    startAutoScrollIfAsked()
                    startDebugInjectionIfAsked()
                    startDebugJumpIfAsked()
                }
            },
            onVisible: { shown in
                // A page that comes back into sight lands again; nothing was
                // measurable while hidden.
                if shown { syncClip("visible") }
            },
            onUserScroll: userTookScroll,
            onUserScrollEnd: handLeftTheList,
            report: scrolled
        ))
        return ControlRoomChatScrollSurfaceView(
            documentHeight: documentHeight,
            viewport: viewport,
            space: Self.space,
            content: AnyView(content),
            base: layout.top(of: window.lowerBound),
            startAt: camera.pinned
                ? max(0, documentHeight - viewport)
                : nil,
            onFrames: framesArrived,
            onGeometry: { geometryJustChanged = true },
            onStartPosition: { y in registerStartPosition(y) }
        )
    }

    /// One plan item, drawn. Extracted from the body so the window (and
    /// only the window) is what the list is made of.
    @ViewBuilder
    private func rowItem(
        _ item: ControlRoomChatPresentation.ListRow,
        theme: Look.Theme,
        indexByID: [String: Int]
    ) -> some View {
        switch item {
        case .start:
            endBoundary(
                theme,
                String(
                    localized: "This is the beginning of the conversation.",
                    comment: "总控台：群聊页，已到最早一条记录（终点分割线，不可点）"
                )
            )
        case .end:
            endBoundary(
                theme,
                String(
                    localized: "This is the newest message.",
                    comment: "总控台：群聊页，已到最新一条记录（终点分割线，不可点）"
                )
            )
        case let .gap(gap):
            gapBoundary(theme, gap: gap)
        case let .message(id):
            if let index = indexByID[id], index < feed.rows.count {
                let row = feed.rows[index]
                let dayBreak = needsDivider(index)
                // **One hairline, never two**: a day divider already
                // separates this row, so the speaker's rule is not stacked
                // on it.
                let speakerBreak = !dayBreak && needsSpeakerRule(index)
                if dayBreak {
                    dayDivider(row.message.atMs, theme)
                } else if speakerBreak {
                    speakerRule(theme)
                }
                let located = feed.locatedAnchor == row.id
                ControlRoomNativeChatRow(
                    row: row,
                    group: feed.group ?? "",
                    generation: feed.generation,
                    markdown: feed.markdown,
                    placeholder: placeholdersOn,
                    hit: located ? locatedHit : nil,
                    onReference: onReference
                )
                .background(located
                    ? theme.searchTarget.color.opacity(locatedGlow)
                    : Color.clear)
                .overlay(alignment: .leading) {
                    // The located row's own edge, so the hit reads as one
                    // message rather than a wash over the list.
                    if located {
                        Rectangle()
                            .fill(theme.searchTargetEdge.color)
                            .frame(width: 4)
                            .opacity(locatedGlow)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Look.Radius.row))
                .background(rowFrames(row.id))
            }
        }
    }

    /// **The instrument the criterion is read from** (task 3016 1a): what the
    /// window drew, where it starts and ends, the document's height and the
    /// viewport's place. `rendered` is the rows' own `onAppear`/`onDisappear`
    /// tally, not a number computed by this view.
    /// A signature that changes when the window stops containing the anchor
    /// (or starts again), so the instrument above speaks once per change.
    private func windowAnchors(
        plan: [ControlRoomChatPresentation.ListRow],
        layout: ControlRoomChatScrollSurface.Layout,
        window: Range<Int>
    ) -> String {
        guard let place = camera.place,
              let index = plan.firstIndex(where: { $0.id == Self.planID(place.id) })
        else { return "-" }
        return window.contains(index) ? "in" : "out:\(index)"
    }

    /// **One line per change of what the window draws.** `rows` is the count
    /// taken in the same `body` pass as the window -- not read live in the
    /// logger, which made an empty first frame look like "192 rows, 0 drawn"
    /// (the feed's answer landed between the body and the callback).
    /// `docH` is **the same number the projection uses** (`documentBottom`):
    /// an estimate in the same line as a measured bottom made "is it on the
    /// bottom?" unreadable (12190 − 968 ≠ 11568, a 346 pt estimate gap).
    private func viewportSignature(
        rows: Int,
        layout: ControlRoomChatScrollSurface.Layout,
        documentHeight: CGFloat,
        window: Range<Int>,
        origin: CGFloat
    ) -> String {
        [
            String(renderedRows),
            String(window.lowerBound),
            String(window.upperBound),
            String(Int(documentHeight.rounded())),
            String(Int(origin.rounded())),
            String(Int(layout.top(of: window.lowerBound).rounded())),
            String(rows),
        ].joined(separator: "|")
    }

    private func sayViewport(
        rows: Int,
        layout: ControlRoomChatScrollSurface.Layout,
        documentHeight: CGFloat,
        window: Range<Int>,
        origin: CGFloat
    ) {
        Self.surfaceLog.notice(
            "viewport: rendered=\(self.renderedRows, privacy: .public) first=\(window.lowerBound, privacy: .public) last=\(max(window.lowerBound, window.upperBound - 1), privacy: .public) rows=\(rows, privacy: .public) window=\(window.count, privacy: .public) docH=\(Int(documentHeight), privacy: .public) offset=\(Int(origin), privacy: .public) viewport=\(Int(self.viewportH), privacy: .public) base=\(Int(layout.top(of: window.lowerBound)), privacy: .public) inOffset=\(Int(max(0, origin - layout.top(of: window.lowerBound))), privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public)"
        )
    }

    // MARK: - The debug self-scroll (task 3016 1a)

    /// **`CHAT_AUTO_SCROLL=<points>` makes the list scroll itself.** A test
    /// instance cannot always inject a wheel (the 2026-11-07 real-machine
    /// red: `CGEventPost`, page keys and the AX scroll action all reached
    /// nothing and wrote no line), so the app has to be able to drive the one
    /// behaviour every scroll criterion is about.
    ///
    /// Positive scrolls towards **older** rows (the document's y decreases),
    /// negative towards the newest. **Nothing runs when the variable is
    /// absent**: no timer, no state, not one line more than a run without it.
    /// **`CHAT_INJECT_AFTER_MS` makes a message arrive, for measuring the
    /// follow behaviour** -- a debug path beside `CHAT_AUTO_SCROLL`, and like
    /// it: with the variable absent nothing is read, nothing is armed, and
    /// the injector is never reached.
    ///
    ///     CHAT_INJECT_AFTER_MS=1500   ms after the surface attaches
    ///     CHAT_INJECT_TEXT="probe 1"  the body (default "probe")
    ///     CHAT_INJECT_REPEAT=1        how many, 0 or absent = one
    ///
    /// The message is handed to the feed at the line the live read feeds
    /// (`ControlRoomChatFeed.injectDebugMessage`), so `rows` grows through
    /// the real `insert` and the change is classified `appended` /
    /// `cause=newer` exactly as an arrival from the core would be.
    private func startDebugInjectionIfAsked() {
        guard !debugInjectionArmed else { return }
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CHAT_INJECT_AFTER_MS"],
              let ms = Double(raw), ms >= 0
        else { return }
        debugInjectionArmed = true
        let text = env["CHAT_INJECT_TEXT"] ?? "probe"
        let times = max(1, Int(env["CHAT_INJECT_REPEAT"] ?? "") ?? 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) {
            for n in 0..<times {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.5) {
                    Self.windowLog.notice(
                        "inject: n=\(n + 1, privacy: .public) of=\(times, privacy: .public) bytes=\(text.utf8.count, privacy: .public)"
                    )
                    feed.injectDebugMessage(text: text)
                }
            }
        }
    }

    /// **The landing screen's placeholders** (design §26).
    ///
    /// A jump lands a window of rows whose Markdown has not been parsed yet;
    /// drawing them at their real heights means the picture moves as each row
    /// measures. Instead every unsettled row draws a fixed-height block, the
    /// header above it is already final, and the whole screen switches to real
    /// heights **once**.
    ///
    /// **Only a jump sets this.** Scrolling never does -- the placeholders
    /// exist for a landing, where nothing has been measured yet; a scroll has
    /// measured rows under it and a block appearing mid-scroll is the flicker
    /// they are meant to remove.
    private func beginPlaceholders() {
        placeholdersOn = true
        placeholderToken &+= 1
        let token = placeholderToken
        DispatchQueue.main.asyncAfter(deadline: .now() + ControlRoomChatPlaceholder.cap) {
            guard placeholderToken == token else { return }
            placeholdersOn = false
        }
    }

    /// **How many rows a landing screen covers before anything is measured.**
    /// No frames exist at that moment, so this is the constant split, not a
    /// measurement: the viewport divided by the placeholder row.
    private var firstScreenRowCount: Int {
        guard viewportH > 0 else { return 1 }
        return max(1, Int((viewportH / ControlRoomChatPlaceholder.rowHeight).rounded(.up)))
    }

    /// **The screen may switch when every row on it has stopped changing.**
    /// Walks the drawn rows from the top of the window; the first unsettled
    /// one leaves the placeholders up. The cap in `beginPlaceholders` is the
    /// other way out.
    private func endPlaceholdersIfSettled() {
        guard placeholdersOn, let group = feed.group else { return }
        let generation = feed.markdown.formGeneration
        var checked = 0
        for id in feed.rows.map(\.id) {
            guard checked < firstScreenRowCount else { break }
            guard let frame = frames[id], frame.height > 1 else { continue }
            checked += 1
            let form = feed.markdown.form(id: id, group: group, generation: generation)
            guard ControlRoomChatMarkdownStore.isSettled(form: form) else { return }
        }
        guard checked > 0 else { return }
        placeholdersOn = false
        Self.windowLog.notice(
            "placeholder: switched screen rows=\(checked, privacy: .public)"
        )
    }

    /// **`CHAT_JUMP_AFTER_MS` / `CHAT_JUMP_TO_INDEX` jump the list once**, for
    /// measuring the landing screen (design §26) where a search cannot be
    /// typed and a locate cannot be clicked. It calls **the product path**,
    /// `jump(to:)`, so the placeholder screen opens because the product opens
    /// it -- there is no debug branch inside the row.
    ///
    ///     CHAT_JUMP_AFTER_MS=2000   ms after the surface attaches
    ///     CHAT_JUMP_TO_INDEX=600    a `feed.rows` index; clamped, and said so
    ///
    /// Absent variables: nothing is read and no timer is armed, like the
    /// other `CHAT_*` switches.
    private func startDebugJumpIfAsked() {
        guard !debugJumpArmed else { return }
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CHAT_JUMP_AFTER_MS"], let ms = Double(raw), ms >= 0
        else { return }
        debugJumpArmed = true
        let wanted = Int(env["CHAT_JUMP_TO_INDEX"] ?? "") ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) {
            guard let last = feed.rows.indices.last else {
                Self.windowLog.notice("jumpdebug: skipped no-rows")
                return
            }
            let index = min(max(0, wanted), last)
            Self.windowLog.notice(
                "jumpdebug: index=\(index, privacy: .public) wanted=\(wanted, privacy: .public) clamped=\(index == wanted ? 0 : 1, privacy: .public)"
            )
            jump(to: feed.rows[index].id)
        }
    }

    private func startAutoScrollIfAsked() {
        guard auto == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CHAT_AUTO_SCROLL"],
              let points = Double(raw), points != 0
        else { return }
        // **The second leg** (`CHAT_AUTO_SCROLL_BACK`): after the first one,
        // scroll back the other way, so "the way home" is measurable too --
        // `pinned` returning to 1 and the clip landing on the document's own
        // end without the user touching the trackpad.
        let back = abs(Double(env["CHAT_AUTO_SCROLL_BACK"] ?? "") ?? 0)
        auto = ControlRoomChatAutoScroll(points: points, back: back)
        Self.surfaceLog.notice(
            "auto: start points=\(points, privacy: .public) back=\(back, privacy: .public) rows=\(self.feed.rows.count, privacy: .public)"
        )
        stepAutoScroll()
    }

    /// One step of the self-scroll. **The step is a reader, not a
    /// projection**: it raises the same signal a wheel raises (`noteWheel`),
    /// and it moves the clip directly so no expectation marks it as the
    /// view's own -- which is what makes the camera write a place and leave
    /// the bottom, exactly as a person's scroll would.
    private func stepAutoScroll() {
        guard let plan = auto, !plan.cancelled else { return }
        guard plan.waits < 100 else {
            plan.cancelled = true
            Self.surfaceLog.notice(
                "auto: done steps=0 moved=0 monotonic=1 reason=never-ready"
            )
            return
        }
        guard handleAttached, !feed.rows.isEmpty, viewportH > 1 else {
            plan.waits += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { stepAutoScroll() }
            return
        }
        let step = min(ControlRoomChatAutoScroll.step, plan.remaining)
        guard step > 0.01 else {
            // **The first leg is done; the second one is the way back.**
            if plan.leg == 0, plan.back > 0 {
                plan.leg = 1
                plan.direction = -plan.direction
                plan.remaining = plan.back
                plan.steps = 0
                plan.moved = 0
                plan.monotonic = true
                plan.last = nil
                Self.surfaceLog.notice(
                    "auto: back start points=\(plan.back, privacy: .public) offset=\(Int(self.scroll.originY ?? 0), privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public)"
                )
                stepAutoScroll()
                return
            }
            finishAutoScroll(plan)
            return
        }
        // **Before the move**: the callback the move causes has to be read as
        // the reader's, which is both what a wheel would say and what the
        // criteria are about.
        // **A move that does not announce itself as a wheel**
        // (`CHAT_AUTO_SCROLL_NO_WHEEL=1`). The driver's every step raises the
        // wheel signal, which is exactly what a real wheel fails to do when
        // its pointer is outside the scroll view -- and that missing signal is
        // the one input that lets the silent clamp branch below fire. Without
        // this flag no reading can reach the state the person reports.
        if !ControlRoomChatAutoScroll.silentWheel { scroll.noteWheel() }
        if plan.steps == 0 { userTookScroll() }
        let before = Double(scroll.originY ?? offsetY)
        scroll.scroll(toY: CGFloat(before + plan.direction * step))
        let after = Double(scroll.originY ?? before)
        plan.remaining -= step
        plan.steps += 1
        plan.moved += min(step, abs(after - before))
        if let last = plan.last {
            if plan.direction < 0, after > last + 0.5 { plan.monotonic = false }
            if plan.direction > 0, after < last - 0.5 { plan.monotonic = false }
        }
        plan.last = after
        sayAutoStep(plan, offset: after)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ControlRoomChatAutoScroll.interval
        ) {
            stepAutoScroll()
        }
    }

    /// One line per step, with the same numbers the `viewport:` line carries
    /// plus the row ids at the window's two ends.
    private func sayAutoStep(_ plan: ControlRoomChatAutoScroll, offset: Double) {
        let rows = listPlan
        let layout = scrollLayout(rows)
        let height = documentBottom(plan: rows, layout: layout)
        let origin = windowOrigin(
            plan: rows, layout: layout, documentHeight: height, viewport: viewportH
        )
        let window = layout.window(at: origin, viewport: viewportH)
        let base = layout.top(of: window.lowerBound)
        let first = rows.indices.contains(window.lowerBound)
            ? rows[window.lowerBound].id : "-"
        let last = rows.indices.contains(window.upperBound - 1)
            ? rows[window.upperBound - 1].id : "-"
        let anchor = camera.place.map { "\($0.id)@\(Int($0.offset))" } ?? "-"
        Self.surfaceLog.notice(
            "auto: step=\(plan.steps, privacy: .public) leg=\(plan.leg == 0 ? "fwd" : "back", privacy: .public) offset=\(Int(offset), privacy: .public) delta=\(Int(self.lastAnchorDelta), privacy: .public) inOffset=\(Int(max(0, origin - base)), privacy: .public) base=\(Int(base), privacy: .public) rendered=\(self.renderedRows, privacy: .public) first=\(first, privacy: .public) last=\(last, privacy: .public) anchor=\(anchor, privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public) dir=\(Int(plan.direction), privacy: .public) remaining=\(Int(plan.remaining), privacy: .public)"
        )
    }

    private func finishAutoScroll(_ plan: ControlRoomChatAutoScroll) {
        plan.cancelled = true
        if plan.leg == 1 {
            let rows = listPlan
            let height = documentBottom(plan: rows, layout: scrollLayout(rows))
            Self.surfaceLog.notice(
                "auto: back done steps=\(plan.steps, privacy: .public) moved=\(Int(plan.moved), privacy: .public) monotonic=\(plan.monotonic ? 1 : 0, privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public) offset=\(Int(self.scroll.originY ?? 0), privacy: .public) docH=\(Int(height), privacy: .public) viewport=\(Int(self.viewportH), privacy: .public)"
            )
            return
        }
        Self.surfaceLog.notice(
            "auto: done steps=\(plan.steps, privacy: .public) moved=\(Int(plan.moved), privacy: .public) monotonic=\(plan.monotonic ? 1 : 0, privacy: .public)"
        )
    }

    // MARK: - The located mark

    /// **The mark breathes when the located row is really on screen.** A
    /// locate is published a moment before its window is, so the arrival is
    /// not the moment: this is asked from the bounds callbacks and the
    /// frames preference, once the row is measured and under the viewport.
    /// One playing per locate (the feed's generation), so the same message
    /// located again plays again.
    private func breatheLocatedIfInView() {
        guard let located = feed.locatedAnchor,
              ControlRoomChatAnchor.locatedIsInView(
                located: located,
                frames: frames,
                offset: Double(offsetY),
                viewport: Double(viewportH)
              )
        else { return }
        let key = "\(feed.generation):\(located)"
        guard breathedLocate != key else { return }
        breathedLocate = key
        breatheLocatedMark()
    }

    /// **Two breaths, once.** The located row's ground and edge go 1 → 0.35 →
    /// 1 twice inside one second, then stay at the steady highlight; nothing
    /// repeats and nothing loops. The person's own answer wins: with Reduce
    /// Motion on, the mark is drawn steady and nothing moves.
    ///
    /// The steps are queued rather than one auto-reversing `repeatCount`
    /// animation: that one ends on its target value, which would leave the
    /// mark dimmed. Here the last step is the steady 1, and only opacity is
    /// touched -- the mark is drawn behind and beside the row, never laid
    /// out, so the breathing cannot move the list (task 2999 ④).
    private func breatheLocatedMark() {
        glowToken &+= 1
        let token = glowToken
        locatedGlow = 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let steps: [(opacity: Double, duration: Double)] = [
            (0.35, 0.25), (1, 0.25), (0.35, 0.25), (1, 0.25),
        ]
        var delay: Double = 0
        for step in steps {
            delay += step.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard glowToken == token else { return }
                withAnimation(.easeInOut(duration: step.duration)) {
                    locatedGlow = step.opacity
                }
            }
        }
    }

    // MARK: - The anchor (task 3016, the second slice)

    /// **The truth is one place: the row at the viewport's top and how far
    /// into it** (`topAnchor`, design v2 §九). The clip origin is a
    /// projection of it, never a second copy: a wheel moves the clip, the
    /// callback writes the anchor, and every layout change puts the clip back
    /// where the anchor says it belongs.
    ///
    /// **There is no compensation to pay.** Rows going in above the viewport
    /// do not move the rows the reader can see -- the anchor names a row, not
    /// a pixel -- so what changes is the document's y of that row, and the
    /// clip follows it in the same pass: a projection, not a debt that waits
    /// for a measurement, whose remainder has to be paid again, or that can
    /// pull the offset backwards while the reader is scrolling.

    /// The document's y of an anchor, **from the window's ruler and not from
    /// the frames**.
    ///
    /// The frames are the previous layout's: rows that have just gone in
    /// above are not measured yet, so a y built from them leaves the anchor
    /// where it was and the picture slides down by what went in, for one
    /// frame (the 2026-11-07 red seen from the other side). The window's
    /// ruler already counts those rows -- at their estimate -- so the clip
    /// moves in the same turn as the rows, and the frames that follow correct
    /// only the estimate's few points.
    private func anchorY(_ anchor: ControlRoomChatCamera.Place) -> Double? {
        // **The row's own measurement decides where it is** (review K):
        // `frames` are the coordinates the content is drawn in, so this is the
        // same number the surface laid out, and measuring the rows above it
        // cannot move it. The window's ruler is only for a row that has never
        // been drawn.
        // **A frame of no height is not a position, and its fallback is the
        // ruler -- not zero.** `anchorDocumentY` refuses a frame at or below
        // `anchorFrameMinimumHeight` (`frames` arrives whole, placeholders
        // included) and answers with `fallback + offset`; passing `0` there
        // would put the clip at the document's top for exactly the rows that
        // have no measurement yet. The guard lives in the one constant so
        // this fast path and the pure function cannot drift apart.
        if let frame = frames[anchor.id],
           frame.height > ControlRoomChatScrollSurface.anchorFrameMinimumHeight {
            return Double(frame.minY) + anchor.offset
        }
        let rows = listPlan
        guard let index = rows.firstIndex(where: {
            $0.id == Self.planID(anchor.id)
        }) else { return nil }
        return ControlRoomChatScrollSurface.anchorDocumentY(
            frame: nil,
            fallback: scrollLayout(rows).top(of: index),
            offset: anchor.offset
        )
    }

    /// **The document's y of a row's top, from the row's own frame.**
    ///
    /// `ControlRoomChatCamera.Place` says what an offset means: *points below
    /// the row's measured frame* (`place(order:frames:at:)`, `y(of:frames:)`).
    /// This is that same rule on the write side -- and it is the rule the
    /// 2026-11-07 ±16 was missing: the anchor was being written against the
    /// window's **ruler** (`Layout.top`, a running sum of heights from the
    /// plan's first row) and read back against the row's **frame**
    /// (`anchorY`), so `anchorY − the reader's y` was the difference between
    /// two rulers, and the projection spent it by moving the reader.
    ///
    /// The two are the same number only while nothing above the window has
    /// changed height since the frames were reported; the frame wins whenever
    /// there is one, because it is what was actually drawn. The ruler is the
    /// answer only for a row that has never been laid out -- the same fallback
    /// `anchorY` uses.
    private func rowTop(
        index: Int,
        rows: [ControlRoomChatPresentation.ListRow],
        layout: ControlRoomChatScrollSurface.Layout
    ) -> CGFloat {
        if rows.indices.contains(index),
           case let .message(id) = rows[index],
           let frame = frames[id],
           frame.height > ControlRoomChatScrollSurface.anchorFrameMinimumHeight {
            return frame.minY
        }
        return layout.top(of: index)
    }

    /// **An anchor inside its row** (design §17). The clip's y and the
    /// window's own ruler are two different numbers once a page goes in or a
    /// row measures taller, so an offset can be written thousands of points
    /// outside its row; the next projection would then put the clip there and
    /// the scroll position would be gone. **The offset is walked back into
    /// `[0, slot)` before it is ever used**, and a value that cannot be
    /// walked is said out loud instead of silently becoming the top row.
    private func normalizedAnchor(
        index: Int,
        offset: CGFloat,
        rows: [ControlRoomChatPresentation.ListRow],
        layout: ControlRoomChatScrollSurface.Layout
    ) -> ControlRoomChatCamera.Place? {
        // **The walk divides by the row's own height, and a drawn row's
        // height is its frame's** -- `scrollLayout` fills `Layout.heights`
        // from `heights`, which `framesArrived` writes from `frames`, so an
        // offset is split across rows by what was really laid out. Only a row
        // that has never been drawn falls back to the feed's estimate, and
        // that is the only place an estimate may decide a boundary.
        guard let (at, value) = layout.normalized(index: index, offset: offset) else {
            Self.cameraLog.notice(
                "anchor: unnormalizable index=\(index, privacy: .public) offset=\(Int(offset), privacy: .public) rows=\(self.feed.rows.count, privacy: .public)"
            )
            return nil
        }
        guard let id = nearestMessage(rows, at: at) else { return nil }
        // A boundary mark inside the window is stepped over: the offset is
        // kept relative to the message that owns the slot.
        if case .message = rows[at] {
            return ControlRoomChatCamera.Place(id: id, offset: Double(value))
        }
        return ControlRoomChatCamera.Place(id: id, offset: 0)
    }

    /// The anchor **at the clip's own y**, with the offset measured from the
    /// row's own top (`rowTop`): points below the row's **frame** where it has
    /// one, below the ruler where it has not.
    ///
    /// **Not `y − layout.top(of:)`** (the 2026-11-07 ±16): `Place.offset` is
    /// defined against the frame by `ControlRoomChatCamera`, and `anchorY`
    /// reads it that way. Writing it against the ruler made the written place
    /// and the read place two different points, and the projection spent the
    /// difference on the reader every time a frame arrived.
    ///
    /// The ruler still chooses **which row** `y` is in (`index(at:)`), which is
    /// its job -- it is the only ruler that covers rows that were never
    /// drawn.
    private func anchorFromClip(_ y: CGFloat) -> ControlRoomChatCamera.Place? {
        let rows = listPlan
        guard !rows.isEmpty else { return nil }
        let layout = scrollLayout(rows)
        let index = layout.index(at: y)
        return normalizedAnchor(
            index: index,
            offset: y - rowTop(index: index, rows: rows, layout: layout),
            rows: rows,
            layout: layout
        )
    }

    /// **How far the anchor moved, in pixels of the current ruler.** The log
    /// field the step checker reads: -40 for a 40 pt step, and the truth when
    /// a ruler change forced an absolute read instead.
    private func anchorPixelMove(
        from old: ControlRoomChatCamera.Place,
        to new: ControlRoomChatCamera.Place
    ) -> Double {
        let rows = listPlan
        let layout = scrollLayout(rows)
        func y(_ place: ControlRoomChatCamera.Place) -> Double? {
            guard let index = rows.firstIndex(where: {
                $0.id == Self.planID(place.id)
            }) else { return nil }
            // The offset is below the row's frame (see `rowTop`), so both ends
            // of the move are measured the same way.
            return Double(rowTop(index: index, rows: rows, layout: layout))
                + place.offset
        }
        guard let before = y(old), let after = y(new) else { return 0 }
        return after - before
    }

    /// **The document's real bottom, for every comparison that is about the
    /// reader's place.** The scroll view's frame height may be the floor
    /// (`live + viewport`) rather than the document's own end, so "am I at the
    /// bottom?" must not be asked of it: floored, it answers yes everywhere.
    private func currentDocumentBottom() -> CGFloat {
        let rows = listPlan
        return documentBottom(plan: rows, layout: scrollLayout(rows))
    }



    /// **The one projection**: put the clip where the anchor is, or at the
    /// document's end while following the newest row.
    private func syncClip(_ reason: String = "-") {
        guard handleAttached, visible, scroll.isVisible, viewportH > 1 else { return }
        let rulerNow = rulerEpoch
        var anchorYValue: Double = -1
        // **Where the anchor's row sits in each of the two rulers** (task
        // 3016, the 2026-11-07 ±16): `anchorY` is the projection's own answer,
        // `frameY` is the row's measured top, `rulerY` is `Layout.top` for the
        // same row. `frameY − rulerY` is the disagreement between the two
        // rulers, and whether it is a constant is the question -- a constant
        // (16?) means the frames' absolute coordinates lag the layout; a
        // number that moves with `rows=`/`content=` means something else.
        // `-1` means "no answer here" (pinned: the anchor is not used).
        var frameYValue: Double = -1
        var rulerYValue: Double = -1
        let target: Double
        var relative = false
        if camera.pinned {
            let rows = listPlan
            let height = documentBottom(plan: rows, layout: scrollLayout(rows))
            target = max(0, Double(height) - Double(viewportH))
            // The anchor is not tracking anything while the page follows the
            // newest row; the next hand starts from an absolute read.
            clipSeen = nil
            clipSeenRuler = rulerEpoch
        } else if let place = camera.place {
            // **The anchor is normalized immediately before it is used**: the
            // heights it was written against may have changed since (a row
            // measured taller, a page measured in), and an offset outside its
            // row would send the clip to a y that is not on this page.
            let ruler = rulerNow
            let rows = listPlan
            let layout = scrollLayout(rows)
            guard let start = rows.firstIndex(where: {
                $0.id == Self.planID(place.id)
            }) else { return }
            guard let fixed = normalizedAnchor(
                index: start, offset: CGFloat(place.offset),
                rows: rows, layout: layout
            ) else { return }
            camera.place = fixed
            guard let y = anchorY(fixed) else { return }
            anchorYValue = y
            // The two rulers, for the row the projection is really using:
            // `normalizedAnchor` may step to a neighbour, so the index is taken
            // again for `fixed` when it differs.
            let fixedIndex = fixed.id == place.id
                ? start
                : (rows.firstIndex(where: { $0.id == Self.planID(fixed.id) })
                    ?? start)
            frameYValue = frames[fixed.id].map { Double($0.minY) } ?? -1
            rulerYValue = Double(layout.top(of: fixedIndex))
            // **The anchor did not move; the document under it did.** Apply
            // the difference, so a scroll in flight keeps the pixels it has
            // and only the layout's drift is corrected. With no reference
            // (the anchor was just written by a jump or a rebase) the clip is
            // put on the anchor itself.
            // **A difference across two rulers is not a difference** (the
            // 2026-11-07 pull-back red, `reason=frames` 113 times): when a
            // frame re-measures the page, the anchor's own y moves by the
            // document's growth, and `y - seen` mixes that growth into what
            // the reader did. Same ruler: move by the difference, so a scroll
            // in flight keeps its pixels. Different ruler: put the clip **on
            // the anchor** in the new ruler, which is the only number that
            // means anything there.
            let seenBefore = clipSeen
            if let seen = clipSeen, ruler == clipSeenRuler {
                target = y - seen
                relative = true
            } else {
                target = y
            }
            // **The reference this projection compared against**, kept for
            // the log below: `clipSeen` is overwritten with the new anchor's
            // y, and printing that would say "seen == to" on every line.
            lastSyncSeen = seenBefore
            clipSeen = y
            clipSeenRuler = ruler
        } else {
            return
        }
        guard let live = scroll.originY else { return }
        let destination = relative ? Double(live) + target : target
        guard abs(destination - Double(live)) > 0.5 else { return }
        // **Who moved the clip, and from what anchor.** The pull-back red
        // (R7) is a projection made against an anchor the reader has already
        // left; this line names the trigger and both numbers.
        Self.windowLog.notice(
            "sync: move reason=\(reason, privacy: .public) from=\(Int(live), privacy: .public) to=\(Int(destination), privacy: .public) delta=\(Int(target), privacy: .public) anchor=\(self.camera.place.map { "\($0.id)@\(Int($0.offset))" } ?? "-", privacy: .public) seen=\(self.lastSyncSeen.map { Int($0) } ?? -1, privacy: .public) anchorY=\(Int(anchorYValue), privacy: .public) ruler=\(rulerNow, privacy: .public) seenRuler=\(self.clipSeenRuler, privacy: .public) relative=\(relative ? 1 : 0, privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public) frameY=\(Int(frameYValue), privacy: .public) rulerY=\(Int(rulerYValue), privacy: .public) offset=\(Int(self.camera.place?.offset ?? -1), privacy: .public) live=\(Int(live), privacy: .public)"
        )
        scrollOwn(to: destination)
    }

    /// One scroll the view asks for. **It is registered before it happens**,
    /// so the callback it causes is recognised as the view's own.
    /// **The surface's own first placement, registered before it happens.**
    /// The same clamp and the same "nothing to do" test the surface applies
    /// in `scroll(to:)`, so a registration exists exactly when a callback
    /// will follow. Nothing is scrolled here: the surface is already doing
    /// it, and a second scroll would be a second callback.
    private func registerStartPosition(_ y: CGFloat) {
        // **Every guard says so when it refuses** (the 2026-11-07 entry run:
        // the surface's first placement was still read as a hand and
        // `own: start matched` never appeared -- with no line here, "not
        // called" and "refused by a guard" read the same).
        guard let maximum = scroll.maximumOriginY else {
            Self.windowLog.notice("own: start skipped no-maximum")
            return
        }
        guard let live = scroll.originY.map(Double.init) else {
            Self.windowLog.notice("own: start skipped no-live")
            return
        }
        let target = min(max(0, Double(y)), Double(maximum))
        guard abs(target - live) > 0.5 else {
            Self.windowLog.notice(
                "own: start skipped no-move target=\(Int(target), privacy: .public) live=\(Int(live), privacy: .public)"
            )
            return
        }
        scroll.ownScroll = ControlRoomChatNativeOwnScroll(
            y: target, at: ProcessInfo.processInfo.systemUptime, start: true
        )
        Self.windowLog.notice(
            "own: start registered y=\(Int(target), privacy: .public) live=\(Int(live), privacy: .public) maximum=\(Int(maximum), privacy: .public)"
        )
    }

    private func scrollOwn(to y: Double) {
        // **The target is clamped here, before the scroll**, so the number
        // recorded is the number the clip will really take. A callback is
        // matched by that y and by nothing else: the first version also took
        // any callback within 50 ms, which swallowed the auto-scroll's own
        // step -- it is a stand-in for a hand, and must be read as one.
        guard let maximum = scroll.maximumOriginY else { return }
        let target = min(max(0, y), Double(maximum))
        guard let live = scroll.originY.map(Double.init) else { return }
        guard abs(target - live) > 0.5 else { return }
        scroll.ownScroll = ControlRoomChatNativeOwnScroll(
            y: target, at: ProcessInfo.processInfo.systemUptime
        )
        _ = scroll.scroll(toY: CGFloat(target))
    }

    /// **An anchor whose row is gone is said out loud**, never silently put
    /// back at the top (design §15).
    ///
    /// The reasons a row leaves -- an eviction, two rows merged onto one id,
    /// a locate's replaced window, a group change -- all arrive here as "the
    /// id is not in the plan". The answer is the nearest message at the
    /// current position, and the line names the row that was lost and the one
    /// that took its place.
    private func rebaseAnchor(_ reason: String) {
        guard let place = camera.place else { return }
        let rows = listPlan
        let wanted = Self.planID(place.id)
        if rows.contains(where: { $0.id == wanted }) { return }
        guard let id = nearestMessage(
            rows, at: scrollLayout(rows).index(at: CGFloat(offsetY))
        ) else {
            // **A lost anchor with nowhere to go is a defect, and it says
            // so** (design §15): nothing is silently put back at the top.
            Self.cameraLog.notice(
                "anchor: lost id=\(place.id, privacy: .public) reason=\(reason, privacy: .public) moved=- rows=\(self.feed.rows.count, privacy: .public)"
            )
            camera.place = nil
            camera.pinned = true
            return
        }
        camera.place = ControlRoomChatCamera.Place(id: id, offset: 0)
        camera.pinned = false
        clipSeen = nil
        feed.reading(anchor: id, offset: 0)
        Self.cameraLog.notice(
            "anchor: lost id=\(place.id, privacy: .public) reason=\(reason, privacy: .public) moved=\(id, privacy: .public) rows=\(self.feed.rows.count, privacy: .public)"
        )
        syncClip("rebase")
    }

    /// **The plan's id for a message.** The plan prefixes every message with
    /// `m:`; a lookup that passes a message id straight through finds
    /// nothing, so the prefix lives in one place.
    private static func planID(_ id: String) -> String {
        ControlRoomChatPresentation.ListRow.message(id: id).id
    }

    /// The nearest message at or below a plan index.
    private func nearestMessage(
        _ rows: [ControlRoomChatPresentation.ListRow], at index: Int
    ) -> String? {
        guard !rows.isEmpty else { return nil }
        let start = min(max(0, index), rows.count - 1)
        for distance in 0..<rows.count {
            let ahead = start + distance
            if ahead < rows.count, case let .message(id) = rows[ahead] { return id }
            let behind = start - distance
            if behind >= 0, case let .message(id) = rows[behind] { return id }
        }
        return nil
    }

    /// **The inverse: pixels → the anchor.** Only a callback writes it, and
    /// **`pinned` follows a hand only** (design §13): reaching the bottom
    /// while the reader scrolls is following again, and leaving it is
    /// reading history. A layout or the view's own scroll changes neither.
    private func scrolled(_ y: CGFloat, _ viewport: CGFloat, _ content: CGFloat) {
        // **A hidden host scrolls nothing.** `feed.stop` and a hidden
        // ancestor do not always reach `onDisappear`; the live view test
        // does.
        guard visible, scroll.isVisible else { return }
        // **A clip origin past the document instantiates nothing.** A
        // rubber-band overscroll is the reader's and is left alone; anything
        // else is clamped back.
        // **The bottom is the document's own**, never the frame's: with the
        // floor on, the frame is `live + viewport` and every point would say
        // "at the bottom".
        let documentBottomNow = currentDocumentBottom()
        if documentBottomNow > viewport + 1,
           y > documentBottomNow - viewport + 2,
           !scroll.userScrolling, !scroll.readerMovedRecently {
            // **This return eats a reader's move and says nothing.** (2026-11-07,
            // the person's report: the wheel does nothing in either direction
            // while the scrollbar still moves it, and it clears itself after a
            // while.) Nothing below runs: no anchor is written, `offsetY` is
            // not updated, and the clip is put on a bottom this function
            // computed. If that bottom is short of the real one, every tick
            // lands back on it and the wheel is dead -- and a scrollbar drag
            // skips this branch because `userScrolling` is true. It was silent,
            // which is why a whole day of readings never saw it.
            Self.windowLog.notice(
                "clamp: ate a move y=\(Int(y), privacy: .public) bottom=\(Int(documentBottomNow), privacy: .public) viewport=\(Int(viewport), privacy: .public) to=\(Int(documentBottomNow - viewport), privacy: .public) wheel=\(scroll.readerMovedRecently ? 1 : 0, privacy: .public) user=\(scroll.userScrolling ? 1 : 0, privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public)"
            )
            scrollOwn(to: Double(documentBottomNow - viewport))
            return
        }
        let contentChanged = abs(content - contentH) > 0.5
        offsetY = y
        viewportH = viewport
        contentH = content
        let bottom = ControlRoomChatAnchor.isAtBottom(
            offset: Double(y),
            viewport: Double(viewport),
            content: Double(documentBottomNow)
        )
        // **A callback the view caused is not a hand**, even while a wheel
        // signal is still warm: it is the clip arriving where the view sent
        // it, and reading it back would write that destination into the
        // anchor and pin the page (the 2026-11-07 red).
        let now = ProcessInfo.processInfo.systemUptime
        var ours = false
        if let own = scroll.ownScroll, now - own.at < 1.0,
           abs(own.y - Double(y)) <= 0.6 {
            ours = true
            scroll.ownScroll = nil
            // **The reading for the entry fix**: the surface's first
            // placement, recognised as the view's own. One per opening, and
            // the `bounds:` line beside it must say `hand=0`.
            if own.start {
                Self.windowLog.notice(
                    "own: start matched y=\(Int(y), privacy: .public) planned=\(Int(own.y), privacy: .public) dt=\(Int((now - own.at) * 1000), privacy: .public)"
                )
            }
        }
        // **Any move the view did not make is the reader's** (review E, MF2):
        // the wheel's own signals only cover the wheel and the trackpad. A
        // page key, a space bar or the accessibility scroll action moves the
        // clip through `NSScrollView` without either signal, and gating on
        // them meant those moves wrote no anchor, did not leave the bottom
        // (a following page was projected straight back down) and never
        // asked for a page near the loaded edge.
        // **A move the view made is not a reader's; neither is a clamp the
        // document's own geometry just caused** (review G): a page measured
        // in changes the frame height in the same pass, AppKit answers by
        // clamping the clip, and without this the clamp would be read as a
        // hand -- the anchor would jump and `pinned` would silently become
        // true.
        //
        // **The test is the geometry action, not a changed number.** It used
        // to be `!contentChanged`, and `content` changes on every tick a page
        // grows in -- so when a group opened, six reader steps in a row wrote
        // no anchor at all (240 pt of wheel, nothing moved).
        //
        // **And a geometry change only excuses a clamp at the document's own
        // ends** (the 2026-11-07 stuck wheel): gating on the flag alone made
        // every measured frame swallow the reader's move, so `syncClip` put
        // the clip back on the stale anchor each tick -- `bounds:` showed
        // 9676 → 9784 → 9677 → 9775, the wheel held in place while frames
        // arrived. A reader who scrolls on the same tick the frame grew is
        // still a reader unless the clip is sitting at an end.
        let geometryChanged = geometryJustChanged
        if geometryChanged { geometryJustChanged = false }
        let atAnEnd = y <= 0.5
            || y >= documentBottomNow - Double(viewport) - 0.5
        let reader = !ours && !(geometryChanged && atAnEnd)
        // **Only a reader writes the anchor**, and it writes it as a
        // movement from the anchor that was already there. An absolute read
        // of the clip is only for a page with no reference yet: after a
        // measurement re-scales the document, the same y belongs to another
        // row, and reading it absolutely walked the anchor 45 rows in one
        // 40 pt step (the 2026-11-07 red).
        if reader {
            // **Every reader's tick must land somewhere** (the 2026-11-07
            // stuck wheel: 42 pull-backs, 35 of them with the document
            // unchanged). A tick that writes nothing leaves the anchor where
            // it was, and the next `syncClip` puts the clip back on it -- the
            // reader's 40 pt undone, every time. So each path below either
            // writes the anchor or re-places it; `branch=` in `bounds:` says
            // which one ran.
            let ruler = rulerEpoch
            // **The reference moves to where the clip is *now*, and the
            // reader's step is applied here, not projected later**: the next
            // callback measures its difference from this number, so a step
            // read back from a destination the view wrote would be counted
            // twice (the 2026-11-07 red: `offset +80` and an id two rows away
            // in the back leg).
            let previousClip = clipSeen
            clipSeen = Double(y)
            clipSeenRuler = ruler
            var branch = "none"
            if let place = camera.place,
               let delta = ControlRoomChatScrollSurface.anchorMovement(
                   seen: previousClip, y: Double(y)
               ) {
                // **A difference measured across two rulers is not the
                // reader's**: the reference belongs to the old one.
                if ruler == clipSeenRuler {
                    let rows = listPlan
                    let layout = scrollLayout(rows)
                    if let index = rows.firstIndex(where: {
                        $0.id == Self.planID(place.id)
                    }), let next = normalizedAnchor(
                        index: index,
                        offset: CGFloat(place.offset) + CGFloat(delta),
                        rows: rows,
                        layout: layout
                    ) {
                        camera.place = next
                        lastAnchorDelta = anchorPixelMove(from: place, to: next)
                        feed.reading(anchor: next.id, offset: next.offset)
                        branch = "inc"
                    } else {
                        // **The anchor's row is gone from the plan**: re-place
                        // it from the reader's own y under this ruler, never
                        // leave the anchor behind.
                        clipSeen = nil
                        rebaseAnchor("reader")
                        branch = "rebase"
                    }
                } else if let next = anchorFromClip(y) {
                    // **The ruler moved under the reference; this tick is
                    // read in the new one, once.** The reader is at `y` in
                    // the new ruler, so that is the answer, and the reference
                    // is clean for the next tick.
                    camera.place = next
                    lastAnchorDelta = anchorPixelMove(from: place, to: next)
                    feed.reading(anchor: next.id, offset: next.offset)
                    branch = "abs:ruler"
                } else {
                    clipSeen = nil
                    branch = "none:ruler"
                }
            } else if let next = anchorFromClip(y) {
                // **No usable reference** (a page's first reader move, or a
                // failed movement): read the clip absolutely once and make it
                // the reference.
                camera.place = next
                feed.reading(anchor: next.id, offset: next.offset)
                branch = "abs:first"
            } else {
                clipSeen = nil
                branch = "none:empty"
            }
            lastReaderBranch = branch
            // **The reader's callback is placed; the view does not project
            // over it.** (The 2026-11-07 flutter: `sync: move reason=reader`
            // 345 times in one run, 257 at −16 and 87 at +16.) The anchor
            // above is written with the window's **ruler**, while `syncClip`
            // places by the row's own **measured frame**, and the two
            // disagree by the decorations the ruler does not count. So
            // projecting here undid the reader's step by exactly that
            // difference on every tick -- `from=9634 to=9618 delta=-16`
            // against `anchor-move ... offset=9634` -- and the next tick read
            // it back as another hand's.
            //
            // **Where the two numbers disagree is still an open question**
            // (a later `reason=frames` projection compares the same pair, and
            // a −16 there would be the same defect under another label).
            // What this line settles is narrower and absolute: **the clip is
            // where the hand put it, and the anchor is the record of where
            // that is** -- the record never gets to move the hand.
            //
            // The earlier version projected here on purpose: a projection
            // *queued before* this callback would otherwise carry the anchor
            // from before the reader's move. That is still true, and it is
            // answered by writing the anchor before any queued projection
            // runs, not by projecting a second time in the same turn.
            // One line per reader callback while this red is open: the counts
            // per branch are the reading (the 2026-11-07 stuck wheel).
            Self.windowLog.notice(
                "anchor-move: branch=\(branch, privacy: .public) delta=\(Int(self.lastAnchorDelta), privacy: .public) offset=\(Int(y), privacy: .public) id=\(self.camera.place?.id ?? "-", privacy: .public) clipSeen=\(self.clipSeen.map { Int($0) } ?? -1, privacy: .public) ruler=\(ruler, privacy: .public) seenRuler=\(self.clipSeenRuler, privacy: .public)"
            )
            if bottom { newBelow = false }
            camera.pinned = bottom
            armQuietCheck()
            maintainWindow(fromInput: true)
            noteTopHit()
        }
        // **`clipSeen` is "where the clip is now", and every callback says
        // so** -- a reader's move already advanced it above; a callback the
        // view caused (or a geometry clamp) advances it here. Written only on
        // a reader's move, the clip's own projection was added into the next
        // reader's delta: one 40 pt step moved the anchor 40 rows (the
        // 2026-11-07 red, `bounds:` n=5 and n=6 moving 10809 → 8447 with the
        // field left at 10769).
        if !reader {
            clipSeen = Double(y)
            clipSeenRuler = rulerEpoch
        }
        sayBounds(
            hand: reader, y: y, content: content,
            delta: lastAnchorDelta, branch: lastReaderBranch
        )
        breatheLocatedIfInView()
        publishViewportRows()
        // **Following the newest row means following it**: a row that has
        // just measured taller, or a message that has just arrived, moves the
        // document's end and the clip with it.
        if camera.pinned, contentChanged {
            DispatchQueue.main.async { syncClip("content") }
        }
    }

    /// **The criterion-2 instrument.** One line each time a gesture reaches
    /// the loaded top while earlier history is still out; a reading is
    /// counted from the log, not judged by eye. Only the transition is
    /// logged, so a reader resting at the top does not fill the log.
    private func noteTopHit() {
        guard viewportH > 0, !feed.rows.isEmpty, feed.hasEarlier else {
            atLoadedTop = false
            return
        }
        let loadedTop = frames[feed.rows[0].id].map { Double($0.minY) } ?? 0
        let hit = readTop - loadedTop <= 1
        if hit, !atLoadedTop {
            atLoadedTop = true
            topHits += 1
            Self.flowLog.notice(
                "top-hit: count=\(topHits, privacy: .public) rows=\(feed.rows.count, privacy: .public) pinned=\(camera.pinned, privacy: .public)"
            )
        } else if !hit {
            atLoadedTop = false
        }
    }

    // MARK: - Keeping the margin (task 3016 R4, review C's M5/M6/M8)

    /// **One tick of the window: one action, at most.** Everything here is
    /// in **points**; the row counts are only how many rows one step may
    /// take. See `ControlRoomChatWindow` for the rule and the constants.
    ///
    /// Three triggers ask for this (review C, M6): every bounds callback,
    /// the quiet check after the hand stops, and a page landing in an apron.
    /// **Every action changes an apron count**, so the next step is queued by
    /// the change handler rather than taken in this tick -- which is what
    /// makes a fill a chain of single actions instead of a burst against one
    /// stale reading (the 2026-11-06 oscillation).
    private func maintainWindow(fromInput: Bool) {
        guard viewportH > 0, !feed.rows.isEmpty else { return }
        let order = feed.rows.map(\.id)
        publishRowHeightEstimate(order: order)
        // **The number the layout uses**, so this reading and `scrollLayout`
        // cannot be two estimates.
        let height = max(1, feed.rowHeightEstimate)
        let reading = windowReading(order: order, height: height)
        // **The row the reader is standing on, before this tick acts.** The
        // pair of ids `sayWindowAction` writes is the one reading of "did the
        // action move the page under the reader" that the offset cannot give
        // (it is not an invariant: a compensation and a scroll both raise it).
        let topIDBefore = windowTopID(order: order, at: reading.top)
        let decision = windowDecision(reading, order: order)
        if decision.contradictory {
            Self.windowLog.notice(
                "window: contradictory top=\(Int(reading.top), privacy: .public) offset=\(Int(self.offsetY), privacy: .public) content=\(Int(reading.content), privacy: .public) margin=\(Int(ControlRoomChatWindow.marginScreens * reading.viewport), privacy: .public) retain=\(Int(ControlRoomChatWindow.retainScreens * reading.viewport), privacy: .public)"
            )
        }
        noteWindowDisagreement(step: decision.feed)

        // **No second feed before the first is placed** (the capacity
        // model's one precondition): an insertion is invisible only because
        // the compensation is exact, and two feeds under one compensation
        // would stack their displacements into one visible jump. **And no
        // eviction either**: an eviction at the far end changes the
        // document's height, and the compensation measures its own amount as
        // that height's growth while the debt is owed.
        let feedStep = decision.feed

        var moved = 0
        var feedWanted = 0
        var side = ""
        var direction = ""
        switch feedStep {
        case .none:
            break
        case let .intakeOlder(n):
            side = "older"
            direction = "in"
            feedWanted = n
            moved = feed.feedOlder(rows: n, maxHeight: 0)
            if moved > 0 {
                // **The rows went in above the viewport; the anchor did
                // not.** Its document's y moved by what went in, and the
                // clip follows it in this same turn -- no debt, no estimate,
                // nothing left to pay later.
                syncClip("feed")
            }
        case let .intakeNewer(n):
            side = "newer"
            direction = "in"
            feedWanted = n
            moved = feed.feedNewer(rows: n, maxHeight: 0)
        case .releaseOlder, .releaseNewer:
            break   // not a feed; the eviction is handled below
        }
        if moved > 0 {
            sayWindowAction(
                side: side, direction: direction, moved: moved,
                want: feedWanted, reading: reading, height: height,
                topIDBefore: topIDBefore
            )
        }

        // **The far end**, one eviction, never touching the camera row.
        // **Not while a hand is on the list** (the 2026-11-07 "it is stuck",
        // from the person's own hand-scroll: `rows: 1000->624 cause=slide` and
        // `624->1000 cause=older` every ~35 ms, 717 and 953 times in one
        // gesture).
        //
        // **A slide is not "the same map, slid"**: dropping the plan's first
        // rows makes `Layout.top` count from the *new* first row, so every
        // surviving row's y moves by the whole removed height, and the feed
        // asks for the same rows back one frame later. The eviction buys
        // nothing here and costs the map its origin -- 30000 pt of flip is the
        // resistance the person feels and the scrollbar running between the
        // top and the middle.
        //
        // **One eviction, after the hand is off**: `handLeftTheList` runs this
        // again with the wheel window expired, and then it costs nothing --
        // no projection is in flight and the reader is not looking at the rows
        // going away.
        let handOnList = scroll.userScrolling || scroll.readerMovedRecently
        var evicted = 0
        var evictWanted = 0
        var evictSide = ""
        if !handOnList {
            switch decision.evict {
            case let .releaseOlder(n):
                evictSide = "older"
                evictWanted = n
                evicted = feed.releaseOlder(count: n)
            case let .releaseNewer(n):
                evictSide = "newer"
                evictWanted = n
                evicted = feed.releaseNewer(count: n)
            default:
                break
            }
        }
        if evicted > 0 {
            sayWindowAction(
                side: evictSide, direction: "out", moved: evicted,
                want: evictWanted, reading: reading, height: height,
                topIDBefore: topIDBefore
            )
        }

        // **Ask from where the window is now, not from where it was**: the
        // action just changed the apron the first decision counted.
        let after = windowReading(order: feed.rows.map(\.id), height: height)
        let requests = windowDecision(after, order: feed.rows.map(\.id))
        if requests.requestOlderRows > 0, feed.canLoadOlder {
            feed.loadOlder(limit: requests.requestOlderRows)
        }
        if fromInput, requests.requestNewerRows > 0, feed.hasNewer {
            feed.loadContextNewer()
        }
    }

    /// **One line per action, and the margins are named apart** (the
    /// 2026-11-07 red): `drawn*` is what the document shows on a side (the
    /// number the rule feeds from), `loaded*` adds the apron behind it (the
    /// number the request is judged against). One name for both made every
    /// reading of the log ambiguous.
    private func sayWindowAction(
        side: String,
        direction: String,
        moved: Int,
        want: Int,
        reading: ControlRoomChatWindow.Reading,
        height: Double,
        topIDBefore: String
    ) {
        let drawnAbove = max(0, reading.top - reading.loadedTop)
        let drawnBelow = max(0, reading.content - (reading.top + reading.viewport))
        let apronAbove = Double(feed.aboveCount) * height
        let apronBelow = Double(feed.belowCount) * height
        // **The top row the action left behind, against the one the decision
        // was taken on.** An intake inserts above the viewport, so this pair
        // differs on the intake's own line -- the compensation has not run
        // yet -- and the next line's `topID` must be the original again. Two
        // lines agreeing is the reader being still; a run of them walking
        // one way is the reader scrolling. Neither is readable from `offset`,
        // which a compensation raises exactly as a scroll does.
        let topIDAfter = windowTopID(
            order: feed.rows.map(\.id), at: Double(self.offsetY)
        )
        Self.windowLog.notice(
            "window: side=\(side, privacy: .public) dir=\(direction, privacy: .public) moved=\(moved, privacy: .public) want=\(want, privacy: .public) rows=\(self.feed.rows.count, privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public) place=\(self.camera.place.map { "\($0.id)@\(Int($0.offset))" } ?? "-", privacy: .public) contentH=\(Int(self.contentH), privacy: .public) live=\(Int(self.liveDocumentHeight), privacy: .public) topID=\(topIDBefore, privacy: .public) topIDAfter=\(topIDAfter, privacy: .public) drawnAbove=\(Int(drawnAbove), privacy: .public) loadedAbove=\(Int(drawnAbove + apronAbove), privacy: .public) drawnBelow=\(Int(drawnBelow), privacy: .public) loadedBelow=\(Int(drawnBelow + apronBelow), privacy: .public) apronAbove=\(self.feed.aboveCount, privacy: .public) apronBelow=\(self.feed.belowCount, privacy: .public) viewport=\(Int(reading.viewport), privacy: .public) margin=\(Int(ControlRoomChatWindow.marginScreens * reading.viewport), privacy: .public) hasEarlier=\(self.feed.hasEarlier ? 1 : 0, privacy: .public) hasNewer=\(self.feed.hasNewer ? 1 : 0, privacy: .public) offset=\(Int(self.offsetY), privacy: .public) content=\(Int(reading.content), privacy: .public)"
        )
    }

    /// **The document's height, one source for every reader of it**: the
    /// window's `content`, the pinned top, and the projection's
    /// `pinIsAvailable`. The scroll view's own height lags the rows on a page
    /// that is opening (192 rows in the frames, 24 from the scroll view), and
    /// a projection that asked its question of the 24 waited for ever.
    private func windowDocumentHeight(order: [String]) -> Double {
        ControlRoomChatWindow.documentHeight(
            order: order, frames: frames, live: Double(liveDocumentHeight)
        )
    }

    /// **The row at the viewport's top edge**, by the frames this view holds.
    /// The camera's place when the map cannot place one (an unmeasured first
    /// row, a width that just changed), so a line is never missing a value.
    private func windowTopID(order: [String], at y: Double) -> String {
        ControlRoomChatCamera.place(order: order, frames: frames, at: y)?.id
            ?? camera.place?.id
            ?? "-"
    }

    private func windowReading(
        order: [String],
        height: Double
    ) -> ControlRoomChatWindow.Reading {
        // **`top` and `content` from one moment.** The document's bottom is
        // the last measured row's frame when there is one -- that comes from
        // the same map `loadedTop` does -- and the scroll view's live height
        // otherwise. The cached `contentH` never reaches the rule (the
        // 2026-11-06 oscillation: a live top against a content height one
        // rows change behind).
        let content = windowDocumentHeight(order: order)
        return ControlRoomChatWindow.Reading(
            // **The actual viewport, always** -- never `cameraTopY()`. **And
            // from the same document height as the content beside it**: a
            // pinned top taken from the document view's frame while the
            // content came from the last measured row can be 20 000 pt apart
            // when the two lag each other, and every threshold is read from
            // this pair (2026-11-07: `content=21632` with a top of 1).
            top: ControlRoomChatWindow.viewportTop(
                pinned: camera.pinned,
                content: content,
                viewport: Double(viewportH),
                offset: Double(offsetY)
            ),
            viewport: Double(viewportH),
            content: content,
            loadedTop: order.first.flatMap { frames[$0] }.map { Double($0.minY) } ?? 0,
            rowHeight: height
        )
    }

    private func windowDecision(
        _ reading: ControlRoomChatWindow.Reading,
        order: [String]
    ) -> ControlRoomChatWindow.Decision {
        // **The row actually at the viewport's top**, from the same actual
        // reading the rest of the decision uses -- not the camera's place,
        // which may be a callback behind (the 2026-11-06 red). It only
        // bounds how many rows an eviction may take.
        let index = ControlRoomChatCamera.place(
            order: order, frames: frames, at: reading.top
        ).flatMap { order.firstIndex(of: $0.id) }
            ?? (camera.pinned ? max(0, order.count - 1) : 0)
        return ControlRoomChatWindow.decide(
            reading,
            aboveRows: feed.aboveCount,
            belowRows: feed.belowCount,
            documentAbove: index,
            documentBelow: max(0, order.count - index - 1),
            hasEarlier: feed.hasEarlier,
            hasNewer: feed.hasNewer
        )
    }

    /// **A row's height, measured.** The median of what the list has laid
    /// out; the feed's default stands in before anything is measured. Not a
    /// mean: one 300 pt message must not drag a screen of 16 pt rows into a
    /// "half a screen is two rows" step.
    /// **Publish the estimate, until it is settled.** One place decides, so
    /// `framesArrived` and `maintainWindow` cannot disagree about it, and
    /// `scrollLayout` reads the same number the window's arithmetic does.
    private func publishRowHeightEstimate(order: [String]) {
        guard !rowHeightEstimateSettled else { return }
        var drawn = 0
        for id in order {
            if let frame = frames[id], frame.height > 1 { drawn += 1 }
        }
        guard drawn > 0 else { return }
        let measured = measuredRowHeight(order: order)
        // **Settle = the median stopped moving**, not "the first sample".
        // The 2026-11-07 entry run froze on the first sample: 27 rows drawn,
        // median 46 -- and the very next pass converted 22 of them to 64.
        // The estimate the whole far end is multiplied by was therefore one
        // conversion stale, by the same 18 points. A sample is worth freezing
        // once it agrees with itself between two passes.
        let stable = abs(measured - feed.rowHeightEstimate) < 0.5
        feed.rowHeightEstimate = measured
        rowHeightEstimatePasses += 1
        if drawn >= Self.estimateFreezeSample, stable {
            rowHeightEstimateSettled = true
        }
        if rowHeightEstimatePasses >= Self.estimateFreezePasses {
            rowHeightEstimateSettled = true
        }
    }

    private func measuredRowHeight(order: [String]) -> Double {
        var heights: [Double] = []
        for id in order {
            if let frame = frames[id], frame.height > 1 {
                heights.append(Double(frame.height))
            }
        }
        guard !heights.isEmpty else { return feed.rowHeightEstimate }
        heights.sort()
        return heights[heights.count / 2]
    }

    /// **A window that feeds older rows while the reader moves towards the
    /// newest is talking past its input.** It says so with both numbers
    /// rather than quietly walking them somewhere they did not ask to go --
    /// and one line per run, not one per tick.
    private func noteWindowDisagreement(step: ControlRoomChatWindow.Step) {
        let offset = Double(offsetY)
        let grew = offset > lastReadOffset + 0.5
        lastReadOffset = offset
        // **The reader's own signal, not the offset alone**: a compensation
        // scroll raises the offset too, and an intake that is ours must not
        // be read as the reader moving the other way.
        let readerMoving = scroll.userScrolling || scroll.readerMovedRecently
        guard case let .intakeOlder(n) = step, grew, readerMoving else {
            disagreeRun = 0
            return
        }
        disagreeRun += 1
        guard disagreeRun == Self.disagreeTicksBeforeSaying else { return }
        Self.windowLog.notice(
            "window: disagree top=\(Int(self.cameraTopY()), privacy: .public) offset=\(Int(offset), privacy: .public) intake=\(n, privacy: .public) rows=\(self.feed.rows.count, privacy: .public) above=\(self.feed.aboveCount, privacy: .public) below=\(self.feed.belowCount, privacy: .public)"
        )
    }

    @discardableResult
    private func rowsChanged(_ rows: [ControlRoomChatFeed.Row]) -> ControlRoomChatAnchor.Change {
        let ids = rows.map(\.id)
        let before = lastIDs.count
        let change = ControlRoomChatAnchor.change(from: lastIDs, to: ids)
        // **When the document changed, and from where** (2026-11-07): the
        // first link in the chain `rows: -> bounds: -> proj: -> window:`.
        if change != .none {
            let kind: String
            switch change {
            case .appended: kind = before == 0 ? "bootstrap" : "newer"
            case .prepended: kind = "older"
            case .moved: kind = "slide"
            case .replaced: kind = before == 0 ? "bootstrap" : "replaced"
            case .none: kind = "none"
            }
            Self.windowLog.notice(
                "rows: \(before, privacy: .public)->\(ids.count, privacy: .public) first=\(ids.first ?? "-", privacy: .public) last=\(ids.last ?? "-", privacy: .public) cause=\(kind, privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public) offset=\(Int(self.offsetY), privacy: .public)"
            )
        }
        switch change {
        case .appended:
            if feed.locatedAnchor != nil {
                // A replaced body here is a search locate, not new messages.
                newBelow = false
            } else if camera.pinned {
                newBelow = false
            } else if !rows.isEmpty {
                newBelow = true
            }
        case .replaced:
            // **A new map, not a longer one.** The frames the view holds are
            // the old window's coordinates, and a projection computed from
            // them lands somewhere that does not exist any more; the drag the
            // index bar is in the middle of was aimed at the old map too.
            frames = [:]
            // **A new map gets a new estimate**: the frozen one was measured
            // on rows from another group. (Within one map it stays frozen --
            // that is §25.2's rule.)
            rowHeightEstimateSettled = false
            // **And a new high-water mark**: group B must not inherit group
            // A's depth. §23.3's rule is one document's -- and the seed is
            // dropped with it, or the new document's first plan would be
            // `max`ed against the old depth.
            barReached = 0
            barReachedSeeded = false
            rowHeightEstimatePasses = 0
            mapEpoch &+= 1
            if feed.locatedAnchor != nil {
                newBelow = false
            } else if camera.pinned {
                newBelow = false
            } else if !rows.isEmpty {
                newBelow = true
            }
        case .prepended, .moved:
            // **A slide is NOT "the same map, slid"** (review C, M4 said it
            // was; the 2026-11-07 hand-scroll says otherwise). Dropping the
            // plan's first rows renumbers the document from the new first
            // row, so the rows that stay are **not** at the same y: their
            // frames belong to a document that no longer exists, and the two
            // coordinate systems were read side by side 30000 pt apart
            // (`frameY=42 rulerY=30150` on one anchor).
            //
            // What keeps the map honest is upstream of this line now: the
            // eviction that causes a slide **does not run while a hand is on
            // the list** (`maintainWindow`), so a reader's scroll never
            // renumbers the document under them. This branch still filters,
            // and the camera row's frame is still never dropped -- that part
            // of M4 stands.
            break
        case .none:
            break
        }
        // **A slide filters the map; it does not clear it** (review C,
        // M4). **The camera row's own frame is never filtered out** (the
        // 2026-11-07 red): the same invariant `releaseOlder` keeps at the
        // row layer -- if a slide drops it from the map, the projection falls
        // back and the viewport lands wherever the measured rows are.
        if change != .replaced, !frames.isEmpty {
            var present = Set(ids)
            if let place = camera.place { present.insert(place.id) }
            frames = frames.filter { present.contains($0.key) }
        }
        lastIDs = ids
        // **§23.1 rule 2, on the view's side.** The feed keeps the reader's
        // place across a stop; the camera is what the projection reads, and
        // while the page was away it may have been cleared. Take the place
        // back when there is one to take -- **and only when the camera has
        // none**, so a place the reader has made since is never overwritten.
        // The three rules of §23.1 need all three pieces (`stop()` keeps the
        // anchor, `start()` recentres on it, this restores the offset); any
        // one alone is a false fix.
        if camera.place == nil, let saved = feed.savedReading {
            camera.place = saved
            camera.pinned = false
            clipSeen = nil
        }
        // **R1-8: a located window's way out lands when the new map does.**
        if pendingReturnToLatest, !isLocated {
            pendingReturnToLatest = false
            camera = ControlRoomChatCamera.State(place: nil, pinned: true)
        }
        return change
    }

    /// **A locate has two moments** (R2-1): `locateEpoch` moves when the
    /// request starts -- before the target's around window exists -- and the
    /// rows change is when it lands. Keyed on both, so re-picking the same
    /// result lands again while a context page appended afterwards does not
    /// pull the reader back.
    ///
    /// **A settled locate is recorded even when its target is not in the
    /// window** (M5). `locateSettled` answers "has this locate finished",
    /// not "is the row here": leaving the key unrecorded made every rows
    /// change ask for the same `around` again -- one core request per round,
    /// for ever.
    private func jumpToLocate(_ target: String?) {
        guard let target else { return }
        let key = "\(feed.locateEpoch):\(target)"
        guard landedLocate != key else { return }
        let settled = ControlRoomChatCamera.locateSettled(
            targetInRows: rowIndexByID[target] != nil,
            hasContext: feed.context != nil,
            trouble: feed.locateTrouble != nil
        )
        if settled { landedLocate = key }
        // A settled locate whose target is not in its window has nothing to
        // land on (the feed has said `TargetNotInWindow`); asking again is
        // the loop M5 closes.
        guard rowIndexByID[target] != nil || !settled else { return }
        // **A locate lands the target in the middle of the viewport**, not on
        // its top edge (design §15, rule 3): the reader picked this message
        // to read it, and half a screen of its context on each side is the
        // useful place. A jump from the index bar keeps the top edge -- that
        // is a position, not a message.
        jump(to: target, centered: true)
    }

    /// **The index bar's seek, through the one teleport primitive.** A drag
    /// asks for a **depth** (points below the newest); a depth is not a
    /// message, so it lands on the nearest one.
    ///
    /// ⚠️ **This does not reach an evicted position.** The bar's total is the
    /// document's own depth in this step; when the high-water mark replaces
    /// it, dragging to the far left lands on the **oldest row still loaded**,
    /// not on the earliest the reader ever reached. An evicted row is not
    /// reachable here -- the `around` slow path for a message with no
    /// `location` hint is unverified -- and on a normal night nothing is
    /// evicted, so the two ends are the same row. **The difference is felt
    /// only after the 5000-row / 32 MiB ceiling, and only then is it a
    /// difference at all.**
    private func seek(toDepth depth: Double) {
        let order = feed.rows.map(\.id)
        let plan = listPlan
        let documentNow = Double(documentBottom(plan: plan, layout: scrollLayout(plan)))
        guard let index = nearestMessageIndex(
            order: order, documentY: documentNow - depth
        ) else { return }
        jump(to: feed.rows[index].id)
    }

    /// **The one teleport primitive** (R1-3). It is one write of the anchor:
    /// a row already in `rows` is landed on at once, and one that is not
    /// loaded changes the map through the feed -- the rows that arrive carry
    /// the anchor, and the projection that follows is the same one every
    /// other layout change uses.
    private func jump(to id: String, centered: Bool = false) {
        // **A jump is the one path that lands on unmeasured rows** (design
        // §26): everything on that screen is drawn as a fixed block until it
        // stops changing.
        beginPlaceholders()
        camera.pinned = false
        newBelow = false
        pendingReturnToLatest = false
        camera.place = ControlRoomChatCamera.Place(id: id, offset: 0)
        clipSeen = nil
        feed.reading(anchor: id, offset: 0)
        let loaded = rowIndexByID[id] != nil
        if !loaded {
            feed.jump(to: id)
            clipSeen = nil
        } else if centered {
            center(on: id)
        } else {
            clipSeen = nil
        }
        syncClip("jump")
    }

    /// **Put a row in the middle of the viewport**: the document's y of its
    /// top, less half of what is left of the screen around it. The anchor is
    /// then read back from that y, so the truth stays the same pair every
    /// other move writes.
    private func center(on id: String) {
        let rows = listPlan
        guard let index = rows.firstIndex(where: {
            $0.id == Self.planID(id)
        }) else { return }
        let layout = scrollLayout(rows)
        let target = layout.centeredOrigin(of: index, viewport: viewportH)
        guard let place = anchorFromClip(target) else { return }
        camera.place = place
        clipSeen = nil
        feed.reading(anchor: place.id, offset: place.offset)
    }

    /// A click on the bare track: one screenful in the direction asked for,
    /// within the loaded map (the index bar never covers more than that).
    /// Near an edge it asks the feed for the next page, exactly as a wheel
    /// there would.
    private func pageBy(_ direction: Int) {
        guard direction != 0, viewportH > 0 else { return }
        // **From where the reader is, not from the camera's projection**:
        // paging is a scroll the person asked for.
        let target = max(0, readTop + Double(direction) * Double(viewportH))
        let order = feed.rows.map(\.id)
        // **The camera is written before the scroll** (R2-2), so the next
        // projection lands on the same place rather than undoing it.
        if let place = ControlRoomChatCamera.place(order: order, frames: frames, at: target) {
            camera.place = place
            camera.pinned = false
            feed.reading(anchor: place.id, offset: place.offset)
        } else if let first = order.first, let frame = frames[first] {
            // Above the first measured row (the list's own top padding): the
            // first row is the closest honest answer.
            let place = ControlRoomChatCamera.Place(
                id: first, offset: max(0, target - Double(frame.minY))
            )
            camera.place = place
            camera.pinned = false
            feed.reading(anchor: place.id, offset: place.offset)
        } else {
            camera.place = nil
            camera.pinned = true
        }
        clipSeen = nil
        syncClip("center")
        maintainWindow(fromInput: true)
    }

    /// **Where the viewport really is** (real-machine red, 2026-11-06): the
    /// clip origin, or the document's end while pinned. This is the input to
    /// every "how much page is left" question.
    ///
    /// **The camera is not an input here.** It says where a projection should
    /// put the viewport; reading its projection back as the viewport's place
    /// was a closed loop. One callback whose inverse was missed froze the
    /// camera, this number with it, and every tick then decided the older
    /// margin was short -- feeding older rows in front of a reader who was
    /// scrolling towards the newest, walking them to the very beginning.
    private var readTop: Double {
        ControlRoomChatWindow.viewportTop(
            pinned: camera.pinned,
            // The live height, not the cached one: a pinned top and the
            // content it is measured from must be the same moment.
            content: Double(liveDocumentHeight),
            viewport: Double(viewportH),
            offset: Double(offsetY)
        )
    }

    /// **The document's height, read now.** The cached `contentH` is only
    /// what a callback last said; a rows change does not move the clip
    /// origin, so no callback follows it and the cache goes stale against a
    /// live offset (the 2026-11-06 oscillation).
    private var liveDocumentHeight: CGFloat {
        scroll.documentHeight ?? contentH
    }

    /// What the camera would project, **for the disagreement log only**
    /// (review: a decision that reads this instead of `readTop` must not be
    /// silent about it).
    private func cameraTopY() -> Double {
        if camera.pinned { return max(0, Double(contentH - viewportH)) }
        if let place = camera.place,
           let y = ControlRoomChatCamera.y(of: place, frames: frames) {
            return y
        }
        return Double(offsetY)
    }

    /// A real live-scroll started (or a wheel burst): **the hand is on the
    /// list**. The anchor is written by the callback the move produces; this
    /// only starts the quiet check that finds the hand leaving.
    private func userTookScroll() {
        armQuietCheck()
    }

    /// **The hand has left the list.** With no momentum left, take one more
    /// step (review C, M6.2) -- the reader's next flick should not meet a
    /// page boundary.
    ///
    /// **One step, not a fill.** Every step changes an apron count, and the
    /// change handler queues the next one; a loop here would run several
    /// actions against one reading, which is the shape that made the
    /// document breathe (2026-11-06).
    private func handLeftTheList() {
        guard !scroll.userScrolling else {
            armQuietCheck()
            return
        }
        // **Momentum is still the reader**: `didEndLiveScroll` fires when the
        // fingers lift, not when the list stops.
        guard !scroll.readerMovedRecently else {
            armQuietCheck()
            return
        }
        maintainWindow(fromInput: false)
    }

    /// **A timer, not only the end notification**: a hand that rests on the
    /// trackpad without lifting never posts `didEndLiveScroll`. Each call
    /// invalidates the one before it, so a wheel burst queues one look.
    private func armQuietCheck() {
        quietToken &+= 1
        let token = quietToken
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ControlRoomChatScrollHandle.wheelWindow
        ) {
            guard quietToken == token else { return }
            if scroll.userScrolling || scroll.readerMovedRecently {
                armQuietCheck()
                return
            }
            handLeftTheList()
        }
    }

    /// **What one bounds callback was**: whether a hand was on the list, where
    /// the clip is, and what the view holds. The first twenty lines are always
    /// written -- a real-machine red is in the first few callbacks of a page
    /// -- and after that one line per change of the judgement.
    private func sayBounds(
        hand: Bool, y: CGFloat, content: CGFloat, delta: Double, branch: String
    ) {
        boundsLines &+= 1
        let seen = "\(hand)|\(camera.pinned)|\(Int(content))"
        guard boundsLines <= 20 || seen != lastBoundsSeen else { return }
        lastBoundsSeen = seen
        Self.windowLog.notice(
            "bounds: hand=\(hand ? 1 : 0, privacy: .public) branch=\(branch, privacy: .public) offset=\(Int(y), privacy: .public) delta=\(Int(delta), privacy: .public) content=\(Int(content), privacy: .public) doc=\(Int(self.currentDocumentBottom()), privacy: .public) contentH=\(Int(self.contentH), privacy: .public) live=\(Int(self.liveDocumentHeight), privacy: .public) viewer=\(self.handleAttached ? 1 : 0, privacy: .public) pinned=\(self.camera.pinned ? 1 : 0, privacy: .public) rows=\(self.feed.rows.count, privacy: .public) frames=\(self.frames.count, privacy: .public) n=\(self.boundsLines, privacy: .public)"
        )
    }

    /// One programmatic scroll, registered **before** the call so a
    /// synchronous bounds callback is not read as the reader. A scroll that
    /// moved nothing has no callback coming.
    ///
    /// **`sole` is the compensation's rule** (review C, M3): one insertion
    /// owes exactly one callback, and every target older than it is void --
    /// a leftover y is the place the reader's own scroll is about to reach.
    private func scrollProgrammatically(toY y: CGFloat, sole: Bool = false) {
        _ = sole
        _ = scroll.scroll(toY: y)
    }

    /// **The feed asks for blocks the size of this window and cannot measure
    /// it.** The count is the index bar's own coverage -- one algorithm, so
    /// the bar and the page the feed asks for cannot disagree about how tall
    /// a screen is. Written from callbacks only, never from `body`.
    private func publishViewportRows() {
        guard viewportH > 0, !frames.isEmpty else { return }
        // **The high-water mark is kept here, not in `body`**: a body pass may
        // read it but must not write it. This runs from every callback that
        // moves the viewport, which is every moment the mark could advance.
        let plan = listPlan
        let documentNow = Double(documentBottom(plan: plan, layout: scrollLayout(plan)))
        let depthNow = ControlRoomChatIndexBar.topPoints(
            documentBottom: documentNow, offset: Double(offsetY)
        )
        if barReachedSeeded {
            barReached = ControlRoomChatIndexBar.reached(previous: barReached, top: depthNow)
        } else if !plan.isEmpty {
            // **Seeded on the first plan that exists**, not on the frame
            // before it: an empty plan's `documentBottom` is the padding, and
            // taking that would freeze the bar at 24 points for the session.
            barReached = depthNow
            barReachedSeeded = true
        }
        guard let covered = ControlRoomChatIndexBar.viewportTicks(
            order: feed.rows.map(\.id),
            frames: frames,
            offset: Double(offsetY),
            viewport: Double(viewportH)
        ) else { return }
        let rows = max(1, Int(covered))
        feed.viewportMeasured = true
        guard rows != feed.viewportRows else { return }
        feed.viewportRows = rows
    }

    /// **The page that could not be read has to say so somewhere.** The
    /// boundary row that used to say it is gone with the rest of them, so
    /// the index bar carries it: a mark at the top of the track and one
    /// sentence in its bubble, which moves nothing and blocks nothing.
    private var olderNotice: String? {
        switch feed.older {
        case .failed:
            return String(localized: "Earlier records could not be read.",
                          comment: "总控台：群聊页，更早记录读取失败（索引条提示）")
        case .gap:
            return String(localized: "Some earlier records could not be read.",
                          comment: "总控台：群聊页，更早记录有损坏（索引条提示）")
        case .idle, .loading, .scanning, .atEnd, .cancelled:
            // **A cancellation says nothing.** It is the state `stop()`
            // leaves behind, so a page shown again would carry a sentence
            // about the session before it -- and a reader who stopped the
            // scan already knows.
            return nil
        }
    }

    /// The person's index bar (task 3002). It reads the same frames and the
    /// same bounds every other rule here reads, and asks for nothing but a
    /// scroll: no page, no group, no window.
    @ViewBuilder
    private func indexBar(_ theme: Look.Theme, height: CGFloat) -> some View {
        if !feed.rows.isEmpty, height > 0 {
            let order = feed.rows.map(\.id)
            // **The bar speaks in points now** (design §23.3). `total` is the
            // document's own depth today; the reader's high-water mark
            // replaces it in the next step, and until then an eviction still
            // shortens the bar.
            let documentNow = Double(documentBottom(plan: listPlan, layout: scrollLayout(listPlan)))
            // **The total is the high-water mark**, not the document: a
            // document that sheds rows must not shrink the bar. `max` with
            // today's depth covers the frame between a scroll and the
            // callback that records it, and stays monotonic.
            let total = max(barReached, ControlRoomChatIndexBar.topPoints(
                documentBottom: documentNow, offset: Double(offsetY)
            ))
            // **R1-14: the bar's top reads the camera**, not the projected
            // pixel. The appearance is the same position; the source stops it
            // lagging a frame behind while a projection is owed. `pinned` has
            // no place to read, so the pixel-derived depth stands there.
            let depth = cameraDepth(order: order, frames: frames, documentBottom: documentNow)
                ?? ControlRoomChatIndexBar.topPoints(
                    documentBottom: documentNow, offset: Double(offsetY)
                )
            let covered = ControlRoomChatIndexBar.viewportPoints(
                viewport: Double(viewportH),
                documentBottom: documentNow,
                offset: Double(offsetY)
            )
            let trackH = max(0, height - 16)
            let shape = ControlRoomChatIndexBar.geometryPoints(
                totalPoints: total,
                viewportPoints: covered,
                depthPoints: depth,
                trackH: trackH
            )
            // **One line per change, not per frame** (the person's debugging
            // aid): a bar that moves while `chat-window`'s decision does not
            // is the bar's own jitter; both moving is the feed's rows.
            let signature = barSignature(
                depth: depth, total: total, covered: covered, shape: shape
            )
            ControlRoomChatIndexBarView(
                totalPoints: total,
                depthPoints: depth,
                viewportPoints: covered,
                trackH: trackH,
                theme: theme,
                mapEpoch: mapEpoch,
                notice: olderNotice,
                time: { atDepth in
                    guard let index = nearestMessageIndex(
                        order: order, documentY: documentNow - atDepth
                    ) else { return "" }
                    return ControlRoomChatPresentation.timeText(
                        atMs: feed.rows[index].message.atMs)
                },
                onSeek: seek(toDepth:),
                onPage: pageBy
            )
            .padding(.trailing, ControlRoomChatIndexBar.trackInset)
            .padding(.vertical, 8)
            .onAppear {
                sayBar(depth: depth, total: total, covered: covered, shape: shape)
            }
            .onChange(of: signature) { _ in
                sayBar(depth: depth, total: total, covered: covered, shape: shape)
            }
        }
    }

    /// What the bar draws, quantised so a sub-pixel wobble is not a change.
    private func barSignature(
        depth: Double,
        total: Double,
        covered: Double,
        shape: ControlRoomChatIndexBar.PointGeometry
    ) -> String {
        [
            String(Int(depth.rounded())), String(Int(total.rounded())),
            String(Int(shape.thumbY.rounded())),
            String(Int(shape.thumbH.rounded())),
            String(Int(covered.rounded())),
        ].joined(separator: "|")
    }

    /// **The index bar's one line** (the person's debugging aid): beside
    /// `chat-window`, it separates "the bar is moving" from "the feed's rows
    /// are". `content` is read live, the same number the window decision
    /// uses.
    /// **Two units on one line, told apart by their names** (design §23.3):
    /// `topP` / `totalP` / `viewP` are **points**; `thumbY` / `offset` /
    /// `content` are **pixels**. `ticks=` used to sit here and would now mean
    /// points while still saying ticks -- the kind of name this file has been
    /// bitten by before.
    private func sayBar(
        depth: Double,
        total: Double,
        covered: Double,
        shape: ControlRoomChatIndexBar.PointGeometry
    ) {
        Self.barLog.notice(
            "chat-bar: topP=\(Int(depth.rounded()), privacy: .public) totalP=\(Int(total.rounded()), privacy: .public) thumbY=\(Int(shape.thumbY.rounded()), privacy: .public)/\(Int(shape.thumbH.rounded()), privacy: .public) viewP=\(Int(covered.rounded()), privacy: .public) offset=\(Int(self.offsetY), privacy: .public) content=\(Int(self.liveDocumentHeight), privacy: .public)"
        )
    }

    // MARK: - Boundaries

    @ViewBuilder
    private func contextNewerBoundary(_ theme: Look.Theme) -> some View {
        if let context = feed.context {
            HStack(spacing: 8) {
                if feed.contextNewerStale {
                    Text(String(localized: "This direction's edge was released.",
                                comment: "总控台：群聊页，定位窗口的更新方向已失效"))
                    Button(String(localized: "Re-anchor here",
                                  comment: "总控台：群聊页，用保留边缘重新定位")) {
                        feed.reanchorNewer()
                    }
                    .buttonStyle(.link)
                } else if !context.newerAtEnd {
                    Button(String(localized: "Later context",
                                  comment: "总控台：群聊页，加载定位窗口更晚的上下文")) {
                        feed.loadContextNewer()
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity)
        }
    }

    private func line(_ theme: Look.Theme) -> some View {
        Rectangle()
            .fill(theme.textSecondary.color.opacity(0.18))
            .frame(height: Look.Line.hairline)
    }

    /// **The window released a run of records here.** The two rows on either
    /// side are not neighbours in the conversation; this boundary says so and
    /// offers the only recovery the frozen core contract allows -- start the
    /// body again from the newest records.
    private func gapBoundary(
        _ theme: Look.Theme,
        gap: ControlRoomChatPresentation.Gap
    ) -> some View {
        HStack(spacing: 8) {
            line(theme)
            Text(gapLabel(gap))
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textTertiary.color)
                .fixedSize()
            Button(String(localized: "Reload from newest",
                          comment: "总控台：群聊页，从最新记录重载并清除缺口")) {
                feed.reloadClearingGap()
            }
            .buttonStyle(.link)
            .font(.system(size: Look.Font.min))
            line(theme)
        }
        .frame(maxWidth: .infinity)
    }

    /// **The conversation's real end, drawn as a mark and nothing else**
    /// (task 3016 R4, review C's M7). It is in the plan, not in `feed.rows`:
    /// it is not a row the window counts, trims or prefetches against, and
    /// it asks for nothing -- 3002's "load earlier" was a control, and this
    /// is not that.
    private func endBoundary(_ theme: Look.Theme, _ text: String) -> some View {
        HStack(spacing: 10) {
            line(theme)
            Text(text)
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textTertiary.color)
                .fixedSize()
            line(theme)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(text)
    }

    private func gapLabel(_ gap: ControlRoomChatPresentation.Gap) -> String {
        switch gap {
        case .before:
            return String(localized: "Earlier records were released.",
                          comment: "总控台：群聊页，更早记录已被窗口释放")
        case .after:
            return String(localized: "Some records were released here.",
                          comment: "总控台：群聊页，窗口释放了一段记录")
        }
    }

    private func dayDivider(_ atMs: Int64, _ theme: Look.Theme) -> some View {
        HStack(spacing: 10) {
            line(theme)
            Text(ControlRoomChatPresentation.dateText(atMs: atMs, nowMs: nowMs))
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textTertiary.color)
                .fixedSize()
            line(theme)
        }
        .padding(.vertical, 2)
    }

    /// **A located page**: its window is another map, and its own way out is
    /// a different action from "scroll to the bottom of this one". The
    /// context arrives a moment after the locate, so the anchor counts too.
    private var isLocated: Bool {
        feed.context != nil || feed.locatedAnchor != nil
    }

    /// **`atBottom` is derived, never a third copy of the truth** (R1-7):
    /// pinned means the bottom; away from it, a camera standing on the last
    /// row is the bottom too.
    private var atBottom: Bool {
        if camera.pinned { return true }
        // **A pixel answer, not "the camera is on the last row"** (A2 S3):
        // the viewport's top can be inside the last row while a screenful of
        // it is still below, and the old rule then hid the "new messages"
        // pill.
        guard let place = camera.place,
              let y = ControlRoomChatCamera.y(of: place, frames: frames)
        else { return false }
        guard viewportH > 0, contentH > 0 else { return false }
        return Double(contentH) - (y + Double(viewportH)) <= 2
    }

    /// The index bar's top tick from the camera (R1-14): the row's index plus
    /// how far into it the reader is, in row heights. `nil` while pinned (the
    /// bottom is not a position in the map) or while the place is unmeasured.
    /// **The camera's own depth**, in points below the document's bottom.
    /// The point-space answer to the row tick this used to return: same
    /// source (the camera, not the projected pixel), same reason -- the bar
    /// must not lag a frame behind while a projection is owed.
    private func cameraDepth(
        order: [String], frames: [String: CGRect], documentBottom: Double
    ) -> Double? {
        guard !camera.pinned, let place = camera.place,
              let y = ControlRoomChatCamera.y(of: place, frames: frames)
        else { return nil }
        return max(0, documentBottom - y)
    }

    /// **The row nearest a document y** -- the last row whose bottom is below
    /// it, which is the same rule `place(order:frames:at:)` uses. A point is
    /// not a message, so this is the only mapping the bar's clocks and drags
    /// can use.
    private func nearestMessageIndex(order: [String], documentY: Double) -> Int? {
        guard !order.isEmpty else { return nil }
        for (index, id) in order.enumerated() {
            guard let frame = frames[id], frame.maxY > documentY else { continue }
            return index
        }
        return order.indices.last
    }

    private func jumpPill(_ theme: Look.Theme) -> some View {
        let located = isLocated
        return Button {
            // The person asked for the bottom: an explicit intent, not a
            // scroll position this view guessed.
            newBelow = false
            // **R1-8: "latest" has two meanings.** A located window is
            // another map, so the page goes back to the live tail first and
            // pins when that map lands (`rowsChanged`); an ordinary page
            // pins now -- after the window itself has been rebuilt around
            // the newest rows (R4): with a ±6-screen window the document's
            // end is not the conversation's end while the newer apron
            // still holds rows, and pinning to the document's bottom would
            // stop short of the newest message. Neither goes through
            // `jump` -- there is no id.
            if located {
                pendingReturnToLatest = true
                feed.returnToLatest()
            } else {
                feed.goToLatest()
                camera.place = nil
                camera.pinned = true
                syncClip("content")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                Text(located
                    ? String(localized: "Return to latest",
                             comment: "总控台：群聊页，退出定位回到最新")
                    : newBelow
                        ? String(localized: "New messages · jump to latest",
                                 comment: "总控台：群聊页，有新消息且不在底部")
                        : String(localized: "Jump to latest",
                                 comment: "总控台：群聊页，回到最新"))
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.text.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.terminalBackground.color)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.textSecondary.color.opacity(0.25), lineWidth: Look.Line.hairline)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }
}

// MARK: - Row frames

/// **What a landing screen shows before its Markdown exists** (design §26).
///
/// The numbers are look-table numbers, not estimates:
/// `Look.Font.min` is 13 pt and a text line is 16; the row stack's spacing is
/// 4 and the row pads 4 above and below. So the body block is three lines and
/// the row it makes is `16 + 4 + 48 + 8 = 76`.
enum ControlRoomChatPlaceholder {
    /// The body block: three text lines.
    static let bodyHeight: CGFloat = 48
    /// The whole row a placeholder makes, used to answer "how many rows is
    /// one screen" before anything has been measured.
    static let rowHeight: CGFloat = 16 + 4 + bodyHeight + 8
    /// **How long a landing may wait for its rows.** The real measurements of
    /// `pending -> markdown` are p50 9 ms / p99 308 ms / max 495 ms, so this
    /// is "the slowest row still arrives"; longer and the landing reads as
    /// stuck.
    static let cap: TimeInterval = 0.6
}

/// The plan behind `CHAT_AUTO_SCROLL`.
private final class ControlRoomChatAutoScroll {
    /// About one text line a step, so the window moves the way a wheel moves
    /// it rather than jumping a screen at a time.
    /// **The speed is settable** (`CHAT_AUTO_SCROLL_STEP`, `CHAT_AUTO_SCROLL_MS`),
    /// because the two regimes are different problems: 40 pt every 30 ms is a
    /// steady wheel and it is what every reading up to 2026-11-07 15:00 was
    /// taken at, while a trackpad flick travels several times faster and
    /// arrives in bursts. A criterion measured at 1 330 pt/s says nothing
    /// about a flick, and reading it as if it did is how a day of work gets
    /// aimed at the wrong thing.
    static let step: Double = Double(
        ProcessInfo.processInfo.environment["CHAT_AUTO_SCROLL_STEP"] ?? ""
    ) ?? 40
    /// Whether the driver's moves reach the view without the wheel signal --
    /// the state a real wheel is in when its pointer is outside the list.
    static let silentWheel =
        ProcessInfo.processInfo.environment["CHAT_AUTO_SCROLL_NO_WHEEL"] == "1"
    /// 30 ms between steps: a steady scroll, not a fling.
    static let interval: TimeInterval = {
        let ms = Double(ProcessInfo.processInfo.environment["CHAT_AUTO_SCROLL_MS"] ?? "")
        return (ms.map { $0 / 1000 } ?? 0.03)
    }()

    /// Negative moves towards older rows (the document's y decreases), which
    /// is what a wheel towards the top does.
    var direction: Double
    var remaining: Double
    /// Points to travel back after the first leg; 0 is a one-way run.
    let back: Double
    /// 0 is the first leg, 1 the way back.
    var leg = 0
    var steps = 0
    /// How many ten-millisecond deadlines passed before the list was ready.
    var waits = 0
    var moved: Double = 0
    var last: Double?
    var monotonic = true
    var cancelled = false

    init(points: Double, back: Double) {
        direction = points < 0 ? 1 : -1
        remaining = abs(points)
        self.back = back
    }
}

/// One scroll the view asked for: where, and when, so its own callback is
/// not read as a hand's.
struct ControlRoomChatNativeOwnScroll {
    var y: Double
    var at: TimeInterval
    /// **The surface's first placement, not one of the view's projections.**
    /// It is the one that has to be recognised as `ours`, and the one whose
    /// matching is logged (the 2026-11-07 "opens in the middle": 2 of 13
    /// openings read this placement as a hand and lost `pinned`).
    var start = false
}

struct RowFramesPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - The scroll view's own number

/// A handle to the `NSScrollView` SwiftUI's `ScrollView` is built on. **A
/// handle and not a second scroll view**: setting this one's clip origin is
/// the same act as a wheel event, so the list keeps its laziness and its
/// identity while the view can still put the viewport back on a message.
final class ControlRoomChatScrollHandle: ObservableObject {
    weak var scrollView: NSScrollView?
    weak var probe: AnyObject?
    /// Set by the scroll view's own live-scroll notifications, which is the
    /// real signal that a person is moving it (not "not programmatic").
    var userScrolling = false
    /// **The second signal, for the wheels the live scroll does not report.**
    /// When a wheel event last reached this scroll view, on
    /// `ProcessInfo.processInfo.systemUptime`'s clock -- the same clock the
    /// view reads it with, so no event timestamp crosses a clock here.
    private(set) var lastWheelAt: TimeInterval = 0
    /// **The one scroll the view has asked for and not yet seen.**
    ///
    /// **On this object, not in the view's `@State`** (the 2026-11-07 entry
    /// run: the surface's first placement registered at `19:57:58.236`, and
    /// the bounds callback one millisecond later -- same y, `|Δ| = 0`,
    /// `dt = 1 ms` -- found no registration at all, so the placement was read
    /// as a hand and wrote an anchor from a document that did not exist yet).
    /// `registerStartPosition` runs inside `updateNSView`, i.e. during a view
    /// update, and a `@State` written there is bookkeeping the reader may not
    /// see. This is a stored property on the object both sides already share;
    /// `userScrolling` next door is written the same way for the same reason.
    var ownScroll: ControlRoomChatNativeOwnScroll?
    /// The window a wheel still counts as "the reader is moving". Also the
    /// wait before a restore the hand interrupted is taken back.
    static let wheelWindow: TimeInterval = 0.3

    /// Whether a wheel is moving this list now, or did within the window a
    /// bounds callback arrives in.
    var readerMovedRecently: Bool {
        readerMovedRecently(now: ProcessInfo.processInfo.systemUptime)
    }

    func readerMovedRecently(now: TimeInterval) -> Bool {
        guard lastWheelAt > 0, now >= lastWheelAt else { return false }
        return now - lastWheelAt <= Self.wheelWindow
    }

    /// A wheel event reached this scroll view. Says whether it began a burst
    /// -- the view voids what it owed on the first event, not on every one.
    @discardableResult
    func noteWheel(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let began = !readerMovedRecently(now: now)
        lastWheelAt = now
        return began
    }

    /// The scroll view is gone: a wheel that reached the old one says nothing
    /// about the new one.
    func forgetWheel() {
        lastWheelAt = 0
    }

    /// **The momentum phase has ended: the reader's hand is off** (M6). The
    /// 0.3 s window exists for hands that stop without lifting; an explicit
    /// end needs no wait, and waiting made a projection land while the list
    /// was still decelerating.
    func endMomentum(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastWheelAt = 0
    }

    /// **Whether a wheel event counts as the reader moving this list.** A
    /// momentum event is window-wide -- the pointer may be anywhere -- so it
    /// counts regardless of where the cursor is (M6). A plain wheel must land
    /// on the scroll view.
    static func wheelCounts(momentum: Bool, pointerInside: Bool) -> Bool {
        momentum || pointerInside
    }

    var isVisible: Bool {
        (probe as? ControlRoomChatScrollProbe.Probe)?.reallyVisible() ?? false
    }

    /// **The document's height as the scroll view has it now**, not as a
    /// callback last reported it. The window's arithmetic compares this with
    /// a live offset; reading the cached value instead put the two numbers a
    /// rows change apart and made the document breathe (2026-11-06).
    var documentHeight: CGFloat? {
        scrollView?.documentView?.frame.height
    }

    /// **The farthest the clip origin may go right now**, which is what the
    /// scroll clamp will allow. A compensation paid before the layout has
    /// made room would be eaten by it.
    var maximumOriginY: CGFloat? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        return max(0, document.frame.height - scrollView.contentView.bounds.height)
    }

    /// The clip origin as it is now, not as a callback last said.
    var originY: CGFloat? {
        scrollView?.contentView.bounds.origin.y
    }

    /// How far into the message the reader was, in the scroll view's own
    /// content coordinates.
    @discardableResult
    func scroll(toY y: CGFloat) -> CGFloat? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let maximum = max(0, document.frame.height - scrollView.contentView.bounds.height)
        let target = min(max(0, y), maximum)
        guard abs(target - scrollView.contentView.bounds.origin.y) > 0.5 else { return nil }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return target
    }
}

/// Reports the enclosing scroll view's content offset, viewport height and
/// document height. It draws nothing and sits inside the scroll content so
/// that `enclosingScrollView` finds the one SwiftUI made.
private struct ControlRoomChatScrollProbe: NSViewRepresentable {
    var handle: ControlRoomChatScrollHandle
    /// Called when the probe has found a scroll view, and when it has lost
    /// one. The view holds a bottom it owes until this says `true`.
    var onAttach: (Bool) -> Void
    var onVisible: (Bool) -> Void
    var onUserScroll: (() -> Void)?
    /// The live scroll ended (fingers lifted). **Not the same as the hand
    /// having left the list**: momentum keeps moving it, so the view checks
    /// the wheel window before doing anything.
    var onUserScrollEnd: (() -> Void)?
    var report: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.handle = handle
        probe.onAttach = onAttach
        probe.onVisible = onVisible
        probe.onUserScroll = onUserScroll
        probe.onUserScrollEnd = onUserScrollEnd
        probe.report = report
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.handle = handle
        view.onAttach = onAttach
        view.onVisible = onVisible
        view.onUserScroll = onUserScroll
        view.onUserScrollEnd = onUserScrollEnd
        view.report = report
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.detachNow()
    }

    final class Probe: NSView {
        weak var handle: ControlRoomChatScrollHandle?
        var onAttach: ((Bool) -> Void)?
        var onVisible: ((Bool) -> Void)?
        var onUserScroll: (() -> Void)?
        var onUserScrollEnd: (() -> Void)?
        var report: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private var observer: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?
        private var liveObservers: [NSObjectProtocol] = []
        /// The wheel monitor: a reader signal that does not go through the
        /// live-scroll notifications (task 2999 ③).
        private var wheelMonitor: Any?
        /// One pending attach at most, and only the latest move may do it.
        private var ledger = ControlRoomChatAnchor.AttachLedger()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let generation = ledger.moved(inWindow: window != nil)
            // **The old observer goes first.** A view moved between windows
            // would otherwise leave one listening to a clip view it is no
            // longer in, and every move would add another.
            detachObserver()
            guard let window else {
                ledger.invalidate()
                onAttach?(false)
                onVisible?(false)
                return
            }
            observeOcclusion(window)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attach(generation: generation)
            }
        }

        private func attach(generation: UInt64) {
            guard let scrollView = enclosingScrollView else { return }
            let clip = String(describing: ObjectIdentifier(scrollView.contentView))
            guard ledger.mayAttach(
                generation: generation, inWindow: window != nil, clip: clip
            ) else { return }
            handle?.scrollView = scrollView
            handle?.probe = self
            handle?.userScrolling = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.publish()
            }
            for (name, value) in [
                (NSScrollView.willStartLiveScrollNotification, true),
                (NSScrollView.didLiveScrollNotification, true),
                (NSScrollView.didEndLiveScrollNotification, false),
            ] {
                liveObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: scrollView, queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.handle?.userScrolling = value
                    if value { self.onUserScroll?() } else { self.onUserScrollEnd?() }
                })
            }
            // **A plain mouse wheel does not always start a live scroll**,
            // so the live-scroll notifications alone cannot say whether the
            // reader moved the list. Only a wheel that lands on this scroll
            // view counts; the first event of a burst voids the follow or
            // restore the view still owed (task 2999 ③).
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.noteWheel(event)
                return event
            }
            ledger.attached(clip, generation: generation)
            onAttach?(true)
            onVisible?(window?.occlusionState.contains(.visible) == true)
            publish()
        }

        private func publish() {
            guard let scrollView = enclosingScrollView,
                  let document = scrollView.documentView
            else { return }
            report?(
                scrollView.contentView.bounds.origin.y,
                scrollView.contentView.bounds.height,
                document.frame.height
            )
        }

        /// A wheel event arrived somewhere in this window: only one that
        /// lands on the scroll view this probe belongs to is the reader
        /// moving *this* list -- **except momentum, which is window-wide**
        /// (M6). A pointer that drifts off the list mid-fling used to stop
        /// refreshing the reader signal, so the gate opened 0.3 s later while
        /// the list was still decelerating and a projection landed under it.
        private func noteWheel(_ event: NSEvent) {
            guard let scrollView = enclosingScrollView,
                  event.window === scrollView.window
            else { return }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            let momentum = event.momentumPhase != []
            guard ControlRoomChatScrollHandle.wheelCounts(
                momentum: momentum,
                pointerInside: scrollView.bounds.contains(point)
            ) else { return }
            if event.momentumPhase == .ended {
                // **The fling is over**: no window, the gate may open now.
                handle?.endMomentum()
                onUserScrollEnd?()
                return
            }
            if handle?.noteWheel() == true { onUserScroll?() }
        }

        /// **The live answer**, not a cached flag: a hidden host or a hidden
        /// ancestor means nothing here scrolls.
        func reallyVisible() -> Bool {
            guard let window, window.occlusionState.contains(.visible) else { return false }
            var view: NSView? = self
            while let current = view {
                if current.isHidden { return false }
                view = current.superview
            }
            return true
        }

        /// Idempotent: an observer and a handle, or neither.
        func detachNow() {
            detachObserver()
            // **A queued attach from this view's life is void now.**
            ledger.invalidate()
            onAttach?(false)
            onVisible?(false)
        }

        private func detachObserver() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
                self.occlusionObserver = nil
            }
            if let wheelMonitor {
                NSEvent.removeMonitor(wheelMonitor)
                self.wheelMonitor = nil
            }
            for item in liveObservers { NotificationCenter.default.removeObserver(item) }
            liveObservers = []
            handle?.scrollView = nil
            handle?.probe = nil
            handle?.userScrolling = false
            handle?.forgetWheel()
            ledger.detach()
        }

        private func observeOcclusion(_ window: NSWindow) {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.onVisible?(self.window?.occlusionState.contains(.visible) == true)
            }
        }

        deinit {
            detachNow()
        }
    }
}

/// One message: its author (or the handover label), role, channel, local
/// time, the terminals it named, and its body.
///
/// **The demand is this row's, and it is registered where the row appears.**
/// `registered` remembers the generation the demand was made under, so the
/// release that follows a page change carries the old generation; the store
/// ignores that release and the new page's demand stays. Repeated `onAppear`
/// is idempotent in the store.
private struct ControlRoomNativeChatRow: View {
    typealias Look = ControlRoomLook

    var row: ControlRoomChatFeed.Row
    var group: String
    var generation: UInt64
    @ObservedObject var markdown: ControlRoomChatMarkdownStore
    /// **This row is on a landing screen that has not settled** (design §26):
    /// its body is drawn as a fixed block until its form stops changing.
    var placeholder: Bool = false
    /// The search hit this row was located to, when it is the located one.
    var hit: ControlRoomChatSearch.Hit?
    var onReference: ((ControlRoomChatData.Message, String?) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var registered: UInt64?
    private static let formLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-form"
    )

    /// **The form this row is drawn in, and the reason** (design §22, I1):
    /// `plain`, `pending`, `deferred` and `markdown` are different heights,
    /// and a row that flips between them while its content does not is a
    /// measured height that is not a function of its identity -- the 2026-11-07
    /// stuck red (`p:978` at 46 and 64 within 30 ms).
    private var form: String {
        "\(markdown.form(id: row.id, group: group, generation: generation)) gen=\(generation)/\(markdown.formGeneration)"
    }

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(alignment: .leading, spacing: 4) {
            header(theme)
            if let mentions = row.message.mentions, !mentions.isEmpty {
                mentionsRow(mentions, theme)
            }
            if placeholder, !ControlRoomChatMarkdownStore.isSettled(
                form: markdown.form(id: row.id, group: group, generation: generation)
            ) {
                placeholderBlock
            } else {
                content
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(row.message.summary ? theme.textSecondary.color.opacity(0.10) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Look.Radius.row))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            register(generation)
            Self.formLog.notice(
                "form: id=\(self.row.id, privacy: .public) \(self.form, privacy: .public)"
            )
        }
        .onChange(of: form) { newForm in
            Self.formLog.notice(
                "form: id=\(self.row.id, privacy: .public) \(newForm, privacy: .public)"
            )
        }
        .onDisappear { unregister() }
        // **The value the modifier hands over, not this view's own
        // `generation`.** SwiftUI calls the action bound to the view it is
        // replacing, whose `generation` is still the old one; asking the
        // store under that value was refused and nothing asked again (task
        // 2994, measured on the real app: `row reacquire ... gen=3` while
        // the page and the store were already on 4).
        .onChange(of: generation) { newGeneration in
            reacquire(generation: newGeneration)
        }
        .onChange(of: row.message.contentVersion) { _ in
            reacquire(generation: generation)
        }
    }

    private var authorText: String {
        // One rule with the speaker above the row: the list's rule compares
        // the same name the row draws.
        ControlRoomChatPresentation.authorText(
            author: row.message.author,
            fromSelf: row.message.fromSelf
        )
    }

    private func header(_ theme: Look.Theme) -> some View {
        HStack(spacing: 6) {
            if row.message.summary {
                tag(ControlRoomChatPresentation.summaryText(), theme: theme)
            } else {
                let author = authorText
                if !author.isEmpty {
                    Text(author)
                        .font(.system(size: Look.Font.min, weight: .semibold))
                        .foregroundStyle(theme.text.color)
                }
            }
            if let role = row.message.role, !role.isEmpty {
                chip(role, theme: theme, strong: false)
            }
            chip(
                ControlRoomChatPresentation.channelText(channel: row.message.channel),
                theme: theme,
                strong: row.message.channel != 0
            )
            Text(ControlRoomChatPresentation.timeText(atMs: row.message.atMs))
                .font(.system(size: Look.Font.min))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
        }
    }

    private func mentionsRow(
        _ mentions: [ControlRoomChatData.Mention],
        _ theme: Look.Theme
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(mentions.enumerated()), id: \.offset) { _, mention in
                Text(ControlRoomChatPresentation.mentionText(mention))
                    .font(.system(size: Look.Font.min))
                    .foregroundStyle(theme.text.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.textSecondary.color.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 0)
        }
    }

    /// **A fixed block where the body will be** (design §26): a constant
    /// height, never an estimate -- a height taken from `rowHeightEstimate`
    /// would be the "one number multiplied by every row" defect of §25 again.
    /// Three text lines, with the material saying "not developed yet" rather
    /// than a grey rectangle.
    private var placeholderBlock: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(maxWidth: .infinity)
            .frame(height: ControlRoomChatPlaceholder.bodyHeight)
            .overlay(alignment: .leading) {
                Text(verbatim: "…")
                    .font(.system(size: Look.Font.min))
                    .foregroundStyle(Look.theme(scheme).textSecondary.color.opacity(0.55))
                    .padding(.leading, 8)
            }
            .accessibilityLabel(Text("loading"))
    }

    private func tag(_ text: String, theme: Look.Theme) -> some View {
        Text(text)
            .font(.system(size: Look.Font.min, weight: .semibold))
            .foregroundStyle(theme.text.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.textSecondary.color.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func chip(_ text: String, theme: Look.Theme, strong: Bool) -> some View {
        Text(text)
            .font(.system(size: Look.Font.min))
            .foregroundStyle(strong ? theme.text.color : theme.textSecondary.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.textSecondary.color.opacity(strong ? 0.16 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func register(_ generation: UInt64) {
        markdown.acquire(row.id, group: group, generation: generation)
        registered = generation
    }

    private func unregister() {
        guard let registered else { return }
        markdown.release(row.id, group: group, generation: registered)
        self.registered = nil
    }

    /// A new generation or a new version of this message is a new demand.
    /// The old one is released with **the generation it was made under**, so
    /// a page that has already moved on cannot be released by this row.
    private func reacquire(generation: UInt64) {
        unregister()
        register(generation)
    }

    @ViewBuilder
    private var content: some View {
        switch markdown.content(
            id: row.id,
            group: group,
            generation: generation,
            text: row.message.text
        ) {
        case let .markdown(document):
            ControlRoomChatMarkdownView(
                document: document,
                highlight: hit.flatMap {
                    ControlRoomChatDisplayHighlight.plan(message: row.message, hit: $0)
                },
                onLink: onReference.map { handler in
                    { url in
                        if let scheme = url.scheme?.lowercased(),
                           ["http", "https", "mailto"].contains(scheme) {
                            handler(row.message, url.absoluteString)
                        } else {
                            // **No fallback to the converted URL**: nil means
                            // the exact raw destination could not be
                            // identified, and the page refuses it.
                            handler(
                                row.message,
                                ControlRoomChatRawReference.destination(
                                    for: url, in: row.message.text
                                )
                            )
                        }
                    }
                }
            )
        case let .pending(text):
            plain(text) {
                Text(String(localized: "Formatting…", comment: "总控台：群聊页，Markdown 尚未解析完成"))
            }
        case let .deferredBudget(text):
            plain(text) {
                Text(String(localized: "Showing the original text",
                            comment: "总控台：群聊页，解析预算不足时显示原文"))
            }
        case let .plain(text):
            plain(text) { EmptyView() }
        }
    }

    private func plain<Note: View>(_ text: String, @ViewBuilder note: () -> Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: Look.Font.min))
                .textSelection(.enabled)
            note()
                .font(.system(size: Look.Font.min))
                .foregroundStyle(.secondary)
        }
    }
}

/// The chat page's left half: the fixed header, the group's messages, and
/// the reason there are none when there is one (task 2791; the first
/// screen's loading/empty/gap/error states, task 2800 S2c-2a and task 2969 B).
///
/// **It draws and does nothing else** except ask the feed to try again when
/// the feed itself says a stopped load may be retried. It does not start or
/// stop the feed: which group is in front, and whether anybody can see it,
/// are things only the container knows (`ControlRoomChatContainer.show` and
/// its `applyVisibility`), and a second owner here would be two answers
/// about whether the page is asking the core.
///
/// ⚠️ **Loading is not empty.** A pending history poll is a page that has
/// not answered yet; drawing "no messages" then would say the group is
/// empty and then take it back a moment later. The states are drawn apart:
/// loading while a page is out, `.cancelled` as itself, `.gap` when the scan
/// ended over damaged records or after its range restarted, the empty
/// sentence only once a clean end answered with no rows, and the core's own
/// refusal as it came.
struct ControlRoomNativeChatPane: View {
    typealias Look = ControlRoomLook

    var group: String
    @ObservedObject var feed: ControlRoomChatFeed
    /// The group's search, for **the hit the window was located to**. The
    /// search feed owns the hits; the page tells this pane which message is
    /// the located one, and this reads that hit's offsets. Nil in a build
    /// without the core's door.
    var search: ControlRoomChatSearchFeed? = nil
    var onSearch: (() -> Void)? = nil
    var onReference: ((ControlRoomChatData.Message, String?) -> Void)? = nil

    /// The hit behind `feed.locatedAnchor`, if the search still holds it.
    private var locatedHit: ControlRoomChatSearch.Hit? {
        guard let anchor = feed.locatedAnchor else { return nil }
        return search?.state.hits.first { $0.message.anchor == anchor }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ControlRoomChatHeader(group: group, feed: feed, onSearch: onSearch)
            if let trouble = feed.trouble {
                Text(trouble)
                    .font(.system(size: Look.Font.min))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .textSelection(.enabled)
            }
            // **The list exists even with no rows.** Choosing between the
            // list and a placeholder destroys `ControlRoomNativeChatView`
            // when a reload clears the window (`reloadClearingGap` →
            // `clearWindow`), taking the keeper, the frames and the scroll
            // handle with it -- and the new view's `onAppear` then drops to
            // the bottom. That is one of the two ways the blank chat was
            // made, and it also made loading visible as a remount. The empty
            // states are drawn *over* the list instead.
            ControlRoomNativeChatView(
                feed: feed, locatedHit: locatedHit, onReference: onReference
            )
            .overlay(alignment: .topLeading) {
                if feed.rows.isEmpty { placeholder }
            }
            if feed.canReload {
                Button {
                    feed.reload()
                } label: {
                    Text(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮"))
                        .font(.system(size: Look.Font.min))
                }
                .buttonStyle(.link)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel(group)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch feed.state {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Loading chat history…",
                                comment: "总控台：群聊页，正在加载聊天记录"))
                    if feed.older == .loading || feed.older == .scanning {
                        Button(String(localized: "Cancel", comment: "总控台：群聊页，取消更早记录加载")) {
                            feed.cancelOlder()
                        }
                        .buttonStyle(.link)
                    }
                }
            case .empty:
                Text(String(localized: "No messages yet.", comment: "总控台：群聊页，历史与实时都没有消息"))
            case .cancelled:
                HStack(spacing: 8) {
                    Text(String(localized: "Loading was cancelled.",
                                comment: "总控台：群聊页，首次读取被取消"))
                    Button(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮")) {
                        feed.reload()
                    }
                    .buttonStyle(.link)
                }
            case .gap:
                HStack(spacing: 8) {
                    Text(String(localized: "Some chat records could not be read.",
                                comment: "总控台：群聊页，历史扫描有坏记录或范围已重置"))
                    Button(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮")) {
                        feed.reload()
                    }
                    .buttonStyle(.link)
                }
            case .failed, .ready:
                // The refusal is drawn above; a failed load with no rows has
                // nothing else to say, and a ready page with no rows is empty.
                EmptyView()
            }
        }
        .font(.system(size: Look.Font.min))
        .foregroundStyle(.secondary)
        .padding(12)
    }
}
