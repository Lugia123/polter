//! The group chat's transcript, drawn by `web/chat/` in WebView2 (task 3086;
//! the page and its wire contract are `web/chat/CONTRACT.md`, the design
//! `polter-artifacts/engine-2026-11-06/DESIGN-CHAT-TRANSCRIPT-V3.md`).
//!
//! **This is the preview page's shell with the chat's bridge in it.** A
//! custom scheme with an authority, a fresh InPrivate view per page, no
//! network, no new windows, no navigation away -- `plugin_page.rs`'s and
//! `preview_page.rs`'s decisions, made once in `webview_host.rs`; what
//! differs is what `window.polter` is and where the bytes come from.
//!
//! # Where the page's bytes come from
//!
//! **Nowhere on disk.** The five files are `include_bytes!` at compile time
//! (the repository's `web/chat/`, one copy shared with the macOS host), and
//! a request is answered only by an exact match in that table. There is no
//! path to escape: `..`, an absolute path, a backslash, a query and an
//! unknown file all answer 403 rather than being remapped. The macOS host
//! serves the same bytes from its bundle (`GhosttyResources.zig` copies
//! them there); this host holds them in the executable.
//!
//! # What the page can reach
//!
//! `window.polter` / `window.polterChat`, whose `postMessage` is the
//! WebView2 channel (`window.chrome.webview.postMessage`, the alias the
//! contract says the page may write to). The page posts the contract's flat
//! messages (`chat.ready`, `chat.loadOlder`, ...); this module turns them
//! into [`Event`]s for the chat window and nothing else. The host answers
//! with `PostWebMessageAsJson`, which the page listens for on
//! `chrome.webview`'s `message` event.
//!
//! **The host is the truth**: which page is loaded, how many rows, what a
//! link or an image means. The page draws and scrolls; it is told
//! `page.reset` / `page.append` / `page.prepend` / `page.theme` /
//! `page.locate` / `page.image`, and it asks back only through the eight
//! `chat.*` messages the contract names.
//!
//! # The old native list is still here
//!
//! This module never paints the transcript; it owns one child window. When
//! `POLTER_CHAT_WEB=0`, or WebView2 (or its Runtime) is missing, or a page
//! fails to be made, [`showing`] is false and the chat window keeps drawing
//! its own rows -- the same fallback the macOS host has. That is why the
//! switch is read here and not compiled in: the two lists can be compared
//! in one binary.

use std::cell::RefCell;

use polter_settings_shell::plugins::PageState;
use serde_json::{json, Value};
use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::{
    CoreWebView2CustomSchemeRegistration, CoreWebView2EnvironmentOptions,
    CreateCoreWebView2ControllerCompletedHandler, CreateCoreWebView2EnvironmentCompletedHandler,
    NavigationCompletedEventHandler, NavigationStartingEventHandler,
    NewWindowRequestedEventHandler, WebMessageReceivedEventHandler,
    WebResourceRequestedEventHandler,
};
use windows::core::{Interface, PCWSTR, PWSTR};
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::UI::Shell::SHCreateMemStream;
use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, WM_APP};

use crate::webview_host::{probe, take_pwstr, user_data_dir, wide, Loader};

/// The scheme the page is served over. `polter-chat://chat/…` is the page's
/// own origin; the authority is written out because a request for any other
/// host is refused rather than served.
pub const SCHEME: &str = "polter-chat";
const AUTHORITY: &str = "chat";
const ENTRY: &str = "/index.html";

/// Posted to the chat window when the page said something (and, with no
/// events queued, still when it said `chat.ready`). The chat window drains
/// [`take_events`]: **never call back into the chat from inside a WebView2
/// handler** -- the handler runs inside a COM callback, the same rule
/// `plugin_page.rs` writes down.
pub const WM_CHAT_PAGE: u32 = WM_APP + 65;

/// The largest file this host will inline as a `data:` URL. Past it the page
/// keeps its alt text: a 40 MB base64 string through `postMessage` is a
/// stall the reader feels, and an image that big is not something a chat
/// message needs inline.
pub const IMAGE_MAX: u64 = 8 * 1024 * 1024;

/// Whether the page is the list. **Not a build flag**: the same binary can
/// be asked for the native list with `POLTER_CHAT_WEB=0`, which is what
/// makes "the page and the old list disagree" testable on one machine.
pub fn enabled() -> bool {
    !matches!(std::env::var("POLTER_CHAT_WEB"), Ok(v) if v == "0")
}

/// The CSS variables the page's own palette is replaced with
/// (`CONTRACT.md` §3.9). The caller (`chat_native`) builds them from the
/// same `look::Theme` its own drawing uses, so the two lists are one skin.
pub fn theme_object(mode: &str, vars: Value) -> Value {
    let mut out = match vars {
        Value::Object(map) => map,
        _ => serde_json::Map::new(),
    };
    out.insert("mode".into(), Value::String(mode.to_owned()));
    Value::Object(out)
}

/// One host-to-page `page.reset` / `page.prepend`.
pub struct Snapshot {
    /// The page's ids **in document order**, with the JSON each row is sent
    /// as. The ids are what the diff is made from; the JSON is only built
    /// once per change.
    pub messages: Vec<(String, Value)>,
    pub has_earlier: bool,
    /// **The older scan has stopped** (task 3098). A `chat.loadOlder` with
    /// no prepend while this is true is a failure to answer, not a wait.
    pub older_settled: bool,
    /// **The older read's failure**, as `page.prepend.error` (task 3098).
    /// `has_earlier` alone cannot say this -- the page would print "start of
    /// history" over a read that never happened.
    pub older_error: Option<String>,
    pub locale: String,
}

/// What the page asked for. The host decides every one of them; this module
/// only carries the question out of the COM callback.
pub enum Event {
    /// The reader reached the top: ask the feed for an older block.
    LoadOlder,
    OpenLink(String),
    /// The reader clicked a picture (`chat.openImage`, contract §4.8). The
    /// window decides whether it is one from the file's own header; this
    /// module only carries the source out of the COM callback.
    OpenImage(String),
    ImageTicket {
        src: String,
        id: String,
    },
    Follow {
        follow: bool,
        pending: i64,
    },
    Menu {
        id: String,
        x: i64,
        y: i64,
    },
    Copy(String),
    Error(String),
    /// A message this host does not know yet: logged, not dropped silently.
    Unknown(String),
}

struct Page {
    parent: isize,
    generation: u64,
    controller: Option<ICoreWebView2Controller>,
    webview: Option<ICoreWebView2>,
    /// The bounds last set, in the parent's client pixels.
    rect: Option<RECT>,
    visible: bool,
    /// The page said `chat.ready`. Nothing is sent before this.
    ready: bool,
    /// This page cannot be made (no Runtime, no controller, or a refused
    /// creation): **never tried again for this window**, so the old list
    /// stays usable instead of a paint retrying a losing call.
    failed: bool,
    /// The theme most recently handed in, sent before the first reset and
    /// again on every change.
    theme: Option<Value>,
    /// The state a `chat.ready` still owes a `page.reset` for.
    pending: Option<Snapshot>,
    /// **The one reset a ready page is owed has been sent** (task 3098).
    /// **Not `last_ids.is_empty()`**: an empty first screen is a valid reset,
    /// and after it the id list is still empty; keying the first reset off
    /// it would reset once per `sync` on an empty group.
    sent_reset: bool,
    /// **A `chat.loadOlder` the page is still owed a `page.prepend` for**
    /// (task 3098). The answer may be the diff's prepend or an empty one when
    /// the scan has nothing to give.
    awaits_prepend: bool,
    last_ids: Vec<String>,
    last_theme: Option<Value>,
    last_located: Option<String>,
    /// A locate asked for before `chat.ready`; sent once the page is there.
    pending_locate: Option<String>,
    events: Vec<Event>,
}

