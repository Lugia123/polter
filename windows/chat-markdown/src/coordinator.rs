//! Which messages need parsing, and which answers may still be applied
//! (task 2802, W3b-B1).
//!
//! **Pure.** The UI executes the actions this returns and hands completions
//! back; nothing here starts a thread, reads a clock or touches a window.
//! The host owns exactly one of these beside its one parse thread and its
//! one cache.
//!
//! What it keeps straight:
//!
//!   * **At most four requests in flight** (queued, running or answered but
//!     not yet collected -- all count), and **at most 1 MiB of source** among
//!     them.
//!   * **One request per key.** The same message asked for by two views is
//!     one parse; both ownercounts are kept and both are told.
//!   * **A late answer is dropped, not delivered.** A completion is handed
//!     only to owners that still ask for that key *and* whose epoch is still
//!     the one they asked under; a view that left or was rebound gets
//!     nothing, and the slot is freed all the same.
//!   * **Absent, Pending, Ready and Fallback are four things.** A pending
//!     request is not a cache hit and a failure is not an empty message.

use std::collections::VecDeque;
use std::sync::Arc;

use crate::{Key, Parsed, Reason};

/// The most requests in flight at once, for the whole host.
pub const MAX_IN_FLIGHT: usize = 4;
/// The most source bytes those requests may hold, for the whole host.
pub const MAX_SOURCE_BYTES: usize = 1024 * 1024;
/// One message's source bound: a larger one is a fallback, never a send.
pub const MAX_SOURCE_ITEM: usize = 256 * 1024;

/// Which view asked, and under which generation. **Not an HWND**: window
/// handles are reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Owner {
    pub view: u64,
    pub epoch: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Absent,
    Pending,
    Ready,
    Fallback,
}

/// What the UI must do. `Send` is carried out with `try_send`: the UI never
/// blocks on the worker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Send { key: Key, source: Arc<str> },
}

#[derive(Debug)]
struct Need {
    key: Key,
    source: Arc<str>,
    owners: Vec<Owner>,
    state: State,
    /// Why it is a fallback, when it is one.
    reason: Option<Reason>,
    /// Handed to the worker and not completed yet.
    sent: bool,
}

#[derive(Debug)]
pub struct Coordinator {
    needs: Vec<Need>,
    /// Keys waiting for a slot, oldest first.
    waiting: VecDeque<Key>,
    in_flight: usize,
    source_bytes: usize,
}

impl Default for Coordinator {
    fn default() -> Self {
        Coordinator::new()
    }
}

/// What a completion came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completion {
    pub key: Key,
    pub state: State,
    /// Owners still asking, and still on the epoch they asked under.
    pub owners: Vec<Owner>,
    /// The failure's word when `state` is `Fallback`.
    pub reason: Option<Reason>,
}

impl Coordinator {
    pub fn new() -> Coordinator {
        Coordinator {
            needs: Vec::new(),
            waiting: VecDeque::new(),
            in_flight: 0,
            source_bytes: 0,
        }
    }

    pub fn in_flight(&self) -> usize {
        self.in_flight
    }

    pub fn source_bytes(&self) -> usize {
        self.source_bytes
    }

    pub fn waiting(&self) -> usize {
        self.waiting.len()
    }

    pub fn state(&self, key: &Key) -> State {
        self.needs
            .iter()
            .find(|n| &n.key == key)
            .map_or(State::Absent, |n| n.state)
    }

