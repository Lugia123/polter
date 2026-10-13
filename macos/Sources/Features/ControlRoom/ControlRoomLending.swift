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
        /// The same three things as `selected`, while the control room is
        /// out of sight (behind another tab, or not on screen): nothing is
        /// borrowed, and whatever was is put back -- but what the right
        /// side *says* is kept true, so that it is right the moment it is
        /// seen. It used to say "select a group" with a group selected,
        /// from a restart until the window was brought forward.
        case outOfSight(group: String?, supervisor: String?, present: Bool)
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

        case let .outOfSight(group, supervisor, present):
            declined = nil
            let back = returnLoan()
            guard let group else {
                detail = .nothingSelected
                return back
            }
            guard let supervisor else {
                detail = .noSupervisor(group: group)
                return back
            }
            // Its terminal is in its own tab, which is where the person
            // would find it now; coming back into sight asks for it here.
            detail = present ? .takenBack(Loan(group: group, terminal: supervisor)) : .supervisorGone(group: group)
            return back
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

extension ControlRoomLending {
    /// One sentence for each way of having no terminal to show. Never
    /// empty: a blank right-hand side reads as something broken.
    ///
    /// Here and not in the view that draws it, so that it can be held to
    /// the Windows host's sentences (`tools/control-room-hosts-agree.py`).
    static func words(for detail: ControlRoomLending.Detail,
                      start: ControlRoomList.SupervisorStart? = nil, alone: Bool = false) -> String {
        if alone {
            // A terminal with a row of its own has no supervisor to speak
            // of: it is itself what the right-hand side would show.
            switch detail {
            case .noSupervisor, .supervisorGone:
                return String(localized: "This terminal is no longer open.", comment: "总控台：选中的是一个不在任何群里的终端，它已经关掉时右栏的说明")
            case .takenBack:
                return String(localized: "Showing in its own tab", comment: "总控台：选中的是一个不在任何群里的终端，它被要回原处以后右栏的第一行：界面现在在哪")
            case .nothingSelected, .terminal:
                break
            }
        }
        switch detail {
        case .nothingSelected:
            return String(localized: "Select a group to see its supervisor.", comment: "总控台：没有选中任何群时右栏的说明")
        case .noSupervisor:
            // Which of these it is is the core's word (`state`, `failed`).
            switch (start?.state, start?.failed) {
            case (.starting, _):
                return String(localized: "Starting the supervisor…", comment: "总控台：点了启动总管以后，总管还没连上的那一段，右栏的说明")
            case (.failed, .terminalNeverOpened):
                return String(localized: "The supervisor did not start: its tab never opened.",
                              comment: "总控台：启动总管失败，标签页没开出来")
            case (.failed, .agentNeverConnected):
                return String(localized: "The supervisor did not start: its tab opened, but no agent connected from it. Its tab shows why.",
                              comment: "总控台：启动总管失败，标签页开了但里面的 agent 没有连上 Polter")
            case (.failed, .terminalClosed):
                return String(localized: "The supervisor did not start: its tab was closed first.",
                              comment: "总控台：启动总管失败，标签页在 agent 连上之前被关掉了")
            case (.failed, .cliNotFound):
                return String(localized: "The supervisor did not start: its agent CLI was not found. Its tab shows why.",
                              comment: "总控台：启动总管失败，启动器自己报的：agent CLI 的程序找不到")
            case (.failed, .cliDidNotStart):
                return String(localized: "The supervisor did not start: its agent CLI could not be started. Its tab shows why.",
                              comment: "总控台：启动总管失败，启动器自己报的：agent CLI 没能启动")
            case (.failed, _):
                return String(localized: "The supervisor did not start.", comment: "总控台：启动总管失败，没有更具体的原因")
            default:
                return String(localized: "This group has no supervisor.", comment: "总控台：选中的群没有总管时右栏的说明")
            }
        case .supervisorGone:
            return String(localized: "The supervisor's terminal is no longer open.", comment: "总控台：总管的终端已经关掉时右栏的说明")
        case .takenBack:
            return String(localized: "Showing in the supervisor's tab", comment: "总控台：总管的终端被要回原处以后右栏的第一行：界面现在在哪")
        case .terminal:
            return ""
        }
    }
}

extension ControlRoomSnapshot {
    /// The supervisor the core names for `group`; nil when it names none or
    /// lists no such group.
    func supervisor(of group: String) -> String? {
        groups.first { $0.name == group }?.steward
    }

    /// The terminal the right-hand side shows for the row `row`: a group's
    /// supervisor, and for a terminal that has a row of its own, that
    /// terminal. Nil for a row the snapshot does not list.
    func terminal(shownFor row: String) -> String? {
        if let one = ungrouped?.first(where: { ControlRoomList.rowId(ofTerminal: $0.id) == row }) {
            return one.id
        }
        return supervisor(of: row)
    }
}
