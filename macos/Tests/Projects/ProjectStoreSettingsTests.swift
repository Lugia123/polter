import Foundation
import Testing
@testable import Ghostty

/// Covers what the settings window's Projects section does to the files
/// (settings.md §6.2): rename, copy, delete to the Trash and back, and the
/// version list -- on a directory of its own, with a Trash of its own.
@MainActor
@Suite
struct ProjectStoreSettingsTests {
    private struct Fixture {
        let store: ProjectStore
        let dir: URL
        let trash: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-settings-tests-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("projects")
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let store = ProjectStore(directory: dir) { url in
            let landed = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: landed)
            return landed
        }
        return Fixture(store: store, dir: dir, trash: trash)
    }

    private func leaf(_ cwd: String, _ scrollback: String = "") -> ProjectNode {
        .leaf(cwd: cwd, title: "", history: "", scrollback: scrollback)
    }

    // MARK: The section keeps up with autosave (#965)

    /// A bound tab autosaves while the settings window is open. The section
    /// used to show the "last saved" it read when it was opened until
    /// something else made it read again (the real app: disk 03:04, window
    /// 02:52). A write now reaches it without anybody calling `reload`.
    @Test func aWriteReachesTheProjectsSectionWithoutAReload() throws {
        let f = try makeFixture()
        try f.store.write(ProjectFile(name: "beta", savedAt: 100, root: leaf("/a"), nextScrollback: nil), keeping: .onLayoutChange)
        let model = ProjectsModel(store: f.store)
        model.reload()
        #expect(model.entries.first?.savedAt == Date(timeIntervalSince1970: 100))

        // What an autosave does: a new cwd, written by the store.
        try f.store.write(ProjectFile(name: "beta", savedAt: 200, root: leaf("/a/b"), nextScrollback: nil), keeping: .onLayoutChange)
        #expect(model.entries.first?.savedAt == Date(timeIntervalSince1970: 200))
    }

    /// Another store's writes are not this section's: the notification is
    /// the store's own.
    @Test func anotherStoresWriteIsNotRead() throws {
        let f = try makeFixture()
        let other = try makeFixture()
        try f.store.write(ProjectFile(name: "beta", savedAt: 100, root: leaf("/a"), nextScrollback: nil), keeping: .onLayoutChange)
        let model = ProjectsModel(store: f.store)
        model.reload()
        try f.store.write(ProjectFile(name: "beta", savedAt: 200, root: leaf("/a/b"), nextScrollback: nil), keeping: .onLayoutChange)
        // Behind the model's back, so only a reload could see it.
        try ProjectFile(name: "zzz", savedAt: 1, root: leaf("/z"), nextScrollback: nil).encoded()
            .write(to: f.dir.appendingPathComponent("zzz.json"))
        // The control: a reload does see it, so its absence below means no
        // reload happened rather than a file the list skips.
        #expect(f.store.list().contains { $0.name == "zzz" })
        try other.store.write(ProjectFile(name: "x", savedAt: 1, root: leaf("/x"), nextScrollback: nil), keeping: .onLayoutChange)
        #expect(!model.entries.contains { $0.name == "zzz" })
    }

    /// A project with a `.prev` (two layouts) and one snapshot.
    @discardableResult
    private func seed(_ f: Fixture, _ name: String) throws -> ProjectStore.Entry {
        try f.store.write(ProjectFile(name: name, savedAt: 100, root: leaf("/a"), nextScrollback: 1), keeping: .onLayoutChange)
        let entry = try f.store.write(ProjectFile(
            name: name, savedAt: 200,
            root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a", "0.snap"), right: leaf("/b")),
            nextScrollback: 1), keeping: .onLayoutChange)
        let snaps = ProjectScrollback.directory(forProjectFile: entry.url)
        try FileManager.default.createDirectory(at: snaps, withIntermediateDirectories: true)
        try Data("scroll".utf8).write(to: snaps.appendingPathComponent("0.snap"))
        return entry
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Versions

    @Test func versionsListTheCurrentAndTheKeptOne() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        let versions = f.store.versions(entry)
        #expect(versions.count == 2)
        #expect(versions[0].isCurrent && versions[0].paneCount == 2)
        #expect(!versions[1].isCurrent && versions[1].paneCount == 1)
        #expect(versions[1].savedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func aProjectWithNoPreviousHasOneVersion() throws {
        let f = try makeFixture()
        let entry = try f.store.write(ProjectFile(name: "fresh", savedAt: 1, root: leaf("/a"), nextScrollback: nil), keeping: .onLayoutChange)
        #expect(f.store.versions(entry).map(\.isCurrent) == [true])
    }

    @Test func scrollbackBytesAddUpTheSnapshots() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        #expect(f.store.scrollbackBytes(entry) == 6)
    }

    // MARK: Rename

    @Test func renameMovesTheFileItsPreviousAndItsSnapshots() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        let renamed = try f.store.rename(entry, to: "play")

        #expect(renamed.name == "play")
        #expect(f.store.list().map(\.name) == ["play"])
        #expect(!exists(entry.url))
        #expect(!exists(ProjectFileWriter.previousURL(for: entry.url)))
        #expect(!exists(ProjectScrollback.directory(forProjectFile: entry.url)))
        #expect(exists(ProjectScrollback.directory(forProjectFile: renamed.url).appendingPathComponent("0.snap")))
        // The kept version is renamed too, or restoring it would bring the
        // old name back.
        let prev = try ProjectFile.decode(from: Data(contentsOf: ProjectFileWriter.previousURL(for: renamed.url)))
        #expect(prev.name == "play")
        #expect(f.store.versions(renamed).count == 2)
        // Nothing left behind under a temporary name.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.dir.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func renameOntoAnotherProjectIsRefusedAndTouchesNothing() throws {
        let f = try makeFixture()
        let work = try seed(f, "work")
        try seed(f, "Play")
        #expect(throws: ProjectStore.StoreError.self) {
            try f.store.rename(work, to: "play")
        }
        #expect(Set(f.store.list().map(\.name)) == ["work", "Play"])
        #expect(exists(work.url))
    }

    /// One file on a case-insensitive disk: moved, not deleted.
    @Test func renameThatOnlyChangesCaseKeepsTheProject() throws {
        let f = try makeFixture()
        let entry = try seed(f, "Work")
        let renamed = try f.store.rename(entry, to: "work")
        #expect(f.store.list().map(\.name) == ["work"])
        #expect(exists(renamed.url))
        #expect(exists(ProjectScrollback.directory(forProjectFile: renamed.url).appendingPathComponent("0.snap")))
    }

    private final class FakeTab: ProjectBindingHolder, ProjectMoveFollower {
        let projectBindingTitle = "tab"
        var calls: [String] = []
        func projectWillMove() { calls.append("will") }
        func projectDidMove(to name: String, oldKey: String, key: String, scrollback: URL) {
            calls.append("did \(name) \(URL(fileURLWithPath: oldKey).lastPathComponent)->\(URL(fileURLWithPath: key).lastPathComponent) \(scrollback.lastPathComponent)")
        }
    }

    /// settings.md §6.2: a project bound to an open tab is renamed with it,
    /// and the binding follows.
    @Test func aBoundProjectIsRenamedAndItsBindingFollows() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        let tab = FakeTab()
        guard case .claimed = f.store.bindings.claim(f.store.bindingKey(name: "work"), for: tab) else {
            Issue.record("claim refused")
            return
        }
        try f.store.rename(entry, to: "play")

        #expect(tab.calls == ["will", "did play work.json->play.json play.scrollback"])
        #expect(f.store.bindings.owner(of: f.store.bindingKey(name: "play")) === tab)
        #expect(f.store.bindings.owner(of: f.store.bindingKey(name: "work")) == nil)
        #expect(f.store.holderTitle(name: "play") == "tab")
    }

    // MARK: Copy

    @Test func aCopyTakesTheFirstFreeNameAndTheSnapshotsButNotThePrevious() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        let first = try f.store.duplicate(entry)
        let second = try f.store.duplicate(entry)

        #expect(first.name != second.name)
        #expect(first.name.hasPrefix("work"))
        #expect(second.name == "\(first.name) 2")
        #expect(f.store.list().count == 3)
        #expect(first.paneCount == 2)
        #expect(exists(ProjectScrollback.directory(forProjectFile: first.url).appendingPathComponent("0.snap")))
        #expect(f.store.versions(first).count == 1)
        // The original is untouched.
        #expect(f.store.versions(entry).count == 2)
    }

    // MARK: Delete and undo

    @Test func deleteMovesEveryPartToTheTrashAndUndoPutsThemBack() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        let trashed = try f.store.trash(entry)

        #expect(f.store.list().isEmpty)
        #expect(trashed.moves.count == 3)
        #expect(!exists(entry.url))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).count == 3)

        try f.store.untrash(trashed)
        let back = try #require(f.store.entry(name: "work"))
        #expect(f.store.versions(back).count == 2)
        #expect(f.store.scrollbackBytes(back) == 6)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).isEmpty)
    }

    /// A project saved under the same name after the delete is not
    /// overwritten by the undo.
    @Test func undoIsRefusedWhenTheNameHasBeenTakenSince() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        let trashed = try f.store.trash(entry)
        try f.store.write(ProjectFile(name: "work", savedAt: 999, root: leaf("/new"), nextScrollback: nil), keeping: .onLayoutChange)

        #expect(throws: ProjectStore.StoreError.self) { try f.store.untrash(trashed) }
        #expect(f.store.entry(name: "work")?.savedAt == Date(timeIntervalSince1970: 999))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).count == 3)
    }

    @Test func aBoundProjectIsNotDeleted() throws {
        let f = try makeFixture()
        let entry = try seed(f, "work")
        let tab = FakeTab()
        _ = f.store.bindings.claim(f.store.bindingKey(name: "work"), for: tab)
        #expect(throws: ProjectStore.StoreError.self) { try f.store.trash(entry) }
        #expect(exists(entry.url))
        withExtendedLifetime(tab) {}
    }
}
