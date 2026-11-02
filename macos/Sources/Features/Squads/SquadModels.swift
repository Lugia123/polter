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

// MARK: What a seat adds up to

/// A seat's skills or MCP servers, as its own page shows them: the role's
/// set with the seat's delta laid over it, and the same list of rows the
/// role page draws.
///
/// **The composition is the core's** (`squad.applySelection`): `remove`
/// first, then `add`, each naming a single id. Everything the seat does not
/// name is the role's -- including `keepByDefault`, which the core never
/// takes from the squad (`setSelection` returns `sel.default` unchanged), so
/// the seat page says "follows the role" rather than offering a switch that
/// could not be saved.
///
/// Pure and here rather than in the page: `SquadLibraryView.swift` draws
/// the tabs but this file is the half `tools/mac-logic-tests` compiles, so
/// the rules can be named in a test and made to fail on purpose.
struct SquadMergedItems: Equatable {
    /// The rows the seat's tab draws, from the CLIs the seat actually runs.
    var merged: RoleMergedItems
    /// The role's set with the seat's delta applied. `isOn` on this is what
    /// the switches show.
    var selection: RoleSelection
    /// Whether the seat says anything of its own about these items.
    var overridden: Bool

    /// The kind of delta one of these tabs writes (`SquadOverride`).
    static func delta(_ kind: AgentCliItem.Kind, _ override: SquadOverride) -> SquadDelta? {
        kind == .skill ? override.cliSkills : override.cliMcp
    }

    /// The role's own set, which is what the seat inherits.
    static func base(_ kind: AgentCliItem.Kind, _ role: Role) -> RoleSelection {
        kind == .skill ? role.skills : role.mcp
    }

    /// A role's set with a delta laid over it -- the same two loops the
    /// core's `applySelection` makes, in the same order.
    static func applied(_ base: RoleSelection, _ delta: SquadDelta?) -> RoleSelection {
        guard let delta else { return base }
        var out = base
        for id in delta.remove { out.set(id, on: false) }
        for id in delta.add { out.set(id, on: true) }
        return out
    }

    /// The CLIs whose installed lists the seat's tabs read.
    ///
    /// The seat runs **one** CLI (`squad.resolve` starts the one entry
    /// `cli` names), so a seat that has moved to another CLI reads that
    /// one's list rather than the role's -- otherwise a launcher over
    /// `claude-code` would show `antigravity`'s skills and hide the ones
    /// the seat was given. A launcher stands as its base does, the same
    /// rule `RoleCliOffer.available` follows.
    static func clis(role: Role, member: SquadMember, in snapshot: AgentCliSnapshot) -> [String] {
        guard let cli = member.override.cli, !cli.isEmpty else { return role.clis.map(\.cli) }
        return [snapshot.own(cli)?.base ?? cli]
    }

    static func of(
        _ kind: AgentCliItem.Kind,
        role: Role,
        member: SquadMember,
        in snapshot: AgentCliSnapshot
    ) -> SquadMergedItems {
        let base = base(kind, role)
        let delta = delta(kind, member.override)
        return SquadMergedItems(
            merged: RoleMergedItems.of(kind, clis: clis(role: role, member: member, in: snapshot), in: snapshot),
            selection: applied(base, delta),
            overridden: delta != nil)
    }

    /// "2/80" for one of a seat's tab labels: kept of listed (task 2667).
    ///
    /// **The roles page's reading, one layer over** (`RoleLibraryView.count`):
    /// the same list the tab draws, the same "kept or locked" rule, the same
    /// two guards on either side of it. The guards are what make the word
    /// rather than a number mean something -- `nil` when the seat runs no CLI
    /// at all, and `nil` when the CLIs it reads listed nothing of this kind,
    /// so the tab says "Skills" instead of claiming "0/0", which would be a
    /// count of a list nobody could read.
    static func count(
        _ kind: AgentCliItem.Kind,
        role: Role,
        member: SquadMember,
        in snapshot: AgentCliSnapshot
    ) -> String? {
        guard !clis(role: role, member: member, in: snapshot).isEmpty else { return nil }
        let merged = of(kind, role: role, member: member, in: snapshot)
        let all = merged.merged.rows.map(\.item)
        guard !all.isEmpty else { return nil }
        let sel = merged.selection
        return "\(all.filter { $0.locked || sel.isOn($0.id) }.count)/\(all.count)"
    }