struct Manager {
    /// Asked once per process: the Runtime does not appear under a running
    /// program.
    probed: Option<(Option<Loader>, PageState)>,
    env: Option<ICoreWebView2Environment>,
    env_pending: bool,
    /// A controller being made for a page that is still wanted.
    waiting: Vec<(isize, u64)>,
    pages: Vec<Page>,
}

thread_local! {
    static MANAGER: RefCell<Manager> = RefCell::new(Manager {
        probed: None,
        env: None,
        env_pending: false,
        waiting: Vec::new(),
        pages: Vec::new(),
    });
}

fn parent_of(parent: HWND) -> isize {
    parent.0 as isize
}

/// The page's record for `parent`, made if it is not there. **Cheap and
/// idempotent**: every entry point may be first (a paint before a tick, a
/// tick before a paint), and the record is what makes the order not
/// matter.
fn touch(parent: HWND) -> bool {
    let key = parent_of(parent);
    MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        if m.pages.iter().any(|p| p.parent == key) {
            return true;
        }
        m.pages.push(Page {
            parent: key,
            generation: 0,
            controller: None,
            webview: None,
            rect: None,
            visible: false,
            ready: false,
            failed: false,
            theme: None,
            pending: None,
            sent_reset: false,
            awaits_prepend: false,
            last_ids: Vec::new(),
            last_theme: None,
            last_located: None,
            pending_locate: None,
            events: Vec::new(),
        });
        true
    })
}

/// A page is being made for this chat window, or is already there.
///
/// **The Runtime's absence is a state, not a crash** (Server 2022 ships
/// without it): the probe answer and every failure become this page's
/// `failed`, which leaves the native list drawing instead.
pub fn open(parent: HWND) {
    if !enabled() {
        return;
    }
    if !touch(parent) {
        return;
    }
    let key = parent_of(parent);
    let (loader, state) = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        match m.probed.clone() {
            Some(x) => x,
            None => {
                let x = probe();
                m.probed = Some(x.clone());
                x
            }
        }
    });
    // **`Loading` is the only state that can make a page** (`plugin_page`
    // reads the same answer the same way): a missing loader and a missing
    // Runtime are both already-decided refusals, and asking anyway would
    // only produce a slower version of the same line.
    let Some(loader) = loader.filter(|_| state == PageState::Loading) else {
        // process-wide: the loader/Runtime is the process's, and this line is
        // the reason the old list is still drawing
        crate::plogf!(
            "[chat-page] no WebView2 ({:?}); the native list stays",
            state
        );
        MANAGER.with(|m| {
            if let Some(p) = m.borrow_mut().pages.iter_mut().find(|p| p.parent == key) {
                p.failed = true;
            }
        });
        return;
    };
    // Already on screen for this window: nothing to make.
    let already = MANAGER.with(|m| {
        m.borrow()
            .pages
            .iter()
            .find(|p| p.parent == key)
            .is_some_and(|p| p.controller.is_some() || p.failed)
    });
    if already {
        return;
    }
    let generation = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        if let Some(p) = m.pages.iter_mut().find(|p| p.parent == key) {
            p.generation += 1;
            p.ready = false;
            p.failed = false;
            // **A snapshot taken before the view existed is still the truth**
            // and is what the first `chat.ready` sends.
            p.last_ids.clear();
            p.last_theme = None;
            p.last_located = None;
            p.generation
        } else {
            0
        }
    });
    let env = MANAGER.with(|m| m.borrow().env.clone());
    match env {
        Some(env) => make_controller(env, key, generation),
        None => make_env(loader, key, generation),
    }
}

/// Bounds and visibility for this paint. `None` takes the page off screen
/// **without closing it** -- a preview pane over it, a popover over it, or
/// no rows to draw: the controller and its state are kept for when the
/// reason passes.
pub fn place_page(parent: HWND, rect: Option<RECT>) {
    let key = parent_of(parent);
    // **The desired bounds are the page's even before its controller
    // exists**: a paint may land first, and the completion must set the size
    // the paint asked for rather than a zero rectangle.
    let (controller, bounds, visible, changed) = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        let Some(p) = m.pages.iter_mut().find(|p| p.parent == key) else {
            return (None, None, false, false);
        };
        match rect {
            Some(r) => {
                let changed = p.rect != Some(r) || !p.visible;
                p.rect = Some(r);
                p.visible = true;
                (p.controller.clone(), Some(r), true, changed)
            }
            None => {
                let changed = p.visible;
                p.visible = false;
                (p.controller.clone(), p.rect, false, changed)
            }
        }
    });
    let Some(ctl) = controller else { return };
    if !changed {
        return;
    }
    unsafe {
        if let Some(r) = bounds {
            let _ = ctl.SetBounds(r);
        }
        let _ = ctl.SetIsVisible(visible);
    }
}

/// Take the page off screen now (the chat window is leaving, or its parent
/// is). The controller is kept: coming back should not reload it.
pub fn hide(parent: HWND) {
    let key = parent_of(parent);
    let ctl = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        let p = m.pages.iter_mut().find(|p| p.parent == key)?;
        p.visible = false;
        p.controller.clone()
    });
    if let Some(ctl) = ctl {
        unsafe {
            let _ = ctl.SetIsVisible(false);
        }
    }
}

/// The page is gone for good: its controller is closed and its record
/// dropped. **Before the parent window is destroyed**, as a child outlives
/// nothing.
pub fn close(parent: HWND) {
    let key = parent_of(parent);
    let ctl = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        m.waiting.retain(|(k, _)| *k != key);
        let index = m.pages.iter().position(|p| p.parent == key)?;
        let page = m.pages.remove(index);
        page.controller
    });
    if let Some(ctl) = ctl {
        unsafe {
            let _ = ctl.Close();
        }
    }
}

/// The theme to send (or to keep for the first reset).
pub fn theme(parent: HWND, value: Value) {
    let key = parent_of(parent);
    let send = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        let Some(p) = m.pages.iter_mut().find(|p| p.parent == key) else {
            return None;
        };
        p.theme = Some(value.clone());
        if p.ready && p.last_theme.as_ref() != Some(&value) {
            p.last_theme = Some(value.clone());
            Some(value)
        } else {
            None
        }
    });
    if let Some(mut value) = send {
        if let Value::Object(map) = &mut value {
            map.insert("type".into(), json!("page.theme"));
        }
        post(parent, value);
    }
}

/// One message a `sync` owes the page (task 3098). **The same value rule the
/// macOS host holds** in `ControlRoomChatTranscriptObligations`; here it is
/// kept out of `Page` and the HWND so a plain unit test can hold it.
#[derive(Debug, PartialEq, Eq)]
pub enum Reply {
    /// The whole document.
    Reset,
    /// The rows from `from` on, one `page.append` each.
    Append { from: usize },
    /// The rows before `up_to` in one `page.prepend`; `up_to == 0` is the
    /// empty answer (the beginning, or a read that failed).
    Prepend {
        up_to: usize,
        has_earlier: bool,
        error: Option<String>,
    },
}

