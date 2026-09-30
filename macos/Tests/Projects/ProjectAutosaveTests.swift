import Testing
import Foundation
@testable import Ghostty

/// A clock the test advances by hand, so debounce timing is exact.
private final class ManualClock: ProjectAutosaveScheduler {
    private(set) var now: TimeInterval = 0
    private var queue: [(id: Int, at: TimeInterval, work: () -> Void)] = []
    private var next = 0

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> Int {
        next += 1
        queue.append((next, now + seconds, work))
        return next
    }

    func cancel(_ token: Int) {
        queue.removeAll { $0.id == token }
    }

    func advance(_ seconds: TimeInterval) {
        now += seconds
        while let index = queue.firstIndex(where: { $0.at <= now }) {
            queue.remove(at: index).work()
        }
    }
}

private final class Tab {}

@Suite
struct ProjectAutosaveTests {
    // MARK: - Debounce

    /// A two-second divider drag at 60 events a second is one write, not
    /// 120. Without the debounce this is 120 -- and 120 chances for `.prev`
    /// to be taken from the middle of the drag.
    @Test func aBurstOfChangesIsOneWrite() {
        let clock = ManualClock()
        var writes = 0
        let debouncer = ProjectAutosaveDebouncer(delay: 1.0, scheduler: clock) { writes += 1 }

        for _ in 0..<120 {
            debouncer.poke()
            clock.advance(1.0 / 60)
        }
        clock.advance(1.0)
        #expect(writes == 1)

        for _ in 0..<10 { debouncer.poke() }
        clock.advance(1.5)
        #expect(writes == 2)
    }

    @Test func flushWritesOnlyWhatIsPending() {
        let clock = ManualClock()
        var writes = 0
        let debouncer = ProjectAutosaveDebouncer(delay: 1.0, scheduler: clock) { writes += 1 }

        debouncer.poke()
        debouncer.flush()
        #expect(writes == 1)
        debouncer.flush()
        #expect(writes == 1)
        debouncer.poke()
        debouncer.cancel()
        clock.advance(5)
        #expect(writes == 1)
    }

    // MARK: - One previous generation

