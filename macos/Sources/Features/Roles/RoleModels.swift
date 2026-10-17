// The role library's values: what the core sends, what the
// window edits, and the small rules between them. No AppKit and no
// GhosttyKit on purpose, so that these can be compiled and checked on
// their own.
import Foundation

/// Which of a CLI's own skills or MCP servers a role keeps: a default, and
/// the ids ticked the other way.
///
/// The same shape as `persona.Selection` in the core, for the reason given
/// there: a plain list of what is on cannot tell "unticked" from "installed
/// after the role was written".
struct RoleSelection: Equatable {
    var keepByDefault: Bool = true
    var except: [String] = []

    func isOn(_ id: String) -> Bool {
        except.contains(id) ? !keepByDefault : keepByDefault
    }

    /// Put `id` in the state asked for, by adding or removing it from
    /// `except` -- whichever is the difference from the default.
    mutating func set(_ id: String, on: Bool) {
        let wantsException = on != keepByDefault
        let isException = except.contains(id)
        if wantsException && !isException { except.append(id) }
        if !wantsException && isException { except.removeAll { $0 == id } }
    }

    /// Change the default while leaving every listed item as it is, so that
    /// flipping "items installed later" never flips what the user can see.
    mutating func setDefault(_ keep: Bool, keeping visible: [String]) {
        guard keep != keepByDefault else { return }
        let states = Dictionary(uniqueKeysWithValues: visible.map { ($0, isOn($0)) })
        keepByDefault = keep
        except = except.filter { !states.keys.contains($0) }
        for (id, on) in states where on != keep { except.append(id) }
    }

    init(keepByDefault: Bool = true, except: [String] = []) {
        self.keepByDefault = keepByDefault
        self.except = except
    }

    init(json: Any?) {
        guard let obj = json as? [String: Any] else { return }
        keepByDefault = (obj["default"] as? Bool) ?? true
        except = (obj["except"] as? [String]) ?? []
    }

    var json: [String: Any] { ["default": keepByDefault, "except": except] }
}

/// A role's choices for one agent CLI: what only that CLI has a word for.
/// Which of its skills and MCP servers are on is the role's, one set for
/// every CLI (`Role.skills`, task 1677).
struct RoleCliChoice: Equatable, Identifiable {
    var cli: String
    var model: String = ""
    var args: [String] = []
    /// The adapter's launch options as the role picked them (`persona.Option`
    /// in the core): option key to value. Carried through as read.
    var options: [String: String] = [:]

    var id: String { cli }

    init(cli: String) { self.cli = cli }

    init(cli: String, json: Any?) {
        self.cli = cli
        let obj = json as? [String: Any] ?? [:]
        model = (obj["model"] as? String) ?? ""
        args = (obj["args"] as? [String]) ?? []
        options = (obj["options"] as? [String: String]) ?? [:]
    }

    var json: [String: Any] {
        var out: [String: Any] = [:]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out["model"] = trimmed }
        if !args.isEmpty { out["args"] = args }
        if !options.isEmpty { out["options"] = options }
        return out
    }
}

/// What Polter does with the terminal a role is started in -- the core's
/// `persona.Polter`. Applied once, when the role starts an agent CLI.
///
/// `supervisor`, `mayAuthorise` and `shielded` grant the terminal
/// something, so only the user sets them: the core refuses a supervisor's
/// `role_put` that changes them, and this window is the user's.
struct RolePolter: Equatable {
    enum Open: String, CaseIterable { case auto, tab }

    var supervisor = false
    var mayAuthorise = false
    var shielded = false
    var watch = false
    var open: Open = .auto
    /// Nil keeps the configured default.
    var quietMs: Int?

    var isDefault: Bool { self == RolePolter() }

    init() {}

    init(json: Any?) {
        guard let obj = json as? [String: Any] else { return }
        supervisor = (obj["supervisor"] as? Bool) ?? false
        mayAuthorise = (obj["may_authorise"] as? Bool) ?? false
        shielded = (obj["shielded"] as? Bool) ?? false
        watch = (obj["watch"] as? Bool) ?? false
        open = (obj["open"] as? String).flatMap(Open.init(rawValue:)) ?? .auto
        quietMs = obj["quiet_ms"] as? Int
    }

