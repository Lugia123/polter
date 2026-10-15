import AppKit
import Combine

/// Which pane a window tab being dragged is over, and on which side: what
/// `TerminalSplitLeaf` draws, the same way it draws a pane being dragged.
final class TabIntoPaneOffer: ObservableObject {
    static let shared = TabIntoPaneOffer()

    struct Offer: Equatable {
        /// The pane's terminal (the one it shows).
        let pane: UUID
        let zone: TerminalSplitDropZone
        let refusal: TabIntoPane.Refusal?
    }

    @Published fileprivate(set) var offer: Offer?
}

/// Follows a window tab while AppKit drags it, and when it is let go over
/// a pane, puts every terminal of it into a new pane there (`TabIntoPane`
/// says why it is done from the side).
final class TabIntoPaneFollower {
    static let shared = TabIntoPaneFollower()

    private struct Target {
        let controller: BaseTerminalController
        let pane: Ghostty.SurfaceView
        let zone: TerminalSplitDropZone
    }

    private var monitor: Any?
    private var timer: Timer?
    /// The window whose tab is being dragged, and how many tabs its group
    /// had: one fewer means AppKit has torn it off.
    private var dragged: TerminalWindow?
    private var groupCount = 0
    private var refusal: TabIntoPane.Refusal?
    private var target: Target?
    private var ticksSinceRelease: Int?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.mouseDown(event)
            return event
        }
    }

    private func mouseDown(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard let window = event.window,
              let hit = window.tabButtonHit(atScreenPoint: point),
              let group = window.tabGroup,
              hit.index < group.windows.count,
              let tab = group.windows[hit.index] as? TerminalWindow,
              tab.windowController is BaseTerminalController else { return }

        stop()
        dragged = tab
        groupCount = group.windows.count

        // AppKit's drag runs its own loop in the event-tracking mode; a
        // timer in the common modes still fires there.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let dragged else { return stop() }

        if NSEvent.pressedMouseButtons & 1 != 0 {
            // Asked every tick, not once on the press: pressing a tab in the
            // control room's own window selects it, the control room goes
            // behind, and what it had lent goes home (measured).
            refusal = TabIntoPane.refusal(tabHasLentTerminal: (dragged.windowController as? BaseTerminalController)?
                .surfaceTree.contains { ControlRoomLender.shared.isLent($0) } ?? false)
            target = paneUnder(NSEvent.mouseLocation)
            dragged.heldForTabDrop = TabIntoPane.holdsWindow(overPane: target != nil, refusal: refusal)
            let offer = target.map { TabIntoPaneOffer.Offer(pane: $0.pane.id, zone: $0.zone, refusal: refusal) }
            if TabIntoPaneOffer.shared.offer != offer {
                TabIntoPaneOffer.shared.offer = offer
            }
            return
        }

        if ticksSinceRelease == nil {
            TabIntoPaneOffer.shared.offer = nil
        }
        let ticks = (ticksSinceRelease ?? -1) + 1
        ticksSinceRelease = ticks
        let tornOff = (dragged.tabGroup?.windows.count ?? 1) < groupCount

        switch TabIntoPane.afterRelease(
            goingIntoPane: dragged.heldForTabDrop, tornOff: tornOff, ticksSinceRelease: ticks) {
        case .wait:
            return
        case .letGo:
            dragged.heldForTabDrop = false
        case .drop:
            if let target, let source = dragged.windowController as? BaseTerminalController {
                source.giveTerminals(to: target.controller, beside: target.pane, zone: target.zone)
            } else {
                dragged.heldForTabDrop = false
            }
        }
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        dragged = nil
        target = nil
        refusal = nil
        ticksSinceRelease = nil
        if TabIntoPaneOffer.shared.offer != nil {
            TabIntoPaneOffer.shared.offer = nil
        }
    }

    /// The pane under `point` (screen coordinates) and the side of it.
    private func paneUnder(_ point: NSPoint) -> Target? {
        // Not `NSWindow.windowNumber(at:)`: what is under the pointer is
        // AppKit's picture of the tab being dragged. The frontmost terminal
        // window there, and of a tab group the tab on show.
        guard let window = NSApp.orderedWindows.first(where: { window in
            window !== dragged && window.isVisible && !window.isMiniaturized
                && window.frame.contains(point)
                && window.windowController is BaseTerminalController
                && (window.tabGroup == nil || window.tabGroup?.selectedWindow === window)
        }), let controller = window.windowController as? BaseTerminalController else { return nil }

        let panes = (controller.surfaceTree.zoomed?.shownLeaves() ?? controller.surfaceTree.shownLeaves())
        for pane in panes where pane.window === window {
            let rect = window.convertToScreen(pane.convert(pane.bounds, to: nil))
            guard rect.contains(point) else { continue }
            // The zone is worked out from the top-left, as SwiftUI gives it.
            let local = CGPoint(x: point.x - rect.minX, y: rect.maxY - point.y)
            return Target(controller: controller, pane: pane, zone: .calculate(at: local, in: rect.size))
        }
        return nil
    }
}

extension BaseTerminalController {
    /// Every terminal of this tab into one new pane beside `pane` in
    /// `target`, on the `zone` side: stacked in this tab's order, showing
    /// the one this tab had the keyboard on. This tab then closes.
    func giveTerminals(to target: BaseTerminalController, beside pane: Ghostty.SurfaceView, zone: TerminalSplitDropZone) {
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        guard let shown = focusedSurface.flatMap({ surfaceTree.shown(for: $0) }) ?? surfaceTree.shownLeaves().first else {
            return
        }
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try target.surfaceTree.inserting(tab: surfaceTree, showing: shown, at: pane, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to put a tab into a pane: \(error, privacy: .public)")
            (window as? TerminalWindow)?.heldForTabDrop = false
            return
        }

        // As a pane dropped from another window (`splitDidDrop`): one undo
        // group, this tab emptied first, then the target given the tree.
        target.undoManager?.beginUndoGrouping()
        target.undoManager?.setActionName("Move Tab")
        defer { target.undoManager?.endUndoGrouping() }

        replaceSurfaceTree(.init())
        target.replaceSurfaceTree(newTree, moveFocusTo: shown, moveFocusFrom: target.focusedSurface)
        target.window?.makeKeyAndOrderFront(nil)
    }
}
