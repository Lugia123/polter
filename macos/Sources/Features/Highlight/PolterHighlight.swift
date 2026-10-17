import AppKit
import GhosttyKit

/// `terminal_highlight` on macOS (task 1689): bring a terminal in front of
/// the person and make its pane stand out until they look, the time is up,
/// or another one is lit.
///
/// **One at a time, and all of it here.** The core keeps no state
/// (`apprt.action.PolterHighlight`): which terminal is lit, the countdown,
/// the key that is swallowed and why it ended live in this one object, and
/// the line that says why it ended is written from here. What the views
/// draw is `PolterHighlightShown`, which this keeps in step.
///
/// The steps are the design's (`highlight-v1/README.md`, "点亮时做哪几步"):
/// find the window -- the control room's, for a terminal lent to it --,
/// bring it back, select its tab, bring it to the front of its stack, bring
/// the window forward and read back where it ended up, then start.
@MainActor
final class PolterHighlight {
    static let shared = PolterHighlight()

    typealias Rules = PolterHighlightRules

    /// The terminal that is lit, and what is needed to end it.
    private struct Lit {
        weak var surface: Ghostty.SurfaceView?
        weak var window: NSWindow?
        let id: String
        let seconds: Double
        let lent: Bool
    }

    private var lit: Lit?
    private var monitor: Any?
    private var deadline: Timer?
    private var watch: Timer?
    private var deminiaturized: NSObjectProtocol?
    private var tabWindow: TerminalWindow?

    private var shown: PolterHighlightShown { .shared }

    /// The action's answer: `applied` with its JSON, or a refusal.
    struct Answer {
        let applied: Bool
        let text: String
    }