    /// One change made to the **merged** set, written back as the seat's
    /// delta. `change` edits what is on screen; what is stored is only the
    /// difference from the role, so a switch moved back to where the role
    /// has it stops being an override rather than becoming one that says
    /// the same thing (`SquadDelta.set`).
    ///
    /// `keepByDefault` is forced back to the role's: it is not the seat's
    /// word (see the type's own note), and a change that moved it would
    /// otherwise turn into a delta over every listed id.
    static func apply(
        _ change: (inout RoleSelection) -> Void,
        kind: AgentCliItem.Kind,
        role: Role,
        into override: inout SquadOverride
    ) {
        let base = base(kind, role)
        let before = applied(base, delta(kind, override))
        var after = before
        change(&after)
        after.keepByDefault = base.keepByDefault

        // Only the ids whose state actually moved are the seat's word.
        let touched = Set(before.except).symmetricDifference(Set(after.except))
        guard !touched.isEmpty else { return }
        var out = delta(kind, override) ?? SquadDelta()
        for id in touched { out.set(id, on: after.isOn(id), roleHas: base.isOn(id)) }

        switch kind {
        case .skill: override.cliSkills = out.isNone ? nil : out
        case .mcp: override.cliMcp = out.isNone ? nil : out
        }
    }
}

/// The choices a seat's CLI drop-down offers (task 2647), and where the
/// seat's own selection stands among them.
///
/// **The defect this exists for**: the drop-down was built from the *role's*
/// `clis` alone, so a seat whose `override.cli` was one of the person's own
/// Agent CLIs (`claude-deepseek-flash`, over `claude-code`) matched no row
/// and SwiftUI drew nothing at all -- an empty control that looked broken
/// and could not be changed back.
///
/// So the rows are: **follow the role**, the CLIs the core found adapters
/// for, the person's own Agent CLIs, and the keys the snapshot does not
/// know at all -- a launcher the person has deleted, which is never
/// dropped, because losing its row would silently rewrite the seat on the
/// next save.
struct SquadCliOptions: Equatable {
    struct Option: Equatable, Identifiable {
        enum Kind: Equatable {
            /// The role's own: the seat says nothing about the CLI.
            case followRole
            /// A CLI a plugin manages.
            case preset
            /// One of the person's own Agent CLIs (`launchers.json`).
            case own
            /// Named by the seat or the role, and not in the snapshot any
            /// more -- a plugin switched off, or a launcher deleted.
            case orphan
        }

        /// The tag the picker matches on; `""` is follow-the-role.
        var key: String
        var label: String
        var kind: Kind
        /// Why this one is only a row at all when it is an orphan: the
        /// sentence the role library uses for the same key
        /// (`AgentCliSnapshot.whyNot`). Nil for the rows that can start.
        var why: String?

        var id: String { key }
    }

    var options: [Option]
    /// `member.override.cli`, or `""` when the seat follows the role.
    var selected: String
    /// What the selected row says. **Empty is not a state this can be in
    /// for a selection that is set**: a row is made for it. It is empty
    /// only when `selected` is `""` and even that row is missing, which is
    /// what `isMatched` reports.
    var selectedLabel: String
    /// Whether `selected` found a row. False is the old blank control.
    var isMatched: Bool
    /// Whether `selected` is a key the snapshot no longer has.
    var isOrphan: Bool
    /// **Why** the selection has no row, when it has none. `isMatched` is
    /// one bit and this is four answers, because the person does something
    /// different about each -- and because "not read yet" is not "gone"
    /// (rule 5: one flag must not say both "I don't know" and "I know, and
    /// the answer is no").
    var standing: Standing

