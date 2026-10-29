import Foundation
import Testing

@testable import Ghostty

/// The squad templates' values and the small rules between them (task 2613,
/// S6): what the core's document reads back as, what a seat writes, and
/// which roles may be in a squad at all.
///
/// Nothing here draws anything and nothing asks the core: these are the
/// files `tools/mac-logic-tests` compiles, and the page that draws them
/// (`SquadLibraryView.swift`) and the type that talks to the core
/// (`SquadLibrary.swift`) are the two this list leaves out.
struct SquadLibraryTests {
    // MARK: The core's document

    static let catalog = """
    {"loaded":true,"error":null,"squads":[
      {"key":"dev","name":"Development","description":"two seats","origin":"user","reason":"","empty":false,
       "members":[
         {"alias":"dev","role":"polter-developer","required":true,"lead":true,"role_missing":false,"supervisor_role":false},
         {"alias":"test","role":"polter-tester","required":false,"lead":false,"role_missing":false,"supervisor_role":false,
          "override":{"cli":"claude-code","instructions":"just the tests","cli_skills":{"add":["a"],"remove":[]}}}
       ]},
      {"key":"sup","name":"Supervisor's own","description":"","origin":"supervisor","reason":"a reason long enough","empty":true,
       "members":[{"alias":"gone","role":"no-such-role","required":false,"lead":false,"role_missing":true,"supervisor_role":false}]}
    ]}
    """

    @Test func theDocumentReadsBackAsTheCoreWroteIt() {
        let read = SquadCatalog(json: Self.catalog)
        #expect(read != nil)
        guard let read else { return }
        #expect(read.loaded)
        #expect(read.error == nil)
        #expect(read.squads.count == 2)

        let dev = read.find("dev")
        #expect(dev?.name == "Development")
        #expect(dev?.summary == "two seats")
        #expect(dev?.origin == .user)
        #expect(dev?.empty == false)
        #expect(dev?.members.count == 2)
        #expect(dev?.members[0].alias == "dev")
        #expect(dev?.members[0].required == true)
        #expect(dev?.members[0].lead == true)
        // The second seat's override: present keys are the squad's word.
        #expect(dev?.members[1].override.cli == "claude-code")
        #expect(dev?.members[1].override.instructions == "just the tests")
        #expect(dev?.members[1].override.cliSkills?.add == ["a"])
        // The role's own `prompt` was never sent, so nothing is claimed about it.
        #expect(dev?.members[1].override.mcp == nil)

        // The two flags the core sets and the page shows.
        #expect(read.find("sup")?.origin == .supervisor)
        #expect(read.find("sup")?.reason == "a reason long enough")
        #expect(read.find("sup")?.members[0].roleMissing == true)
        #expect(read.find("sup")?.empty == true)
    }

    @Test func aDocumentThatIsNotAnObjectIsNotRead() {
        #expect(SquadCatalog(json: "not json at all") == nil)
        #expect(SquadCatalog(json: "[]") == nil)
    }

