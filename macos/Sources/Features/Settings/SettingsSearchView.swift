import SwiftUI

/// What the search found, in place of the page (screenshot.md §12.2): one
/// row for each thing, best first, each under a small line saying where it
/// lives. A setting is the same row, with the same control, as on its own
/// page, and can be changed here; anything else is a line that leads to
/// where it is.
struct SettingsSearchResults: View {
    @ObservedObject var model: SettingsModel
    /// Watched as well: a setting changed from here is drawn again with the
    /// value it now has.
    @ObservedObject var general: GeneralModel

    private typealias L = SettingsLayout

    init(model: SettingsModel) {
        self.model = model
        self.general = model.general
    }

    var body: some View {
        let results = model.results ?? []
        if results.isEmpty {
            // A sentence, not an empty page.
            VStack {
                Spacer()
                Text(ConfigFormRules.localized("No settings match."))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: L.groupGap - L.rowGap) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: L.rowGap / 2) {
                            Button(model.crumb(for: entry.target)) { model.jump(to: entry.target) }
                                .buttonStyle(.link)
                                .font(SettingsFont.minimum)
                            row(entry)
                        }
                    }
                }
                .padding(L.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: SettingsSearch.Entry) -> some View {
        switch entry.target {
        case let .formItem(key, group):
            if let item = general.form?.items.first(where: { $0.key == key }) {
                ConfigFormRow(
                    model: general, item: item,
                    control: ConfigFormRules.control(for: item, in: group), group: group)
                    .disabled(!general.writesAllowed)
            } else {
                plain(entry)
            }
        case let .shortcut(action, _):
            if let shortcut = general.form?.sections.flatMap(\.shortcuts).first(where: { $0.action == action }) {
                ConfigShortcutRow(model: general, shortcut: shortcut)
            } else {
                plain(entry)
            }
        case .role, .project, .plugin, .pluginItem, .keybind:
            plain(entry)
        }
    }

    /// A result that is not a setting of the General form: its name, what
    /// is said about it, and the whole line leads to where it is.
    private func plain(_ entry: SettingsSearch.Entry) -> some View {
        Button {
            model.jump(to: entry.target)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name ?? entry.key ?? "")
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
