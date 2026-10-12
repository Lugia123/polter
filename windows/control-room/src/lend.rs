//! Which terminal the control room has borrowed, and what has to happen to
//! it when anything changes (`dev-docs/poltergeist/control-room.md`, 12.5).
//!
//! The right-hand side shows the selected group's supervisor: the real
//! terminal, shown in the control room and given back afterwards. **A
//! terminal is in one place at a time**, and every way of leaving -- another
//! group selected, the control room closed or covered, its own pane closed
//! under it -- has to end with it either back where it was or let go of.
//! That is what this decides, as a list of things to do in order. It touches
//! no window, so it runs anywhere; the macOS host's `ControlRoomLending.swift`
//! is the same thing, and `tools/control-room-hosts-agree.py` runs the two
//! through one script of events.
//!
//! Which terminal is a group's supervisor is the core's to say (`steward`
//! in the snapshot). Nothing here works it out.
//!
//! **One thing is this host's own: `Place::Elsewhere`.** On Windows a
//! terminal is borrowed only from a tab of the control room's own window --
//! there its window is already a child of the same frame and showing it is a
//! matter of where the layout puts it. A supervisor in another window is not
//! moved (that needs `SetParent` across frames, which nothing has measured
//! yet); the right-hand side says where it is and offers to go there.

/// One terminal on loan, and the group it is shown for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Loan {
    pub group: String,
    /// The terminal's id as the core writes it.
    pub terminal: String,
}

/// Where the supervisor the core names is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Place {
    /// In a tab of the control room's own window: it can be shown here.
    Here,
    /// In another window. Not moved; see the module's note.
    Elsewhere,
    /// No pane holds that terminal any more.
    Gone,
}

/// What the right-hand side shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Detail {
    /// No group is selected.
    NothingSelected,
    /// The core names no supervisor for this group.
    NoSupervisor { group: String },
    /// The core names one, and no pane holds that terminal any more.
    SupervisorGone { group: String },
    /// It is in another window and stays there.
    Elsewhere(Loan),
    /// The person took it back to its own tab; it stays there until they
    /// ask for it here again or select another group.
    TakenBack(Loan),
    /// The terminal itself.
    Terminal(Loan),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// Take the terminal out of the control room. `to_home` says its place
    /// in its own tab is still there and it goes back into it; false, there
    /// is nowhere to put it and it is only let go of. `focus` hands the
    /// keyboard to it there.
    GiveBack { terminal: String, to_home: bool, focus: bool },
    /// Show the terminal on the right.
    Borrow(Loan),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The selection, or the snapshot behind it, is now this: the selected
    /// group, the supervisor the core names for it, and where that terminal
    /// is. Sent on every change of any of them, so it is also how a
    /// supervisor that changed or went away is noticed.
    Selected { group: Option<String>, supervisor: Option<String>, place: Place },
    /// The person asked for it back, from the placeholder in its tab.
    Reclaimed { terminal: String },
    /// The person asked for it here again after taking it back.
    AskedFor,
    /// The terminal's place in its own tab is gone: the pane, the tab or
    /// the window was closed.
    HomeGone { terminal: String },
    /// The control room is going away, or out of sight: its tab or its
    /// window is closing, the application is quitting, or another tab of
    /// its window was brought in front of it.
    Closing,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lending {
    loan: Option<Loan>,
    detail: Detail,
    /// The terminal the person took back, while its group stays selected.
    declined: Option<String>,
}

impl Default for Lending {
    fn default() -> Self {
        Lending { loan: None, detail: Detail::NothingSelected, declined: None }
    }
}

impl Lending {
    /// What is on loan now.
    pub fn loan(&self) -> Option<&Loan> {
        self.loan.as_ref()
    }

    pub fn detail(&self) -> &Detail {
        &self.detail
    }

