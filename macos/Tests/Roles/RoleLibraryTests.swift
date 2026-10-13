import AppKit
import Testing
@testable import Ghostty

/// The role library's values, built without an app, a window or a core.
/// The menu that uses them is `PersonaMenuTests`.
///
/// The value half is also compiled and run on its own against
/// `RoleModels.swift` (see that file's header): these tests run hosted in
/// the app, and starting the app is not something an agent on this machine
/// may do while the user is using it.
@MainActor
@Suite
struct RoleLibraryTests {
    // MARK: Selection

    @Test func aSwitchIsAnExceptionToTheDefault() {
        var s = RoleSelection()
        #expect(s.isOn("skill:a"))
        s.set("skill:a", on: false)
        #expect(!s.isOn("skill:a"))
        #expect(s.except == ["skill:a"])
        s.set("skill:a", on: true)
        #expect(s.except.isEmpty)
    }

    /// The case a plain list of what is on could not express.
    @Test func flippingTheDefaultLeavesEveryVisibleSwitchAlone() {
        var s = RoleSelection()
        s.set("skill:b", on: false)
        s.setDefault(false, keeping: ["skill:a", "skill:b", "skill:c"])
        #expect(s.isOn("skill:a"))
        #expect(!s.isOn("skill:b"))
        #expect(s.isOn("skill:c"))
        #expect(!s.isOn("skill:installed-tomorrow"))
    }

    // MARK: The Polter half

    /// Read, edited and written back; a default one is not written at all,
    /// and `builtin` never is -- a file cannot make a role Polter's.
    @Test func thePolterHalfRoundTripsAndBuiltinIsNeverWritten() throws {
        let json = """
        {"loaded":true,"error":null,"path":null,"personas":[
         {"key":"polter-supervisor","name":"Polter Supervisor","builtin":true,
          "polter":{"supervisor":true,"may_authorise":false,"shielded":false,"watch":false,"open":"tab"}},
         {"key":"w","name":"W","polter":{"watch":true,"open":"auto","quiet_ms":600000}},
         {"key":"plain","name":"P"}]}
        """
        let catalog = try #require(RoleCatalog(json: json))
        let boss = catalog.roles[0]
        #expect(boss.builtin)
        #expect(boss.polter.supervisor)
        #expect(boss.polter.open == .tab)
        #expect(boss.displayName != "")
        #expect(boss.jsonObject["builtin"] == nil)

        var copy = boss
        copy.builtin = false
        #expect((copy.jsonObject["polter"] as? [String: Any])?["supervisor"] as? Bool == true)

        let w = catalog.roles[1]
        #expect(w.polter.watch)
        #expect(w.polter.quietMs == 600000)
        #expect((w.jsonObject["polter"] as? [String: Any])?["quiet_ms"] as? Int == 600000)

        #expect(catalog.roles[2].polter.isDefault)
        #expect(catalog.roles[2].jsonObject["polter"] == nil)
    }

    // MARK: Roles

    private let catalogJSON = """
    {"loaded":true,"error":null,"path":"/x/personas.json","personas":[
     {"key":"archer","name":"Archer","description":"d","instructions":"be brief",
      "tools":{"deny":["notify_user"]},"hint":{"model":"sonnet","disable_host_plugins":[]},
      "skills":["reading-a-terminal"],
      "clis":{"claude-code":{"skills":{"default":false,"except":["skill:pdf"]},"mcp":{"default":true,"except":[]},"model":"opus","args":["--verbose"]}}}]}
    """

