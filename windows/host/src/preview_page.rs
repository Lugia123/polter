//! A file preview, in WebView2, beside the terminal it is about (task 2628,
//! #2140 W1; `polter-artifacts/2145/PLAN.md` §2.1 and §3.2).
//!
//! **This is the plugin page's shell with the other bridge in it.** The
//! surrounding decisions -- a custom scheme with an authority, a fresh
//! InPrivate view per page, no network, no new windows, no navigation away
//! -- are `plugin_page.rs`'s and `PluginPage.swift`'s, made once in
//! `webview_host.rs`; what differs is what `window.polter` is and where the
//! bytes come from, and that is all this file is.
//!
//! # Where a previewed file's bytes come from
//!
//! **Never from a path the host worked out.** A preview is served over
//! `polter-file://<token>/<rel>`; the token is a capability the core minted
//! for one workdir and one scope (`src/poltergeist/files/Tickets.zig`, task
//! 2573), and every single request goes back through `ghostty_app_files` to
//! the core's `files_resolve(token, rel)`, which judges `rel` against *that
//! ticket* again and answers the real path -- or a refusal. The host reads
//! only the path it was given. Which ticket and which `rel` is
//! `polter_preview_route::resolve`'s (the same table the macOS host runs).
//!
//! # What the page can reach
//!
//! `window.polter`, with the eight calls `polter_preview_route::Call` names:
//! `info`, `read`, `readRel`, `openPath`, `watch`, `look`, `propose`,
//! `dirty`. **There is no `write`, no `create`, no `delete`, no `rename`, no
//! `exec` and no `fetch`.** Writing happens only through the core's
//! `files_commit`, and only after the person has chosen on the host's own
//! change screen -- `propose` is not a write, it hands the text over.
//!
//! `window.chrome.webview.postMessage` is the transport, as in
//! `plugin_page.rs`; the script aliases it to `window.polter` so a plugin
//! author writes one thing for both hosts.

// ⚠️ **A file-level allow, and it is a statement about this file and not a
// habit.** When it was written nothing called `show`/`hide`: putting a
// preview in the workdirs page was M2/W2 (#2140), one task later, and the
// evidence that the allow was about reachability rather than decay was that
// `cargo check` reported all 22 items as `never used` **including `serve`,
// `ask_core` and `BRIDGE`** -- the three that carry the file's whole
// behaviour (measured 2026-11-01, 22 of 29).
//
// **Task 3148 is that M2/W2 call site** -- the workdirs page shows one
// preview in `SlotKey::workdir` and closes it when the page goes -- so the
// allow now covers what is still genuinely unused (the chat's own paths are
// in `chat_native.rs`), and the compiler's account of what is left is worth
// reading: run `cargo check` and the `never used` list is shorter than 22.
// `windows/host/src/ffi.rs` carries the same allow for the same shape of
// reason (declarations that belong together, consumers a task behind).
#![allow(dead_code)]

use std::cell::RefCell;

use polter_preview_route::{content_type, Call, Refused, SCHEME};
use polter_settings_shell::plugins::PageState;
use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::{
    CoreWebView2CustomSchemeRegistration, CoreWebView2EnvironmentOptions,
    CreateCoreWebView2ControllerCompletedHandler, CreateCoreWebView2EnvironmentCompletedHandler,
    NavigationStartingEventHandler, NewWindowRequestedEventHandler, WebMessageReceivedEventHandler,
    WebResourceRequestedEventHandler,
};
use windows::core::{Interface, PCWSTR, PWSTR};
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::UI::Shell::SHCreateMemStream;

use crate::webview_host::{probe, take_keyboard_back, take_pwstr, user_data_dir, wide, Loader};

/// The custom scheme this host registers a second time for the preview, on
/// top of the plugin page's. **WebView2 registers schemes per environment**,
/// and the two pages share one environment (`webview_host::user_data_dir`),
/// so both are registered when either is made -- see `make_env`.
pub const PREVIEW_SCHEME: &str = SCHEME;
/// The plugin page's assets, for a `render:"page"` descriptor. **A scheme of
/// its own**, so a plugin page and a previewed file never share an origin.
pub const PAGE_SCHEME: &str = "polter-preview-plugin";

/// Where the terminator is: the amount the page is told about one file. Sizes
/// beyond it come back through `info` with `truncated: true` rather than
/// being silently short.
pub const READ_MAX: usize = 4 << 20;

/// Which part of the product a preview belongs to. **A group's preview and
/// the working directory's are different owners**, never one page reused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SlotKind {
    Chat,
    Workdir,
}

/// One preview slot's owner. **The parent window is part of the key**: the
/// same group watched in two native pages must not share one controller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlotKey {
    pub kind: SlotKind,
    /// The group's name for a chat slot; `None` for the working directory.
    pub group: Option<String>,
    pub parent: isize,
}

impl SlotKey {
    pub fn chat(group: &str, parent: HWND) -> SlotKey {
        SlotKey {
            kind: SlotKind::Chat,
            group: Some(group.to_owned()),
            parent: parent.0 as isize,
        }
    }

    pub fn workdir(parent: HWND) -> SlotKey {
        SlotKey {
            kind: SlotKind::Workdir,
            group: None,
            parent: parent.0 as isize,
        }
    }

    fn parent(&self) -> HWND {
        HWND(self.parent as *mut std::ffi::c_void)
    }
}

