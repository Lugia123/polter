import AppKit

/// What a pane being dragged shows over a window's tab strip, and what
/// letting it go there does (task 1557).
///
/// The strip is the system's `NSTabBar`, which does not take our drag type,
/// so nothing about it is told the pane is there. The drag source is told
/// instead: it calls `moved(to:)` as the pointer moves and `ended(at:)` when
/// it lets go, and this finds the strip under the pointer, asks
/// `TabStripDrop` what it means, and draws that in a view laid over the
/// strip that takes no events. **The tab bar is the selected tab's**, so it
/// changes when a tab comes forward; the view follows it.
@MainActor
final class TabStripDragOverlay {
    static let shared = TabStripDragOverlay()

    /// A strip under the pointer, and what the pointer over it means.
    struct Over {
        let tabBar: NSView
        /// The windows of its tab group, in the strip's order.
        let windows: [NSWindow]
        /// Each tab's button, in `tabBar`'s coordinates.
        let buttons: [NSRect]
        let target: TabStripDrop.Target
    }

    /// Whether the pointer is over a strip just now: the drop zones of the
    /// panes stay dark while it is (task 1557 C).
    private(set) var isOverStrip = false

    private let hint = HintView()
    private var dwell = TabStripDrop.Dwell<ObjectIdentifier>()
    private var dragged: Ghostty.SurfaceView?
    private var lastPoint: NSPoint?
    private var timer: Timer?

    // MARK: The drag source's calls

    /// The pointer is at `screenPoint` with `surface` in hand.
    func moved(to screenPoint: NSPoint, surface: Ghostty.SurfaceView) {
        dragged = surface
        lastPoint = screenPoint
        WindowTabChipSlide.held = true
        update()
    }

    /// The drag ended at `screenPoint`; Esc when `cancelled`. Takes the hint
    /// away, and answers the window to insert before or after, when letting
    /// go there makes the pane a new tab.
    func ended(at screenPoint: NSPoint, surface: Ghostty.SurfaceView, cancelled: Bool) -> (neighbor: NSWindow, ordered: NSWindow.OrderingMode)? {
        defer { clear() }
        guard !cancelled, let over = Self.over(screenPoint, surface: surface) else { return nil }
        guard case .insert(let index) = over.target else { return nil }
        if index < over.windows.count {
            return (over.windows[index], .below)
        }
        guard let last = over.windows.last else { return nil }
        return (last, .above)
    }

    /// Esc, or the drag is over: everything this drew goes.
    func clear() {
        timer?.invalidate()
        timer = nil
        dwell = .init()
        dragged = nil
        lastPoint = nil
        isOverStrip = false
        WindowTabChipSlide.held = false
        hint.removeFromSuperview()
        hint.state = .init()
    }

    // MARK: Following the pointer

    private func update() {
        guard let surface = dragged, let point = lastPoint else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let over = Self.over(point, surface: surface) else {
            isOverStrip = false
            _ = dwell.at(nil, now: now)
            hint.removeFromSuperview()
            stopTimer()
            return
        }
        isOverStrip = true

        var forward: NSWindow?
        if case .bringForward(let i) = over.target { forward = over.windows[i] }
        if let ready = dwell.at(forward.map(ObjectIdentifier.init), now: now),
           let window = over.windows.first(where: { ObjectIdentifier($0) == ready }) {
            window.tabGroup?.selectedWindow = window
            // The strip is the new selected tab's from here on.
            DispatchQueue.main.async { [weak self] in self?.update() }
        }

        var state = HintView.State()
        if case .insert(let index) = over.target,
           let x = TabStripDrop.markX(index: index, tabs: over.buttons.map { .init(minX: $0.minX, maxX: $0.maxX) }) {
            let tab = over.buttons[min(index, over.buttons.count - 1)]
            state.mark = NSRect(x: x - 1, y: tab.minY + 4, width: 2, height: max(0, tab.height - 8))
        }
        if let waiting = dwell.tab, let progress = dwell.progress(now: now),
           let i = over.windows.firstIndex(where: { ObjectIdentifier($0) == waiting }) {
            state.hover = over.buttons[i]
            state.progress = progress
        }
        if hint.superview !== over.tabBar {
            hint.removeFromSuperview()
            hint.frame = over.tabBar.bounds
            hint.autoresizingMask = [.width, .height]
            over.tabBar.addSubview(hint, positioned: .above, relativeTo: nil)
        }
        hint.state = state

        if state.progress != nil { startTimer() } else { stopTimer() }
    }

    /// The pointer can rest over a tab: the bar fills and the tab comes
    /// forward without it moving. A drag runs the event-tracking run loop
    /// mode, so the timer is in the common modes.
    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Finding the strip

    /// The strip under `screenPoint`, if there is one, and what the pointer
    /// over it means for `surface`.
    private static func over(_ screenPoint: NSPoint, surface: Ghostty.SurfaceView) -> Over? {
        for window in NSApp.windows where window.isVisible && window is TerminalWindow {
            guard let tabBar = window.tabBarView, !tabBar.isHiddenOrHasHiddenAncestor,
                  let barWindow = tabBar.window else { continue }
            let local = tabBar.convert(barWindow.convertPoint(fromScreen: screenPoint), from: nil)
            guard tabBar.bounds.contains(local) else { continue }
            let windows = window.tabGroup?.windows ?? [window]
            let buttons = tabBar.descendants(withClassName: "NSTabButton")
                .map { tabBar.convert($0.bounds, from: $0) }
                .sorted { $0.minX < $1.minX }
            // Mid-animation the buttons and the windows can disagree; a
            // strip whose tabs cannot be named is no strip.
            guard buttons.count == windows.count, !buttons.isEmpty else { return nil }
            let selected = window.tabGroup?.selectedWindow.flatMap { windows.firstIndex(of: $0) }
            let source = surface.window
            let alone = (source?.windowController as? BaseTerminalController)?.surfaceTree.isSplit == false
                && source.map { windows.contains($0) } == true
            let target = TabStripDrop.target(
                x: local.x,
                tabs: buttons.map { .init(minX: $0.minX, maxX: $0.maxX) },
                selected: selected,
                alone: alone)
            return Over(tabBar: tabBar, windows: windows, buttons: buttons, target: target)
        }
        return nil
    }

    // MARK: The view

    /// Laid over the tab bar; draws, and lets every event through.
    private final class HintView: NSView {
        struct State: Equatable {
            /// The insertion mark: a round-ended accent bar in a gap.
            var mark: NSRect?
            /// The tab being waited on, and how far along the wait is.
            var hover: NSRect?
            var progress: Double?
        }

        var state = State() {
            didSet { if state != oldValue { needsDisplay = true } }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let accent = NSColor.controlAccentColor
            if let hover = state.hover {
                let ground = hover.insetBy(dx: 1, dy: 2)
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: ground, xRadius: 6, yRadius: 6).fill()
                if let progress = state.progress {
                    // Along the tab's bottom edge, clear of the round ends.
                    let inset: CGFloat = 6
                    let full = max(0, ground.width - inset * 2)
                    let y = isFlipped ? ground.maxY - 2 : ground.minY
                    let bar = NSRect(x: ground.minX + inset, y: y, width: full * progress, height: 2)
                    accent.setFill()
                    NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                }
            }
            if let mark = state.mark {
                accent.setFill()
                NSBezierPath(roundedRect: mark, xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}
