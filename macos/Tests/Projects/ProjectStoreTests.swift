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

        try store.delete(name: "throwaway")
        #expect(store.list().isEmpty)
    }

    @MainActor
    @Test func deletingSomethingNotThereThrows() {
        let store = makeStore()
        #expect(throws: (any Error).self) {
            try store.delete(name: "never saved")
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
}
