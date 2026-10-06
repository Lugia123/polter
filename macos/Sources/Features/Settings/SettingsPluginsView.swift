import AppKit
import SwiftUI

/// The Plugins section's state: which plugin is shown, its settings as
/// saved and as being edited, and what the core says about each (settings.md
/// §5). Saving goes through the core's writer (`PluginCore.configure`).
@MainActor
final class PluginsPane: ObservableObject, SettingsPane {
    @Published private(set) var plugins: [Plugin] = []
    /// What the core says, by key. Nil when it did not answer.
    @Published private(set) var statuses: [String: PluginCoreStatus]?
    @Published private(set) var selection: String?
    /// The shown plugin's settings as saved, with the schema's defaults put
    /// in for anything unset -- so what is on screen and what would be
    /// saved are the same thing.
    @Published private(set) var saved = PluginSettings()
    @Published var draft = PluginSettings()
    /// Why the last save failed; nil when it did not.
    @Published private(set) var status: String?
    /// The last test's answer, beside the Test button.
    @Published private(set) var testResult: (ok: Bool, text: String)?
    @Published private(set) var logLines: [String] = []
    @Published var tab: Tab = .settings

    enum Tab: Hashable { case settings, page }

    var plugin: Plugin? {
        plugins.first { $0.key == selection }
    }

    var isDirty: Bool { selection != nil && draft != saved }

    /// Read everything again: what is installed, what the core says, and the
    /// shown plugin's file. A draft being edited is kept.
    func reload() {
        plugins = PluginCatalog.installed()
        statuses = PluginCore.statuses()
        if let selection, !plugins.contains(where: { $0.key == selection }) {
            load(nil)
        } else if !isDirty {
            load(selection, keepMessages: true)
        }
    }

    /// Show `key`, asking first when the plugin being left has unsaved
    /// changes (settings.md §2.4). False when the person cancelled.
    @discardableResult
    func select(_ key: String?) -> Bool {
        guard key != selection else { return true }
        guard SettingsUnsaved.confirmLeaving(self) else { return false }
        load(key)
        return true
    }

    /// Show `key`'s saved settings. `keepMessages` is for reading the same
    /// plugin again: its last test result and save error stay beside the
    /// buttons they belong to.
    private func load(_ key: String?, keepMessages: Bool = false) {
        selection = key
        if !keepMessages {
            status = nil
            testResult = nil
        }
        guard let plugin else {
            saved = PluginSettings()
            draft = saved
            logLines = []
            return
        }
        var settings = PluginSettings.load(for: plugin)
        for parameter in plugin.parameters {
            guard settings.params[parameter.name] == nil,
                  let value = parameter.defaultValue
            else { continue }
            settings.params[parameter.name] = value
        }
        saved = settings
        draft = settings
        if tab == .page && plugin.pageURL == nil { tab = .settings }
        reloadLog()
    }

    func reloadLog() {
        guard let key = selection, let url = PluginCatalog.logURL(for: key) else {
            logLines = []
            return
        }
        logLines = SettingsRules.logTail(Self.readTail(of: url))
    }

    /// The end of a file, without reading all of a log that has grown for
    /// months. A first line cut in half is dropped.
    private static func readTail(of url: URL, bytes: UInt64 = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > bytes ? end - bytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        // Repairing, not failable: the cut above can land inside a UTF-8
        // sequence, and a failable read would lose the whole tail for it.
        // swiftlint:disable:next optional_data_string_conversion
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let cut = text.firstIndex(where: \.isNewline) {
            text = String(text[text.index(after: cut)...])
        }
        return text
    }

    // MARK: What the sidebar and the header show

    /// The dot for a plugin, from its file as saved and the core's answer.
    func dot(for plugin: Plugin) -> PluginDot {
        let settings = PluginSettings.load(for: plugin)
        return SettingsRules.pluginDot(
            restartPending: PluginLaunch.shared.restartPending(plugin, now: settings),
            enabled: settings.enabled,
            missing: settings.missing(for: plugin),
            status: statuses?[plugin.key])
    }

    /// The shown plugin still runs with the settings it started with.
    var restartPending: Bool {
        guard let plugin else { return false }
        return PluginLaunch.shared.restartPending(plugin, now: PluginSettings.load(for: plugin))
    }

    func listing(query: String) -> SettingsRules.Listing {
        SettingsRules.listing(
            items: plugins.map { (key: $0.key, name: $0.name) },
            query: query,
            selection: selection)
    }

    // MARK: SettingsPane

    func save() -> Bool {
        guard let plugin else { return true }
        let missing = draft.missing(for: plugin)
        if draft.enabled && !missing.isEmpty {
            status = Self.missingSentence(missing)
            return false
        }

        // Every declared parameter, an empty one unsetting it: the form is
        // the whole of what the person sees, so what they emptied is what
        // they meant. The core refuses a name the manifest does not
        // declare, and one written by hand is kept by its merge untouched.
        var params: [String: String] = [:]
        for parameter in plugin.parameters {
            params[parameter.name] = draft.params[parameter.name] ?? ""
        }

        switch PluginCore.configure(plugin.key, enabled: draft.enabled, params: params) {
        case .failure(let failure):
            status = failure.message
            return false
        case .success:
            statuses = PluginCore.statuses()
            load(plugin.key)
            return true
        }
    }

