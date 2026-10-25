import AppKit
import SwiftUI
import GhosttyKit

/// Settings › General › Agent CLI (task 2156): the agent CLIs the plugins
/// declare and the person's own, in one table; the person's own edited in a
/// form under it. What is written is the core's (`launchers.json`, through
/// `ghostty_app_launcher_put` / `_delete`); nothing here looks at a token.
@MainActor
final class AgentCliModel: ObservableObject, AgentCliDraftHolder {
    typealias R = AgentCliRules

    @Published private(set) var page: R.Page?
    /// The row selected, by key.
    @Published var selected: String?
    /// The person's own one being edited: a copy of the saved one, or a new
    /// one (empty key) not yet saved.
    @Published var draft: R.Custom?
    /// What the last action said, for the bottom bar.
    @Published var status: String?

    private var app: ghostty_app_t? { (NSApp.delegate as? AppDelegate)?.ghostty.app }

    func reload() {
        guard let app,
              let json = PersonaCatalog.readJSON({ ghostty_app_launchers(app, $0, $1) }),
              let page = R.decode(json) else { return }
        self.page = page
        if let key = selected, let c = page.file.launchers.first(where: { $0.key == key }) {
            draft = c
        } else if draft?.key.isEmpty == false {
            draft = nil
        }
    }

    func select(_ row: R.Row) {
        selected = row.key
        draft = row.custom ? page?.file.launchers.first { $0.key == row.key } : nil
        status = nil
    }

    func add() {
        guard let page else { return }
        selected = nil
        draft = R.blank(in: page)
        status = nil
    }

    /// The saved one as it was, or no draft for a new one.
    func revert() {
        if let key = selected { draft = page?.file.launchers.first { $0.key == key } } else { draft = nil }
        status = nil
    }

    var dirty: Bool {
        guard let draft else { return false }
        if draft.key.isEmpty { return true }
        return page?.file.launchers.first { $0.key == draft.key } != draft
    }

    func save() {
        guard let app, let page, let draft else { return }
        if let problem = R.problem(draft) {
            status = Self.words(problem)
            return
        }
        let json = R.putJSON(draft, in: page)
        var err = [CChar](repeating: 0, count: 128)
        let ok = json.withCString { body in
            err.withUnsafeMutableBufferPointer { ghostty_app_launcher_put(app, body, UInt(strlen(body)), $0.baseAddress, UInt($0.count)) }
        }
        if ok {
            selected = (try? JSONDecoder().decode(R.Custom.self, from: Data(json.utf8)))?.key ?? selected
            status = String(localized: "Saved.", comment: "Agent CLI 设置页：保存成功后底栏的状态")
            reload()
        } else {
            status = Self.words(error: String(cString: err))
        }
    }

    func delete() {
        guard let app, let key = selected, page?.file.launchers.contains(where: { $0.key == key }) == true else { return }
        var err = [CChar](repeating: 0, count: 128)
        let ok = key.withCString { k in
            err.withUnsafeMutableBufferPointer { ghostty_app_launcher_delete(app, k, UInt(strlen(k)), $0.baseAddress, UInt($0.count)) }
        }
        if ok {
            selected = nil
            draft = nil
            status = nil
            reload()
        } else {
            status = Self.words(error: String(cString: err))
        }
    }

    static func words(_ p: R.Problem) -> String {
        switch p {
        case .noName: String(localized: "Give it a name.", comment: "Agent CLI 设置页：名称为空时底栏的提示")
        case .noBase: String(localized: "Pick the CLI it runs.", comment: "Agent CLI 设置页：没有选底子 CLI 时底栏的提示")
        case .commandNotAbsolute: String(localized: "The command needs a full path (~/ is fine).", comment: "Agent CLI 设置页：启动命令不是绝对路径时底栏的提示")
        case .badEnvName(let n): String(localized: "\"\(n)\" is not a variable name: letters, digits and _.", comment: "Agent CLI 设置页：环境变量名不合法时底栏的提示")
        }
    }

    static func words(error: String) -> String {
        switch error {
        case "UnknownBase": String(localized: "That CLI has no plugin here.", comment: "Agent CLI 设置页：底子 CLI 没有对应插件")
        case "CommandNotAbsolute": words(.commandNotAbsolute)
        case "KeyTaken", "BadKey": String(localized: "That name can't be used. Try another.", comment: "Agent CLI 设置页：由名称生成的 key 不可用")
        case "WriteFailed": String(localized: "Couldn't write the file; nothing was changed.", comment: "Agent CLI 设置页：写文件失败")
        default: String(localized: "Not saved (\(error)).", comment: "Agent CLI 设置页：其它保存失败，括号里是错误名")
        }
    }
}

