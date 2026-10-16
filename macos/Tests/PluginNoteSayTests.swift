import Foundation
import Testing
@testable import Ghostty

/// #1644: the hover over a plugin's row in Settings > Plugins showed the
/// core's English note, which is written for an agent ("plugin_configure
/// with enabled: true switches it on"). The settings window's document now
/// carries `note_say` as well -- the same reason as a template -- and the
/// window says that in the person's language. `note` itself is untouched.
struct PluginNoteSayTests {
    private static let listJSON = """
        {"ok":true,"plugins":[
          {"key":"kimi","name":"Kimi CLI","enabled":true,"params":[],
           "state":"dormant","cursor":0,"failures":7,"note":"kimi is dormant: it failed to start 7 time(s)",
           "note_say":{"key":"dormant","template":"It failed to start {1} time(s) and is now tried every fifteen minutes. Polter's log says why.","args":["7"]}},
          {"key":"codex","name":"Codex CLI","enabled":false,"params":[],
           "note":"codex is installed but switched off"}
        ]}
        """

    /// A bundle holding one translation, made in a temporary directory.
    private func bundle(_ strings: String) throws -> (Bundle, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("polter-note-tests-\(UUID().uuidString).bundle")
        for lproj in ["en.lproj", "Base.lproj"] {
            let dir = root.appendingPathComponent(lproj)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(strings.utf8).write(to: dir.appendingPathComponent("Localizable.strings"))
        }
        return (try #require(Bundle(url: root)), root)
    }

    @Test func theNoteStaysAndTheReasonIsSaidInTheBundlesLanguage() throws {
        let list = try #require(PluginCoreStatus.parse(Self.listJSON))
        let kimi = try #require(list["kimi"])
        #expect(kimi.note == "kimi is dormant: it failed to start 7 time(s)")
        #expect(kimi.noteSay?.args == ["7"])

        let (zh, root) = try bundle("""
            "It failed to start {1} time(s) and is now tried every fifteen minutes. Polter's log says why." = "启动失败 {1} 次，现在每 15 分钟试一次。原因见 Polter 的日志。";
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(kimi.shownNote(in: zh) == "启动失败 7 次，现在每 15 分钟试一次。原因见 Polter 的日志。")
    }

    /// No translation: the English template, filled. No `note_say` at all
    /// (an older core, or a document an agent was handed): the note.
    @Test func whatCannotBeSaidFallsBack() throws {
        let list = try #require(PluginCoreStatus.parse(Self.listJSON))
        let (empty, root) = try bundle("")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(list["kimi"]?.shownNote(in: empty)
                == "It failed to start 7 time(s) and is now tried every fifteen minutes. Polter's log says why.")
        #expect(list["codex"]?.noteSay == nil)
        #expect(list["codex"]?.shownNote(in: empty) == "codex is installed but switched off")
    }
}
