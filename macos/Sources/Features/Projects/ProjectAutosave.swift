import Foundation

// The parts of project autosave that don't need a live terminal: writing a
// project file while keeping one previous generation, coalescing bursts of
// changes into one write, and making sure one project has one writer. See
// `dev-docs/project-scrollback.md` 3.5.5-3.5.6 for why each exists.
//
// Foundation-only on purpose, so every rule here can be exercised without a
// `ghostty_app_t`. The AppKit half -- which events trigger a save, and where
// a tab's binding is kept across restarts -- is in
// `TerminalController+Projects.swift`.

// MARK: - Writing with one previous generation

enum ProjectFileWriter {
    enum Outcome: Equatable {
        /// Nothing but `saved_at` would have changed, so nothing was written.
        case unchanged
        /// Written. `rotated` says whether the old file became `.prev`.
        case written(rotated: Bool)
    }

    /// `<name>.json.prev` beside `<name>.json`. Its extension is `prev`, so
    /// `ProjectStore.list()` (which only takes `.json`) never lists it.
    static func previousURL(for url: URL) -> URL {
        url.appendingPathExtension("prev")
    }

    /// When the version on disk is kept as `.prev`. **No default, on
    /// purpose**: the two kinds of write look the same at the call, and the
    /// one that was wrong -- "Overwrite with Current Tab" -- went through the
    /// autosave rule because it never had to say which it was (#965).
    enum Keeping: Equatable {
        /// Autosave, and every save that follows a tab around as it
        /// changes: keep the old version only when the *layout* changed.
        case onLayoutChange
        /// Replacing a project with something else ("Overwrite with Current
        /// Tab", settings.md §6.2): always keep what was replaced, whatever
        /// its shape. One pane over one pane otherwise lost the old cwd and
        /// title outright, while the confirmation said they were kept.
        case always
    }

    /// What writing `file` over `existing` (the bytes on disk, nil when
    /// there is no file) does, decided without touching the disk.
    ///
    /// Autosave turns a mistake into something permanent: close five panes
    /// by accident and the project no longer has them. `.prev` is the way
    /// back, and it only works if it still holds the layout from before the
    /// mistake. So autosave rotates on a layout change (a pane added or
    /// removed, a split's direction changed) and **not** on the changes that
    /// follow a person around all day -- a title, a cwd, a divider dragged a
    /// few points. Rotating on those would replace the good layout with the
    /// bad one within seconds of the mistake, the next time a shell set its
    /// title. A replacement is one deliberate act, so it always rotates.
    ///
    /// A file that's identical apart from `saved_at` isn't written at all,
    /// by either kind: every write would otherwise change `saved_at`, so
    /// every write would look like a change -- and there is nothing being
    /// replaced to keep.
    ///
    /// An existing file that doesn't decode is always rotated rather than
    /// overwritten -- it is somebody's project, and this can't tell whose
    /// layout it was.
    static func plan(writing file: ProjectFile, over existing: Data?, keeping: Keeping) -> Outcome {
        guard let existing else { return .written(rotated: false) }
        guard let old = try? ProjectFile.decode(from: existing) else { return .written(rotated: true) }
        if old.name == file.name && old.root == file.root && old.nextScrollback == file.nextScrollback {
            return .unchanged
        }
        switch keeping {
        case .always: return .written(rotated: true)
        case .onLayoutChange: return .written(rotated: old.root?.layout != file.root?.layout)
        }
    }

    /// Write `file` to `url`, keeping what was there as `.prev` as `plan`
    /// decides.
    @discardableResult
    static func write(_ file: ProjectFile, to url: URL, keeping: Keeping) throws -> Outcome {
        let fm = FileManager.default
        let outcome = plan(writing: file, over: try? Data(contentsOf: url), keeping: keeping)
        guard case .written(let rotate) = outcome else { return outcome }

        if rotate {
            let prev = previousURL(for: url)
            if fm.fileExists(atPath: prev.path) {
                _ = try fm.replaceItemAt(prev, withItemAt: copyToTemporary(url))
            } else {
                try fm.copyItem(at: url, to: prev)
            }
        }

        try file.encoded().write(to: url, options: .atomic)
        return outcome
    }

    /// Swap the project at `url` with its `.prev`, so that restoring the
    /// previous version is itself undoable by restoring again. Throws if
    /// there is no `.prev`.
    static func restorePrevious(at url: URL) throws {
        let fm = FileManager.default
        let prev = previousURL(for: url)
        guard fm.fileExists(atPath: prev.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: prev.path])
        }
        guard fm.fileExists(atPath: url.path) else {
            try fm.moveItem(at: prev, to: url)
            return
        }

        let current = try copyToTemporary(url)
        _ = try fm.replaceItemAt(url, withItemAt: prev)
        try fm.moveItem(at: current, to: prev)
    }

    private static func copyToTemporary(_ url: URL) throws -> URL {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: url, to: temporary)
        return temporary
    }
}

