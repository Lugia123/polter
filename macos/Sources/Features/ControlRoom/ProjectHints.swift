import AppKit
import Combine

/// The line saying a project was made for a group (task 1713, v2 A1), one
/// per group. **One object, two copies on screen**: the control room's
/// right-hand side and the supervisor's own pane draw the same one, so undo
/// or ✕ in either takes both away.
final class ProjectHint: ObservableObject, Identifiable {
    enum State: Equatable {
        /// With its undo.
        case shown
        /// Undone: the line saying so, with ✕ only.
        case undone(String)
    }

    let group: String
    let origin: ProjectLinkPlan.Origin
    @Published private(set) var state: State = .shown
    /// How long it has been seen (`ProjectLinkRules.HintClock`). An undone
    /// line has a clock of its own, started when it was undone.
    private(set) var clock = ProjectLinkRules.HintClock()

    var id: String { group }

    init(group: String, origin: ProjectLinkPlan.Origin) {
        self.group = group
        self.origin = origin
    }

    var text: String { ProjectLinkPlan.hintText(origin, short: false) }
    var shortText: String { ProjectLinkPlan.hintText(origin, short: true) }

    fileprivate func look(at: Double, visible: Bool) { clock.look(at: at, visible: visible) }
    fileprivate func close() { clock.close() }
    fileprivate func undone(_ text: String, at: Double) {
        state = .undone(text)
        clock = ProjectLinkRules.HintClock()
        clock.look(at: at, visible: false)
    }
}

/// Every line standing, by group, and the clock that takes each away.
final class ProjectHints: ObservableObject {
    static let shared = ProjectHints()

    @Published private(set) var hints: [String: ProjectHint] = [:]
    /// Each group's supervisor's terminal, as the last snapshot said: where
    /// the copy in the supervisor's own pane goes. Written by the app.
    @Published var stewards: [String: String] = [:]

    /// The group whose supervisor is in `terminal`, when its line stands.
    func hint(inPaneOf terminal: String?) -> ProjectHint? {
        guard let terminal, let group = stewards.first(where: { $0.value == terminal })?.key else { return nil }
        return hints[group]
    }

    /// What undoing does, in the app (`ProjectLinkDesk`): nil when it was
    /// all done, or why not.
    var undoer: ((String, ProjectLinkPlan.Origin) -> String?)?
    /// Says the line out loud for a screen reader.
    var announce: (String) -> Void = { text in
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    /// Seconds on a clock that only goes forward.
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    private var probes: [(group: String, view: WeakView)] = []
    private var timer: Timer?

    struct WeakView {
        weak var view: NSView?
    }

    /// The line for `group`, if one stands.
    func hint(for group: String) -> ProjectHint? { hints[group] }

    /// A project was made for `group`: the line comes, unless the one
    /// standing is about the same event (`ProjectLinkPlan.replaces`).
    func show(_ origin: ProjectLinkPlan.Origin, for group: String) {
        let standing = hints[group].flatMap { $0.state == .shown ? $0.origin : nil }
        guard ProjectLinkPlan.replaces(origin, standing: standing) else { return }
        let hint = ProjectHint(group: group, origin: origin)
        hint.look(at: now(), visible: false)
        hints[group] = hint
        announce(hint.text)
        startTicking()
    }

    func close(_ group: String) {
        hints[group]?.close()
        hints[group] = nil
    }

    func undo(_ group: String) {
        guard let hint = hints[group], hint.state == .shown else { return }
        let failed = undoer?(group, hint.origin)
        let text = failed.map(ProjectLinkPlan.undoFailedText) ?? ProjectLinkPlan.undoneText(hint.origin)
        hint.undone(text, at: now())
        announce(text)
        objectWillChange.send()
    }

    // MARK: Being seen

    /// A copy of the line is in `view`. Kept weakly; a view that went away
    /// no longer counts.
    func register(_ view: NSView, for group: String) {
        probes.removeAll { $0.view.view == nil || $0.view.view === view }
        probes.append((group, WeakView(view: view)))
    }

    /// Whether any copy of `group`'s line is where the person can see it:
    /// the app active, its window the key one and showing that tab, and the
    /// copy not hidden.
    func seen(_ group: String) -> Bool {
        guard NSApp.isActive else { return false }
        return probes.contains { probe in
            guard probe.group == group, let view = probe.view.view, let window = view.window else { return false }
            let front = window.tabGroup?.selectedWindow ?? window
            return window.isKeyWindow && front === window && window.occlusionState.contains(.visible)
                && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
        }
    }

    /// Look at every line at `at`; `visible` says whether a group's is seen.
    /// A line seen for long enough goes.
    func tick(at: Double, visible: (String) -> Bool) {
        for (group, hint) in hints {
            hint.look(at: at, visible: visible(group))
            if hint.clock.gone { hints[group] = nil }
        }
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick(at: self.now(), visible: self.seen)
            if self.hints.isEmpty {
                self.timer?.invalidate()
                self.timer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
