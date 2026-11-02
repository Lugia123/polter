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
    /// `byPerson` false is a worker the core stacked (task 1797,
    /// `poltergeist_new_stacked`): the keyboard stays where it was
    /// (`TerminalPresence.focus(_:afterStacking:onto:byPerson:)`).
    @discardableResult
    func stackNewTerminal(
        onto target: Ghostty.SurfaceView,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil,
        byPerson: Bool = true
    ) -> Ghostty.SurfaceView? {
        guard holdsStacks, surfaceTree.contains(target) else { return nil }
        guard let ghostty_app = ghostty.app else { return nil }
        // The one in front of that pane now, which goes behind.
        let behind = surfaceTree.shown(for: target) ?? target
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        do {
            let newTree = try surfaceTree.stacking(newView, onto: target)
            let focus = TerminalPresence.focus(focusedSurface, afterStacking: newView, onto: behind, byPerson: byPerson)
            replaceSurfaceTree(
                newTree,
                moveFocusTo: focus === newView ? newView : nil,
                moveFocusFrom: focus === newView ? focusedSurface : nil,
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

    /// `view` -- a terminal of any tab, any window -- moved to where
    /// `target`, a terminal of this tab, is (task 1797, `terminal_stack`):
    /// onto its pane's stack behind, at the end, or into a pane of its own
    /// to the right (`SplitTree.takingIn`). A move: it keeps its surface and
    /// its process, and the pane or tab it leaves closes when empty
    /// (`polterLetGo`). The keyboard stays where it was, except on `view`
    /// itself when it goes behind: then what its new pane shows has it.
    /// The answer is the tool's: applied, or why not.
    func polterMovePane(_ view: Ghostty.SurfaceView, onto target: Ghostty.SurfaceView, splitRight: Bool) -> (applied: Bool, text: String) {
        guard surfaceTree.contains(target) else { return (false, "the terminal it goes to is not in a terminal tab") }
        guard view !== target else { return (false, "a terminal cannot be moved onto itself") }
        guard splitRight || holdsStacks else { return (false, "this window holds no stacks") }
        if !splitRight, let stack = surfaceTree.stack(of: target), stack.members.contains(where: { $0 === view }) {
            return (true, "already in that stack")
        }
        let base: SplitTree<Ghostty.SurfaceView>
        let from: BaseTerminalController?
        if surfaceTree.contains(view) {
            guard let without = polterTakingOut(view)?.tree else { return (false, "it could not be taken out of its pane") }
            base = without
            from = nil
        } else {
            guard let owner = BaseTerminalController.controller(owning: view) else {
                return (false, "the terminal to move is not in a terminal tab")
            }
            base = surfaceTree
            from = owner
        }
        let tree: SplitTree<Ghostty.SurfaceView>
        do {
            tree = try base.takingIn(view, onto: target, splitRight: splitRight)
        } catch {
            return (false, "it could not be put there: \(error)")
        }
        let hadKeyboard = focusedSurface === view || view.window?.firstResponder === view
        from?.polterLetGo(view)
        let shownNow = tree.isShown(view) ? view : tree.shown(for: target)
        replaceSurfaceTree(
            tree,
            moveFocusTo: hadKeyboard ? shownNow : nil,
            moveFocusFrom: nil,
            undoAction: "Move Terminal")
        return (true, splitRight ? "split beside" : "stacked behind")
    }

    // MARK: The menu

    /// The six rows of a Stack submenu, in the order they are put on it: the
    /// verb, the binding action it is the menu form of, and the words.
    ///
    /// **The one table.** Two menus carry these rows -- the menu bar's
    /// (`AppDelegate.stackMenuItems`, which also hands each row the key the
    /// config gives its action) and a terminal's own right-click menu (task
    /// 2661) -- and a second copy of the six titles is a second copy that
    /// drifts: the right-click menu would keep yesterday's words after the
    /// menu bar's were reworded, and nothing would say so. The words here are
    /// the existing ones, unchanged, and the verbs are still
    /// `PaneStackRules.Verb`'s six: this table adds no seventh row.
    ///
    /// Each menu picks its own selectors from the verb
    /// (`menuBarSelector(for:)` / `paneSelector(for:)`), because the two act
    /// on different things -- the menu bar's on the pane the keyboard is in,
    /// a right-click's on the pane under the pointer.
    ///
    /// A stored `let`, not a function: the six rows are a fact about the app
    /// and nothing computes them, and a second copy of them is exactly what
    /// this table exists to prevent. `@MainActor` is spelled out though the
    /// class already infers it from `NSWindowController`, because both
    /// readers are menus.
    @MainActor
    static let stackMenuVerbs: [(verb: PaneStackRules.Verb, action: String, title: String)] = [
        (.new, "pane_stack:new",
         String(localized: "New Terminal in This Pane", comment: "层叠子菜单：在当前这一格里新开一个终端，叠在前面")),
        (.next, "pane_stack:next",
         String(localized: "Next Stacked Terminal", comment: "层叠子菜单：这一叠的下一个")),
        (.previous, "pane_stack:previous",
         String(localized: "Previous Stacked Terminal", comment: "层叠子菜单：这一叠的上一个")),
        (.out, "pane_stack:out",
         String(localized: "Move Terminal Out of Stack", comment: "层叠子菜单：把当前终端从这一叠里拿出来，成为旁边的一格")),
        (.ontoNext, "pane_stack:onto_next",
         String(localized: "Stack onto Next Pane", comment: "层叠子菜单：把当前终端叠到下一格上")),
        (.ontoPrevious, "pane_stack:onto_previous",
         String(localized: "Stack onto Previous Pane", comment: "层叠子菜单：把当前终端叠到上一格上")),
    ]

    /// The selector a menu-bar Stack row fires: the controller's own, which
    /// acts on the pane the keyboard is in.
    ///
    /// A switch over every verb, not a lookup in the table above: a seventh
    /// verb would otherwise get whatever the fallback answered, and the menu
    /// bar would carry a row wired to nothing. Written out, adding one is a
    /// compile error here and in `paneSelector(for:)`.
    static func menuBarSelector(for verb: PaneStackRules.Verb) -> Selector {
        switch verb {
        case .new: return #selector(paneStackNew(_:))
        case .next: return #selector(paneStackNext(_:))
        case .previous: return #selector(paneStackPrevious(_:))
        case .out: return #selector(paneStackOut(_:))
        case .ontoNext: return #selector(paneStackOntoNext(_:))
        case .ontoPrevious: return #selector(paneStackOntoPrevious(_:))
        }
    }

    /// The selector a terminal's own right-click Stack row fires.
    ///
    /// They are `Ghostty.SurfaceView`'s, declared beside that menu
    /// (`SurfaceView_AppKit.swift`, `polterStackMenuItem`): the view is what
    /// answers the right-click, and each action names the terminal it was
    /// opened on as it goes (`perform(stack:at:)`), rather than letting the
    /// row act on whichever pane happens to hold the keyboard.
    static func paneSelector(for verb: PaneStackRules.Verb) -> Selector {
        switch verb {
        case .new: return #selector(Ghostty.SurfaceView.polterStackNew(_:))
        case .next: return #selector(Ghostty.SurfaceView.polterStackNext(_:))
        case .previous: return #selector(Ghostty.SurfaceView.polterStackPrevious(_:))
        case .out: return #selector(Ghostty.SurfaceView.polterStackOut(_:))
        case .ontoNext: return #selector(Ghostty.SurfaceView.polterStackOntoNext(_:))
        case .ontoPrevious: return #selector(Ghostty.SurfaceView.polterStackOntoPrevious(_:))
        }
    }

    /// The verb a menu item of the Stack submenu stands for; nil for any
    /// other item. Read on both menus, and by the menu bar's validation.
    static func stackVerb(of action: Selector?) -> PaneStackRules.Verb? {
        guard let action else { return nil }
        return stackMenuVerbs.first { menuBarSelector(for: $0.verb) == action
            || paneSelector(for: $0.verb) == action }?.verb
    }

    @objc func paneStackNew(_ sender: Any?) { perform(stack: .new) }
    @objc func paneStackNext(_ sender: Any?) { perform(stack: .next) }
    @objc func paneStackPrevious(_ sender: Any?) { perform(stack: .previous) }
    @objc func paneStackOut(_ sender: Any?) { perform(stack: .out) }
    @objc func paneStackOntoNext(_ sender: Any?) { perform(stack: .ontoNext) }
    @objc func paneStackOntoPrevious(_ sender: Any?) { perform(stack: .ontoPrevious) }
}
