import AppKit
import SwiftUI

/// The General section (settings.md §7): a list of groups, and the group's
/// page. The groups drawn from the core's form table are placeholders until
/// the host has that table; Keyboard Shortcuts, Advanced and About need
/// nothing from it and are here now.
@MainActor
final class GeneralModel: ObservableObject {
    @Published private(set) var group: GeneralGroup = GeneralGroup.allCases[0]
    /// What the last action said, in the bottom bar.
    @Published var status: String?

    func select(_ group: GeneralGroup) {
        guard group != self.group else { return }
        self.group = group
        status = nil
    }

    func route(to item: String?, fresh: Bool) {
        select(GeneralRules.groupToSelect(item: item, fresh: fresh, current: group))
    }

    var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    /// The host's own file opener, not `open_config`: that now opens this
    /// window.
    func openConfigFile() {
        ghostty?.openConfig()
    }

    func reloadConfig() {
        guard let ghostty else { return }
        ghostty.reloadConfig()
        status = String(localized: "Configuration reloaded.", comment: "设置窗口·通用：重新加载配置之后底栏的提示")
    }
}

/// The section's three parts on the settings grid (§2.3a): the group list,
/// the group's page, and the bottom bar.
struct GeneralView: View {
    enum Part { case list, detail, bar }

    @ObservedObject var model: GeneralModel
    var part: Part

    private typealias L = SettingsLayout

    @FocusState private var listFocused: Bool

    var body: some View {
        switch part {
        case .list: list
        case .detail: detail
        case .bar: bar
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(spacing: L.rowGap / 4) {
                ForEach(GeneralGroup.allCases) { group in
                    SettingsRow(selected: model.group == group) {
                        Text(group.title)
                            .foregroundStyle(group.needsForm ? .secondary : .primary)
                    }
                    .onTapGesture {
                        listFocused = true
                        model.select(group)
                    }
                }
            }
            .padding(.vertical, L.rowGap)
        }
        .settingsListFocus()
        .focused($listFocused)
        .onMoveCommand { direction in
            guard let delta = direction.rowDelta,
                  let next = SettingsRules.step(from: model.group, in: GeneralGroup.allCases, by: delta)
            else { return }
            model.select(next)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if model.group.needsForm {
            VStack {
                Spacer()
                Text(String(localized: "Coming in a later update.", comment: "设置窗口：项目/插件栏目第一期的占位文字"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let ghostty = model.ghostty {
            switch model.group {
            case .keybinds: GeneralKeybinds(ghostty: ghostty)
            case .advanced: GeneralAdvanced(ghostty: ghostty)
            default: GeneralAbout()
            }
        } else {
            GeneralAbout()
        }
    }

    // MARK: Bar

    /// Status on the left, the group's own actions on the right (§2.3a).
    private var bar: some View {
        HStack(spacing: L.rowGap) {
            if let status = model.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            switch model.group {
            case .keybinds:
                Button(String(localized: "Edit in Config File…", comment: "设置窗口·通用：快捷键组，在配置文件里改快捷键")) {
                    model.openConfigFile()
                }
            case .advanced:
                Button(String(localized: "Open config file…", comment: "设置窗口：通用栏目，用外部编辑器打开配置文件")) {
                    model.openConfigFile()
                }
                Button(String(localized: "Reload Configuration", comment: "配置有错时的提示条")) {
                    model.reloadConfig()
                }
            default:
                EmptyView()
            }
        }
        .controlSize(.large)
        .padding(.leading, L.ContentEdge.bottomBar)
        .padding(.trailing, L.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keyboard Shortcuts: the same listing as the "Keyboard Shortcuts…" window
/// and the Windows page -- one row per action, name (tag under it), keys,
/// note -- read afresh whenever the configuration changes.
private struct GeneralKeybinds: View {
    @ObservedObject var ghostty: Ghostty.App

    private typealias L = SettingsLayout
    private typealias C = GeneralRules.KeybindColumns

    var body: some View {
        let rows = KeybindsModel.rows(config: ghostty.config.config)
        GeometryReader { geometry in
            let below = GeneralRules.keybindNoteBelow(contentWidth: geometry.size.width - 2 * L.pad)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: L.rowGap) {
                    Text(String(localized: "\(String(rows.count)) actions. Some have no shortcut yet.", comment: "快捷键一览窗口"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        if below {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: C.gap) {
                                    name(row)
                                    keys(row)
                                }
                                if !row.note.isEmpty {
                                    note(row).padding(.leading, C.name + C.gap)
                                }
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: C.gap) {
                                name(row)
                                keys(row)
                                note(row)
                            }
                        }
                    }
                }
                .padding(L.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The name first, the tag under it (the tag is what a config file is
    /// written in).
    private func name(_ row: KeybindRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name ?? row.action)
                .font(row.name == nil ? .system(.body, design: .monospaced) : .body)
            if row.name != nil {
                Text(row.action)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: C.name, alignment: .leading)
    }

    /// Each key an unbreakable block; a dash when there is none.
    private func keys(_ row: KeybindRow) -> some View {
        Text(KeybindsModel.keysLabel(row.keys))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(row.keys.isEmpty ? .secondary : .primary)
            .frame(width: C.keys, alignment: .leading)
    }

    private func note(_ row: KeybindRow) -> some View {
        Text(row.note)
            .font(.caption)
            .foregroundStyle(row.hiddenFromMenu ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Advanced: the configuration errors of the configuration now loaded
/// (the same list the errors window shows), updated on every reload.
/// Opening and reloading the file are in the bottom bar.
private struct GeneralAdvanced: View {
    @ObservedObject var ghostty: Ghostty.App

    private typealias L = SettingsLayout

    var body: some View {
        let errors = ghostty.config.errors
        ScrollView {
            VStack(alignment: .leading, spacing: L.rowGap) {
                Text(String(localized: "Configuration Errors", comment: "设置窗口·通用：高级组，配置错误列表的标题"))
                    .font(.headline)
                if errors.isEmpty {
                    Text(String(localized: "The configuration loaded without errors.", comment: "设置窗口·通用：高级组，没有配置错误"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "\(String(errors.count)) error(s). The lines they name were ignored; fix them and reload.", comment: "设置窗口·通用：高级组，配置错误的条数"))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: L.rowGap / 2) {
                        ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                            Text(error)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(L.rowGap)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .padding(L.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// About: version, build and commit, from the bundle -- the same three the
/// About window shows.
private struct GeneralAbout: View {
    private typealias L = SettingsLayout

    var body: some View {
        let info = Bundle.main.infoDictionary
        let rows = GeneralRules.aboutRows(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            commit: info?["PolterCommit"] as? String)
        VStack(alignment: .leading, spacing: L.groupGap) {
            HStack(spacing: L.pad) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Polter")
                        .font(.title2.weight(.semibold))
                    Text(String(localized: "A terminal that minds the agents running in it. \nBuilt on Ghostty.", comment: "关于窗口"))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: L.rowGap) {
                ForEach(rows, id: \.label) { row in
                    formRow(label(row.label)) {
                        Text(row.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
        }
        .padding(L.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ label: GeneralRules.AboutRow.Label) -> String {
        switch label {
        case .version: String(localized: "Version", comment: "设置窗口·通用：关于组，版本")
        case .build: String(localized: "Build", comment: "设置窗口·通用：关于组，构建号")
        case .commit: String(localized: "Commit", comment: "设置窗口·通用：关于组，提交号")
        }
    }
}
