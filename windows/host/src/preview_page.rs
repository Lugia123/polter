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

// ⚠️ **A file-level allow, and it is a statement about this task and not a
// habit.** Everything here is reached by `show`/`hide`, and nothing calls
// them yet: putting a preview in a pane, in the right side's page and in the
// workdirs page is M2/W2 (#2140), one task later. The evidence that this is
// reachability and not decay is that `cargo check` reports all 22 items as
// `never used` **including `serve`, `ask_core` and `BRIDGE`** -- the three
// that carry this task's whole behaviour -- so an allow that hid a real
// mistake would hide those too. Measured 2026-11-01 by the test seat from the
// build's own diagnostics (`windows/host/src/preview_page.rs`, 22 of 29).
//
// **What removes it**: the M2/W2 call sites. Then the compiler goes back to
// saying which of these is still unused, and that answer will mean something.
// `windows/host/src/ffi.rs` carries the same allow for the same shape of
// reason (declarations that belong together, consumers a task behind).
#![allow(dead_code)]

use std::cell::RefCell;

use polter_preview_route::{content_type, Call, Refused, SCHEME};
use polter_settings_shell::plugins::PageState;
use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::{
    CoreWebView2CustomSchemeRegistration, CoreWebView2EnvironmentOptions, CreateCoreWebView2ControllerCompletedHandler,
    CreateCoreWebView2EnvironmentCompletedHandler, NavigationStartingEventHandler, NewWindowRequestedEventHandler,
    WebMessageReceivedEventHandler, WebResourceRequestedEventHandler,
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

/// Where the terminator is: the amount the page is told about one file. Sizes
/// beyond it come back through `info` with `truncated: true` rather than
/// being silently short.
pub const READ_MAX: usize = 4 << 20;

struct Preview {
    /// Asked once per process, as the plugin page's is. `None` until the
    /// first preview is shown.
    probed: Option<(Option<Loader>, PageState)>,
    env: Option<ICoreWebView2Environment>,
    env_pending: bool,
    controller: Option<ICoreWebView2Controller>,
    /// The ticket being shown, or being made for. A second `show` for the
    /// same one leaves the view alone: reopening a preview must not throw
    /// away what the person was reading.
    token: Option<String>,
    parent: HWND,
    rect: RECT,
    /// Bumped whenever the page on screen should change: a completion that
    /// arrives for an older one closes what it made.
    generation: u64,
    state: PageState,
}

thread_local! {
    static PREVIEW: RefCell<Preview> = RefCell::new(Preview {
        probed: None,
        env: None,
        env_pending: false,
        controller: None,
        token: None,
        parent: HWND(std::ptr::null_mut()),
        rect: RECT::default(),
        generation: 0,
        state: PageState::Loading,
    });
}

/// What the preview's slot can show now, or `None` when no preview has been
/// asked for. The one state the slot paints a sentence for is a Runtime that
/// is not on the machine -- `PLAN.md` §2.1: "WebView2 Runtime 不在时
/// （Server 2022），预览区写明原因，给「用默认程序打开」，不显示成空白".
pub fn state() -> Option<PageState> {
    PREVIEW.with(|p| {
        let s = p.borrow();
        s.token.as_ref().map(|_| s.state.clone())
    })
}

/// Whether a preview is on screen for this ticket.
pub fn showing() -> Option<String> {
    PREVIEW.with(|p| p.borrow().token.clone())
}

/// Show the file behind `token` in `rect` of `parent`.
///
/// **The token is the whole of what the host knows about the file.** It came
/// from the core (`files_open`, through `ghostty_app_files`) and nothing here
/// can turn it into a path; the page's requests are resolved by the core, one
/// at a time, against this ticket's scope.
pub fn show(parent: HWND, rect: RECT, token: &str) {
    let probed = PREVIEW.with(|c| c.borrow().probed.clone());
    let (loader, st) = match probed {
        Some(x) => x,
        None => {
            let x = probe();
            PREVIEW.with(|c| c.borrow_mut().probed = Some(x.clone()));
            x
        }
    };
    let Some(loader) = loader.filter(|_| st == PageState::Loading) else {
        PREVIEW.with(|c| {
            let s = &mut *c.borrow_mut();
            s.token = Some(token.to_string());
            s.parent = parent;
            s.rect = rect;
            s.state = st;
        });
        return;
    };

    let (same, controller) = PREVIEW.with(|c| {
        let s = &mut *c.borrow_mut();
        s.parent = parent;
        s.rect = rect;
        (s.token.as_deref() == Some(token), s.controller.clone())
    });
    if same {
        if let Some(ctl) = controller {
            unsafe {
                let _ = ctl.SetBounds(rect);
                let _ = ctl.SetIsVisible(true);
            }
        }
        return;
    }

    // Another file: the old page goes, the new one is made.
    close_controller();
    let generation = PREVIEW.with(|c| {
        let s = &mut *c.borrow_mut();
        s.token = Some(token.to_string());
        s.generation += 1;
        s.state = PageState::Loading;
        s.generation
    });
    let token = token.to_string();
    let env = PREVIEW.with(|c| c.borrow().env.clone());
    match env {
        Some(env) => make_controller(env, generation, token),
        None => make_env(loader, generation, token),
    }
}

/// Take the preview off screen. The controller is dropped with the ticket:
/// a preview that is closed is a ticket nobody holds, and the core's cap
/// (`Tickets.max_tickets`) is what closes the oldest one.
pub fn hide() {
    let (ctl, parent) = PREVIEW.with(|c| {
        let s = c.borrow();
        (s.controller.clone(), s.parent)
    });
    if let Some(ctl) = ctl {
        unsafe {
            let _ = ctl.SetIsVisible(false);
        }
        take_keyboard_back(parent);
    }
}

fn close_controller() {
    let ctl = PREVIEW.with(|c| {
        let s = &mut *c.borrow_mut();
        s.token = None;
        s.controller.take()
    });
    if let Some(ctl) = ctl {
        unsafe {
            let _ = ctl.Close();
        }
    }
}

fn make_env(loader: Loader, generation: u64, token: String) {
    if PREVIEW.with(|c| std::mem::replace(&mut c.borrow_mut().env_pending, true)) {
        return;
    }
    // **Both schemes, in one environment.** WebView2 registers a custom
    // scheme when the environment is made and not afterwards, and the
    // plugin page and the preview can each be the first to ask for one --
    // so the environment carries both whichever page made it. That is why
    // this list and `plugin_page::make_env`'s name the same two.
    let mut regs: Vec<Option<ICoreWebView2CustomSchemeRegistration>> = Vec::new();
    for scheme in [PREVIEW_SCHEME, polter_settings_shell::plugins::SCHEME] {
        let reg = CoreWebView2CustomSchemeRegistration::new(scheme.to_string());
        unsafe {
            reg.set_treat_as_secure(true);
            reg.set_has_authority_component(true);
        }
        // No `SetAllowedOrigins` restriction: that list is what *other*
        // origins may be served this scheme's resources, and a preview is
        // served to its own ticket's page only -- a rule about other origins
        // would be a rule nobody here could rely on. What keeps a page to its
        // own ticket is `serve` and `on_message`, both of which compare the
        // token in the request with the one this view was shown for.
        regs.push(Some(reg.into()));
    }
    let options = CoreWebView2EnvironmentOptions::default();
    unsafe { options.set_scheme_registrations(regs) };
    let options: ICoreWebView2EnvironmentOptions = options.into();
    let handler = CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(move |hr, env| {
        PREVIEW.with(|c| c.borrow_mut().env_pending = false);
        match (hr, env) {
            (Ok(()), Some(env)) => {
                PREVIEW.with(|c| c.borrow_mut().env = Some(env.clone()));
                make_controller(env, generation, token);
            }
            (r, _) => failed("environment", r.err().map(|e| e.code().0).unwrap_or(-1)),
        }
        Ok(())
    }));
    let folder = user_data_dir().map(|d| wide(&d.display().to_string()));
    let folder_ptr = folder.as_ref().map(|w| PCWSTR(w.as_ptr())).unwrap_or(PCWSTR::null());
    let hr = unsafe { (loader.create)(PCWSTR::null(), folder_ptr, options.as_raw(), handler.as_raw()) };
    if hr.is_err() {
        PREVIEW.with(|c| c.borrow_mut().env_pending = false);
        failed("environment", hr.0);
    }
}