    func perform(surface: Ghostty.SurfaceView, seconds: UInt32, label: String?) -> Answer {
        PolterHighlightShown.terminalOf = { ($0 as? Ghostty.SurfaceView).flatMap(ControlRoomLender.terminal(of:)) }
        let id = ControlRoomLender.terminal(of: surface) ?? "0x0000000000000000"

        if seconds == 0 {
            guard let lit, lit.surface === surface else {
                return Answer(applied: true, text: Rules.endedJSON(false))
            }
            end(.cancelled)
            return Answer(applied: true, text: Rules.endedJSON(true))
        }

        // 1. The window. A terminal lent to the control room is shown
        //    there, so that is the window (the same test `present_terminal`
        //    makes).
        let lent = ControlRoomLender.shared.isLent(surface)
        let controller = BaseTerminalController.controller(owning: surface)
        let window: NSWindow? = lent ? surface.window : controller?.window
        guard let window, controller != nil || lent else {
            return Answer(applied: false, text: Rules.refusalJSON(
                code: "NotShown", message: "that terminal is not in any window"))
        }
        // A quick terminal that is put away is not popped out for the caller.
        if controller is QuickTerminalController, !window.isVisible {
            return Answer(applied: false, text: Rules.refusalJSON(
                code: "NotShown", message: "that terminal is in the quick terminal, which is hidden"))
        }

        // One at a time. The same terminal again starts its countdown again
        // and replaces nothing.
        var replaced: UInt64 = 0
        if let old = lit {
            if old.surface !== surface, let gone = old.surface {
                replaced = PoltergeistLayoutCell.surfaceHandle(for: gone).map(UInt64.init) ?? 0
            }
            end(old.surface === surface ? .restarted : .replaced)
        }

        let keyBefore = NSApp.keyWindow
        let wasMinimized = window.isMiniaturized
        let wasHidden = NSApp.isHidden
        var switched = Rules.Switched()
        let inGroup = { (w: NSWindow?) -> Bool in
            guard let w else { return false }
            return w === window || (window.tabGroup?.windows.contains(w) ?? false)
        }
        switched.window = wasMinimized || wasHidden || !inGroup(keyBefore)
        if let group = window.tabGroup, let selected = group.selectedWindow, selected !== window {
            switched.tab = true
        }

        // 2. Bring it back.
        if wasHidden { NSApp.unhide(nil) }
        if wasMinimized { window.deminiaturize(nil) }

        // 4. Its place in a stack.
        if !lent, let controller, let stack = controller.surfaceTree.stack(of: surface), stack.shown != surface.id {
            controller.showStackMember(surface)
            switched.stack = true
        }

        // 3 and 5. Selecting the tab is bringing its window forward: on this
        // platform a tab is a window in a tab group. The window is not
        // moved to this Space -- that would change the person's layout --
        // so on another Space it is the system's to switch, or not.
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: false)
            }
        }

        // The keyboard: left where it was within one tab; on the lit pane
        // when its tab or window had to be brought.
        if switched.tab || switched.window, !lent {
            Ghostty.moveFocus(to: surface)
        }

        let waiting = wasMinimized && window.isMiniaturized
        let front = Rules.front(
            appActive: NSApp.isActive,
            windowIsKey: window.isKeyWindow,
            onActiveSpace: window.isOnActiveSpace,
            wasMinimized: wasMinimized,
            waitingForWindow: waiting)
        if front == .refused, !NSApp.isActive {
            // Once, not until it is answered.
            NSApp.requestUserAttention(.informationalRequest)
        }

        // 6. Draw, and start counting -- once the window is back, so the
        //    countdown is not spent on its animation.
        lit = Lit(surface: surface, window: window, id: id, seconds: Double(seconds), lent: lent)
        shown.begin(
            id: id, window: window, label: label, title: surface.title,
            seconds: Double(seconds), started: waiting ? nil : Date())
        installMonitor()
        startWatching()
        if waiting {
            deminiaturized = NotificationCenter.default.addObserver(
                forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowCameBack() }
            }
        } else {
            startCountdown()
        }
        showOnTab()

        Ghostty.logger.info(
            "[highlight] start id=\(id, privacy: .public) seconds=\(seconds) window=\(switched.window) tab=\(switched.tab) stack=\(switched.stack) front=\(front.rawValue, privacy: .public) timer=\(waiting ? "waiting" : "running", privacy: .public) lent=\(lent) replaced=\(replaced)")

        return Answer(applied: true, text: Rules.shownJSON(
            switched: switched, front: front, timerRunning: !waiting, replaced: replaced))
    }

    /// A minimised window is back: what `front` could not say yet is read
    /// now, into the log, and the countdown starts.
    private func windowCameBack() {
        removeDeminiaturizeObserver()
        guard let lit, let window = lit.window else { return }
        let front = Rules.front(
            appActive: NSApp.isActive, windowIsKey: window.isKeyWindow,
            onActiveSpace: window.isOnActiveSpace, wasMinimized: true, waitingForWindow: false)
        Ghostty.logger.info("[highlight] window back id=\(lit.id, privacy: .public) front=\(front.rawValue, privacy: .public)")
        shown.started = Date()
        startCountdown()
    }

    // MARK: Ending

    /// Why it ends, with one more than the log has words for: lighting the
    /// same terminal again ends nothing the person can see.
    private enum Ending {
        case reason(Rules.Reason)
        case restarted

        static let timeout = Ending.reason(.timeout)
        static let key = Ending.reason(.key)
        static let click = Ending.reason(.click)
        static let replaced = Ending.reason(.replaced)
        static let cancelled = Ending.reason(.cancelled)
        static let closed = Ending.reason(.closed)
    }

    private func end(_ ending: Ending) {
        guard let ended = lit else { return }
        lit = nil
        removeMonitor()
        deadline?.invalidate()
        deadline = nil
        watch?.invalidate()
        watch = nil
        removeDeminiaturizeObserver()
        tabWindow?.polterHighlightTab(false)
        tabWindow = nil

        switch ending {
        case .restarted:
            shown.clear(fading: false)
        case .reason(let reason):
            shown.clear(fading: reason == .timeout)
            Ghostty.logger.info("[highlight] end id=\(ended.id, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        }
    }

    private func startCountdown() {
        guard let lit else { return }
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: lit.seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.timeout) }
        }
    }

    /// The terminal closing or being taken to another window ends it.
    /// Looked at four times a second: no notification says both.
    private func startWatching() {
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let lit else { return }
        guard let surface = lit.surface, let window = lit.window, surface.window === window else {
            end(.closed)
            return
        }
        if !lit.lent, BaseTerminalController.controller(owning: surface) == nil {
            end(.closed)
            return
        }
        // A tab bar is rebuilt when tabs come and go; put the tab's
        // breathing back on whichever button is its own now.
        tabWindow?.polterHighlightTab(true)
    }

    // MARK: The first key, and clicks

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Not `self?.handle(event) ?? event`: nil from `handle` is the
            // swallowed key, and `??` would hand it straight back.
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Only events in the lit window end it; anywhere else -- another tab
    /// of its group included, which is another window -- they are none of
    /// this. A plain key ends it and is swallowed; one with ⌘ or ⌃ goes on
    /// and ends nothing (`Rules.key`). A click on the panes ends it and
    /// goes where it was going; one on the tab bar ends nothing
    /// (`Rules.clickEnds`).
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let lit, let window = lit.window, event.window === window else { return event }
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags
            switch Rules.key(command: flags.contains(.command), control: flags.contains(.control)) {
            case .swallow:
                end(.key)
                return nil
            case .pass:
                return event
            }
        default:
            if Rules.clickEnds(at: event.locationInWindow, paneArea: window.contentLayoutRect) {
                end(.click)
            }
            return event
        }
    }

    private func removeDeminiaturizeObserver() {
        if let deminiaturized { NotificationCenter.default.removeObserver(deminiaturized) }
        deminiaturized = nil
    }

    // MARK: The tab

    /// The lit terminal's own tab breathes, so it can be found from another
    /// one. A lent terminal's is the control room's, which has no window tab.
    private func showOnTab() {
        guard let lit, !lit.lent, let window = lit.window as? TerminalWindow else { return }
        tabWindow = window
        window.polterHighlightTab(true)
    }
}