    func revert() {
        draft = saved
        status = nil
    }

    /// Called when a plugin's own page saved: the file changed under the
    /// form, so the form reads it again unless it holds edits.
    func pageSaved() {
        statuses = PluginCore.statuses()
        if !isDirty { load(selection, keepMessages: true) }
        objectWillChange.send()
    }

    func test() {
        guard let key = selection else { return }
        switch PluginCore.test(key) {
        case .success(let text): testResult = (true, text)
        case .failure(let failure): testResult = (false, failure.message)
        }
        statuses = PluginCore.statuses()
        reloadLog()
    }

    static func missingSentence(_ missing: [String]) -> String {
        String(
            format: String(localized: "Fill in first: %@", comment: "设置窗口：插件，缺的必填项，%@ 是用顿号/逗号连起来的项名"),
            missing.joined(separator: String(localized: ", ", comment: "设置窗口：列举项之间的分隔符")))
    }
}

/// The Plugins section, in the parts the settings window places on its grid
/// (settings.md §2.3a): the detail in the body, the one bar in the bottom
/// band. The list is the sidebar's (`PluginSidebarRows`).
struct PluginsView: View {
    enum Part { case detail, bar }

    @ObservedObject var pane: PluginsPane
    var part: Part

    private typealias Grid = SettingsLayout

