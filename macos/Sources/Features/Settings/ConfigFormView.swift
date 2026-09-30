import AppKit
import SwiftUI

/// One group of the General section drawn from the core's form table
/// (settings.md §7.1-7.4): a row per key, each on the form grid -- key in
/// the label column, control in the control column, help and any error
/// under the control. Every change writes at once (§7.3), so there is no
/// Revert / Save.
struct ConfigFormPage: View {
    @ObservedObject var model: GeneralModel
    var group: GeneralGroup

    private typealias L = SettingsLayout

    var body: some View {
        VStack(spacing: 0) {
            if group == .all {
                TextField(String(localized: "Filter by setting name", comment: "设置窗口·通用：全部选项里按键名过滤的输入框"), text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, L.pad)
                    .padding(.vertical, L.rowGap)
                Divider()
            }
            if let form = model.form, !model.writesAllowed {
                Label(String(format: String(localized: "This Polter reads %@, but the form would write %@. The settings are shown read-only.", comment: "设置窗口·通用：进程读的配置文件与表单要写的不是同一个，参数依次是两个路径"), ((model.ghostty?.configPath ?? "") as NSString).abbreviatingWithTildeInPath, (form.main as NSString).abbreviatingWithTildeInPath), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, L.pad)
                    .padding(.vertical, L.rowGap + 4)
                    .background(Color.orange.opacity(0.08))
            }
            if let form = model.form {
                let items = ConfigFormRules.items(in: group, of: form, query: model.query)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: L.groupGap - L.rowGap) {
                        ForEach(items) { item in
                            ConfigFormRow(model: model, item: item, control: ConfigFormRules.control(for: item, in: group))
                                .disabled(!model.writesAllowed)
                        }
                        if items.isEmpty {
                            Text(String(localized: "No matching settings", comment: "设置窗口·通用：全部选项过滤后一个都不剩"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(L.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack {
                    Spacer()
                    Text(model.formUnavailable
                         ? String(localized: "Polter's core did not hand over the settings table.", comment: "设置窗口·通用：拿不到核心的配置表")
                         : String(localized: "Reading the settings…", comment: "设置窗口·通用：正在读配置表"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { if model.form == nil { model.reloadForm() } }
    }
}

/// One key: label, control, help, error, and where the value comes from
/// when the form cannot write it.
private struct ConfigFormRow: View {
    @ObservedObject var model: GeneralModel
    let item: ConfigForm.Item
    let control: ConfigForm.Control

    private typealias L = SettingsLayout

    /// Ghostty's own help text, folded away until asked for.
    @State private var showingMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: L.rowGap / 2) {
            HStack(alignment: .firstTextBaseline, spacing: L.labelGap) {
                label
                    .frame(width: L.label, alignment: .trailing)
                ConfigFormControl(model: model, item: item, control: control)
                    // Made again from the value on disk whenever that
                    // changes -- after a write, a refused write, a restore
                    // or a hand edit -- so what the control shows is never
                    // an old draft beside a new value.
                    .id("\(item.value)\u{0}\(model.attempts[item.key] ?? 0)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            formControl {
                VStack(alignment: .leading, spacing: 2) {
                    if let error = model.fieldErrors[item.key] {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if !ConfigFormRules.isWritable(item) {
                        readonlyNote
                    }
                    help
                    if showingMore, let doc = item.doc {
                        Text(doc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .contextMenu {
            if ConfigFormRules.canRestoreDefault(item) {
                Button(String(localized: "Restore Default", comment: "设置窗口·通用：把这一项恢复成默认值（删掉配置文件里那一行）")) {
                    model.set(item.key, nil)
                }
            }
        }
    }

    /// Under the control: the key as the config file spells it (quiet,
    /// monospaced -- it is what a person searches the file for), then the
    /// form's sentence, then "More…" for Ghostty's own text (#973). A key
    /// with no name of its own shows only the sentence: its key is already
    /// the label.
    private var help: some View {
        let line = helpLine(ConfigFormRules.sentence(item))
        // "More…" is the last run of the same text, not a button beside
        // it: beside it, a long key squeezed the sentence into a column at
        // the window's narrowest. As a link it wraps with the words.
        let more: Text? = ConfigFormRules.hasMore(item) ? Text(Self.moreLink(showingMore)).font(.caption) : nil
        return (more.map { line + Text(verbatim: "  ") + $0 } ?? line)
            .lineLimit(showingMore ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url == Self.moreURL else { return .systemAction }
                showingMore.toggle()
                return .handled
            })
    }

    private static let moreURL = URL(string: "polter-settings:more")!

    private static func moreLink(_ showing: Bool) -> AttributedString {
        var text = AttributedString(showing
            ? String(localized: "Less", comment: "设置窗口·通用：收起 Ghostty 原文说明")
            : String(localized: "More…", comment: "设置窗口·通用：展开 Ghostty 原文说明"))
        text.link = moreURL
        return text
    }

    private func helpLine(_ sentence: String?) -> Text {
        let key = Text(item.key).font(.caption.monospaced()).foregroundColor(Color(nsColor: .tertiaryLabelColor))
        let words = sentence.map { Text($0).font(.caption).foregroundColor(.secondary) }
        switch (item.label != nil, words) {
        case (true, let words?): return key + Text(verbatim: "  ") + words
        case (true, nil): return key
        case (false, let words?): return words
        case (false, nil): return Text(verbatim: "")
        }
    }

    /// The form's name for the key (the key itself in All Options), with the
    /// dot of §7.3 when the value is not the default.
    private var label: some View {
        HStack(spacing: 4) {
            if ConfigFormRules.differsFromDefault(item) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .help(String(format: String(localized: "Changed from the default (%@). Right-click to restore it.", comment: "设置窗口·通用：与默认值不同的圆点的说明，%@ 是默认值"), item.default.isEmpty ? "—" : item.default))
            }
            Text(ConfigFormRules.title(item))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(item.key)
        }
    }

    @ViewBuilder
    private var readonlyNote: some View {
        switch item.source.kind {
        case .file:
            HStack(spacing: L.rowGap) {
                Text(String(format: String(localized: "Set in %@, line %@.", comment: "设置窗口·通用：这一项由别的配置文件设置，参数依次是文件、行号"), ((item.source.path ?? "") as NSString).abbreviatingWithTildeInPath, String(item.source.line ?? 0)))
                Button(String(localized: "Open That File", comment: "设置窗口·通用：打开设置了这一项的那个配置文件")) {
                    if let path = item.source.path { model.openFile(path) }
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        case .cli:
            Text(String(localized: "Set on the command line; a change here would not take effect.", comment: "设置窗口·通用：这一项由命令行设置"))
                .font(.callout)
        case .main, .default:
            HStack(spacing: L.rowGap) {
                Text(String(localized: "Edited in the config file, not here.", comment: "设置窗口·通用：可重复的键等表单不写，只能在配置文件里改"))
                Button(String(localized: "Edit in Config File…", comment: "设置窗口·通用：快捷键组，在配置文件里改快捷键")) {
                    model.openConfigFile()
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
    }
}

/// The control for one key. Toggles, choices and sliders write the moment
/// they change; text writes on Return or when it loses focus (§7.3).
private struct ConfigFormControl: View {
    @ObservedObject var model: GeneralModel
    let item: ConfigForm.Item
    let control: ConfigForm.Control

    @State private var draft = ""
    @State private var light = ""
    @State private var dark = ""
    @State private var slider = 0.0
    @FocusState private var focused: Bool

    var body: some View {
        content
            .onAppear(perform: load)
    }

    @ViewBuilder
    private var content: some View {
        switch control {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { ConfigFormRules.isOn(item) },
                set: { model.set(item.key, ConfigFormRules.toggleValue($0)) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
        case .choice:
            Picker("", selection: Binding(
                get: { item.value },
                set: { if $0 != item.value { model.set(item.key, $0) } })) {
                ForEach(item.choices ?? [], id: \.self) { Text($0).tag($0) }
                if !(item.choices ?? []).contains(item.value) {
                    Text(item.value).tag(item.value)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .number where ConfigFormRules.usesSlider(item):
            HStack(spacing: SettingsLayout.rowGap) {
                Slider(value: $slider, in: (item.min ?? 0)...(item.max ?? 1)) { editing in
                    if !editing { commit(ConfigFormRules.sliderText(slider)) }
                }
                .frame(maxWidth: 240)
                Text(ConfigFormRules.sliderText(slider))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .theme:
            HStack(spacing: SettingsLayout.rowGap) {
                TextField(String(localized: "Light", comment: "设置窗口·通用：主题，浅色时用的主题"), text: $light)
                    .onSubmit(commitTheme)
                TextField(String(localized: "Dark", comment: "设置窗口·通用：主题，深色时用的主题"), text: $dark)
                    .onSubmit(commitTheme)
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onChange(of: focused) { if !$0 { commitTheme() } }
        case .color:
            HStack(spacing: SettingsLayout.rowGap) {
                textField
                if let color = Self.color(item.value) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(nsColor: .separatorColor)))
                }
            }
        case .number, .text, .font:
            textField
        case .readonly:
            Text(item.value.isEmpty ? "—" : item.value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }

    private var textField: some View {
        TextField(item.default, text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: control == .number ? 160 : .infinity)
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { if !$0 { commit(draft) } }
    }

    private func load() {
        draft = item.value
        (light, dark) = ConfigFormRules.themePair(item.value)
        slider = Double(item.value) ?? item.min ?? 0
    }

    private func commit(_ value: String) {
        guard ConfigFormRules.shouldWrite(value, over: item) else { return }
        model.set(item.key, value)
    }

    private func commitTheme() {
        commit(ConfigFormRules.themeValue(light: light, dark: dark))
    }

    /// `#rrggbb` or `rrggbb` as a swatch; anything else (a name) draws none.
    static func color(_ value: String) -> Color? {
        var hex = value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((n >> 16) & 0xff) / 255, green: Double((n >> 8) & 0xff) / 255, blue: Double(n & 0xff) / 255)
    }
}
