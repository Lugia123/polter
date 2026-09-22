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

/// A role's choices for one agent CLI.
struct RoleCliChoice: Equatable, Identifiable {
    var cli: String
    var skills = RoleSelection()
    var mcp = RoleSelection()
    var model: String = ""
    var args: [String] = []

    var id: String { cli }

    init(cli: String) { self.cli = cli }

    init(cli: String, json: Any?) {
        self.cli = cli
        let obj = json as? [String: Any] ?? [:]
        skills = RoleSelection(json: obj["skills"])
        mcp = RoleSelection(json: obj["mcp"])
        model = (obj["model"] as? String) ?? ""
        args = (obj["args"] as? [String]) ?? []
    }

    var json: [String: Any] {
        var out: [String: Any] = ["skills": skills.json, "mcp": mcp.json]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out["model"] = trimmed }
        if !args.isEmpty { out["args"] = args }
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
    var polter = RolePolter()

    /// Shipped with Polter. Shown, launched and copied, never saved: the
    /// core refuses to replace or delete one.
    var builtin = false

    /// Everything else in the object, as JSON, so it compares and saves.
    var passthrough: Data = Data("{}".utf8)

    var id: String { key }

    static let editedKeys: Set<String> = ["key", "name", "description", "instructions", "clis", "polter", "builtin"]

    /// The key of the supervisor role Polter ships (`persona.supervisor_key`).
    static let supervisorKey = "polter-supervisor"

    /// The name to show. A built-in role's is in the core in English, and
    /// shown here in the user's language.
    var displayName: String {
        guard builtin else { return name }
        switch key {
        case Self.supervisorKey: return String(localized: "Polter Supervisor", comment: "角色库：内置角色名，Polter 总管")
        default: return name
        }
    }

    var displaySummary: String {
        guard builtin else { return summary }
        switch key {
        case Self.supervisorKey:
            return String(localized: "Starts in a new tab as this window's supervisor: splits the work, hands it out and checks it.", comment: "角色库：内置总管角色的一句话说明")
        default: return summary
        }
    }

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
        polter = RolePolter(json: obj["polter"])
        builtin = (obj["builtin"] as? Bool) ?? false
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

/// What the core said about the library: the roles, and whether that list
/// can be believed.
struct RoleCatalog: Equatable {
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
        }
    }
}

/// The core's cache of what each CLI has installed.
struct AgentCliSnapshot: Equatable {
    /// Nothing has ever been read. Not the same as "no CLIs".
    var stale = true
    /// A newer answer is on its way; ask again shortly.
    var refreshing = false
    var clis: [AgentCli] = []

    init() {}

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        stale = (obj["stale"] as? Bool) ?? true
        refreshing = (obj["refreshing"] as? Bool) ?? false
        clis = ((obj["clis"] as? [[String: Any]]) ?? []).compactMap(AgentCli.init(json:))
    }

    func cli(_ key: String) -> AgentCli? {
        clis.first { $0.key == key }
    }

    func label(for key: String) -> String {
        cli(key)?.label ?? key
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
            default: return 3
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
        default: return item.source
        }
    }
}