/// **What this sync owes the page.** `sent_reset` and `awaits_prepend` are
/// the page's own state and are updated in place.
///
/// The rule the real machine broke: an empty first screen is still a reset,
/// and a `chat.loadOlder` that yields no rows is still a prepend. Both used
/// to be "nothing to send", which is how a page waits for ever.
fn decide(
    sent_reset: &mut bool,
    awaits_prepend: &mut bool,
    ids: &[String],
    last: &[String],
    has_earlier: bool,
    older_settled: bool,
    older_error: Option<&str>,
) -> Vec<Reply> {
    if !*sent_reset {
        *sent_reset = true;
        return vec![Reply::Reset];
    }
    let mut replies = Vec::new();
    let mut answered = false;
    if ids == last {
        // Nothing moved. (A theme change goes out on its own path.)
    } else if ids.starts_with(last) {
        replies.push(Reply::Append { from: last.len() });
    } else if ids.ends_with(last) {
        replies.push(Reply::Prepend {
            up_to: ids.len() - last.len(),
            has_earlier,
            error: None,
        });
        answered = true;
    } else {
        // A row left from the front (the feed's window trimmed) while another
        // arrived: there is no anchor shared by both ends any more, and the
        // page's ids must match the host's.
        replies.push(Reply::Reset);
        answered = true;
    }
    if *awaits_prepend {
        if answered {
            *awaits_prepend = false;
        } else if older_settled && older_error.is_some() {
            // **A failure is not the beginning**, whatever `has_earlier`
            // says (`page_snapshot` maps a failed scan to false): the page
            // must print the reason, not "start of history" (task 3098).
            *awaits_prepend = false;
            replies.push(Reply::Prepend {
                up_to: 0,
                has_earlier: true,
                error: older_error.map(str::to_owned),
            });
        } else if !has_earlier {
            // Reached the beginning with no rows: the empty prepend **is**
            // the answer (`CONTRACT.md` §3.2).
            *awaits_prepend = false;
            replies.push(Reply::Prepend {
                up_to: 0,
                has_earlier: false,
                error: None,
            });
        } else if older_settled {
            // Stopped without reaching the beginning and without a failure
            // to name (cancelled): still an answer, never silence.
            *awaits_prepend = false;
            replies.push(Reply::Prepend {
                up_to: 0,
                has_earlier: true,
                error: None,
            });
        }
    }
    replies
}

/// The feed's rows, as the page's messages. First `page.reset`, then the
/// smallest message that makes the page agree with this snapshot.
pub fn sync(parent: HWND, snapshot: Snapshot) {
    if !enabled() {
        return;
    }
    if !touch(parent) {
        return;
    }
    let key = parent_of(parent);
    let ready = MANAGER.with(|m| {
        m.borrow()
            .pages
            .iter()
            .find(|p| p.parent == key)
            .is_some_and(|p| p.ready)
    });
    if !ready {
        // **The page has not said `chat.ready` yet**; nothing sent now would
        // be heard. The snapshot is kept and becomes the first reset.
        MANAGER.with(|m| {
            if let Some(p) = m.borrow_mut().pages.iter_mut().find(|p| p.parent == key) {
                p.pending = Some(snapshot);
            }
        });
        return;
    }

    let ids: Vec<String> = snapshot.messages.iter().map(|(id, _)| id.clone()).collect();
    let theme = MANAGER.with(|m| {
        m.borrow()
            .pages
            .iter()
            .find(|p| p.parent == key)
            .and_then(|p| p.theme.clone())
    });
    let (last, mut sent_reset, mut awaits_prepend) = MANAGER.with(|m| {
        let m = m.borrow();
        match m.pages.iter().find(|p| p.parent == key) {
            Some(p) => (p.last_ids.clone(), p.sent_reset, p.awaits_prepend),
            None => (Vec::new(), false, false),
        }
    });

    let Snapshot {
        messages,
        has_earlier,
        older_settled,
        older_error,
        locale,
    } = snapshot;

    let replies = decide(
        &mut sent_reset,
        &mut awaits_prepend,
        &ids,
        &last,
        has_earlier,
        older_settled,
        older_error.as_deref(),
    );
    for reply in &replies {
        match reply {
            Reply::Reset => reset(parent, &messages, has_earlier, &locale),
            Reply::Append { from } => {
                for (_, value) in &messages[*from..] {
                    post(
                        parent,
                        json!({ "type": "page.append", "message": value, "pending": 0 }),
                    );
                }
            }
            Reply::Prepend {
                up_to,
                has_earlier,
                error,
            } => {
                let list: Vec<&Value> = messages[..*up_to].iter().map(|(_, v)| v).collect();
                let mut object = json!({
                    "type": "page.prepend",
                    "messages": list,
                    "hasEarlier": has_earlier,
                });
                if let Some(error) = error {
                    object["error"] = json!(error);
                }
                post(parent, object);
            }
        }
    }

    MANAGER.with(|m| {
        if let Some(p) = m.borrow_mut().pages.iter_mut().find(|p| p.parent == key) {
            p.last_ids = ids;
            p.sent_reset = sent_reset;
            p.awaits_prepend = awaits_prepend;
            if !messages.is_empty() {
                p.last_theme = theme.clone();
            }
        }
    });
}

fn reset(parent: HWND, messages: &[(String, Value)], has_earlier: bool, locale: &str) {
    let key = parent_of(parent);
    let theme = MANAGER.with(|m| {
        m.borrow()
            .pages
            .iter()
            .find(|p| p.parent == key)
            .and_then(|p| p.theme.clone())
    });
    // **`theme` is nested under `theme` here** (`CONTRACT.md` §3.1); only
    // the `page.theme` message carries the variables at the top level
    // (§3.9). The page reads `m.theme` on a reset and `m` itself on a
    // theme.
    let mut object = serde_json::Map::new();
    object.insert("type".into(), json!("page.reset"));
    object.insert(
        "messages".into(),
        Value::Array(messages.iter().map(|(_, v)| v.clone()).collect()),
    );
    if let Some(theme) = theme {
        object.insert("theme".into(), theme);
    }
    object.insert("locale".into(), json!(locale));
    object.insert("hasEarlier".into(), json!(has_earlier));
    post(parent, Value::Object(object));
    MANAGER.with(|m| {
        if let Some(p) = m.borrow_mut().pages.iter_mut().find(|p| p.parent == key) {
            p.last_ids = messages.iter().map(|(id, _)| id.clone()).collect();
            p.last_theme = p.theme.clone();
            // **The one reset a ready page is owed has gone.** Not
            // `last_ids.is_empty()`: an empty reset leaves it empty and the
            // next sync would reset again (task 3098).
            p.sent_reset = true;
        }
    });
}

/// **A `chat.loadOlder` is out; its answer is the next prepend** (task 3098).
pub fn await_prepend(parent: HWND) {
    let key = parent_of(parent);
    MANAGER.with(|m| {
        if let Some(p) = m.borrow_mut().pages.iter_mut().find(|p| p.parent == key) {
            p.awaits_prepend = true;
        }
    });
}

/// **Answer a `chat.loadOlder` the feed had nothing to ask for** (task 3098).
/// The empty prepend is the answer: `hasEarlier: false` is "start of
/// history", and a failed read carries `error` so the page can say so.
pub fn answer_older(parent: HWND, has_earlier: bool, error: Option<&str>) {
    let key = parent_of(parent);
    MANAGER.with(|m| {
        if let Some(p) = m.borrow_mut().pages.iter_mut().find(|p| p.parent == key) {
            p.awaits_prepend = false;
        }
    });
    let mut object = json!({
        "type": "page.prepend",
        "messages": [],
        "hasEarlier": has_earlier,
    });
    if let Some(error) = error {
        object["error"] = json!(error);
    }
    post(parent, object);
}

/// Scroll to one message and light it. A search result or "back to latest"
/// is the only caller today; the answer is `page.locate`.
pub fn locate(parent: HWND, id: &str) {
    let key = parent_of(parent);
    let send = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        let Some(p) = m.pages.iter_mut().find(|p| p.parent == key) else {
            return false;
        };
        // Kept for `chat.ready`: a search click may land while the page is
        // still loading, and the row it named is still the right one.
        p.pending_locate = Some(id.to_owned());
        if !p.ready || p.last_located.as_deref() == Some(id) {
            return false;
        }
        p.last_located = Some(id.to_owned());
        p.pending_locate = None;
        true
    });
    if send {
        post(parent, json!({ "type": "page.locate", "id": id }));
    }
}

/// Answer a `chat.imageTicket` with the file the page cannot read
/// (`CONTRACT.md` §3.8). `src` is echoed back **verbatim**, because that is
/// what the page matches on.
pub fn send_image(parent: HWND, payload: Value) {
    let mut value = payload;
    if let Value::Object(map) = &mut value {
        map.insert("type".into(), json!("page.image"));
    }
    post(parent, value);
}