    /// What to do about `event`, in the order to do it.
    pub fn handle(&mut self, event: Event) -> Vec<Effect> {
        match event {
            Event::Selected { group, supervisor, place } => self.select(group, supervisor, place),

            Event::Reclaimed { terminal } => match self.loan.take() {
                Some(loan) if loan.terminal == terminal => {
                    self.declined = Some(terminal.clone());
                    self.detail = Detail::TakenBack(loan);
                    vec![Effect::GiveBack { terminal, to_home: true, focus: true }]
                }
                other => {
                    self.loan = other;
                    Vec::new()
                }
            },

            Event::AskedFor => match &self.detail {
                Detail::TakenBack(wanted) => {
                    let wanted = wanted.clone();
                    self.declined = None;
                    self.loan = Some(wanted.clone());
                    self.detail = Detail::Terminal(wanted.clone());
                    vec![Effect::Borrow(wanted)]
                }
                Detail::NothingSelected
                | Detail::NoSupervisor { .. }
                | Detail::SupervisorGone { .. }
                | Detail::Elsewhere(_)
                | Detail::Terminal(_) => Vec::new(),
            },

            Event::HomeGone { terminal } => {
                if self.declined.as_deref() == Some(terminal.as_str()) {
                    self.declined = None;
                }
                let waiting_on_it = match &self.detail {
                    Detail::TakenBack(wanted) | Detail::Elsewhere(wanted) if wanted.terminal == terminal => Some(wanted.group.clone()),
                    _ => None,
                };
                if let Some(group) = waiting_on_it {
                    self.detail = Detail::SupervisorGone { group };
                }
                match self.loan.take() {
                    Some(loan) if loan.terminal == terminal => {
                        self.detail = Detail::SupervisorGone { group: loan.group };
                        // There is no home to go back to.
                        vec![Effect::GiveBack { terminal, to_home: false, focus: false }]
                    }
                    other => {
                        self.loan = other;
                        Vec::new()
                    }
                }
            }

            Event::Closing => {
                self.declined = None;
                self.detail = Detail::NothingSelected;
                self.return_loan()
            }
        }
    }

    fn select(&mut self, group: Option<String>, supervisor: Option<String>, place: Place) -> Vec<Effect> {
        let Some(group) = group else {
            self.declined = None;
            self.detail = Detail::NothingSelected;
            return self.return_loan();
        };
        let Some(supervisor) = supervisor else {
            self.declined = None;
            self.detail = Detail::NoSupervisor { group };
            return self.return_loan();
        };
        let wanted = Loan { group: group.clone(), terminal: supervisor.clone() };
        match place {
            Place::Gone => {
                self.declined = None;
                self.detail = Detail::SupervisorGone { group };
                // If it is the one on loan, its home went without anyone
                // saying so: let go of it rather than put it back nowhere.
                match self.loan.take() {
                    Some(loan) if loan.terminal == supervisor => {
                        vec![Effect::GiveBack { terminal: supervisor, to_home: false, focus: false }]
                    }
                    other => {
                        self.loan = other;
                        self.return_loan()
                    }
                }
            }
            Place::Elsewhere => {
                self.declined = None;
                self.detail = Detail::Elsewhere(wanted);
                // Whatever was here goes home; this one is not fetched.
                self.return_loan()
            }
            Place::Here => {
                if self.declined.as_deref() == Some(supervisor.as_str()) {
                    // Still the terminal the person took back.
                    self.detail = Detail::TakenBack(wanted);
                    return Vec::new();
                }
                self.declined = None;
                self.detail = Detail::Terminal(wanted.clone());
                if self.loan.as_ref().is_some_and(|loan| loan.terminal == supervisor) {
                    // Already here: one supervisor minding two groups, or
                    // the same selection again. It does not move.
                    self.loan = Some(wanted);
                    return Vec::new();
                }
                let mut effects = self.return_loan();
                self.loan = Some(wanted.clone());
                effects.push(Effect::Borrow(wanted));
                effects
            }
        }
    }

    /// Put whatever is on loan back in its own tab, without the keyboard:
    /// the person is looking at something else.
    fn return_loan(&mut self) -> Vec<Effect> {
        match self.loan.take() {
            Some(loan) => vec![Effect::GiveBack { terminal: loan.terminal, to_home: true, focus: false }],
            None => Vec::new(),
        }
    }
}

/// With the control room's tab in front and a terminal shown on its right,
/// which of the two has the keyboard: the terminal once the person has
/// clicked in it, the list otherwise -- so selecting a group, which is what
/// borrows the terminal, leaves the keyboard on the list (暂定, as on
/// macOS). With nothing on loan it is always the list.
pub fn keyboard_in_terminal(on_loan: bool, person_clicked_the_terminal: bool) -> bool {
    on_loan && person_clicked_the_terminal
}