/// Why a slot cannot be made now. **An explicit refusal is the only
/// alternative to closing a page the person is looking at.**
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShowError {
    /// All resident slots are visible and the budget is full.
    Budget,
    /// Another slot already owns this ticket; this one refuses rather
    /// than share or steal it.
    AlreadyOwned,
    /// The core said a **matched** plugin shows this file and named a
    /// `render` this host has no page for, or a `page` with no location.
    /// **No raw-file fallback**: the file could be drawn, and drawing it
    /// would say "the plugin is fine" about a page that is not there. A
    /// file *no* plugin claims is not this case -- it is the file itself
    /// (task 3148, `show`'s header).
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PageAssets {
    dir: String,
    page: String,
}

/// One resident preview: its controller, the ticket it shows and the
/// generation a late completion is checked against.
struct Preview {
    controller: Option<ICoreWebView2Controller>,
    /// The ticket being shown, or being made for.
    token: Option<String>,
    rect: RECT,
    generation: u64,
    state: PageState,
    /// `Some` when the core chose a plugin page rather than the file itself.
    page: Option<PageAssets>,
    visible: bool,
    /// A controller creation is in flight for this slot/generation.
    creating: bool,
    /// Last time this slot was shown/used, for LRU eviction of hidden
    /// slots only.
    used: u64,
}

struct Manager {
    /// Asked once per process, as the plugin page's is.
    probed: Option<(Option<Loader>, PageState)>,
    /// One environment for every slot: WebView2 registers the custom
    /// schemes once per environment, and the plugin pages share it too.
    env: Option<ICoreWebView2Environment>,
    env_pending: bool,
    /// Controller creations waiting for the shared environment. Keyed by
    /// slot; a later show for the same slot replaces the older request.
    waiting: Vec<(SlotKey, u64, String)>,
    slots: Vec<(SlotKey, Preview)>,
    /// A monotonic "last used" for eviction and nothing else.
    tick: u64,
}

/// 1 working directory + 4 groups. **Only a hidden slot may be evicted.**
pub const MAX_RESIDENT_SLOTS: usize = 5;

thread_local! {
    static SLOTS: RefCell<Manager> = RefCell::new(Manager {
        probed: None,
        env: None,
        env_pending: false,
        waiting: Vec::new(),
        slots: Vec::new(),
        tick: 0,
    });
}

fn slot_index(manager: &Manager, key: &SlotKey) -> Option<usize> {
    manager.slots.iter().position(|(k, _)| k == key)
}

/// Who holds a ticket, as far as the ledger can be read right now.
enum Owner {
    /// No slot names it; the caller's unadopted ticket.
    Unowned,
    /// A slot holds it; the caller must not close it.
    Held(SlotKey),
    /// The ledger is borrowed elsewhere and cannot be read. **This is not
    /// "unowned"**: a close is deferred until the question can be answered.
    Unknown,
}

thread_local! {
    /// Closes that arrived while the slot ledger was borrowed. A separate
    /// cell so they can be retried without needing the ledger.
    static DEFERRED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

fn defer_close(token: &str) {
    DEFERRED.with(|d| {
        if let Ok(mut d) = d.try_borrow_mut() {
            if !d.iter().any(|t| t == token) {
                d.push(token.to_owned());
            }
        }
    });
}

/// Retry every close deferred while the ledger was busy. Called whenever
/// the ledger is readable again and from the page's own tick.
pub fn flush_deferred() {
    let tokens: Vec<String> = DEFERRED.with(|d| std::mem::take(&mut *d.borrow_mut()));
    let mut again: Vec<String> = Vec::new();
    for token in tokens {
        match token_owner(&token) {
            Owner::Unowned => close_token(&token),
            Owner::Held(_) => {
                crate::plogf!("[preview] {}: not closing a ticket another slot owns", token);
            }
            Owner::Unknown => again.push(token),
        }
    }
    if !again.is_empty() {
        DEFERRED.with(|d| d.borrow_mut().extend(again));
    }
}

#[cfg(test)]
fn deferred_len() -> usize {
    DEFERRED.with(|d| d.borrow().len())
}

fn token_owner(token: &str) -> Owner {
    SLOTS.with(|m| match m.try_borrow() {
        Ok(m) => match m
            .slots
            .iter()
            .find(|(_, slot)| slot.token.as_deref() == Some(token))
        {
            Some((key, _)) => Owner::Held(key.clone()),
            None => Owner::Unowned,
        },
        Err(_) => Owner::Unknown,
    })
}

fn slot_generation(key: &SlotKey) -> Option<u64> {
    SLOTS.with(|m| {
        m.try_borrow()
            .ok()
            .and_then(|m| slot_index(&m, key).map(|i| m.slots[i].1.generation))
    })
}

/// What this slot can show now, or `None` when no preview has been asked
/// for there.
pub fn state(key: &SlotKey) -> Option<PageState> {
    SLOTS.with(|m| {
        m.try_borrow().ok().and_then(|m| {
            slot_index(&m, key).and_then(|i| {
                let slot = &m.slots[i].1;
                slot.token.as_ref().map(|_| slot.state.clone())
            })
        })
    })
}

/// Whether this slot is showing a preview, and which ticket.
pub fn showing(key: &SlotKey) -> Option<String> {
    SLOTS.with(|m| {
        m.try_borrow()
            .ok()
            .and_then(|m| slot_index(&m, key).and_then(|i| m.slots[i].1.token.clone()))
    })
}

/// Close one ticket through the core door. **Ledger and view may not
/// disagree**: a slot that stops showing a ticket closes it exactly once.
fn close_token(token: &str) {
    if token.is_empty() {
        return;
    }
    if let Err(why) = ask_core("files_close", serde_json::json!({ "token": token })) {
        // process-wide: the ticket is the core's; a refusal is logged and
        // the host holds nothing that could retry it.
        crate::plogf!("[preview] {}: closing the ticket failed: {}", token, why);
    }
}

/// Close a ticket `show` refused to adopt. **The caller keeps the ticket it
/// minted** and hands it back here; a refused adopt must not leak it.
pub fn close_unowned(token: &str) {
    // An earlier close that found the ledger busy gets its retry first.
    flush_deferred();
    match token_owner(token) {
        // **Never close another slot's ticket**: a refused adopt is only
        // ours when nobody owns it.
        Owner::Held(_) => {
            crate::plogf!(
                "[preview] {}: not closing a ticket another slot owns",
                token
            );
        }
        // **Busy is not "nobody owns it".** The effect waits for a ledger
        // that can answer instead of leaking or closing the wrong ticket.
        Owner::Unknown => {
            crate::plogf!(
                "[preview] {}: the ticket ledger is busy; close deferred",
                token
            );
            defer_close(token);
        }
        Owner::Unowned => close_token(token),
    }
}

/// Drop a slot's controller and ticket.
fn close_preview(slot: &mut Preview) {
    if let Some(ctl) = slot.controller.take() {
        unsafe {
            let _ = ctl.Close();
        }
    }
    if let Some(token) = slot.token.take() {
        close_token(&token);
    }
    slot.state = PageState::Loading;
    slot.visible = false;
    slot.creating = false;
}

/// Show the file behind `token` in `rect` for `key`. **The token and plugin
/// description must come from the core's reference answer**; this function
/// cannot turn a path into either.
///
/// # What a file with no plugin on it is
///
/// **The file itself, in the view's own frame** (task 3148; the macOS
/// host's `.file`). The whole of that path was already here: with no page
/// assets the view is navigated to `entry_url(token)` -- `polter-file://
/// <token>/` -- and every request goes back to the core's `files_resolve`
/// for the ticket's own `rel`, which answers with the real path and this
/// host reads it with `polter_preview_route::content_type`'s type. So
/// "no plugin answers for this file" is **not a refusal any more**; it is
/// the preview a file had before plugins could claim one.
///
/// **A `matched` plugin whose `render` this host has no page for is still
/// refused**, and deliberately: the file is there and could be drawn, and
/// drawing it would be exactly the silent fallback the macOS host's
/// `.unavailable` exists to prevent -- "the plugin is broken" and "the
/// plugin is fine, its page is here" would draw the same picture.
pub fn show(
    key: SlotKey,
    rect: RECT,
    token: &str,
    plugin: Option<&serde_json::Value>,
) -> Result<(), ShowError> {
    let parent = key.parent();
    // **The core says what kind of view this is.** A matched plugin names
    // its page; every other answer -- `status:"none"`, a plugin asked for by
    // name that was not found or is off, or a core from before the field --
    // is the file itself. Which of those it was is the core's to say and is
    // not a difference this host draws: a file nothing claimed is the file.
    let matched = plugin.filter(|p| p.get("status").and_then(|s| s.as_str()) == Some("matched"));
    let page_assets = match matched {
        None => None,
        // **A `render` that is there and is not `page` is the file itself**
        // (`browser`, or a tag this build has no page for): the macOS host's
        // `pageLocation(of:)` answers `.notAPagePlugin` for exactly that, and
        // its `.browser` is the file too. **A `render` that is not there at
        // all is a refusal** -- the core did not say how the file is shown,
        // and a host that guessed would be deciding it (`.renderUnknown`).
        Some(plugin) => match plugin.get("render").and_then(|r| r.as_str()) {
            None | Some("") => return Err(ShowError::Unsupported),
            Some("page") => {
                let dir = plugin
                    .get("plugin_dir")
                    .and_then(|d| d.as_str())
                    .ok_or(ShowError::Unsupported)?;
                let page = plugin
                    .get("page")
                    .and_then(|p| p.as_str())
                    .ok_or(ShowError::Unsupported)?;
                Some(PageAssets {
                    dir: dir.to_owned(),
                    page: page.to_owned(),
                })
            }
            Some(_) => None,
        },
    };
    // **One ticket, one owner.** A second slot gets an explicit refusal
    // and the owning slot is not touched; the caller may mint another
    // ticket for a different slot.
    match token_owner(token) {
        Owner::Held(owner) if owner != key => return Err(ShowError::AlreadyOwned),
        // **A ledger that cannot answer is not permission**: adopting into
        // unknown ownership is refused rather than guessed.
        Owner::Unknown => return Err(ShowError::AlreadyOwned),
        _ => {}
    }
    let (loader, st) = SLOTS.with(|m| {
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
    let Some(loader) = loader.filter(|_| st == PageState::Loading) else {
        // **No Runtime: the old ticket/controller still go through the
        // same replace rule**, then the slot says why it cannot show.
        let old = SLOTS.with(
            |m| -> Result<(Option<ICoreWebView2Controller>, Option<String>), ShowError> {
                let mut m = m.borrow_mut();
                m.tick += 1;
                let tick = m.tick;
                let i = match slot_index(&m, &key) {
                    Some(i) => i,
                    None => {
                        if m.slots.len() >= MAX_RESIDENT_SLOTS {
                            let hidden = m
                                .slots
                                .iter()
                                .enumerate()
                                .filter(|(_, (_, s))| !s.visible)
                                .min_by_key(|(_, (_, s))| s.used)
                                .map(|(i, _)| i);
                            let Some(i) = hidden else {
                                return Err(ShowError::Budget);
                            };
                            let mut old = m.slots.remove(i);
                            close_preview(&mut old.1);
                        }
                        m.slots.push((
                            key.clone(),
                            Preview {
                                controller: None,
                                token: None,
                                rect,
                                generation: tick,
                                state: st.clone(),
                                page: None,
                                visible: true,
                                creating: false,
                                used: tick,
                            },
                        ));
                        m.slots.len() - 1
                    }
                };
                let slot = &mut m.slots[i].1;
                slot.rect = rect;
                slot.visible = true;
                slot.used = tick;
                if slot.token.as_deref() == Some(token) {
                    slot.state = st.clone();
                    return Ok((None, None));
                }
                slot.generation = tick;
                slot.state = st.clone();
                let old_ctl = slot.controller.take();
                let old_token = slot.token.replace(token.to_owned());
                Ok((old_ctl, old_token))
            },
        );
        let (old_ctl, old_token) = old?;
        if let Some(ctl) = old_ctl {
            unsafe {
                let _ = ctl.Close();
            }
        }
        if let Some(old) = old_token {
            close_token(&old);
        }
        unsafe {
            let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false);
        }
        return Ok(());
    };

    enum Place {
        Reuse(Option<ICoreWebView2Controller>, u64),
        Create(u64, Option<ICoreWebView2Environment>),
        Refused,
    }
    let place = SLOTS.with(|m| -> Place {
        let mut m = m.borrow_mut();
        m.tick += 1;
        let tick = m.tick;
        let i = match slot_index(&m, &key) {
            Some(i) => i,
            None => {
                if m.slots.len() >= MAX_RESIDENT_SLOTS {
                    let hidden = m
                        .slots
                        .iter()
                        .enumerate()
                        .filter(|(_, (_, s))| !s.visible)
                        .min_by_key(|(_, (_, s))| s.used)
                        .map(|(i, _)| i);
                    let Some(i) = hidden else {
                        return Place::Refused;
                    };
                    let mut old = m.slots.remove(i);
                    close_preview(&mut old.1);
                }
                m.slots.push((
                    key.clone(),
                    Preview {
                        controller: None,
                        token: None,
                        rect,
                        generation: tick,
                        state: PageState::Loading,
                        page: None,
                        visible: true,
                        creating: false,
                        used: tick,
                    },
                ));
                m.slots.len() - 1
            }
        };
        // **Read what the queue says before borrowing the slot**; they
        // are two fields of the same manager.
        let pending = m.slots[i].1.generation;
        let same_token = m.slots[i].1.token.as_deref() == Some(token);
        let creating = m
            .waiting
            .iter()
            .any(|(k, g, t)| k == &key && *g == pending && t == token);
        let slot = &mut m.slots[i].1;
        slot.rect = rect;
        slot.page = page_assets.clone();
        slot.visible = true;
        slot.used = tick;
        if same_token && (slot.controller.is_some() || creating || slot.creating) {
            let ctl = slot.controller.clone();
            return Place::Reuse(ctl, pending);
        }
        if !same_token {
            // Replace inside this slot: close the old resources exactly
            // once after this borrow.
            let old_ctl = slot.controller.take();
            let old_token = slot.token.replace(token.to_owned());
            // Closing inside the borrow is only a COM Close; the token
            // goes out through the ticket ledger in the same step.
            if let Some(ctl) = old_ctl {
                unsafe {
                    let _ = ctl.Close();
                }
            }
            if let Some(old) = old_token {
                close_token(&old);
            }
        }
        // A retry (Failed, or hidden with no controller) still gets a real
        // generation and a fresh creation request.
        slot.generation = tick;
        slot.state = PageState::Loading;
        slot.creating = true;
        let env = m.env.clone();
        Place::Create(tick, env)
    });
    match place {
        Place::Refused => Err(ShowError::Budget),
        Place::Reuse(controller, generation) => {
            let _ = generation;
            if let Some(ctl) = controller {
                unsafe {
                    let _ = ctl.SetBounds(rect);
                    let _ = ctl.SetIsVisible(true);
                    let _ =
                        windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false);
                }
            }
            Ok(())
        }
        Place::Create(generation, env) => {
            let token = token.to_owned();
            match env {
                Some(env) => make_controller(env, key, generation, token),
                None => make_env(loader, key, generation, token),
            }
            Ok(())
        }
    }
}
/// Take this slot off screen. Other slots -- another group, the working
/// directory, another parent window -- are untouched.
pub fn hide(key: &SlotKey) {
    let (ctl, parent) = SLOTS.with(|m| {
        let m = m.borrow();
        match slot_index(&m, key) {
            Some(i) => {
                let slot = &m.slots[i].1;
                (slot.controller.clone(), key.parent())
            }
            None => (None, key.parent()),
        }
    });
    SLOTS.with(|m| {
        if let Ok(mut m) = m.try_borrow_mut() {
            if let Some(i) = slot_index(&m, key) {
                m.slots[i].1.visible = false;
            }
        }
    });
    if let Some(ctl) = ctl {
        unsafe {
            let _ = ctl.SetIsVisible(false);
        }
        take_keyboard_back(parent);
    }
}

/// Forget one slot entirely: its controller and its ticket.
pub fn close(key: &SlotKey) {
    let gone = SLOTS.with(|m| {
        let mut m = m.borrow_mut();
        m.waiting.retain(|(k, _, _)| k != key);
        slot_index(&m, key).map(|i| m.slots.remove(i))
    });
    if let Some((_, mut slot)) = gone {
        close_preview(&mut slot);
    }
}

/// Every slot in one window: what a destroyed native page releases.
pub fn close_all_for_parent(parent: HWND) {
    let gone: Vec<(SlotKey, Preview)> = SLOTS.with(|m| {
        let mut m = m.borrow_mut();
        let want = parent.0 as isize;
        let (keep, gone) = m.slots.drain(..).partition(|(key, _)| key.parent != want);
        m.slots = keep;
        m.waiting.retain(|(key, _, _)| key.parent != want);
        gone
    });
    for (_, mut slot) in gone {
        close_preview(&mut slot);
    }
}

pub fn hide_all_for_parent(parent: HWND) {
    let keys: Vec<SlotKey> = SLOTS.with(|m| {
        m.borrow()
            .slots
            .iter()
            .filter(|(key, slot)| key.parent == parent.0 as isize && slot.visible)
            .map(|(key, _)| key.clone())
            .collect()
    });
    for key in keys {
        hide(&key);
    }
}

fn make_env(loader: Loader, key: SlotKey, generation: u64, token: String) {
    // **Every waiter is remembered**, not only the first: one shared
    // environment serves all of them when it is ready.
    let start = SLOTS.with(|m| {
        let mut m = m.borrow_mut();
        if let Some(env) = m.env.clone() {
            return (Some(env), false);
        }
        m.waiting.retain(|(k, _, _)| k != &key);
        // A show for a slot that has since been evicted/closed does not
        // hold a queue entry.
        let live: Vec<SlotKey> = m.slots.iter().map(|(k, _)| k.clone()).collect();
        m.waiting.retain(|(k, _, _)| live.contains(k));
        m.waiting.push((key.clone(), generation, token.clone()));
        if std::mem::replace(&mut m.env_pending, true) {
            (None, false)
        } else {
            (None, true)
        }
    });
    if let Some(env) = start.0 {
        make_controller(env, key, generation, token);
        return;
    }
    if !start.1 {
        return;
    }
    let mut regs: Vec<Option<ICoreWebView2CustomSchemeRegistration>> = Vec::new();
    for scheme in [
        PREVIEW_SCHEME,
        PAGE_SCHEME,
        polter_settings_shell::plugins::SCHEME,
    ] {
        let reg = CoreWebView2CustomSchemeRegistration::new(scheme.to_string());
        unsafe {
            reg.set_treat_as_secure(true);
            reg.set_has_authority_component(true);
        }
        regs.push(Some(reg.into()));
    }
    let options = CoreWebView2EnvironmentOptions::default();
    unsafe { options.set_scheme_registrations(regs) };
    let options: ICoreWebView2EnvironmentOptions = options.into();
    let handler =
        CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(move |hr, env| {
            let waiting = SLOTS.with(|m| {
                let mut m = m.borrow_mut();
                m.env_pending = false;
                std::mem::take(&mut m.waiting)
            });
            match (hr, env) {
                (Ok(()), Some(env)) => {
                    SLOTS.with(|m| m.borrow_mut().env = Some(env.clone()));
                    for (key, generation, token) in waiting {
                        let live = SLOTS.with(|m| {
                            m.borrow().slots.iter().any(|(k, slot)| {
                                k == &key
                                    && slot.generation == generation
                                    && slot.token.as_deref() == Some(token.as_str())
                            })
                        });
                        if live {
                            make_controller(env.clone(), key, generation, token);
                        }
                    }
                }
                (r, _) => {
                    let hr = r.err().map(|e| e.code().0).unwrap_or(-1);
                    for (key, generation, _) in waiting {
                        failed(&key, generation, "environment", hr);
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
        let waiting = SLOTS.with(|m| {
            let mut m = m.borrow_mut();
            m.env_pending = false;
            std::mem::take(&mut m.waiting)
        });
        for (key, generation, _) in waiting {
            failed(&key, generation, "environment", hr.0);
        }
    }
}
/// A failure is this slot's, not the process's: another page's preview is
/// untouched.
fn failed(key: &SlotKey, generation: u64, what: &str, hr: i32) {
    // process-wide: the message names the slot
    crate::plogf!(
        "[preview] {:?}/{:?}: making the {} failed: 0x{:08X}",
        key.kind,
        key.group,
        what,
        hr as u32
    );
    let parent = key.parent();
    let mine = SLOTS.with(|m| {
        let mut m = m.borrow_mut();
        match slot_index(&m, key) {
            Some(i) if m.slots[i].1.generation == generation => {
                m.slots[i].1.state = PageState::Failed(hr);
                m.slots[i].1.creating = false;
                true
            }
            _ => false,
        }
    });
    if mine {
        unsafe {
            let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false);
        }
    }
}

fn make_controller(env: ICoreWebView2Environment, key: SlotKey, generation: u64, token: String) {
    let parent = key.parent();
    let made_key = key.clone();
    let made_token = token.clone();
    let handler = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(move |hr, ctl| {
        let Some(ctl) = ctl.filter(|_| hr.is_ok()) else {
            failed(
                &made_key,
                generation,
                "view",
                hr.err().map(|e| e.code().0).unwrap_or(-1),
            );
            return Ok(());
        };
        // **The slot, the generation and the ticket all have to still be
        // the ones this controller was made for.** A late completion for a
        // closed or replaced slot closes what it made and shows nothing.
        let live = SLOTS.with(|m| {
            m.borrow().slots.iter().any(|(k, slot)| {
                k == &made_key
                    && slot.generation == generation
                    && slot.token.as_deref() == Some(made_token.as_str())
            })
        });
        if !live {
            unsafe {
                let _ = ctl.Close();
            }
            return Ok(());
        }
        if let Err(e) = configure(&ctl, &made_token, generation, &made_key) {
            unsafe {
                let _ = ctl.Close();
            }
            failed(&made_key, generation, "view", e.code().0);
            return Ok(());
        }
        let placed = SLOTS.with(|m| {
            let mut m = m.borrow_mut();
            match slot_index(&m, &made_key) {
                Some(i)
                    if m.slots[i].1.generation == generation
                        && m.slots[i].1.token.as_deref() == Some(made_token.as_str()) =>
                {
                    m.slots[i].1.controller = Some(ctl.clone());
                    m.slots[i].1.state = PageState::Ready;
                    m.slots[i].1.creating = false;
                    // **Desired visibility is the slot's**, not "a
                    // controller just arrived": a hide while it was being
                    // made must not be undone.
                    Some((m.slots[i].1.rect, m.slots[i].1.visible))
                }
                _ => None,
            }
        });
        if let Some((rect, visible)) = placed {
            unsafe {
                let _ = ctl.SetBounds(rect);
                let _ = ctl.SetIsVisible(visible);
                if visible {
                    let _ =
                        windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false);
                }
            }
        } else {
            unsafe {
                let _ = ctl.Close();
            }
        }
        Ok(())
    }));
    // InPrivate: nothing the preview stores outlives it or reaches the next
    // file's page (`websiteDataStore = .nonPersistent()` on the macOS side).
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
            // process-wide: as above
            crate::plogf!(
                "[preview] this runtime has no controller options; the preview is not InPrivate"
            );
            unsafe { env.CreateCoreWebView2Controller(parent, &handler) }
        }
    };
    if let Err(e) = r {
        failed(&key, generation, "view", e.code().0);
    }
}

fn slot_page(key: &SlotKey) -> Option<PageAssets> {
    SLOTS.with(|m| {
        m.try_borrow()
            .ok()
            .and_then(|m| slot_index(&m, key).and_then(|i| m.slots[i].1.page.clone()))
    })
}

/// The token in either of this preview's two schemes' URIs.
fn uri_token(uri: &str) -> Option<&str> {
    let rest = uri
        .strip_prefix(PREVIEW_SCHEME)
        .or_else(|| uri.strip_prefix(PAGE_SCHEME))?
        .strip_prefix("://")?;
    Some(rest.split('/').next().unwrap_or(""))
}

fn encode_segment(segment: &str) -> String {
    let mut out = String::new();
    for byte in segment.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn decode_segment(segment: &str) -> Option<String> {
    let bytes = segment.as_bytes();
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

/// The page path, percent-encoded **one segment at a time**, so a space or
/// a Chinese name is a path and not a query.
fn page_entry_url(token: &str, assets: &PageAssets) -> String {
    let path = assets
        .page
        .split('/')
        .map(encode_segment)
        .collect::<Vec<_>>()
        .join("/");
    format!("{PAGE_SCHEME}://{token}/{path}")
}

/// The page scheme's path segments, decoded exactly once, for **this**
/// token. A query/fragment is not part of a file name; `..`, `.`, an empty
/// segment, a decoded separator, a drive-ish `:` and an invalid escape are
/// refused rather than silently remapped. The host is the ticket, so a page
/// can only name its own directory.
fn page_segments(uri: &str, token: &str) -> Option<Vec<String>> {
    let rest = uri.strip_prefix(PAGE_SCHEME)?.strip_prefix("://")?;
    let mut parts = rest.splitn(2, '/');
    let host = parts.next()?;
    if host != token {
        return None;
    }
    let path = parts.next().unwrap_or("");
    let path = path.split(['?', '#']).next().unwrap_or("");
    if path.is_empty() {
        return None;
    }
    let mut out = Vec::new();
    for seg in path.split('/') {
        let decoded = decode_segment(seg)?;
        if decoded.is_empty()
            || decoded == "."
            || decoded == ".."
            || decoded.contains(['/', '\\', ':', '\0'])
        {
            return None;
        }
        out.push(decoded);
    }
    Some(out)
}

/// The answer for one request in the page scheme: the URL's own segments,
/// read under the page's directory, and the **plugin** MIME table. Split
/// out from `serve` so the entry URL, the file read and the response type
/// are one tested chain.
fn page_asset(uri: &str, token: &str, dir: &str) -> (u16, &'static str, Vec<u8>, &'static str) {
    let Some(segs) = page_segments(uri, token) else {
        return (403, "Forbidden", Vec::new(), "text/plain");
    };
    match crate::webview_host::read_inside(std::path::Path::new(dir), &segs) {
        Some(bytes) => (
            200,
            "OK",
            bytes,
            polter_settings_shell::plugins::content_type(
                segs.last().map(String::as_str).unwrap_or(""),
            ),
        ),
        None => (404, "Not Found", Vec::new(), "text/plain"),
    }
}

fn configure(
    ctl: &ICoreWebView2Controller,
    token: &str,
    generation: u64,
    key: &SlotKey,
) -> windows::core::Result<()> {
    unsafe {
        let wv = ctl.CoreWebView2()?;
        let settings = wv.Settings()?;
        settings.SetAreDevToolsEnabled(false)?;
        settings.SetAreDefaultContextMenusEnabled(false)?;
        settings.SetIsStatusBarEnabled(false)?;
        settings.SetIsWebMessageEnabled(true)?;
        settings.SetIsScriptEnabled(true)?;
        // A previewed file may be a page that links out. `PLAN.md` §2.3:
        // `window.open` goes to the core's link policy, which hands http,
        // https and mailto to the system browser and refuses the rest --
        // that policy is the host's and is not built here, so a new window
        // is refused as it is for a plugin page.
        settings.SetAreHostObjectsAllowed(false)?;

        // Every request, whatever its scheme, comes here. Ours are the
        // preview's; everything else -- http, file:, the plugin scheme --
        // is answered 403 (no network, twice over with the CSP header).
        let all = wide("*");
        wv.AddWebResourceRequestedFilter(
            PCWSTR(all.as_ptr()),
            COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
        )?;
        let t = token.to_string();
        let guard = key.clone();
        let mut tok = 0i64;
        wv.add_WebResourceRequested(
            &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
                if slot_generation(&guard) != Some(generation) {
                    return Ok(());
                }
                if let Some(args) = args {
                    serve(&args, &t, &guard.clone());
                }
                Ok(())
            })),
            &mut tok,
        )?;

        // A link to anywhere but this scheme does nothing. A preview is not
        // a browser, and a page that navigated would leave the slot showing
        // a blank frame with no way back.
        let t = token.to_string();
        wv.add_NavigationStarting(
            &NavigationStartingEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    let mut uri = PWSTR::null();
                    let _ = args.Uri(&mut uri);
                    let uri = take_pwstr(uri);
                    let allowed = uri_token(&uri) == Some(t.as_str())
                        && (uri.starts_with(PREVIEW_SCHEME) || uri.starts_with(PAGE_SCHEME));
                    if !allowed {
                        let _ = args.SetCancel(true);
                        // process-wide: as above
                        crate::plogf!("[preview] {}: navigation to {:?} refused", t, uri);
                    }
                }
                Ok(())
            })),
            &mut tok,
        )?;

        // No new windows (see the note in `configure`).
        wv.add_NewWindowRequested(
            &NewWindowRequestedEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    let _ = args.SetHandled(true);
                }
                Ok(())
            })),
            &mut tok,
        )?;

        let t = token.to_string();
        let guard = key.clone();
        wv.add_WebMessageReceived(
            &WebMessageReceivedEventHandler::create(Box::new(move |wv, args| {
                // **A message from a replaced or closed slot never reaches
                // the core**, even if the old page was still queued.
                if slot_generation(&guard) != Some(generation) {
                    return Ok(());
                }
                if let (Some(wv), Some(args)) = (wv, args) {
                    on_message(&wv, &args, &t);
                }
                Ok(())
            })),
            &mut tok,
        )?;

        let script = wide(BRIDGE);
        wv.AddScriptToExecuteOnDocumentCreated(PCWSTR(script.as_ptr()), None)?;
        let url_text = match slot_page(key) {
            Some(assets) => page_entry_url(token, &assets),
            None => entry_url(token),
        };
        let url = wide(&url_text);
        wv.Navigate(PCWSTR(url.as_ptr()))?;
    }
    // process-wide: as above
    crate::plogf!(
        "[preview] {}: view made, loading {}",
        token,
        entry_url(token)
    );
    Ok(())
}

