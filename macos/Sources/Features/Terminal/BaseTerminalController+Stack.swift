import AppKit
import GhosttyKit

/// Stacks, in a tab: several terminals in one pane, one of them in front
/// (control-room.md, 12.6.2).
///
/// What a stack is and what each change does to the tree is `SplitTree`'s
/// (`stacking`, `showing`, `unstacking`, `removing(member:)`), and which
/// verb is on offer is `PaneStackRules`. Here is only the part that needs
/// a live tab: making the terminal, replacing the tree with undo, and
/// keeping the keyboard off a terminal that has gone behind.
extension BaseTerminalController {
    /// Whether this tab holds stacks at all. The quick terminal does not:
    /// it wears no frames, so there would be no strip to reach them by.
    var holdsStacks: Bool { !(self is QuickTerminalController) }

    /// Open a new terminal in the pane `target` is in, in front.
    @discardableResult
    func stackNewTerminal(
        onto target: Ghostty.SurfaceView,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard holdsStacks, surfaceTree.contains(target) else { return nil }
        guard let ghostty_app = ghostty.app else { return nil }
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        do {
            let newTree = try surfaceTree.stacking(newView, onto: target)
            replaceSurfaceTree(
                newTree, moveFocusTo: newView, moveFocusFrom: focusedSurface,
                undoAction: "Stack Terminal")
        } catch {
            Ghostty.logger.warning("failed to stack a new terminal: \(error, privacy: .public)")
            return nil
        }
        return newView
    }

    /// Bring `view` to the front of its pane. The keyboard follows when
    /// the one going behind had it: focus is never left on a terminal
    /// nobody can see (`TerminalPresence.focus`).
    func showStackMember(_ view: Ghostty.SurfaceView) {
        guard let stack = surfaceTree.stack(of: view), stack.shown != view.id else { return }
        guard let behind = stack.members.first(where: { $0.id == stack.shown }) else { return }
        do {
            let newTree = try surfaceTree.showing(view)
            let focus = TerminalPresence.focus(focusedSurface, afterShowing: view, inPlaceOf: behind)
            replaceSurfaceTree(
                newTree,
                moveFocusTo: focus === view ? view : nil,
                moveFocusFrom: focus === view ? behind : nil,
                undoAction: "Switch Stacked Terminal")
        } catch {
            Ghostty.logger.warning("failed to show a stacked terminal: \(error, privacy: .public)")
        }
    }

    /// Step along the tabs of the pane `view` is in, round the ends.
    func showStackNeighbour(of view: Ghostty.SurfaceView, by step: Int) {
        guard let stack = surfaceTree.stack(of: view),
              let current = stack.members.firstIndex(where: { $0.id == stack.shown }),
              let to = PaneStackRules.neighbour(of: current, count: stack.members.count, by: step)
        else { return }
        showStackMember(stack.members[to])
    }

    /// Take `view` out of its stack into a pane of its own beside it.
    func unstack(_ view: Ghostty.SurfaceView, direction: SplitTree<Ghostty.SurfaceView>.NewDirection = .right) {
        guard surfaceTree.stack(of: view) != nil else { return }
        do {
            let newTree = try surfaceTree.unstacking(view, direction: direction)
            replaceSurfaceTree(
                newTree, moveFocusTo: view, moveFocusFrom: focusedSurface,
                undoAction: "Unstack Terminal")
        } catch {
            Ghostty.logger.warning("failed to unstack a terminal: \(error, privacy: .public)")
        }
    }

    /// Put `view` -- a terminal of this tab, wherever in its pane -- onto
    /// the stack of the pane `target` is in. Its own pane closes behind it
    /// when it was that pane's only terminal; nothing is closed that was
    /// running.
    func stack(_ view: Ghostty.SurfaceView, onto target: Ghostty.SurfaceView) {
        guard holdsStacks, view !== target,
              surfaceTree.contains(view), surfaceTree.contains(target) else { return }
        // Already one pane: there is nothing to move.
        if let stack = surfaceTree.stack(of: target), stack.members.contains(where: { $0 === view }) { return }
        do {
            let without = try surfaceTree.removing(member: view)
            let newTree = try without.stacking(view, onto: target)
            replaceSurfaceTree(
                newTree, moveFocusTo: view, moveFocusFrom: focusedSurface,
                undoAction: "Stack Terminal")
        } catch {
            Ghostty.logger.warning("failed to stack a terminal onto another: \(error, privacy: .public)")
        }
    }

    /// Carry out one of the stack's verbs on the pane the keyboard is in
    /// (or on `view`, when a menu or a tool names one).
    func perform(stack verb: PaneStackRules.Verb, at view: Ghostty.SurfaceView? = nil) {
        guard let view = view ?? focusedSurface, surfaceTree.contains(view) else { return }
        switch verb {
        case .new:
            stackNewTerminal(onto: view)
        case .next:
            showStackNeighbour(of: view, by: 1)
        case .previous:
            showStackNeighbour(of: view, by: -1)
        case .out:
            unstack(view)
        case .ontoNext, .ontoPrevious:
            // The pane after or before this one, in the order the panes
            // are walked by "next split": what this terminal joins.
            guard let shown = surfaceTree.shown(for: view),
                  let node = surfaceTree.root?.node(view: shown),
                  let target = surfaceTree.focusTarget(
                    for: verb == .ontoNext ? .next : .previous, from: node),
                  target !== shown
            else { return }
            stack(view, onto: target)
        }
    }

