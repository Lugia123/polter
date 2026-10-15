import AppKit

/// Moving a whole tab for `terminal_tab_move` (task 1571).
///
/// **The window is moved, not rebuilt.** On this platform a tab is its own
/// window inside a tab group, so moving a tab is taking that window out of
/// one group and adding it to another (or to the same one, at another
/// place). Its controller, its tree and every terminal in it stay exactly
/// what they were: a tab rebuilt elsewhere would be a close and a reopen,
/// which is what tidying by tool is forbidden to do.
extension TerminalController {
    /// Move this tab to `index` in its strip, or in `into`'s strip when that
    /// is another tab's controller. Answers the text the tool reads: on a
    /// refusal, a sentence -- or `{"code","message"}` for a code other than
    /// `Refused` (`PolterArrangePlan.Refusal.wire`).
    func polterMoveTab(to index: Int, into: TerminalController?) -> (applied: Bool, text: String) {
        guard let window else { return (false, "that tab has no window") }

        // The control room is showing one of these terminals: its pane here
        // is a placeholder the person will come back to.
        if let lent = surfaceTree.first(where: { ControlRoomLender.shared.isLent($0) }) {
            let refusal = PolterArrangePlan.Refusal(
                code: "Lent",
                message: "terminal \(PoltergeistLayoutCell.handleString(for: lent)) in that tab is " +
                    "being shown in the control room, and nothing was moved.")
            return (false, refusal.wire)
        }

        let destination = into?.window ?? window
        guard destination.tabbingMode != .disallowed, window.tabbingMode != .disallowed else {
            return (false, "that window does not take tabs")
        }
        let strip = destination.tabGroup?.windows ?? [destination]
        let others = strip.filter { $0 !== window }

        // Nothing else in the strip: it is already where it is asked to be.
        guard !others.isEmpty else { return (true, "{}") }

        let slot = PolterArrangePlan.tabSlot(index: index, othersCount: others.count)
        // Already there: AppKit would take it out and put it back, and the
        // strip would flash for nothing.
        if let at = strip.firstIndex(where: { $0 === window }), at == min(index, strip.count - 1) {
            return (true, "{}")
        }

        // Where it was, to be put back if the new strip will not take it:
        // all or nothing, as for a layout.
        let before = window.tabGroup?.windows ?? [window]
        let wasAt = before.firstIndex(where: { $0 === window }) ?? 0
        let backAnchor: (NSWindow, NSWindow.OrderingMode)? = before.count < 2 ? nil :
            (wasAt > 0 ? (before[wasAt - 1], .above) : (before[1], .below))

        if let group = window.tabGroup, group.windows.count > 1 {
            group.removeWindow(window)
        }
        let anchor = slot.map { others[$0] } ?? others[others.count - 1]
        let ordered: NSWindow.OrderingMode = slot == nil ? .above : .below
        guard anchor.addTabbedWindowSafely(window, ordered: ordered) else {
            if let (back, order) = backAnchor { _ = back.addTabbedWindowSafely(window, ordered: order) }
            return (false, "that window would not take the tab, and it was left where it was")
        }
        anchor.tabGroup?.selectedWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.relabelTabs()
        }
        return (true, "{}")
    }
}