    var body: some View {
        switch part {
        case .detail: detail
        case .bar: bar
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let plugin = pane.plugin {
            ScrollView {
                VStack(alignment: .leading, spacing: Grid.groupGap) {
                    if pane.restartPending { restartBanner }
                    header(plugin)
                    switchRow(plugin)
                    tabs(plugin)
                    log(plugin)
                }
                .padding(Grid.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: Grid.rowGap) {
                Text(pane.plugins.isEmpty
                     ? String(localized: "No plugins installed", comment: "插件菜单：一个插件都没有")
                     : String(localized: "Choose a plugin in the sidebar.", comment: "设置窗口：插件栏目，还没选插件"))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Open Plugins Folder", comment: "插件菜单：打开插件目录")) {
                    if let dir = PluginCatalog.userDirectory {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
                Spacer()
            }
            .padding(Grid.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Always there while the plugin waits for a restart, rather than a
    /// box that is dismissed and forgotten (settings.md §5.2).
    private var restartBanner: some View {
        HStack(spacing: Grid.rowGap) {
            Text(PluginDot.restartPending.symbol)
            Text(String(localized: "Takes effect after Polter restarts. Its running copy still has the settings it started with.", comment: "设置窗口：插件，保存时它在跑，重启后生效的横幅"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(SettingsFont.minimum)
        .padding(Grid.rowGap + Grid.rowGap / 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
    }

    private func header(_ plugin: Plugin) -> some View {
        VStack(alignment: .leading, spacing: Grid.rowGap / 2) {
            HStack(alignment: .firstTextBaseline, spacing: Grid.rowGap) {
                Text(plugin.name).font(.title2)
                let byline = [
                    plugin.version.isEmpty ? nil : "v\(plugin.version)",
                    plugin.author.isEmpty ? nil : plugin.author,
                ].compactMap { $0 }.joined(separator: " · ")
                if !byline.isEmpty {
                    Text(byline).foregroundStyle(.secondary)
                }
            }
            // The plugin's own sentence about itself, in the reader's
            // language when it ships one.
            if !plugin.summary.isEmpty {
                Text(plugin.summary)
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The switch, greyed out while required settings are missing, with
    /// which ones beside it (settings.md §5.2). Switching off is always
    /// allowed.
    private func switchRow(_ plugin: Plugin) -> some View {
        let missing = pane.draft.missing(for: plugin)
        let blocked = !pane.draft.enabled && !missing.isEmpty
        return formRow(String(localized: "Status", comment: "设置窗口：插件，开关那一行的标签")) {
            HStack(spacing: Grid.rowGap) {
                Toggle(String(localized: "Let this plugin run", comment: "插件设置"), isOn: $pane.draft.enabled)
                    .disabled(blocked)
                let dot = pane.dot(for: plugin)
                HStack(spacing: Grid.rowGap / 2) {
                    Text(verbatim: dot.symbol).foregroundStyle(dot.color)
                    Text(dot.title).foregroundStyle(.secondary)
                }
                if !missing.isEmpty {
                    Text(PluginsPane.missingSentence(missing))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func tabs(_ plugin: Plugin) -> some View {
        VStack(alignment: .leading, spacing: Grid.rowGap) {
            Picker("", selection: $pane.tab) {
                Text(String(localized: "Settings", comment: "设置窗口：插件，页签「设置」")).tag(PluginsPane.Tab.settings)
                if plugin.pageURL != nil {
                    Text(String(localized: "Page", comment: "设置窗口：插件，页签「页面」（插件自带网页）")).tag(PluginsPane.Tab.page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch pane.tab {
            case .settings:
                PluginSettingsForm(plugin: plugin, settings: $pane.draft)
            case .page:
                // The plugin's own page, in the tab rather than a window of
                // its own (settings.md §5.3). A new page per plugin: the
                // bridge is one plugin's, and its origin is too.
                PluginPage(
                    plugin: plugin,
                    onSave: { pane.pageSaved() },
                    onClose: { pane.tab = .settings })
                    .id(plugin.key)
                    .frame(height: 520)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
        }
    }

    private func log(_ plugin: Plugin) -> some View {
        VStack(alignment: .leading, spacing: Grid.rowGap) {
            HStack(spacing: Grid.rowGap) {
                Text(String(localized: "Log", comment: "设置窗口：插件，日志分组标题")).font(.headline)
                Spacer()
                Button(String(localized: "Refresh", comment: "设置窗口：插件，刷新日志")) { pane.reloadLog() }
                Button(String(localized: "Show Log", comment: "插件菜单：打开这个插件的日志")) {
                    if let url = PluginCatalog.logURL(for: plugin.key) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(PluginCatalog.logURL(for: plugin.key) == nil)
                Button(String(localized: "Show Plugin Folder", comment: "设置窗口：插件，在 Finder 里显示这个插件的目录")) {
                    NSWorkspace.shared.activateFileViewerSelecting([plugin.directory])
                }
            }
            if pane.logLines.isEmpty {
                Text(String(localized: "Nothing written yet.", comment: "设置窗口：插件，还没有日志"))
                    .foregroundStyle(.secondary)
            } else {
                Text(pane.logLines.joined(separator: "\n"))
                    .font(SettingsFont.minimumMonospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Grid.rowGap)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
        }
    }

    // MARK: Bottom band

    private var bar: some View {
        HStack(spacing: Grid.rowGap) {
            if let status = pane.status {
                Label(status, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(SettingsFont.minimum)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if pane.isDirty {
                Text(String(localized: "Unsaved changes", comment: "角色库：有未保存的修改"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let result = pane.testResult {
                // Beside the button that produced it (settings.md §5.2).
                Text(result.text)
                    .font(SettingsFont.minimum)
                    .foregroundStyle(result.ok ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(result.text)
                    .textSelection(.enabled)
            }
            if pane.plugin != nil {
                Button(String(localized: "Test", comment: "设置窗口：插件，测试按钮（与 plugin_test 同一逻辑）")) { pane.test() }
                Button(String(localized: "Revert", comment: "角色库：放弃修改回到已保存的版本")) { pane.revert() }
                    .disabled(!pane.isDirty)
                Button(String(localized: "Save", comment: "角色库：保存按钮")) { _ = pane.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!pane.isDirty)
            }
        }
        .controlSize(.large)
        .padding(.leading, Grid.ContentEdge.bottomBar)
        .padding(.trailing, Grid.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The plugins under Plugins in the sidebar, each with its dot and what the
/// dot means in words (settings.md §2.3, §5.1). The search filters them by
/// name or key, as it does the roles list.
struct PluginSidebarRows: View {
    @ObservedObject var pane: PluginsPane
    var query: String
    var selected: (String) -> Bool
    var onSelect: (String) -> Void

    private typealias Grid = SettingsLayout

    var body: some View {
        let listing = pane.listing(query: query)
        if listing.noMatch && !pane.plugins.isEmpty {
            Text(String(localized: "No matching plugins", comment: "设置窗口：搜索没有匹配的插件"))
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .padding(.leading, Grid.pad + Grid.pad)
                .frame(maxWidth: .infinity, minHeight: Grid.control, alignment: .leading)
        }
        ForEach(listing.visible, id: \.self) { key in
            if let plugin = pane.plugins.first(where: { $0.key == key }) {
                let dot = pane.dot(for: plugin)
                SettingsRow(selected: selected(key), inset: Grid.padSidebar) {
                    HStack(spacing: Grid.rowGap) {
                        Text(verbatim: dot.symbol)
                            .foregroundStyle(dot.color)
                            .frame(width: Grid.pad)
                        Text(plugin.name).lineLimit(1)
                        Spacer(minLength: Grid.rowGap / 2)
                        Text(dot.title)
                            .font(SettingsFont.minimum)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, Grid.pad)
                }
                .help(pane.statuses?[key]?.note ?? "")
                .onTapGesture { onSelect(key) }
            }
        }
    }
}

extension PluginDot {
    var color: Color {
        switch self {
        case .restartPending: .orange
        case .off: .secondary
        case .missingConfig: .yellow
        case .failing: .red
        case .on: .green
        }
    }
}