/// The entry URL: the ticket's own file, which is `rel` empty
/// (`Tickets.resolve` reads it as the anchor).
pub fn entry_url(token: &str) -> String {
    format!("{PREVIEW_SCHEME}://{token}/")
}

/// What the page finds on `window`, as `plugin_page`'s bridge does it: the
/// eight calls, each a promise, frozen and non-configurable so a dependency
/// that runs later cannot replace it. Top frame only.
///
/// **The list is `polter_preview_route::Call`'s and is written out here
/// because this is JavaScript.** A call named in one and not the other is a
/// call a page can make and the host refuses, or one the host would answer
/// and the page cannot ask -- the crate's own test holds the eight names to
/// the table, and this text is the second copy that test cannot see.
const BRIDGE: &str = r#"(function () {
  if (window.top !== window || !window.chrome || !window.chrome.webview) return;
  const wv = window.chrome.webview;
  const pending = new Map();
  let next = 1;
  wv.addEventListener("message", (e) => {
    const m = e.data;
    const p = m && pending.get(m.id);
    if (!p) return;
    pending.delete(m.id);
    if (m.error) p.reject(new Error(m.error)); else p.resolve(m.result);
  });
  const post = (method, argument) => new Promise((resolve, reject) => {
    const id = next++;
    pending.set(id, { resolve, reject });
    wv.postMessage({ id: id, method: method, argument: argument === undefined ? null : argument });
  });
  Object.defineProperty(window, "polter", {
    value: Object.freeze({
      info: () => post("info"),
      read: (offset, length) => post("read", { offset: offset || 0, length: length || 0 }),
      readRel: (rel, offset, length) => post("readRel", { rel: rel, offset: offset || 0, length: length || 0 }),
      openPath: (rel) => post("openPath", { rel: rel }),
      watch: (cb) => post("watch", { cb: true }).then(() => {
        window.__polterWatch = cb;
        return true;
      }),
      look: () => post("look"),
      propose: (fullText, baseVersion) => post("propose", { fullText: fullText, baseVersion: baseVersion }),
      dirty: (yes) => post("dirty", { dirty: !!yes }),
    }),
    writable: false,
    configurable: false,
  });
})();"#;

