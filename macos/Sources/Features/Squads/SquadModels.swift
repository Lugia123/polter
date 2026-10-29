// The squad templates' values: what the core sends, what the member page
// edits, and the small rules between them. No AppKit and no GhosttyKit on
// purpose, so that these can be compiled and checked on their own
// (tools/mac-logic-tests), the way RoleModels.swift is.
//
// The shape is the core's (`src/poltergeist/squad.zig`): a member names a
// role and stores **only what differs from it**. `SquadStore.writeCatalogJson`
// is the document these decode, and `squad.writeMember` the one
// `ghostty_app_squad_put` takes.
import Foundation

/// One squad template.
struct Squad: Equatable, Identifiable {
    var key: String
    var name: String
    /// The core's `description`. Spelled `summary` here because it is what
    /// the role library calls the same field, and `description` is spoken
    /// for by `CustomStringConvertible`.
    var summary: String = ""
    var origin: SquadOrigin = .user
    /// Why a supervisor made it instead of an existing template; empty for
    /// the person's own (`squad.min_reason_len`).
    var reason: String = ""
    /// The core's word: the template has no members.
    var empty = false
    var members: [SquadMember] = []

    var id: String { key }

    var displayName: String { name.isEmpty ? key : name }

    var displaySummary: String { summary }

    /// The member that leads: the one marked, else the first required, else
    /// the first member (`Squad.leadOf` in the core).
    var lead: SquadMember? {
        members.first { $0.lead } ?? members.first { $0.required } ?? members.first
    }

    func member(_ alias: String) -> SquadMember? {
        members.first { $0.alias == alias }
    }

    /// An empty template, for "new squad".
    static func blank(key: String, name: String) -> Squad {
        Squad(key: key, name: name, summary: "", origin: .user, reason: "", empty: true, members: [])
    }

    init(key: String, name: String, summary: String = "", origin: SquadOrigin = .user,
         reason: String = "", empty: Bool = false, members: [SquadMember] = []) {
        self.key = key
        self.name = name
        self.summary = summary
        self.origin = origin
        self.reason = reason
        self.empty = empty
        self.members = members
    }

    init?(json obj: [String: Any]) {
        guard let key = obj["key"] as? String, let name = obj["name"] as? String else { return nil }
        self.key = key
        self.name = name
        summary = (obj["description"] as? String) ?? ""
        origin = (obj["origin"] as? String).flatMap(SquadOrigin.init(rawValue:)) ?? .user
        reason = (obj["reason"] as? String) ?? ""
        empty = (obj["empty"] as? Bool) ?? false
        members = ((obj["members"] as? [[String: Any]]) ?? []).compactMap(SquadMember.init(json:))
    }

    /// The object `ghostty_app_squad_put` takes.
    var jsonObject: [String: Any] {
        var out: [String: Any] = [
            "key": key,
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "origin": origin.rawValue,
            "members": members.map(\.jsonObject),
        ]
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out["description"] = trimmed }
        // A reason is the supervisor's, and the core refuses one shorter
        // than `min_reason_len`; the person's own template carries none.
        if origin == .supervisor, !reason.isEmpty { out["reason"] = reason }
        return out
    }

    var jsonData: Data? {
        try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }
}

/// Who made a template (`squad.Origin`).
enum SquadOrigin: String, Equatable {
    case user, supervisor
}

/// One seat in a template: what it is called, the role it is built on, and
/// what it does differently.
struct SquadMember: Equatable, Identifiable {
    var alias: String
    var role: String
    /// Required or optional: a hint for whoever opens the task, nothing more
    /// (`2433/PLAN.md` §2.6).
    var required: Bool = false
    var lead = false
    /// The core says the role it names is not in the library any more.
    var roleMissing = false
    /// The core says the role is a supervisor role, which may not be a
    /// member at all (v3, item 12).
    var supervisorRole = false
    var override = SquadOverride.none

    /// The alias is the member's identity in the template, and the core
    /// refuses two alike (`DuplicateAlias`), so it is the id here too.
    var id: String { alias }

