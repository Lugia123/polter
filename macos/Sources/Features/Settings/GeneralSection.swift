import AppKit
import SwiftUI
import GhosttyKit

/// The General section (settings.md §7): a list of groups, and the group's
/// page. The first six are the core's form table (`ghostty_app_config_form`),
/// written one key at a time through `ghostty_app_config_set`; Keyboard
/// Shortcuts, Advanced and About need nothing from it.
@MainActor
final class GeneralModel: ObservableObject {
    @Published private(set) var group: GeneralGroup = GeneralGroup.allCases[0]
    /// What the last action said, in the bottom bar.
    @Published var status: String?

    func select(_ group: GeneralGroup) {
        guard group != self.group else { return }
        self.group = group
        status = nil
        // Another group is another page: a refusal on the last one no
        // longer describes anything on screen (#986).
        fieldErrors = ConfigFormRules.errors(fieldErrors, after: .reread)
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
        reloadForm()
        status = String(localized: "Configuration reloaded.", comment: "设置窗口·通用：重新加载配置之后底栏的提示")
    }

    // MARK: Form (§7.2-7.3)

    /// The core's table, as last read. Nil before the first read or when
    /// the core did not answer.
    @Published private(set) var form: ConfigForm?
    /// The core could not be asked, or its answer did not read.
    @Published private(set) var formUnavailable = false
    /// Why the last write of a key was refused, under that key's control.
    @Published private(set) var fieldErrors: [String: String] = [:]
    /// All Options' filter.
    @Published var query = ""
    /// How many writes of each key have been tried; part of the control's
    /// identity, so a refused write still puts the value on disk back.
    @Published private(set) var attempts: [String: Int] = [:]

    /// Read the table again: on opening, after every write, and whenever
    /// the window comes forward -- the file may have been edited by hand
    /// (§7.3).
    func reloadForm(_ read: ConfigFormRules.FormRead = .reread) {
        fieldErrors = ConfigFormRules.errors(fieldErrors, after: read)
        guard let app = ghostty?.app,
              let json = PersonaCatalog.readJSON({ ghostty_app_config_form(app, $0, $1) }),
              let form = ConfigForm.parse(json)
        else {
            formUnavailable = true
            return
        }
        formUnavailable = false
        self.form = form
    }

    /// Write one key (nil = restore the default), then reload the app's
    /// configuration and the table (§7.2 rule 7). A refusal is shown under
    /// the control and the control goes back to the value on disk.
    /// See `ConfigFormRules.formWritesAllowed`.
    var writesAllowed: Bool {
        guard let form else { return false }
        return ConfigFormRules.formWritesAllowed(hostConfigPath: ghostty?.configPath, formMain: form.main)
    }

    func set(_ key: String, _ value: String?) {
        guard let app = ghostty?.app, writesAllowed else { return }
        let result = Self.callSet(app: app, key: key, value: value)
        attempts[key, default: 0] += 1
        status = nil
        if let result, result.ok {
            fieldErrors[key] = nil
            ghostty?.reloadConfig()
            if let wrote = result.wrote {
                status = String(format: String(localized: "Saved to %@.", comment: "设置窗口·通用：写入配置文件之后底栏的提示，%@ 是文件路径"), (wrote as NSString).abbreviatingWithTildeInPath)
            }
        } else {
            fieldErrors[key] = Self.message(for: result)
        }
        // This write's own read: its refusal stays under the control.
        reloadForm(.afterOwnWrite)
    }

