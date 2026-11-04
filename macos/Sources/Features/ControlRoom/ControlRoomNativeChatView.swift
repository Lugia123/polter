import SwiftUI

/// The group chat's messages, drawn natively (task 2791, #2791; the demand
/// and Markdown wiring, task 2800 C2b-1).
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
/// **A message's body is the block face**: `ControlRoomChatMarkdownView`
/// draws a document the feed's store parsed off the main thread. While that
/// document is being made the row shows its original text, selectable, with
/// a short note; a row the budget could not admit says so plainly instead of
/// spinning; and no row ever draws another version's document.
struct ControlRoomNativeChatView: View {
    @ObservedObject var feed: ControlRoomChatFeed

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(feed.rows) { row in
                    ControlRoomNativeChatRow(
                        row: row,
                        group: feed.group ?? "",
                        generation: feed.generation,
                        markdown: feed.markdown
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One message: its author and role, and its body.
///
/// **The demand is this row's, and it is registered where the row appears.**
/// `registered` remembers the generation the demand was made under, so the
/// release that follows a page change carries the old generation; the store
/// ignores that release and the new page's demand stays. Repeated `onAppear`
/// is idempotent in the store.
private struct ControlRoomNativeChatRow: View {
    var row: ControlRoomChatFeed.Row
    var group: String
    var generation: UInt64
    @ObservedObject var markdown: ControlRoomChatMarkdownStore

    @State private var registered: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.message.author)
                    .font(.body)
                    .fontWeight(.semibold)
                if let role = row.message.role, !role.isEmpty {
                    Text(role)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { register() }
        .onDisappear { unregister() }
        .onChange(of: generation) { _ in reacquire() }
        .onChange(of: row.message.contentVersion) { _ in reacquire() }
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
            ControlRoomChatMarkdownView(document: document)
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
                .font(.body)
                .textSelection(.enabled)
            note()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The chat page's left half: the group's messages out of the feed, and the
/// reason there are none when there is one (task 2791; the first screen's
/// loading/empty/error states, task 2800 S2c-2a).
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
/// empty and then take it back a moment later. The three states are drawn
/// apart: loading while a page is out, the empty sentence only once a page
/// answered with no rows, and the core's own refusal as it came -- a host
/// that reworded it would be answering a second time about why there is
/// nothing to show.
struct ControlRoomNativeChatPane: View {
    var group: String
    @ObservedObject var feed: ControlRoomChatFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let trouble = feed.trouble {
                Text(trouble)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .textSelection(.enabled)
            }
            if feed.rows.isEmpty {
                placeholder
            } else {
                ControlRoomNativeChatView(feed: feed)
            }
            if feed.canReload {
                Button {
                    feed.reload()
                } label: {
                    Text(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮"))
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
        switch feed.state {
        case .idle, .loading:
            Text(String(localized: "Loading", comment: "终端视图"))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(12)
        case .empty:
            Text(String(localized: "No messages yet.", comment: "总控台：群聊页，历史与实时都没有消息"))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(12)
        case .failed, .ready:
            // The refusal is drawn above; a failed load with no rows has
            // nothing else to say, and a ready page with no rows is empty.
            EmptyView()
        }
    }
}
