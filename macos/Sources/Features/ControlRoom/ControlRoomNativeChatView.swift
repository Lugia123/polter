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
/// **The reader's place is a message and an offset** (DESIGN-v2 §9.2), kept
/// in `ControlRoomChatAnchor`: the first row reaching the viewport's top edge
/// and how far into it the reader is. Older pages, a measured Markdown row, a
/// narrower window and the preview sidebar opening all change row heights;
/// each of those reports new frames and the viewport is put back on the same
/// message. **New messages follow only while the reader is at the bottom**;
/// away from it they raise the "jump to latest" pill instead.
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
    @State private var keeper = ControlRoomChatAnchor.Keeper()
    @State private var lastIDs: [String] = []
    @State private var offsetY: CGFloat = 0
    @State private var viewportH: CGFloat = 0
    @State private var contentH: CGFloat = 0
    /// How many times this blank episode has been recovered. Bounded so a
    /// recovery that cannot help (the rows are simply not laid out yet) does
    /// not become a scroll loop; reset as soon as a row is on screen.
    @State private var blankAttempts = 0
    @State private var framesEpoch: UInt64 = 0
    @State private var seenFramesEpoch: UInt64 = 0
    @State private var atBottom = true
    @State private var newBelow = false
    /// One ask of `ScrollViewReader`, for a row the lazy stack has not made
    /// yet. **The token, not the id, is the identity**: asking twice for the
    /// same row must fire twice.
    private struct SeekRequest: Equatable {
        var id: String
        var token: UInt64
    }
    @State private var seekRequest: SeekRequest?
    @State private var seekToken: UInt64 = 0
    /// The frames epoch a restore was frozen against. **A restore that would
    /// land where the viewport already is has not been answered until the
    /// frames have moved on**: the frames may still be the replaced window's,
    /// and consuming the restore then loses the correction for good.
    @State private var frozenFramesEpoch: UInt64 = 0
    /// Bumped when the map is replaced rather than extended. The index bar
    /// reads it to abandon a drag that was aimed at the old map.
    @State private var mapEpoch: UInt64 = 0
    /// Invalidates the "the hand has left the list" restore attempts queued
    /// by earlier wheel events.
    @State private var quietToken: UInt64 = 0
    /// Whether the view has told the feed the reader is moving. **The gate
    /// is the feed's; this is only the edge that sets it**, so the view never
    /// asks twice for the same state.
    @State private var toldReaderActive = false
    /// The one scroll the view is doing: none, following the newest message,
    /// or putting the reader's place back. **Mutually exclusive**, so a
    /// bottom never opens a restore that then blocks the follow, and an
    /// explicit "latest" replaces a restore instead of leaving it behind.
    private enum ScrollIntent: Equatable {
        case none
        case follow
        case restore
    }
    @State private var scrollIntent: ScrollIntent = .none
    /// Where a bounds callback belongs. A layout change is not the reader,
    /// even when its bounds arrive before the new frames do; a programmatic
    /// scroll is only programmatic at the place it was sent.
    private enum ScrollPhase: Equatable {
        case idle
        case layoutAwaitingFrames
        case programmatic(expected: CGFloat)
    }
    @State private var scrollPhase: ScrollPhase = .layoutAwaitingFrames
    @State private var inScrollCall = false
    /// The probe has found the scroll view and is listening to its clip view.
    @State private var handleAttached = false
    @State private var visible = false
    /// A bottom the view still owes the reader: performed when the handle is
    /// attached and the page is visible, and abandoned if the reader scrolls.
    @State private var followIntent = false
    @State private var followIntentUserEpoch: UInt64 = 0
    @State private var followIntentFeedGeneration: UInt64 = 0
    /// Invalidates queued work made for a page that has moved on.
    @State private var lifecycleEpoch: UInt64 = 0
    /// Bumped by appear/disappear so queued work from the previous showing
    /// is dropped.
    @State private var activeToken: UInt64 = 0
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
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - The blank-screen probe (task 3002)

    /// **Only the abnormal path writes a line.** The person reproduced a chat
    /// whose header drew and whose list was empty; the suspicion is a clip
    /// origin outside the document, which makes `LazyVStack` instantiate
    /// nothing. This says so when it happens and is silent otherwise.
    ///
    /// `POLTERCHAT_TRACE` is accepted beside the brief's `POLTER_CHAT_TRACE`
    /// because `tools/mac-test-instance.sh` unsets every inherited
    /// `POLTER_*`/`GHOSTTY_*`/`CLAUDE*` variable -- the brief's name would
    /// never reach an app started that way.
    private static let traceOn =
        ProcessInfo.processInfo.environment["POLTER_CHAT_TRACE"] == "1"
        || ProcessInfo.processInfo.environment["POLTERCHAT_TRACE"] == "1"
    private static let traceLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-view"
    )

    private func traceState(_ why: String) {
        guard Self.traceOn else { return }
        // A state word, never the refusal's own text: a diagnostic line is
        // not the place for a message body or a core's words.
        let state: String
        switch feed.state {
        case .idle: state = "idle"
        case .loading: state = "loading"
        case .ready: state = "ready"
        case .empty: state = "empty"
        case .cancelled: state = "cancelled"
        case .gap: state = "gap"
        case .failed: state = "failed"
        }
        Self.traceLog.notice(
            "\(why, privacy: .public) rows=\(feed.rows.count, privacy: .public) state=\(state, privacy: .public) y=\(Int(offsetY), privacy: .public) content=\(Int(contentH), privacy: .public) viewport=\(Int(viewportH), privacy: .public) plan=\(self.listPlan.count, privacy: .public)"
        )
    }

    /// **A non-empty list with no row on screen is recovered, not waited
    /// out.** The criterion is the measured frames, not a clamped offset:
    /// `scroll(toY:)` clamps against a document height that a `LazyVStack`
    /// only estimates, so an offset can be perfectly legal and still land in
    /// a stretch that instantiates nothing.
    ///
    /// Checked where a blank list actually came from: the probe attaching, a
    /// tab coming back, a width change, the viewport going from 0 to real,
    /// and a replaced map. At most two attempts per episode; any successful
    /// sighting resets the count.
    ///
    /// **The order is the point**: a frozen or located place first (that is
    /// where the reader was), then the nearest measured row (where rows
    /// exist), and only then the bottom -- not "jump to the bottom" as a
    /// first answer, which would throw the reader's place away.
    private func recoverVisiblePlace(_ why: String) {
        guard visible, handleAttached, viewportH > 0, !feed.rows.isEmpty,
              !frames.isEmpty
        else { return }
        let visibleRow = frames.values.contains {
            $0.maxY > offsetY && $0.minY < offsetY + viewportH
        }
        if visibleRow {
            blankAttempts = 0
            return
        }
        guard blankAttempts < 2 else { return }
        blankAttempts += 1
        traceState("blank-\(why)")
        // 1. Where the reader was, if that was ever frozen or located.
        if let target = keeper.restoreTarget(frames: frames) {
            scrollProgrammatically(toY: target)
            return
        }
        if let located = feed.locatedAnchor, let frame = frames[located] {
            scrollProgrammatically(toY: frame.minY)
            return
        }
        // 2. The nearest measured row: a place the lazy stack definitely has.
        let centre = Double(offsetY + viewportH / 2)
        if let id = ControlRoomChatAnchor.nearestMeasured(centre: centre, frames: frames),
           let frame = frames[id], abs(frame.minY - offsetY) > 1 {
            scrollProgrammatically(
                toY: min(frame.minY, max(0, contentH - viewportH)))
            return
        }
        // 3. Nothing measured reaches the viewport: the newest messages are
        // the end of the map that always exists.
        requestFollow()
    }

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
                                if attached {
                                    performFollowIfPossible()
                                    restoreSoon()
                                    // **A probe that has just found its
                                    // scroll view** is one of the moments the
                                    // blank list came from (a return to the
                                    // tab, a rebuilt host): the place is put
                                    // back once the frames are known.
                                    DispatchQueue.main.async {
                                        recoverVisiblePlace("attach")
                                    }
                                }
                            },
                            onVisible: { _ in },
                            onUserScroll: userTookScroll,
                            onUserScrollEnd: handLeftTheList,
                            report: scrolled
                        ))
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: geometry.size.width) { _ in
                        layoutChangedForScroll()
                    }
                    .onChange(of: seekRequest) { request in
                        guard let request else { return }
                        // **A jump inside the loaded map** (task 3002): the
                        // index bar and the search never point at a row the
                        // ForEach does not have, so this is a scroll and not
                        // a change of map. The measured correction that
                        // follows is `restoreSoon`'s.
                        proxy.scrollTo(request.id, anchor: .top)
                    }
                    .overlay(alignment: .trailing) {
                        indexBar(theme, height: geometry.size.height)
                    }
                }
            }
            // **A located window keeps its own way out.** Its bottom is the
            // end of the around window, not the newest message, so the pill
            // has to return the page to the live tail; `requestFollow()`
            // alone would only scroll this map. The condition is the located
            // state, not `atBottom`: reading the middle of a located window
            // leaves `atBottom` false too, and the two mean different things.
            if isLocated || !atBottom {
                jumpPill(theme)
            }
        }
        .onAppear {
            visible = true
            activeToken &+= 1
            lastIDs = feed.rows.map(\.id)
            // **A page always opens on the newest message** (task 3002, the
            // person's ruling of 2026-11-06). The list is a fixed-height
            // frame over a stream, not a document with a remembered bookmark:
            // a group that comes back where it was read starts the reader in
            // history by accident. The place is still reported to the feed
            // (`reading(anchor:)`) so trimming keeps the reader's
            // neighbourhood -- it just never seeds the viewport.
            atBottom = true
            newBelow = false
            blankAttempts = 0
            requestFollow()
            DispatchQueue.main.async { recoverVisiblePlace("appear") }
            // A page that opens already located: the mark may breathe once
            // the row is measured and under the viewport, which is what the
            // frames preference and the bounds callbacks ask below.
            breatheLocatedIfInView()
        }
        .onDisappear {
            visible = false
            followIntent = false
            scrollIntent = .none
            activeToken &+= 1
            lifecycleEpoch &+= 1
            // **The hand is not on a page that is gone.** A gesture
            // interrupted by leaving the page would otherwise leave the view
            // believing the reader is still touching the list, and it would
            // never announce the next one -- the feed would keep holding
            // pages for a hand that left. **Not `readerIdle()`**: a page may
            // be merged when the hand leaves a list that is still there, not
            // because the page went away (`feed.stop` is that moment).
            if toldReaderActive {
                toldReaderActive = false
                feed.readerActive(false)
            }
            // Any quiet check still queued belongs to the page that left.
            quietToken &+= 1
        }
        // **The locate's own epoch drives the landing** (task 3002 review A).
        // The anchor's value could not: picking the same search result twice
        // changes nothing about it, so nothing happened. The feed bumps
        // `locateEpoch` on `locate()` and on a locate's own failure -- and
        // **not** on a stop, a reload or a session change, which are not
        // locates and must not pull the reader anywhere.
        .onChange(of: feed.locateEpoch) { _ in landOnLocate() }
        .onChange(of: feed.rows) { rows in
            lifecycleEpoch &+= 1
            // The rows changed, so the frames will too: history freezes the
            // reader, the bottom follows and never opens a restore.
            scrollPhase = .layoutAwaitingFrames
            if atBottom {
                keeper.cancelRestore()
            } else {
                freezeForRestore()
            }
            rowsChanged(rows)
        }
        // **A viewport that has just become real** (0 → positive, or a new
        // size): the moment the reproduced blank chat came back from.
        .onChange(of: viewportH) { height in
            guard height > 0 else { return }
            DispatchQueue.main.async {
                recoverVisiblePlace("viewport")
                publishViewportRows()
            }
        }
        .onPreferenceChange(RowFramesPreference.self) { value in
            frames = value
            framesEpoch &+= 1
            if scrollPhase == .layoutAwaitingFrames { scrollPhase = .idle }
            // **A frames change is a consequence, never a cause.** This used
            // to freeze the reader's place and owe a restore on every frames
            // change while away from the bottom -- and scrolling up a
            // LazyVStack changes frames on every row it makes. Each of those
            // froze the anchor *from before* the scroll it was in the middle
            // of, put the viewport back there, and the reader's next wheel
            // started it again: the list jumped under the hand, and only the
            // scroller (which never asks this view) could reach the top
            // (measured on the real app, 0.11.2381). Every event that really
            // does owe a restore -- a prepended page, a replaced window, a
            // narrower window, a locate -- says so where it happens and sets
            // `scrollIntent` itself.
            restoreSoon()
            // The located row may have just been measured: that is one of
            // the two moments its mark may breathe (task 2999 ④).
            breatheLocatedIfInView()
            recoverVisiblePlace("frames")
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

    // MARK: - Scrolling

    private func scrolled(_ y: CGFloat, _ viewport: CGFloat, _ content: CGFloat) {
        // **A hidden host scrolls nothing.** `feed.stop` and a hidden ancestor
        // do not always reach `onDisappear`; the live view test does.
        guard visible, scroll.isVisible else { return }
        // **A clip origin past the document instantiates nothing.** The
        // reproduced blank chat is this: the header drew, the list did not,
        // and the origin was outside the content. A rubber-band overscroll is
        // the reader's and is left alone; anything else is clamped back.
        if content > viewport + 1, y > content - viewport + 2,
           !inScrollCall, !scroll.userScrolling, !scroll.readerMovedRecently {
            traceState("origin-past-content")
            scrollProgrammatically(toY: content - viewport)
            return
        }
        let contentChanged = abs(content - contentH) > 0.5
        let wasAtBottom = atBottom
        offsetY = y
        viewportH = viewport
        contentH = content
        let epochChanged = seenFramesEpoch != framesEpoch
        seenFramesEpoch = framesEpoch
        let phaseAtCallback = scrollPhase
        var programmatic = false
        switch phaseAtCallback {
        case .layoutAwaitingFrames:
            break
        case let .programmatic(expected):
            programmatic = abs(y - expected) <= 1
            if !programmatic { keeper.cancelProgrammatic() }
        case .idle:
            programmatic = inScrollCall
        }
        // **A measured Markdown row moves the bounds before its frames
        // preference arrives.** Content height changing with the same frames
        // epoch is layout, not the reader; a real live-scroll event is the
        // reader even then.
        let cause = ControlRoomChatAnchor.cause(
            contentChanged: contentChanged && !programmatic,
            framesChanged: epochChanged,
            phaseIsLayout: phaseAtCallback == .layoutAwaitingFrames,
            programmatic: programmatic,
            userScrolling: scroll.userScrolling,
            // **A wheel is the reader even when no live scroll is running**:
            // the live-scroll notification covers the touch, not the
            // momentum after `didEndLiveScroll`. Without this, a momentum
            // callback carrying a lazily measured row's growth was layout,
            // and the list was put back down under the reader's hand (task
            // 2999 ③).
            readerRecently: scroll.readerMovedRecently
        )
        if cause == .programmatic { keeper.consumeProgrammaticCallback() }
        if phaseAtCallback != .layoutAwaitingFrames || epochChanged {
            scrollPhase = .idle
        }
        if cause == .layout, contentChanged, !epochChanged, !keeper.restoring {
            if atBottom {
                requestFollow()
            } else {
                freezeForRestore()
                restoreSoon()
            }
        }
        // **A hand on the list has an end after all.** There is no "the
        // reader let go" event to correct at, so the corrections a gesture
        // interrupted are taken back here: when the wheel has been quiet for
        // its window (0.3s), or when the live scroll ends. The restore is
        // still the frozen anchor + intra-row offset, one shot -- never a sum
        // of per-row height differences.
        if cause == .user {
            if !toldReaderActive {
                toldReaderActive = true
                readerActive(true)
            }
            armQuietCheck()
        }

        // **Who moved is decided here and handed down.** The keeper used to
        // infer the reader from the frames not having changed, which is a
        // fact about layout, not about who moved: a window replacement's
        // ordinary bounds callback cleared the frozen place a locate was
        // waiting to restore to (task 2999 ④/③).
        let user = keeper.bounds(
            y: y,
            order: feed.rows.map(\.id),
            frames: frames,
            user: cause == .user
        )
        if user {
            // The reader moved: no bottom is owed and a restore is over.
            followIntent = false
            scrollIntent = .none
            if let next = keeper.anchor {
                // Trim keeps this neighbourhood; it never moves the reader.
                feed.reading(anchor: next.id, offset: next.offset)
            }
        }
        let bottom = ControlRoomChatAnchor.isAtBottom(
            offset: y, viewport: viewport, content: content
        )
        if bottom {
            atBottom = true
            // **Only the reader clears the notice**: a layout or a
            // programmatic scroll reaching the bottom is not them reading.
            if user { newBelow = false }
            performFollowIfPossible()
        } else {
            atBottom = false
        }
        if contentChanged, !bottom {
            if wasAtBottom && !user {
                requestFollow()
            } else {
                restoreSoon()
            }
        }
        // **The top edge asks quietly** (task 3002): with no loading row and
        // no "load earlier" control, getting the next page is the background
        // continuing, not an event. The threshold is one viewport rather than
        // the old 24pt: 24pt fires only once the reader is already at the
        // very end of the map, so every page would arrive after them. One
        // viewport asks while there is still content above to read.
        if user, ControlRoomChatAnchor.shouldLoadOlder(offset: y, threshold: viewport) {
            askForMore(.older)
        }
        // **And the bottom edge in a located window.** An around answer is a
        // short window: without this the lower half of the screen is empty
        // once the reader reaches its end, and the boundary row that used to
        // offer the next page is gone with the rest of them.
        if user, feed.context != nil,
           ControlRoomChatAnchor.isAtBottom(
                offset: y, viewport: viewport, content: content, tolerance: viewport) {
            askForMore(.newer)
        }
        // **The viewport has moved**: if it has come to rest on the located
        // row, that is the moment its mark breathes (task 2999 ④).
        breatheLocatedIfInView()
        recoverVisiblePlace("scrolled")
        publishViewportRows()
    }

    private func rowsChanged(_ rows: [ControlRoomChatFeed.Row]) {
        let ids = rows.map(\.id)
        let change = ControlRoomChatAnchor.change(from: lastIDs, to: ids)
        switch change {
        case .appended:
            if feed.locatedAnchor != nil {
                // A replaced body here is a search locate, not new messages.
                atBottom = false
                newBelow = false
            } else if atBottom {
                requestFollow()
            } else if !rows.isEmpty {
                newBelow = true
            }
        case .replaced:
            // **A new map, not a longer one.** The frames the view holds are
            // the old window's coordinates, and a restore computed from them
            // lands somewhere that does not exist any more; the drag the
            // index bar is in the middle of was aimed at the old map too.
            frames = [:]
            framesEpoch &+= 1
            mapEpoch &+= 1
            if feed.locatedAnchor != nil {
                atBottom = false
                newBelow = false
            } else if atBottom {
                requestFollow()
            } else if !rows.isEmpty {
                newBelow = true
            }
            // Out of range almost only happens on a replacement, so the
            // recovery is asked for here as well as from the frames.
            DispatchQueue.main.async { recoverVisiblePlace("replaced") }
        case .prepended:
            // The reader stays on their message; the frozen anchor is put
            // back once the new frames are known. At the bottom there is
            // nothing to keep.
            if atBottom { requestFollow() }
        case .none:
            break
        }
        lastIDs = ids
        // The new rows are laid out after this turn: if they arrived but none
        // is on screen, that is the blank list, and it is recovered there.
        blankAttempts = 0
        DispatchQueue.main.async { recoverVisiblePlace("rows") }
    }

    /// **A jump to a row in the loaded map** (task 3002). The index bar and
    /// the search never name a row the `ForEach` does not have, so this is a
    /// scroll and never a change of map: reaching a message that is not
    /// loaded is `feed`'s `around` window, and by the time it answers the row
    /// is here.
    ///
    /// A measured row moves in one step. A row the lazy stack has not made
    /// yet is asked for by name, and the keeper's frozen place is the same
    /// row, so the one correction the frames preference causes lands on it --
    /// two rounds at most, because the keeper is spent after one.
    private func seek(toIndex index: Int) {
        guard index >= 0, index < feed.rows.count else { return }
        let row = feed.rows[index]
        // The person asked for a place: no bottom is owed and no older page
        // is being waited for.
        followIntent = false
        newBelow = false
        atBottom = false
        freezeForRestore(.init(id: row.id, offset: 0))
        if let frame = frames[row.id] {
            scrollPhase = .idle
            scrollProgrammatically(toY: frame.minY)
            restoreSoon()
            return
        }
        scrollPhase = .layoutAwaitingFrames
        seekToken &+= 1
        seekRequest = SeekRequest(
            id: ControlRoomChatPresentation.ListRow.message(id: row.id).id,
            token: seekToken
        )
    }

    /// A click on the bare track: one screenful in the direction asked for,
    /// within the loaded map (the index bar never covers more than that).
    /// Near the top it also asks the feed for the next page, exactly as a
    /// wheel there would.
    private func pageBy(_ direction: Int) {
        guard direction != 0, viewportH > 0 else { return }
        let target = max(0, offsetY + CGFloat(direction) * viewportH)
        keeper.cancelRestore()
        followIntent = false
        scrollIntent = .none
        scrollPhase = .idle
        scrollProgrammatically(toY: target)
        if direction < 0,
           ControlRoomChatAnchor.shouldLoadOlder(offset: target, threshold: viewportH) {
            askForMore(.older)
        }
        // **The mirror of the top edge**: a programmatic page never comes
        // back as `user`, so the near-bottom ask in `scrolled` can never fire
        // for it. In a located window that leaves the lower half of the
        // screen empty -- the boundary row that used to offer the next page
        // is gone.
        if direction > 0, feed.context != nil,
           ControlRoomChatAnchor.isAtBottom(
                offset: Double(target), viewport: Double(viewportH),
                content: Double(contentH), tolerance: Double(viewportH)) {
            askForMore(.newer)
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
            let top = ControlRoomChatIndexBar.topTick(
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

    /// A layout change that is not the reader moving: **at the bottom it only
    /// owes a follow; away from it, it freezes the reader for a restore.**
    /// Never both, which is how a restore could block the follow for ever.
    private func layoutChangedForScroll() {
        lifecycleEpoch &+= 1
        if atBottom {
            keeper.cancelRestore()
            requestFollow()
        } else {
            scrollPhase = .layoutAwaitingFrames
            freezeForRestore()
            restoreSoon()
        }
        // The width changed under the list: if that left nothing on screen,
        // put a place back (see `recoverVisiblePlace`).
        DispatchQueue.main.async { recoverVisiblePlace("width") }
    }

    /// **Freeze the reader's place for one restore.** The place is a row and
    /// an offset into it, never a sum of row heights: a frame that measures
    /// ten rows is one restore to the same row, not ten shifts.
    ///
    /// An anchor is never absent while rows are measured -- the place is a
    /// fact about the frames, not about the reader having scrolled -- so a
    /// prepend with no anchor yet is given the first row's measured frame
    /// rather than shifting content under a reader nothing compensates for.
    ///
    /// The frames epoch the freeze was made against travels with it: a
    /// restore answered by the map it froze against has answered nothing.
    private func freezeForRestore(_ anchor: ControlRoomChatAnchor.Anchor? = nil) {
        let place = anchor
            ?? keeper.anchor
            ?? ControlRoomChatAnchor.anchor(
                order: feed.rows.map(\.id), frames: frames, at: Double(offsetY))
        if let place { keeper.seed(place) }
        keeper.layoutWillChange()
        frozenFramesEpoch = framesEpoch
        scrollIntent = .restore
    }

    /// **A locate landed (or failed).** The landed case puts the target at
    /// the top once its row exists -- and it does so even when `rows` did not
    /// change at all, which is what picking the same search result twice is.
    ///
    /// ⚠️ **Not a promise that every repeat locate moves the list**: a target
    /// row that is in the window but has never been instantiated has no
    /// frame, and this view cannot make the lazy stack make it. The locate's
    /// own window replacement is what gives the row a frame. The measuring
    /// that proves "the second click landed too" is a real-app reading.
    private func landOnLocate() {
        guard let target = feed.locatedAnchor else {
            // **A failed or cleared locate leaves no place to land on.** The
            // optimistic freeze must go with it, or the next layout change
            // (a sidebar opening, a wider window) would execute it and jump
            // to a row the reader never asked for.
            keeper.cancelRestore()
            if scrollIntent == .restore { scrollIntent = .none }
            return
        }
        // A located window is history reading: do not follow, and put the
        // target at the top once its row exists.
        atBottom = false
        newBelow = false
        scrollPhase = .layoutAwaitingFrames
        freezeForRestore(.init(id: target, offset: 0))
        restoreSoon()
    }

    /// Put the viewport back on the **frozen** anchor. Every fact is checked
    /// again at execution: the page's showing token, the feed's generation
    /// and session, the window, the attach, the layout epoch, and that this
    /// is still the restore (a follow or a user scroll cancels it).
    private func restoreSoon() {
        // **Nothing is put back under a hand that is on the list.** A restore
        // that ran during a wheel or a live scroll is a second thing moving
        // the viewport at the same time; whichever won, the reader saw a
        // jump. What is owed is not dropped here, either: the feed holds a
        // page that arrives while the reader is moving, and the quiet timer
        // (`armQuietCheck` -> `handLeftTheList`) freezes, lets the merge in
        // and restores once, after the hand has really left.
        guard ControlRoomChatAnchor.mayRestore(
            userScrolling: scroll.userScrolling,
            readerRecently: scroll.readerMovedRecently
        ) else { return }
        guard scrollIntent == .restore, keeper.restoring, !atBottom else { return }
        let epoch = keeper.layoutEpoch
        let lifecycle = lifecycleEpoch
        let active = activeToken
        let feedGeneration = feed.generation
        let session = feed.session
        let owedEpoch = frozenFramesEpoch
        DispatchQueue.main.async {
            guard scrollIntent == .restore, visible, scroll.isVisible, handleAttached,
                  !atBottom, keeper.restoring,
                  keeper.layoutEpoch == epoch,
                  lifecycleEpoch == lifecycle,
                  activeToken == active,
                  feed.generation == feedGeneration,
                  feed.session == session,
                  let target = keeper.restoreTarget(frames: frames)
            else { return }
            if abs(target - offsetY) <= 1 {
                // **Not answered yet, so not spent.** `frames` may still be
                // the map the restore was frozen against (the replacement's
                // preference has not arrived); consuming it there would mark
                // the correction done and nothing would ask again.
                guard ControlRoomChatAnchor.restoreWasAnswered(
                    framesEpoch: framesEpoch, frozenAt: owedEpoch
                ) else { return }
                keeper.restored()
                scrollIntent = .none
                return
            }
            scrollProgrammatically(toY: target)
            keeper.restored()
            scrollIntent = .none
        }
    }

    /// A bottom the person is owed: remembered with the epoch of the reader
    /// and the feed generation, and performed only where it can be seen.
    /// A real live-scroll started: **every queued scroll intent is void**,
    /// including a restore waiting for new frames and a follow waiting for
    /// attach. The next bounds is the reader's, not ours.
    private func userTookScroll() {
        keeper.cancelRestore()
        keeper.cancelProgrammatic()
        scrollIntent = .none
        followIntent = false
        scrollPhase = .idle
        lifecycleEpoch &+= 1
        // The reader is here and moving: a blank-list recovery may try again
        // from wherever they have gone.
        blankAttempts = 0
        // **And the feed is told, so a page it already holds is not merged
        // into a document the reader is moving** (task 3002 review, the
        // ruling of `### 5`): inserting above the viewport moves the
        // document at once, and putting it back afterwards is a second
        // visible movement -- a correction can fix the endpoint, never the
        // moment. The page waits in the feed instead.
        toldReaderActive = true
        readerActive(true)
        armQuietCheck()
    }

    /// **The hand has left the list** -- it has been still for the wheel
    /// window. Freeze the place first, then let the feed merge what it held,
    /// and restore once.
    private func handLeftTheList() {
        guard toldReaderActive else { return }
        // **Momentum is still the reader**: `didEndLiveScroll` fires when the
        // fingers lift, not when the list stops. A wheel inside its window
        // means the hand has not really left yet.
        guard !scroll.readerMovedRecently else {
            armQuietCheck()
            return
        }
        toldReaderActive = false
        // **Freeze first, against the rows as they are**: nothing has been
        // merged into them while the hand was on the list. `readerIdle()`
        // merges synchronously, so the freeze must be in place before it.
        let rowsAtFreeze = feed.rows.count
        freezeForRestore()
        feed.readerIdle()
        restoreSoon()
        // **A freeze that nothing answered is not left standing.** If the
        // feed had no page to merge, the keeper would stay "restoring" and
        // hold the next follow off. The wait is longer than a turn because
        // the merge arrives through a SwiftUI update of its own; the row
        // count must still be the one the freeze was made against.
        quietToken &+= 1
        let token = quietToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard quietToken == token, keeper.restoring,
                  frozenFramesEpoch == framesEpoch,
                  feed.rows.count == rowsAtFreeze
            else { return }
            keeper.cancelRestore()
            if scrollIntent == .restore { scrollIntent = .none }
        }
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

    /// **The feed's reader gate.** It is only "is the hand on the list"; the
    /// 0.3s quiet judgement is this view's (`armQuietCheck`), because only
    /// the view sees the wheel stream. `true` holds a page that arrives; the
    /// hand leaving goes through `feed.readerIdle()`, which merges it and
    /// sets the flag itself -- a bare `false` would hold no merge.
    private func readerActive(_ active: Bool) {
        guard active else { return }
        feed.readerActive(true)
    }

    private func requestFollow() {
        // An explicit latest replaces a restore instead of being refused by
        // it.
        keeper.cancelRestore()
        scrollIntent = .follow
        followIntent = true
        followIntentUserEpoch = keeper.userEpoch
        followIntentFeedGeneration = feed.generation
        // After the turn that changed the rows: the scroll view's document
        // height is the old one until SwiftUI has laid the new rows out.
        DispatchQueue.main.async { performFollowIfPossible() }
    }

    private func performFollowIfPossible() {
        guard followIntent, scrollIntent == .follow,
              visible, scroll.isVisible, handleAttached, !keeper.restoring,
              ControlRoomChatAnchor.mayFollow(
                intentEpoch: followIntentUserEpoch,
                currentUserEpoch: keeper.userEpoch
              ),
              feed.generation == followIntentFeedGeneration
        else {
            if scrollIntent == .follow, !followIntent { scrollIntent = .none }
            return
        }
        followIntent = false
        scrollProgrammatically(toY: .greatestFiniteMagnitude)
        atBottom = true
        newBelow = false
        scrollIntent = .none
    }

    /// One programmatic scroll, registered **before** the call so a
    /// synchronous bounds callback is not read as the reader. A scroll that
    /// moved nothing has no callback coming, and its registration is taken
    /// back rather than left to swallow the next user scroll.
    private func scrollProgrammatically(toY y: CGFloat) {
        keeper.willScrollProgrammatically()
        inScrollCall = true
        let target = scroll.scroll(toY: y)
        inScrollCall = false
        if let target {
            // An asynchronous callback must match this place; a synchronous
            // one has already been classified by `inScrollCall`.
            scrollPhase = .programmatic(expected: target)
        } else {
            keeper.cancelProgrammatic()
            scrollPhase = .idle
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

    private func jumpPill(_ theme: Look.Theme) -> some View {
        let located = isLocated
        return Button {
            // The person asked for the bottom: an explicit intent, not a
            // scroll position this view guessed.
            newBelow = false
            if located {
                // **Back to the live conversation.** A located window is
                // another map; scrolling to its end is not "latest". The
                // feed replaces the window, the index bar starts again on
                // the new map, and the view follows the tail from there.
                atBottom = true
                feed.returnToLatest()
            }
            requestFollow()
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
        /// moving *this* list.
        private func noteWheel(_ event: NSEvent) {
            guard let scrollView = enclosingScrollView,
                  event.window === scrollView.window
            else { return }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(point) else { return }
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