    /// A hand-written role's tool rules must survive the window saving its
    /// description.
    /// An official role says where it stands against the shipped one, in
    /// the core's four words; that is read, shown, and never sent back --
    /// it is the core's to say, and a write that carried it would be a
    /// write claiming to know.
    @Test func anOfficialRolesStandingIsReadAndNeverWrittenBack() throws {
        func role(_ official: String) throws -> Role {
            let json = """
            {"key":"polter-tester","name":"Polter Tester","description":"d","builtin":true,
             "official":\(official)}
            """
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try #require(Role(json: obj))
        }
        let stale = try role(#"{"state":"modified_stale","overridden":["instructions","polter.watch"],"stale":["instructions"],"reason":null}"#)
        #expect(stale.official?.state == .modifiedStale)
        #expect(stale.official?.stale == ["instructions"])
        #expect(stale.official?.canRestore == true)
        #expect(try role(#"{"state":"pristine","overridden":[],"stale":[],"reason":null}"#).official?.canRestore == false)
        let unknown = try role(#"{"state":"unknown","overridden":[],"stale":[],"reason":"not json"}"#)
        // Not known is something to put back from, and says why.
        #expect(unknown.official?.canRestore == true)
        #expect(unknown.official?.reason == "not json")
        // A word this build does not know is not guessed at.
        #expect(try role(#"{"state":"something-new"}"#).official == nil)

        // Shown under the name it ships with, whatever the reader's language.
        #expect(stale.displayName == "Polter Tester")
        #expect(stale.displaySummary == "d")
        // What goes back to the core carries neither word for "official".
        #expect(stale.jsonObject["official"] == nil)
        #expect(stale.jsonObject["builtin"] == nil)
        #expect(stale.jsonObject["name"] as? String == "Polter Tester")
    }

    /// The library says which of the person's roles are in the file and not
    /// in use, and why their changes to official roles could not be read;
    /// absent means neither.
    @Test func theCatalogSaysWhatIsShadowedAndWhyChangesWereNotRead() throws {
        let full = try #require(RoleCatalog(json: """
        {"loaded":true,"error":null,"path":"/x/personas.json","personas":[],
         "shadowed":[{"key":"polter-tester","name":"我的测试员"}],"overrides_error":"not json"}
        """))
        #expect(full.shadowed == [.init(key: "polter-tester", name: "我的测试员")])
        #expect(full.overridesError == "not json")
        let plain = try #require(RoleCatalog(json: #"{"loaded":true,"error":null,"path":null,"personas":[]}"#))
        #expect(plain.shadowed.isEmpty)
        #expect(plain.overridesError == nil)
    }

    /// The official skills, each with the text in use and the shipped text;
    /// a list that could not be made is an error, not an empty list.
    @Test func officialSkillsCarryBothTextsAndAnUnknownListIsAnError() throws {
        let some = try #require(OfficialSkillCatalog(json: """
        {"error":null,"skills":[
         {"name":"supervising","description":"d","state":"modified","reason":null,"source":"mine","shipped":"theirs"},
         {"name":"reading-a-terminal","description":"","state":"pristine","reason":null,"source":"same","shipped":"same"}]}
        """))
        #expect(some.skills.map(\.name) == ["supervising", "reading-a-terminal"])
        #expect(some.skills[0].source == "mine" && some.skills[0].shipped == "theirs")
        #expect(some.skills[0].official.canRestore && !some.skills[1].official.canRestore)
        #expect(some.error == nil)
        let none = try #require(OfficialSkillCatalog(json: #"{"error":"could not be listed","skills":null}"#))
        #expect(none.skills.isEmpty && none.error == "could not be listed")
    }

    @Test func fieldsTheWindowDoesNotEditAreWrittenBack() throws {
        let catalog = try #require(RoleCatalog(json: catalogJSON))
        var role = try #require(catalog.roles.first)
        role.name = "Renamed"
        let out = role.jsonObject
        #expect((out["tools"] as? [String: Any]) != nil)
        #expect((out["hint"] as? [String: Any])?["model"] as? String == "sonnet")
        #expect(out["skills"] as? [String] == ["reading-a-terminal"])
        #expect(out["name"] as? String == "Renamed")
        let cc = (out["clis"] as? [String: Any])?["claude-code"] as? [String: Any]
        #expect(cc?["model"] as? String == "opus")
        #expect(cc?["args"] as? [String] == ["--verbose"])
    }

    @Test func anUntouchedRoleIsNotADraft() throws {
        let a = try #require(RoleCatalog(json: catalogJSON)?.roles.first)
        let b = try #require(RoleCatalog(json: catalogJSON)?.roles.first)
        #expect(a == b)
        var c = b
        c.summary = "changed"
        #expect(a != c)
    }

    @Test func aKeyIsMadeFromTheNameWhenItCanBe() {
        #expect(Role.suggestedKey(for: "Code Reviewer!", avoiding: []) == "code-reviewer")
        #expect(Role.suggestedKey(for: "射手", avoiding: []) == "role-1")
        #expect(Role.suggestedKey(for: "射手", avoiding: ["role-1"]) == "role-2")
        #expect(Role.suggestedKey(for: "archer", avoiding: ["archer"]) == "archer-1")
        #expect(Role.isValidKey("a-1"))
        #expect(!Role.isValidKey("Archer"))
        #expect(!Role.isValidKey(String(repeating: "x", count: 33)))
    }

    @Test func extraArgumentsSurviveTheTextField() {
        let args = ["--x", "a b", "", "it's"]
        #expect(RoleArgs.split(RoleArgs.join(args)) == args)
        #expect(RoleArgs.split("--permission-mode auto") == ["--permission-mode", "auto"])
    }
}