/// One `files_*` request, as the text the socket would carry, and the
/// core's answer **as it wrote it** -- a refusal included -- or why there
/// is no answer at all.
///
/// **The one door to `ghostty_app_files`** (task 3148). The preview's own
/// page and the working-directories page both come through here, so the
/// text a ticket is listed with and the text it is resolved with are built
/// the same way. This level says only whether the core answered; **what it
/// said is the caller's to read**, because the two callers read a refusal
/// differently: a preview wants the sentence, and the workdirs page wants
/// the code and the reason as well (`workdirs::read_listing`, whose three
/// branches are the point).
pub(crate) fn ask_raw(request: &str) -> Result<String, String> {
    let Some(api) = crate::api_opt() else {
        return Err("the core is not running".into());
    };
    let Some(ask) = api.app_files else {
        return Err("this build's core has no file preview calls".into());
    };
    let app = crate::app_opt();
    if app.is_null() {
        return Err("the core is not running".into());
    }
    let need = unsafe {
        ask(
            app,
            request.as_ptr(),
            request.len(),
            std::ptr::null_mut(),
            0,
        )
    };
    if need == 0 {
        // Zero is this door's "that is not one of the five": named rather
        // than read as an empty answer.
        return Err("it is not a request the core answers for a host".into());
    }
    let mut buf = vec![0u8; need + 1];
    let wrote = unsafe {
        ask(
            app,
            request.as_ptr(),
            request.len(),
            buf.as_mut_ptr(),
            buf.len(),
        )
    };
    if wrote == 0 || wrote > need {
        return Err("it changed size between asking and reading".into());
    }
    String::from_utf8(buf[..wrote].to_vec()).map_err(|_| "it is not UTF-8".to_string())
}