    init(alias: String, role: String, required: Bool = false, lead: Bool = false,
         roleMissing: Bool = false, supervisorRole: Bool = false,
         override: SquadOverride = .none) {
        self.alias = alias
        self.role = role
        self.required = required
        self.lead = lead
        self.roleMissing = roleMissing
        self.supervisorRole = supervisorRole
        self.override = override
    }

    init?(json obj: [String: Any]) {
        guard let alias = obj["alias"] as? String, let role = obj["role"] as? String else { return nil }
        self.alias = alias
        self.role = role
        required = (obj["required"] as? Bool) ?? false
        lead = (obj["lead"] as? Bool) ?? false
        roleMissing = (obj["role_missing"] as? Bool) ?? false
        supervisorRole = (obj["supervisor_role"] as? Bool) ?? false
        override = SquadOverride(json: obj["override"])
    }

    /// The member `ghostty_app_squad_put` takes. Only the keys that are
    /// there: writing a missing one as an empty value would turn "follows
    /// the role" into "overrides it with nothing" (`writeOverride`).
    var jsonObject: [String: Any] {
        var out: [String: Any] = [
            "alias": alias,
            "role": role,
            "required": required,
            "lead": lead,
        ]
        if !override.isNone { out["override"] = override.jsonObject }
        return out
    }
}

/// What one member says about one agent CLI. Every field is the member's
/// word when it is set, and the role's when it is not (`CliOverride`).
struct SquadCliChoice: Equatable, Identifiable {
    var cli: String
    var model: String = ""
    var args: [String] = []
    var options: [String: String] = [:]

    var id: String { cli }

    var isEmpty: Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && args.isEmpty && options.isEmpty
    }

    init(cli: String) { self.cli = cli }

    /// One choice out of the core's `clis` object, where **the CLI's name is
    /// the key** and the value carries only what the member changes -- so the
    /// name has to be handed in beside the value (`writeOverride`). There is
    /// deliberately no init that reads a value on its own: it would produce a
    /// choice named `""`, which writes the member's choice back under an
    /// empty name. A nameless choice is not something to forget to fill in,
    /// it is something that cannot be spelled.
    init?(cli: String, json: Any?) {
        guard let obj = json as? [String: Any] else { return nil }
        self.cli = cli
        model = (obj["model"] as? String) ?? ""
        args = (obj["args"] as? [String]) ?? []
        options = (obj["options"] as? [String: String]) ?? [:]
    }

    var jsonObject: [String: Any] {
        var out: [String: Any] = [:]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out["model"] = trimmed }
        if !args.isEmpty { out["args"] = args }
        if !options.isEmpty { out["options"] = options }
        return out
    }
}

/// Ids a member adds to, and takes from, what its role has (`squad.Delta`).
/// **Both lists are the squad's word**: an id in neither follows the role.
struct SquadDelta: Equatable {
    var add: [String] = []
    var remove: [String] = []

    var isNone: Bool { add.isEmpty && remove.isEmpty }

    init() {}

    init?(json: Any?) {
        guard let obj = json as? [String: Any] else { return nil }
        add = (obj["add"] as? [String]) ?? []
        remove = (obj["remove"] as? [String]) ?? []
    }

    func isOn(_ id: String, roleHas: Bool) -> Bool {
        if add.contains(id) { return true }
        if remove.contains(id) { return false }
        return roleHas
    }

    /// Put `id` in the state asked for, by writing the difference from the
    /// role and by removing both words when there is none -- so that a tick
    /// moved back is the role's again rather than an override that says the
    /// same thing.
    mutating func set(_ id: String, on: Bool, roleHas: Bool) {
        add.removeAll { $0 == id }
        remove.removeAll { $0 == id }
        guard on != roleHas else { return }
        if on { add.append(id) } else { remove.append(id) }
    }

    var jsonObject: [String: Any] { ["add": add, "remove": remove] }
}

