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
}