/// **The answer when the path is not a picture** (`CONTRACT.md` §3.10,
/// task 3098): the page swaps the placeholder for a clickable file link. A
/// silent drop left nothing but the alt text, with no way to tell why.
pub fn send_not_image(parent: HWND, src: &str) {
    post(parent, json!({ "type": "page.notImage", "src": src }));
}

/// Take the questions the page asked since the last drain.
pub fn take_events(parent: HWND) -> Vec<Event> {
    let key = parent_of(parent);
    MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        match m.pages.iter_mut().find(|p| p.parent == key) {
            Some(p) => std::mem::take(&mut p.events),
            None => Vec::new(),
        }
    })
}

/// `chat.imageTicket`'s answer: the file's bytes as a `data:` URL and its
/// pixel size from its header, or `None` -- and then the page keeps the alt
/// text -- when the path is not absolute, the file is missing, too large
/// (`IMAGE_MAX`), cannot be read, or **is not a picture by its own first
/// bytes** (task 3117: a name is not a picture).
pub fn image_payload(src: &str) -> Option<Value> {
    let raw = strip_file_prefix(src);
    let (path, bytes) = read_image_candidate(&raw)?;
    let mime = image_kind(&bytes)?;
    let mut payload = json!({
        "src": src,
        "url": format!("data:{};base64,{}", mime, crate::preview_page::base64(&bytes)),
    });
    if let Some((w, h)) = image_size(&bytes) {
        if let Value::Object(map) = &mut payload {
            map.insert("width".into(), json!(w));
            map.insert("height".into(), json!(h));
        }
    }
    crate::plogf!(
        "[chat-page] image: inlined src={:?} path={:?} decoded={} bytes={}",
        src,
        path,
        raw != path,
        bytes.len()
    );
    Some(payload)
}

/// Remove `file://` and leave the rest as written.
fn strip_file_prefix(src: &str) -> String {
    match src.strip_prefix("file://") {
        Some(rest) => rest.to_owned(),
        None => src.to_owned(),
    }
}

/// **Percent-decoded first, verbatim second** (task 3098). A Windows path in
/// Markdown arrives with `\` written as `%5C` (`C:%5CUsers%5C…%5Cpic.png`),
/// and `metadata("C:%5C…")` simply fails. The **decoded** candidate is tried
/// first; the raw one stays as a second chance so a path that really contains
/// `%` is not rewritten. Which one was used is in the log line.
fn image_candidates(raw: &str) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(decoded) = percent_decode(raw) {
        if decoded != raw {
            out.push(decoded);
        }
    }
    out.push(raw.to_owned());
    out
}

/// A percent-decode of a path, or `None` when an escape is malformed.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hi = *bytes.get(i + 1)?;
            let lo = *bytes.get(i + 2)?;
            let value = u8::from_str_radix(std::str::from_utf8(&[hi, lo]).ok()?, 16).ok()?;
            out.push(value);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The first candidate that is a readable file within `IMAGE_MAX` **whose
/// own first bytes are a picture** (task 3117). The extension is never the
/// check: a 30-byte text file named `fake.png` used to be inlined and drawn
/// as a broken image, while the click route (`local_image_path`) already
/// judged it by its header -- one file, two answers.
///
/// The bytes judged here are the same bytes handed back, so the payload can
/// never be of a different file than the one whose header was read.
fn read_image_candidate(raw: &str) -> Option<(String, Vec<u8>)> {
    for path in image_candidates(raw) {
        // `file:///C:/…` loses its drive colon to the prefix strip; a path
        // that is neither absolute nor drive-qualified is not one this host
        // reads.
        if !path.starts_with('/') && !path.contains(':') {
            continue;
        }
        if path.ends_with('/') {
            continue;
        }
        let size = match std::fs::metadata(&path) {
            Ok(meta) => meta.len(),
            Err(_) => continue,
        };
        if size > IMAGE_MAX {
            crate::plogf!(
                "[chat-page] image: too large path={:?} bytes={}",
                path,
                size
            );
            continue;
        }
        match std::fs::read(&path) {
            Ok(bytes) => {
                if image_kind(&bytes).is_none() {
                    crate::plogf!(
                        "[chat-page] image: not a picture by its header path={:?} bytes={}",
                        path,
                        bytes.len()
                    );
                    continue;
                }
                return Some((path, bytes));
            }
            Err(_) => continue,
        }
    }
    None
}

/// **Whether this path names a picture this host will open**, from its own
/// first bytes -- the Windows half of the macOS host's `isImagePath`.
///
/// The clicked-picture route (`chat.openImage`, and a Markdown link that
/// points at one) uses this instead of handing the path to the reference
/// preview. That preview is the core's ticket, judged against the chat's
/// workdir (`files/Tickets.zig`), so a picture kept outside it (a screenshot
/// in `/tmp`, or anywhere under the user's profile) is refused *by design* --
/// **this is the one place a chat path deliberately steps around that
/// boundary**, and it does so only for a picture the host has itself read the
/// header of. `None` means "not a picture": the caller must neither open it
/// nor fall back to a preview, so this adds no route for opening arbitrary
/// local files with a system program.
///
/// `~` is not expanded here, matching `image_payload` above: a `~` path does
/// not inline on this host today either, and the opening route stays in step
/// with what the transcript drew.
pub fn local_image_path(src: &str) -> Option<String> {
    let raw = strip_file_prefix(src);
    for path in image_candidates(&raw) {
        // `file:///C:/…` loses its drive colon to the prefix strip; a path
        // that is neither absolute nor drive-qualified is not one this host
        // reads.
        if !path.starts_with('/') && !path.contains(':') {
            continue;
        }
        if path.ends_with('/') {
            continue;
        }
        let size = match std::fs::metadata(&path) {
            Ok(meta) => meta.len(),
            Err(_) => continue,
        };
        if size > IMAGE_MAX {
            continue;
        }
        let mut head = [0u8; 16];
        let mut file = match std::fs::File::open(&path) {
            Ok(file) => file,
            Err(_) => continue,
        };
        use std::io::Read;
        let Ok(read) = file.read(&mut head) else {
            continue;
        };
        if image_kind(&head[..read]).is_some() {
            return Some(path);
        }
    }
    None
}

/// **The picture's MIME type from its own first bytes, or `None`** -- the
/// one judgement both routes use now: inlining (`read_image_candidate`) and
/// opening a click (`local_image_path`). A name is not a picture (task
/// 3117), and the same set is the one the macOS host's `imageMIME` uses:
/// PNG `89 50 4E 47`, JPEG `FF D8 FF`, GIF `GIF8`, WebP `RIFF….WEBP`, BMP
/// `BM`, TIFF `II*\0` / `MM\0*`, HEIC `ftyp` + a HEIF brand.
///
/// **SVG is deliberately absent**, matching the macOS host: it is text, a
/// local SVG is a file link rather than an inline image, and accepting it
/// here would add a type the page would draw from markup.
///
/// A short slice (`head` may be fewer bytes than `read` returned) simply
/// fails every check that would read past its end.
fn image_kind(head: &[u8]) -> Option<&'static str> {
    if head.starts_with(b"\x89PNG") {
        return Some("image/png");
    }
    if head.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }
    if head.starts_with(b"GIF8") {
        return Some("image/gif");
    }
    if head.len() >= 12 && head.starts_with(b"RIFF") && &head[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if head.starts_with(b"BM") {
        return Some("image/bmp");
    }
    if head.starts_with(b"II*\0") || head.starts_with(b"MM\0*") {
        return Some("image/tiff");
    }
    if head.len() >= 12
        && &head[4..8] == b"ftyp"
        && matches!(&head[8..12], b"heic" | b"heix" | b"heif" | b"mif1")
    {
        return Some("image/heic");
    }
    None
}

