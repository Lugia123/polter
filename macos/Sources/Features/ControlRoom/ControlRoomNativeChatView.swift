import SwiftUI

/// The group chat's messages, drawn natively (task 2791, #2791): the list
/// the chat page is being moved onto, in place of the `polter +chat`
/// terminal (`ControlRoomChat.swift`, which is the shape being replaced one
/// slice at a time).
///
/// **A view and nothing else.** It is handed the messages it draws and asks
/// nobody for them: where a batch comes from, which group it is about, and
/// when to ask again are the caller's (a later slice's feed, and
/// `ControlRoomChatContainer`'s wiring). That is deliberate -- a view that
/// also fetched would be untestable without a core, and "it drew nothing"
/// and "the request failed" would look the same.
///
/// **Keyed by `seq`, the group's own count.** It is the identity inside one
/// core run, which is what a list of rows needs; `log_seq` is the cursor one
/// pages with and is 0 for a message never written down.
///
/// **No styling of its own yet.** The face is the system body face and the
/// colours are the system's, so that this slice adds no size, no colour and
/// no sentence to the tables the control room's look and its translations
/// come from. The design's own sizes and colours are `ControlRoomLook`'s and
/// arrive with the slice that draws the rest of the row.
struct ControlRoomNativeChatView: View {
    var messages: [ControlRoomChatData.Message]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.seq) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(message.author)
                                .font(.body)
                                .fontWeight(.semibold)
                            if let role = message.role, !role.isEmpty {
                                Text(role)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(message.text)
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
/// reason there are none when there is one (task 2791).
///
/// **It draws and does nothing else.** It does not start or stop the feed:
/// which group is in front, and whether anybody can see it, are things only
/// the container knows (`ControlRoomChatContainer.show` and its
/// `applyVisibility`), and a second owner here would be two answers about
/// whether the page is asking the core -- the one that is on screen being
/// whichever ran last.
///
/// **The refusal is the core's own words, drawn as they came.** They are not
/// a paragraph of this application's, so nothing here is a string the
/// translation tables would want -- and a host that reworded a refusal would
/// be answering a second time about why there is nothing to show.
struct ControlRoomNativeChatPane: View {
    var group: String
    @ObservedObject var feed: ControlRoomChatFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let trouble = feed.trouble {
                Text(trouble)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .textSelection(.enabled)
            }
            ControlRoomNativeChatView(messages: feed.messages)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel(group)
    }
}