    /// The set of messages `owner` can see now, computed by the caller from
    /// the rows in sight. Keys already cached are `Ready` at once and are
    /// not sent; everything else is sent as the budget allows.
    ///
    /// `cached` is the host's one cache (a read, never a parse): a hit is
    /// shared, not re-requested.
    pub fn replace_demand(
        &mut self,
        owner: Owner,
        items: Vec<(Key, Arc<str>)>,
        cached: &dyn Fn(&Key) -> Option<State>,
    ) -> Vec<Action> {
        for need in self.needs.iter_mut() {
            if need.owners.contains(&owner) && !items.iter().any(|(k, _)| k == &need.key) {
                need.owners.retain(|o| o != &owner);
            }
        }
        // **An answer nobody asks for keeps no source**: a ready or
        // fallback need with no owner is dropped; the cache still holds
        // what there was to hold. A sent one stays until its reply, so its
        // slot is accounted for.
        self.needs.retain(|n| n.sent || !n.owners.is_empty());
        self.waiting.retain(|k| {
            self.needs
                .iter()
                .any(|n| &n.key == k && !n.owners.is_empty() && !n.sent && n.state == State::Absent)
        });

        for (key, source) in items {
            if let Some(need) = self.needs.iter_mut().find(|n| n.key == key) {
                if !need.owners.contains(&owner) {
                    need.owners.push(owner);
                }
                // **The cache is re-asked every time**: an evicted entry
                // goes back to Absent and is requested again, and a cached
                // fallback stays a fallback rather than becoming Ready. A
                // request already out keeps its Pending state.
                if !need.sent && need.state != State::Pending {
                    match cached(&key) {
                        Some(state) => {
                            if state != need.state {
                                need.state = state;
                                need.reason = if state == State::Fallback {
                                    Some(Reason::Unsupported)
                                } else {
                                    None
                                };
                            }
                        }
                        None if matches!(need.state, State::Ready | State::Fallback) => {
                            need.state = State::Absent;
                            need.reason = None;
                            if !self.waiting.contains(&key) {
                                self.waiting.push_back(key.clone());
                            }
                        }
                        None => {}
                    }
                }
                continue;
            }
            let (state, reason) = if source.len() > MAX_SOURCE_ITEM {
                (State::Fallback, Some(Reason::Limit))
            } else {
                match cached(&key) {
                    Some(State::Ready) => (State::Ready, None),
                    Some(State::Fallback) => (State::Fallback, Some(Reason::Unsupported)),
                    _ => (State::Absent, None),
                }
            };
            let wait = state == State::Absent;
            self.needs.push(Need {
                key: key.clone(),
                source,
                owners: vec![owner],
                state,
                reason,
                sent: false,
            });
            if wait {
                self.waiting.push_back(key);
            }
        }
        self.dispatch()
    }

    /// The UI's view went away (page left, group changed, minimised): its
    /// owner demand is withdrawn. A request already running finishes and
    /// frees its slot, but its answer reaches nobody.
    pub fn leave(&mut self, owner: Owner) {
        for need in self.needs.iter_mut() {
            need.owners.retain(|o| o != &owner);
        }
        self.waiting.retain(|k| {
            self.needs
                .iter()
                .any(|n| &n.key == k && !n.owners.is_empty() && !n.sent && n.state == State::Absent)
        });
        self.needs.retain(|n| n.sent || !n.owners.is_empty());
    }

    /// An answer from the worker. **The complete Key and a still-live owner
    /// epoch decide whether it is applied at all**; a stale one only frees
    /// its slot.
    pub fn complete(
        &mut self,
        key: &Key,
        parsed: &Parsed,
        live: &dyn Fn(Owner) -> bool,
    ) -> Option<Completion> {
        let at = self.needs.iter().position(|n| &n.key == key)?;
        let need = self.needs.remove(at);
        if need.sent {
            self.in_flight = self.in_flight.saturating_sub(1);
            self.source_bytes = self.source_bytes.saturating_sub(need.source.len());
        }
        self.waiting.retain(|k| k != key);
        let (state, reason) = match parsed {
            Parsed::Document(_) => (State::Ready, None),
            Parsed::PlainFallback(reason) => (State::Fallback, Some(*reason)),
        };
        let owners: Vec<Owner> = need.owners.into_iter().filter(|o| live(*o)).collect();
        Some(Completion {
            key: key.clone(),
            state,
            owners,
            reason,
        })
    }