/// Width and height from a file's own header, where this host knows the
/// format. **Best effort**: the page reserves a box from these numbers so a
/// late image does not move what is being read, and a format it does not
/// know simply arrives without them (`<img onload>` compensates).
fn image_size(bytes: &[u8]) -> Option<(u32, u32)> {
    // PNG: signature, then the IHDR chunk's two big-endian lengths.
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes.get(12..16) == Some(b"IHDR") {
        let w = u32::from_be_bytes(bytes.get(16..20)?.try_into().ok()?);
        let h = u32::from_be_bytes(bytes.get(20..24)?.try_into().ok()?);
        return Some((w, h));
    }
    // GIF: the logical screen descriptor, little-endian.
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        let w = u16::from_le_bytes(bytes.get(6..8)?.try_into().ok()?) as u32;
        let h = u16::from_le_bytes(bytes.get(8..10)?.try_into().ok()?) as u32;
        return Some((w, h));
    }
    // BMP: a BITMAPINFOHEADER's signed sizes.
    if bytes.starts_with(b"BM") && bytes.len() >= 26 {
        let w = i32::from_le_bytes(bytes.get(18..22)?.try_into().ok()?);
        let h = i32::from_le_bytes(bytes.get(22..26)?.try_into().ok()?).abs();
        if w > 0 && h > 0 {
            return Some((w as u32, h as u32));
        }
    }
    // JPEG: walk the markers to a start-of-frame segment.
    if bytes.starts_with(&[0xFF, 0xD8]) {
        let mut i = 2usize;
        while i + 9 < bytes.len() {
            if bytes[i] != 0xFF {
                i += 1;
                continue;
            }
            let marker = bytes[i + 1];
            // SOF0..SOF15 except C4 (Huffman tables), C8 (reserved), CC (arith).
            if (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
                let h = u16::from_be_bytes(bytes.get(i + 5..i + 7)?.try_into().ok()?) as u32;
                let w = u16::from_be_bytes(bytes.get(i + 7..i + 9)?.try_into().ok()?) as u32;
                if w > 0 && h > 0 {
                    return Some((w, h));
                }
                return None;
            }
            let len = u16::from_be_bytes(bytes.get(i + 2..i + 4)?.try_into().ok()?) as usize;
            if len < 2 {
                return None;
            }
            i += 2 + len;
        }
    }
    None
}

// -- the WebView2 side -----------------------------------------------------

fn make_env(loader: Loader, key: isize, generation: u64) {
    let start = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        m.waiting.retain(|(k, _)| *k != key);
        m.waiting.push((key, generation));
        !std::mem::replace(&mut m.env_pending, true)
    });
    if !start {
        return;
    }
    let reg = CoreWebView2CustomSchemeRegistration::new(SCHEME.to_string());
    unsafe {
        reg.set_treat_as_secure(true);
        reg.set_has_authority_component(true);
    }
    let options = CoreWebView2EnvironmentOptions::default();
    unsafe { options.set_scheme_registrations(vec![Some(reg.into())]) };
    let options: ICoreWebView2EnvironmentOptions = options.into();
    let handler =
        CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(move |hr, env| {
            let waiting = MANAGER.with(|m| {
                let mut m = m.borrow_mut();
                m.env_pending = false;
                std::mem::take(&mut m.waiting)
            });
            match (hr, env) {
                (Ok(()), Some(env)) => {
                    MANAGER.with(|m| m.borrow_mut().env = Some(env.clone()));
                    for (key, generation) in waiting {
                        let live = MANAGER.with(|m| {
                            m.borrow()
                                .pages
                                .iter()
                                .any(|p| p.parent == key && p.generation == generation && !p.failed)
                        });
                        if live {
                            make_controller(env.clone(), key, generation);
                        }
                    }
                }
                (r, _) => {
                    let hr = r.err().map(|e| e.code().0).unwrap_or(-1);
                    for (key, generation) in waiting {
                        failed(key, generation, "environment", hr);
                    }
                }
            }
            Ok(())
        }));
    let folder = user_data_dir().map(|d| wide(&d.display().to_string()));
    let folder_ptr = folder
        .as_ref()
        .map(|w| PCWSTR(w.as_ptr()))
        .unwrap_or(PCWSTR::null());
    let hr = unsafe {
        (loader.create)(
            PCWSTR::null(),
            folder_ptr,
            options.as_raw(),
            handler.as_raw(),
        )
    };
    if hr.is_err() {
        let waiting = MANAGER.with(|m| {
            let mut m = m.borrow_mut();
            m.env_pending = false;
            std::mem::take(&mut m.waiting)
        });
        for (key, generation) in waiting {
            failed(key, generation, "environment", hr.0);
        }
    }
}

fn failed(key: isize, generation: u64, what: &str, hr: i32) {
    // process-wide: the message names the chat window
    crate::plogf!(
        "[chat-page] {:?}: making the {} failed: 0x{:08X}; the native list stays",
        key,
        what,
        hr as u32
    );
    MANAGER.with(|m| {
        if let Some(p) = m
            .borrow_mut()
            .pages
            .iter_mut()
            .find(|p| p.parent == key && p.generation == generation)
        {
            p.failed = true;
        }
    });
}

fn make_controller(env: ICoreWebView2Environment, key: isize, generation: u64) {
    let parent = HWND(key as *mut std::ffi::c_void);
    let handler = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(move |hr, ctl| {
        let Some(ctl) = ctl.filter(|_| hr.is_ok()) else {
            failed(
                key,
                generation,
                "view",
                hr.err().map(|e| e.code().0).unwrap_or(-1),
            );
            return Ok(());
        };
        let live = MANAGER.with(|m| {
            m.borrow()
                .pages
                .iter()
                .any(|p| p.parent == key && p.generation == generation && !p.failed)
        });
        if !live {
            unsafe {
                let _ = ctl.Close();
            }
            return Ok(());
        }
        if let Err(e) = configure(&ctl, key, generation) {
            unsafe {
                let _ = ctl.Close();
            }
            failed(key, generation, "view", e.code().0);
            return Ok(());
        }
        let placed = MANAGER.with(|m| {
            let mut m = m.borrow_mut();
            m.pages
                .iter_mut()
                .find(|p| p.parent == key && p.generation == generation)
                .map(|p| {
                    // **Desired visibility is the page's**, not "a controller
                    // just arrived": a hide while it was being made must not
                    // be undone.
                    let answer = (p.rect, p.visible);
                    p.controller = Some(ctl.clone());
                    answer
                })
        });
        let Some((rect, visible)) = placed else {
            unsafe {
                let _ = ctl.Close();
            }
            return Ok(());
        };
        if let Some(rect) = rect {
            unsafe {
                let _ = ctl.SetBounds(rect);
                let _ = ctl.SetIsVisible(visible);
            }
        }
        let _ = unsafe { windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false) };
        Ok(())
    }));
    // InPrivate: nothing the page stores outlives it or reaches the next
    // chat's page (`websiteDataStore = .nonPersistent()` on the macOS side).
    let with_options = env
        .cast::<ICoreWebView2Environment10>()
        .ok()
        .and_then(|e10| {
            let o = unsafe { e10.CreateCoreWebView2ControllerOptions() }.ok()?;
            unsafe { o.SetIsInPrivateModeEnabled(true) }.ok()?;
            Some((e10, o))
        });
    let r = match with_options {
        Some((e10, o)) => unsafe {
            e10.CreateCoreWebView2ControllerWithOptions(parent, &o, &handler)
        },
        None => {
            // process-wide: the one WebView2 Runtime
            crate::plogf!(
                "[chat-page] this runtime has no controller options; the page is not InPrivate"
            );
            unsafe { env.CreateCoreWebView2Controller(parent, &handler) }
        }
    };
    if let Err(e) = r {
        failed(key, generation, "view", e.code().0);
    }
}

