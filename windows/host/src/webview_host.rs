//! The WebView2 shell a plugin's settings page and a file preview are both
//! served in (task 2628, #2140 W1; `polter-artifacts/2145/PLAN.md` §2.1:
//! "Windows：同样从 `plugin_page.rs` 抽出 `webview_host.rs`，预览用它").
//!
//! **The behaviour is `PluginPage.swift`'s, and the macOS twin of this file
//! is `macos/Sources/Features/Preview/PluginWebView.swift`**: served over a
//! custom scheme, one origin per page, nothing kept on disk, no network, no
//! new windows. The reasons are written out in that file's header and are
//! not repeated here.
//!
//! What lives here is everything about a WebView2 that is **not** about what
//! the page can do: loading the Runtime without depending on it, where its
//! user-data folder goes, and the four small conversions both pages need.
//! What a page's `window.polter` may reach stays in the page that serves it
//! (`plugin_page.rs`, `preview_page.rs`), because that is the part that must
//! differ.
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

use std::path::{Path, PathBuf};

use polter_settings_shell::plugins as settings;
use windows::core::{HRESULT, PCWSTR, PWSTR};
use windows::Win32::Foundation::HMODULE;
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryExW, LOAD_WITH_ALTERED_SEARCH_PATH};

/// `CreateCoreWebView2EnvironmentWithOptions`, resolved out of the loader
/// DLL by name.
pub type CreateEnv = unsafe extern "system" fn(
    PCWSTR,
    PCWSTR,
    *mut std::ffi::c_void,
    *mut std::ffi::c_void,
) -> HRESULT;

/// `GetAvailableCoreWebView2BrowserVersionString`, likewise.
pub type GetVersion = unsafe extern "system" fn(PCWSTR, *mut PWSTR) -> HRESULT;

/// The two entry points, once the DLL beside the executable has been asked
/// for them.
#[derive(Clone, Copy)]
pub struct Loader {
    pub create: CreateEnv,
}

/// A NUL-terminated UTF-16 copy of `s`, for the Win32 calls that want one.
pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Take a `PWSTR` the Runtime handed back, freeing the COM allocation it
/// came in. Empty for a null pointer, which is what a version string that
/// was never written looks like.
pub fn take_pwstr(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { p.to_string() }.unwrap_or_default();
    unsafe { CoTaskMemFree(Some(p.0 as *const std::ffi::c_void)) };
    s
}

/// Find `WebView2Loader.dll` beside the executable and ask it for the
/// Runtime. `None` with the reason when the DLL is not there or has no entry
/// points; the state says which of the three ways the page is unavailable.
///
/// **Once per process**, and the caller keeps the answer: the Runtime does
/// not appear under a running program, so a second probe would cost a
/// `LoadLibraryExW` and say the same thing.
pub fn probe() -> (Option<Loader>, settings::PageState) {
    let Some(path) = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join("WebView2Loader.dll")))
    else {
        return (None, settings::page_state(false, Err(0)));
    };
    let w = wide(&path.display().to_string());
    let module: HMODULE =
        match unsafe { LoadLibraryExW(PCWSTR(w.as_ptr()), None, LOAD_WITH_ALTERED_SEARCH_PATH) } {
            Ok(m) => m,
            Err(e) => {
                // process-wide: the WebView2 loader, looked for once per process
                crate::plogf!("[webview] {} did not load: {:?}", path.display(), e);
                return (None, settings::page_state(false, Err(0)));
            }
        };
    let create =
        unsafe { GetProcAddress(module, windows::core::s!("CreateCoreWebView2EnvironmentWithOptions")) };
    let version =
        unsafe { GetProcAddress(module, windows::core::s!("GetAvailableCoreWebView2BrowserVersionString")) };
    let (Some(create), Some(version)) = (create, version) else {
        // process-wide: as above
        crate::plogf!("[webview] {} has no WebView2 entry points", path.display());
        return (None, settings::page_state(false, Err(0)));
    };
    let create: CreateEnv = unsafe { std::mem::transmute(create) };
    let version: GetVersion = unsafe { std::mem::transmute(version) };
    let mut v = PWSTR::null();
    let hr = unsafe { version(PCWSTR::null(), &mut v) };
    let text = take_pwstr(v);
    let answer = if hr.is_ok() { Ok(text.as_str()) } else { Err(hr.0) };
    let st = settings::page_state(true, answer);
    // process-wide: as above
    crate::plogf!(
        "[webview] loader {} found; runtime version {:?} hr=0x{:08X} -> {:?}",
        path.display(),
        text,
        hr.0 as u32,
        st
    );
    (Some(Loader { create }), st)
}

/// `%LOCALAPPDATA%\polter\webview2`: WebView2 needs a folder of its own even
/// for an InPrivate page, and the default -- beside the executable -- may
/// not be writable.
///
/// **One folder for every web view in the process**, which is what the
/// macOS side does too: `websiteDataStore = .nonPersistent()` is per view,
/// and nothing a page stores is reachable from another because of that and
/// not because of this path.
pub fn user_data_dir() -> Option<PathBuf> {
    Some(crate::plugins::user_dir()?.parent()?.join("webview2"))
}

/// The file at `segs` under `root`, **only if it is still under `root` once
/// links are followed**.
///
/// The scheme rule fences the path's *spelling* (`polter_settings_shell::
/// plugins::resolve`, `webview_shell`), and this fences where it really
/// lands: a page's own directory is somebody else's directory, so a symlink
/// in it pointing at `~/.ssh` is a thing that can happen.
///
/// ⚠️ **A preview does not read its file here.** A previewed file's real
/// path comes from the core (`ghostty_app_files`, `files_resolve`), which
/// judges it against the ticket's scope; the host only reads what the core
/// named. This function is for the plugin's own `ui/`, whose fence is a
/// directory rather than a capability.
pub fn read_inside(root: &Path, segs: &[String]) -> Option<Vec<u8>> {
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

/// **The keyboard out of a hidden page** (task 1003): after a page is closed
/// or switched away from, the focus stayed in WebView2's own child window,
/// now invisible, and every key -- Ctrl+W among them -- went into it. It
/// goes back to `parent`, as a click on the surrounding window would.
pub fn take_keyboard_back(parent: windows::Win32::Foundation::HWND) {
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetFocus, SetFocus};
    use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, IsChild, IsWindowVisible, GA_ROOT};
    if parent.0.is_null() {
        return;
    }
    unsafe {
        let f = GetFocus();
        // In the hidden page's own windows -- or, as the test machine read
        // it (task 1005), on the surrounding window itself, where WebView2
        // leaves it when it hides.
        let stranded = !f.0.is_null()
            && (f == parent || (IsChild(parent, f).as_bool() && !IsWindowVisible(f).as_bool()));
        if stranded {
            let to = if crate::plugins_ui::focus_after_page() {
                GetFocus()
            } else {
                let root = GetAncestor(parent, GA_ROOT);
                let _ = SetFocus(Some(root));
                root
            };
            // process-wide: the one page that was on screen
            crate::plogf!("[webview] keyboard taken back from the hidden page ({:?}) to {:?}", f, to);
        }
    }
}
