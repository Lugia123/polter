//! Re-reading the config file, which is the whole of what «重载配置» means.
//!
//! **What was here before.** `menu.rs` has a `重载配置` row and `keys.rs`
//! binds `ctrl+shift+,` to `reload_config`. Both worked, in the sense that the
//! core parsed the binding, performed it, and handed
//! `GHOSTTY_ACTION_RELOAD_CONFIG` to the host -- where the arm asked the
//! settings window to refresh its error list and answered `true`. Nothing
//! re-read the file and nothing told the core. Editing the config and
//! pressing the key changed nothing at all, and the log said
//! `[action] config_change/reload_config`, which reads exactly like it
//! worked.
//!
//! `ghostty_app_update_config` appeared **zero times** in this host. That is
//! also why the seven things `App.updateConfig` sets -- the agent socket, the
//! notice interval, the stand-down rule, the three Poltergeist timers and the
//! compaction threshold -- sat at their struct defaults for the life of a
//! Windows process. The doc comment on `App.zig`'s `ensurePoltergeistServer`
//! says in so many words that `updateConfig` runs only on a config reload and
//! that neither apprt calls it at launch -- so a *reload* is the only thing
//! that ever sets them, and on this platform there was no reload.
//!
//! # Why any of this needs a window
//!
//! `cb_action` arrives on whichever thread the core is on. `App.updateConfig`
//! is documented main-thread-only, and the handle it replaces (`CONFIG`) is
//! read by `keys.rs` while a menu is being built and by `settings_ui.rs`
//! while the error list is drawn -- both on the thread that owns windows. So
//! the work is posted to a message-only window created on that thread and
//! done from its window procedure, which is what makes freeing the old handle
//! safe rather than a race nobody would ever reproduce.
//!
//! **The cost of that, stated rather than hidden:** there is no call edge
//! between [`request`] and `perform`. A `PostMessage` to a window nobody
//! pumps looks, in the source, exactly like a working one.
//!
//! # Two tags that say opposite things
//!
//! `reload_config` asks the host to go and read. `config_change` tells the
//! host what was read -- and `App.updateConfig` performs it at the end of
//! itself, synchronously, before returning. They shared
//! one arm in `cb_action`, which was harmless only because that arm did not
//! reload: make it reload and it feeds itself, reload -> update_config ->
//! config_change -> reload, with nothing to stop it. They are two arms now,
//! and [`on_config_change`] is the half that must never read the file.
//!
//! # Soft and hard
//!
//! `ghostty_action_reload_config_s` carries one bool. Hard (`soft = false`)
//! is a person asking for the file to be read again. Soft is the core saying
//! its own conditional state moved -- the system went dark, say -- and it
//! wants the values recomputed against the config the host already holds.
//! Reading the file on a soft reload would throw away nothing today, but it
//! would turn a theme switch into a disk read on every toggle; and a soft
//! reload aimed at *a surface* is a per-surface recompute that must not touch
//! the app config at all.

use std::sync::atomic::{AtomicPtr, Ordering};

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, PostMessageW, RegisterClassW, HWND_MESSAGE, WINDOW_EX_STYLE,
    WINDOW_STYLE, WM_APP, WNDCLASSW,
};

use crate::ffi;
use crate::{plogf, wlogf};

/// Ask for a reload on the thread that owns windows.
///
/// `wparam` is the `soft` flag; `lparam` is the surface the core aimed the
/// action at, or null for an app-wide one.
const WM_POLTER_RELOAD_CONFIG: u32 = WM_APP + 1;

/// The message-only window. Null until [`init`] runs, and a null here is a
/// reload that is dropped **with a line saying so** -- the alternative is a
/// menu row that silently does nothing, which is the defect this file exists
/// to end.
static HWND_RELOAD: AtomicPtr<std::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Create the message-only window. Called from `main` on the thread that owns
/// windows, next to the other module `init`s.
pub fn init(hinst: HINSTANCE) {
    unsafe {
        let class = w!("PolterReloadConfig");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(reload_proc),
            hInstance: hinst,
            lpszClassName: class,
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 {
            // process-wide: one window class for the whole process, before any
            // frame is involved
            plogf!("[reload] RegisterClassW failed; «重载配置» will do nothing");
            return;
        }
        // Message-only: it never shows, and its messages are pumped by the
        // main loop like any other window this thread owns. The same shape
        // `menu.rs` uses for its self-test.
        match CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR::null(),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => {
                HWND_RELOAD.store(h.0, Ordering::Release);
                // process-wide: the reload route is one per process
                plogf!("[reload] ready");
            }
            // Said out loud: a reload route that failed to exist reads, from
            // the chair, as a menu item that does nothing -- which is the
            // state this file was written to leave behind.
            // process-wide: no window exists to attribute this to; that is the
            // fact being reported
            Err(e) => plogf!("[reload] CreateWindowExW failed: {e:?}; «重载配置» will do nothing"),
        }
    }
}

/// **Safe from any thread.** The core performs this action from wherever it
/// happens to be; the work happens on the thread that owns windows.
///
/// Returns whether the request was posted, which is what `cb_action` answers
/// to the core -- `true` here means "this host has taken it on", not "the
/// config has been reloaded", and those are one message apart.
pub fn request(soft: bool, surface: ffi::Surface) -> bool {
    let h = HWND_RELOAD.load(Ordering::Acquire);
    if h.is_null() {
        // process-wide: the reload window does not exist, so there is no
        // window this line could belong to
        plogf!("[reload] asked for before init; dropped");
        return false;
    }
    unsafe {
        PostMessageW(
            Some(HWND(h)),
            WM_POLTER_RELOAD_CONFIG,
            WPARAM(soft as usize),
            LPARAM(surface as isize),
        )
        .is_ok()
    }
}

