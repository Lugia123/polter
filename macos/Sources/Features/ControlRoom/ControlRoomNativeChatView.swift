import AppKit
import OSLog
import SwiftUI

/// The group chat's transcript, and **the one decision this file still
/// makes: which of its two forms draws it** (task 3084; the page and its
/// wire contract are `web/chat/CONTRACT.md`).
///
/// **The page is the list.** `ControlRoomChatTranscriptPage.isEnabled` (the
/// process was not asked for `POLTER_CHAT_WEB=0`) puts
/// `ControlRoomChatWebView` in the pane; the page parses and draws the
/// Markdown, keeps the scroll position, and reports what the reader did
/// through one channel. What is left here is the host's side of that: which
/// rows exist (`pageMessages`), whether older history is still out, what a
/// link means -- and the feed's own transfers when a page lands in an apron.
///
/// **The fallback is a plain list, not a second scroll model.** A page that
/// is not drawing -- asked for away with `POLTER_CHAT_WEB=0`, or a page that
/// never said `chat.ready` -- is the messages' raw text in one `ScrollView`.
/// Nothing in it writes where the reader is, follows a new message, or
/// measures a row: the scroll view owns its position and the feed owns
/// which rows exist. It exists so a page that will not load is a diagnosis
/// rather than a blank group chat (design v3 §五).
///
/// **The old native list is gone** (design v3 §七). The camera, the anchor,
/// the window plan, the line table, the index bar, the seek and the landing
/// placeholders were the other thing `POLTER_CHAT_WEB=0` used to mean; they
/// went with it, and their tests with them.
struct ControlRoomNativeChatView: View {
    typealias Look = ControlRoomLook