/// `ask_raw`, parsed, with the core's refusal turned into an `Err` that
/// carries its sentence -- for callers that want the answer itself.
pub(crate) fn ask_text(request: &str) -> Result<serde_json::Value, String> {
    let text = ask_raw(request)?;
    let value: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("the core's answer is not JSON: {e}"))?;
    // `{"refused":...}` is the core's no, in the one shape it refuses in.
    if value.get("refused").is_some() {
        return Err(value
            .get("why")
            .and_then(|w| w.as_str())
            .unwrap_or("refused")
            .to_string());
    }
    Ok(value)
}

/// `ask_text` for one of the two calls this file's own page makes, built
/// from a method and its parameters.
///
/// `rel` is what the page asked for, already through
/// `polter_preview_route::resolve`; the ticket is the one this view is
/// showing.
fn ask_core(method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
    ask_text(&serde_json::json!({ "method": method, "params": params }).to_string())
}

/// Serve one request the page made over `polter-file://`.
///
/// **The route says which ticket and which `rel`; the core says whether and
/// where.** Nothing in this function builds a path, and there is no branch
/// in which it could: it hands `(token, rel)` to `files_resolve` and writes
/// what came back.
fn serve(args: &ICoreWebView2WebResourceRequestedEventArgs, token: &str, key: &SlotKey) {
    let env = SLOTS.with(|m| m.borrow().env.clone());
    let Some(env) = env else { return };
    let uri = unsafe { args.Request() }
        .ok()
        .map(|r| {
            let mut u = PWSTR::null();
            let _ = unsafe { r.Uri(&mut u) };
            take_pwstr(u)
        })
        .unwrap_or_default();

    // **A plugin page is served from its own directory**, never from the
    // ticket's file; a ticket URL is served from the core's resolution.
    // The URL goes through the same `page_segments` the entry URL is built
    // from: one decode, the ticket as host, no query in the file name.
    if uri.starts_with(PAGE_SCHEME) {
        let (status, reason, body, ctype) = match slot_page(key) {
            Some(assets) => page_asset(&uri, token, &assets.dir),
            None => (403, "Forbidden", Vec::new(), "text/plain"),
        };
        // **Every answer, not only refusals**, for the same reason as the
        // ticket path: a page's own script/style arriving as 200 here is
        // what shows this route works.
        // process-wide: as above
        crate::plogf!("[preview] {}: {} -> {}", token, uri, status);
        let headers = format!(
            "Content-Type: {ctype}\r\nContent-Security-Policy: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff",
            page_csp(token)
        );
        let stream = unsafe { SHCreateMemStream(Some(&body)) };
        let reason = wide(reason);
        let headers = wide(&headers);
        if let Ok(resp) = unsafe {
            env.CreateWebResourceResponse(
                stream.as_ref(),
                // API takes i32; `page_asset` answers a u16 status.
                status.into(),
                PCWSTR(reason.as_ptr()),
                PCWSTR(headers.as_ptr()),
            )
        } {
            let _ = unsafe { args.SetResponse(&resp) };
        }
        return;
    }
    let (status, reason, body, ctype) = match polter_preview_route::resolve(&uri) {
        Ok(route) => {
            // A page may only ask about the ticket it was served from: a
            // second token in the URL is another file's capability, and
            // this view was never given it.
            if route.token != token {
                // process-wide: as above
                crate::plogf!(
                    "[preview] {}: request for another ticket's file refused",
                    token
                );
                (403, "Forbidden", Vec::new(), "text/plain")
            } else {
                match ask_core(
                    "files_resolve",
                    serde_json::json!({ "token": route.token, "rel": route.rel }),
                ) {
                    Ok(answer) => match answer.get("path").and_then(|p| p.as_str()) {
                        // The host reads the path the core named, and only
                        // that. Whether it is inside the ticket's scope was
                        // decided one call ago, by the core.
                        Some(path) => match std::fs::read(path) {
                            Ok(bytes) => (200, "OK", bytes, content_type(path)),
                            Err(_) => (404, "Not Found", Vec::new(), "text/plain"),
                        },
                        None => (403, "Forbidden", Vec::new(), "text/plain"),
                    },
                    Err(why) => {
                        // The refusal's own words, logged here and handed to
                        // the page as 403: a page that asked for something it
                        // may not have should hear "no", not an empty file.
                        // process-wide: as above
                        crate::plogf!("[preview] {}: {} -> 403 ({})", token, uri, why);
                        (403, "Forbidden", Vec::new(), "text/plain")
                    }
                }
            }
        }
        Err(why) => {
            // process-wide: as above
            crate::plogf!(
                "[preview] {}: request for {:?} refused ({:?})",
                token,
                uri,
                why
            );
            let (status, reason) = match why {
                Refused::OtherScheme | Refused::BadToken => (403, "Forbidden"),
                Refused::Outside | Refused::BadEscape => (403, "Forbidden"),
            };
            (status, reason, Vec::new(), "text/plain")
        }
    };
    // The slot's generation was checked by the handler that called this;
    // a request for a replaced view never reaches here.
    // **Every answer, not only refusals**: a 200 is what shows this path
    // works, and a `fetch` that never appears is then the policy stopping it
    // in the page, not a request lost.
    // process-wide: as above
    crate::plogf!("[preview] {}: {} -> {}", token, uri, status);
    let headers = format!(
        "Content-Type: {ctype}\r\nContent-Security-Policy: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff",
        csp(token)
    );
    let stream = unsafe { SHCreateMemStream(Some(&body)) };
    let reason = wide(reason);
    let headers = wide(&headers);
    if let Ok(resp) = unsafe {
        env.CreateWebResourceResponse(
            stream.as_ref(),
            status,
            PCWSTR(reason.as_ptr()),
            PCWSTR(headers.as_ptr()),
        )
    } {
        let _ = unsafe { args.SetResponse(&resp) };
    }
}

