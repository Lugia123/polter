import AppKit
import Testing
@testable import Ghostty

/// The role library's values and the `Launch with Role ▸` menu, built
/// without an app, a window or a core.
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

    // MARK: Launch menu

    private func role(_ key: String, clis: [String]) -> Role {
        var r = Role(key: key, name: key.capitalized)
        r.clis = clis.map { RoleCliChoice(cli: $0) }
        return r
    }

    private func submenu(_ roles: [Role], target: RoleLaunchTarget?, loaded: Bool = true) -> NSMenu {
        var catalog = RoleCatalog()
        catalog.loaded = loaded
        catalog.roles = roles
        let item = NSMenuItem()
        RoleLaunchMenu.configure(item, catalog: catalog, clis: AgentCliSnapshot(), target: target, imagesDesired: false)
        return item.submenu!
    }

    @Test func oneCliLaunchesStraightAwayAndSeveralAsk() throws {
        let target = RoleLaunchTargetStub()
        let menu = submenu([role("solo", clis: ["claude-code"]), role("duo", clis: ["claude-code", "codex"])], target: target)

        let solo = menu.items[0]
        #expect(solo.submenu == nil)
        #expect(solo.isEnabled)
        #expect(solo.representedObject as? [String] == ["solo", "claude-code"])
        #expect(solo.action == #selector(RoleLaunchTarget.launchWithRole(_:)))

        let duo = menu.items[1]
        let clis = try #require(duo.submenu)
        #expect(clis.items.map { $0.representedObject as? [String] } == [["duo", "claude-code"], ["duo", "codex"]])
        #expect(clis.items.allSatisfy { $0.isEnabled })

        // The library is always the last row.
        #expect(menu.items.last?.action == #selector(RoleLibraryOpener.showRoleLibrary(_:)))
    }

    /// Shown, not hidden: a role missing from the menu reads as unsaved.
    @Test func aRoleWithNoCliIsListedAndCannotBeClicked() {
        let menu = submenu([role("idle", clis: [])], target: RoleLaunchTargetStub())
        #expect(menu.items[0].title.contains("Idle"))
        #expect(!menu.items[0].isEnabled)
    }

    /// Nowhere to open the tab beside: every launch row is off, and the
    /// library row is still on -- that is when a first role gets made.
    @Test func withNoTerminalOnlyTheLibraryIsClickable() {
        let menu = submenu([role("solo", clis: ["claude-code"])], target: nil)
        let enabled = menu.items.filter { $0.isEnabled && !$0.isSeparatorItem }
        #expect(enabled.count == 1)
        #expect(enabled.first?.action == #selector(RoleLibraryOpener.showRoleLibrary(_:)))
    }

    /// "Not read yet" and "none" are different rows.
    @Test func notReadYetIsNotNoRoles() {
        let unread = submenu([], target: RoleLaunchTargetStub(), loaded: false)
        let empty = submenu([], target: RoleLaunchTargetStub(), loaded: true)
        #expect(unread.items[0].title != empty.items[0].title)
        #expect(!unread.items[0].isEnabled)
        #expect(!empty.items[0].isEnabled)
    }
}

@MainActor
final class RoleLaunchTargetStub: NSObject, RoleLaunchTarget {
    private(set) var launches: [[String]] = []

    func launchWithRole(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [String] { launches.append(pair) }
    }
}
