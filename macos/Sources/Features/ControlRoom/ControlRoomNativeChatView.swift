import AppKit
import OSLog
import SwiftUI

/// The group chat's messages, drawn natively (task 2791, #2791; the demand
/// and Markdown wiring, task 2800 C2b-1; history, header and reading state,
/// task 2969 B).
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
/// **The truth is where the viewport's top edge is pinned, not how far the
/// view scrolled** (task 3016, the camera model). `camera` names the row and
/// the offset into it; `pinned` says the viewport is at the bottom. The pixel
/// offset is a projection of those two: it is written only by `project()`
/// (truth → pixels) and read back only in `scrolled` for a callback the
/// reader caused (pixels → truth). Older pages, a measured Markdown row, a
/// narrower window and the preview sidebar opening all change row heights;
/// each of those reports new frames and the view projects the same camera
/// again. **New messages follow while `pinned`**; away from the bottom they
/// raise the "jump to latest" pill instead.
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
    /// **The truth about where the reader is** (task 3016):
    /// `ControlRoomChatCamera.State` holds the place, whether the viewport is
    /// pinned to the bottom, and the projection still owed. Nothing else in
    /// this view is allowed to be a second copy of that truth.
    @State private var camera = ControlRoomChatCamera.State()
    @State private var lastIDs: [String] = []
    /// The pixels, projected from the camera (or the bottom) on every change
    /// and never read as the truth. The index bar reads the same numbers.
    @State private var offsetY: CGFloat = 0
    @State private var viewportH: CGFloat = 0
    @State private var contentH: CGFloat = 0
    @State private var framesEpoch: UInt64 = 0
    @State private var seenFramesEpoch: UInt64 = 0
    /// Set when the rows changed and the frames that answer them have not
    /// arrived. A bounds callback in this window is layout, not the reader.
    @State private var layoutAwaitingFrames = false
    /// The frames epoch an owed projection was made against. **An answer
    /// from the same map is not an answer** (R1-12).
    @State private var waitingSince: UInt64?
    @State private var newBelow = false
    /// The row the lazy stack has been asked to make by name, so a camera on
    /// an unmeasured row asks once rather than on every pass.
    @State private var soughtID: String?
    /// One ask of `ScrollViewReader`, for a row the lazy stack has not made
    /// yet. **The token, not the id, is the identity**: asking twice for the
    /// same row must fire twice.
    private struct SeekRequest: Equatable {
        var id: String
        var token: UInt64
    }
    @State private var seekRequest: SeekRequest?
    @State private var seekToken: UInt64 = 0
    /// A seek is in flight: the bounds callbacks it causes are the view's,
    /// not the reader's.
    @State private var seekInFlight = false
    /// Bumped when the map is replaced rather than extended. The index bar
    /// reads it to abandon a drag that was aimed at the old map.
    @State private var mapEpoch: UInt64 = 0
    @State private var inScrollCall = false
    /// **Every target the view's own scrolls have sent and not yet seen a
    /// callback for** (MF2). A set, not a slot: one turn may send two
    /// programmatic scrolls, and clearing the expectation on the first
    /// callback made the second read as the reader -- the camera then took
    /// the programmatic landing and `pinned` turned off.
    @State private var expectedScrolls: [Double] = []
    /// **A jump whose row is not in the loaded map yet** (M1). While the
    /// `around` is on its way, the place names a row `rows` does not have;
    /// that is "not loaded yet", not "gone", and must not fall back.
    @State private var jumpInFlight: String?
    /// **How many times a continuous gesture has reached the loaded top with
    /// earlier history still available** (the criterion-2 instrument). Logged
    /// only on entering that state, not on every callback.
    @State private var topHits = 0
    @State private var atLoadedTop = false
    /// The probe has found the scroll view and is listening to its clip view.
    @State private var handleAttached = false
    @State private var visible = false
    /// The hand is on the list, as the feed was last told.
    @State private var toldReaderActive = false
    /// Invalidates the quiet checks queued by earlier wheel events.
    @State private var quietToken: UInt64 = 0
    /// Invalidates the owed-projection checks queued by earlier events.
    @State private var projectionToken: UInt64 = 0
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

    private static let space = "poltergeist.chat.rows"
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
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var body: some View {
        let theme = Look.theme(scheme)
        let plan = listPlan
        let indexByID = rowIndexByID
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            // **No loading row above the list** (task 3002): the
                            // window is a fixed-height frame over a stream with no
                            // length, and getting more of it is the background's
                            // business -- it must not be a visible event.
                            ForEach(plan, id: \.id) { item in
                                switch item {
                                case let .gap(gap):
                                    gapBoundary(theme, gap: gap)
                                case let .message(id):
                                    if let index = indexByID[id], index < feed.rows.count {
                                        let row = feed.rows[index]
                                        let dayBreak = needsDivider(index)
                                        // **One hairline, never two**: a day
                                        // divider already separates this row, so
                                        // the speaker's rule is not stacked on it.
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
                                            hit: located ? locatedHit : nil,
                                            onReference: onReference
                                        )
                                        .background(located
                                            ? theme.searchTarget.color.opacity(locatedGlow)
                                            : Color.clear)
                                        .overlay(alignment: .leading) {
                                            // The located row's own edge, so the
                                            // hit reads as one message rather
                                            // than a wash over the list.
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
                            contextNewerBoundary(theme)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .coordinateSpace(name: Self.space)
                        .background(ControlRoomChatScrollProbe(
                            handle: scroll,
                            onAttach: { attached in
                                handleAttached = attached
                                // **R1-6: the probe attaching is a projection
                                // trigger.** A rebuilt host finds its scroll
                                // view again and the camera is projected from
                                // scratch.
                                if attached { project() }
                            },
                            onVisible: { shown in
                                // A page that comes back into sight projects
                                // again; nothing was measurable while hidden.
                                if shown { project() }
                            },
                            onUserScroll: userTookScroll,
                            onUserScrollEnd: handLeftTheList,
                            report: scrolled
                        ))
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: geometry.size.width) { _ in
                        // **R1-12: the frames are the old width's.** A
                        // projection against them would scroll to a wrong
                        // place and the arriving frames would scroll a second
                        // time -- two visible movements. Clear them; the new
                        // frames are what the projection waits for.
                        frames = [:]
                        framesEpoch &+= 1
                        layoutAwaitingFrames = true
                        project()
                    }
                    .onChange(of: seekRequest) { request in
                        guard let request else { return }
                        // **The second half of a two-stage jump** (R1-3): a
                        // row the lazy stack has not made yet has no frame,
                        // so the projection cannot reach it. Ask for it by
                        // name; `project()` corrects to the measured frame
                        // when it arrives. The id here is the list plan's
                        // (`"m:"+row.id`), never the camera's.
                        proxy.scrollTo(request.id, anchor: .top)
                    }
                    .overlay(alignment: .trailing) {
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
            lastIDs = feed.rows.map(\.id)
            // **A page always opens on the newest message** (task 3002, the
            // person's ruling of 2026-11-06). The list is a fixed-height
            // frame over a stream, not a document with a remembered bookmark.
            // **It is one word now** (task 3016): `pinned` is the truth, and
            // there is no landing action that could fail and be lost.
            camera = ControlRoomChatCamera.State(place: nil, pinned: true)
            waitingSince = nil
            newBelow = false
            pendingReturnToLatest = false
            soughtID = nil
            landedLocate = nil
            project()
            // A page that opens already located: the mark may breathe once
            // the row is measured and under the viewport, which is what the
            // frames preference and the bounds callbacks ask below.
            breatheLocatedIfInView()
        }
        .onDisappear {
            visible = false
            // **The hand is not on a page that is gone.** A gesture
            // interrupted by leaving the page would otherwise leave the feed
            // holding a page for a hand that left. `feed.stop` is the other
            // moment, and it clears the same flag.
            toldReaderActive = false
            feed.readerActive(false)
            // **Every queued ticket belongs to the page that left** (A2 S2):
            // a quiet check or an owed projection arranged before the page
            // went away must not run on it, nor on the page that replaces it.
            quietToken &+= 1
            projectionToken &+= 1
            jumpInFlight = nil
        }
        // **A locate has two moments** (R2-1). `locateEpoch` moves when the
        // request starts, before the target's around window exists; the rows
        // change that lands the window is the second. `jumpToLocate` is keyed
        // on both so a repeated pick of the same result lands again and a
        // context page appended afterwards does not pull the reader back.
        .onChange(of: feed.locateEpoch) { _ in
            jumpToLocate(feed.locatedAnchor)
            // A locate that failed outright names no target; its in-flight
            // wait would otherwise never be spent (M1).
            if feed.locatedAnchor == nil { jumpInFlight = nil }
        }
        .onChange(of: feed.rows) { rows in
            // **One map, one projection.** Every rows change -- an older
            // page prepended, a live message appended, a locate's new window
            // -- says the frames will move, and the camera is projected onto
            // them. If the camera's row is gone, the fallback says so.
            layoutAwaitingFrames = true
            rowsChanged(rows)
            jumpToLocate(feed.locatedAnchor)
            project()
        }
        // **A viewport that has just become real** (0 → positive, or a new
        // size) projects the camera again: the bottom target depends on it.
        .onChange(of: viewportH) { height in
            guard height > 0 else { return }
            project()
            publishViewportRows()
        }
        .onPreferenceChange(RowFramesPreference.self) { value in
            frames = value
            framesEpoch &+= 1
            layoutAwaitingFrames = false
            seekInFlight = false
            // **A frames change is a consequence, never a cause.** Scrolling
            // up a LazyVStack changes frames on every row it makes; none of
            // those may move the camera. They are the moment the projection
            // runs, because the camera's row may have just been measured.
            project()
            // The located row may have just been measured: that is one of
            // the two moments its mark may breathe (task 2999 ④).
            breatheLocatedIfInView()
            publishViewportRows()
        }
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
            trimmedBefore: feed.trimmedBefore,
            trimmedAfter: feed.trimmedAfter
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

    // MARK: - The camera (task 3016)

    /// **The projection: truth → pixels.** The only place the view puts the
    /// camera or the bottom on screen. It reads no pixel offset; everything
    /// it decides comes from `ControlRoomChatCamera`.
    ///
    /// **Nothing is projected under a hand that is on the list** (R1-2). A
    /// second thing moving the viewport during a live scroll or a wheel is a
    /// jump the reader sees. What is owed is not dropped: `camera.owed` keeps
    /// it and `flushOwedProjection` pays it once the wheel is quiet.
    private func project() {
        guard handleAttached else { return }
        // **A page that is hidden or gone scrolls nothing** (A2 S1/S2).
        guard visible, scroll.isVisible else {
            camera.owed = projectionNow()
            return
        }
        guard ControlRoomChatCamera.mayProject(
            userScrolling: scroll.userScrolling,
            readerRecently: scroll.readerMovedRecently
        ) else {
            camera.owed = projectionNow()
            armProjectionCheck()
            return
        }
        apply(projectionNow())
    }

    private func projectionNow() -> ControlRoomChatCamera.Projection {
        ControlRoomChatCamera.projection(
            state: camera,
            order: feed.rows.map(\.id),
            frames: frames,
            content: Double(contentH),
            viewport: Double(viewportH),
            // **The fallback measures from the top edge** (M2), not from the
            // viewport's middle: the middle plus scrolling the row's top into
            // place was a half-screen jump.
            centre: Double(offsetY),
            pending: jumpInFlight
        )
    }

    /// Do one projection. **A projection made against a version of the frames
    /// may only be answered by a newer one** (R1-12): after a width change the
    /// old frames are gone and the debt waits for the new ones. `wait` and
    /// `fallback` are two different answers and both are said out loud in the
    /// model; here the second also writes a diagnostic.
    private func apply(_ projection: ControlRoomChatCamera.Projection) {
        switch projection {
        case let .scroll(y):
            guard mayAnswerNow() else {
                camera.owed = projection
                armProjectionCheck()
                return
            }
            camera.owed = nil
            scrollProgrammatically(toY: CGFloat(y))
        case let .scrollTo(id):
            // **Only a real jump asks the lazy stack by name** (R1-3 / MF1):
            // the camera already names the row, and asking for it makes the
            // stack build it; the frames that follow land here again.
            camera.owed = projection
            seekToJump(id)
        case .pin:
            guard mayAnswerNow() else {
                camera.owed = projection
                armProjectionCheck()
                return
            }
            camera.owed = nil
            // **No row height needed** (MF1): the estimated document's
            // bottom is the target, and the next frames change pins again.
            scrollProgrammatically(toY: .greatestFiniteMagnitude)
            if let last = feed.rows.last {
                // **Trim is fed by the camera** (R1-5): pinned means the
                // reader is at the newest end.
                feed.reading(anchor: last.id, offset: 0)
            }
        case let .wait(id):
            // "I do not know yet": the frames preference asks again.
            // **Nothing is sought here** (MF1): seeking to a row that is
            // about to be measured scrolled to one place and then another.
            _ = id
            camera.owed = projection
            waitingSince = framesEpoch
        case let .fallback(nearest):
            // **"I know it is gone."** Five paths put the camera's row
            // outside the window (trim, a locate's new window, a session
            // change, `clearWindow`, a clamped origin); without this the
            // list would draw nothing at all. The fallback names a place
            // **inside** the nearest measured row (M2), so landing on it
            // moves the viewport by at most one row, not half a screen.
            camera.owed = projection
            waitingSince = framesEpoch
            Self.cameraLog.notice(
                "chat camera fallback id=\(camera.place?.id ?? "-", privacy: .public) nearest=\(nearest?.id ?? "-", privacy: .public) off=\(Int(nearest?.offset ?? 0), privacy: .public) rows=\(feed.rows.count, privacy: .public)"
            )
            if let nearest, let y = ControlRoomChatCamera.y(of: nearest, frames: frames) {
                camera.place = nearest
                camera.pinned = false
                feed.reading(anchor: nearest.id, offset: nearest.offset)
                scrollProgrammatically(toY: CGFloat(y))
            } else if !feed.rows.isEmpty {
                // Nothing measured: the newest end is the only place that
                // exists, and the pinned projection knows how to wait for it.
                camera.place = nil
                camera.pinned = true
            }
        }
    }

    private func mayAnswerNow() -> Bool {
        guard let since = waitingSince else { return true }
        guard ControlRoomChatCamera.mayAnswer(
            framesEpoch: framesEpoch, waitingSince: since
        ) else { return false }
        waitingSince = nil
        return true
    }

    /// **The second half of a two-stage jump** (R1-3). A row the lazy stack
    /// has not made has no frame, so the projection cannot reach it; asking
    /// `ScrollViewReader` for it makes the stack build it, and the frames
    /// that follow land the camera exactly. **Once per row**: the token makes
    /// the same row askable again after a new jump. **Only a jump calls
    /// this** (MF1) -- a row that is simply not measured yet waits.
    private func seekToJump(_ id: String) {
        guard soughtID != id else { return }
        soughtID = id
        seekInFlight = true
        seekToken &+= 1
        seekRequest = SeekRequest(
            // The list plan's identity, not the camera's (R1-3).
            id: ControlRoomChatPresentation.ListRow.message(id: id).id,
            token: seekToken
        )
    }

    /// **The inverse: pixels → truth.** Only a callback the reader caused may
    /// move the camera, and the bottom it lands on is what `pinned` means.
    private func scrolled(_ y: CGFloat, _ viewport: CGFloat, _ content: CGFloat) {
        // **A hidden host scrolls nothing.** `feed.stop` and a hidden ancestor
        // do not always reach `onDisappear`; the live view test does.
        guard visible, scroll.isVisible else { return }
        // **A clip origin past the document instantiates nothing** (R1-13:
        // this is one of the kept readers of the pixel value). A rubber-band
        // overscroll is the reader's and is left alone; anything else is
        // clamped back. **The camera is written before the scroll** (R2-2),
        // or the next projection would undo the clamp.
        if content > viewport + 1, y > content - viewport + 2,
           !inScrollCall, !scroll.userScrolling, !scroll.readerMovedRecently {
            let target = Double(content - viewport)
            if let place = ControlRoomChatCamera.place(
                order: feed.rows.map(\.id), frames: frames, at: target
            ) {
                camera.place = place
                feed.reading(anchor: place.id, offset: place.offset)
            }
            camera.pinned = true
            camera.owed = nil
            scrollProgrammatically(toY: content - viewport)
            return
        }
        let contentChanged = abs(content - contentH) > 0.5
        offsetY = y
        viewportH = viewport
        contentH = content
        let epochChanged = seenFramesEpoch != framesEpoch
        seenFramesEpoch = framesEpoch
        // **Every target the view sent is kept until its own callback**
        // (MF2). A callback matching none is the reader's (or layout's) and
        // leaves the set alone, so the second of two programmatic scrolls in
        // one turn still matches.
        let programmatic = ControlRoomChatCamera.programmaticCallback(
            inScrollCall: inScrollCall,
            seekInFlight: seekInFlight,
            y: Double(y),
            expectations: &expectedScrolls
        )
        // **A measured Markdown row moves the bounds before its frames
        // preference arrives.** Content height changing with the same frames
        // epoch is layout, not the reader; a real live-scroll event is the
        // reader even then.
        let cause = ControlRoomChatAnchor.cause(
            contentChanged: contentChanged && !programmatic,
            framesChanged: epochChanged,
            phaseIsLayout: layoutAwaitingFrames,
            programmatic: programmatic,
            userScrolling: scroll.userScrolling,
            // **A wheel is the reader even when no live scroll is running**:
            // the live-scroll notification covers the touch, not the momentum
            // after `didEndLiveScroll` (task 2999 ③).
            readerRecently: scroll.readerMovedRecently
        )
        if layoutAwaitingFrames, epochChanged { layoutAwaitingFrames = false }
        let bottom = ControlRoomChatAnchor.isAtBottom(
            offset: Double(y), viewport: Double(viewport), content: Double(content)
        )
        if cause == .user {
            // **The hand is on the list**, so the feed holds pages for it
            // (R1-1), and the view says when it leaves.
            if !toldReaderActive {
                toldReaderActive = true
                feed.readerActive(true)
            }
            armQuietCheck()
            // **The camera is written only here**, and trim is fed from it on
            // every write (R1-5) -- a programmatic jump leaves the feed a
            // stale anchor otherwise, and trim may then evict the camera's
            // own row.
            camera.bounds(
                cause: cause,
                y: Double(y),
                order: feed.rows.map(\.id),
                frames: frames
            )
            if let place = camera.place {
                feed.reading(anchor: place.id, offset: place.offset)
            }
            // **R1-7: a reader who reaches the bottom is following again.**
            camera.pinned = ControlRoomChatCamera.pinned(
                after: cause, atBottom: bottom, was: camera.pinned
            )
            if bottom { newBelow = false }
        }
        // **Content that grew under a pinned viewport stays pinned** (R2-7's
        // mac answer): every projection re-pins, so a row measuring taller
        // cannot leave the viewport half-way up.
        if camera.pinned, contentChanged, cause != .user {
            DispatchQueue.main.async { project() }
        }
        maybePrefetch(fromInput: cause == .user)
        noteTopHit()
        breatheLocatedIfInView()
        publishViewportRows()
    }

    /// **The criterion-2 instrument.** One line each time a gesture reaches
    /// the loaded top while earlier history is still out; a reading is
    /// counted from the log, not judged by eye. Only the transition is
    /// logged, so a reader resting at the top does not fill the log.
    private func noteTopHit() {
        guard viewportH > 0, !feed.rows.isEmpty, hasEarlierHistory else {
            atLoadedTop = false
            return
        }
        let loadedTop = frames[feed.rows[0].id].map { Double($0.minY) } ?? 0
        let hit = currentTopY() - loadedTop <= 1
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

    /// Earlier history this window has not loaded yet.
    private var hasEarlierHistory: Bool {
        if let context = feed.context {
            return context.olderToken != nil && !context.olderAtEnd
        }
        return feed.historyTail?.nextToken != nil
    }

    private func rowsChanged(_ rows: [ControlRoomChatFeed.Row]) {
        let ids = rows.map(\.id)
        let change = ControlRoomChatAnchor.change(from: lastIDs, to: ids)
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
            framesEpoch &+= 1
            mapEpoch &+= 1
            soughtID = nil
            if feed.locatedAnchor != nil {
                newBelow = false
            } else if camera.pinned {
                newBelow = false
            } else if !rows.isEmpty {
                newBelow = true
            }
        case .prepended:
            // **The camera keeps its row and the projection is the
            // correction.** The page itself never waits for the hand: that is
            // R1-1's job in the feed (a coordinate-system guard), not the
            // view's.
            break
        case .none:
            break
        }
        lastIDs = ids
        // **A jump whose map has arrived is no longer in flight** (M1).
        if let inFlight = jumpInFlight, ids.contains(inFlight) {
            jumpInFlight = nil
        }
        // **R1-8: a located window's way out lands when the new map does.**
        if pendingReturnToLatest, !isLocated {
            pendingReturnToLatest = false
            camera = ControlRoomChatCamera.State(place: nil, pinned: true)
            waitingSince = nil
            jumpInFlight = nil
        }
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
        if feed.locateTrouble != nil { jumpInFlight = nil }
        // A settled locate whose target is not in its window has nothing to
        // land on (the feed has said `TargetNotInWindow`); asking again is
        // the loop M5 closes.
        guard rowIndexByID[target] != nil || !settled else { return }
        jump(to: target)
    }

    /// The index bar's seek, through the one teleport primitive.
    private func seek(toIndex index: Int) {
        guard index >= 0, index < feed.rows.count else { return }
        jump(to: feed.rows[index].id)
    }

    /// **The one teleport primitive** (R1-3). A row already measured is a
    /// projection; one in `rows` but not yet made is asked for by name and
    /// corrected when its frame arrives; one not loaded at all changes the
    /// map through the feed, and the around answer arrives as rows.
    ///
    /// **The camera is written first** (R2-2): `proxy.scrollTo` is a
    /// programmatic scroll, and a projection that did not know where it went
    /// would put it back.
    private func jump(to id: String) {
        camera.pinned = false
        camera.owed = nil
        newBelow = false
        pendingReturnToLatest = false
        soughtID = nil
        waitingSince = nil
        camera.place = ControlRoomChatCamera.Place(id: id, offset: 0)
        feed.reading(anchor: id, offset: 0)
        guard rowIndexByID[id] != nil else {
            // **The map has to change, so this is not "gone"** (M1): the
            // projection waits for the row instead of falling back while the
            // `around` is on its way.
            jumpInFlight = id
            feed.jump(to: id)
            project()
            return
        }
        jumpInFlight = nil
        project()
    }

    /// A click on the bare track: one screenful in the direction asked for,
    /// within the loaded map (the index bar never covers more than that).
    /// Near an edge it asks the feed for the next page, exactly as a wheel
    /// there would.
    private func pageBy(_ direction: Int) {
        guard direction != 0, viewportH > 0 else { return }
        let target = max(0, currentTopY() + Double(direction) * Double(viewportH))
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
        camera.owed = nil
        waitingSince = nil
        project()
        maybePrefetch(fromInput: true)
    }

    /// The top edge in content coordinates, from the camera when it has one.
    /// **The pixel offset is only the fallback** for a camera not measurable
    /// yet; it is never the truth.
    private func currentTopY() -> Double {
        if camera.pinned { return max(0, Double(contentH - viewportH)) }
        if let place = camera.place,
           let y = ControlRoomChatCamera.y(of: place, frames: frames) {
            return y
        }
        return Double(offsetY)
    }

    /// **Asking for more is silent, and it happens early** (R1-1 / §5): three
    /// viewports before the loaded edge is what keeps a fast scroll from
    /// reaching a page boundary. The feed's own gates (`canLoadOlder`, the
    /// cooldown) make asking on every bounds callback one request per page.
    ///
    /// **The newer edge is asked for only on the reader's own input** (M4).
    /// A pinned viewport re-pins on every page, and its programmatic callback
    /// is always at distance 0 -- asking there walked the whole remaining
    /// history one core request at a time.
    private func maybePrefetch(fromInput: Bool) {
        guard viewportH > 0, !feed.rows.isEmpty else { return }
        let viewport = Double(viewportH)
        let top = currentTopY()
        let loadedTop = frames[feed.rows[0].id].map { Double($0.minY) } ?? 0
        if ControlRoomChatCamera.wantsOlder(
            top: top, loadedTop: loadedTop, viewport: viewport
        ) {
            askForMore(.older)
        }
        if feed.context != nil,
           ControlRoomChatCamera.newerIsDue(
            wants: ControlRoomChatCamera.wantsNewer(
                bottom: top + viewport,
                loadedBottom: Double(contentH),
                viewport: viewport),
            fromInput: fromInput
           ) {
            askForMore(.newer)
        }
    }

    /// A real live-scroll started (or a wheel burst): **the hand is on the
    /// list**, and every projection is postponed until it leaves.
    private func userTookScroll() {
        // **The reader voids every expectation the view had** (MF2).
        expectedScrolls = []
        seekInFlight = false
        if !toldReaderActive {
            toldReaderActive = true
            feed.readerActive(true)
        }
        armQuietCheck()
    }

    /// **The hand has left the list.** The feed lands the pages it held for
    /// the gesture and the rows change projects once with the merged frames;
    /// the projection postponed by the gate is paid after that, not before
    /// (A2 S4: paying first would land on the pre-merge map and move again).
    private func handLeftTheList() {
        guard toldReaderActive else { return }
        // **Momentum is still the reader**: `didEndLiveScroll` fires when the
        // fingers lift, not when the list stops.
        guard !scroll.readerMovedRecently else {
            armQuietCheck()
            return
        }
        toldReaderActive = false
        // **R1-1: the held pages land now**, in one rows change.
        feed.readerIdle()
        flushOwedProjection()
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
            flushOwedProjection()
        }
    }

    /// Pay the projection a gesture postponed, once the hand is really gone.
    private func flushOwedProjection() {
        guard camera.owed != nil else { return }
        guard ControlRoomChatCamera.mayProject(
            userScrolling: scroll.userScrolling,
            readerRecently: scroll.readerMovedRecently
        ) else {
            armProjectionCheck()
            return
        }
        project()
    }

    /// A short timer for the owed projection, so a wheel that stops without
    /// a live-scroll end still pays it. It is the same window the wheel
    /// signal uses.
    private func armProjectionCheck() {
        projectionToken &+= 1
        let token = projectionToken
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ControlRoomChatScrollHandle.wheelWindow
        ) {
            guard projectionToken == token else { return }
            flushOwedProjection()
        }
    }

    /// One programmatic scroll, registered **before** the call so a
    /// synchronous bounds callback is not read as the reader. A scroll that
    /// moved nothing has no callback coming.
    private func scrollProgrammatically(toY y: CGFloat) {
        inScrollCall = true
        let target = scroll.scroll(toY: y)
        inScrollCall = false
        if let target {
            // **Every target stays until its own callback** (MF2), so two
            // scrolls in one turn are both recognised. A target that never
            // produced a callback must not accumulate: the set is small.
            expectedScrolls.append(Double(target))
            if expectedScrolls.count > 8 {
                expectedScrolls.removeFirst(expectedScrolls.count - 8)
            }
        }
    }

    /// **The feed asks for blocks the size of this window and cannot measure
    /// it.** The count is the index bar's own coverage -- one algorithm, so
    /// the bar and the page the feed asks for cannot disagree about how tall
    /// a screen is. Written from callbacks only, never from `body`.
    private func publishViewportRows() {
        guard viewportH > 0, !frames.isEmpty else { return }
        guard let covered = ControlRoomChatIndexBar.viewportTicks(
            order: feed.rows.map(\.id),
            frames: frames,
            offset: Double(offsetY),
            viewport: Double(viewportH)
        ) else { return }
        let rows = max(1, Int(covered))
        guard rows != feed.viewportRows else { return }
        feed.viewportRows = rows
    }

    private enum AskDirection {
        case older
        case newer
    }

    /// **Asking for more is silent, and the feed owns both gates.** With no
    /// loading row the records either side of the frame are the background's
    /// business. `canLoadOlder` is the single question -- false while a page
    /// is out, held for the reader's hand, or cooling down after a failure --
    /// so this can be asked on every bounds callback without a request storm
    /// and without a second cooldown of the view's own. `loadOlder` routes to
    /// the context cursor by itself when a located window has no
    /// `historyTail`; only the newer direction is a separate call, because
    /// that edge belongs to a located window alone.
    private func askForMore(_ direction: AskDirection) {
        switch direction {
        case .older:
            guard feed.canLoadOlder else { return }
            feed.loadOlder()
        case .newer:
            feed.loadContextNewer()
        }
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
            // **R1-14: the bar's top reads the camera**, not the projected
            // pixel. The appearance is the same tick; the source stops it
            // lagging a frame behind while a projection is owed. `pinned` has
            // no place to read, so the pixel-derived tick stands there.
            let top = cameraTopTick(order: order, frames: frames)
                ?? ControlRoomChatIndexBar.topTick(
                    order: order,
                    frames: frames,
                    offset: Double(offsetY),
                    viewport: Double(viewportH)
                ) ?? 0
            let covered = ControlRoomChatIndexBar.viewportTicks(
                order: order,
                frames: frames,
                offset: Double(offsetY),
                viewport: Double(viewportH)
            ) ?? 1
            ControlRoomChatIndexBarView(
                totalTicks: feed.rows.count,
                topTick: top,
                viewportTicks: covered,
                trackH: max(0, height - 16),
                theme: theme,
                mapEpoch: mapEpoch,
                notice: olderNotice,
                time: { index in
                    guard index >= 0, index < feed.rows.count else { return "" }
                    return ControlRoomChatPresentation.timeText(
                        atMs: feed.rows[index].message.atMs)
                },
                onSeek: seek(toIndex:),
                onPage: pageBy
            )
            .padding(.trailing, ControlRoomChatIndexBar.trackInset)
            .padding(.vertical, 8)
        }
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
    private func cameraTopTick(order: [String], frames: [String: CGRect]) -> Double? {
        guard !camera.pinned, let place = camera.place,
              let index = order.firstIndex(of: place.id),
              let frame = frames[place.id], frame.height > 0
        else { return nil }
        return Double(index) + place.offset / Double(frame.height)
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
            // simply pins now. Neither goes through `jump` -- there is no id.
            if located {
                pendingReturnToLatest = true
                feed.returnToLatest()
            } else {
                camera.place = nil
                camera.pinned = true
                camera.owed = nil
                waitingSince = nil
                project()
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

private struct RowFramesPreference: PreferenceKey {
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
    /// The search hit this row was located to, when it is the located one.
    var hit: ControlRoomChatSearch.Hit?
    var onReference: ((ControlRoomChatData.Message, String?) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var registered: UInt64?

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(alignment: .leading, spacing: 4) {
            header(theme)
            if let mentions = row.message.mentions, !mentions.isEmpty {
                mentionsRow(mentions, theme)
            }
            content
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(row.message.summary ? theme.textSecondary.color.opacity(0.10) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Look.Radius.row))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { register(generation) }
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
