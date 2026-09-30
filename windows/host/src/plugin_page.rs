//! A plugin's own page (settings.md §5.3), in WebView2, inside the Plugins
//! section's Page tab. **The behaviour is `PluginPage.swift`'s**: served over
//! `polter-plugin://<key>/` from the plugin's `ui/`, one origin per plugin,
//! nothing kept on disk, no network, no new windows, and one object on the
//! page -- `window.polter` with `settings()`, `save(next)` and `close()` --
//! which is the whole of what the page can reach. The reasons are written
//! out in that file's header and are not repeated here.
//!
//! # Loading WebView2 without depending on it
//!
//! **The Runtime may not be on the machine** (Server 2022 ships without it),
//! and the page tab has to say so rather than the process failing to start.
//! So `WebView2Loader.dll` is never linked: it is loaded by full path from
//! beside the executable when the page is first shown, and its two entry
//! points are resolved by name. `webview2-com` supplies only the COM
//! interface definitions and the callback objects; its own
//! `CreateCoreWebView2Environment*` wrappers are never called, which is what
//! keeps the DLL out of the import table (checked on the built exe with
//! `objdump -p`, see the task's report). Which of the three ways it can be
//! missing is `polter_settings_shell::plugins::page_state`.
//!
//! ⚠️ **No WebView2 call is made while `PAGE` is borrowed.** The interfaces
//! are cloned out first: WebView2 raises some events synchronously, and a
//! handler here borrows the cell.

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use polter_settings_shell::plugins::{self as rules, Call, PageState};
use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::{
    CoreWebView2CustomSchemeRegistration, CoreWebView2EnvironmentOptions, CreateCoreWebView2ControllerCompletedHandler,
    CreateCoreWebView2EnvironmentCompletedHandler, NavigationStartingEventHandler, NewWindowRequestedEventHandler,
    WebMessageReceivedEventHandler, WebResourceRequestedEventHandler,
};
use windows::core::{Interface, HRESULT, PCWSTR, PWSTR};
use windows::Win32::Foundation::{HMODULE, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryExW, LOAD_WITH_ALTERED_SEARCH_PATH};
use windows::Win32::UI::Shell::SHCreateMemStream;
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

use crate::plugins::{self, Plugin};

/// Posted to the plugins section when the page saved (`wparam` 1) or asked
/// to close (2). **`WM_APP + 19`**, free when written (`grep 'WM_APP +'`);
/// posted to that one window only. Posted rather than called: the section's
/// answer rebuilds the page, and that must not happen inside the page's own
/// message handler.
pub const WM_PAGE_EVENT: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 19;

type CreateEnv = unsafe extern "system" fn(PCWSTR, PCWSTR, *mut std::ffi::c_void, *mut std::ffi::c_void) -> HRESULT;
type GetVersion = unsafe extern "system" fn(PCWSTR, *mut PWSTR) -> HRESULT;

#[derive(Clone, Copy)]
struct Loader {
    create: CreateEnv,
}

struct Page {
    /// Asked once per process: the Runtime does not appear under a running
    /// program. `None` until the page is first shown.
    probed: Option<(Option<Loader>, PageState)>,
    env: Option<ICoreWebView2Environment>,
    /// Being made: another request waits for it rather than making a second.
    env_pending: bool,
    controller: Option<ICoreWebView2Controller>,
    /// The plugin the controller shows, or is being made for.
    key: Option<String>,
    dir: PathBuf,
    parent: HWND,
    rect: RECT,
    /// Bumped whenever the page on screen should change: a completion that
    /// arrives for an older one closes what it made.
    generation: u64,
    state: PageState,
}

thread_local! {
    static PAGE: RefCell<Page> = RefCell::new(Page {
        probed: None,
        env: None,
        env_pending: false,
        controller: None,
        key: None,
        dir: PathBuf::new(),
        parent: HWND(std::ptr::null_mut()),
        rect: RECT::default(),
        generation: 0,
        state: PageState::Loading,
    });
}

