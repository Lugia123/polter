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