struct AgentCliPage: View {
    @ObservedObject var model: AgentCliModel
    private typealias L = SettingsLayout
    private typealias R = AgentCliRules

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: L.rowGap) {
                Text(String(localized: "Agent CLI", comment: "Agent CLI 设置页：标题（名字，不翻译）")).fontWeight(.semibold)
                table
                if let draft = model.draft, let page = model.page {
                    form(draft, page: page)
                        .padding(.top, L.groupGap - L.rowGap)
                }
            }
            .padding(L.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(SettingsFont.minimum)
        .onAppear { model.reload() }
    }

    // MARK: The table

    private var table: some View {
        let rows = model.page.map(R.rows) ?? []
        return VStack(spacing: 0) {
            row(name: Text(String(localized: "Name", comment: "Agent CLI 设置页：表头，名称")),
                base: Text(String(localized: "CLI", comment: "Agent CLI 设置页：表头，底子 CLI")),
                source: Text(String(localized: "Source", comment: "Agent CLI 设置页：表头，来源（预设或自定义）")),
                command: Text(String(localized: "Command", comment: "Agent CLI 设置页：表头，启动命令")))
                .foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.key) { r in
                row(name: Text(r.name),
                    base: Text(r.base),
                    source: Text(r.custom
                        ? String(localized: "Your own", comment: "Agent CLI 设置页：来源列，用户自定义的")
                        : String(localized: "Preset (plugin)", comment: "Agent CLI 设置页：来源列，插件声明的预设项"))
                        .foregroundStyle(.secondary),
                    command: Text(r.command ?? String(localized: "Started by its plugin", comment: "Agent CLI 设置页：启动命令列，预设项由插件启动"))
                        .foregroundStyle(.secondary))
                    .overlay(alignment: .leading) { if model.selected == r.key { selection } }
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(r) }
            }
        }
    }

    /// The selected row: an outline and a bar at its left -- never a grey
    /// ground.
    private var selection: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary, lineWidth: 1)
            Rectangle().fill(Color.primary).frame(width: 3)
        }
    }

    private func row(name: some View, base: some View, source: some View, command: some View) -> some View {
        HStack(spacing: L.rowGap * 2) {
            name.frame(width: 200, alignment: .leading)
            base.frame(width: 110, alignment: .leading)
            source.frame(width: 110, alignment: .leading)
            command.frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, L.rowInset + 4)
        .frame(height: L.control)
    }

    // MARK: The form

    private func form(_ draft: R.Custom, page: R.Page) -> some View {
        // Read once more after the draft is gone (task 2164): never `draft!`.
        let binding = { (path: WritableKeyPath<R.Custom, String>) in model.field(path, else: draft[keyPath: path]) }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: L.labelGap, verticalSpacing: L.rowGap) {
            GridRow {
                label(String(localized: "Name", comment: "Agent CLI 设置页：表单，名称"))
                TextField("", text: binding(\.name)).textFieldStyle(.roundedBorder)
            }
            GridRow {
                label(String(localized: "CLI", comment: "Agent CLI 设置页：表单，底子 CLI"))
                Picker("", selection: binding(\.base)) {
                    ForEach(page.presets, id: \.key) { Text($0.name).tag($0.key) }
                }
                .labelsHidden().frame(width: 200, alignment: .leading)
            }
            GridRow {
                label(String(localized: "Command", comment: "Agent CLI 设置页：表单，启动命令"))
                HStack(spacing: L.rowGap) {
                    TextField("", text: binding(\.command)).textFieldStyle(.roundedBorder).font(SettingsFont.minimumMonospaced)
                    Button(String(localized: "Choose…", comment: "Agent CLI 设置页：选择启动命令文件的按钮")) { chooseCommand() }
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                note(String(localized: "A full path; ~/ is fine. Keep a token in your command rather than here.", comment: "Agent CLI 设置页：启动命令下的静态说明（唯一的令牌提示，不拦截）"))
            }
            GridRow {
                label(String(localized: "Variables", comment: "Agent CLI 设置页：表单，环境变量"))
                envs(draft)
            }
            GridRow {
                label(String(localized: "Arguments", comment: "Agent CLI 设置页：表单，参数"))
                TextField("", text: Binding(
                    get: { R.argsLine(model.field(\.args, else: draft.args).wrappedValue) },
                    set: { model.field(\.args, else: draft.args).wrappedValue = R.args(fromLine: $0) }))
                    .textFieldStyle(.roundedBorder).font(SettingsFont.minimumMonospaced)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).frame(width: L.label, alignment: .trailing)
    }

    private func note(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func envs(_ draft: R.Custom) -> some View {
        VStack(alignment: .leading, spacing: L.rowGap) {
            ForEach(draft.env.indices, id: \.self) { i in
                HStack(spacing: L.rowGap) {
                    TextField(String(localized: "Variable name", comment: "Agent CLI 设置页：环境变量名输入框的占位"), text: model.variable(i, \.name, else: draft.env[i].name))
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                    TextField("", text: model.variable(i, \.value, else: draft.env[i].value))
                        .textFieldStyle(.roundedBorder)
                    Button { model.removeVariable(i) } label: { Image(systemName: "minus") }
                }
                .font(SettingsFont.minimumMonospaced)
            }
            Button { model.draft?.env.append(.init(name: "", value: "")) } label: { Image(systemName: "plus") }
        }
    }

    private func chooseCommand() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = url.path
            model.draft?.command = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
    }
}

/// The Agent CLI page's bottom bar: add and delete under the list's edge,
/// what the last action said, and Revert / Save at the right (§2.3a).
struct AgentCliBar: View {
    @ObservedObject var model: AgentCliModel
    private typealias L = SettingsLayout

    var body: some View {
        HStack(spacing: L.rowGap) {
            Button { model.add() } label: { Image(systemName: "plus") }
                .help(String(localized: "Add an Agent CLI of your own", comment: "Agent CLI 设置页：底栏加号的提示"))
            Button { model.delete() } label: { Image(systemName: "minus") }
                .disabled(model.draft == nil || model.draft?.key.isEmpty == true)
                .help(String(localized: "Delete it", comment: "Agent CLI 设置页：底栏减号的提示"))
            if let status = model.status {
                Text(status).font(SettingsFont.minimum).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(String(localized: "Revert", comment: "Agent CLI 设置页：还原按钮")) { model.revert() }
                .disabled(!model.dirty)
            Button(String(localized: "Save", comment: "Agent CLI 设置页：保存按钮")) { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty)
        }
        .controlSize(.large)
        .padding(.leading, L.ContentEdge.bottomBar)
        .padding(.trailing, L.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