/// What the page tab can show now. The section paints a sentence for every
/// state but `Loading` and `Ready`.
pub fn state() -> PageState {
    PAGE.with(|p| p.borrow().state.clone())
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn take_pwstr(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { p.to_string() }.unwrap_or_default();
    unsafe { CoTaskMemFree(Some(p.0 as *const std::ffi::c_void)) };
    s
}

/// Find the loader beside the executable and ask it for the Runtime.
fn probe() -> (Option<Loader>, PageState) {
    let Some(path) = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join("WebView2Loader.dll"))) else {
        return (None, rules::page_state(false, Err(0)));
    };
    let w = wide(&path.display().to_string());
    let module: HMODULE = match unsafe { LoadLibraryExW(PCWSTR(w.as_ptr()), None, LOAD_WITH_ALTERED_SEARCH_PATH) } {
        Ok(m) => m,
        Err(e) => {
            // process-wide: the WebView2 loader, looked for once per process
            crate::plogf!("[page] {} did not load: {:?}", path.display(), e);
            return (None, rules::page_state(false, Err(0)));
        }
    };
    let create = unsafe { GetProcAddress(module, windows::core::s!("CreateCoreWebView2EnvironmentWithOptions")) };
    let version = unsafe { GetProcAddress(module, windows::core::s!("GetAvailableCoreWebView2BrowserVersionString")) };
    let (Some(create), Some(version)) = (create, version) else {
        // process-wide: as above
        crate::plogf!("[page] {} has no WebView2 entry points", path.display());
        return (None, rules::page_state(false, Err(0)));
    };
    let create: CreateEnv = unsafe { std::mem::transmute(create) };
    let version: GetVersion = unsafe { std::mem::transmute(version) };
    let mut v = PWSTR::null();
    let hr = unsafe { version(PCWSTR::null(), &mut v) };
    let text = take_pwstr(v);
    let answer = if hr.is_ok() { Ok(text.as_str()) } else { Err(hr.0) };
    let st = rules::page_state(true, answer);
    // process-wide: as above
    crate::plogf!("[page] loader {} found; runtime version {:?} hr=0x{:08X} -> {:?}", path.display(), text, hr.0 as u32, st);
    (Some(Loader { create }), st)
}

/// Show `p`'s page in `rect` of `parent` (the section window).
pub fn show(parent: HWND, rect: RECT, p: &Plugin) {
    let probed = PAGE.with(|c| c.borrow().probed.clone());
    let (loader, st) = match probed {
        Some(x) => x,
        None => {
            let x = probe();
            PAGE.with(|c| c.borrow_mut().probed = Some(x.clone()));
            x
        }
    };
    let Some(loader) = loader.filter(|_| st == PageState::Loading) else {
        PAGE.with(|c| c.borrow_mut().state = st);
        return;
    };
    let dir = p.dir.clone();
    let (same, controller) = PAGE.with(|c| {
        let s = &mut *c.borrow_mut();
        s.parent = parent;
        s.rect = rect;
        (s.key.as_deref() == Some(p.key.as_str()), s.controller.clone())
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
    // Another plugin: the old page goes, the new one is made.
    close_controller();
    let generation = PAGE.with(|c| {
        let s = &mut *c.borrow_mut();
        s.key = Some(p.key.clone());
        s.dir = dir;
        s.generation += 1;
        s.state = PageState::Loading;
        s.generation
    });
    let env = PAGE.with(|c| c.borrow().env.clone());
    match env {
        Some(env) => make_controller(env, generation),
        None => make_env(loader),
    }
}

/// Take the page off screen. The controller is kept for the same plugin:
/// switching tabs back should not reload what the person was doing.
pub fn hide() {
    let ctl = PAGE.with(|c| c.borrow().controller.clone());
    if let Some(ctl) = ctl {
        unsafe {
            let _ = ctl.SetIsVisible(false);
        }
    }
}

fn close_controller() {
    let ctl = PAGE.with(|c| {
        let s = &mut *c.borrow_mut();
        s.key = None;
        s.controller.take()
    });
    if let Some(ctl) = ctl {
        unsafe {
            let _ = ctl.Close();
        }
    }
}

/// `%LOCALAPPDATA%\polter\webview2`: WebView2 needs a folder of its own even
/// for an InPrivate page, and the default -- beside the executable -- may
/// not be writable.
fn user_data_dir() -> Option<PathBuf> {
    Some(plugins::user_dir()?.parent()?.join("webview2"))
}

fn make_env(loader: Loader) {
    if PAGE.with(|c| std::mem::replace(&mut c.borrow_mut().env_pending, true)) {
        return;
    }
    let reg = CoreWebView2CustomSchemeRegistration::new(rules::SCHEME.to_string());
    unsafe {
        reg.set_treat_as_secure(true);
        reg.set_has_authority_component(true);
    }
    let options = CoreWebView2EnvironmentOptions::default();
    unsafe { options.set_scheme_registrations(vec![Some(reg.into())]) };
    let options: ICoreWebView2EnvironmentOptions = options.into();
    let handler = CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(move |hr, env| {
        PAGE.with(|c| c.borrow_mut().env_pending = false);
        match (hr, env) {
            (Ok(()), Some(env)) => {
                let generation = PAGE.with(|c| {
                    let s = &mut *c.borrow_mut();
                    s.env = Some(env.clone());
                    s.generation
                });
                make_controller(env, generation);
            }
            (r, _) => failed("environment", r.err().map(|e| e.code().0).unwrap_or(-1)),
        }
        Ok(())
    }));
    let folder = user_data_dir().map(|d| wide(&d.display().to_string()));
    let folder_ptr = folder.as_ref().map(|w| PCWSTR(w.as_ptr())).unwrap_or(PCWSTR::null());
    let hr = unsafe { (loader.create)(PCWSTR::null(), folder_ptr, options.as_raw(), handler.as_raw()) };
    if hr.is_err() {
        PAGE.with(|c| c.borrow_mut().env_pending = false);
        failed("environment", hr.0);
    }
}

fn failed(what: &str, hr: i32) {
    // process-wide: the one plugin page the settings window can show
    crate::plogf!("[page] making the {} failed: 0x{:08X}", what, hr as u32);
    let parent = PAGE.with(|c| {
        let s = &mut *c.borrow_mut();
        s.state = PageState::Failed(hr);
        s.parent
    });
    unsafe {
        let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(parent), None, false);
    }
}

