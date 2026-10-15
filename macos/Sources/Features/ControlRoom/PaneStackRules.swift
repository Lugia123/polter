import Foundation

/// What a pane that holds a stack draws, worked out from the tree's stack
/// and the core's snapshot -- and the few choices about a stack that are
/// the person's to change (control-room.md, 12.6.2).
///
/// No view and no terminal in here: the split view hands in which terminal
/// each member is and what its own view calls it, and gets back the
/// `PaneStack` the strip draws. So this is tested without the app.
enum PaneStackRules {
    /// The four things about a stack's look the person has not ruled on.
    /// **One place, so that ruling on one is changing one line** (task
    /// 1493; each is 暂定, with the other candidate beside it).
    enum Choices {
        /// An ordinary terminal that holds a stack shows the strip too --
        /// even alone in its tab, and even with `poltergeist-pane-frames`
        /// off: a stack with no strip is terminals nobody can reach.
        /// (The other candidate, no strip on an ordinary terminal, is not
        /// one that can be chosen for that reason; what can be is
        /// `plainStyle`.)
        static let plainStyle: PaneStack.PlainStyle = .band
        /// The frame round a stack is the frame of the member in front,
        /// so it changes as the tabs are switched. The other candidate:
        /// the frame of the first member, whoever is in front.
        static let frameFollowsShown = true
    }

    /// One terminal of a pane's stack, as the split view knows it.
    struct Member: Equatable {
        /// The core's id for the terminal; nil while it has none.
        var terminal: String?
        /// What its own view calls it, for a terminal the snapshot does
        /// not list.
        var ownName: String
    }

    /// What a pane holding `members`, showing `shown`, draws.
    ///
    /// Every member's name, glyph and frame are the core's words for that
    /// terminal (`PaneFrame.drawn`, asked as for a pane that is not alone:
    /// in a stack every member has a name to show). `urgent` is the core's
    /// own order of who is waiting -- `pulses`, most pressing first --
    /// kept to the terminals of this stack. **Nothing here ranks a glyph**:
    /// it is a walk down the core's list and a test of membership.
    static func stack(
        members: [Member], shown: Int,
        terminals: [ControlRoomSnapshot.Terminal]?, pulses: [String]
    ) -> PaneStack {
        let place = PaneFrame.Place(enabled: true, quickTerminal: false, alone: false)
        let drawn: [PaneStack.Member] = members.map { member in
            let listed = member.terminal.flatMap { id in terminals?.first { $0.id == id } }
            // Never nil at this place: an ordinary terminal that is not
            // alone has a name.
            let frame = PaneFrame.drawn(terminal: member.terminal, ownName: member.ownName, at: place, in: terminals)
            // The pair the frame's title draws, from the same values
            // (task 1582): a held terminal says held here as it does there.
            let title = frame?.title
            return PaneStack.Member(
                name: title?.name ?? member.ownName,
                shown: title?.shown ?? listed.map { .init($0.shown) } ?? .none,
                wears: frame?.wears ?? .plain,
                role: title?.roleWord(in: frame?.wears ?? .plain))
        }
        let urgent: [Int] = pulses.compactMap { waiting in
            members.firstIndex { $0.terminal == waiting }
        }
        return PaneStack(
            members: drawn,
            current: members.indices.contains(shown) ? shown : 0,
            plainStyle: Choices.plainStyle,
            urgent: urgent)
    }

    /// The frame a pane holding `stack` wears: the member in front's, or
    /// the first member's (`Choices.frameFollowsShown`). Never nothing --
    /// see `Choices.plainStyle`.
    static func wears(_ stack: PaneStack) -> PaneFrame.Kind {
        let member = Choices.frameFollowsShown ? stack.showing : stack.members.first
        return member?.wears ?? .plain
    }

    /// The title a pane holding a stack hands its frame: the one the
    /// frame would have had, or -- for an ordinary terminal that would
    /// have worn nothing -- the name of the member in front with nothing
    /// to say.
    static func title(_ stack: PaneStack, framed: PaneFrame.Title?) -> PaneFrame.Title {
        framed ?? PaneFrame.Title(name: stack.showing?.name ?? "", shown: .none, word: "")
    }

    /// The member a step along the tabs from `current` lands on, round the
    /// ends; nil when there is nowhere else to go.
    static func neighbour(of current: Int, count: Int, by step: Int) -> Int? {
        guard count > 1, current >= 0, current < count else { return nil }
        let to = ((current + step) % count + count) % count
        return to == current ? nil : to
    }

    /// What one of the stack's verbs does to the pane the keyboard is in.
    enum Verb: String, CaseIterable {
        /// A new terminal in this pane, in front.
        case new
        /// The next tab of this pane's stack, and the one before.
        case next
        case previous
        /// This terminal out of its stack, into a pane of its own beside.
        case out
        /// This pane's terminal onto the next pane's stack, and the one
        /// before: two panes become one.
        case ontoNext = "onto_next"
        case ontoPrevious = "onto_previous"
    }

    /// Whether `verb` has anything to do, so a menu can grey what has not.
    /// `stacked` is whether the pane holds more than one terminal, `panes`
    /// how many panes the tab shows, `quick` whether it is the quick
    /// terminal -- which holds no stacks, as it wears no frames.
    static func offers(_ verb: Verb, stacked: Bool, panes: Int, quick: Bool) -> Bool {
        if quick { return false }
        switch verb {
        case .new: return true
        case .next, .previous, .out: return stacked
        case .ontoNext, .ontoPrevious: return panes > 1
        }
    }
}