    @ObservedObject var feed: ControlRoomChatFeed
    /// The search hit the window was located to, when a search result was
    /// picked. Its offsets are what marks the matched text inside the
    /// message (`ControlRoomChatDisplayHighlight`). The page does its own
    /// marking; the plain fallback marks the row only.
    var locatedHit: ControlRoomChatSearch.Hit?
    var onReference: ((ControlRoomChatData.Message, String?) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    /// **The page never said `chat.ready`.** The one-page watchdog
    /// (`ControlRoomChatPageBridge.watchForReady`) is the only failure
    /// WebKit gives us for "the page's script did not run"; this is that
    /// word, kept. **One way only**: a page that speaks after this is not
    /// switched back over a list the reader can already read.
    @State private var pageUnready = false

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var body: some View {
        let theme = Look.theme(scheme)
        Group {
            if ControlRoomChatTranscriptPage.isEnabled, !pageUnready {
                page(theme)
            } else {
                plainList(theme)
            }
        }
        .onAppear {
            // **Both forms draw the feed's rows whole.** The page can only
            // be told to grow (or to be replaced with a smaller document it
            // knows about), and the plain list draws every row it is given;
            // neither may have a row taken out from under the reader by the
            // feed's memory retainer (task 3084,
            // `ControlRoomChatFeed.keepsWholeDocument`).
            feed.keepsWholeDocument = true
        }
        // **A page landing in an apron is a reason to look again.** Neither
        // form has a viewport window to maintain, and without this an older
        // page that `feed.loadOlder()` correctly fetched would sit in
        // `above` forever and the transcript would never grow upwards.
        // `feedOlder` returns 0 on an empty apron, so `aboveCount` and
        // `older` are one transfer, not two.
        .onChange(of: feed.aboveCount) { _ in
            feed.feedOlder(rows: feed.aboveCount, maxHeight: 0)
        }
        .onChange(of: feed.belowCount) { _ in
            feed.feedNewer(rows: feed.belowCount, maxHeight: 0)
        }
        .onChange(of: feed.older) { _ in
            feed.feedOlder(rows: feed.aboveCount, maxHeight: 0)
        }
    }

    // MARK: - The page (task 3084)

    /// **The page, and the questions it may ask** (`CONTRACT.md` §4). It
    /// draws nothing here: every closure below answers a question the page
    /// put to the host, and `pageMessages` is the state it is told.
    private func page(_ theme: Look.Theme) -> some View {
        ControlRoomChatWebView(
            messages: pageMessages,
            // **The page's `hasEarlier` is the feed's own word about the
            // beginning**, not "a page is out": while a load is in flight
            // more history does exist, and answering false there would
            // show the reader "start of history" on a list that is not.
            hasEarlier: !feed.reachedBeginning,
            theme: ControlRoomChatTranscriptPage.Theme(look: theme),
            located: feed.locatedAnchor,
            // **The place a closed chat was left at** (task 3096 #4). The
            // bridge sends it once, on the first reset; the feed already
            // recentres its resume around this anchor, so the row is loaded
            // when the page asks to land on it.
            reading: feed.restoredPlace,
            // **A failed read is said out loud** (task 3098): the page draws
            // the retry instead of an empty group or "start of history".
            resetError: feed.resetFailure,
            olderError: feed.olderFailure,
            olderSettled: feed.olderSettled,
            // **Nothing to ask is still an answer** (task 3098): when the
            // feed has no older request to make, the bridge owes the page an
            // empty `page.prepend` instead of waiting for one that will
            // never come.
            onOlder: {
                switch feed.loadOlder() {
                case .started:
                    return .started
                case .nothing:
                    return .answered(
                        hasEarlier: !feed.reachedBeginning,
                        error: feed.olderFailure)
                }
            },
            onOpenLink: openWebLink,
            onImageTicket: { src in ControlRoomChatTranscriptPage.imagePayload(for: src) },
            onMenu: { id, x, y in
                // Not wired this slice (task 3084): the page's native menu
                // arrives whole in a later one, and the log is the evidence
                // it arrived at all.
                ControlRoomChatTranscriptPage.log.notice(
                    "menu: id=\(id, privacy: .public) x=\(Int(x), privacy: .public) y=\(Int(y), privacy: .public)")
            },
            onCopy: { text in
                ControlRoomChatTranscriptPage.log.notice(
                    "copy: chars=\(text.count, privacy: .public)")
            },
            onFollow: { follow, pendingMessageCount in
                ControlRoomChatTranscriptPage.log.notice(
                    "follow: follow=\(follow ? 1 : 0, privacy: .public) pending=\(pendingMessageCount, privacy: .public)")
            },
            // **The page never said `chat.ready`**: the watchdog's word,
            // taken as the fallback's trigger (design v3 §五: a page that
            // will not load shows the plain list rather than nothing).
            onUnready: {
                ControlRoomChatTranscriptPage.log.error(
                    "fallback: no chat.ready; drawing the plain list")
                pageUnready = true
            },
            // **Where the reader is** (task 3096 #4). The feed keeps the
            // last one; the container stores it when the group is left, and
            // only when the reader was not at the bottom (`following`).
            onReading: { anchor, offset, following in
                feed.reading(anchor: anchor, offset: offset, following: following)
            },
            // **"Back to latest"** (task 3096 #5). The page's own scroll can
            // only reach the end of what is loaded; when the host is holding
            // a located window (a search result's around page), that end is
            // not the conversation's newest, so the feed is rebuilt at the
            // newest. A live window needs nothing: the page has already
            // scrolled to its real end.
            onJumpLatest: {
                if feed.locatedAnchor != nil { feed.returnToLatest() }
            }
        )
    }

    // MARK: - The fallback: a plain list (design v3 §五)

    /// **The same messages, raw.** No Markdown, no measurement, no
    /// position: one `ScrollView` over `feed.rows`, each row drawn by
    /// `ControlRoomNativeChatRow` in its plain form. That form registers no
    /// demand with `ControlRoomChatMarkdownStore`, so `content(...)` answers
    /// its own `.plain(text:)` branch -- the store's plain-text path, not a
    /// second renderer.
    ///
    /// **Older history is asked for by the only thing this list can see**:
    /// the first loaded row appearing means the reader reached the top of
    /// what is loaded. That calls the feed's own `loadOlder`; nothing here
    /// counts rows or works out a position.
    private func plainList(_ theme: Look.Theme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let notice = olderNotice {
                        Text(notice)
                            .font(.system(size: Look.Font.min))
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    ForEach(Array(feed.rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 4) {
                            if needsDivider(index) {
                                dayDivider(row.message.atMs, theme)
                            }
                            ControlRoomNativeChatRow(
                                row: row,
                                group: feed.group ?? "",
                                generation: feed.generation,
                                markdown: feed.markdown,
                                plainText: true,
                                hit: feed.locatedAnchor == row.id ? locatedHit : nil,
                                onReference: onReference
                            )
                        }
                        .onAppear {
                            if index == 0, feed.canLoadOlder { feed.loadOlder() }
                        }
                    }
                    // **The conversation's real end, drawn as a mark** --
                    // the same sentence and hairline the native list used.
                    if feed.reachedEnd {
                        endBoundary(theme, String(
                            localized: "This is the newest message.",
                            comment: "总控台：群聊页，已到最新一条记录（终点分割线，不可点）"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                // **It opens on the newest message** (task 3002's ruling),
                // through the scroll view's own placement -- not a second
                // position model: nothing records it and nothing restores it.
                if let last = feed.rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// **The page that could not be read has to say so somewhere.** The
    /// index bar used to carry this sentence; it went with the bar (design
    /// v3 §七), so the fallback carries it at the top of the list. A
    /// cancellation says nothing: it is the state `stop()` leaves behind,
    /// and a reader who stopped the scan already knows.
    private var olderNotice: String? {
        switch feed.older {
        case .failed:
            return String(localized: "Earlier records could not be read.",
                          comment: "总控台：群聊页，更早记录读取失败（纯文本回退）")
        case .gap:
            return String(localized: "Some earlier records could not be read.",
                          comment: "总控台：群聊页，更早记录有损坏（纯文本回退）")
        case .idle, .loading, .scanning, .atEnd, .cancelled:
            return nil
        }
    }

    // MARK: - Rows and days

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
    /// The feed, as the page's messages (`web/chat/CONTRACT.md` §2.1).
    ///
    /// **`text` is the raw Markdown**, not a rendered block: the page parses
    /// it once, and that is what the page is for. The two separators are
    /// decided here because both are questions about the neighbours, and the
    /// neighbours are the feed's.
    private var pageMessages: [ControlRoomChatTranscriptPage.Message] {
        feed.rows.enumerated().map { index, row in
            let message = row.message
            let dayBreak = needsDivider(index)
            return ControlRoomChatTranscriptPage.Message(
                id: row.id,
                seq: message.seq,
                at: message.atMs,
                author: ControlRoomChatPresentation.authorText(
                    author: message.author, fromSelf: message.fromSelf),
                role: message.role,
                text: message.text,
                dayBreak: dayBreak,
                speakerRule: !dayBreak && needsSpeakerRule(index)
            )
        }
    }

    /// **The page's link, answered the way a native row answers its own.**
    ///
    /// The wire contract carries the href but not the message it was drawn
    /// in (`CONTRACT.md` §4.4), so the message is the newest row whose raw
    /// Markdown carries that destination -- which is the row the link was
    /// drawn in for every link the page can produce. External URLs open the
    /// way they always did; a file or terminal reference goes to the side
    /// panel through `onReference`, with the same raw-destination rule the
    /// Markdown view applies (`ControlRoomChatRawReference`).
    private func openWebLink(_ href: String) {
        // An image click arrives here with the image's own source (contract
        // §4.4). A `data:` URL is one this host produced, and the rest are
        // schemes the page itself may load -- none of them is a reference.
        guard !href.hasPrefix("data:"),
              !href.hasPrefix("polter-chat:"),
              !href.hasPrefix("polter-file:")
        else { return }

        // **An image is not a file to preview.** The page no longer sends an
        // image's click (2026-11-09), but a Markdown link can still point at
        // one; a preview of it is a panel that cannot read the path. The
        // file's own header decides, not its name.
        if ControlRoomChatTranscriptPage.isImagePath(href) {
            ControlRoomChatTranscriptPage.log.notice(
                "link: image path ignored \(Self.short(href), privacy: .public)")
            return
        }

        let decoded = href.removingPercentEncoding ?? href
        let message = feed.rows.reversed().first {
            $0.message.text.contains(href) || $0.message.text.contains(decoded)
        }?.message

        guard let url = URL(string: href) else {
            ControlRoomChatTranscriptPage.log.notice(
                "link: unreadable \(Self.short(href), privacy: .public)")
            return
        }
        if let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            if let message {
                onReference?(message, url.absoluteString)
            } else {
                // The same end `resolveReference` reaches for an external
                // link, for a row the loaded window no longer holds.
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let message else {
            ControlRoomChatTranscriptPage.log.notice(
                "link: no message carries \(Self.short(href), privacy: .public)")
            return
        }
        onReference?(
            message,
            ControlRoomChatRawReference.destination(for: url, in: message.text))
    }

    /// A log line is not a place to print a `data:` URL or a 2,000-character
    /// reference; the first part names the destination well enough.
    private static func short(_ text: String) -> String {
        text.count <= 120 ? text : String(text.prefix(120)) + "…"
    }
    private func line(_ theme: Look.Theme) -> some View {
        Rectangle()
            .fill(theme.textSecondary.color.opacity(0.18))
            .frame(height: Look.Line.hairline)
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
    }}

/// One message: its author (or the handover label), role, channel, local
/// time, the terminals it named, and its body.
///
/// **The demand is this row's, and it is registered where the row appears.**
/// `registered` remembers the generation the demand was made under, so the
/// release that follows a page change carries the old generation; the store
/// ignores that release and the new page's demand stays. Repeated `onAppear`
/// is idempotent in the store.
///
/// **A plain row registers no demand** (`plainText`). The store then answers
/// `content(...)` with its own `.plain(text:)` branch -- the source text,
/// nobody parsing anything -- which is exactly what the fallback list draws
/// (design v3 §五). It is the store's plain path, not a second renderer.
private struct ControlRoomNativeChatRow: View {
    typealias Look = ControlRoomLook

    var row: ControlRoomChatFeed.Row
    var group: String
    var generation: UInt64
    @ObservedObject var markdown: ControlRoomChatMarkdownStore
    /// **Draw the raw text and ask the store for nothing** (the fallback
    /// list, design v3 §五). No demand is registered, so the store answers
    /// from its `.plain(text:)` branch; see the type's comment.
    var plainText: Bool = false
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
            content
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(row.message.summary ? theme.textSecondary.color.opacity(0.10) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Look.Radius.row))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // **A plain row is not a demand**: the store's plain branch is
            // what the fallback wants, and a demand would hand it a parse.
            if !plainText { register(generation) }
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
            guard !plainText else { return }
            reacquire(generation: newGeneration)
        }
        .onChange(of: row.message.contentVersion) { _ in
            guard !plainText else { return }
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