    private func makeURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-autosave-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("p.json")
    }

    private func leaf(_ cwd: String, _ title: String = "") -> ProjectNode {
        .leaf(cwd: cwd, title: title, history: "", scrollback: "")
    }

    /// `.prev` is the file from before the *last* layout change -- one
    /// generation. An implementation that only ever wrote `.prev` once
    /// would pass the first half of this and fail the second.
    @Test func previousIsExactlyOneGenerationBack() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        let single = ProjectFile(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil)
        let side = ProjectFile(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil)
        let stacked = ProjectFile(name: "p", savedAt: 3, root: .split(direction: .vertical, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil)

        #expect(try ProjectFileWriter.write(single, to: url, keeping: .onLayoutChange) == .written(rotated: false))
        #expect(!FileManager.default.fileExists(atPath: prev.path))
        let first = try Data(contentsOf: url)

        #expect(try ProjectFileWriter.write(side, to: url, keeping: .onLayoutChange) == .written(rotated: true))
        #expect(try Data(contentsOf: prev) == first)
        let second = try Data(contentsOf: url)

        #expect(try ProjectFileWriter.write(stacked, to: url, keeping: .onLayoutChange) == .written(rotated: true))
        #expect(try Data(contentsOf: prev) == second)
        #expect(try Data(contentsOf: prev) != first)
    }

    /// Titles, cwds and ratios change all day. If they rotated `.prev`, the
    /// layout from before a mistake would be gone the next time a shell set
    /// its title.
    @Test func previousSurvivesChangesThatAreNotLayout() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        try ProjectFileWriter.write(ProjectFile(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        try ProjectFileWriter.write(ProjectFile(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        let kept = try Data(contentsOf: prev)

        let retitled = ProjectFile(name: "p", savedAt: 3, root: .split(direction: .horizontal, ratio: 0.8, left: leaf("/a/x", "vim"), right: leaf("/b")), nextScrollback: nil)
        #expect(try ProjectFileWriter.write(retitled, to: url, keeping: .onLayoutChange) == .written(rotated: false))
        #expect(try Data(contentsOf: prev) == kept)
        #expect(try ProjectFile.decode(from: Data(contentsOf: url)).root == retitled.root)
    }

    // MARK: Overwrite keeps what it replaced (#965)

    /// The case found on the real app: one pane over one pane is no layout
    /// change, so the autosave rule kept nothing -- and the old cwd and
    /// title were gone while the confirmation said they were kept.
    @Test func overwritingOnePaneWithOnePaneKeepsTheReplacedVersion() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        try ProjectFileWriter.write(ProjectFile(name: "g", savedAt: 1, root: leaf("/work/g", "gamma-only"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        let replaced = try Data(contentsOf: url)

        let tab = ProjectFile(name: "g", savedAt: 2, root: leaf("/bin", "/bin/sh"), nextScrollback: nil)
        #expect(try ProjectFileWriter.write(tab, to: url, keeping: .always) == .written(rotated: true))
        #expect(try Data(contentsOf: prev) == replaced)
        #expect(try ProjectFile.decode(from: Data(contentsOf: prev)).root == leaf("/work/g", "gamma-only"))
        #expect(try ProjectFile.decode(from: Data(contentsOf: url)).root == tab.root)
    }

    /// The decision on its own, both kinds side by side: they differ only
    /// where the layout did not change.
    @Test func theTwoKindsDifferOnlyWhenTheLayoutStaysTheSame() throws {
        let old = try ProjectFile(name: "p", savedAt: 1, root: leaf("/a", "x"), nextScrollback: nil).encoded()
        let retitled = ProjectFile(name: "p", savedAt: 2, root: leaf("/a", "y"), nextScrollback: nil)
        let split = ProjectFile(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil)
        let same = ProjectFile(name: "p", savedAt: 9, root: leaf("/a", "x"), nextScrollback: nil)

        #expect(ProjectFileWriter.plan(writing: retitled, over: old, keeping: .onLayoutChange) == .written(rotated: false))
        #expect(ProjectFileWriter.plan(writing: retitled, over: old, keeping: .always) == .written(rotated: true))
        #expect(ProjectFileWriter.plan(writing: split, over: old, keeping: .onLayoutChange) == .written(rotated: true))
        #expect(ProjectFileWriter.plan(writing: split, over: old, keeping: .always) == .written(rotated: true))
        // Nothing but `saved_at` differs: nothing is replaced, nothing kept.
        #expect(ProjectFileWriter.plan(writing: same, over: old, keeping: .always) == .unchanged)
        // No file yet: nothing to keep, either way.
        #expect(ProjectFileWriter.plan(writing: same, over: nil, keeping: .always) == .written(rotated: false))
        // A file that does not decode is kept, either way.
        #expect(ProjectFileWriter.plan(writing: same, over: Data("not json".utf8), keeping: .onLayoutChange) == .written(rotated: true))
    }

    @Test func onlySavedAtChangingIsNotAWrite() throws {
        let url = try makeURL()
        try ProjectFileWriter.write(ProjectFile(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        let before = try Data(contentsOf: url)
        #expect(try ProjectFileWriter.write(ProjectFile(name: "p", savedAt: 2, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange) == .unchanged)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func restoringSwapsAndRestoringAgainUndoes() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        try ProjectFileWriter.write(ProjectFile(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        try ProjectFileWriter.write(ProjectFile(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        let current = try Data(contentsOf: url)
        let previous = try Data(contentsOf: prev)

        try ProjectFileWriter.restorePrevious(at: url)
        #expect(try Data(contentsOf: url) == previous)
        #expect(try Data(contentsOf: prev) == current)

        try ProjectFileWriter.restorePrevious(at: url)
        #expect(try Data(contentsOf: url) == current)
        #expect(try Data(contentsOf: prev) == previous)
    }

    @Test func anUndecodableFileIsKeptNotOverwritten() throws {
        let url = try makeURL()
        try Data("{not json".utf8).write(to: url)
        try ProjectFileWriter.write(ProjectFile(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        #expect(try Data(contentsOf: ProjectFileWriter.previousURL(for: url)) == Data("{not json".utf8))
    }

    // MARK: - One writer per project

    @Test func aSecondBindingIsRefusedAndNamesTheHolder() {
        let registry = ProjectBindingRegistry()
        let first = Tab()
        let second = Tab()

        guard case .claimed = registry.claim("k", for: first) else {
            Issue.record("first claim refused")
            return
        }
        guard case .heldBy(let holder) = registry.claim("k", for: second) else {
            Issue.record("second claim was not refused")
            return
        }
        #expect(holder === first)

        registry.release("k", for: second)
        #expect(registry.owner(of: "k") === first)
        registry.release("k", for: first)
        guard case .claimed = registry.claim("k", for: second) else {
            Issue.record("claim after release refused")
            return
        }
    }

    @Test func aHolderThatWentAwayDoesNotLockTheProject() {
        let registry = ProjectBindingRegistry()
        var gone: Tab? = Tab()
        _ = registry.claim("k", for: gone!)
        gone = nil
        guard case .claimed = registry.claim("k", for: Tab()) else {
            Issue.record("a released-by-deallocation project is still locked")
            return
        }
    }
}