/// What a member does differently from the role it is built on.
///
/// **A key that is there is an override, whatever its value; a key that is
/// not there follows the role.** Every field is an optional with no
/// default, so "the squad did not say" (`nil`) and "the squad said: empty"
/// (`""`) cannot be written by leaving a line out -- the lesson `squad.zig`
/// states for the core, kept here so the two sides cannot drift.
///
/// The role's `key`, `name`, `description`, `prompt`, `polter` and `tools`
/// may not be overridden at all (`forbidden_override_keys`): the last two
/// are the permission boundary. That is why a member page has no name, key
/// or description field and no way to touch the Polter switches.
struct SquadOverride: Equatable {
    /// Which CLI the member starts in, replacing the role's own.
    var cli: String?
    var clis: [SquadCliChoice] = []
    /// Replaces the role's instructions whole. Present and empty is a
    /// replacement too: "this member gets none".
    var instructions: String?
    var cliSkills: SquadDelta?
    var cliMcp: SquadDelta?
    var skills: SquadDelta?
    var mcp: SquadDelta?

    /// The one spelled-out "says nothing" (`Override.none`).
    static let none = SquadOverride()

    /// Keys the core refuses inside `override`, repeated here so a member
    /// page cannot be written that sends one.
    static let forbiddenKeys: Set<String> = ["key", "name", "description", "prompt", "polter", "tools"]

    var isNone: Bool {
        cli == nil && clis.isEmpty && instructions == nil
            && cliSkills == nil && cliMcp == nil && skills == nil && mcp == nil
    }

    init() {}

    init(json: Any?) {
        guard let obj = json as? [String: Any] else { return }
        cli = obj["cli"] as? String
        if let clis = obj["clis"] as? [String: Any] {
            // A `clis` entry that is not an object is dropped rather than
            // written back as an empty choice: the core's own writer only
            // makes objects, so a value of another kind is a hand-edited
            // file the core's reader refuses before this is ever reached.
            self.clis = clis.keys.sorted().compactMap { SquadCliChoice(cli: $0, json: clis[$0]) }
        }
        instructions = obj["instructions"] as? String
        cliSkills = SquadDelta(json: obj["cli_skills"])
        cliMcp = SquadDelta(json: obj["cli_mcp"])
        skills = SquadDelta(json: obj["skills"])
        mcp = SquadDelta(json: obj["mcp"])
    }

    private init(cli: String?, clis: [SquadCliChoice], instructions: String?,
                 cliSkills: SquadDelta?, cliMcp: SquadDelta?, skills: SquadDelta?, mcp: SquadDelta?) {
        self.cli = cli
        self.clis = clis
        self.instructions = instructions
        self.cliSkills = cliSkills
        self.cliMcp = cliMcp
        self.skills = skills
        self.mcp = mcp
    }

    init?(json obj: [String: Any], cli: String) {
        guard let choice = SquadCliChoice(cli: cli, json: obj) else { return nil }
        self.cli = cli
        clis = [choice]
    }

    func cliChoice(_ key: String) -> SquadCliChoice? {
        clis.first { $0.cli == key }
    }

    mutating func setCliChoice(_ key: String, _ change: (inout SquadCliChoice) -> Void) {
        if let i = clis.firstIndex(where: { $0.cli == key }) {
            change(&clis[i])
        } else {
            var fresh = SquadCliChoice(cli: key)
            change(&fresh)
            clis.append(fresh)
        }
        // A choice that says nothing is not an override any more: keeping
        // it would write `"clis": {"claude-code": {}}`, which the core reads
        // as "this member overrides nothing about it" spelled the long way.
        clis.removeAll { $0.isEmpty }
    }

    /// The object `squad.writeOverride` writes: only the keys that are there.
    var jsonObject: [String: Any] {
        var out: [String: Any] = [:]
        if let cli { out["cli"] = cli }
        if !clis.isEmpty {
            out["clis"] = Dictionary(uniqueKeysWithValues: clis.map { ($0.cli, $0.jsonObject) })
        }
        if let instructions { out["instructions"] = instructions }
        if let cliSkills { out["cli_skills"] = cliSkills.jsonObject }
        if let cliMcp { out["cli_mcp"] = cliMcp.jsonObject }
        if let skills { out["skills"] = skills.jsonObject }
        if let mcp { out["mcp"] = mcp.jsonObject }
        return out
    }
}