    var json: [String: Any] {
        var out: [String: Any] = [
            "supervisor": supervisor,
            "may_authorise": mayAuthorise,
            "shielded": shielded,
            "watch": watch,
            "open": open.rawValue,
        ]
        if let quietMs { out["quiet_ms"] = quietMs }
        return out
    }
}

/// One role from the library, in the shape the window edits.
///
/// **Fields the window does not edit are carried through untouched.** A
/// hand-written role may have `tools`, `hint`, `prompt` and the Polter-side
/// `skills`/`mcp` -- the hot half that still works on a running terminal.
/// Dropping them on save would turn "I changed the description" into "I
/// quietly took this role's tool rules away", which nobody would notice
/// until a worker had the wrong tools.
struct Role: Equatable, Identifiable {
    var key: String
    var name: String
    var summary: String = ""
    var instructions: String = ""
    var clis: [RoleCliChoice] = []
    /// Which of the CLIs' own skills and MCP servers the role keeps: one set
    /// for every CLI it is started in (`cli_skills` / `cli_mcp`, task 1677).
    /// The core reads an older file's per-CLI sets into this.
    var skills = RoleSelection()
    var mcp = RoleSelection()
    var polter = RolePolter()

    /// An official role: shipped with Polter. Some of it can be changed
    /// here and put back (`official`); its name, its description and what
    /// it grants cannot, and it cannot be deleted.
    var builtin = false

    /// Where an official role stands against the shipped one; nil for a
    /// role somebody wrote. The core's word, never worked out here.
    var official: RoleOfficial?

    /// Everything else in the object, as JSON, so it compares and saves.
    var passthrough: Data = Data("{}".utf8)

    var id: String { key }

    static let editedKeys: Set<String> = ["key", "name", "description", "instructions", "clis", "cli_skills", "cli_mcp", "polter", "builtin", "official"]

    /// The key of the supervisor role Polter ships (`persona.supervisor_key`).
    static let supervisorKey = "polter-supervisor"

    /// The name to show: the name. An official role's used to be shown in
    /// the reader's language by its key; official roles are English as
    /// shipped, so the name beside the "Official" mark is the shipped one.
    var displayName: String { name }

