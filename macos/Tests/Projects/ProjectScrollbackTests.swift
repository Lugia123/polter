import Testing
import Foundation
@testable import Ghostty

@Suite
struct ProjectScrollbackTests {
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

    /// The filter is "what this save wrote", including the `.tmp` the core
    /// may still be about to rename into place -- and *every* other entry
    /// goes, including ones that look exactly like a snapshot (`2.snap` from
    /// a pane that no longer exists) and stale temporaries.
    @Test func pruneKeepsExactlyWhatWasWrittenAndItsTemporary() throws {
        let dir = try makeDirectory(["0.snap", "0.snap.tmp", "1.snap", "2.snap", "2.snap.tmp", "stray"])
        ProjectScrollback.prune(directory: dir, keeping: ["0.snap", "1.snap"])
        #expect(contents(dir) == ["0.snap", "0.snap.tmp", "1.snap"])
    }

    @Test func pruneWithNothingWrittenRemovesTheDirectory() throws {
        let dir = try makeDirectory(["0.snap"])
        ProjectScrollback.prune(directory: dir, keeping: [])
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// One sanitizer, not two: the directory is derived from the project
    /// file's URL, so a name with a dot in it still maps to one directory.
    @Test func directorySitsBesideTheProjectFile() {
        let file = URL(fileURLWithPath: "/p/v1.2 notes.json")
        #expect(ProjectScrollback.directory(forProjectFile: file).path == "/p/v1.2 notes.scrollback")
    }

    @Test func onlyWhatFilenameProducesIsAccepted() {
        #expect(ProjectScrollback.isSnapshotFilename(ProjectScrollback.filename(number: 0)))
        #expect(ProjectScrollback.isSnapshotFilename(ProjectScrollback.filename(number: 117)))
        for bad in ["", ".snap", "a.snap", "../0.snap", "0.snap.tmp", "0.SNAP", "1٣.snap"] {
            #expect(!ProjectScrollback.isSnapshotFilename(bad), "\(bad)")
        }
    }

    // MARK: - Allocation

    /// A stand-in for `Ghostty.SurfaceView`: `cwd` says whose history a
    /// snapshot holds, `snapshot` is `SurfaceView.projectSnapshot`.
    private final class Pane {
        let cwd: String
        var snapshot: ProjectScrollback.PaneSnapshot?
        init(_ cwd: String) { self.cwd = cwd }
    }

    /// What `ProjectStore.save` does per leaf, in tree order.
    private func save(_ panes: [Pane], existing: ProjectFile?, capture: Bool) -> ProjectFile {
        var allocator = ProjectScrollback.Allocator(
            project: "/p/p.json",
            storedNext: existing?.nextScrollback,
            inUse: existing?.scrollbackFilenames ?? [])
        let leaves: [ProjectNode] = panes.map { pane in
            let snapshot = allocator.snapshot(for: pane.snapshot, allocate: capture)
            if let snapshot { pane.snapshot = snapshot }
            return .leaf(cwd: pane.cwd, title: "", history: "", scrollback: snapshot?.filename ?? "")
        }
        let root = leaves.dropFirst().reduce(leaves[0]) { .split(direction: .horizontal, ratio: 0.5, left: $0, right: $1) }
        return ProjectFile(name: "p", savedAt: 0, root: root, nextScrollback: allocator.next)
    }

    private func snapshots(_ node: ProjectNode?) -> [String: String] {
        switch node {
        case .leaf(let cwd, _, _, let scrollback): return [cwd: scrollback]
        case .split(_, _, let left, let right): return snapshots(left).merging(snapshots(right)) { $1 }
        case nil: return [:]
        }
    }

    /// The floor for numbering by pane rather than by position: swap two
    /// panes and autosave, and each must still name -- and on restore, get
    /// back -- its own history. Numbering the i-th leaf `i.snap` passes
    /// every test that never moves a pane, and here hands each pane the
    /// other's history.
    @Test func swappingPanesKeepsEachPanesOwnHistory() throws {
        let a = Pane("/a")
        let b = Pane("/b")
        let saved = save([a, b], existing: nil, capture: true)
        let history = snapshots(saved.root)
        #expect(history["/a"] != history["/b"])

        let swapped = save([b, a], existing: saved, capture: false)
        #expect(snapshots(swapped.root) == history)

        let reopened = try ProjectFile.decode(from: swapped.encoded())
        #expect(snapshots(reopened.root) == history)
    }

    /// A number whose pane has closed is never handed out again, even once
    /// nothing on disk or in the file mentions it any more -- or the new
    /// pane would restore the closed one's history.
    @Test func aClosedPanesNumberIsNeverReused() {
        let a = Pane("/a")
        let b = Pane("/b")
        let first = save([a, b], existing: nil, capture: true)
        let closedB = save([a], existing: first, capture: true)
        #expect(!closedB.scrollbackFilenames.contains(b.snapshot!.filename))

        let c = Pane("/c")
        let reopened = save([a, c], existing: closedB, capture: true)
        #expect(c.snapshot?.filename != b.snapshot?.filename)
        #expect(Set(reopened.scrollbackFilenames).count == 2)
    }

    @Test func autosaveHandsOutNoNumbers() {
        let a = Pane("/a")
        let saved = save([a], existing: nil, capture: true)
        let fresh = Pane("/b")
        let autosaved = save([a, fresh], existing: saved, capture: false)
        #expect(fresh.snapshot == nil)
        #expect(snapshots(autosaved.root)["/b"] == "")
        #expect(autosaved.nextScrollback == saved.nextScrollback)
    }

    @Test func aSnapshotFromAnotherProjectIsNotReused() {
        let moved = Pane("/a")
        moved.snapshot = .init(project: "/p/other.json", filename: "0.snap")
        let saved = save([moved], existing: nil, capture: true)
        #expect(moved.snapshot?.project == "/p/p.json")
        #expect(saved.nextScrollback == 1)
    }

    /// A file that lost its counter (written by another port, or by hand)
    /// still can't hand out a number that is in use.
    @Test func theCounterStartsPastEveryNumberInUse() {
        var allocator = ProjectScrollback.Allocator(project: "k", storedNext: nil, inUse: ["4.snap", "junk", "1.snap"])
        #expect(allocator.snapshot(for: nil, allocate: true)?.filename == "5.snap")
    }
}
