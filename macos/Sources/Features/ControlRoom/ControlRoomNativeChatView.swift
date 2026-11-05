import AppKit
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
    @State private var framesEpoch: UInt64 = 0
    @State private var seenFramesEpoch: UInt64 = 0
    @State private var atBottom = true
    @State private var newBelow = false
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

    private static let space = "poltergeist.chat.rows"
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var body: some View {
        let theme = Look.theme(scheme)
        let plan = listPlan
        let indexByID = rowIndexByID
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        olderBoundary(theme)
                        contextOlderBoundary(theme)
                        ForEach(plan, id: \.id) { item in
                            switch item {
                            case let .gap(gap):
                                gapBoundary(theme, gap: gap)
                            case let .message(id):
                                if let index = indexByID[id], index < feed.rows.count {
                                    let row = feed.rows[index]
                                    if needsDivider(index) {
                                        dayDivider(row.message.atMs, theme)
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
                                        ? theme.searchTarget.color
                                        : Color.clear)
                                    .overlay(alignment: .leading) {
                                        // The located row's own edge, so the
                                        // hit reads as one message rather
                                        // than a wash over the list.
                                        if located {
                                            Rectangle()
                                                .fill(theme.searchTargetEdge.color)
                                                .frame(width: 3)
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
                            }
                        },
                        onVisible: { _ in },
                        onUserScroll: userTookScroll,
                        report: scrolled
                    ))
                }
                .onChange(of: geometry.size.width) { _ in
                    layoutChangedForScroll()
                }
            }
            if !atBottom {
                jumpPill(theme)
            }
        }
        .onAppear {
            visible = true
            activeToken &+= 1
            lastIDs = feed.rows.map(\.id)
            // **A page shown again comes back where it was read**, not at the
            // bottom. Only a page with no saved position follows the newest
            // message.
            if let saved = feed.savedReading,
               feed.rows.contains(where: { $0.id == saved.id }) {
                // **A saved reading position is history intent**, not a
                // bottom: the first bounds of the new showing must not move
                // it, and restoreSoon must not be turned away by atBottom.
                atBottom = false
                scrollPhase = .layoutAwaitingFrames
                keeper.seed(saved)
                keeper.layoutWillChange()
                scrollIntent = .restore
                restoreSoon()
            } else {
                atBottom = true
                requestFollow()
            }
        }
        .onDisappear {
            visible = false
            followIntent = false
            scrollIntent = .none
            activeToken &+= 1
            lifecycleEpoch &+= 1
        }
        .onChange(of: feed.locatedAnchor) { target in
            guard let target else { return }
            // A located window is history reading: do not follow, and put
            // the target at the top once its row exists.
            atBottom = false
            newBelow = false
            keeper.seed(.init(id: target, offset: 0))
            keeper.layoutWillChange()
            scrollIntent = .restore
            scrollPhase = .layoutAwaitingFrames
            restoreSoon()
        }
        .onChange(of: feed.rows) { rows in
            lifecycleEpoch &+= 1
            // The rows changed, so the frames will too: history freezes the
            // reader, the bottom follows and never opens a restore.
            scrollPhase = .layoutAwaitingFrames
            if atBottom {
                keeper.cancelRestore()
            } else {
                keeper.layoutWillChange()
                scrollIntent = .restore
            }
            rowsChanged(rows)
        }
        .onPreferenceChange(RowFramesPreference.self) { value in
            frames = value
            framesEpoch &+= 1
            if scrollPhase == .layoutAwaitingFrames { scrollPhase = .idle }
            if !atBottom {
                keeper.layoutWillChange()
                scrollIntent = .restore
            }
            restoreSoon()
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

    // MARK: - Scrolling

    private func scrolled(_ y: CGFloat, _ viewport: CGFloat, _ content: CGFloat) {
        // **A hidden host scrolls nothing.** `feed.stop` and a hidden ancestor
        // do not always reach `onDisappear`; the live view test does.
        guard visible, scroll.isVisible else { return }
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
            userScrolling: scroll.userScrolling
        )
        let framesChanged = cause == .layout
        if cause == .programmatic { keeper.consumeProgrammaticCallback() }
        if phaseAtCallback != .layoutAwaitingFrames || epochChanged {
            scrollPhase = .idle
        }
        if cause == .layout, contentChanged, !epochChanged, !keeper.restoring {
            if atBottom {
                requestFollow()
            } else {
                keeper.layoutWillChange()
                scrollIntent = .restore
                restoreSoon()
            }
        }

        let user = keeper.bounds(
            y: y,
            order: feed.rows.map(\.id),
            frames: frames,
            framesChanged: framesChanged,
            programmatic: cause == .programmatic
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
        if user, ControlRoomChatAnchor.shouldLoadOlder(offset: y), feed.canLoadOlder {
            feed.loadOlder()
        }
    }

    private func rowsChanged(_ rows: [ControlRoomChatFeed.Row]) {
        let ids = rows.map(\.id)
        switch ControlRoomChatAnchor.change(from: lastIDs, to: ids) {
        case .appended, .replaced:
            if feed.locatedAnchor != nil {
                // A replaced body here is a search locate, not new messages.
                atBottom = false
                newBelow = false
            } else if atBottom {
                requestFollow()
            } else if !rows.isEmpty {
                newBelow = true
            }
        case .prepended:
            // The reader stays on their message; the frozen anchor is put
            // back once the new frames are known. At the bottom there is
            // nothing to keep.
            if atBottom { requestFollow() }
        case .none:
            break
        }
        lastIDs = ids
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
            keeper.layoutWillChange()
            scrollIntent = .restore
            restoreSoon()
        }
    }

    /// Put the viewport back on the **frozen** anchor. Every fact is checked
    /// again at execution: the page's showing token, the feed's generation
    /// and session, the window, the attach, the layout epoch, and that this
    /// is still the restore (a follow or a user scroll cancels it).
    private func restoreSoon() {
        guard scrollIntent == .restore, keeper.restoring, !atBottom else { return }
        let epoch = keeper.layoutEpoch
        let lifecycle = lifecycleEpoch
        let active = activeToken
        let feedGeneration = feed.generation
        let session = feed.session
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
    private func contextOlderBoundary(_ theme: Look.Theme) -> some View {
        if let context = feed.context {
            HStack(spacing: 8) {
                if feed.contextOlderStale {
                    Text(String(localized: "This direction's edge was released.",
                                comment: "总控台：群聊页，定位窗口的更早方向已失效"))
                    Button(String(localized: "Re-anchor here",
                                  comment: "总控台：群聊页，用保留边缘重新定位")) {
                        feed.reanchorOlder()
                    }
                    .buttonStyle(.link)
                } else if !context.olderAtEnd {
                    Button(String(localized: "Earlier context",
                                  comment: "总控台：群聊页，加载定位窗口更早的上下文")) {
                        feed.loadContextOlder()
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
                Button(String(localized: "Return to latest",
                              comment: "总控台：群聊页，退出定位回到最新")) {
                    feed.returnToLatest()
                }
                .buttonStyle(.link)
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity)
        }
    }

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

    @ViewBuilder
    private func olderBoundary(_ theme: Look.Theme) -> some View {
        switch feed.older {
        case .loading, .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Loading earlier messages…",
                            comment: "总控台：群聊页，向前加载更早记录"))
                Button(String(localized: "Cancel", comment: "总控台：群聊页，取消更早记录加载")) {
                    feed.cancelOlder()
                }
                .buttonStyle(.link)
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity)
        case .atEnd:
            boundaryText(String(localized: "You have reached the earliest message.",
                                comment: "总控台：群聊页，已到最早记录"), theme: theme)
        case .gap:
            HStack(spacing: 8) {
                Text(String(localized: "Some earlier records could not be read.",
                            comment: "总控台：群聊页，更早记录有损坏"))
                if feed.canLoadOlder {
                    Button(String(localized: "Continue", comment: "总控台：群聊页，继续加载")) {
                        feed.loadOlder()
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity)
        case .cancelled:
            HStack(spacing: 8) {
                Text(String(localized: "Loading earlier messages was cancelled.",
                            comment: "总控台：群聊页，更早记录加载被取消"))
                if feed.canLoadOlder {
                    Button(String(localized: "Continue", comment: "总控台：群聊页，继续加载")) {
                        feed.loadOlder()
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity)
        case let .failed(why):
            HStack(spacing: 8) {
                Text(String(localized: "Could not load earlier messages (\(why)).",
                            comment: "总控台：群聊页，更早记录加载失败"))
                if feed.canLoadOlder {
                    Button(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮")) {
                        feed.loadOlder()
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity)
        case .idle:
            if feed.canLoadOlder {
                Button(String(localized: "Load earlier messages",
                              comment: "总控台：群聊页，主动加载更早记录")) {
                    feed.loadOlder()
                }
                .buttonStyle(.link)
                .font(.system(size: Look.Font.min))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func boundaryText(_ text: String, theme: Look.Theme) -> some View {
        HStack(spacing: 8) {
            line(theme)
            Text(text)
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textTertiary.color)
                .fixedSize()
            line(theme)
        }
        .frame(maxWidth: .infinity)
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

    private func jumpPill(_ theme: Look.Theme) -> some View {
        Button {
            // The person asked for the bottom: an explicit intent, not a
            // scroll position this view guessed.
            newBelow = false
            requestFollow()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                Text(newBelow
                    ? String(localized: "New messages · jump to latest",
                             comment: "总控台：群聊页，有新消息且不在底部")
                    : String(localized: "Jump to latest", comment: "总控台：群聊页，回到最新"))
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
    var report: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.handle = handle
        probe.onAttach = onAttach
        probe.onVisible = onVisible
        probe.onUserScroll = onUserScroll
        probe.report = report
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.handle = handle
        view.onAttach = onAttach
        view.onVisible = onVisible
        view.onUserScroll = onUserScroll
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
        var report: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private var observer: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?
        private var liveObservers: [NSObjectProtocol] = []
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
                    if value { self.onUserScroll?() }
                })
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
            for item in liveObservers { NotificationCenter.default.removeObserver(item) }
            liveObservers = []
            handle?.scrollView = nil
            handle?.probe = nil
            handle?.userScrolling = false
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
        .onAppear { register() }
        .onDisappear { unregister() }
        .onChange(of: generation) { _ in reacquire() }
        .onChange(of: row.message.contentVersion) { _ in reacquire() }
    }

    private var authorText: String {
        if !row.message.author.isEmpty { return row.message.author }
        if row.message.fromSelf {
            return String(localized: "You", comment: "总控台：群聊页，自己发的消息作者名")
        }
        return ""
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

    private func register() {
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
    private func reacquire() {
        unregister()
        register()
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
            if feed.rows.isEmpty {
                placeholder
            } else {
                ControlRoomNativeChatView(
                    feed: feed, locatedHit: locatedHit, onReference: onReference)
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
