import Testing
import AppKit
@testable import Ghostty

/// Covers the file-management half of `ProjectStore` (listing, overwrite,
/// deletion, filename sanitization) using empty trees, which need no live
/// `Ghostty.App`/`ghostty_app_t` to construct -- `SplitTree<ViewType>()`'s
/// root is `nil`, so no leaf ever needs a real `Ghostty.SurfaceView`. What
/// this can't cover without a live app is `ProjectNode.capturing`/
/// `materializing` themselves (see `ProjectDocumentTests` for the format
/// those two serialize to and from, which is the part that can be tested
/// in full).
@MainActor
@Suite
struct ProjectStoreTests {
    private func makeStore() -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-store-tests-\(UUID().uuidString)")
        return ProjectStore(directory: dir)
    }

    @MainActor
    @Test func saveThenListFindsIt() throws {
        let store = makeStore()
        let entry = try store.save(name: "sprint planning", tree: .init())

        #expect(entry.name == "sprint planning")
        #expect(entry.paneCount == 0)

        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "sprint planning")
    }

    @MainActor
    @Test func savingTheSameNameTwiceOverwritesRatherThanDuplicates() throws {
        let store = makeStore()
        try store.save(name: "notes", tree: .init())
        try store.save(name: "notes", tree: .init())

        #expect(store.list().count == 1)
    }

    @MainActor
    @Test func namesThatSanitizeToTheSameFilenameCollide() throws {
        // Mirrors `Project.zig`'s documented trade in `sanitizeFilename`:
        // "two names that sanitize to the same filename collide -- last
        // write wins -- ... the `name` field inside the file is what's
        // authoritative for display either way."
        let store = makeStore()
        try store.save(name: "a/b", tree: .init())
        try store.save(name: "a\\b", tree: .init())

        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "a\\b")
    }

    @MainActor
    @Test func deleteRemovesIt() throws {
        let store = makeStore()
        try store.save(name: "throwaway", tree: .init())
        #expect(store.list().count == 1)

        try store.delete(try #require(store.entry(name: "throwaway")))
        #expect(store.list().isEmpty)
    }

    @MainActor
    @Test func deletingSomethingNotThereThrows() {
        let (store, dir) = makeStoreWithDirectory()
        let gone = ProjectStore.Entry(
            url: dir.appendingPathComponent("never saved.json"),
            name: "never saved",
            savedAt: Date(),
            paneCount: 0)
        #expect(throws: (any Error).self) {
            try store.delete(gone)
        }
    }

    @MainActor
    @Test func blankNameIsRejected() {
        let store = makeStore()
        #expect(throws: ProjectStore.StoreError.self) {
            try store.save(name: "   ", tree: .init())
        }
    }

    @MainActor
    @Test func entryForAnUnknownNameIsNil() {
        let store = makeStore()
        #expect(store.entry(name: "ghost") == nil)
    }

    // MARK: - Binding

    private final class FakeTab: ProjectBindingHolder {
        let projectBindingTitle: String
        init(_ title: String) { projectBindingTitle = title }
    }

    /// Refusing is half of it; the other half is saying which tab has the
    /// project, so the person knows what to close.
    @MainActor
    @Test func actionsOnABoundProjectAreRefusedNamingTheTab() throws {
        let store = makeStore()
        try store.save(name: "notes", tree: .init())
        let tab = FakeTab("~/src/notes")
        guard case .claimed = store.bindings.claim(store.bindingKey(name: "notes"), for: tab) else {
            Issue.record("claim refused")
            return
        }

        #expect(store.holderTitle(name: "notes") == "~/src/notes")
        let actions: [() throws -> Void] = [
            { try store.delete(try #require(store.entry(name: "notes"))) },
            { try store.restorePrevious(try #require(store.entry(name: "notes"))) },
        ]
        for action in actions {
            do {
                try action()
                Issue.record("not refused")
            } catch let error as ProjectStore.StoreError {
                guard case .boundElsewhere(let name, let holder) = error else {
                    Issue.record("wrong error: \(error)")
                    continue
                }
                #expect(name == "notes")
                #expect(holder == "~/src/notes")
                #expect(error.localizedDescription.contains("~/src/notes"))
            }
        }
        #expect(store.entry(name: "notes") != nil)
        withExtendedLifetime(tab) {}
    }

    /// Two names that sanitize to one file are one project, so they are
    /// one binding too.
    @MainActor
    @Test func namesThatShareAFileShareABinding() {
        let store = makeStore()
        #expect(store.bindingKey(name: "a/b") == store.bindingKey(name: "a\\b"))
    }

    @MainActor
    @Test func deleteAlsoRemovesThePreviousVersion() throws {
        let (store, dir) = makeStoreWithDirectory()
        try store.write(ProjectFile(name: "notes", savedAt: 1, root: .leaf(cwd: "/a", title: "", history: "", scrollback: ""), nextScrollback: nil))
        try store.write(ProjectFile(name: "notes", savedAt: 2, root: nil, nextScrollback: nil))
        #expect(store.entry(name: "notes")?.hasPrevious == true)

        try store.delete(try #require(store.entry(name: "notes")))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.json.prev").path))
    }

    // MARK: - Scrollback directory

    @MainActor
    @Test func deleteAlsoRemovesTheScrollbackDirectory() throws {
        let (store, dir) = makeStoreWithDirectory()
        try store.save(name: "notes", tree: .init())
        let snapshots = dir.appendingPathComponent("notes.scrollback")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: snapshots.appendingPathComponent("0.snap"))

        try store.delete(try #require(store.entry(name: "notes")))
        #expect(!FileManager.default.fileExists(atPath: snapshots.path))
    }

    /// A pane that was in the project last time and isn't now leaves a
    /// `<n>.snap` that looks exactly like a live one. Saving an empty tree
    /// wrote nothing, so nothing of the old directory may survive.
    @MainActor
    @Test func savingAgainRemovesSnapshotsThisSaveDidNotWrite() throws {
        let (store, dir) = makeStoreWithDirectory()
        let snapshots = dir.appendingPathComponent("notes.scrollback")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: snapshots.appendingPathComponent("0.snap"))

        try store.save(name: "notes", tree: .init())
        #expect(!FileManager.default.fileExists(atPath: snapshots.path))
    }

    private func makeStoreWithDirectory() -> (ProjectStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-store-tests-\(UUID().uuidString)")
        return (ProjectStore(directory: dir), dir)
    }

    // MARK: - Files an older rule named (issue #23)

    /// The failure this guards against is silent: a project saved under an
    /// older rule's filename is listed (the listing reads contents) but
    /// can't be opened or deleted (those used to recompute the filename).
    /// `a:b` is `a:b.json` under the old macOS rule and `a_b.json` now.
    @MainActor
    @Test func aProjectUnderAnOlderFilenameIsStillFoundAndMovedOnSave() throws {
        let (store, dir) = makeStoreWithDirectory()
        let legacy = dir.appendingPathComponent("a:b.json")
        let root = ProjectNode.leaf(cwd: "/a", title: "", history: "", scrollback: "")
        try ProjectFile(name: "a:b", savedAt: 1, root: root, nextScrollback: 3).encoded().write(to: legacy)
        try Data("previous".utf8).write(to: ProjectFileWriter.previousURL(for: legacy))

        let found = try #require(store.entry(name: "a:b"))
        #expect(found.url.lastPathComponent == "a:b.json")
        #expect(store.list().map(\.name) == ["a:b"])

        try store.save(name: "a:b", tree: .init())

        let moved = dir.appendingPathComponent("a_b.json")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: ProjectFileWriter.previousURL(for: legacy).path))
        #expect(store.list().map(\.url.lastPathComponent) == ["a_b.json"])
        // The layout changed (a pane -> nothing), so the adopted file became
        // `.prev`; the counter it carried survived the move.
        let previous = try ProjectFile.decode(from: Data(contentsOf: ProjectFileWriter.previousURL(for: moved)))
        #expect(previous.root == root)
        #expect(try ProjectFile.decode(from: Data(contentsOf: moved)).nextScrollback == 3)
    }

    /// Deleting goes by the file the entry came from, sidecars included --
    /// not by a filename recomputed from the name.
    @MainActor
    @Test func deletingAProjectUnderAnOlderFilenameRemovesThatFile() throws {
        let (store, dir) = makeStoreWithDirectory()
        let legacy = dir.appendingPathComponent("a:b.json")
        try ProjectFile(name: "a:b", savedAt: 1, root: nil, nextScrollback: nil).encoded().write(to: legacy)
        try Data("previous".utf8).write(to: ProjectFileWriter.previousURL(for: legacy))

        try store.delete(try #require(store.entry(name: "a:b")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
