import Foundation

/// Which terminal the control room has borrowed, and what has to happen to
/// it when anything changes (`dev-docs/poltergeist/control-room.md`, 7.3).
///
/// The right-hand side shows the selected group's supervisor: the real
/// terminal, taken out of its own tab and put back afterwards. **A terminal
/// is in one place at a time**, and every way of leaving -- another group
/// selected, the control room closed, the person asking for it back, its
/// own tab closed under it -- has to end with it either back where it was
/// or let go of. That is what this decides, as a list of things to do in
/// order; it touches no view, so it can be run without a window.
///
/// Which terminal is a group's supervisor is the core's to say (`steward`
/// in the snapshot). Nothing here works it out.
struct ControlRoomLending: Equatable {
    /// One terminal on loan, and the group it is shown for.
    struct Loan: Equatable {
        var group: String
        /// The terminal's id as the core writes it.
        var terminal: String
    }

    /// What the right-hand side shows.
    enum Detail: Equatable {
        /// No group is selected.
        case nothingSelected
        /// The core names no supervisor for this group.
        case noSupervisor(group: String)
        /// The core names one, and no tab holds that terminal any more.
        case supervisorGone(group: String)
        /// The person took it back to its own tab; it stays there until
        /// they ask for it here again or select another group.
        case takenBack(Loan)
        /// The terminal itself.
        case terminal(Loan)

        /// The loan when the terminal itself is shown; nil for a sentence.
        var terminal: Loan? {
            if case let .terminal(loan) = self { return loan }
            return nil
        }
    }

    enum Effect: Equatable {
        /// Take the terminal out of the control room. `toHome` says its
        /// place in its own tab is still there and it goes back into it;
        /// false, there is nowhere to put it and it is only let go of.
        /// `focus` hands the keyboard to it there.
        case giveBack(terminal: String, toHome: Bool, focus: Bool)
        /// Take the terminal out of its own tab, leaving the placeholder,
        /// and show it on the right.
        case borrow(Loan)
    }

    enum Event: Equatable {
        /// The selection, or the snapshot behind it, is now this: the
        /// selected group, the supervisor the core names for it, and
        /// whether a tab still holds that terminal. Sent on every change
        /// of either, so it is also how a supervisor that changed or went
        /// away is noticed.
        case selected(group: String?, supervisor: String?, present: Bool)
        /// The person asked for it back, from the placeholder in its tab.
        case reclaimed(terminal: String)
        /// The person asked for it here again after taking it back.
        case askedFor
        /// The terminal's place in its own tab is gone: the pane, the tab
        /// or the window was closed.
        case homeGone(terminal: String)
        /// The control room is going away, or out of sight: its tab or its
        /// window is closing, the application is quitting, or another tab
        /// of its window was brought in front of it.
        case closing
    }

    /// What is on loan now.
    private(set) var loan: Loan?
    private(set) var detail: Detail = .nothingSelected
    /// The terminal the person took back, while its group stays selected.
    private var declined: String?

    /// What to do about `event`, in the order to do it.
    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .selected(group, supervisor, present):
            return select(group: group, supervisor: supervisor, present: present)

        case let .reclaimed(terminal):
            guard let loan, loan.terminal == terminal else { return [] }
            self.loan = nil
            declined = terminal
            detail = .takenBack(loan)
            return [.giveBack(terminal: terminal, toHome: true, focus: true)]

        case .askedFor:
            guard case let .takenBack(wanted) = detail else { return [] }
            declined = nil
            loan = wanted
            detail = .terminal(wanted)
            return [.borrow(wanted)]

        case let .homeGone(terminal):
            if declined == terminal { declined = nil }
            if case let .takenBack(wanted) = detail, wanted.terminal == terminal {
                detail = .supervisorGone(group: wanted.group)
            }
            guard let loan, loan.terminal == terminal else { return [] }
            self.loan = nil
            detail = .supervisorGone(group: loan.group)
            // There is no home to go back to.
            return [.giveBack(terminal: terminal, toHome: false, focus: false)]

        case .closing:
            declined = nil
            detail = .nothingSelected
            return returnLoan()
        }
    }

    private mutating func select(group: String?, supervisor: String?, present: Bool) -> [Effect] {
        guard let group else {
            declined = nil
            detail = .nothingSelected
            return returnLoan()
        }
        guard let supervisor else {
            declined = nil
            detail = .noSupervisor(group: group)
            return returnLoan()
        }
        guard present else {
            declined = nil
            detail = .supervisorGone(group: group)
            // If it is the one on loan, its home went without anyone
            // saying so: let go of it rather than put it back nowhere.
            if let loan, loan.terminal == supervisor {
                self.loan = nil
                return [.giveBack(terminal: supervisor, toHome: false, focus: false)]
            }
            return returnLoan()
        }

        let wanted = Loan(group: group, terminal: supervisor)
        if declined == supervisor {
            // Still the terminal the person took back.
            detail = .takenBack(wanted)
            return []
        }
        declined = nil
        detail = .terminal(wanted)
        if let loan, loan.terminal == supervisor {
            // Already here: one supervisor minding two groups, or the same
            // selection again. It does not move.
            self.loan = wanted
            return []
        }
        let back = returnLoan()
        loan = wanted
        return back + [.borrow(wanted)]
    }

    /// Put whatever is on loan back in its own tab, without the keyboard:
    /// the person is looking at something else.
    private mutating func returnLoan() -> [Effect] {
        guard let loan else { return [] }
        self.loan = nil
        return [.giveBack(terminal: loan.terminal, toHome: true, focus: false)]
    }
}

extension ControlRoomSnapshot {
    /// The supervisor the core names for `group`; nil when it names none or
    /// lists no such group.
    func supervisor(of group: String) -> String? {
        groups.first { $0.name == group }?.steward
    }
}