fn failed(what: &str, hr: i32) {
    // process-wide: the one preview the window can show
    crate::plogf!("[preview] making the {} failed: 0x{:08X}", what, hr as u32);
    let parent = PREVIEW.with(|c| {
        let s = &mut *c.borrow_mut();
        s.state = PageState::Failed(hr);
        s.parent
    });
    unsafe {
        let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false);
    }
}

fn make_controller(env: ICoreWebView2Environment, generation: u64, token: String) {
    let parent = PREVIEW.with(|c| c.borrow().parent);
    let handler = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(move |hr, ctl| {
        let Some(ctl) = ctl.filter(|_| hr.is_ok()) else {
            failed("view", hr.err().map(|e| e.code().0).unwrap_or(-1));
            return Ok(());
        };
        let current = PREVIEW.with(|c| c.borrow().generation);
        if current != generation {
            // Made for a ticket that is no longer on screen.
            unsafe {
                let _ = ctl.Close();
            }
            return Ok(());
        }
        if let Err(e) = configure(&ctl, &token) {
            unsafe {
                let _ = ctl.Close();
            }
            failed("view", e.code().0);
            return Ok(());
        }
        let (rect, parent) = PREVIEW.with(|c| {
            let s = &mut *c.borrow_mut();
            s.controller = Some(ctl.clone());
            s.state = PageState::Ready;
            (s.rect, s.parent)
        });
        unsafe {
            let _ = ctl.SetBounds(rect);
            let _ = ctl.SetIsVisible(true);
            let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false);
        }
        Ok(())
    }));
    // InPrivate: nothing the preview stores outlives it or reaches the next
    // file's page (`websiteDataStore = .nonPersistent()` on the macOS side).
    let with_options = env.cast::<ICoreWebView2Environment10>().ok().and_then(|e10| {
        let o = unsafe { e10.CreateCoreWebView2ControllerOptions() }.ok()?;
        unsafe { o.SetIsInPrivateModeEnabled(true) }.ok()?;
        Some((e10, o))
    });
    let r = match with_options {
        Some((e10, o)) => unsafe { e10.CreateCoreWebView2ControllerWithOptions(parent, &o, &handler) },
        None => {
            // process-wide: as above
            crate::plogf!("[preview] this runtime has no controller options; the preview is not InPrivate");
            unsafe { env.CreateCoreWebView2Controller(parent, &handler) }
        }
    };
    if let Err(e) = r {
        failed("view", e.code().0);
    }
}