/// Where a field of the member page stands: the role's, or the squad's.
enum SquadFieldSource: Equatable {
    case inherited, overridden

    var mark: String {
        switch self {
        case .inherited: String(localized: "Inherited from the role", comment: "小队模版：成员页字段标记，这个字段跟着角色走")
        case .overridden: String(localized: "Squad override", comment: "小队模版：成员页字段标记，这个字段被小队改了")
        }
    }
}

/// The core's document: every template, and whether that list can be
/// believed (`SquadStore.writeCatalogJson`).
struct SquadCatalog: Equatable {
    /// False until the file has been looked at. An empty list before then
    /// is "not read yet", not "no templates".
    var loaded = false
    /// The file does not parse; `squads` is the last good version and the
    /// window must not offer to save over it.
    var error: String?
    var squads: [Squad] = []

    init() {}

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        loaded = (obj["loaded"] as? Bool) ?? false
        error = obj["error"] as? String
        squads = ((obj["squads"] as? [[String: Any]]) ?? []).compactMap(Squad.init(json:))
    }

    func find(_ key: String) -> Squad? {
        squads.first { $0.key == key }
    }
}

/// The small rules of the squads page, with nothing drawn: which roles may
/// join, what is wrong with an alias, and what a new template is called.
enum SquadRules {
    /// The key of the supervisor role Polter ships (`persona.supervisor_key`).
    static let supervisorKey = Role.supervisorKey

    /// `squad.max_alias_len`.
    static let maxAliasLength = 24
    /// `squad.max_description_len`.
    static let maxSummaryLength = 200

    /// Whether a role may not be a member: the supervisor Polter ships, or
    /// any role that makes its terminal one (`squad.isSupervisorRole`).
    /// **Both conditions, and the role's own Polter switch rather than its
    /// key**: a role of the person's that they turned into a supervisor is
    /// the second one.
    static func isSupervisor(_ role: Role) -> Bool {
        role.key == supervisorKey || role.polter.supervisor
    }

    /// The roles the "add member" panel may list. The two supervisor kinds
    /// are **not shown at all**, rather than shown greyed: a row that
    /// cannot be picked is a row that invites a click.
    static func addable(_ roles: [Role]) -> [Role] {
        roles.filter { !isSupervisor($0) }
    }

