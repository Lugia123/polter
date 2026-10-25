import Foundation
import Testing
@testable import Ghostty

/// Settings › General › Agent CLI (task 2156): what the core answers, read
/// into the table and the form; a new one's key; what is sent back.
struct AgentCliRulesTests {
    typealias R = AgentCliRules

    static let json = """
    {"presets":[{"key":"claude-code","name":"Claude Code","standing":"ok"},{"key":"codex","name":"Codex","standing":"off"}],
     "roles":[{"key":"polter-supervisor","name":"总管"},{"key":"polter-tester","name":"测试员"}],
     "file":{"version":1,"launchers":[{"key":"claude-deepseek-flash","name":"Claude · DeepSeek flash","base":"claude-code",
       "command":"/home/me/boclaw/claude-boclaw","env":[{"name":"ANTHROPIC_MODEL","value":"deepseek-flash"}],"args":["--verbose"],"roles":["polter-tester"]}]}}
    """

    @Test func theTableIsThePresetsThenTheirOwn() throws {
        let page = try #require(R.decode(Self.json))
        let rows = R.rows(page)
        #expect(rows.map(\.key) == ["claude-code", "codex", "claude-deepseek-flash"])
        #expect(rows.map(\.custom) == [false, false, true])
        #expect(rows[0].command == nil)
        #expect(rows[2].base == "claude-code")
        #expect(page.file.launchers[0].roles == ["polter-tester"])
    }

    @Test func aNewOnesKeyIsItsNameAndNeverTakesOneInUse() throws {
        let page = try #require(R.decode(Self.json))
        #expect(R.key(for: "Claude · DeepSeek flash", in: page) == "claude-deepseek-flash-2")
        #expect(R.key(for: "My Gateway!", in: page) == "my-gateway")
        #expect(R.key(for: "国产模型", in: page) == "agent-cli")
        #expect(R.key(for: "Codex", in: page) == "codex-2")
        // A blank one is off for every role.
        #expect(R.blank(in: page).roles.isEmpty)
        #expect(R.blank(in: page).base == "claude-code")
    }

    @Test func aDraftNeedsANameAFullPathAndPlainVariableNamesButNoTokenIsLookedAt() throws {
        let page = try #require(R.decode(Self.json))
        var c = page.file.launchers[0]
        #expect(R.problem(c) == nil)
        c.command = "~/bin/gw"
        #expect(R.problem(c) == nil)
        c.command = "C:\\tools\\gw.ps1"
        #expect(R.problem(c) == nil)
        c.command = "claude-boclaw"
        #expect(R.problem(c) == .commandNotAbsolute)
        c.command = "/x"
        c.name = " "
        #expect(R.problem(c) == .noName)
        c.name = "n"
        c.env = [.init(name: "1BAD", value: "")]
        #expect(R.problem(c) == .badEnvName("1BAD"))
        c.env = [.init(name: "ANTHROPIC_AUTH_TOKEN", value: "sk-live")]
        #expect(R.problem(c) == nil)
    }

    @Test func whatIsSentHasAKeyAndNoEmptyRows() throws {
        let page = try #require(R.decode(Self.json))
        var c = R.blank(in: page)
        c.name = "My Gateway"
        c.command = "/x/gw"
        c.env = [.init(name: "", value: "ignored"), .init(name: "A", value: "1")]
        c.args = ["", "-v"]
        let sent = try JSONDecoder().decode(R.Custom.self, from: Data(R.putJSON(c, in: page).utf8))
        #expect(sent.key == "my-gateway")
        #expect(sent.env == [.init(name: "A", value: "1")])
        #expect(sent.args == ["-v"])
        #expect(R.args(fromLine: "  --a  b ") == ["--a", "b"])
    }

    /// **This page no longer decides which roles may start in it** (task
    /// 2156 v5): the role library does, through the core's
    /// `ghostty_app_role_launcher_set`. What this page sends still carries
    /// whatever the core last gave it -- it passes the switches straight
    /// through and neither adds nor drops one -- and the core keeps them
    /// (`settingsPutLauncher`, `keep_roles` true).
    @Test func whatIsSentFromThisPagePassesTheRolesThroughUnchanged() throws {
        let page = try #require(R.decode(Self.json))
        let c = try #require(page.file.launchers.first)
        #expect(c.roles == ["polter-tester"])
        let sent = try JSONDecoder().decode(R.Custom.self, from: Data(R.putJSON(c, in: page).utf8))
        #expect(sent.roles == ["polter-tester"])
        // Nothing on this page can tick or untick one, so there is no field
        // whose emptiness would read as "off for every role".
        #expect(R.blank(in: page).roles.isEmpty)
    }

    // MARK: Deleting the selected one (task 2164)

    @MainActor final class Holder: AgentCliDraftHolder {
        var draft: R.Custom?
    }

    /// What `AgentCliModel.delete` does to the form's draft, and what
    /// SwiftUI does next: reads the bindings of the form it is taking away.
    /// That read was a `draft!`, and Polter crashed on it.
    @Test @MainActor func theFormsControlsAreReadOnceMoreAfterTheSelectedOneIsDeletedAndNothingCrashes() throws {
        let page = try #require(R.decode(Self.json))
        let saved = try #require(page.file.launchers.first)
        let h = Holder()
        h.draft = saved
        let name = h.field(\.name, else: saved.name)
        let args = h.field(\.args, else: saved.args)
        let value = h.variable(0, \.value, else: saved.env[0].value)
        #expect(name.wrappedValue == "Claude · DeepSeek flash")

        h.draft = nil

        #expect(name.wrappedValue == "Claude · DeepSeek flash")
        #expect(args.wrappedValue == ["--verbose"])
        #expect(value.wrappedValue == "deepseek-flash")
        // And a write to a control that is going away goes nowhere.
        name.wrappedValue = "typed late"
        #expect(h.draft == nil)
    }

    /// A variable's row removed under its own fields: they are read again
    /// at an index that is no longer there.
    @Test @MainActor func aVariablesFieldsAreReadOnceMoreAfterItsRowIsRemoved() throws {
        let page = try #require(R.decode(Self.json))
        let h = Holder()
        h.draft = try #require(page.file.launchers.first)
        let name = h.variable(0, \.name, else: "ANTHROPIC_MODEL")
        name.wrappedValue = "MODEL"
        #expect(h.draft?.env.first?.name == "MODEL")
        h.removeVariable(0)
        #expect(h.draft?.env.isEmpty == true)
        #expect(name.wrappedValue == "ANTHROPIC_MODEL")
        name.wrappedValue = "late"
        #expect(h.draft?.env.isEmpty == true)
        h.removeVariable(0)
    }
}