    /// The UI could not hand this request to the worker (its queue was
    /// full, or it is gone). **The reservation goes back**: the slot and
    /// its bytes are free again and the key waits to be retried.
    pub fn rollback(&mut self, key: &Key) {
        let Some(need) = self.needs.iter_mut().find(|n| &n.key == key && n.sent) else {
            return;
        };
        need.sent = false;
        need.state = State::Absent;
        self.in_flight = self.in_flight.saturating_sub(1);
        self.source_bytes = self.source_bytes.saturating_sub(need.source.len());
        self.waiting.push_front(need.key.clone());
    }

    /// Why a fallback need is one, when it is one.
    pub fn reason(&self, key: &Key) -> Option<Reason> {
        self.needs
            .iter()
            .find(|n| &n.key == key)
            .and_then(|n| n.reason)
    }

    /// Fill the four slots and the 1 MiB, oldest first. Called by the host
    /// after a completion; also called inside `replace_demand`.
    pub fn dispatch(&mut self) -> Vec<Action> {
        let mut actions = Vec::new();
        while self.in_flight < MAX_IN_FLIGHT {
            let Some(key) = self.waiting.front().cloned() else {
                break;
            };
            let Some(need) = self
                .needs
                .iter_mut()
                .find(|n| n.key == key && !n.sent && n.state == State::Absent)
            else {
                self.waiting.pop_front();
                continue;
            };
            if need.source.len() > MAX_SOURCE_ITEM {
                // Belt and braces: an oversize source is a fallback, never
                // a request.
                need.state = State::Fallback;
                need.reason = Some(Reason::Limit);
                self.waiting.pop_front();
                continue;
            }
            let bytes = need.source.len();
            if self.source_bytes + bytes > MAX_SOURCE_BYTES {
                // This one does not fit; the rest may not either, but a
                // smaller one behind it could. Give the slot to the next
                // that fits and leave this queued.
                let mut moved = false;
                if let Some(pos) = self.waiting.iter().skip(1).position(|k| {
                    self.needs
                        .iter()
                        .find(|n| &n.key == k && !n.sent && n.state == State::Absent)
                        .is_some_and(|n| self.source_bytes + n.source.len() <= MAX_SOURCE_BYTES)
                }) {
                    let at = pos + 1;
                    if let Some(k) = self.waiting.remove(at) {
                        self.waiting.push_front(k);
                        moved = true;
                    }
                }
                if !moved {
                    break;
                }
                continue;
            }
            need.sent = true;
            need.state = State::Pending;
            self.in_flight += 1;
            self.source_bytes += bytes;
            let source = need.source.clone();
            self.waiting.pop_front();
            actions.push(Action::Send {
                key: key.clone(),
                source,
            });
        }
        actions
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(anchor: &str, version: u64) -> Key {
        Key {
            group: "g".to_owned(),
            generation: 1,
            anchor: anchor.to_owned(),
            content_version: version,
        }
    }

    fn owner(view: u64, epoch: u64) -> Owner {
        Owner { view, epoch }
    }

    fn item(anchor: &str, source: &str) -> (Key, Arc<str>) {
        (key(anchor, 0), Arc::from(source))
    }

    fn no_cache(_: &Key) -> Option<State> {
        None
    }

    #[test]
    fn the_same_key_is_one_request_however_many_views_want_it() {
        let mut c = Coordinator::new();
        let actions = c.replace_demand(owner(1, 1), vec![item("a", "x")], &no_cache);
        assert_eq!(actions.len(), 1);
        let more = c.replace_demand(owner(2, 1), vec![item("a", "x")], &no_cache);
        assert!(more.is_empty(), "one parse, two owners");
        assert_eq!(c.in_flight(), 1);

        let done = c.complete(
            &key("a", 0),
            &Parsed::PlainFallback(Reason::Unsupported),
            &|_| true,
        );
        let owners = done.expect("completed").owners;
        assert_eq!(owners.len(), 2);
        assert_eq!(c.in_flight(), 0);
    }

    #[test]
    fn never_more_than_four_in_flight_and_the_fifth_waits_its_turn() {
        let mut c = Coordinator::new();
        let items: Vec<_> = (0..5).map(|i| item(&format!("k{i}"), "s")).collect();
        let actions = c.replace_demand(owner(1, 1), items, &no_cache);
        assert_eq!(actions.len(), 4);
        assert_eq!(c.in_flight(), 4);
        assert_eq!(c.waiting(), 1);
        // One finishes; the fifth goes, never a fifth slot.
        c.complete(&key("k0", 0), &Parsed::Document(crate::Document { blocks: vec![] }), &|_| true);
        let drained = c.dispatch();
        assert_eq!(drained.len(), 1);
        assert_eq!(c.in_flight(), 4);
    }

    #[test]
    fn the_source_budget_is_one_mib_across_requests() {
        let mut c = Coordinator::new();
        let full = "x".repeat(MAX_SOURCE_ITEM);
        // Four at the per-message bound are exactly the 1 MiB budget.
        let items: Vec<(Key, Arc<str>)> = (0..4)
            .map(|i| (key(&format!("k{i}"), 0), Arc::from(&full[..])))
            .collect();
        let actions = c.replace_demand(owner(1, 1), items, &no_cache);
        assert_eq!(actions.len(), 4);
        assert_eq!(c.source_bytes(), MAX_SOURCE_BYTES);
        // A fifth, tiny one waits for a slot and for bytes.
        let more = c.replace_demand(owner(2, 1), vec![item("k9", "s")], &no_cache);
        assert!(more.is_empty());
        assert_eq!(c.waiting(), 1);
        c.complete(&key("k0", 0), &Parsed::PlainFallback(Reason::Limit), &|_| true);
        assert_eq!(c.dispatch().len(), 1, "the slot and bytes are free again");
    }

    #[test]
    fn one_source_over_the_message_bound_is_a_fallback_never_a_send() {
        let mut c = Coordinator::new();
        let big = "x".repeat(MAX_SOURCE_ITEM + 1);
        let actions = c.replace_demand(owner(1, 1), vec![(key("a", 0), Arc::from(&big[..]))], &no_cache);
        assert!(actions.is_empty(), "an oversize message is not sent");
        assert_eq!(c.state(&key("a", 0)), State::Fallback);
        assert_eq!(c.reason(&key("a", 0)), Some(Reason::Limit));
        assert_eq!(c.in_flight(), 0);
    }

    #[test]
    fn a_refused_send_rolls_its_reservation_back_and_can_be_retried() {
        let mut c = Coordinator::new();
        let actions = c.replace_demand(owner(1, 1), vec![item("a", "x")], &no_cache);
        assert_eq!(actions.len(), 1);
        assert_eq!(c.in_flight(), 1);
        c.rollback(&key("a", 0));
        assert_eq!(c.in_flight(), 0);
        assert_eq!(c.source_bytes(), 0);
        assert_eq!(c.state(&key("a", 0)), State::Absent);
        assert_eq!(c.dispatch().len(), 1, "the retry is offered again");
    }

    #[test]
    fn a_view_that_left_gets_no_answer_and_its_slot_is_freed() {
        let mut c = Coordinator::new();
        c.replace_demand(owner(7, 3), vec![item("a", "x")], &no_cache);
        c.leave(owner(7, 3));
        // The request was already out: its answer reaches nobody, and the
        // slot comes back.
        let done = c.complete(&key("a", 0), &Parsed::PlainFallback(Reason::Unsupported), &|o| {
            o == owner(7, 3)
        });
        let done = done.expect("the slot was accounted for");
        assert!(done.owners.is_empty(), "a gone view is not delivered to");
        assert_eq!(c.in_flight(), 0);
    }

    #[test]
    fn an_old_epoch_is_not_delivered_even_when_the_view_number_matches() {
        let mut c = Coordinator::new();
        c.replace_demand(owner(9, 1), vec![item("a", "x")], &no_cache);
        let done = c
            .complete(&key("a", 0), &Parsed::PlainFallback(Reason::Unsupported), &|o| {
                o.view == 9 && o.epoch == 2
            })
            .unwrap();
        assert!(done.owners.is_empty(), "the epoch asked is the one checked");
    }

    #[test]
    fn a_key_that_differs_anywhere_is_a_different_request() {
        let mut c = Coordinator::new();
        let other: Vec<(Key, Arc<str>)> = [
            Key {
                group: "h".to_owned(),
                ..key("a", 0)
            },
            Key {
                generation: 2,
                ..key("a", 0)
            },
            key("b", 0),
            Key {
                content_version: 4,
                ..key("a", 0)
            },
        ]
        .into_iter()
        .map(|k| (k, Arc::from("x")))
        .collect();
        let actions = c.replace_demand(owner(1, 1), other, &no_cache);
        assert_eq!(actions.len(), 4, "none of them was mistaken for another");
    }

    #[test]
    fn a_cache_hit_is_ready_without_a_parse_and_an_eviction_asks_again() {
        let mut c = Coordinator::new();
        let hit = |_: &Key| Some(State::Ready);
        let actions = c.replace_demand(owner(1, 1), vec![item("a", "x")], &hit);
        assert!(actions.is_empty());
        assert_eq!(c.state(&key("a", 0)), State::Ready);
        // Ready with an owner stays, but the cache is asked again every
        // time: an eviction makes the same demand go out.
        let actions = c.replace_demand(owner(1, 1), vec![item("a", "x")], &no_cache);
        assert_eq!(actions.len(), 1, "evicted cache re-requests the same key");
        assert_eq!(c.state(&key("a", 0)), State::Pending);
    }

    #[test]
    fn a_cached_fallback_is_not_reported_as_ready_and_owners_keep_no_fallback_source() {
        let mut c = Coordinator::new();
        let fallback = |_: &Key| Some(State::Fallback);
        let actions = c.replace_demand(owner(1, 1), vec![item("bad", "source")], &fallback);
        assert!(actions.is_empty());
        assert_eq!(c.state(&key("bad", 0)), State::Fallback);
        // The owner leaves: a fallback nobody asks for keeps no source.
        c.leave(owner(1, 1));
        assert_eq!(c.state(&key("bad", 0)), State::Absent);
    }

    #[test]
    fn a_shared_source_is_one_allocation_for_both_owners() {
        let mut c = Coordinator::new();
        let source: Arc<str> = Arc::from("same");
        let first = c.replace_demand(owner(1, 1), vec![(key("a", 0), source.clone())], &no_cache);
        let Action::Send { source: sent, .. } = &first[0] else {
            panic!("expected a send");
        };
        assert!(Arc::ptr_eq(sent, &source));
        c.replace_demand(owner(2, 1), vec![(key("a", 0), source.clone())], &no_cache);
        assert_eq!(Arc::strong_count(&source), 3, "coordinator + two owners' arcs");
    }

    #[test]
    fn a_fallback_is_not_an_empty_document_and_both_states_are_kept() {
        let mut c = Coordinator::new();
        c.replace_demand(owner(1, 1), vec![item("ok", "x"), item("bad", "y")], &no_cache);
        let ok = c
            .complete(&key("ok", 0), &Parsed::Document(crate::Document { blocks: vec![] }), &|_| true)
            .unwrap();
        assert_eq!(ok.state, State::Ready);
        let bad = c
            .complete(&key("bad", 0), &Parsed::PlainFallback(Reason::Unsupported), &|_| true)
            .unwrap();
        assert_eq!(bad.state, State::Fallback);
        assert_eq!(bad.reason, Some(Reason::Unsupported));
    }
}