    enum Standing: Equatable {
        /// A row was made for it.
        case offered
        /// The snapshot knows the key and it cannot start here: its program
        /// is not on this machine, or it is the other major version. The
        /// core has a sentence for which (`AgentCliSnapshot.whyNot`), and
        /// turning a plugin on is the fix.
        case unavailable
        /// The snapshot has never heard of it -- a launcher the person has
        /// deleted, or a key written by hand. Nothing here can say why.
        case unknown
        /// Nothing has been read yet. Not the same as either of the two
        /// above, and the page says so rather than accusing the seat.
        case notRead
    }
    /// The CLIs whose **per-CLI settings** a seat may write
    /// (`override.clis`): the one it starts in, or one the role is already
    /// set up for. Any other key is refused by the core with `BadField`
    /// (`squad.zig:353-360`), so the page works this set out rather than
    /// writing something the core will throw away.
    var settingKeys: [String]

    static func of(role: Role, member: SquadMember, in snapshot: AgentCliSnapshot) -> SquadCliOptions {
        let offered = RoleCliOffer.available(snapshot)

        var options: [Option] = [Option(
            key: "",
            label: role.clis.isEmpty
                ? String(localized: "The role's own", comment: "小队模版：成员页 CLI 选择，跟随角色")
                : String(format: String(localized: "The role's own (%@)", comment: "小队模版：成员页 CLI 选择，%@ 是角色自己的 CLI"), role.clis.map(\.cli).joined(separator: ", ")),
            kind: .followRole)]
        // The presets and the person's own, through the same filter every
        // other start menu reads (task 2237): a CLI whose program is
        // missing or is the other major version is not a row the core would
        // accept.
        var known: Set<String> = [""]

        // **Nothing read yet: the role's own are the rows.** `nil` from
        // `RoleCliOffer.available` is "not known", not "none here", and the
        // same fallback every start menu makes is to offer what the role
        // named. Without this the drop-down of a seat whose snapshot has
        // not arrived holds only "follow the role" -- which is the empty
        // control again, one state over. It is *not* an orphan judgement:
        // `standing` stays `.notRead` for a key nobody has vouched for.
        if snapshot.stale {
            for key in role.clis.map(\.cli) where !key.isEmpty && known.insert(key).inserted {
                options.append(Option(key: key, label: snapshot.label(for: key), kind: .preset, why: nil))
            }
        }
        for cli in snapshot.clis where offered?.contains(cli.key) ?? true {
            guard known.insert(cli.key).inserted else { continue }
            options.append(Option(key: cli.key, label: cli.label, kind: .preset, why: nil))
        }
        for mine in snapshot.own where offered?.contains(mine.key) ?? true {
            guard known.insert(mine.key).inserted else { continue }
            options.append(Option(
                key: mine.key,
                label: String(
                    format: String(localized: "%@ — runs %@", comment: "小队模版：成员页 CLI 选择，一个自定义 Agent CLI 与它底下的 CLI，如「agy bestfunc — runs antigravity」"),
                    mine.name, snapshot.label(for: mine.base)),
                kind: .own,
                why: nil))
        }
        // **Only a key the snapshot does not know at all** -- a launcher
        // the person has deleted. Losing that row would draw nothing (the
        // defect) *and* would quietly rewrite the seat on the next save.
        //
        // A key the snapshot knows but cannot start (its program is not on
        // this machine, or it is the other major version) is deliberately
        // **not** a row: it is not something this seat may be moved to, and
        // `RoleCliOffer.available` is where that question is answered for
        // every start menu in the app. Adding one here would undo that
        // filter one call later. A selection on such a key therefore
        // matches nothing, which is the state the page says out loud.
        //
        // `stale` is the third case and not a fourth: nothing has been read
        // yet, so "not known" is not "gone". One flag for both is exactly
        // what rule 5 is about, so nothing is called an orphan until the
        // snapshot has an answer.
        if !snapshot.stale {
            for key in role.clis.map(\.cli) + [member.override.cli ?? ""] where !key.isEmpty && !snapshot.known(key) {
                guard known.insert(key).inserted else { continue }
                options.append(Option(
                    key: key,
                    label: String(format: String(localized: "%@ (not here any more)", comment: "小队模版：成员页 CLI 选择，这个 CLI 现在这台机器上没有了，%@ 是它的名字"),
                                  snapshot.label(for: key)),
                    kind: .orphan,
                    why: snapshot.whyNot(key)))
            }
        }

        let selected = member.override.cli ?? ""
        let row = options.first { $0.key == selected }
        let standing = Self.standing(row != nil, selected: selected, in: snapshot)
        return SquadCliOptions(
            options: options,
            selected: selected,
            selectedLabel: row?.label ?? "",
            isMatched: row != nil,
            isOrphan: row?.kind == .orphan,
            standing: standing,
            // **No key twice**, in the order the role has them: a seat that
            // starts in a CLI the role already lists names it once, and the
            // page must not draw two "Starting …" sections for one CLI.
            settingKeys: dedup(role.clis.map(\.cli) + (selected.isEmpty ? [] : [selected])))
    }

