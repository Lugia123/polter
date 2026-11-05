import SwiftUI

/// The chat page's fixed header (DESIGN-v2 §4): the group's name, its brief
/// in at most two lines with an expand control, and the member count with a
/// read-only member list.
///
/// **It does not scroll.** The messages below it move; this does not, which
/// is what makes the group a reader is in stay named while they read.
///
/// **Values in, a view out.** The group's own facts come from the feed's
/// `chat_metadata` answer; nothing here asks the core or guesses a brief, a
/// member or a role the core did not send. A failed or missing answer says
/// so instead of drawing an empty group.
struct ControlRoomChatHeader: View {
    typealias Look = ControlRoomLook

    var group: String
    @ObservedObject var feed: ControlRoomChatFeed
    /// The page's search slot. Nil in a build that has no search feed; the
    /// button is simply not there then.
    var onSearch: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var briefExpanded = false
    @State private var membersShown = false

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group)
                    .font(.system(size: Look.Font.groupName, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group)
                Spacer(minLength: 8)
                if let onSearch {
                    Button(action: onSearch) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text(String(localized: "Search messages",
                                        comment: "总控台：群聊页头部，打开群内消息搜索"))
                        }
                        .font(.system(size: Look.Font.min))
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.textSecondary.color.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    // **No chord in the hint**: the chat page has no ⌘F of
                    // its own (it is not a key equivalent here), and a hint
                    // naming one is a promise nothing answers.
                    .help(String(localized: "Search this group",
                                 comment: "总控台：群聊页头部，搜索按钮提示"))
                }
                if let facts = ready {
                    memberButton(facts, theme: theme)
                }
            }
            brief(theme)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.terminalBackground.color)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.textSecondary.color.opacity(0.18))
                .frame(height: Look.Line.hairline)
        }
    }

    private var ready: ControlRoomChatMetadata.Group? {
        guard case let .ready(facts) = feed.metadata else { return nil }
        return facts
    }

    // MARK: - Brief

    @ViewBuilder
    private func brief(_ theme: Look.Theme) -> some View {
        switch feed.metadata {
        case .idle, .loading:
            Text(String(localized: "Reading group info…", comment: "总控台：群聊页头部，正在读取群信息"))
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textTertiary.color)
        case let .failed(code):
            Text(String(localized: "Group info is unavailable.", comment: "总控台：群聊页头部，群信息读取失败"))
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textSecondary.color)
                .help(code)
                .textSelection(.enabled)
        case let .ready(facts):
            if !facts.brief.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(facts.brief)
                        .font(.system(size: Look.Font.min))
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(briefExpanded ? nil : 2)
                        .textSelection(.enabled)
                    if ControlRoomChatPresentation.showsBriefToggle(facts.brief) {
                        Button {
                            briefExpanded.toggle()
                        } label: {
                            Text(briefExpanded
                                ? String(localized: "Collapse", comment: "总控台：群聊页头部，收起简述")
                                : String(localized: "Expand", comment: "总控台：群聊页头部，展开简述"))
                                .font(.system(size: Look.Font.min))
                                .foregroundStyle(theme.textSecondary.color)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Members

    private func memberButton(
        _ facts: ControlRoomChatMetadata.Group,
        theme: Look.Theme
    ) -> some View {
        Button {
            membersShown.toggle()
            if membersShown { feed.refreshMetadata() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                Text(memberCount(facts))
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.textSecondary.color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $membersShown, arrowEdge: .bottom) {
            memberPopover(facts, theme: theme)
        }
    }

    private func memberCount(_ facts: ControlRoomChatMetadata.Group) -> String {
        // An explicit format key: the repo already ships "%d members", and
        // an interpolated key would be a second spelling of the same words.
        String(
            format: String(localized: "%d members", comment: "总控台：群聊页头部，成员数"),
            Int(facts.memberCount)
        )
    }

    private func memberPopover(
        _ facts: ControlRoomChatMetadata.Group,
        theme: Look.Theme
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(memberCount(facts))
                .font(.system(size: Look.Font.min, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(facts.members, id: \.id) { member in
                        HStack(spacing: 6) {
                            Text(member.title.isEmpty ? member.id : member.title)
                                .font(.system(size: Look.Font.min))
                                .lineLimit(1)
                            if let role = member.role, !role.isEmpty {
                                Text(role)
                                    .font(.system(size: Look.Font.min))
                                    .foregroundStyle(theme.textSecondary.color)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(theme.textSecondary.color.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
            if facts.membersTruncated {
                Divider()
                Text(String(
                    format: String(localized: "Showing the first %d members.",
                                   comment: "总控台：群聊页头部，成员列表被截断"),
                    Int(facts.members.count)
                ))
                    .font(.system(size: Look.Font.min))
                    .foregroundStyle(theme.textTertiary.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Divider()
            Text(String(localized: "Read-only: viewing members sends nothing.",
                        comment: "总控台：群聊页头部，成员弹层只读说明"))
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textTertiary.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 240, alignment: .leading)
    }
}
