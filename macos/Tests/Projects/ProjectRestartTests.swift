import Testing
import AppKit
import GhosttyKit
@testable import Ghostty

/// What happens to a bound project's scrollback when the app restarts (#49).
///
/// After a restart, a bound tab's panes come back through window
/// restoration (`SurfaceView`'s `Codable`), not from the project -- and the
/// tab is bound again (`restoreProjectBinding`). The first autosave then
/// saves those panes into the project.
///
/// Measured first by @0x97e7 (readings 1-3 and the control). Reading 1-3 only
/// ask whether the number and the file survive; a fix could keep both and
/// still lose the history, because the journal, once it starts, rewrites the
/// file from what the pane shows -- and a pane that came back without its
/// snapshot loaded shows nothing. Readings A and B ask for the history itself.
@MainActor
@Suite(.serialized)
struct ProjectRestartTests {
    /// Everything the surface holds, history included, as text.
    private static func text(_ view: Ghostty.SurfaceView) -> String {
        guard let surface = view.surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Spin the main run loop until `condition` holds or `seconds` pass.
    private static func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    @Test func restoredPaneAndTheFirstAutosave() throws {
        guard let app = (NSApplication.shared.delegate as? AppDelegate)?.ghostty.app else {
            // Not a skip: with no live app nothing below would run, and a
            // test that ran nothing must not read as a pass.
            Issue.record("no live ghostty_app_t in this test host; nothing was measured")
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-restart-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir)

        // A pane with something in it that can be looked for afterwards.
        let marker = "MARK49-\(UUID().uuidString.prefix(8))"
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'echo \(marker); exec sleep 600'"
        let original = Ghostty.SurfaceView(app, baseConfig: config)
        try #require(Self.wait(10) { Self.text(original).contains(marker) }, "the original pane never showed \(marker)")

        // Saved as a project with capture on: a real snapshot, waited for
        // (the capture lands asynchronously). A file of made-up bytes would
        // not do: once the restored pane loads it, the core deletes a
        // snapshot it cannot decode.
        try store.save(name: "restart", tree: .init(view: original), capturingScrollback: true, keeping: .onLayoutChange)
        let number = try #require(original.projectSnapshot?.filename)
        let url = try #require(store.entry(name: "restart")?.url)
        let snapshotFile = ProjectScrollback.directory(forProjectFile: url).appendingPathComponent(number)
        try #require(Self.wait(10) {
            ((try? FileManager.default.attributesOfItem(atPath: snapshotFile.path)[.size] as? Int) ?? 0) > 0
        }, "the capture of \(number) never landed")

        // The app restarts: the pane comes back through window restoration.
        let restored = try JSONDecoder().decode(
            Ghostty.SurfaceView.self,
            from: JSONEncoder().encode(original))

        // Reading 1: the number.
        let restoredNumber = restored.projectSnapshot?.filename
        print("RESTART-READING restored pane's snapshot: \(restoredNumber ?? "<none>") (was \(number))")
        #expect(restoredNumber == number, "window restoration dropped the pane's snapshot number")

        // Reading A: the history is back in the restored pane.
        let historyBack = Self.wait(10) { Self.text(restored).contains(marker) }
        print("RESTART-READING restored pane shows \(marker): \(historyBack)")
        #expect(historyBack, "the restored pane does not show \(marker): its snapshot was not loaded")

        // The tab is bound again, and the first autosave runs.
        try store.save(name: "restart", tree: .init(view: restored), capturingScrollback: false, keeping: .onLayoutChange)

        // Reading 2 and 3: the file and the name the project gives the pane.
        let fileSurvives = FileManager.default.fileExists(atPath: snapshotFile.path)
        let saved = try ProjectFile.decode(from: Data(contentsOf: url))
        print("RESTART-READING after the first autosave: \(number) exists=\(fileSurvives); project now refers to \(saved.scrollbackFilenames)")
        #expect(fileSurvives, "the first autosave after a restart deleted \(number), the pane's saved scrollback")
        #expect(saved.scrollbackFilenames == [number], "after the autosave the project refers to \(saved.scrollbackFilenames) for this pane")

        // Reading B: after the journal has rewritten the file from the
        // restored pane (its interval is 5 s by default), the file still
        // restores the history -- a pane built from it shows the marker.
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        var again = Ghostty.SurfaceConfiguration()
        again.scrollbackRestore = snapshotFile.path
        again.command = "/bin/sh -c 'exec sleep 600'"
        let reopened = Ghostty.SurfaceView(app, baseConfig: again)
        let survives = Self.wait(10) { Self.text(reopened).contains(marker) }
        print("RESTART-READING after the journal's rewrite, \(number) restores \(marker): \(survives)")
        #expect(survives, "after the restored pane's journal rewrote \(number), the file no longer holds \(marker)")
    }

    /// Control: the same save and autosave without the restart in between.
    /// If this is green, what reddens above is the lost number, not the
    /// autosave or the prune on their own. (It does not tell a fixed store
    /// from one whose prune deletes nothing; `ProjectScrollbackTests`'s
    /// `pruneKeepsExactlyWhatWasWrittenAndItsTemporary` does.)
    @Test func samePaneAndTheNextAutosave() throws {
        guard let app = (NSApplication.shared.delegate as? AppDelegate)?.ghostty.app else {
            Issue.record("no live ghostty_app_t in this test host; nothing was measured")
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-restart-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir)
        let view = Ghostty.SurfaceView(app, baseConfig: .init())
        try store.save(name: "restart", tree: .init(view: view), capturingScrollback: true, keeping: .onLayoutChange)
        let number = try #require(view.projectSnapshot?.filename)
        let url = try #require(store.entry(name: "restart")?.url)
        let snapshotDir = ProjectScrollback.directory(forProjectFile: url)
        let snapshotFile = snapshotDir.appendingPathComponent(number)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: snapshotFile)

        try store.save(name: "restart", tree: .init(view: view), capturingScrollback: false, keeping: .onLayoutChange)

        let saved = try ProjectFile.decode(from: Data(contentsOf: url))
        #expect(FileManager.default.fileExists(atPath: snapshotFile.path), "control: the autosave deleted \(number) with no restart in between")
        #expect(saved.scrollbackFilenames == [number], "control: the project refers to \(saved.scrollbackFilenames)")
    }
}