/// What becomes of a request to close a pane (the core's `close_surface`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseOf {
    /// Close that pane, as always.
    ThePane,
    /// It is the terminal shown in the control room and the person pressed
    /// close while looking at the control room: what closes is the control
    /// room's tab, and the terminal goes home with its process running.
    TheControlRoom,
}

/// `on_loan` is whether the pane is the one shown in the control room;
/// `asks` is the core's "this needs the person's consent", which it says
/// only of a close the person asked for while something is running.
///
/// A close the core does not ask about is let through to the pane: that is
/// what a program ending looks like, and a terminal whose program has ended
/// must not be kept. (The usual close key is `close_tab`, which already
/// lands on the tab in front -- the control room's -- without this.)
pub fn close_of(on_loan: bool, asks: bool) -> CloseOf {
    if on_loan && asks {
        CloseOf::TheControlRoom
    } else {
        CloseOf::ThePane
    }
}

/// Whether a new split may be made from this pane. Not from the one shown
/// in the control room: the split would open in its own tab, where nobody
/// is looking (as on macOS).
pub fn may_split(on_loan: bool) -> bool {
    !on_loan
}

/// The English of what the right-hand side says when it shows a sentence; a
/// host translates each.
pub mod msg {
    use crate::n_;

    pub const GONE: &str = n_("The supervisor's terminal is no longer open.");
    /// What the supervisor's frame says the terminal in it is.
    pub const SUPERVISOR: &str = n_("Supervisor");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selected(group: &str, supervisor: Option<&str>, place: Place) -> Event {
        Event::Selected { group: Some(group.into()), supervisor: supervisor.map(str::to_string), place }
    }

    fn loan(group: &str, terminal: &str) -> Loan {
        Loan { group: group.into(), terminal: terminal.into() }
    }

    fn back(terminal: &str, to_home: bool, focus: bool) -> Effect {
        Effect::GiveBack { terminal: terminal.into(), to_home, focus }
    }

    #[test]
    fn selecting_a_group_borrows_its_supervisor_and_selecting_another_swaps_them() {
        let mut l = Lending::default();
        assert_eq!(l.handle(selected("a", Some("t1"), Place::Here)), vec![Effect::Borrow(loan("a", "t1"))]);
        assert_eq!(l.loan(), Some(&loan("a", "t1")));
        assert_eq!(l.detail(), &Detail::Terminal(loan("a", "t1")));
        // The one that was here goes home first, then the new one comes.
        assert_eq!(
            l.handle(selected("b", Some("t2"), Place::Here)),
            vec![back("t1", true, false), Effect::Borrow(loan("b", "t2"))]
        );
        assert_eq!(l.loan(), Some(&loan("b", "t2")));
    }