fn configure(
    ctl: &ICoreWebView2Controller,
    key: isize,
    generation: u64,
) -> windows::core::Result<()> {
    let wv = unsafe { ctl.CoreWebView2()? };
    unsafe {
        let settings = wv.Settings()?;
        settings.SetAreDevToolsEnabled(false)?;
        settings.SetAreDefaultContextMenusEnabled(false)?;
        settings.SetIsStatusBarEnabled(false)?;
        settings.SetIsWebMessageEnabled(true)?;
        settings.SetIsScriptEnabled(true)?;
        settings.SetAreHostObjectsAllowed(false)?;

        // Every request, whatever its scheme, comes here. Ours is answered
        // from the compiled-in table; everything else -- http, file:, a
        // second scheme -- is 403 (no network, twice over with the CSP).
        let all = wide("*");
        wv.AddWebResourceRequestedFilter(
            PCWSTR(all.as_ptr()),
            COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
        )?;
        let mut tok = 0i64;
        wv.add_WebResourceRequested(
            &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
                if page_live(key, generation) {
                    if let Some(args) = args {
                        serve(&args);
                    }
                }
                Ok(())
            })),
            &mut tok,
        )?;

        // A link to anywhere but this page does nothing: handled in the
        // page as `chat.openLink`, and refused here if it tries anyway.
        wv.add_NavigationStarting(
            &NavigationStartingEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    let mut uri = PWSTR::null();
                    let _ = args.Uri(&mut uri);
                    let uri = take_pwstr(uri);
                    if !uri.starts_with(&format!("{SCHEME}://{AUTHORITY}/")) {
                        let _ = args.SetCancel(true);
                        // process-wide: the page is the one the chat window shows
                        crate::plogf!("[chat-page] navigated to {:?} refused", uri);
                    }
                }
                Ok(())
            })),
            &mut tok,
        )?;

        // No new windows: `window.open` and `target=_blank` get nothing.
        wv.add_NewWindowRequested(
            &NewWindowRequestedEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    let _ = args.SetHandled(true);
                }
                Ok(())
            })),
            &mut tok,
        )?;

        // The load's own verdict, so a page that did not arrive is a line
        // rather than an empty rectangle.
        wv.add_NavigationCompleted(
            &NavigationCompletedEventHandler::create(Box::new(move |_, args| {
                let Some(args) = args else { return Ok(()) };
                let mut ok = windows::core::BOOL(0);
                match args.IsSuccess(&mut ok) {
                    Ok(()) if ok.as_bool() => {
                        crate::plogf!("[chat-page] loaded {SCHEME}://{AUTHORITY}{ENTRY}");
                    }
                    Ok(()) => {
                        let mut status = COREWEBVIEW2_WEB_ERROR_STATUS::default();
                        let _ = args.WebErrorStatus(&mut status);
                        crate::plogf!("[chat-page] load failed: web error {}", status.0);
                    }
                    Err(e) => {
                        crate::plogf!("[chat-page] load failed: {:?}", e);
                    }
                }
                Ok(())
            })),
            &mut tok,
        )?;

        wv.add_WebMessageReceived(
            &WebMessageReceivedEventHandler::create(Box::new(move |_, args| {
                if !page_live(key, generation) {
                    return Ok(());
                }
                if let Some(args) = args {
                    on_message(key, &args);
                }
                Ok(())
            })),
            &mut tok,
        )?;

        let script = wide(BRIDGE);
        wv.AddScriptToExecuteOnDocumentCreated(PCWSTR(script.as_ptr()), None)?;
        let url = wide(&entry_url());
        wv.Navigate(PCWSTR(url.as_ptr()))?;
        MANAGER.with(|m| {
            if let Some(p) = m
                .borrow_mut()
                .pages
                .iter_mut()
                .find(|p| p.parent == key && p.generation == generation)
            {
                p.webview = Some(wv.clone());
            }
        });
    }
    // process-wide: the chat window's page
    crate::plogf!("[chat-page] {}: view made, loading {}", key, entry_url());
    Ok(())
}

fn page_live(key: isize, generation: u64) -> bool {
    MANAGER.with(|m| {
        m.borrow()
            .pages
            .iter()
            .any(|p| p.parent == key && p.generation == generation && !p.failed)
    })
}

fn entry_url() -> String {
    format!("{SCHEME}://{AUTHORITY}{ENTRY}")
}

/// What the page finds on `window`: the two names the contract mentions,
/// both posting through WebView2's own channel. **Frozen**: the page assigns
/// `window.polterChat` itself later (its own `receive`), so that one is
/// configurable; `window.polter` is not, and is the one `chat.js` prefers.
const BRIDGE: &str = r#"(function () {
  if (window.top !== window) return;
  if (!window.chrome || !window.chrome.webview) return;
  var wv = window.chrome.webview;
  var bridge = {
    protocol: 2,
    postMessage: function (obj) { wv.postMessage(obj); },
    receive: function (obj) { window.postMessage(obj, "*"); },
    sent: []
  };
  try {
    Object.defineProperty(window, "polter", {
      value: bridge, writable: false, configurable: false, enumerable: true
    });
  } catch (e) { window.polter = bridge; }
  if (!window.polterChat) window.polterChat = bridge;
})();"#;

/// The page's five files, compiled in. **One copy, shared with the macOS
/// host**: the repository's `web/chat/` (design §一: "两端按字节一致嵌入").
const ASSETS: &[(&str, &[u8], &str)] = &[
    (
        "/index.html",
        include_bytes!("../../../web/chat/index.html"),
        "text/html; charset=utf-8",
    ),
    (
        "/chat.css",
        include_bytes!("../../../web/chat/chat.css"),
        "text/css; charset=utf-8",
    ),
    (
        "/chat.js",
        include_bytes!("../../../web/chat/chat.js"),
        "text/javascript; charset=utf-8",
    ),
    (
        "/vendor/marked.min.js",
        include_bytes!("../../../web/chat/vendor/marked.min.js"),
        "text/javascript; charset=utf-8",
    ),
    (
        "/vendor/highlight.min.js",
        include_bytes!("../../../web/chat/vendor/highlight.min.js"),
        "text/javascript; charset=utf-8",
    ),
];

/// The request's path under this page's origin, or `None` when it is not
/// this page's origin at all.
///
/// **Exact spelling only**: the host is `chat`, there is no query or
/// fragment, no backslash, no `:` and no `.`/`..` segment. The bytes served
/// are a table lookup, so nothing outside it can be reached even if one of
/// those rules were written wrongly.
fn path_of(uri: &str) -> Option<&str> {
    let rest = uri.strip_prefix(SCHEME)?.strip_prefix("://")?;
    let (host, _) = rest.split_once('/')?;
    if host != AUTHORITY {
        return None;
    }
    let path = &rest[rest.find('/')?..];
    let path = path.split(['?', '#']).next()?;
    if path.contains('\\') || path.contains(':') {
        return None;
    }
    for seg in path.split('/') {
        if seg == "." || seg == ".." {
            return None;
        }
    }
    Some(path)
}

fn asset(uri: &str) -> (u16, &'static str, &'static [u8], &'static str) {
    match path_of(uri) {
        Some(path) => match ASSETS.iter().find(|(name, _, _)| *name == path) {
            Some((_, bytes, ctype)) => (200, "OK", bytes, ctype),
            None => (404, "Not Found", &[], "text/plain"),
        },
        None => (403, "Forbidden", &[], "text/plain"),
    }
}

/// The `Content-Security-Policy` sent with every response
/// (`CONTRACT.md` §1). `connect-src 'none'` is the one that matters most:
/// no `fetch`, no `XMLHttpRequest`, no `WebSocket` -- the page gets its data
/// from the host's messages and nowhere else. `polter-file:` is there for
/// an image ticket the host chose not to inline; `data:` for one it did.
fn csp() -> String {
    "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; \
img-src 'self' data: polter-chat: polter-file:; font-src 'self'; connect-src 'none'; \
frame-src 'none'; object-src 'none'; media-src 'none'; form-action 'none'; \
base-uri 'none'; frame-ancestors 'none'"
        .to_owned()
}

