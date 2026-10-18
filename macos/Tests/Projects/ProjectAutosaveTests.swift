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
            debouncer.poke(.layout)
            clock.advance(1.0 / 60)
        }
        clock.advance(1.0)
        #expect(writes == 1)

        for _ in 0..<10 { debouncer.poke(.layout) }
        clock.advance(1.5)
        #expect(writes == 2)
    }

    @Test func flushWritesOnlyWhatIsPending() {
        let clock = ManualClock()
        var writes = 0
        let debouncer = ProjectAutosaveDebouncer(delay: 1.0, scheduler: clock) { writes += 1 }

        debouncer.poke(.layout)
        debouncer.flush()
        #expect(writes == 1)
        debouncer.flush()
        #expect(writes == 1)
        debouncer.poke(.layout)
        debouncer.cancel()
        clock.advance(5)
        #expect(writes == 1)
    }

    // MARK: - Changes that never stop

    /// A pane with an agent in it changes its title for as long as the
    /// agent works. `every` seconds apart, for `seconds`.
    private func churn(_ debouncer: ProjectAutosaveDebouncer<ManualClock>, on clock: ManualClock,
                       for seconds: TimeInterval, every: TimeInterval = 0.25) {
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            debouncer.poke(.paneDetail)
            clock.advance(every)
            elapsed += every
        }
    }

    /// What the user reported: a split made while agents were working was
    /// not in the project. Every title change restarted the one-second
    /// wait, and they came four a second.
    @Test func aLayoutChangeIsWrittenWhileTitlesKeepChanging() {
        let clock = ManualClock()
        var writes: [TimeInterval] = []
        let debouncer = ProjectAutosaveDebouncer(scheduler: clock) { writes.append(clock.now) }

        debouncer.poke(.layout)
        churn(debouncer, on: clock, for: 10)
        // Written no later than a layout change may be put off, and not
        // before the burst had its second of quiet to end in.
        let first = writes.first ?? .infinity
        #expect(first <= ProjectAutosaveChange.layout.noLaterThan)
        #expect(first > ProjectAutosaveChange.quiet)
    }

    @Test func titlesThatNeverStopAreWrittenNowAndThenAndNotEachTime() {
        let clock = ManualClock()
        var writes = 0
        let debouncer = ProjectAutosaveDebouncer(scheduler: clock) { writes += 1 }

        // Ninety seconds, 360 changes: not none, and not 360.
        churn(debouncer, on: clock, for: 90)
        #expect(writes == 3)
    }

    @Test func aLayoutChangeBringsForwardAWriteThatWasWaitingOnTitles() {
        let clock = ManualClock()
        var writes: [TimeInterval] = []
        let debouncer = ProjectAutosaveDebouncer(scheduler: clock) { writes.append(clock.now) }

        churn(debouncer, on: clock, for: 10)
        #expect(writes.isEmpty)
        debouncer.poke(.layout)
        churn(debouncer, on: clock, for: 5)
        let first = writes.first ?? .infinity
        #expect(first <= 10 + ProjectAutosaveChange.layout.noLaterThan)
        // And a title after a layout change does not push it back out.
        #expect(first > 10)
    }

    @Test func oneChangeAloneStillWaitsOutItsSecond() {
        let clock = ManualClock()
        var writes = 0
        let debouncer = ProjectAutosaveDebouncer(scheduler: clock) { writes += 1 }

        debouncer.poke(.layout)
        clock.advance(0.9)
        #expect(writes == 0)
        clock.advance(0.2)
        #expect(writes == 1)
        // Nothing left over: the latest moment went with the write.
        clock.advance(60)
        #expect(writes == 1)
    }

    @Test func aWriteThatWasDroppedOrDoneLeavesNoLatestMomentBehind() {
        let clock = ManualClock()
        var writes = 0
        let debouncer = ProjectAutosaveDebouncer(scheduler: clock) { writes += 1 }

        // A layout change, dropped (the tab was unbound). Titles after it
        // are a new burst with their own, longer, latest moment.
        debouncer.poke(.layout)
        clock.advance(0.5)
        debouncer.cancel()
        churn(debouncer, on: clock, for: 10)
        #expect(writes == 0)
        // The same after a flush.
        debouncer.flush()
        #expect(writes == 1)
        churn(debouncer, on: clock, for: 10)
        #expect(writes == 1)
    }

    @Test func aLayoutChangeWaitsLessThanATitleAndBothLongerThanTheQuiet() {
        #expect(ProjectAutosaveChange.quiet == 1)
        #expect(ProjectAutosaveChange.layout.noLaterThan == 3)
        #expect(ProjectAutosaveChange.paneDetail.noLaterThan == 30)
    }

    // MARK: - One previous generation

    private func makeURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-autosave-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("p.json")
    }

    private func leaf(_ cwd: String, _ title: String = "") -> ProjectNode {
        .leaf(cwd: cwd, title: title, history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
    }

    /// `.prev` is the file from before the *last* layout change -- one
    /// generation. An implementation that only ever wrote `.prev` once
    /// would pass the first half of this and fail the second.
    @Test func previousIsExactlyOneGenerationBack() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        let single = ProjectFile.oneTab(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil)
        let side = ProjectFile.oneTab(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil)
        let stacked = ProjectFile.oneTab(name: "p", savedAt: 3, root: .split(direction: .vertical, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil)

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
        try ProjectFileWriter.write(ProjectFile.oneTab(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        try ProjectFileWriter.write(ProjectFile.oneTab(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        let kept = try Data(contentsOf: prev)

        let retitled = ProjectFile.oneTab(name: "p", savedAt: 3, root: .split(direction: .horizontal, ratio: 0.8, left: leaf("/a/x", "vim"), right: leaf("/b")), nextScrollback: nil)
        #expect(try ProjectFileWriter.write(retitled, to: url, keeping: .onLayoutChange) == .written(rotated: false))
        #expect(try Data(contentsOf: prev) == kept)
        #expect(try ProjectFile.decode(from: Data(contentsOf: url)).firstTab == retitled.firstTab)
    }

    // MARK: Overwrite keeps what it replaced (#965)

    /// The case found on the real app: one pane over one pane is no layout
    /// change, so the autosave rule kept nothing -- and the old cwd and
    /// title were gone while the confirmation said they were kept.
    @Test func overwritingOnePaneWithOnePaneKeepsTheReplacedVersion() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        try ProjectFileWriter.write(ProjectFile.oneTab(name: "g", savedAt: 1, root: leaf("/work/g", "gamma-only"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        let replaced = try Data(contentsOf: url)

        let tab = ProjectFile.oneTab(name: "g", savedAt: 2, root: leaf("/bin", "/bin/sh"), nextScrollback: nil)
        #expect(try ProjectFileWriter.write(tab, to: url, keeping: .always) == .written(rotated: true))
        #expect(try Data(contentsOf: prev) == replaced)
        #expect(try ProjectFile.decode(from: Data(contentsOf: prev)).firstTab == leaf("/work/g", "gamma-only"))
        #expect(try ProjectFile.decode(from: Data(contentsOf: url)).firstTab == tab.firstTab)
    }

    /// **The first write over a format 1 file keeps it as `.prev`**, even
    /// when the project has not changed at all -- the case that otherwise
    /// writes nothing, and would leave the file in the old format for good.
    /// What is kept is the old file's own bytes: the way back for the build
    /// that wrote it, which cannot read what replaces it.
    @Test func aFormat1FileIsKeptWhenItIsFirstWrittenOver() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        let old = Data(#"{"name":"p","saved_at":1,"root":{"kind":"leaf","cwd":"/a"}}"#.utf8)
        try old.write(to: url)
        let same = ProjectFile.oneTab(name: "p", savedAt: 9, root: leaf("/a"), nextScrollback: nil)
        // The control: nothing but the time differs.
        #expect(try ProjectFile.decode(from: old).windows == same.windows)

        #expect(ProjectFileWriter.plan(writing: same, over: old, keeping: .onLayoutChange) == .written(rotated: true))
        #expect(try ProjectFileWriter.write(same, to: url, keeping: .onLayoutChange) == .written(rotated: true))
        #expect(try Data(contentsOf: prev) == old)
        #expect(try ProjectFile.format(of: Data(contentsOf: url)) == ProjectFile.formatVersion)

        // Now in this format: the same save again writes nothing, as before.
        #expect(try ProjectFileWriter.write(same.with(name: "p", savedAt: 10), to: url, keeping: .onLayoutChange) == .unchanged)
        #expect(try Data(contentsOf: prev) == old)
    }

    /// What a save compares is the whole project: a tab in a second window
    /// is as much its layout as the first.
    @Test func whatASaveFindsIsComparedOverEveryTabAndWindow() throws {
        func project(_ windows: [[ProjectNode]], group: String? = "g", savedAt: Int = 1) -> ProjectFile {
            ProjectFile(
                name: "p", savedAt: savedAt, group: group,
                windows: windows.map { ProjectWindow(frame: nil, front: 0, tabs: $0.map(ProjectTab.init)) },
                nextScrollback: nil)
        }
        let was = project([[leaf("/first"), leaf("/second")], [leaf("/other window")]])
        let disk = try was.encoded()
        func plan(_ file: ProjectFile) -> ProjectFileWriter.Outcome {
            ProjectFileWriter.plan(writing: file, over: disk, keeping: .onLayoutChange)
        }

        #expect(plan(project([[leaf("/first"), leaf("/second")], [leaf("/other window")]], savedAt: 2)) == .unchanged)
        // A directory in the second window: a change, not of layout.
        #expect(plan(project([[leaf("/first"), leaf("/second")], [leaf("/elsewhere")]])) == .written(rotated: false))
        // The group alone: a change, not of layout.
        #expect(plan(project([[leaf("/first"), leaf("/second")], [leaf("/other window")]], group: nil)) == .written(rotated: false))
        // A split in the second tab, a tab fewer, a window fewer: layout.
        let split = ProjectNode.split(direction: .vertical, ratio: 0.5, left: leaf("/second"), right: leaf("/x"))
        #expect(plan(project([[leaf("/first"), split], [leaf("/other window")]])) == .written(rotated: true))
        #expect(plan(project([[leaf("/first")], [leaf("/other window")]])) == .written(rotated: true))
        #expect(plan(project([[leaf("/first"), leaf("/second")]])) == .written(rotated: true))

        // A project from a later format is somebody's project: kept.
        let later = Data(#"{"format":4,"name":"p","saved_at":1,"windows":[]}"#.utf8)
        #expect(ProjectFileWriter.plan(writing: was, over: later, keeping: .onLayoutChange) == .written(rotated: true))
    }

    /// The decision on its own, both kinds side by side: they differ only
    /// where the layout did not change.
    @Test func theTwoKindsDifferOnlyWhenTheLayoutStaysTheSame() throws {
        let old = try ProjectFile.oneTab(name: "p", savedAt: 1, root: leaf("/a", "x"), nextScrollback: nil).encoded()
        let retitled = ProjectFile.oneTab(name: "p", savedAt: 2, root: leaf("/a", "y"), nextScrollback: nil)
        let split = ProjectFile.oneTab(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil)
        let same = ProjectFile.oneTab(name: "p", savedAt: 9, root: leaf("/a", "x"), nextScrollback: nil)

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
        try ProjectFileWriter.write(ProjectFile.oneTab(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        let before = try Data(contentsOf: url)
        #expect(try ProjectFileWriter.write(ProjectFile.oneTab(name: "p", savedAt: 2, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange) == .unchanged)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func restoringSwapsAndRestoringAgainUndoes() throws {
        let url = try makeURL()
        let prev = ProjectFileWriter.previousURL(for: url)
        try ProjectFileWriter.write(ProjectFile.oneTab(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
        try ProjectFileWriter.write(ProjectFile.oneTab(name: "p", savedAt: 2, root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a"), right: leaf("/b")), nextScrollback: nil), to: url, keeping: .onLayoutChange)
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
        try ProjectFileWriter.write(ProjectFile.oneTab(name: "p", savedAt: 1, root: leaf("/a"), nextScrollback: nil), to: url, keeping: .onLayoutChange)
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