    var displaySummary: String { summary }

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    init?(json obj: [String: Any]) {
        guard let key = obj["key"] as? String, let name = obj["name"] as? String else { return nil }
        self.key = key
        self.name = name
        summary = (obj["description"] as? String) ?? ""
        instructions = (obj["instructions"] as? String) ?? ""
        if let clis = obj["clis"] as? [String: Any] {
            self.clis = clis.keys.sorted().map { RoleCliChoice(cli: $0, json: clis[$0]) }
        }
        skills = RoleSelection(json: obj["cli_skills"])
        mcp = RoleSelection(json: obj["cli_mcp"])
        polter = RolePolter(json: obj["polter"])
        builtin = (obj["builtin"] as? Bool) ?? false
        official = RoleOfficial(json: obj["official"])
        let rest = obj.filter { !Self.editedKeys.contains($0.key) }
        passthrough = (try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    func choice(for cli: String) -> RoleCliChoice? {
        clis.first { $0.cli == cli }
    }

    /// The object `ghostty_app_persona_put` takes.
    var jsonObject: [String: Any] {
        var out = (try? JSONSerialization.jsonObject(with: passthrough)) as? [String: Any] ?? [:]
        out["key"] = key
        out["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { out["description"] = summary }
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["instructions"] = instructions
        }
        if !clis.isEmpty {
            out["clis"] = Dictionary(uniqueKeysWithValues: clis.map { ($0.cli, $0.json) })
        }
        out["cli_skills"] = skills.json
        out["cli_mcp"] = mcp.json
        if !polter.isDefault { out["polter"] = polter.json }
        return out
    }

    var jsonData: Data? {
        try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }

    /// A key for a new role, made from its name when the name has any
    /// letters or digits to make one from, and numbered otherwise --
    /// a Chinese name has none, and a key has to be `[a-z0-9-]`.
    static func suggestedKey(for name: String, avoiding taken: Set<String>) -> String {
        let ascii = name.lowercased().unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) { return c }
            return "-"
        }
        var base = String(ascii)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if base.count > 24 { base = String(base.prefix(24)) }
        if base.isEmpty { base = "role" }
        if !taken.contains(base) && base != "role" { return base }
        for n in 1... {
            let candidate = "\(base)-\(n)"
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    static func isValidKey(_ key: String) -> Bool {
        guard (1...32).contains(key.count) else { return false }
        return key.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

/// Where an official role, or an official skill, stands against the one
/// Polter ships (`persona.Official` in the core).
struct RoleOfficial: Equatable {
    enum State: String {
        case pristine, modified, unknown
        /// Changed here, and the shipped one has changed in the same place
        /// since.
        case modifiedStale = "modified_stale"
    }

    var state: State
    var overridden: [String] = []
    var stale: [String] = []
    var reason: String?

    init(state: State, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }

    init?(json: Any?) {
        guard let obj = json as? [String: Any],
              let raw = obj["state"] as? String, let state = State(rawValue: raw) else { return nil }
        self.state = state
        overridden = (obj["overridden"] as? [String]) ?? []
        stale = (obj["stale"] as? [String]) ?? []
        reason = OfficialWhy.display(
            code: obj["reason_code"] as? String,
            detail: obj["reason_detail"] as? String,
            english: obj["reason"] as? String)
    }

    /// Whether there is anything to put back.
    var canRestore: Bool { state != .pristine }

    /// A field path from the core (`official.targetOf`), in words.
    static func fieldName(_ path: String) -> String {
        switch path {
        case "instructions": return String(localized: "Instructions", comment: "角色库：分区名，启动时附加给 agent 的指令")
        case "polter.watch", "polter.open", "polter.quiet_ms": return String(localized: "Polter", comment: "角色库：分区名，这个角色启动的终端在 Polter 里是什么身份")
        default: return String(localized: "Agent CLIs", comment: "角色库：分区名，这个角色可以启动哪些 CLI")
        }
    }
}

/// One skill Polter ships, with the text in use and where it stands.
struct OfficialSkill: Equatable, Identifiable {
    var name: String
    var summary: String
    var official: RoleOfficial
    /// The whole file in use: the person's copy when there is one.
    var source: String
    var shipped: String
    var id: String { name }

    init?(json obj: [String: Any]) {
        guard let name = obj["name"] as? String, let source = obj["source"] as? String,
              let official = RoleOfficial(json: obj) else { return nil }
        self.name = name
        self.source = source
        self.official = official
        summary = (obj["description"] as? String) ?? ""
        shipped = (obj["shipped"] as? String) ?? source
    }
}

struct OfficialSkillCatalog: Equatable {
    /// Why the list could not be made; then `skills` is empty because it
    /// is not known, not because there are none.
    var error: String?
    var skills: [OfficialSkill] = []

    init() {}

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        error = obj["error"] as? String
        skills = ((obj["skills"] as? [[String: Any]]) ?? []).compactMap(OfficialSkill.init(json:))
    }
}

/// What the core said about the library: the roles, and whether that list
/// can be believed.
struct RoleCatalog: Equatable {
    /// A role the file holds under a key that is now an official role's.
    struct Shadowed: Equatable, Identifiable {
        var key: String
        var name: String
        var id: String { key }
    }

    /// Roles of the person's that are in the file and not in use, because
    /// Polter ships a role under their key.
    var shadowed: [Shadowed] = []
    /// Why the file of changes to official roles could not be read as a
    /// whole; nil when it could.
    var overridesError: String?

    /// False until the file has been looked at. An empty list before then
    /// is "not read yet", not "no roles".
    var loaded = false
    /// The file does not parse; `roles` is the last good version and the
    /// window must not offer to save over it.
    var error: String?
    var path: String?
    var roles: [Role] = []

    init() {}

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        loaded = (obj["loaded"] as? Bool) ?? false
        error = obj["error"] as? String
        path = obj["path"] as? String
        roles = ((obj["personas"] as? [[String: Any]]) ?? []).compactMap(Role.init(json:))
        shadowed = ((obj["shadowed"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let key = row["key"] as? String else { return nil }
            return Shadowed(key: key, name: (row["name"] as? String) ?? key)
        }
        overridesError = OfficialWhy.display(
            code: obj["overrides_error_code"] as? String,
            detail: obj["overrides_error_detail"] as? String,
            english: obj["overrides_error"] as? String)
    }
}

/// One skill or MCP server a CLI has installed, as its adapter described it.
struct AgentCliItem: Equatable, Identifiable {
    enum Kind: String { case skill, mcp }

    var id: String
    var kind: Kind
    var name: String
    var summary: String
    var detail: String
    var source: String
    var group: String?
    var groupSummary: String?
    var locked: Bool

    init?(json obj: [String: Any]) {
        guard let id = obj["id"] as? String,
              let kind = (obj["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let name = obj["name"] as? String else { return nil }
        self.id = id
        self.kind = kind
        self.name = name
        summary = (obj["description"] as? String) ?? ""
        detail = (obj["detail"] as? String) ?? ""
        source = (obj["source"] as? String) ?? ""
        group = obj["group"] as? String
        groupSummary = obj["group_description"] as? String
        locked = (obj["locked"] as? Bool) ?? false
    }
}

/// An agent CLI a role can start, found because a plugin manages it.
struct AgentCli: Equatable, Identifiable {
    var key: String
    var label: String
    var bin: String
    /// The adapter could not answer; `items` is empty for that reason and
    /// not because nothing is installed.
    var error: String?
    /// Whether the CLI's program was found. Nil when the adapter did not say.
    var installed: Bool?
    var items: [AgentCliItem] = []
    var notes: [String] = []
    /// The unattended settings its adapter offers, each with only the
    /// values this version of the CLI takes (the inventory's `options`,
    /// task 1677).
    var options: [AgentCliOption] = []

    var id: String { key }

    func items(_ kind: AgentCliItem.Kind) -> [AgentCliItem] {
        items.filter { $0.kind == kind }
    }

    init?(json obj: [String: Any]) {
        guard let key = obj["key"] as? String else { return nil }
        self.key = key
        label = (obj["label"] as? String) ?? key
        bin = (obj["bin"] as? String) ?? key
        error = obj["error"] as? String
        if let inventory = obj["inventory"] as? [String: Any] {
            installed = inventory["installed"] as? Bool
            items = ((inventory["items"] as? [[String: Any]]) ?? []).compactMap(AgentCliItem.init(json:))
            notes = (inventory["notes"] as? [String]) ?? []
            options = ((inventory["options"] as? [[String: Any]]) ?? []).compactMap(AgentCliOption.init(json:))
        }
    }
}

/// One unattended setting an adapter offers (`permission_mode`, `sandbox`):
/// a drop-down whose values are the CLI's own words, each with the flags it
/// adds -- shown in grey beside it.
struct AgentCliOption: Equatable, Identifiable {
    struct Value: Equatable {
        var value: String
        var args: [String]
    }

    var key: String
    var label: String
    var values: [Value]

    var id: String { key }

    init?(json obj: [String: Any]) {
        guard let key = obj["key"] as? String else { return nil }
        self.key = key
        label = (obj["label"] as? String) ?? key
        values = ((obj["values"] as? [[String: Any]]) ?? []).compactMap { v in
            guard let value = v["value"] as? String else { return nil }
            return Value(value: value, args: (v["args"] as? [String]) ?? [])
        }
    }

    /// What the window calls it: the three the two adapters offer by their
    /// words in the design, anything else by the adapter's own label.
    var title: String {
        switch key {
        case "permission_mode": return String(localized: "Permission Mode", comment: "角色库：Claude Code 的无人值守下拉，--permission-mode")
        case "approval": return String(localized: "Approval", comment: "角色库：Codex 的无人值守下拉，--ask-for-approval")
        case "sandbox": return String(localized: "Sandbox", comment: "角色库：Codex 的无人值守下拉，--sandbox")
        default: return label
        }
    }
}

/// The skills or MCP servers of every CLI a role starts in, as one list
/// (07, 08; task 1677): the role keeps one set for all of them.
///
/// The rules, the design's four answers:
/// 1. **One id is one row.** Both adapters write ids alike, so a skill
///    both CLIs have is one switch; the first CLI's description is shown.
/// 2. A row only one CLI has says so ("Codex only"), beside its name.
/// 3. A CLI that cannot be read (plugin off, or none) is not guessed at:
///    its items are not listed, and **no row is marked "only"** -- with one
///    side unread, "only the other" would be a guess. The role's ticks for
///    it stay as they are.
/// 4. With one CLI, nothing is marked: "only it" says nothing.
struct RoleMergedItems: Equatable {
    struct Row: Equatable, Identifiable {
        var item: AgentCliItem
        /// The name of the one CLI that has it, when that is worth saying.
        var only: String?
        var id: String { item.id }
    }

    var rows: [Row]
    /// CLIs the role starts in whose lists could not be read: their key,
    /// and their name when the core has one.
    var unread: [(key: String, label: String)]

    static func == (a: Self, b: Self) -> Bool {
        a.rows == b.rows && a.unread.map(\.key) == b.unread.map(\.key)
    }

    static func of(_ kind: AgentCliItem.Kind, clis keys: [String], in snapshot: AgentCliSnapshot) -> RoleMergedItems {
        var read: [AgentCli] = []
        var unread: [(key: String, label: String)] = []
        for key in keys {
            if let cli = snapshot.cli(key), cli.error == nil {
                read.append(cli)
            } else {
                let held = snapshot.heldBack.first { $0.key == key }
                unread.append((key, snapshot.cli(key)?.label ?? held?.label ?? key))
            }
        }
        let marking = read.count > 1 && unread.isEmpty
        var rows: [Row] = []
        var at: [String: Int] = [:]
        var holders: [String: [String]] = [:]
        for cli in read {
            for item in cli.items(kind) {
                holders[item.id, default: []].append(cli.label)
                if at[item.id] == nil {
                    at[item.id] = rows.count
                    rows.append(Row(item: item, only: nil))
                }
            }
        }
        if marking {
            for i in rows.indices {
                let who = holders[rows[i].item.id] ?? []
                if who.count == 1 { rows[i].only = who[0] }
            }
        }
        return RoleMergedItems(rows: rows, unread: unread)
    }
}

/// The core's cache of what each CLI has installed.
struct AgentCliSnapshot: Equatable {
    /// Nothing has ever been read. Not the same as "no CLIs".
    var stale = true
    /// A newer answer is on its way; ask again shortly.
    var refreshing = false
    var clis: [AgentCli] = []
    /// CLIs a plugin manages that are not in `clis` because they cannot be
    /// started here, and why (task 1677). A CLI in neither has no plugin.
    var heldBack: [HeldBack] = []

    struct HeldBack: Equatable {
        enum Why: String { case pluginOff = "plugin_off", cannotRun = "cannot_run" }
        var key: String
        var label: String
        var why: Why
    }

    /// Where a CLI a role names stands here. Three reasons it cannot start,
    /// because the person does three different things about them.
    enum Standing: Equatable {
        case ok
        /// Installed, switched off: a switch in Plugins.
        case pluginOff(label: String)
        /// On, and nothing here can run its adapter: no switch fixes it.
        case cannotRun(label: String)
        /// No plugin manages it.
        case noPlugin
    }

    func standing(_ key: String) -> Standing {
        if cli(key) != nil { return .ok }
        guard let held = heldBack.first(where: { $0.key == key }) else { return .noPlugin }
        switch held.why {
        case .pluginOff: return .pluginOff(label: held.label)
        case .cannotRun: return .cannotRun(label: held.label)
        }
    }

    /// The sentence for a CLI a role names that cannot start here; nil
    /// when it can.
    func whyNot(_ key: String) -> String? {
        switch standing(key) {
        case .ok:
            return nil
        case .pluginOff(let label):
            return String(localized: "\(label) plugin is off: \(label) won't be offered when this role is started. The settings stay in the role.",
                          comment: "角色库：角色勾了某 CLI，但它的插件装着、关着。两个都是 CLI 名")
        case .cannotRun(let label):
            return String(localized: "\(label) can't be started on this machine: nothing here can run its plugin. The settings stay in the role.",
                          comment: "角色库：角色勾了某 CLI，插件开着，但这台机器上跑不起来它的 adapter。是 CLI 名")
        case .noPlugin:
            return String(localized: "No plugin manages this CLI any more", comment: "角色库：角色里配了某 CLI，但对应插件已不在")
        }
    }

    init() {}

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        stale = (obj["stale"] as? Bool) ?? true
        refreshing = (obj["refreshing"] as? Bool) ?? false
        clis = ((obj["clis"] as? [[String: Any]]) ?? []).compactMap(AgentCli.init(json:))
        heldBack = ((obj["held_back"] as? [[String: Any]]) ?? []).compactMap { one in
            guard let key = one["key"] as? String,
                  let why = (one["why"] as? String).flatMap(HeldBack.Why.init(rawValue:)) else { return nil }
            return HeldBack(key: key, label: (one["label"] as? String) ?? key, why: why)
        }
    }

    func cli(_ key: String) -> AgentCli? {
        clis.first { $0.key == key }
    }

    func label(for key: String) -> String {
        cli(key)?.label ?? heldBack.first { $0.key == key }?.label ?? key
    }
}

/// Splitting and joining the extra-arguments field.
///
/// One line in the window, a list in the file: typed the way a shell would
/// take it, with quotes around anything that has a space in it.
enum RoleArgs {
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for c in text {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                started = true
            } else if c.isWhitespace {
                if started || !current.isEmpty { out.append(current) }
                current = ""
                started = false
            } else {
                current.append(c)
            }
        }
        if started || !current.isEmpty { out.append(current) }
        return out
    }

    static func join(_ args: [String]) -> String {
        args.map { arg in
            guard arg.isEmpty || arg.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else { return arg }
            return arg.contains("\"") ? "'\(arg)'" : "\"\(arg)\""
        }.joined(separator: " ")
    }
}

/// The skills or MCP servers of one CLI, in groups a person recognises:
/// their own, this project's, and one per plugin.
struct RoleItemGroup: Identifiable {
    var id: String
    var title: String
    var summary: String?
    var items: [AgentCliItem]

    static func groups(_ items: [AgentCliItem]) -> [RoleItemGroup] {
        var order: [String] = []
        var byKey: [String: RoleItemGroup] = [:]
        for item in items {
            let key = item.group.map { "plugin:\($0)" } ?? item.source
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = RoleItemGroup(
                    id: key,
                    title: title(for: item),
                    summary: item.groupSummary,
                    items: [])
            }
            byKey[key]?.items.append(item)
        }
        let rank: (String) -> Int = { key in
            switch key {
            case "user": return 0
            case "project": return 1
            case "local": return 2
            // The user's own things, in the order they are theirs. The
            // plugins, which have no fixed order, come after all of them.
            case "claude.ai": return 3
            case "claude-code": return 4
            default: return 5
            }
        }
        return order
            .sorted { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b)
                    : (byKey[a]?.title ?? a).localizedCaseInsensitiveCompare(byKey[b]?.title ?? b) == .orderedAscending
            }
            .compactMap { byKey[$0] }
    }

    private static func title(for item: AgentCliItem) -> String {
        if let group = item.group { return group }
        switch item.source {
        case "user": return String(localized: "Yours", comment: "角色库：分组名，用户自己装的（~/.claude 下）")
        case "project": return String(localized: "This Project", comment: "角色库：分组名，项目目录里的")
        case "local": return String(localized: "This Project, Only on This Machine", comment: "角色库：分组名，本机该项目的私有配置")
        case "claude.ai": return String(localized: "Synced from claude.ai", comment: "角色库：分组名，从 claude.ai 同步下来的 skill")
        case "claude-code": return String(localized: "Built In", comment: "角色库：分组名，Claude Code 自带的 skill，只能整体开关")
        default: return item.source
        }
    }
}

