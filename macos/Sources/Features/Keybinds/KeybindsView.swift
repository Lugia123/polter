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
            Text("\(rows.count) actions. Some have no shortcut yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            List(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.action)
                        .font(.system(.body, design: .monospaced))
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