fn make_controller(env: ICoreWebView2Environment, generation: u64) {
    let parent = PAGE.with(|c| c.borrow().parent);
    let handler = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(move |hr, ctl| {
        let Some(ctl) = ctl.filter(|_| hr.is_ok()) else {
            failed("view", hr.err().map(|e| e.code().0).unwrap_or(-1));
            return Ok(());
        };
        let current = PAGE.with(|c| c.borrow().generation);
        if current != generation {
            // Made for a plugin that is no longer on screen.
            unsafe {
                let _ = ctl.Close();
            }
            return Ok(());
        }
        if let Err(e) = configure(&ctl) {
            unsafe {
                let _ = ctl.Close();
            }
            failed("view", e.code().0);
            return Ok(());
        }
        let (rect, parent) = PAGE.with(|c| {
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
    // InPrivate: nothing the page stores outlives it or reaches the next
    // plugin's page (`websiteDataStore = .nonPersistent()` on the macOS side).
    let with_options = env.cast::<ICoreWebView2Environment10>().ok().and_then(|e10| {
        let o = unsafe { e10.CreateCoreWebView2ControllerOptions() }.ok()?;
        unsafe { o.SetIsInPrivateModeEnabled(true) }.ok()?;
        Some((e10, o))
    });
    let r = match with_options {
        Some((e10, o)) => unsafe { e10.CreateCoreWebView2ControllerWithOptions(parent, &o, &handler) },
        None => {
            // process-wide: as above
            crate::plogf!("[page] this runtime has no controller options; the page is not InPrivate");
            unsafe { env.CreateCoreWebView2Controller(parent, &handler) }
        }
    };
    if let Err(e) = r {
        failed("view", e.code().0);
    }
}

/// What the page may do, set on a new view before it loads anything.
fn configure(ctl: &ICoreWebView2Controller) -> windows::core::Result<()> {
    let key = PAGE.with(|c| c.borrow().key.clone()).unwrap_or_default();
    unsafe {
        let wv = ctl.CoreWebView2()?;
        let settings = wv.Settings()?;
        settings.SetAreDevToolsEnabled(false)?;
        settings.SetAreDefaultContextMenusEnabled(false)?;
        settings.SetIsStatusBarEnabled(false)?;
        settings.SetIsWebMessageEnabled(true)?;
        settings.SetIsScriptEnabled(true)?;

        // Every request, whatever its scheme, comes here: ours are served
        // from `ui/`, everything else is answered 403 (no network, §5.3's
        // "no network" twice over with the CSP header).
        let all = wide("*");
        wv.AddWebResourceRequestedFilter(PCWSTR(all.as_ptr()), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)?;
        let k = key.clone();
        let mut token = 0i64;
        wv.add_WebResourceRequested(
            &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    serve(&args, &k);
                }
                Ok(())
            })),
            &mut token,
        )?;
        // A link to anywhere else does nothing.
        let k = key.clone();
        wv.add_NavigationStarting(
            &NavigationStartingEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    let mut uri = PWSTR::null();
                    let _ = args.Uri(&mut uri);
                    let uri = take_pwstr(uri);
                    if rules::resolve(&uri, &k).is_err() {
                        let _ = args.SetCancel(true);
                        // process-wide: as above
                        crate::plogf!("[page] {}: navigation to {:?} refused", k, uri);
                    }
                }
                Ok(())
            })),
            &mut token,
        )?;
        // No new windows: `window.open` and `target=_blank` get nothing.
        wv.add_NewWindowRequested(
            &NewWindowRequestedEventHandler::create(Box::new(move |_, args| {
                if let Some(args) = args {
                    let _ = args.SetHandled(true);
                }
                Ok(())
            })),
            &mut token,
        )?;
        let k = key.clone();
        wv.add_WebMessageReceived(
            &WebMessageReceivedEventHandler::create(Box::new(move |wv, args| {
                if let (Some(wv), Some(args)) = (wv, args) {
                    on_message(&wv, &args, &k);
                }
                Ok(())
            })),
            &mut token,
        )?;
        let script = wide(BRIDGE);
        wv.AddScriptToExecuteOnDocumentCreated(PCWSTR(script.as_ptr()), None)?;
        let url = wide(&rules::entry_url(&key));
        wv.Navigate(PCWSTR(url.as_ptr()))?;
    }
    // process-wide: as above
    crate::plogf!("[page] {}: view made, loading {}", key, rules::entry_url(&key));
    Ok(())
}