/// The `Content-Security-Policy` sent with every response.
///
/// **`'self'` is the ticket's own origin**, so everything has to come from
/// this preview. `connect-src 'none'` is the one that matters most: no
/// `fetch`, no `XMLHttpRequest`, no `WebSocket`, no `EventSource` -- a
/// previewed file's data reaches the page through `window.polter`, and the
/// request is stopped in the page before it is made. Images and media are
/// the exception and the one `PLAN.md` §2.1 names: a markdown file's `<img>`
/// may load from this ticket, which is a load the core resolves like any
/// other.
fn csp(token: &str) -> String {
    format!(
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; \
img-src 'self' data: {PREVIEW_SCHEME}://{token}; media-src 'self' {PREVIEW_SCHEME}://{token}; \
font-src 'self' data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; \
base-uri 'none'; frame-ancestors 'none'"
    )
}

/// The plugin page's own CSP: only its page assets, inline script/style as
/// plugin pages use, and **no network**.
fn page_csp(token: &str) -> String {
    format!(
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; \
img-src 'self' data:; font-src 'self' data:; connect-src 'none'; frame-src 'none'; object-src 'none'; \
form-action 'none'; base-uri 'none'; frame-ancestors 'none'; media-src 'self' {PAGE_SCHEME}://{token}"
    )
}

/// Enough types for a file being previewed: `polter_preview_route::content_type`,
/// imported above. **This host keeps no second copy of that table** -- it had
/// one, and its `.css`/`.json` answers had drifted from the macOS host's
/// while both sent `nosniff`. See that crate for the table and the fixture
/// that pins both hosts to it.
fn on_message(wv: &ICoreWebView2, args: &ICoreWebView2WebMessageReceivedEventArgs, token: &str) {
    let mut src = PWSTR::null();
    let _ = unsafe { args.Source(&mut src) };
    let source = take_pwstr(src);
    // The message has to come from this ticket's own origin: a frame from
    // anywhere else is not the file that was served.
    let from_here = uri_token(&source) == Some(token);
    if !from_here {
        // process-wide: as above
        crate::plogf!("[preview] {}: message from {:?} ignored", token, source);
        return;
    }
    let mut j = PWSTR::null();
    let _ = unsafe { args.WebMessageAsJson(&mut j) };
    let text = take_pwstr(j);
    let Ok(msg) = serde_json::from_str::<serde_json::Value>(&text) else {
        return;
    };
    let id = msg.get("id").cloned().unwrap_or(serde_json::Value::Null);
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let argument = msg
        .get("argument")
        .cloned()
        .unwrap_or(serde_json::Value::Null);

    // **`Call::parse` is the whole surface.** A method that is not one of
    // the eight is `no such call: <name>`, so an author who guessed finds out
    // instead of waiting on a promise that never settles -- and there is no
    // arm here for `write` or `delete` to fall into, because `parse` has no
    // case to give them.
    let reply = match Call::parse(method) {
        None => Err(format!("no such call: {method}")),
        Some(call) => answer(call, token, &argument),
    };
    let out = match reply {
        Ok(result) => serde_json::json!({ "id": id, "result": result }),
        Err(error) => serde_json::json!({ "id": id, "error": error }),
    };
    let w = wide(&out.to_string());
    let _ = unsafe { wv.PostWebMessageAsJson(PCWSTR(w.as_ptr())) };
}