    /// The call writes once; a result too long for the buffer is read back
    /// with `ghostty_app_config_set_result` rather than by calling again.
    private static func callSet(app: ghostty_app_t, key: String, value: String?) -> ConfigSetResult? {
        var buf = [CChar](repeating: 0, count: 16 * 1024)
        let cap = UInt(buf.count)
        let size: UInt = key.withCString { k in
            buf.withUnsafeMutableBufferPointer { b in
                if let value {
                    return value.withCString { v in
                        ghostty_app_config_set(app, k, UInt(strlen(k)), v, UInt(strlen(v)), b.baseAddress, cap)
                    }
                }
                return ghostty_app_config_set(app, k, UInt(strlen(k)), nil, 0, b.baseAddress, cap)
            }
        }
        let json: String?
        if size < cap {
            json = String(bytes: buf.prefix(Int(size)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
        } else {
            json = PersonaCatalog.readJSON({ ghostty_app_config_set_result(app, $0, $1) })
        }
        return json.flatMap(ConfigSetResult.parse)
    }

    static func message(for result: ConfigSetResult?) -> String {
        guard let result else {
            return String(localized: "Polter's core did not answer.", comment: "设置窗口·通用：写配置时核心没有回答")
        }
        switch result.code {
        case "invalid_value":
            return result.message ?? String(localized: "Not a valid value for this setting.", comment: "设置窗口·通用：值不合法")
        case "read_only":
            return String(localized: "This setting is set somewhere the form does not write.", comment: "设置窗口·通用：这一项由别处设置，表单不写")
        case "busy":
            return String(localized: "The config file kept changing while it was being written. Try again.", comment: "设置窗口·通用：写入时配置文件一直在变")
        case "unknown_key":
            return String(localized: "This build does not know this setting.", comment: "设置窗口·通用：核心不认识这个键")
        default:
            return result.message ?? String(localized: "The setting could not be written.", comment: "设置窗口·通用：写入失败")
        }
    }

    func openFile(_ path: String) {
        ghostty?.openTextFile(path: path)
    }

    /// The keys an action is bound to, written the way the Keyboard
    /// Shortcuts page writes them; none when it has no binding.
    func keys(of action: String) -> [String] {
        KeybindsModel.rows(config: ghostty?.config.config).first { $0.action == action }?.keys ?? []
    }

    /// The folder a directory setting names: what is written, or, with
    /// nothing written, the default the app is actually using.
    func directory(of item: ConfigForm.Item) -> URL {
        if item.key == "screenshot-directory", let url = ghostty?.config.screenshotDirectory { return url }
        return URL(fileURLWithPath: (item.value as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Ask for a folder. Nil when the person cancelled.
    func chooseDirectory(startingAt start: URL) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Show a folder in the Finder: itself selected when it is there, and
    /// otherwise the nearest folder above it that is.
    func revealDirectory(_ url: URL) {
        var shown = url
        while !FileManager.default.fileExists(atPath: shown.path), shown.pathComponents.count > 1 {
            shown = shown.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([shown])
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

    private var detail: some View {
        detailContent
            // Advanced shows the form's backup, and a route can land there
            // before any form group has been drawn.
            .onAppear { if model.form == nil { model.reloadForm() } }
    }

    @ViewBuilder
    private var detailContent: some View {
        if model.group.needsForm {
            ConfigFormPage(model: model, group: model.group)
        } else if let ghostty = model.ghostty {
            switch model.group {
            case .keybinds: GeneralKeybinds(ghostty: ghostty)
            case .advanced: GeneralAdvanced(ghostty: ghostty, backup: model.form?.backup)
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
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            switch model.group {
            case .appearance, .font, .terminal, .windows, .polter, .all, .screenshot:
                Button(String(localized: "Open config file…", comment: "设置窗口：通用栏目，用外部编辑器打开配置文件")) {
                    model.openConfigFile()
                }
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
                        .font(SettingsFont.minimum)
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
                    .font(SettingsFont.minimumMonospaced)
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
            .font(SettingsFont.minimum)
            .foregroundStyle(row.hiddenFromMenu ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Advanced: the configuration errors of the configuration now loaded
/// (the same list the errors window shows), updated on every reload.
/// Opening and reloading the file are in the bottom bar.
private struct GeneralAdvanced: View {
    @ObservedObject var ghostty: Ghostty.App
    /// Where the copy taken before this run's first write went (§7.1).
    var backup: String?

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
                                .font(SettingsFont.minimumMonospaced)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(L.rowGap)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                }
                Text(String(localized: "Backup", comment: "设置窗口·通用：高级组，设置窗口第一次写配置前留的备份"))
                    .font(.headline)
                    .padding(.top, L.groupGap - L.rowGap)
                if let backup {
                    Text((backup as NSString).abbreviatingWithTildeInPath)
                        .font(SettingsFont.minimumMonospaced)
                        .textSelection(.enabled)
                } else {
                    Text(String(localized: "This window has not written the config file since Polter started, so there is no backup yet.", comment: "设置窗口·通用：高级组，还没有备份"))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(L.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// About: version, build and commit, from the bundle, and the links and
/// copyright the About window used to carry -- "About Polter" opens this
/// group now (settings.md §7).
private struct GeneralAbout: View {
    private typealias L = SettingsLayout

    @Environment(\.openURL) private var openURL

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
            HStack(spacing: L.rowGap) {
                Button("Docs") { openURL(PolterLinks.docs) }
                Button("GitHub") { openURL(PolterLinks.github) }
                Button("Ghostty") { openURL(PolterLinks.upstream) }
            }
            if let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String, !copyright.isEmpty {
                Text(copyright)
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
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
