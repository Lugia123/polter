import Foundation
import Testing
@testable import Ghostty

/// What a save removes from a project's snapshot directory
/// (`ProjectScrollback.prune`). Apart from `ProjectScrollbackTests`, which
/// asks the core to write and read snapshots, so that these run in
/// `tools/mac-logic-tests` (task 1801).
@Suite
struct ProjectScrollbackPruneTests {
    private func makeDirectory(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-scrollback-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func contents(_ dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// Only snapshots go, and only the ones this save did not write
    /// (`2.snap`, from a pane that no longer exists). The core's temporary
    /// file has a random name and is renamed into place after this may have
    /// run: it stays, as does anything else that is not a snapshot (task
    /// 1801).
    @Test func pruneRemovesOnlySnapshotsThatWereNotWritten() throws {
        let dir = try makeDirectory(["0.snap", "1.snap", "2.snap", "c955cd5b39c7435f", "2.snap.tmp", "stray"])
        let pruned = ProjectScrollback.prune(directory: dir, keeping: ["0.snap", "1.snap"])
        #expect(contents(dir) == ["0.snap", "1.snap", "c955cd5b39c7435f", "2.snap.tmp", "stray"])
        // What it says it removed is what it removed (task 1784's log line).
        #expect(pruned.removed == ["2.snap"])
        #expect(!pruned.wholeDirectory)
    }

    @Test func pruneWithNothingWrittenRemovesTheDirectory() throws {
        let dir = try makeDirectory(["0.snap"])
        let pruned = ProjectScrollback.prune(directory: dir, keeping: [])
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(pruned.wholeDirectory)
    }
}