/// What the page finds on `window`: the three calls, each a promise, frozen
/// and non-configurable so a dependency that runs later cannot replace it.
/// Top frame only -- a frame the page embeds does not get the bridge.
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
      settings: () => post("read"),
      save: (next) => post("write", next || {}),
      close: () => post("close"),
    }),
    writable: false,
    configurable: false,
  });
})();"#;

fn serve(args: &ICoreWebView2WebResourceRequestedEventArgs, key: &str) {
    let (dir, env) = PAGE.with(|c| {
        let s = c.borrow();
        (s.dir.clone(), s.env.clone())
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
    let (status, reason, body, ctype) = match rules::resolve(&uri, key) {
        Ok(segs) => match read_inside(&dir.join("ui"), &segs) {
            Some(bytes) => (200, "OK", bytes, rules::content_type(segs.last().map(String::as_str).unwrap_or(""))),
            None => (404, "Not Found", Vec::new(), "text/plain"),
        },
        Err(why) => {
            // process-wide: as above
            crate::plogf!("[page] {}: request for {:?} refused ({:?})", key, uri, why);
            (403, "Forbidden", Vec::new(), "text/plain")
        }
    };
    let headers = format!(
        "Content-Type: {ctype}\r\nContent-Security-Policy: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff",
        rules::CSP
    );
    let stream = unsafe { SHCreateMemStream(Some(&body)) };
    let reason = wide(reason);
    let headers = wide(&headers);
    if let Ok(resp) = unsafe { env.CreateWebResourceResponse(stream.as_ref(), status, PCWSTR(reason.as_ptr()), PCWSTR(headers.as_ptr())) } {
        let _ = unsafe { args.SetResponse(&resp) };
    }
}

/// The file at `segs` under `root`, **only if it is still under `root`
/// once links are followed**: `resolve` fences the path's spelling, this
/// fences where it really lands.
fn read_inside(root: &Path, segs: &[String]) -> Option<Vec<u8>> {
    let root = std::fs::canonicalize(root).ok()?;
    let mut p = root.clone();
    for s in segs {
        p.push(s);
    }
    let real = std::fs::canonicalize(&p).ok()?;
    if !real.starts_with(&root) || !real.is_file() {
        return None;
    }
    std::fs::read(real).ok()
}

fn on_message(wv: &ICoreWebView2, args: &ICoreWebView2WebMessageReceivedEventArgs, key: &str) {
    let mut src = PWSTR::null();
    let _ = unsafe { args.Source(&mut src) };
    let source = take_pwstr(src);
    if !rules::message_from_page(&source, key) {
        // process-wide: as above
        crate::plogf!("[page] {}: message from {:?} ignored", key, source);
        return;
    }
    let mut j = PWSTR::null();
    let _ = unsafe { args.WebMessageAsJson(&mut j) };
    let text = take_pwstr(j);
    let Ok(msg) = serde_json::from_str::<serde_json::Value>(&text) else { return };
    let id = msg.get("id").cloned().unwrap_or(serde_json::Value::Null);
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let reply = match Call::parse(method) {
        Some(Call::Read) => describe(key).map_err(|e| e.to_string()),
        Some(Call::Write) => write(key, msg.get("argument").unwrap_or(&serde_json::Value::Null)),
        Some(Call::Close) => {
            post_section(2);
            Ok(serde_json::Value::Null)
        }
        None => Err(format!("no such call: {method}")),
    };
    let out = match reply {
        Ok(result) => serde_json::json!({ "id": id, "result": result }),
        Err(error) => serde_json::json!({ "id": id, "error": error }),
    };
    let w = wide(&out.to_string());
    let _ = unsafe { wv.PostWebMessageAsJson(PCWSTR(w.as_ptr())) };
}

fn post_section(what: usize) {
    let parent = PAGE.with(|c| c.borrow().parent);
    unsafe {
        let _ = PostMessageW(Some(parent), WM_PAGE_EVENT, WPARAM(what), LPARAM(0));
    }
}

fn find(key: &str) -> Option<Plugin> {
    plugins::catalog().into_iter().find(|p| p.key == key)
}

/// `settings()`: the shape `PluginPageBridge.describe` returns.
fn describe(key: &str) -> Result<serde_json::Value, &'static str> {
    let p = find(key).ok_or("no such plugin")?;
    let parameters: Vec<serde_json::Value> = p
        .params
        .iter()
        .map(|x| {
            let mut d = serde_json::json!({
                "name": x.name, "title": x.title, "help": x.help,
                "required": x.required, "secret": x.secret,
            });
            match &x.control {
                plugins::Control::Text => d["type"] = "text".into(),
                plugins::Control::Flag => d["type"] = "boolean".into(),
                plugins::Control::Choice(c) => {
                    d["type"] = "enum".into();
                    d["choices"] = serde_json::json!(c);
                }
            }
            if let Some(v) = &x.default {
                d["default"] = v.clone().into();
            }
            d
        })
        .collect();
    Ok(serde_json::json!({
        "key": p.key, "name": p.name, "events": p.events,
        "enabled": p.enabled, "params": p.values, "parameters": parameters,
    }))
}

/// `save(next)`: `enabled` and `params` are the whole of it, and what is not
/// named stays as it was. Only text values: a settings file holds strings.
fn write(key: &str, arg: &serde_json::Value) -> Result<serde_json::Value, String> {
    let p = find(key).ok_or("no such plugin")?;
    let enabled = arg.get("enabled").and_then(|b| b.as_bool()).unwrap_or(p.enabled);
    let mut values = p.values.clone();
    if let Some(obj) = arg.get("params").and_then(|x| x.as_object()) {
        for (k, v) in obj {
            if let Some(s) = v.as_str() {
                values.insert(k.clone(), s.to_string());
            }
        }
    }
    if plugins::configure(key, enabled, &values)? == plugins::Saved::Applied {
        let kept = values.iter().filter(|(_, v)| !v.is_empty()).map(|(k, v)| (k.clone(), v.clone())).collect();
        plugins::started_with(key, (enabled, kept));
    }
    post_section(1);
    describe(key).map_err(|e| e.to_string())
}