    #[test]
    fn one_supervisor_minding_two_groups_does_not_move_between_them() {
        let mut l = Lending::default();
        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(selected("b", Some("t1"), Place::Here)), vec![]);
        // It is on loan for the group that is selected now.
        assert_eq!(l.loan(), Some(&loan("b", "t1")));
        // The same selection again is nothing either.
        assert_eq!(l.handle(selected("b", Some("t1"), Place::Here)), vec![]);
    }

    #[test]
    fn a_group_with_nothing_to_show_sends_the_last_one_home_and_says_which_nothing() {
        let mut l = Lending::default();
        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(selected("b", None, Place::Gone)), vec![back("t1", true, false)]);
        assert_eq!(l.detail(), &Detail::NoSupervisor { group: "b".into() });
        assert_eq!(l.loan(), None);

        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(Event::Selected { group: None, supervisor: None, place: Place::Gone }), vec![back("t1", true, false)]);
        assert_eq!(l.detail(), &Detail::NothingSelected);

        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(selected("c", Some("t9"), Place::Gone)), vec![back("t1", true, false)]);
        assert_eq!(l.detail(), &Detail::SupervisorGone { group: "c".into() });
    }

    #[test]
    fn a_supervisor_in_another_window_is_not_fetched_and_whatever_was_here_goes_home() {
        let mut l = Lending::default();
        assert_eq!(l.handle(selected("a", Some("t1"), Place::Elsewhere)), vec![]);
        assert_eq!(l.detail(), &Detail::Elsewhere(loan("a", "t1")));
        assert_eq!(l.loan(), None);
        l.handle(selected("b", Some("t2"), Place::Here));
        assert_eq!(l.handle(selected("a", Some("t1"), Place::Elsewhere)), vec![back("t2", true, false)]);
        assert_eq!(l.loan(), None);
        // The one on loan moved to another window (its tab was moved out):
        // it is let go home, not held.
        l.handle(selected("b", Some("t2"), Place::Here));
        assert_eq!(l.handle(selected("b", Some("t2"), Place::Elsewhere)), vec![back("t2", true, false)]);
        assert_eq!(l.detail(), &Detail::Elsewhere(loan("b", "t2")));
    }

    #[test]
    fn a_home_that_went_is_not_gone_back_to() {
        let mut l = Lending::default();
        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(Event::HomeGone { terminal: "t1".into() }), vec![back("t1", false, false)]);
        assert_eq!(l.detail(), &Detail::SupervisorGone { group: "a".into() });
        assert_eq!(l.loan(), None);
        // Somebody else's home going is nothing to this loan.
        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(Event::HomeGone { terminal: "t7".into() }), vec![]);
        assert_eq!(l.loan(), Some(&loan("a", "t1")));
        // And one that went without anyone saying so, noticed at the next
        // snapshot: let go of, not put back nowhere.
        assert_eq!(l.handle(selected("a", Some("t1"), Place::Gone)), vec![back("t1", false, false)]);
    }

    #[test]
    fn closing_sends_it_home_without_the_keyboard_and_only_once() {
        let mut l = Lending::default();
        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(Event::Closing), vec![back("t1", true, false)]);
        assert_eq!(l.handle(Event::Closing), vec![]);
        assert_eq!(l.detail(), &Detail::NothingSelected);
        // Coming back in front borrows it again.
        assert_eq!(l.handle(selected("a", Some("t1"), Place::Here)), vec![Effect::Borrow(loan("a", "t1"))]);
    }

    #[test]
    fn taken_back_stays_back_until_it_is_asked_for_or_another_group_is_selected() {
        let mut l = Lending::default();
        l.handle(selected("a", Some("t1"), Place::Here));
        assert_eq!(l.handle(Event::Reclaimed { terminal: "t1".into() }), vec![back("t1", true, true)]);
        assert_eq!(l.detail(), &Detail::TakenBack(loan("a", "t1")));
        // The next snapshot does not take it away again.
        assert_eq!(l.handle(selected("a", Some("t1"), Place::Here)), vec![]);
        assert_eq!(l.loan(), None);
        assert_eq!(l.handle(Event::AskedFor), vec![Effect::Borrow(loan("a", "t1"))]);
        assert_eq!(l.detail(), &Detail::Terminal(loan("a", "t1")));
        // Asking with nothing taken back is nothing.
        assert_eq!(l.handle(Event::AskedFor), vec![]);
        // Reclaiming a terminal that is not the one on loan is nothing.
        assert_eq!(l.handle(Event::Reclaimed { terminal: "t9".into() }), vec![]);
        assert_eq!(l.loan(), Some(&loan("a", "t1")));
        // Taken back, then another group and back again: it comes.
        l.handle(Event::Reclaimed { terminal: "t1".into() });
        l.handle(selected("b", None, Place::Gone));
        assert_eq!(l.handle(selected("a", Some("t1"), Place::Here)), vec![Effect::Borrow(loan("a", "t1"))]);
    }

    #[test]
    fn the_keyboard_stays_on_the_list_until_the_person_clicks_in_the_terminal() {
        assert!(!keyboard_in_terminal(true, false));
        assert!(keyboard_in_terminal(true, true));
        assert!(!keyboard_in_terminal(false, true));
        assert!(!keyboard_in_terminal(false, false));
    }

    #[test]
    fn close_on_the_borrowed_terminal_closes_the_control_room_unless_the_program_ended() {
        assert_eq!(close_of(true, true), CloseOf::TheControlRoom);
        // A close nobody has to consent to is a program that ended.
        assert_eq!(close_of(true, false), CloseOf::ThePane);
        assert_eq!(close_of(false, true), CloseOf::ThePane);
        assert_eq!(close_of(false, false), CloseOf::ThePane);
    }

    #[test]
    fn the_borrowed_terminal_is_not_split() {
        assert!(!may_split(true));
        assert!(may_split(false));
    }
}
