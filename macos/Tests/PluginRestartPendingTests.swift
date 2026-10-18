import Foundation
import Testing
@testable import Ghostty

/// #1697: switched on through `plugin_configure` while Polter ran, a plugin
/// was started by the core with what was saved, and the Windows settings
/// window still said "Restart Polter to apply" until it was saved there
/// again; this window, the other way round, never said so for a change an
/// agent made under a running copy. Both read their snapshot of "the
/// settings at launch". ↻ is now the core's `restart_pending` and nothing
/// else.
struct PluginRestartPendingTests {
    private static let listJSON = """
        {"ok":true,"plugins":[
          {"key":"codex","enabled":true,"state":"feeding","cursor":0,"failures":0,"restart_pending":false},
          {"key":"archive","enabled":true,"state":"feeding","cursor":4,"failures":0,"restart_pending":true},
          {"key":"slack","enabled":false,"note":"installed but switched off"}
        ]}
        """

    @Test func theDocumentSaysWhichOneWaits() throws {
        let list = try #require(PluginCoreStatus.parse(Self.listJSON))
        // Started by the core with what was saved: nothing waits.
        #expect(list["codex"]?.waitsForRestart == false)
        // Running on settings other than are saved now.
        #expect(list["archive"]?.waitsForRestart == true)
        // No copy running, and the field left out with the rest of the group.
        #expect(list["slack"]?.restartPending == false)
        #expect(list["slack"]?.waitsForRestart == false)
    }

    @Test func onlyARunningCopyCanWait() {
        let stopped = PluginCoreStatus(key: "p", enabled: true, state: "", restartPending: true)
        #expect(!stopped.waitsForRestart)
        let running = PluginCoreStatus(key: "p", enabled: true, state: "feeding", restartPending: true)
        #expect(running.waitsForRestart)
    }
}
