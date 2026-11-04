import SwiftUI

/// The group chat's messages, drawn natively (task 2791, #2791; the stable
/// row identity, task 2800 S2c-2a).
///
/// **A view and nothing else.** It is handed the rows it draws and asks
/// nobody for them: where a batch comes from, which group it is about, and
/// when to ask again are the feed's. That is deliberate -- a view that also
/// fetched would be untestable without a core, and "it drew nothing" and
/// "the request failed" would look the same.
///
/// **Keyed by the row's display id, never by `seq`.** `seq` is the group's
/// own count: several history records carry `seq = 0`, and two core runs
/// reuse the same numbers, so a list keyed by it would fold distinct
/// messages into one row. The id is the first core anchor this feed saw for
/// that message and does not change when the core later calls the same
/// message by its persisted anchor.
///
/// **No styling of its own yet.** The face is the system body face and the
/// colours are the system's, so that this slice adds no size and no colour
/// to the tables the control room's look comes from.
struct ControlRoomNativeChatView: View {
    var rows: [ControlRoomChatFeed.Row]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
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
                        Text(row.message.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                ControlRoomNativeChatView(rows: feed.rows)
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