/// What the preview may do, set on a new view before it loads anything.
///
/// **Two of the plugin page's settings are looser here and neither is
/// reach.** A preview's page is a file somebody wrote, so its scripts run --
/// that is the point of a preview -- and the thing that keeps a script from
/// reaching anything is that there is no bridge in it beyond the eight calls
/// and no network, not that scripts are off.
fn configure(ctl: &ICoreWebView2Controller, token: &str) -> windows::core::Result<()> {
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
        wv.AddWebResourceRequestedFilter(PCWSTR(all.as_ptr()), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)?;
        let t = token.to_string();
        let mut tok = 0i64;
        wv.add_WebResourceRequested(
            &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    serve(&args, &t);
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
                    if polter_preview_route::resolve(&uri).is_err() {
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
        wv.add_WebMessageReceived(
            &WebMessageReceivedEventHandler::create(Box::new(move |wv, args| {
                if let (Some(wv), Some(args)) = (wv, args) {
                    on_message(&wv, &args, &t);
                }
                Ok(())
            })),
            &mut tok,
        )?;

        let script = wide(BRIDGE);
        wv.AddScriptToExecuteOnDocumentCreated(PCWSTR(script.as_ptr()), None)?;
        let url = wide(&entry_url(token));
        wv.Navigate(PCWSTR(url.as_ptr()))?;
    }
    // process-wide: as above
    crate::plogf!("[preview] {}: view made, loading {}", token, entry_url(token));
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

/// **The core's answer, and the only place a path is decided.**
///
/// `rel` is what the page asked for, already through
/// `polter_preview_route::resolve`; the ticket is the one this view is
/// showing. The request goes out as the text the socket would carry, so the
/// host and an agent's door cannot disagree about what a ticket does.
fn ask_core(method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
    let Some(api) = crate::api_opt() else { return Err("the core is not running".into()) };
    let Some(ask) = api.app_files else {
        return Err("this build's core has no file preview calls".into());
    };
    let app = crate::app_opt();
    if app.is_null() {
        return Err("the core is not running".into());
    }
    let request = serde_json::json!({ "method": method, "params": params }).to_string();
    let need = unsafe { ask(app, request.as_ptr(), request.len(), std::ptr::null_mut(), 0) };
    if need == 0 {
        // Zero is this door's "that is not one of the five": named rather
        // than read as an empty answer.
        return Err(format!("{method} is not a request the core answers for a host"));
    }
    let mut buf = vec![0u8; need + 1];
    let wrote = unsafe { ask(app, request.as_ptr(), request.len(), buf.as_mut_ptr(), buf.len()) };
    if wrote == 0 || wrote > need {
        return Err("it changed size between asking and reading".into());
    }
    let text = String::from_utf8(buf[..wrote].to_vec()).map_err(|_| "it is not UTF-8".to_string())?;
    let value: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("the core's answer is not JSON: {e}"))?;
    // `{"refused":...}` is the core's no, in the one shape it refuses in.
    if value.get("refused").is_some() {
        return Err(value.get("why").and_then(|w| w.as_str()).unwrap_or("refused").to_string());
    }
    Ok(value)
}

/// Serve one request the page made over `polter-file://`.
///
/// **The route says which ticket and which `rel`; the core says whether and
/// where.** Nothing in this function builds a path, and there is no branch
/// in which it could: it hands `(token, rel)` to `files_resolve` and writes
/// what came back.
fn serve(args: &ICoreWebView2WebResourceRequestedEventArgs, token: &str) {
    let (env, generation) = PREVIEW.with(|c| {
        let s = c.borrow();
        (s.env.clone(), s.generation)
    });
    let Some(env) = env else { return };
    let uri = unsafe { args.Request() }
        .ok()
        .map(|r| {
            let mut u = PWSTR::null();
            let _ = unsafe { r.Uri(&mut u) };
            take_pwstr(u)
        })
        .unwrap_or_default();

    let (status, reason, body, ctype) = match polter_preview_route::resolve(&uri) {
        Ok(route) => {
            // A page may only ask about the ticket it was served from: a
            // second token in the URL is another file's capability, and
            // this view was never given it.
            if route.token != token {
                // process-wide: as above
                crate::plogf!("[preview] {}: request for another ticket's file refused", token);
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
            crate::plogf!("[preview] {}: request for {:?} refused ({:?})", token, uri, why);
            let (status, reason) = match why {
                Refused::OtherScheme | Refused::BadToken => (403, "Forbidden"),
                Refused::Outside | Refused::BadEscape => (403, "Forbidden"),
            };
            (status, reason, Vec::new(), "text/plain")
        }
    };
    // Generation check: a request that arrived for a view that has since
    // been replaced is dropped rather than answered into the new one.
    if PREVIEW.with(|c| c.borrow().generation) != generation {
        return;
    }
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
        env.CreateWebResourceResponse(stream.as_ref(), status, PCWSTR(reason.as_ptr()), PCWSTR(headers.as_ptr()))
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
    let from_here = match polter_preview_route::resolve(&source) {
        Ok(r) => r.token == token,
        Err(_) => false,
    };
    if !from_here {
        // process-wide: as above
        crate::plogf!("[preview] {}: message from {:?} ignored", token, source);
        return;
    }
    let mut j = PWSTR::null();
    let _ = unsafe { args.WebMessageAsJson(&mut j) };
    let text = take_pwstr(j);
    let Ok(msg) = serde_json::from_str::<serde_json::Value>(&text) else { return };
    let id = msg.get("id").cloned().unwrap_or(serde_json::Value::Null);
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let argument = msg.get("argument").cloned().unwrap_or(serde_json::Value::Null);

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
fn answer(call: Call, token: &str, argument: &serde_json::Value) -> Result<serde_json::Value, String> {
    match call {
        // What the file is. The core's `files_open` answer carries this for
        // the ticket's own file, and it is reread on every ask rather than
        // kept, so a file that changed under the preview is not described
        // by what it was.
        Call::Info => ask_core("files_resolve", serde_json::json!({ "token": token, "rel": "" })),
        Call::Read => {
            let rel = argument.get("rel").and_then(|r| r.as_str()).unwrap_or("");
            let resolved = ask_core("files_resolve", serde_json::json!({ "token": token, "rel": rel }))?;
            let path = resolved.get("path").and_then(|p| p.as_str()).ok_or("refused")?;
            let offset = argument.get("offset").and_then(|o| o.as_u64()).unwrap_or(0) as usize;
            let length = argument.get("length").and_then(|l| l.as_u64()).unwrap_or(0) as usize;
            let length = if length == 0 { READ_MAX } else { length.min(READ_MAX) };
            let bytes = read_span(path, offset, length)?;
            Ok(serde_json::json!({
                "base64": base64(&bytes),
                "size": resolved.get("size").cloned().unwrap_or(serde_json::Value::Null),
                "truncated": bytes.len() == length,
            }))
        }
        Call::ReadRel => {
            let rel = argument.get("rel").and_then(|r| r.as_str()).ok_or("readRel needs a path")?;
            let mut with_rel = argument.clone();
            with_rel["rel"] = serde_json::Value::String(rel.to_string());
            answer(Call::Read, token, &with_rel)
        }
        // **The host switches the preview; the page does not read a path.**
        // The `rel` goes to the core like any other, so a file outside this
        // ticket's scope is refused here as it would be in an `<img>`.
        Call::OpenPath => {
            let rel = argument.get("rel").and_then(|r| r.as_str()).ok_or("openPath needs a path")?;
            let resolved = ask_core("files_resolve", serde_json::json!({ "token": token, "rel": rel }))?;
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
            let full_text = argument.get("fullText").and_then(|t| t.as_str()).ok_or("propose needs text")?;
            let base_version = argument.get("baseVersion").and_then(|v| v.as_str()).unwrap_or("");
            ask_core(
                "files_propose",
                serde_json::json!({ "token": token, "full_text": full_text, "base_version": base_version }),
            )
        }
        // Whether there are unsaved changes. The host keeps this for its
        // own "you have unsaved changes" question; nothing is written.
        Call::Dirty => {
            let dirty = argument.get("dirty").and_then(|d| d.as_bool()).unwrap_or(false);
            Ok(serde_json::json!({ "dirty": dirty }))
        }
    }
}

/// A span of a file the core named, clamped to what is really there.
fn read_span(path: &str, offset: usize, length: usize) -> Result<Vec<u8>, String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path).map_err(|e| e.to_string())?;
    f.seek(SeekFrom::Start(offset as u64)).map_err(|e| e.to_string())?;
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
            format!("#{:02X}{:02X}{:02X}{:02X}", c.r, c.g, c.b, (c.a.clamp(0.0, 1.0) * 255.0).round() as u8)
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
fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
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
        assert!(csp.contains(&format!("{PREVIEW_SCHEME}://{TOKEN}")), "{csp}");
        assert!(csp.contains("connect-src 'none'"), "{csp}");
        assert!(csp.contains("frame-ancestors 'none'"), "{csp}");
        // Another ticket's origin is not named, by construction: the only
        // token in the policy is this one.
        assert_eq!(csp.matches(PREVIEW_SCHEME).count(), 2, "img-src and media-src: {csp}");
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