fn serve(args: &ICoreWebView2WebResourceRequestedEventArgs) {
    let env = MANAGER.with(|m| m.borrow().env.clone());
    let Some(env) = env else { return };
    let uri = match unsafe { args.Request() } {
        Ok(request) => {
            let mut u = PWSTR::null();
            let _ = unsafe { request.Uri(&mut u) };
            take_pwstr(u)
        }
        Err(_) => String::new(),
    };
    let (status, reason, body, ctype) = asset(&uri);
    // Refusals are the ones worth a line; a 200 for the five known files is
    // the page working.
    if status != 200 {
        crate::plogf!("[chat-page] serve {} -> {} ({})", uri, status, reason);
    }
    let headers = format!(
        "Content-Type: {ctype}\r\nContent-Security-Policy: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff",
        csp()
    );
    let stream = unsafe { SHCreateMemStream(Some(body)) };
    let reason = wide(reason);
    let headers = wide(&headers);
    if let Ok(resp) = unsafe {
        env.CreateWebResourceResponse(
            stream.as_ref(),
            status.into(),
            PCWSTR(reason.as_ptr()),
            PCWSTR(headers.as_ptr()),
        )
    } {
        let _ = unsafe { args.SetResponse(&resp) };
    }
}

fn on_message(key: isize, args: &ICoreWebView2WebMessageReceivedEventArgs) {
    let mut src = PWSTR::null();
    let _ = unsafe { args.Source(&mut src) };
    let source = take_pwstr(src);
    if !source.starts_with(&format!("{SCHEME}://{AUTHORITY}/")) {
        crate::plogf!("[chat-page] message from {:?} ignored", source);
        return;
    }
    let mut j = PWSTR::null();
    let _ = unsafe { args.WebMessageAsJson(&mut j) };
    let text = take_pwstr(j);
    let Ok(msg) = serde_json::from_str::<Value>(&text) else {
        crate::plogf!("[chat-page] bridge: malformed message {}", text);
        return;
    };
    let kind = msg.get("type").and_then(Value::as_str).unwrap_or("");
    // **Every bridge message is a line** (task 3086's instrument): what the
    // page asked and what the host answered are read from here, not guessed
    // from what the window looks like.
    crate::plogf!("[chat-page] bridge: recv {}", kind);

    let mut event = None;
    match kind {
        "chat.ready" => {
            let protocol = msg.get("protocol").and_then(Value::as_i64).unwrap_or(-1);
            crate::plogf!("[chat-page] ready protocol={}", protocol);
            let pending = MANAGER.with(|m| {
                let mut m = m.borrow_mut();
                let Some(p) = m.pages.iter_mut().find(|p| p.parent == key) else {
                    return None;
                };
                p.ready = true;
                p.pending.take()
            });
            if let Some(snapshot) = pending {
                reset(
                    HWND(key as *mut std::ffi::c_void),
                    &snapshot.messages,
                    snapshot.has_earlier,
                    &snapshot.locale,
                );
            }
            // A locate asked for while the page was loading goes out now,
            // after the reset, so it has rows to land on.
            let located = MANAGER.with(|m| {
                let mut m = m.borrow_mut();
                let p = m.pages.iter_mut().find(|p| p.parent == key)?;
                let id = p.pending_locate.take()?;
                p.last_located = Some(id.clone());
                Some(id)
            });
            if let Some(id) = located {
                post(
                    HWND(key as *mut std::ffi::c_void),
                    json!({ "type": "page.locate", "id": id }),
                );
            }
        }
        "chat.loadOlder" => event = Some(Event::LoadOlder),
        "chat.openLink" => {
            event = Some(Event::OpenLink(
                msg.get("href")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
            ))
        }
        "chat.openImage" => {
            event = Some(Event::OpenImage(
                msg.get("src")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
            ))
        }
        // **Two requests, one answer** (`CONTRACT.md` §4.7): a Markdown
        // image and a bare path in the prose are the same question. The page
        // sends both; neither may be answered with silence (§3.10).
        "chat.imageTicket" | "chat.image" => {
            event = Some(Event::ImageTicket {
                src: msg
                    .get("src")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
                id: msg
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
            })
        }
        "chat.follow" => {
            event = Some(Event::Follow {
                follow: msg.get("follow").and_then(Value::as_bool).unwrap_or(false),
                pending: msg.get("pending").and_then(Value::as_i64).unwrap_or(0),
            })
        }
        // **Part of the shared page protocol, accepted here and not acted
        // on** (task 3096; `CONTRACT.md` §12, a known difference). The page
        // reports its reading and its "back to latest"; this host does not
        // keep a place yet, so it ignores the one and the page's own scroll
        // is the whole answer to the other. **Not `Unknown`**: a message the
        // protocol defines is not a page this host failed to understand.
        "chat.reading" | "chat.jumpLatest" => {}
        "chat.restoreFailed" => {
            crate::plogf!(
                "[chat-page] reading: restore failed why={:?}",
                msg.get("why")
            );
        }
        "chat.menu" => {
            event = Some(Event::Menu {
                id: msg
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
                x: msg.get("x").and_then(Value::as_i64).unwrap_or(0),
                y: msg.get("y").and_then(Value::as_i64).unwrap_or(0),
            })
        }
        "chat.copy" => {
            event = Some(Event::Copy(
                msg.get("text")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
            ))
        }
        "chat.error" => {
            event = Some(Event::Error(
                msg.get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
            ))
        }
        other => event = Some(Event::Unknown(other.to_owned())),
    }
    let queued = MANAGER.with(|m| {
        let mut m = m.borrow_mut();
        match m.pages.iter_mut().find(|p| p.parent == key) {
            Some(p) => {
                if let Some(event) = event {
                    p.events.push(event);
                }
                true
            }
            None => false,
        }
    });
    if queued {
        let _ = unsafe {
            PostMessageW(
                Some(HWND(key as *mut std::ffi::c_void)),
                WM_CHAT_PAGE,
                windows::Win32::Foundation::WPARAM(0),
                windows::Win32::Foundation::LPARAM(0),
            )
        };
    }
}

/// One host-to-page message. `PostWebMessageAsJson` takes the JSON text the
/// page's `chrome.webview` listener parses; **the JSON is built here** and
/// never concatenated by hand.
fn post(parent: HWND, value: Value) {
    let key = parent_of(parent);
    let wv = MANAGER.with(|m| {
        m.borrow()
            .pages
            .iter()
            .find(|p| p.parent == key)
            .and_then(|p| p.webview.clone())
    });
    let Some(wv) = wv else {
        // process-wide: the page for this chat window
        crate::plogf!(
            "[chat-page] {}: no view to send {:?}",
            key,
            value.get("type")
        );
        return;
    };
    crate::plogf!(
        "[chat-page] bridge: send {}",
        value.get("type").and_then(Value::as_str).unwrap_or("?")
    );
    let text = wide(&value.to_string());
    if let Err(e) = unsafe { wv.PostWebMessageAsJson(PCWSTR(text.as_ptr())) } {
        crate::plogf!("[chat-page] {}: send failed: {:?}", key, e);
    }
}

#[cfg(test)]
mod obligations {
    use super::{decide, Reply};