/// One of the eight calls.
fn answer(
    call: Call,
    token: &str,
    argument: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    match call {
        // What the file is. The core's `files_open` answer carries this for
        // the ticket's own file, and it is reread on every ask rather than
        // kept, so a file that changed under the preview is not described
        // by what it was.
        Call::Info => ask_core(
            "files_resolve",
            serde_json::json!({ "token": token, "rel": "" }),
        ),
        Call::Read => {
            let rel = argument.get("rel").and_then(|r| r.as_str()).unwrap_or("");
            let resolved = ask_core(
                "files_resolve",
                serde_json::json!({ "token": token, "rel": rel }),
            )?;
            let path = resolved
                .get("path")
                .and_then(|p| p.as_str())
                .ok_or("refused")?;
            let offset = argument.get("offset").and_then(|o| o.as_u64()).unwrap_or(0) as usize;
            let length = argument.get("length").and_then(|l| l.as_u64()).unwrap_or(0) as usize;
            let length = if length == 0 {
                READ_MAX
            } else {
                length.min(READ_MAX)
            };
            let bytes = read_span(path, offset, length)?;
            Ok(serde_json::json!({
                "base64": base64(&bytes),
                "size": resolved.get("size").cloned().unwrap_or(serde_json::Value::Null),
                "truncated": bytes.len() == length,
            }))
        }
        Call::ReadRel => {
            let rel = argument
                .get("rel")
                .and_then(|r| r.as_str())
                .ok_or("readRel needs a path")?;
            let mut with_rel = argument.clone();
            with_rel["rel"] = serde_json::Value::String(rel.to_string());
            answer(Call::Read, token, &with_rel)
        }
        // **The host switches the preview; the page does not read a path.**
        // The `rel` goes to the core like any other, so a file outside this
        // ticket's scope is refused here as it would be in an `<img>`.
        Call::OpenPath => {
            let rel = argument
                .get("rel")
                .and_then(|r| r.as_str())
                .ok_or("openPath needs a path")?;
            let resolved = ask_core(
                "files_resolve",
                serde_json::json!({ "token": token, "rel": rel }),
            )?;
            // The ticket stays the same and the anchor does not move: the
            // page is what changes, not what this view may reach. Said as
            // such rather than pretending the file changed underneath.
            Ok(serde_json::json!({ "path": resolved.get("path"), "opened": false }))
        }
        // Registered for the page; what arrives is the core's business and
        // not this call's (the host drives it when the file moves).
        Call::Watch => Ok(serde_json::json!({ "watching": true })),
        // Colour tokens, font and size. The host's own look, so that a
        // preview and the page around it do not disagree about a colour.
        Call::Look => Ok(look_tokens()),
        // **Not a write.** The text goes to the core, which draws the change
        // and hands back what would be written; `files_commit` is a separate
        // call, made only after the person has chosen.
        Call::Propose => {
            let full_text = argument
                .get("fullText")
                .and_then(|t| t.as_str())
                .ok_or("propose needs text")?;
            let base_version = argument
                .get("baseVersion")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            ask_core(
                "files_propose",
                serde_json::json!({ "token": token, "full_text": full_text, "base_version": base_version }),
            )
        }
        // Whether there are unsaved changes. The host keeps this for its
        // own "you have unsaved changes" question; nothing is written.
        Call::Dirty => {
            let dirty = argument
                .get("dirty")
                .and_then(|d| d.as_bool())
                .unwrap_or(false);
            Ok(serde_json::json!({ "dirty": dirty }))
        }
    }
}

/// A span of a file the core named, clamped to what is really there.
fn read_span(path: &str, offset: usize, length: usize) -> Result<Vec<u8>, String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path).map_err(|e| e.to_string())?;
    f.seek(SeekFrom::Start(offset as u64))
        .map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; length];
    let n = f.read(&mut buf).map_err(|e| e.to_string())?;
    buf.truncate(n);
    Ok(buf)
}

/// What `look()` hands the page: the host's own colours, the face and the
/// sizes, as `PLAN.md` §3.2 asks for that call.
///
/// **A preview is a page somebody else wrote, drawn inside Polter's own
/// window**, and the file it shows is usually someone's markdown or code. The
/// one thing that must not happen is the page inventing a look beside the
/// window it sits in -- white text on a light host, or the terminal's
/// near-black ground inside a floating panel. So the numbers come from the
/// table the host itself draws its chrome from (`polter_control_room::look`)
/// and from the one font source every other window here uses
/// (`crate::uifont`, which floors a size at the system's menu font).
///
/// ⚠️ **The size floor is the reason this is not a constant.** `look::font::
/// BODY` is 13 logical points; the menu font moves with Settings >
/// Accessibility > Text size and a preview set at a literal 13 is unreadable
/// on a machine set to 150%. `uifont::make` is where that floor lives, so
/// the size handed to a page is asked of the same place a control's size is.
///
/// Colours are `#RRGGBB` and the alpha is separate, because that is what CSS
/// takes and the page is a web page; `Rgba.a` is `f64` in the table for the
/// same reason.
fn look_tokens() -> serde_json::Value {
    use polter_control_room::look;
    let theme = look::theme(!crate::theme::system().light);
    // Six digits, or eight when the table has an alpha: `line` is black at
    // 0.16 and a page handed `#000000` for it would draw a hard rule where
    // the host draws a faint one. `#RRGGBBAA` is what CSS takes.
    let hex = |c: look::Rgba| {
        if c.a >= 1.0 {
            format!("#{:02X}{:02X}{:02X}", c.r, c.g, c.b)
        } else {
            format!(
                "#{:02X}{:02X}{:02X}{:02X}",
                c.r,
                c.g,
                c.b,
                (c.a.clamp(0.0, 1.0) * 255.0).round() as u8
            )
        }
    };
    let mut colours = serde_json::Map::new();
    for (name, c) in [
        ("text", theme.text),
        ("text_secondary", theme.text_secondary),
        ("text_tertiary", theme.text_tertiary),
        ("well", theme.window_base),
        ("panel", theme.side_panel),
        ("row", theme.surface_row),
        ("row_selected", theme.surface_row_selected),
        ("line", theme.line),
        ("line_faint", theme.line_faint),
        ("terminal_background", theme.terminal_background),
        ("terminal_text", theme.terminal_text),
        ("terminal_dim", theme.terminal_dim),
        ("attention", theme.attention),
        ("problem", theme.problem),
    ] {
        colours.insert(name.to_string(), serde_json::Value::String(hex(c)));
    }
    // The faces, by the name a page would put in `font-family`: the system's
    // message font, which is the one every other window here draws in.
    let face = |p: PCWSTR| unsafe { p.to_string() }.unwrap_or_default();
    serde_json::json!({
        "dark": theme.dark,
        "colours": colours,
        "font": { "ui": face(crate::uifont::ui_face()), "mono": face(crate::uifont::mono_face()) },
        "size": {
            "body": look::font::BODY,
            "min": look::font::MIN,
            "line_height": look::font::LINE_HEIGHT_TERMINAL,
        },
        "radius": { "card": look::radius::ROW, "window": look::radius::WINDOW },
    })
}