extension ProjectNode {
    /// What a mistake changes and an ordinary day doesn't -- see
    /// `ProjectFileWriter.write`. The tree's shape and split directions;
    /// not ratios, cwds, titles, or anything captured per pane.
    indirect enum Layout: Equatable {
        case pane
        case split(Direction, Layout, Layout)
    }

    var layout: Layout {
        switch self {
        case .leaf: return .pane
        case .split(let direction, _, let left, let right):
            return .split(direction, left.layout, right.layout)
        }
    }
}

// MARK: - Coalescing

/// Something that can run a closure later and cancel it -- a seam so the
/// debouncer can be driven by a clock a test controls.
protocol ProjectAutosaveScheduler {
    associatedtype Token
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> Token
    func cancel(_ token: Token)
}

/// `DispatchQueue.main`, the real clock.
struct MainQueueScheduler: ProjectAutosaveScheduler {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    func cancel(_ token: DispatchWorkItem) {
        token.cancel()
    }
}

/// Runs `action` once, `delay` after the last `poke()` of a burst.
///
/// Dragging a split divider changes the tree on every mouse-moved event;
/// without this, each of those is a file write and -- worse -- each is a
/// chance for `.prev` to be taken from the middle of a drag.
final class ProjectAutosaveDebouncer<Scheduler: ProjectAutosaveScheduler> {
    let delay: TimeInterval
    private let scheduler: Scheduler
    private let action: () -> Void
    private var pending: Scheduler.Token?

    init(delay: TimeInterval = 1.0, scheduler: Scheduler, action: @escaping () -> Void) {
        self.delay = delay
        self.scheduler = scheduler
        self.action = action
    }

    var isPending: Bool { pending != nil }

    /// Something changed: (re)start the wait.
    func poke() {
        if let pending { scheduler.cancel(pending) }
        pending = scheduler.schedule(after: delay) { [weak self] in
            self?.pending = nil
            self?.action()
        }
    }

    /// Run a pending write now instead of later -- for when the thing
    /// being saved is about to stop existing. Does nothing if none is
    /// pending.
    func flush() {
        guard let pending else { return }
        scheduler.cancel(pending)
        self.pending = nil
        action()
    }

    /// Drop a pending write without running it.
    func cancel() {
        guard let pending else { return }
        scheduler.cancel(pending)
        self.pending = nil
    }
}

// MARK: - One writer per project

/// A live thing a project can be bound to; its title is how a refusal
/// says who holds the project.
protocol ProjectBindingHolder: AnyObject {
    var projectBindingTitle: String { get }
}

/// Which live owner (a tab) each project is bound to.
///
/// Two tabs bound to one project would both autosave into one file, and
/// the failure of that is silent: each overwrites the other, and whichever
/// wrote last is the project. So a second binding is refused, and the
/// refusal names who holds it.
///
/// Keyed by the project *file*, not the name: two names that sanitize to
/// the same filename are the same project on disk (see `ProjectStore.Entry`).
/// Owners are held weakly, so an owner that went away without releasing
/// (a crash of that code path, a leak fixed later) doesn't lock its
/// project forever.
final class ProjectBindingRegistry {
    enum Claim {
        case claimed
        case heldBy(AnyObject)
    }

    private final class Weak {
        weak var owner: AnyObject?
        init(_ owner: AnyObject) { self.owner = owner }
    }

    private var owners: [String: Weak] = [:]

    /// Bind `key` to `owner`. Claiming a key the owner already holds is a
    /// no-op success.
    func claim(_ key: String, for owner: AnyObject) -> Claim {
        if let current = owners[key]?.owner, current !== owner {
            return .heldBy(current)
        }
        owners[key] = Weak(owner)
        return .claimed
    }

    /// Unbind `key`, but only from `owner` -- releasing something another
    /// owner holds is a no-op, so a stale release can't free a live claim.
    func release(_ key: String, for owner: AnyObject) {
        guard owners[key]?.owner === owner else { return }
        owners[key] = nil
    }

    func owner(of key: String) -> AnyObject? {
        owners[key]?.owner
    }

    /// The project under `old` is now under `new` (it was renamed): whoever
    /// held it holds it there. Nothing held `new` -- a rename onto a
    /// project that exists is refused before it gets here.
    func move(_ old: String, to new: String) {
        guard old != new, let entry = owners.removeValue(forKey: old) else { return }
        owners[new] = entry
    }
}

/// A binding holder that has to be told when its project is renamed under
/// it (settings.md §6.2: "the binding follows the new name"). Separate from
/// `ProjectBindingHolder` so that a holder that is only ever asked its title
/// need not answer this.
@MainActor
protocol ProjectMoveFollower: AnyObject {
    /// About to move: land any pending write where the project is now, and
    /// stop writing to it.
    func projectWillMove()
    /// Moved: the project is `name` now, its key `key`, its snapshots in
    /// `scrollback`. Panes that were journaling under `oldKey` go on
    /// journaling the same snapshot names there.
    func projectDidMove(to name: String, oldKey: String, key: String, scrollback: URL)
}