    /// Why an alias cannot be used, in words for the person; nil when it can.
    /// `editing` is the alias the member had before this edit -- a squad's
    /// existing member being renamed does not collide with itself.
    ///
    /// **The core's units, not Swift's.** `squad.zig:296` refuses
    /// `alias.len > max_alias_len` where `alias` is a `[]const u8`: that is
    /// UTF-8 bytes, and `String.count` is Characters. 24 Chinese characters
    /// are 24 characters and 72 bytes, so a check in Characters would let a
    /// template through that the core then refuses with `BadField` -- a save
    /// that fails for a reason this page said was fine. Measured both ways
    /// (byte length of a String's `utf8` view, and the same on the core's
    /// side) rather than assumed.
    static func aliasProblem(_ alias: String, among members: [SquadMember], editing: String?) -> String? {
        if alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "A member needs an alias: the task panel and the channel call this seat by it.",
                          comment: "小队模版：别名不能为空")
        }
        if byteLength(alias) > maxAliasLength {
            return String(format: String(localized: "At most %d characters.", comment: "小队模版：别名过长，%d 是上限"), maxAliasLength)
        }
        // Compared **as written**, which is what the core does: it walks the
        // members with `std.mem.eql(u8, q.alias, m.alias)` (line 262) and
        // writes the alias out untrimmed. Comparing trimmed values here would
        // mark `" dev "` and `"dev"` as a clash the core does not have.
        let clash = members.contains { $0.alias == alias && $0.alias != editing }
        if clash {
            return String(format: String(localized: "Another member of this squad is already called \"%@\".", comment: "小队模版：别名在本小队里重复，%@ 是别名"), alias)
        }
        return nil
    }

    /// A string's length in UTF-8 bytes: the unit the core's `len` is in, and
    /// the one every limit in `squad.zig` is written against.
    static func byteLength(_ text: String) -> Int { text.utf8.count }

    /// The same question for the draft being saved: every alias that the
    /// others would collide with, so a page can mark all of them rather
    /// than the first. Compared as written, for `aliasProblem`'s reason.
    static func duplicateAliases(_ members: [SquadMember]) -> Set<String> {
        var seen: Set<String> = []
        var twice: Set<String> = []
        for m in members where !seen.insert(m.alias).inserted { twice.insert(m.alias) }
        return twice
    }

    /// What is wrong with each member's alias, by the member's **position**.
    ///
    /// Keyed by position and not by alias for the reason the editor states:
    /// the alias is what collides, so two rows that clash would write over
    /// one another in a dictionary keyed by it, and one of the two would be
    /// drawn as if it were fine.
    ///
    /// A name that two members carry is reported against both of them, so
    /// the pair is visible; a name only one carries is checked as an edit of
    /// itself, which is what makes renaming a member not a clash with the
    /// name it is leaving.
    static func aliasProblems(_ members: [SquadMember]) -> [Int: String] {
        let twice = duplicateAliases(members)
        var out: [Int: String] = [:]
        for (i, member) in members.enumerated() {
            let editing = twice.contains(member.alias) ? nil : member.alias
            if let why = aliasProblem(member.alias, among: members, editing: editing) {
                out[i] = why
            }
        }
        return out
    }

    /// The members of `squad` whose role is a supervisor, by alias: what
    /// happens when a role that was already a member is later turned into
    /// one (`FINAL.md` decision 3). The core refuses such a squad
    /// (`SupervisorNotAllowed`), so the page has to offer to take them out
    /// rather than let a save fail with a reason nobody can act on.
    static func supervisorMembers(of squad: Squad, roles: [Role]) -> [String] {
        squad.members.compactMap { member in
            // The core's own word first, and on its own: `supervisor_role` is
            // set by the core for a role it looked at, and it stays true for
            // the window between a role being changed here and the catalog
            // being read again -- which is exactly when the modal is asked
            // for. Folding it into the lookup below would drop it whenever
            // the role library no longer has that key at all.
            if member.supervisorRole { return member.alias }
            guard let role = roles.first(where: { $0.key == member.role }) else { return nil }
            return isSupervisor(role) ? member.alias : nil
        }
    }

    /// Every squad that holds a member whose role is now a supervisor, and
    /// which aliases in it. What the modal beside "delete this role" lists.
    static func squadsHoldingSupervisors(_ squads: [Squad], roles: [Role]) -> [(squad: Squad, aliases: [String])] {
        squads.compactMap { squad in
            let aliases = supervisorMembers(of: squad, roles: roles)
            return aliases.isEmpty ? nil : (squad, aliases)
        }
    }

    /// The same template with those aliases gone, ready to be written back.
    static func removing(_ aliases: [String], from squad: Squad) -> Squad {
        var out = squad
        out.members.removeAll { aliases.contains($0.alias) }
        out.empty = out.members.isEmpty
        return out
    }

    /// A key for a new template, made from its name when the name has any
    /// letters or digits to make one from, and numbered otherwise -- a
    /// Chinese name has none, and a key has to be `[a-z0-9-]`.
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
        if base.isEmpty { base = "squad" }
        if !taken.contains(base) && base != "squad" { return base }
        for n in 1... {
            let candidate = "\(base)-\(n)"
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    /// Whether a key can be saved at all: the same charset a role's key has
    /// (`persona.isValidKey`).
    static func isValidKey(_ key: String) -> Bool {
        Role.isValidKey(key)
    }

    /// A template as the list row shows it: its name, and what its members
    /// amount to.
    static func memberCountText(_ squad: Squad) -> String {
        squad.members.isEmpty
            ? String(localized: "No members yet", comment: "小队模版：列表行副标题，这个小队还没有成员")
            : String(format: String(localized: "%d members", comment: "小队模版：列表行副标题，%d 是成员数"), squad.members.count)
    }
}
