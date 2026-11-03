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
            if feed.hasSendDoor {
                ControlRoomChatComposer(group: group, feed: feed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel(group)
    }
}

/// The box the person writes in, and the one press that posts it (task 2791,
/// slice 2).
///
/// **It draws the group it is given and nothing else.** Whether this group
/// is the one in front, and whether there is a door at all, are the feed's
/// (`canPost`) and the container's -- a second copy of that condition here
/// would be two answers about which group a post goes to, and the one on
/// screen would be whichever ran last.
///
/// ⚠️ **A plain Return does not send.** The field is a `TextField` and
/// nothing is bound to its `onSubmit`: Return is how a person accepts an
/// input method's candidate (拼音候选), and a box that posted on it would
/// send a half-typed line every time somebody picked a character. The chord
/// is ⌘↩, which is not one any input method claims, and it is attached to
/// this button only -- which exists only for the group in front.
///
/// **What the last post became of is said in one line, and the three states
/// read differently** (`Posted`): a refusal invites another press, and
/// "may or may not have gone" says so and does not.
struct ControlRoomChatComposer: View {
    var group: String
    @ObservedObject var feed: ControlRoomChatFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let said = status {
                Text(said)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                TextField(String(localized: "Message", comment: "总控台：群聊页，输入框的占位文字"),
                          text: Binding(get: { feed.draft(for: group) },
                                        set: { feed.setDraft($0, for: group) }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                Button(String(localized: "Send", comment: "总控台：群聊页，发送按钮")) {
                    feed.post()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!feed.canPost)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Message", comment: "总控台：群聊页，输入框的占位文字"))
    }

    /// What to say about the last post, if anything.
    ///
    /// **`unknown` says "may or may not have gone" and not "failed"**: the
    /// whole reason the core has three states is that a caller which read
    /// this as a failure would send the message twice.
    private var status: String? {
        switch feed.posted {
        case .none:
            return nil
        case let .confirmed(answer):
            return answer
        case let .refused(why):
            return String(format: String(localized: "Not sent: %@",
                                         comment: "总控台：群聊页，发送被拒绝，%@ 是核心给的原因"), why)
        case let .unknown(why):
            return why.isEmpty
                ? String(localized: "It may or may not have been sent. Check the conversation before sending it again.",
                         comment: "总控台：群聊页，发送结果未知")
                : String(format: String(localized: "It may or may not have been sent (%@). Check the conversation before sending it again.",
                                        comment: "总控台：群聊页，发送结果未知，%@ 是核心给的原因"), why)
        }
    }
}
