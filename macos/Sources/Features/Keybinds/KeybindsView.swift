import SwiftUI
import GhosttyKit

/// The keybind listing.
///
/// **One row per action, and the header says so.** This page has an action
/// count, a binding count and a command count in the same neighbourhood and
/// they are different numbers; naming the column keeps the next reader from
/// taking it for one of the others.
struct KeybindsView: View {
    let rows: [KeybindRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "\(rows.count) actions. Some have no shortcut yet.", comment: "快捷键一览窗口"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            List(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // **The name first, the tag under it.** The tag is what
                    // a config file is written in and it stays on the page
                    // for that reason; it is not what somebody scanning for
                    // "the one that resets the font size" is reading. A page
                    // of `reset_font_size` is in neither language.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name ?? row.action)
                            .font(row.name == nil
                                ? .system(.body, design: .monospaced)
                                : .body)
                        if row.name != nil {
                            Text(row.action)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 220, alignment: .leading)

                    // The keys, or a dash. **A dash rather than an empty
                    // cell**: blank reads as a rendering failure, and this
                    // page's whole point is that "no key" is a fact worth
                    // showing.
                    Text(row.keys.isEmpty ? "—" : row.keys.joined(separator: "   "))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(row.keys.isEmpty ? .secondary : .primary)
                        .frame(width: 160, alignment: .leading)

                    Text(row.note)
                        .font(.caption)
                        .foregroundStyle(row.hiddenFromMenu ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