    /// Whether `verb` has anything to do on the pane `view` is in (the one
    /// the keyboard is in, when none is named).
    func offers(stack verb: PaneStackRules.Verb, at view: Ghostty.SurfaceView? = nil) -> Bool {
        guard let view = view ?? focusedSurface, surfaceTree.contains(view) else { return false }
        return PaneStackRules.offers(
            verb,
            stacked: surfaceTree.stack(of: view) != nil,
            panes: surfaceTree.shownLeaves().count,
            quick: !holdsStacks)
    }

    /// Close `views`, terminals of one stack, together (task 1582: "close
    /// others / to the right / to the left"). **One question for all of
    /// them**: when any has something running, the person is asked once;
    /// then they go without asking again. Closing every one takes the pane
    /// with it, as closing a pane's last terminal always has.
    func polterCloseStacked(_ views: [Ghostty.SurfaceView]) {
        let here = views.filter { surfaceTree.contains($0) }
        guard !here.isEmpty else { return }
        let remove = { [weak self] in
            guard let self else { return }
            var tree = self.surfaceTree
            for view in here where tree.contains(view) {
                ClosedTabs.shared.remember(directory: view.pwd)
                guard let next = try? tree.removing(member: view) else { continue }
                tree = next
            }
            let focus = self.focusedSurface.flatMap { tree.contains($0) ? $0 : nil } ?? tree.shownLeaves().first
            self.replaceSurfaceTree(tree, moveFocusTo: focus, undoAction: "Close Terminals")
        }
        guard here.contains(where: { $0.needsConfirmQuit }) else {
            remove()
            return
        }
        confirmClose(
            messageText: String(localized: "Close Terminal?", comment: "关闭确认框"),
            informativeText: String(localized: "The terminal still has a running process. If you close the terminal the process will be killed.", comment: "关闭确认框")
        ) { remove() }
    }

    /// A terminal let go on the strip of the pane `target` is in, at tab
    /// `index` (task 1582). One of that same stack is moved along it; one
    /// from elsewhere -- this tab or another window's -- joins the stack
    /// there, in front, and leaves where it was the way a dragged pane
    /// always has (`polterLetGo`).
    func polterDrop(_ source: Ghostty.SurfaceView, onStackOf target: Ghostty.SurfaceView, at index: Int) {
        guard holdsStacks, surfaceTree.contains(target) else { return }
        if let stack = surfaceTree.stack(of: target), stack.members.contains(where: { $0 === source }) {
            // Along its own strip. `index` counts the tab itself; where it
            // ends up does not.
            let from = stack.members.firstIndex { $0 === source } ?? 0
            let to = index > from ? index - 1 : index
            guard to != from, let tree = try? surfaceTree.reordering(source, to: to) else { return }
            replaceSurfaceTree(tree, undoAction: "Move Stacked Terminal")
            return
        }
        guard source !== target else { return }
        if surfaceTree.contains(source) {
            guard let without = polterTakingOut(source)?.tree,
                  let tree = try? without.stacking(source, onto: target, at: index) else { return }
            replaceSurfaceTree(tree, moveFocusTo: source, moveFocusFrom: focusedSurface, undoAction: "Stack Terminal")
            return
        }
        guard let from = BaseTerminalController.controller(owning: source), from !== self,
              let tree = try? surfaceTree.stacking(source, onto: target, at: index) else { return }
        from.polterLetGo(source)
        replaceSurfaceTree(tree, moveFocusTo: source, moveFocusFrom: focusedSurface, undoAction: "Stack Terminal")
    }

    // MARK: The menu

    /// The verb a menu item of the Stack submenu stands for; nil for any
    /// other item.
    static func stackVerb(of action: Selector?) -> PaneStackRules.Verb? {
        switch action {
        case #selector(paneStackNew(_:)): return .new
        case #selector(paneStackNext(_:)): return .next
        case #selector(paneStackPrevious(_:)): return .previous
        case #selector(paneStackOut(_:)): return .out
        case #selector(paneStackOntoNext(_:)): return .ontoNext
        case #selector(paneStackOntoPrevious(_:)): return .ontoPrevious
        default: return nil
        }
    }

    @objc func paneStackNew(_ sender: Any?) { perform(stack: .new) }
    @objc func paneStackNext(_ sender: Any?) { perform(stack: .next) }
    @objc func paneStackPrevious(_ sender: Any?) { perform(stack: .previous) }
    @objc func paneStackOut(_ sender: Any?) { perform(stack: .out) }
    @objc func paneStackOntoNext(_ sender: Any?) { perform(stack: .ontoNext) }
    @objc func paneStackOntoPrevious(_ sender: Any?) { perform(stack: .ontoPrevious) }
}