    fn ids(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    /// **An empty first screen is a reset** (task 3098). The old rule sent
    /// one only when there were rows or more history; on a slow feed that
    /// was never true, and the page waited for ever.
    #[test]
    fn an_empty_first_sync_is_still_a_reset() {
        let (mut sent, mut awaits) = (false, false);
        let replies = decide(&mut sent, &mut awaits, &[], &[], false, true, None);
        assert_eq!(replies, vec![Reply::Reset]);
        assert!(sent);
    }

    /// **Not `last_ids.is_empty()`**: after the empty reset the ids are still
    /// empty, and a second empty sync must send nothing.
    #[test]
    fn a_second_empty_sync_sends_nothing() {
        let (mut sent, mut awaits) = (true, false);
        let replies = decide(&mut sent, &mut awaits, &[], &[], true, true, None);
        assert!(replies.is_empty());
    }

    /// The scan reached the beginning with no rows: the empty prepend is the
    /// answer, with `hasEarlier: false`.
    #[test]
    fn an_older_read_that_ends_empty_is_answered() {
        let (mut sent, mut awaits) = (true, true);
        let replies = decide(
            &mut sent,
            &mut awaits,
            &ids(&["m1"]),
            &ids(&["m1"]),
            false,
            true,
            None,
        );
        assert_eq!(
            replies,
            vec![Reply::Prepend {
                up_to: 0,
                has_earlier: false,
                error: None
            }]
        );
        assert!(!awaits);
    }

    /// A scan that is still out is not an answer yet.
    #[test]
    fn an_older_read_still_running_is_not_answered() {
        let (mut sent, mut awaits) = (true, true);
        let replies = decide(
            &mut sent,
            &mut awaits,
            &ids(&["m1"]),
            &ids(&["m1"]),
            true,
            false,
            None,
        );
        assert!(replies.is_empty());
        assert!(awaits);
    }

    /// A failed read is an explicit answer carrying its reason.
    #[test]
    fn a_failed_older_read_carries_its_reason() {
        let (mut sent, mut awaits) = (true, true);
        let replies = decide(
            &mut sent,
            &mut awaits,
            &ids(&["m1"]),
            &ids(&["m1"]),
            true,
            true,
            Some("BadParams"),
        );
        assert_eq!(
            replies,
            vec![Reply::Prepend {
                up_to: 0,
                has_earlier: true,
                error: Some("BadParams".to_owned()),
            }]
        );
        assert!(!awaits);
    }

    /// **A failure outranks `has_earlier: false`**: `page_snapshot` maps a
    /// failed scan to false, but the page must still say "could not read"
    /// rather than "start of history" (task 3098).
    #[test]
    fn a_failed_older_read_is_not_the_beginning() {
        let (mut sent, mut awaits) = (true, true);
        let replies = decide(
            &mut sent,
            &mut awaits,
            &ids(&["m1"]),
            &ids(&["m1"]),
            false,
            true,
            Some("BadParams"),
        );
        assert_eq!(
            replies,
            vec![Reply::Prepend {
                up_to: 0,
                has_earlier: true,
                error: Some("BadParams".to_owned()),
            }]
        );
    }

    /// Rows arrived in front: that prepend is the answer.
    #[test]
    fn prepended_rows_are_the_answer() {
        let (mut sent, mut awaits) = (true, true);
        let replies = decide(
            &mut sent,
            &mut awaits,
            &ids(&["m0", "m1"]),
            &ids(&["m1"]),
            true,
            true,
            None,
        );
        assert_eq!(
            replies,
            vec![Reply::Prepend {
                up_to: 1,
                has_earlier: true,
                error: None
            }]
        );
        assert!(!awaits);
    }

    /// A live append and an older read that ended empty in one pass owe two
    /// messages; the prepend is the older answer.
    #[test]
    fn an_append_and_an_older_end_in_one_pass_are_two_replies() {
        let (mut sent, mut awaits) = (true, true);
        let replies = decide(
            &mut sent,
            &mut awaits,
            &ids(&["m1", "m2"]),
            &ids(&["m1"]),
            false,
            true,
            None,
        );
        assert_eq!(
            replies,
            vec![
                Reply::Append { from: 1 },
                Reply::Prepend {
                    up_to: 0,
                    has_earlier: false,
                    error: None
                },
            ]
        );
        assert!(!awaits);
    }
}

/// **A name is not a picture** (task 3117): the inline route and the click
/// route must give the same answer about the same bytes. These tests judge
/// the header alone, plus the two routes through a real file on disk.
#[cfg(test)]
mod pictures {
    use super::{image_kind, read_image_candidate, IMAGE_MAX};

    /// The first 16 bytes of a PNG: signature, `IHDR` chunk length, `IHDR`.
    /// 16 because that is exactly what the click route reads.
    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
    /// 30 bytes of plain text -- the file the Windows test seat shipped as
    /// `fake.png` and watched arrive as `image: inlined … bytes=30`.
    const TEXT: &[u8] = b"this is not a picture at all!\n";

    fn temp_file(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("polter-3117-{}-{}", std::process::id(), name));
        std::fs::write(&path, bytes).expect("write the fixture");
        path
    }

    fn remove(path: &std::path::Path) {
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_png_header_is_png() {
        assert_eq!(image_kind(PNG), Some("image/png"));
    }

    #[test]
    fn each_known_header_gets_its_mime() {
        assert_eq!(image_kind(b"\xFF\xD8\xFF\xE0"), Some("image/jpeg"));
        assert_eq!(image_kind(b"GIF89a"), Some("image/gif"));
        assert_eq!(
            image_kind(b"RIFF\x00\x00\x00\x00WEBPVP8 "),
            Some("image/webp")
        );
        assert_eq!(image_kind(b"BM\x00\x00"), Some("image/bmp"));
        assert_eq!(image_kind(b"II*\x00"), Some("image/tiff"));
        assert_eq!(image_kind(b"MM\x00*"), Some("image/tiff"));
        assert_eq!(image_kind(b"\x00\x00\x00\x18ftypheic"), Some("image/heic"));
    }

    /// **The defect's judgement**: the same 30 bytes, no matter the name.
    #[test]
    fn thirty_bytes_of_text_is_not_a_picture() {
        assert_eq!(TEXT.len(), 30);
        assert_eq!(image_kind(TEXT), None);
    }

    #[test]
    fn an_empty_head_is_not_a_picture() {
        assert_eq!(image_kind(b""), None);
    }

    /// Shorter than the shortest signature it would need to match: PNG needs
    /// four bytes, JPEG three.
    #[test]
    fn a_head_shorter_than_the_magic_is_not_a_picture() {
        assert_eq!(image_kind(b"\x89PN"), None);
        assert_eq!(image_kind(b"\xFF\xD8"), None);
        assert_eq!(image_kind(b"GI"), None);
        // A RIFF container that is not WebP is not a picture either.
        assert_eq!(image_kind(b"RIFF\x00\x00\x00\x00WAVE"), None);
    }

    /// **This is the defect** (task 3117): 30 bytes of text under a `.png`
    /// name. Judged by the name it inlines as a broken image; judged by the
    /// header it is `None`, and the caller answers `page.notImage`.
    #[test]
    fn a_text_file_named_png_is_not_a_candidate() {
        let path = temp_file("fake.png", TEXT);
        let answer = read_image_candidate(path.to_str().expect("utf-8 temp path"));
        remove(&path);
        assert_eq!(answer, None);
    }

    /// The other direction, so the answer cannot be "never inline": a PNG
    /// header in a file whose name says otherwise is still a picture.
    #[test]
    fn a_png_header_under_a_txt_name_is_a_candidate() {
        let path = temp_file("picture.txt", PNG);
        let answer = read_image_candidate(path.to_str().expect("utf-8 temp path"));
        remove(&path);
        match answer {
            Some((got, bytes)) => {
                assert_eq!(got, path.to_str().expect("utf-8 temp path"));
                assert_eq!(bytes, PNG);
            }
            None => panic!("a PNG header in a .txt file was refused"),
        }
    }

    /// The whole inline route names the type it read, not the name it saw.
    #[test]
    fn an_inlined_png_says_image_png() {
        let path = temp_file("inline.txt", PNG);
        let payload = crate::chat_page::image_payload(path.to_str().expect("utf-8 temp path"));
        remove(&path);
        let url = payload
            .as_ref()
            .and_then(|payload| payload["url"].as_str())
            .unwrap_or_default()
            .to_owned();
        assert!(url.starts_with("data:image/png;base64,"), "url={url}");
    }

    /// A file larger than `IMAGE_MAX` is refused before its bytes are read,
    /// so a name cannot get past the cap either.
    #[test]
    fn a_file_over_the_cap_is_not_a_candidate() {
        let path = temp_file("huge.png", &vec![0u8; IMAGE_MAX as usize + 1]);
        let answer = read_image_candidate(path.to_str().expect("utf-8 temp path"));
        remove(&path);
        assert_eq!(answer, None);
    }
}
