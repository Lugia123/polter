import SwiftUI

/// A help line whose last run is "More…" (or "Less" once open): a link
/// inside the text, so it wraps with the words -- beside the text, a long
/// key squeezed the sentence into a column at the window's narrowest.
///
/// What a screen reader is given is not that text. SwiftUI reports a link
/// run inside a `Text` as an `AXLink` that is not enabled, although a click
/// on it works, so VoiceOver read "More…" as unavailable (seen in the
/// settings window's All Options page, 2026-10-18). The accessibility
/// representation is the sentence and a real link button beside it, which
/// is enabled and toggles the same state.
struct MoreLinkText: View {
    let line: Text
    let hasMore: Bool
    @Binding var showingMore: Bool

    static let moreURL = URL(string: "polter-settings:more")!

    var body: some View {
        let shown = hasMore ? line + Text(verbatim: "  ") + Text(link).font(SettingsFont.minimum) : line
        return shown
            .lineLimit(showingMore ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url == Self.moreURL else { return .systemAction }
                showingMore.toggle()
                return .handled
            })
            .accessibilityRepresentation {
                VStack(alignment: .leading) {
                    line
                    if hasMore {
                        Button(title) { showingMore.toggle() }
                            .buttonStyle(.link)
                    }
                }
            }
    }

    private var title: String {
        showingMore
            ? String(localized: "Less", comment: "设置窗口·通用：收起 Ghostty 原文说明")
            : String(localized: "More…", comment: "设置窗口·通用：展开 Ghostty 原文说明")
    }

    private var link: AttributedString {
        var text = AttributedString(title)
        text.link = Self.moreURL
        return text
    }
}