    @Test func anUnreadFileIsNotAnEmptyList() {
        // The distinction the whole page turns on: `loaded` false is "not
        // looked at yet", and `error` set is "there, and it does not parse".
        let fresh = SquadCatalog()
        #expect(!fresh.loaded)
        #expect(fresh.error == nil)
        #expect(fresh.squads.isEmpty)

        let broken = SquadCatalog(json: #"{"loaded":true,"error":"line 3: expected a name","squads":[]}"#)
        #expect(broken?.loaded == true)
        #expect(broken?.error == "line 3: expected a name")
    }

    @Test func aSquadWithNoNameOrKeyIsNotASquad() {
        #expect(Squad(json: ["name": "no key"]) == nil)
        #expect(Squad(json: ["key": "no-name"]) == nil)
    }

    @Test func theLeadIsTheMarkedOneThenTheFirstRequiredThenTheFirst() {
        // The core's own order (`Squad.leadOf`), which the page repeats
        // rather than invent.
        let marked = Squad(key: "a", name: "a", members: [
            SquadMember(alias: "one", role: "r1", required: true),
            SquadMember(alias: "two", role: "r2", lead: true),
        ])
        #expect(marked.lead?.alias == "two")

        let required = Squad(key: "b", name: "b", members: [
            SquadMember(alias: "one", role: "r1"),
            SquadMember(alias: "two", role: "r2", required: true),
        ])
        #expect(required.lead?.alias == "two")

        let plain = Squad(key: "c", name: "c", members: [
            SquadMember(alias: "one", role: "r1"),
            SquadMember(alias: "two", role: "r2"),
        ])
        #expect(plain.lead?.alias == "one")
        #expect(Squad.blank(key: "d", name: "d").lead == nil)
    }

    // MARK: What a seat writes back

    @Test func aSeatWritesOnlyTheKeysItHas() {
        var member = SquadMember(alias: "dev", role: "polter-developer")
        // Nothing overridden: no `override` key at all, rather than an empty
        // object the core would read as a seat that overrides nothing.
        #expect(member.jsonObject["override"] == nil)

        member.override.cli = "codex"
        let obj = member.jsonObject
        #expect(obj["alias"] as? String == "dev")
        #expect(obj["role"] as? String == "polter-developer")
        #expect(obj["required"] as? Bool == false)
        #expect(obj["lead"] as? Bool == false)
        let override = obj["override"] as? [String: Any]
        #expect(override?["cli"] as? String == "codex")
    }

    @Test func anEmptyInstructionIsNotTheSameAsNoInstruction() {
        // The line `squad.zig` draws and this side has to keep: a key that
        // is there is the squad's word whatever its value.
        var saysNothing = SquadOverride.none
        #expect(saysNothing.isNone)
        #expect(saysNothing.instructions == nil)

        var saysNone = SquadOverride.none
        saysNone.instructions = ""
        #expect(!saysNone.isNone)
        #expect(saysNone.jsonObject["instructions"] as? String == "")
        #expect(saysNone.jsonObject["cli"] == nil)
    }

    @Test func whatTheCoreForbidsNeverGetsWritten() {
        var override = SquadOverride.none
        override.cli = "claude-code"
        override.instructions = "hello"
        override.skills = SquadDelta()
        let keys = Set(override.jsonObject.keys)
        #expect(keys.isSubset(of: Set(["cli", "clis", "instructions", "cli_skills", "cli_mcp", "skills", "mcp"])))
        #expect(keys.isDisjoint(with: SquadOverride.forbiddenKeys))
    }

    @Test func theClisObjectIsKeyedByTheClisName() {
        // The shape the core reads: `clis` is an object keyed by the CLI's
        // name, so the name has to be handed in beside the value -- which is
        // why there is no init that reads a value on its own.
        let obj: [String: Any] = [
            "cli": "claude-code",
            "clis": ["claude-code": ["model": "opus"], "codex": ["args": ["--verbose"]]],
        ]
        let override = SquadOverride(json: obj)
        #expect(override.cliChoice("claude-code")?.model == "opus")
        #expect(override.cliChoice("codex")?.args == ["--verbose"])
        #expect(override.cliChoice("not-there") == nil)
        #expect(override.cliChoice("claude-code")?.isEmpty == false)

        let written = override.jsonObject["clis"] as? [String: Any]
        #expect(Set(written?.keys.map { $0 } ?? []) == Set(["claude-code", "codex"]))
    }

    @Test func aCliChoiceThatSaysNothingIsNotAnOverride() {
        var override = SquadOverride.none
        override.setCliChoice("claude-code") { $0.model = "opus" }
        #expect(override.clis.count == 1)

        // Typed back to nothing: the entry goes, rather than staying as
        // `"claude-code": {}` -- "this seat overrides nothing", spelled long.
        override.setCliChoice("claude-code") { $0.model = "" }
        #expect(override.clis.isEmpty)
        #expect(override.isNone)
        #expect(override.jsonObject["clis"] == nil)
    }

    @Test func anUnknownCliInTheFileIsKeptRatherThanDropped() {
        // Not this window's business whether the CLI is installed: a seat
        // that names one is a fact about the file, and dropping it here
        // would take it out on the next save.
        let override = SquadOverride(json: ["clis": ["a-cli-nobody-has": ["model": "m"]]])
        #expect(override.clis.map(\.cli) == ["a-cli-nobody-has"])
    }

    @Test func aDeltaWritesTheDifferenceAndNothingAtAllWhenThereIsNone() {
        // The role does not have it and the squad turns it on: an add.
        var delta = SquadDelta()
        delta.set("x", on: true, roleHas: false)
        #expect(delta.add == ["x"])
        #expect(delta.remove.isEmpty)
        #expect(delta.isOn("x", roleHas: false))

        // Moved back to what the role already says: neither word is written,
        // so the field is the role's again rather than an override that
        // happens to agree with it.
        delta.set("x", on: false, roleHas: false)
        #expect(delta.isNone)
        #expect(delta.isOn("x", roleHas: false) == false)
        // Which is what "asks the role" means: the same delta against a role
        // that does have it answers true.
        #expect(delta.isOn("x", roleHas: true))

        // The page's other question: the role has it, the squad took it away.
        var removed = SquadDelta()
        removed.set("x", on: false, roleHas: true)
        #expect(removed.remove == ["x"])
        #expect(!removed.isNone)
        #expect(removed.isOn("x", roleHas: true) == false)

        // And unticking, then ticking again, leaves the role's own state.
        removed.set("x", on: true, roleHas: true)
        #expect(removed.isNone)
    }

    @Test func aSquadWritesItsDescriptionAndReasonOnlyWhenItHasThem() {
        let bare = Squad(key: "dev", name: "Dev")
        let bareObj = bare.jsonObject
        #expect(bareObj["description"] == nil)
        #expect(bareObj["reason"] == nil)
        #expect(bareObj["key"] as? String == "dev")

        var theirs = Squad(key: "sup", name: "Sup", origin: .supervisor, reason: "long enough to pass the core")
        theirs.summary = "  spaced  "
        let theirsObj = theirs.jsonObject
        #expect(theirsObj["description"] as? String == "spaced")
        #expect(theirsObj["reason"] as? String == "long enough to pass the core")

        // A reason is a supervisor's: the person's own template carries none
        // however it was typed, since the core refuses one that is too short.
        var mine = Squad(key: "mine", name: "Mine", origin: .user, reason: "short")
        mine.summary = ""
        #expect(mine.jsonObject["reason"] == nil)

        #expect(bare.jsonData != nil)
    }

    // MARK: Which roles may join

    @Test func neitherKindOfSupervisorMayJoinASquad() {
        // Both conditions the design names: the supervisor Polter ships, and
        // any role whose own Polter switch makes its terminal one.
        let shipped = Role(key: "polter-supervisor", name: "Supervisor")
        var theirs = Role(key: "my-own-boss", name: "Boss")
        theirs.polter.supervisor = true
        let plain = Role(key: "polter-developer", name: "Developer")

        #expect(SquadRules.isSupervisor(shipped))
        #expect(SquadRules.isSupervisor(theirs))
        #expect(!SquadRules.isSupervisor(plain))

        let addable = SquadRules.addable([shipped, theirs, plain])
        #expect(addable.map(\.key) == ["polter-developer"])
    }

    @Test func aRoleTheLibraryDoesNotKnowIsNotASupervisorHere() {
        // The core answers `supervisor_role` for a role it found; a role the
        // library does not have is `role_missing` and is a different thing.
        let member = SquadMember(alias: "a", role: "who-knows", roleMissing: true)
        let squad = Squad(key: "s", name: "s", members: [member])
        #expect(SquadRules.supervisorMembers(of: squad, roles: []).isEmpty)
    }

    @Test func aRoleTurnedIntoaSupervisorIsFoundInEverySquadHoldingIt() {
        let boss = Role(key: "polter-supervisor", name: "Supervisor")
        let plain = Role(key: "polter-developer", name: "Developer")
        let one = Squad(key: "one", name: "one", members: [
            SquadMember(alias: "dev", role: "polter-developer"),
            SquadMember(alias: "boss", role: "polter-supervisor"),
        ])
        let two = Squad(key: "two", name: "two", members: [
            SquadMember(alias: "dev2", role: "polter-developer"),
        ])

        let holding = SquadRules.squadsHoldingSupervisors([one, two], roles: [boss, plain])
        #expect(holding.count == 1)
        #expect(holding.first?.squad.key == "one")
        #expect(holding.first?.aliases == ["boss"])

        let cleaned = SquadRules.removing(["boss"], from: one)
        #expect(cleaned.members.map(\.alias) == ["dev"])
        #expect(!cleaned.empty)

        // Taking the last one out leaves an empty template, and `empty` says
        // so rather than leaving the count and the flag disagreeing.
        let gutted = SquadRules.removing(["boss", "dev"], from: one)
        #expect(gutted.members.isEmpty)
        #expect(gutted.empty)
    }

    @Test func theCoresOwnWordOnASeatIsEnoughOnItsOwn() {
        // `supervisor_role` is the core already having looked. The role
        // library here has nothing that matches, so only the flag can be
        // what finds it -- which is the case a role just edited in the Roles
        // section arrives as.
        let squad = Squad(key: "s", name: "s", members: [
            SquadMember(alias: "boss", role: "renamed-since", supervisorRole: true),
            SquadMember(alias: "dev", role: "polter-developer"),
        ])
        #expect(SquadRules.supervisorMembers(of: squad, roles: []).contains("boss"))
    }

    // MARK: Aliases

    @Test func anAliasIsCheckedAgainstTheOthersAndAgainstItself() {
        let members = [
            SquadMember(alias: "dev", role: "r1"),
            SquadMember(alias: "test", role: "r2"),
        ]
        #expect(SquadRules.aliasProblem("dev", among: members, editing: "dev") == nil)
        let clash = SquadRules.aliasProblem("dev", among: members, editing: nil)
        #expect(clash != nil)
        #expect(clash?.contains("dev") == true)

        // Empty, and too long. Only whitespace is empty -- the core asks
        // `std.mem.trim(...).len == 0` (`squad.zig:296`), so `"   "` is a
        // name it refuses as missing rather than as long.
        #expect(SquadRules.aliasProblem("", among: members, editing: nil) != nil)
        #expect(SquadRules.aliasProblem("   ", among: members, editing: nil) != nil)
        let long = String(repeating: "x", count: SquadRules.maxAliasLength)
        #expect(SquadRules.aliasProblem(long, among: members, editing: nil) == nil)
        #expect(SquadRules.aliasProblem(long + "x", among: members, editing: nil) != nil)
        #expect(SquadRules.maxAliasLength == 24)
    }

    @Test func anAliasIsMeasuredInTheCoresUnitNotSwifts() {
        // `squad.zig:296` refuses `alias.len > max_alias_len` where `alias`
        // is `[]const u8`: **UTF-8 bytes**. `String.count` is Characters, so
        // 24 Chinese characters would pass a check written in Characters and
        // then be refused by the core with `BadField` -- a save the page said
        // was fine. Both numbers are asserted here so the difference is the
        // test's subject rather than a thing to notice later.
        let cjk = String(repeating: "开", count: 24)
        #expect(cjk.count == 24, "24 characters")
        #expect(SquadRules.byteLength(cjk) == 72, "and 72 bytes")
        #expect(SquadRules.aliasProblem(cjk, among: [], editing: nil) != nil)

        // Eight of them are exactly the 24 bytes the core allows.
        let eight = String(repeating: "开", count: 8)
        #expect(eight.count == 8)
        #expect(SquadRules.byteLength(eight) == 24)
        #expect(SquadRules.aliasProblem(eight, among: [], editing: nil) == nil)

        // ASCII is one byte a character, so the two units agree there.
        #expect(SquadRules.byteLength("dev") == 3)
        #expect(SquadRules.aliasProblem("dev", among: [], editing: nil) == nil)
    }

    @Test func aSummaryIsMeasuredInTheCoresUnitNotSwifts() {
        #expect(SquadRules.maxSummaryLength == 200)
        let cjk67 = String(repeating: "开", count: 67)
        #expect(cjk67.count == 67)
        #expect(SquadRules.byteLength(cjk67) == 201)
        #expect(SquadRules.byteLength(cjk67) > SquadRules.maxSummaryLength)

        let cjk66 = String(repeating: "开", count: 66)
        #expect(cjk66.count == 66)
        #expect(SquadRules.byteLength(cjk66) == 198)
        #expect(SquadRules.byteLength(cjk66) <= SquadRules.maxSummaryLength)
    }

    @Test func aClashIsReadAsWrittenBecauseThatIsWhatTheCoreReads() {
        // `squad.zig:262` walks the members with `std.mem.eql(u8, q.alias,
        // m.alias)` on the alias as it stands, and `writeMember` writes it
        // untrimmed. Comparing trimmed values here would report a clash the
        // core does not have -- and the page would refuse a save that would
        // have worked.
        //
        // Asked the way the page asks it: each seat against the others, with
        // its own name as the one it is leaving. `editing` is that name, so
        // the seat does not clash with itself.
        let spaced = [
            SquadMember(alias: "dev", role: "r1"),
            SquadMember(alias: " dev ", role: "r2"),
        ]
        #expect(SquadRules.aliasProblems(spaced).isEmpty)
        #expect(SquadRules.duplicateAliases(spaced).isEmpty)
        #expect(SquadRules.aliasProblem(" dev ", among: spaced, editing: " dev ") == nil)

        // Two that are written the same are a clash, whichever name is being
        // typed -- `editing` nil is a seat that is not in the list yet.
        let same = [
            SquadMember(alias: "dev", role: "r1"),
            SquadMember(alias: "dev", role: "r2"),
        ]
        #expect(SquadRules.duplicateAliases(same) == ["dev"])
        #expect(SquadRules.aliasProblems(same).count == 2)
        #expect(SquadRules.aliasProblem("dev", among: same, editing: nil) != nil)
    }

    @Test func twoSeatsWithTheSameNameAreBothMarked() {
        // By position, not by alias: keyed by alias the two would overwrite
        // each other and one of them would be drawn as if it were fine.
        let members = [
            SquadMember(alias: "dev", role: "r1"),
            SquadMember(alias: "dev", role: "r2"),
            SquadMember(alias: "test", role: "r3"),
        ]
        let problems = SquadRules.aliasProblems(members)
        #expect(problems.count == 2)
        #expect(problems[0] != nil)
        #expect(problems[1] != nil)
        #expect(problems[2] == nil)
        #expect(problems[0]?.contains("dev") == true)

        // Empty aliases are two seats with the same (no) name as well.
        let blanks = SquadRules.aliasProblems([
            SquadMember(alias: "", role: "r1"),
            SquadMember(alias: "", role: "r2"),
        ])
        #expect(blanks.count == 2)
    }

    @Test func oneBadSeatIsOneMarkAndTheRestAreFine() {
        let members = [
            SquadMember(alias: "dev", role: "r1"),
            SquadMember(alias: "test", role: "r2"),
            SquadMember(alias: "dev", role: "r3"),
            SquadMember(alias: "", role: "r4"),
        ]
        let problems = SquadRules.aliasProblems(members)
        // Two seats called `dev`, and one with no name at all: three rows
        // marked out of four, and `test` is not one of them.
        #expect(Set(problems.keys) == Set([0, 2, 3]))
        #expect(SquadRules.duplicateAliases(members) == ["dev"])
    }

    @Test func aCleanSquadHasNothingMarked() {
        let members = [
            SquadMember(alias: "dev", role: "r1"),
            SquadMember(alias: "test", role: "r2"),
        ]
        #expect(SquadRules.aliasProblems(members).isEmpty)
        #expect(SquadRules.duplicateAliases(members).isEmpty)
    }

    // MARK: New templates

    @Test func aKeyIsMadeFromTheNameAndIsNeverTakenTwice() {
        // A Chinese name has no letters a key can use, so it falls back to a
        // numbered one rather than to an empty key.
        #expect(SquadRules.suggestedKey(for: "Development", avoiding: []) == "development")
        #expect(SquadRules.suggestedKey(for: "dev Squad", avoiding: []) == "dev-squad")
        #expect(SquadRules.suggestedKey(for: "开发小队", avoiding: []) == "squad-1")
        #expect(SquadRules.suggestedKey(for: "Development", avoiding: ["development"]) == "development-1")
        #expect(SquadRules.suggestedKey(for: "开发小队", avoiding: ["squad-1"]) == "squad-2")

        // Long names are cut to something a key can be.
        let long = String(repeating: "a", count: 40)
        let cut = SquadRules.suggestedKey(for: long, avoiding: [])
        #expect(cut.count <= 24)
        #expect(Role.isValidKey(cut))
        #expect(SquadRules.isValidKey(cut))
    }

    @Test func aKeyIsWhatTheCoreAcceptsAsOne() {
        #expect(SquadRules.isValidKey("dev"))
        #expect(SquadRules.isValidKey("dev-2"))
        #expect(!SquadRules.isValidKey("Dev"))
        #expect(!SquadRules.isValidKey(""))
        #expect(!SquadRules.isValidKey("has space"))
        #expect(!SquadRules.isValidKey("开发"))
        #expect(!SquadRules.isValidKey(String(repeating: "a", count: 33)))
    }

    @Test func aNewTemplateIsSpelledOutEmpty() {
        let blank = Squad.blank(key: "dev", name: "Development")
        #expect(blank.members.isEmpty)
        #expect(blank.empty)
        #expect(blank.origin == .user)
        #expect(blank.summary.isEmpty)
        #expect(blank.reason.isEmpty)
        #expect(blank.displayName == "Development")
        // A template with no name but a key shows its key rather than nothing.
        #expect(Squad.blank(key: "dev", name: "").displayName == "dev")
    }

    @Test func theListSaysHowManySeatsThereAre() {
        #expect(SquadRules.memberCountText(Squad.blank(key: "a", name: "a")).isEmpty == false)
        let two = Squad(key: "b", name: "b", members: [
            SquadMember(alias: "x", role: "r1"),
            SquadMember(alias: "y", role: "r2"),
        ])
        #expect(SquadRules.memberCountText(two).contains("2"))
        #expect(SquadRules.memberCountText(two) != SquadRules.memberCountText(Squad.blank(key: "a", name: "a")))
    }

    // MARK: Where a field stands

    @Test func aFieldSaysWhetherItIsTheRolesOrTheSquads() {
        #expect(SquadFieldSource.inherited.mark != SquadFieldSource.overridden.mark)
        #expect(!SquadFieldSource.inherited.mark.isEmpty)
        #expect(!SquadFieldSource.overridden.mark.isEmpty)
    }

    // MARK: A route to the section

    @Test func aRouteSelectsTheTemplateItNamesOrTheFirstOnAFreshWindow() {
        let keys = ["one", "two"]
        #expect(SettingsRules.squadToSelect(item: "two", fresh: false, keys: keys) == .select("two"))
        // A named template that is gone counts as none named.
        #expect(SettingsRules.squadToSelect(item: "gone", fresh: true, keys: keys) == .select("one"))
        // An open window keeps what it shows.
        #expect(SettingsRules.squadToSelect(item: nil, fresh: false, keys: keys) == .keep)
        #expect(SettingsRules.squadToSelect(item: nil, fresh: true, keys: keys) == .select("one"))
        #expect(SettingsRules.squadToSelect(item: nil, fresh: true, keys: []) == .select(nil))
    }
}
