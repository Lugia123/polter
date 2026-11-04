//! The host's one Markdown parse service (task 2802, W3b-B1).
//!
//! **One thread for the whole host**, one 200/4 MiB cache (`chat-markdown`),
//! and at most four requests in flight / 1 MiB of source. The UI only ever
//! does `try_send` and `try_recv`; it never parses, never blocks and never
//! joins. The worker only parses: it holds no core handle, no window, no
//! HDC, no file and no network.
//!
//! A completion is offered back to the owners that still ask for that exact
//! key under the epoch they asked with. The liveness answer is the UI's
//! (`poll` takes it as a closure): the service itself keeps no HWND, so a
//! reused handle cannot make an old answer land in a new view.

use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};

use polter_chat_markdown::cache::{Cache, Entry, Key};
use polter_chat_markdown::coordinator::{Action, Completion, Coordinator, Owner, State};
use polter_chat_markdown::{parse, Parsed};

struct Service {
    jobs: SyncSender<(Key, Arc<str>)>,
    done: Receiver<(Key, Parsed)>,
    coordinator: Coordinator,
    cache: Cache,
}

/// `None` when the one worker could not be started: the service is then
/// unavailable, the original text stays on screen, and nothing crashes.
static SERVICE: OnceLock<Option<Mutex<Service>>> = OnceLock::new();

fn service() -> Option<&'static Mutex<Service>> {
    SERVICE
        .get_or_init(|| {
            let (jobs, job_rx) = sync_channel::<(Key, Arc<str>)>(4);
            let (done_tx, done) = sync_channel::<(Key, Parsed)>(4);
            let started = std::thread::Builder::new()
                .name("polter-chat-markdown".to_owned())
                .spawn(move || {
                    crate::name_this_thread("polter-chat-markdown");
                    // Blocking on the worker side is fine: it is the
                    // background. The UI only ever tries.
                    while let Ok((key, source)) = job_rx.recv() {
                        let parsed = parse(&source);
                        if done_tx.send((key, parsed)).is_err() {
                            // The UI is gone; the channel is closed, so do we.
                            break;
                        }
                    }
                });
            match started {
                Ok(_) => Some(Mutex::new(Service {
                    jobs,
                    done,
                    coordinator: Coordinator::new(),
                    cache: Cache::new(),
                })),
                Err(_) => None,
            }
        })
        .as_ref()
}

fn lock() -> Option<std::sync::MutexGuard<'static, Service>> {
    service().map(|m| m.lock().unwrap_or_else(|poisoned| poisoned.into_inner()))
}

fn cached_state(cache: &Cache, key: &Key) -> Option<State> {
    match cache.peek(key) {
        Some(Entry::Document(_)) => Some(State::Ready),
        Some(Entry::PlainFallback(_)) => Some(State::Fallback),
        None => None,
    }
}

/// Hand the coordinator's actions to the worker. **A send that is refused
/// is rolled back**: the slot and its bytes go back and the key is offered
/// again, never silently dropped.
fn send_actions(s: &mut Service, actions: Vec<Action>) {
    for action in actions {
        let Action::Send { key, source } = action;
        if s.jobs.try_send((key.clone(), source)).is_err() {
            s.coordinator.rollback(&key);
        }
    }
}

/// Report what one view can see now. Called from the UI's visible tick; it
/// sends requests and returns at once.
pub fn demand(owner: Owner, items: Vec<(Key, Arc<str>)>) {
    let Some(mut s) = lock() else {
        return;
    };
    let actions = {
        let Service {
            coordinator, cache, ..
        } = &mut *s;
        coordinator.replace_demand(owner, items, &|key| cached_state(cache, key))
    };
    send_actions(&mut s, actions);
}

/// The parsed document for one identity, when the cache holds it. **A
/// shared `Arc`, never a copy**: the view draws from it and drops it again.
pub fn document(key: &Key) -> Option<Arc<polter_chat_markdown::Document>> {
    let s = lock()?;
    match s.cache.peek(key)? {
        Entry::Document(doc) => Some(doc.clone()),
        Entry::PlainFallback(_) => None,
    }
}

/// The view left the page (another group, another page, hidden or
/// minimised): its demand is withdrawn. A request already running finishes
/// and frees its slot; its answer reaches nobody.
pub fn leave(owner: Owner) {
    if let Some(mut s) = lock() {
        s.coordinator.leave(owner);
    }
}

/// Collect up to four answers, keep the documents in the one cache, and
/// return who may repaint. `live` is the UI's answer about an owner -- the
/// service has no window handles.
pub fn poll(live: &dyn Fn(Owner) -> bool) -> Vec<Completion> {
    let Some(mut s) = lock() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for _ in 0..4 {
        let Ok((key, parsed)) = s.done.try_recv() else {
            break;
        };
        let completion = {
            let Service {
                coordinator, cache, ..
            } = &mut *s;
            let Some(completion) = coordinator.complete(&key, &parsed, live) else {
                continue;
            };
            match parsed {
                Parsed::Document(doc) => {
                    cache.insert(key.clone(), Entry::Document(Arc::new(doc)));
                }
                Parsed::PlainFallback(reason) => {
                    cache.insert(key, Entry::PlainFallback(reason));
                }
            }
            completion
        };
        out.push(completion);
        // A slot came free: fill it from what is still waiting.
        let actions = s.coordinator.dispatch();
        send_actions(&mut s, actions);
    }
    out
}
