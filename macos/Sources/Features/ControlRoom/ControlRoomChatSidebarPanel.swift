import SwiftUI

/// The chat's search, drawn in the one right-hand slot (DESIGN-v2 §11.2).
///
/// **Its state is the feed's**, never a copy: typing goes to the feed, a page
/// is merged by the feed, and the panel only draws. Closing goes back through
/// the page, which owns the slot.
struct ControlRoomChatSidebarPanel: View {
    typealias Look = ControlRoomLook
    typealias S = ControlRoomChatSearch

    @ObservedObject var feed: ControlRoomChatSearchFeed
    /// The message feed whose `locate` the page asked: **the left side's
    /// state, drawn on the right** (DESIGN-v2 §11.3). A locate that is still
    /// out and one that failed are different words, and both are shown
    /// above the results, which stay on screen either way.
    var locating = false
    var locateFailed: String?
    var onClose: () -> Void
    /// A result was picked: the page locates its original conversation.
    var onLocate: ((S.Hit) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            header(theme)
            field(theme)
            status(theme)
            locateStatus(theme)
            Divider()
            results(theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.terminalBackground.color)
        .onAppear {
            text = feed.state.query
            fieldFocused = true
        }
    }

    // MARK: - Header and field

    private func header(_ theme: Look.Theme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textSecondary.color)
            Text(String(localized: "Find in this group",
                        comment: "总控台：群聊页，搜索面板标题"))
                .font(.system(size: Look.Font.min, weight: .semibold))
                .foregroundStyle(theme.text.color)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: Look.Font.min))
                    .foregroundStyle(theme.textSecondary.color)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Close search", comment: "总控台：群聊页，关闭搜索"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.textSecondary.color.opacity(0.06))
    }

    private func field(_ theme: Look.Theme) -> some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "Search this group…", comment: "总控台：群聊页，搜索输入框占位"),
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: Look.Font.min))
            .focused($fieldFocused)
            .onChange(of: text) { value in
                // The field is the only writer of the query; the feed owns
                // the debounce.
                feed.setQuery(value)
            }
            .onSubmit { feed.submitNow() }
            if !text.isEmpty {
                Button {
                    text = ""
                    feed.setQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Look.Font.min))
                        .foregroundStyle(theme.textTertiary.color)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.textSecondary.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Status

    @ViewBuilder
    private func status(_ theme: Look.Theme) -> some View {
        HStack(spacing: 6) {
            switch feed.state.search {
            case .idle:
                Text(String(localized: "Type something to search",
                            comment: "总控台：群聊页，搜索空输入提示"))
            case .emptyQuery:
                Text(String(localized: "Type something to search",
                            comment: "总控台：群聊页，搜索空输入提示"))
            case .waiting, .searching:
                ProgressView().controlSize(.small)
                Text(String(localized: "Searching…", comment: "总控台：群聊页，正在搜索"))
            case .scanningMore:
                Text(String(localized: "Found \(feed.state.hits.count) · still searching",
                            comment: "总控台：群聊页，已有结果但仍在扫描"))
                Spacer(minLength: 0)
                Button(String(localized: "Load more", comment: "总控台：群聊页，加载更多搜索结果")) {
                    feed.loadMore()
                }
                .buttonStyle(.link)
            case .results:
                if feed.state.complete, !feed.state.hitsTrimmed {
                    Text(String(localized: "\(feed.state.hits.count) results",
                                comment: "总控台：群聊页，完整搜索结果数"))
                } else {
                    Text(String(localized: "Found \(feed.state.hits.count) · not complete",
                                comment: "总控台：群聊页，结果不完整或按窗口截断"))
                }
            case .paused:
                Text(String(localized: "Paused", comment: "总控台：群聊页，搜索已暂停"))
                Spacer(minLength: 0)
                if feed.state.hasMore {
                    Button(String(localized: "Load more", comment: "总控台：群聊页，加载更多搜索结果")) {
                        feed.loadMore()
                    }
                    .buttonStyle(.link)
                }
            case .noResults:
                Text(String(localized: "No matches", comment: "总控台：群聊页，搜索无结果"))
            case .partial:
                Text(String(localized: "Found \(feed.state.hits.count) · some records could not be read",
                            comment: "总控台：群聊页，搜索遇到坏记录"))
                Spacer(minLength: 0)
                Button(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮")) {
                    feed.retry()
                }
                .buttonStyle(.link)
            case let .failed(code):
                Text(String(localized: "Search failed (\(code)).",
                            comment: "总控台：群聊页，搜索失败及核心错误码"))
                Spacer(minLength: 0)
                Button(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮")) {
                    feed.retry()
                }
                .buttonStyle(.link)
            case .cancelled:
                Text(String(localized: "Search cancelled", comment: "总控台：群聊页，搜索已取消"))
                Spacer(minLength: 0)
                Button(String(localized: "Try Again", comment: "总控台：群聊页，读取失败后的重试按钮")) {
                    feed.retry()
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: Look.Font.min))
        .foregroundStyle(theme.textSecondary.color)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// The left side's state, said on the right. **Nothing while there is
    /// nothing to say**; the results below are never cleared by either.
    @ViewBuilder
    private func locateStatus(_ theme: Look.Theme) -> some View {
        if locating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Locating…",
                            comment: "总控台：群聊页，正在定位搜索结果"))
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        } else if let locateFailed {
            Text(String(localized: "Could not locate that message.",
                        comment: "总控台：群聊页，搜索结果定位失败"))
                .font(.system(size: Look.Font.min))
                .foregroundStyle(theme.textSecondary.color)
                .help(locateFailed)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ theme: Look.Theme) -> some View {
        if !feed.state.hits.isEmpty {
            if feed.state.hitsTrimmed {
                Text(String(localized: "Showing the matches around this point; search again for the newest.",
                            comment: "总控台：群聊页，搜索结果按滑动窗口保留"))
                    .font(.system(size: Look.Font.min))
                    .foregroundStyle(theme.textTertiary.color)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(feed.state.hits, id: \.message.anchor) { hit in
                        resultCard(hit, theme: theme)
                    }
                }
                .padding(8)
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func resultCard(_ hit: S.Hit, theme: Look.Theme) -> some View {
        let selected = feed.state.selected == hit.message.anchor
        return Button {
            feed.select(hit.message.anchor)
            onLocate?(hit)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if hit.message.summary {
                        Text(ControlRoomChatPresentation.summaryText())
                            .font(.system(size: Look.Font.min, weight: .semibold))
                            .foregroundStyle(theme.text.color)
                    } else {
                        Text(hit.message.author)
                            .font(.system(size: Look.Font.min, weight: .semibold))
                            .foregroundStyle(theme.text.color)
                        if let role = hit.message.role, !role.isEmpty {
                            Text(role)
                                .font(.system(size: Look.Font.min))
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    Text(ControlRoomChatPresentation.channelText(channel: hit.message.channel))
                        .font(.system(size: Look.Font.min))
                        .foregroundStyle(theme.textSecondary.color)
                    Spacer(minLength: 0)
                    // **A full local date and time**: a search spans days,
                    // and two equal clock times are not the same moment.
                    Text(ControlRoomChatPresentation.dateText(atMs: hit.message.atMs, nowMs: nowMs)
                         + " " + ControlRoomChatPresentation.timeText(atMs: hit.message.atMs))
                        .font(.system(size: Look.Font.min))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                }
                Text(highlighted(hit, theme: theme))
                    .font(.system(size: Look.Font.min))
                    .lineLimit(3)
                    .foregroundStyle(theme.text.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(selected
                ? theme.textSecondary.color.opacity(0.16)
                : theme.textSecondary.color.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: Look.Radius.row))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Look.Radius.row)
                        .stroke(theme.textSecondary.color.opacity(0.35),
                                lineWidth: Look.Line.hairline)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// The snippet with only the core's ranges marked. The ranges were
    /// validated as UTF-8 scalar boundaries at decode; the mapping drops a
    /// range it cannot express rather than moving it.
    private func highlighted(_ hit: S.Hit, theme: Look.Theme) -> AttributedString {
        var text = AttributedString(hit.snippet)
        for range in S.stringRanges(hit.snippet, ranges: hit.ranges) {
            guard let attributedRange = Range(range, in: text) else { continue }
            // **The look's colour, not a view's own yellow** (task 2982):
            // the same `search_hit` the message body uses, so the snippet
            // and the located message cannot come to differ.
            text[attributedRange].backgroundColor = theme.searchHit.color
            text[attributedRange].foregroundColor = theme.text.color
        }
        return text
    }
}