extern "system" fn reload_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_POLTER_RELOAD_CONFIG {
        perform(wp.0 != 0, lp.0 as ffi::Surface);
        return LRESULT(0);
    }
    unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
}

/// The reload itself, on the thread that owns windows.
fn perform(soft: bool, surface: ffi::Surface) {
    let api = crate::api();

    // **A surface target is never a file read.** The only thing that sends
    // one is `Surface.notifyConfigConditionalState`, which is the core
    // telling us its own conditional state moved; the answer is to recompute
    // that surface against the config we already hold.
    if !surface.is_null() {
        // **Checked for liveness first.** The pointer travelled through a
        // `PostMessage`, and a surface can close between the post and here --
        // at which point handing it to the core is a use-after-free, not a
        // wrong answer.
        let frame = crate::tabs::frame_of_surface(surface);
        let cfg = crate::config_handle();
        match (frame, cfg.is_null()) {
            (Some(f), false) => {
                unsafe { (api.surface_update_config)(surface, cfg) };
                wlogf!(f, "[reload] surface soft={} -> surface_update_config", soft as u8);
            }
            // The quick terminal's surface is not a pane, so `frame_of_surface`
            // does not find it. Reported rather than guessed at: sending this
            // to some other surface would be silent and wrong.
            (None, _) => {
                // process-wide: the surface is in no window this host tracks,
                // which is the fact being reported
                plogf!("[reload] surface {surface:?} is in no live window; dropped");
            }
            (Some(f), true) => wlogf!(f, "[reload] no config handle yet; dropped"),
        }
        return;
    }

    let app = crate::app_handle();
    if app.is_null() {
        // process-wide: there is no app, so no window either
        plogf!("[reload] no app yet; dropped");
        return;
    }

    // A soft app reload hands the core back what it already gave us. macOS
    // does the same thing (`reloadConfig(soft:)`), and for the same reason:
    // the file has not changed, the conditions have.
    if soft {
        let cfg = crate::config_handle();
        if cfg.is_null() {
            // process-wide: no config handle exists yet
            plogf!("[reload] soft reload with no config handle; dropped");
            return;
        }
        unsafe { (api.app_update_config)(app, cfg) };
        // process-wide: the app config is one per process
        plogf!("[reload] soft -> app_update_config with the config already held");
        return;
    }

    // ---- the hard reload: read the file again ----
    //
    // The same three calls `main` makes at startup, in the same order. A
    // config that fails to parse is still a config -- the core reports the
    // trouble as diagnostics and carries on with what it could read -- so
    // there is no "did it load" bool to check here, and the count is logged
    // instead of being turned into a refusal.
    let fresh = unsafe {
        let c = (api.config_new)();
        (api.config_load_default_files)(c);
        (api.config_finalize)(c);
        c
    };
    if fresh.is_null() {
        // process-wide: no config was produced, so nothing changed anywhere
        plogf!("[reload] ghostty_config_new returned null; keeping the old config");
        return;
    }
    let diagnostics = unsafe { (api.config_diagnostics_count)(fresh) };

    // **Swapped before the core is told**, because `app_update_config`
    // performs `.config_change` back at us before it returns, on this thread,
    // and the arm that answers it asks the settings window to redraw its
    // error list -- from `CONFIG`. Swap afterwards and that list is the
    // previous file's diagnostics, which is the one reading a person would
    // use to decide whether their edit was accepted.
    let old = crate::adopt_config(fresh);

    unsafe { (api.app_update_config)(app, fresh) };

    // **The core kept nothing.** `embedded.zig` clones what it needs before
    // returning, and the header says the caller may free immediately. So the
    // old handle is ours, and it goes now -- a reload is a key people hold
    // down while they edit a theme, and a whole `Config` leaked per press has
    // a slope.
    //
    // **What makes that safe is an enumeration, not a lock**, so here is the
    // enumeration: `config_handle` has three callers -- `keys::shortcut_for`
    // and `keys::trigger_lookup`, reached while a menu is being built and
    // from `quick::init`, and `settings_ui`'s error list. All three are on
    // the thread that owns windows, which is this one, and none of them keeps
    // the pointer past its own call. A fourth caller on another thread would
    // make this a use-after-free with no symptom until the timing is wrong,
    // which is why the list is written down where the free is.
    if !old.is_null() && old != fresh {
        unsafe { (api.config_free)(old) };
    }

    // process-wide: the app config is one per process
    plogf!(
        "[reload] hard -> re-read the file, {} diagnostic(s), handed to the core, old handle freed={}",
        diagnostics,
        (!old.is_null() && old != fresh) as u8
    );

    // Last, so the window is asked to redraw once, after the swap.
    crate::settings_ui::request_errors();
}

/// The core telling us what it just applied.
///
/// **This must never read the file.** It is performed from inside
/// `app_update_config`, so a re-read here is a recursion with nothing to stop
/// it. All it does is let anything that renders config-derived state know
/// that state moved.
///
/// **The payload is not adopted**, and the reason is a lifetime: the config
/// pointer this action carries is valid only for the duration of the call
/// (`apprt/action.zig` says so on `ConfigChange`), so keeping it would need
/// `ghostty_config_clone` and a second owner for the clone. What that costs
/// today is that `CONFIG` is the config as *read*, not as the core sees it
/// after applying its conditional state -- the two differ only where a
/// `light:`/`dark:` conditional is in play, and only for the values a menu
/// shortcut is looked up from.
pub fn on_config_change() {
    crate::settings_ui::request_errors();
}
