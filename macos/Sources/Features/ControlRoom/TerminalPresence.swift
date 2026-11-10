import Foundation

/// A terminal that is in its tab's tree and not in front of the person
/// there: what its own tab's controller says about it to the core, and who
/// says it instead (control-room.md, 12.6.2, "可见性与借出合成一个规则").
///
/// There is one such kind today -- lent to the control room -- and stacking
/// adds a second: behind another terminal in the same pane. The controller
/// wants the same thing of both (do not report its focus or its visibility
/// as though it were on screen here), and what differs is only who reports
/// in its place. One rule for the two, so that the second kind is not a
/// second `if … { continue }` written beside the first.
///
/// **Nothing calls this yet.** It is the table, written down and tested,
/// ahead of the step that wires it in.
enum TerminalPresence {
    /// What the tab's own controller reports for one of its terminals.
    enum OwnTabReports: Equatable {
        /// As it always has: visible when the window is, focused when it
        /// is the focused pane.
        case asShown
        /// Nothing. The control room has it and reports for it.
        case nothing
        /// Not visible and not focused -- said once, when it goes behind.
        case hidden
    }

    /// `shown` is whether the terminal is the one its pane shows; `lent`
    /// is whether the control room has borrowed it.
    ///
    /// **Lent wins, wherever it sits in its pane**: the control room is
    /// showing it, so "hidden" from here would be a lie about a terminal
    /// the person is looking at.
    static func ownTabReports(shown: Bool, lent: Bool) -> OwnTabReports {
        if lent { return .nothing }
        return shown ? .asShown : .hidden
    }

    /// Whether the terminal's place in its own tab draws the "it is in the
    /// control room" placeholder. Only where it would otherwise be drawn:
    /// a terminal borrowed from behind another leaves no gap to explain.
    static func drawsLentPlaceholder(shown: Bool, lent: Bool) -> Bool {
        lent && shown
    }

    /// The focused terminal after a pane changes which of its terminals it
    /// shows. **Focus is never left on one that is behind**: if the one
    /// going behind had it, the one coming forward takes it. Any other
    /// focus stands.
    static func focus<ID: Equatable>(_ focused: ID?, afterShowing front: ID, inPlaceOf behind: ID) -> ID? {
        focused == behind ? front : focused
    }

    /// The focused terminal after a new one is stacked in front of
    /// `behind`. The person's own "new" -- a key, a menu, the stack's "+"
    /// -- takes the keyboard there. **A worker the core stacked (task 1797)
    /// takes it from nobody**: not from the supervisor, not from where the
    /// person is typing. Only `behind` itself loses it, because it is going
    /// behind, and then to the new terminal in the same pane.
    static func focus<ID: Equatable>(_ focused: ID?, afterStacking new: ID, onto behind: ID, byPerson: Bool) -> ID? {
        byPerson ? new : focus(focused, afterShowing: new, inPlaceOf: behind)
    }

    /// The focused terminal after its tab's tree changed: **the same one
    /// when the tree still holds it**, and the first one the tree shows
    /// when it does not. Nothing focused stays nothing focused -- a tree
    /// change is not a reason to give somebody the keyboard.
    ///
    /// The rule this completes is the file's: **focus is never left on a
    /// terminal nobody can see.** That was written for one that goes
    /// behind another; a terminal that is *gone* is the other half, and it
    /// was missing (task 3141). The controller's `focusedSurface` is a
    /// strong reference to the last terminal that had focus, and losing
    /// focus deliberately does not clear it -- `TerminalView` keeps "the
    /// last non-nil value", so the field only moves when focus lands on
    /// *another* surface. A pane that was clicked and then closed
    /// therefore went on being the controller's focused surface, and the
    /// whole terminal went on being alive with it: its view, its surface,
    /// its pty, its shell. That is issue #25, whose symptom is a closed
    /// pane's shell surviving until "the next click in the window" --
    /// which is the next focus change, and the only thing that ever moved
    /// the field.
    ///
    /// Not inverted: a tree change that leaves the focused terminal in
    /// place must leave it alone, or closing any pane would drop the
    /// keyboard.
    static func focusAfterTreeChange<ID: Equatable>(
        _ focused: ID?,
        stillIn tree: (ID) -> Bool,
        shown: [ID],
    ) -> ID? {
        guard let focused else { return nil }
        if tree(focused) { return focused }
        return shown.first
    }
}