/// The bytes as the page can carry them. A preview reads a file's bytes
/// through `read`, and a text document is not the only thing this serves --
/// a base64 string is what both hosts can hand to a page without a second
/// encoding rule per platform.
pub(crate) fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use polter_preview_route::Call;

    /// A token as `Tickets.newId` mints one: 16 bytes, lower-case hex.
    const TOKEN: &str = "9f2c0a1b4d5e6f708192a3b4c5d6e7f8";

    /// **The URL this view loads is one its own route accepts.** The two are
    /// written in different places -- `entry_url` here, `resolve` in the
    /// crate -- and a view that navigated to something the handler then
    /// refused would show an empty frame with nothing logged as an error.
    #[test]
    fn the_entry_url_is_a_route_this_scheme_serves() {
        let url = entry_url(TOKEN);
        assert_eq!(url, format!("{PREVIEW_SCHEME}://{TOKEN}/"));
        let route = polter_preview_route::resolve(&url).expect("the entry URL must resolve");
        assert_eq!(route.token, TOKEN);
        // An empty `rel` is the ticket's own file, which is what a preview of
        // a file means.
        assert_eq!(route.rel, "");
    }

    /// **The page URL is built and served by one parser.** `page_entry_url`
    /// encodes each segment; `page_segments` -- the function `serve` calls
    /// -- decodes each segment exactly once. A space or a Chinese name must
    /// survive that round trip, and the query is not part of a file name.
    #[test]
    fn a_page_url_round_trips_through_its_own_router() {
        let assets = PageAssets {
            dir: "C:\\plugins\\p".into(),
            page: "ui/我的 页面.html".into(),
        };
        let url = page_entry_url(TOKEN, &assets);
        assert!(url.starts_with("polter-preview-plugin://"), "{url}");
        assert!(url.contains("%20"), "{url}");
        assert_eq!(
            page_segments(&url, TOKEN).expect("the URL this view loads must route"),
            vec!["ui".to_string(), "我的 页面.html".to_string()]
        );
        // `?v=1` is the resource asking for a file, not a file named that.
        let versioned = format!("{PAGE_SCHEME}://{TOKEN}/ui/style.css?v=1");
        assert_eq!(
            page_segments(&versioned, TOKEN),
            Some(vec!["ui".to_string(), "style.css".to_string()])
        );
    }

    /// **The entry HTML, its script and its stylesheet, through one
    /// chain**: `page_entry_url` -> `page_asset` (the function `serve`
    /// calls). The HTML is a page and the two assets carry the types the
    /// engine needs; a `?v=1` resource and a Chinese/space name load.
    #[test]
    fn the_entry_url_serves_the_page_files_it_names() {
        let dir = std::env::temp_dir().join(format!("polter-preview-page-{}", std::process::id()));
        let ui = dir.join("ui");
        std::fs::create_dir_all(&ui).expect("a page directory");
        std::fs::write(ui.join("我的 页面.html"), b"<html></html>").expect("the entry");
        std::fs::write(ui.join("app.js"), b"window.x = 1;").expect("a script");
        std::fs::write(ui.join("style.css"), b"body {}").expect("a stylesheet");
        let page = PageAssets {
            dir: dir.to_string_lossy().into_owned(),
            page: "ui/我的 页面.html".into(),
        };
        let entry = page_entry_url(TOKEN, &page);
        let (status, _, body, ctype) = page_asset(&entry, TOKEN, &page.dir);
        assert_eq!((status, ctype), (200, "text/html; charset=utf-8"), "{entry}");
        assert_eq!(body, b"<html></html>");
        for (name, want) in [
            ("app.js", "text/javascript; charset=utf-8"),
            ("style.css", "text/css; charset=utf-8"),
        ] {
            let url = format!("{PAGE_SCHEME}://{TOKEN}/ui/{name}?v=1");
            let (status, _, _, ctype) = page_asset(&url, TOKEN, &page.dir);
            assert_eq!((status, ctype), (200, want), "{url}");
        }
        // A traversal is refused with the URL's own answer, not remapped
        // onto another file in the directory.
        let escape = format!("{PAGE_SCHEME}://{TOKEN}/ui/../secret");
        assert_eq!(page_asset(&escape, TOKEN, &page.dir).0, 403);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// One decode, then refuse what leaves the page's own directory. A
    /// silent remap would serve a different file than the URL named.
    #[test]
    fn the_page_router_refuses_escapes_instead_of_remapping_them() {
        for bad in [
            "a/../b",
            "%2e%2e/x",
            "%2E%2E/x",
            "a%2Fb",
            "a%5Cb",
            "%ZZ",
            "x/%2E",
            "a//b",
        ] {
            let url = format!("{PAGE_SCHEME}://{TOKEN}/{bad}");
            assert_eq!(page_segments(&url, TOKEN), None, "{bad}");
        }
        // Another ticket is another origin, and an empty path names no file.
        assert_eq!(
            page_segments(&format!("{PAGE_SCHEME}://other/index.html"), TOKEN),
            None
        );
        assert_eq!(page_segments(&format!("{PAGE_SCHEME}://{TOKEN}/"), TOKEN), None);
    }

    /// **A page is a program, so its own assets take the plugin table.**
    /// The ticket table would answer `text/plain` for `.js`/`.css`, and the
    /// `nosniff` header then makes the engine refuse to run or apply them.
    #[test]
    fn a_plugin_page_asset_is_not_a_previewed_source_file() {
        assert_eq!(
            polter_settings_shell::plugins::content_type("ui/app.js"),
            "text/javascript; charset=utf-8"
        );
        assert_eq!(
            polter_settings_shell::plugins::content_type("ui/app.css"),
            "text/css; charset=utf-8"
        );
        // The preview ticket's table is unchanged: a person reads that file.
        assert_eq!(content_type("ui/app.js"), "text/plain; charset=utf-8");
        assert_eq!(content_type("ui/app.css"), "text/plain; charset=utf-8");
    }

    #[test]
    fn the_scheme_is_the_crates_and_has_an_authority() {
        assert_eq!(PREVIEW_SCHEME, SCHEME);
        assert_eq!(SCHEME, "polter-file");
        // A preview's files are `<token>/<rel>` and the token is the whole of
        // what may be read, so a request with no authority names no ticket.
        assert!(polter_preview_route::resolve("polter-file:///x.md").is_err());
    }

    /// **The eight names, read out of the JavaScript this host injects.**
    ///
    /// `Call::ALL` is the Rust list and `BRIDGE` is a string literal: nothing
    /// in the compiler holds one to the other, and the two ways they drift
    /// are both silent -- a call the page can make and the host refuses, or
    /// one the host would answer and no page can ask. The pattern is
    /// `post("<name>"`, one per call, which is the only place `BRIDGE` names
    /// a method.
    #[test]
    fn the_bridge_offers_exactly_the_eight_calls_the_crate_names() {
        let mut said: Vec<&str> = Vec::new();
        for piece in BRIDGE.split("post(\"").skip(1) {
            said.push(piece.split('"').next().expect("a quote closes the name"));
        }
        let mut want: Vec<&str> = Call::ALL.iter().map(|c| c.name()).collect();
        said.sort_unstable();
        want.sort_unstable();
        assert_eq!(said, want, "the injected bridge and Call::ALL disagree");
        // And the six a page must not have are not in the text at all.
        for forbidden in ["write", "create", "delete", "rename", "exec", "fetch"] {
            assert!(
                !BRIDGE.contains(&format!("{forbidden}:")),
                "the bridge offers `{forbidden}`"
            );
        }
    }

    /// **This host's `serve` answers with the crate's table and not a copy of
    /// its own.** The table itself is asserted row by row in
    /// `polter_preview_route` (which compiles anywhere; this file needs
    /// WebView2) -- what is worth asserting *here* is that the import is
    /// wired: a local `fn content_type` reintroduced into this file would
    /// shadow the crate's and these four lines would still pass, so what
    /// this really pins is the shape of the answer for a source file.
    #[test]
    fn a_source_file_is_served_as_text_and_not_as_a_document() {
        assert_eq!(content_type("a/b/index.html"), "text/html; charset=utf-8");
        assert_eq!(content_type("README.md"), "text/plain; charset=utf-8");
        assert_eq!(content_type("src/main.rs"), "text/plain; charset=utf-8");
        assert_eq!(content_type("notes.txt"), "text/plain; charset=utf-8");
        assert_eq!(content_type("shot.png"), "image/png");
        // Anything nobody wrote a type for is bytes: an unknown extension
        // must not stop the file being read.
        assert_eq!(content_type("blob.wat"), "application/octet-stream");
    }

    /// The policy names the ticket's own origin and nothing else, and the one
    /// that matters most is `connect-src 'none'`: a previewed file's data
    /// reaches the page through `window.polter`.
    #[test]
    fn the_policy_lets_in_only_this_tickets_own_origin() {
        let csp = csp(TOKEN);
        assert!(
            csp.contains(&format!("{PREVIEW_SCHEME}://{TOKEN}")),
            "{csp}"
        );
        assert!(csp.contains("connect-src 'none'"), "{csp}");
        assert!(csp.contains("frame-ancestors 'none'"), "{csp}");
        // Another ticket's origin is not named, by construction: the only
        // token in the policy is this one.
        assert_eq!(
            csp.matches(PREVIEW_SCHEME).count(),
            2,
            "img-src and media-src: {csp}"
        );
    }

    /// **A ledger that is borrowed cannot answer "who owns this".** The
    /// close waits for it instead of being treated as an unowned ticket;
    /// once the borrow is gone, the deferred effect runs.
    #[test]
    fn a_busy_owner_ledger_defers_a_close_instead_of_calling_it_unowned() {
        SLOTS.with(|m| {
            let _held = m.borrow_mut();
            close_unowned(TOKEN);
        });
        assert_eq!(deferred_len(), 1, "busy is not unowned");
        flush_deferred();
        assert_eq!(deferred_len(), 0);
    }

    #[test]
    fn bytes_go_to_the_page_as_base64() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        // Not just ASCII: a previewed file is somebody's text, in whatever
        // language they wrote it in.
        assert_eq!(base64("构建".as_bytes()), "5p6E5bu6");
    }
}