    /// Why the selection has a row, or why it does not.
    ///
    /// A function rather than a chain of conditions where it is used: the
    /// four answers are read off two independent questions (is there a row;
    /// has the snapshot been read) and a third that only matters when there
    /// is none. Written once, so the page's sentence and the test's
    /// expectation cannot come from two different readings of the same
    /// state.
    static func standing(_ matched: Bool, selected: String, in snapshot: AgentCliSnapshot) -> Standing {
        // **"Nothing read yet" is asked first, and only about a key somebody
        // named.** A row can exist without the snapshot having vouched for
        // it: while nothing has been read the page offers the role's own by
        // name, so there is a row to draw (`isMatched`) and still no answer
        // to give -- "has a row" is not "knows". The empty tag is the
        // exception and keeps `.offered`: its row is the role itself, not a
        // claim about any CLI.
        if snapshot.stale && !selected.isEmpty { return .notRead }
        if matched { return .offered }
        return snapshot.known(selected) ? .unavailable : .unknown
    }

    /// The same keys, in the same order, with each one only once.
    static func dedup(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    /// One CLI's launch settings for this seat: the role's entry for that
    /// CLI with the seat's own keys laid over it -- what `squad.resolve`
    /// builds at launch, with the same rule (the role's entry for *that*
    /// CLI, and nothing about the others).
    static func choice(_ cli: String, role: Role, member: SquadMember) -> RoleCliChoice {
        var out = role.choice(for: cli) ?? RoleCliChoice(cli: cli)
        guard let over = member.override.cliChoice(cli) else { return out }
        if !over.model.isEmpty { out.model = over.model }
        if !over.args.isEmpty { out.args = over.args }
        if !over.options.isEmpty { out.options = over.options }
        return out
    }

    /// Write back **only** what differs from the role: a field that equals
    /// the role's stops being an override instead of being one that says
    /// the same thing (`writeOverride`'s rule, and `SquadDelta.set`'s).
    static func setChoice(
        _ cli: String,
        role: Role,
        into override: inout SquadOverride,
        _ change: (inout RoleCliChoice) -> Void
    ) {
        let base = role.choice(for: cli) ?? RoleCliChoice(cli: cli)
        var edited = choice(cli, role: role, member: SquadMember(alias: "", role: role.key, override: override))
        change(&edited)

        var over = SquadCliChoice(cli: cli)
        if edited.model != base.model { over.model = edited.model }
        if edited.args != base.args { over.args = edited.args }
        if edited.options != base.options { over.options = edited.options }
        override.setCliChoice(cli) { $0 = over }
    }

    /// The CLIs a seat's "Starting …" sections are drawn for: the one it
    /// starts in when it has named one, otherwise the role's own, since
    /// that is what it will run.
    ///
    /// **Not the same question as `settingKeys`**, which is what the core
    /// will *accept* (`override.clis` may also name a CLI the role is set
    /// up for). This one is what the seat will actually run, and it is the
    /// shorter list: a seat starts one CLI, so drawing a section for every
    /// CLI the role allows would be four forms editing something that never
    /// starts.
    static func startClis(role: Role, member: SquadMember) -> [String] {
        guard let cli = member.override.cli, !cli.isEmpty else { return role.clis.map(\.cli) }
        return [cli]
    }
}
