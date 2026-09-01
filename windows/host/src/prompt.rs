//! The two things the core asks this host to do on the host's own thread: put
//! a title box on screen, and float the window on top.
//!
//! **Why the host owns this and the core does not.** `prompt_surface_title`
//! and `prompt_tab_title` are core actions, but performing them means putting
//! a text field on screen, which no core can do. The core hands the request to
//! the apprt (`GHOSTTY_ACTION_PROMPT_TITLE`, tag 37) and waits; on Windows
//! nothing was listening, so both menu rows opened nothing at all.
//!
//! **The two rows are two different requests, and this file keeps them
//! apart.** The action carries `ghostty_action_prompt_title_e`:
//! `SURFACE` renames this pane's terminal, `TAB` renames the tab and keeps
//! that name against whatever the shell sets afterwards, `WINDOW` renames the
//! window. They arrive on one tag, so an arm that ignored the payload would
//! rename the wrong thing while looking entirely correct -- the same defect
//! the menu itself had when one row was labelled for the tab and wired to the
//! surface.
//!
//! **The typed name goes back through the core, not into the host's model.**
//! On accept this runs `set_tab_title:<text>` (or the surface/window one), the
//! same binding a keybind would; the core then announces the new title through
//! `SET_TITLE` / `SET_TAB_TITLE`, which the host already handles. So there is
//! exactly one path that changes a title, and the box is not a second place
//! that knows what a title means.

use std::cell::RefCell;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_ESCAPE, VK_RETURN};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{logf, plogf, wlogf};

/// Requests posted here from `cb_action`.
///
/// **`cb_action` can arrive on the core's thread**, and both of these touch
/// windows: making one, and re-ordering one. `SetWindowPos` on another
/// thread's window blocks until that thread pumps, and the thread it would be
/// waiting for is the one that may be inside `binding_action` waiting for the
/// core -- so this goes through a message like every other host action.
const WM_HOST_REQUEST: u32 = WM_APP + 12;
const REQ_TITLE: usize = 1;
const REQ_FLOAT: usize = 2;

/// `ghostty_action_float_window_e`.
pub const FLOAT_ON: i32 = 0;
pub const FLOAT_OFF: i32 = 1;
pub const FLOAT_TOGGLE: i32 = 2;

/// `ghostty_action_prompt_title_e`.
pub const SCOPE_SURFACE: i32 = 0;
pub const SCOPE_TAB: i32 = 1;
pub const SCOPE_WINDOW: i32 = 2;

/// The binding this scope's answer is sent back through, and the words on the
/// box. **One table, so the label and the action cannot drift apart** -- they
/// drifted once already, in the menu, and nothing on screen showed it.
fn scope_of(scope: i32) -> Option<(&'static str, &'static str)> {
    match scope {
        SCOPE_SURFACE => Some(("set_surface_title", "改终端标题")),
        SCOPE_TAB => Some(("set_tab_title", "改标签标题")),
        SCOPE_WINDOW => Some(("set_window_title", "改窗口标题")),
        _ => None,
    }
}

struct Open {
    hwnd: isize,
    edit: isize,
    /// The **terminal window** this box belongs to.
    ///
    /// Not `hwnd` above: that is the box's own popup, and a log line naming it
    /// would answer "which window?" with the name of the thing that is asking
    /// the question. Carried because `close` runs from the edit control's
    /// window procedure, which has no way back to the frame.
    frame: isize,
    /// The terminal the typed name will be applied to. 0 = whichever has
    /// focus, which is a fallback and not a default.
    surface: usize,
    /// Which binding the text will be sent through.
    action: &'static str,
    label: &'static str,
    /// What had focus before, for `overlay::focus_back`.
    prev: isize,
}

thread_local! {
    static OPEN: RefCell<Option<Open>> = const { RefCell::new(None) };
}

const PAD: i32 = 12;
const COL_BG: u32 = 0x00403f3d;
const COL_TEXT: u32 = 0x00ffffff;

/// Is the window pinned above the others right now?
///
/// **Asked of the window, not remembered here.** The extended style *is* the
/// state; a copy kept beside it would be the thing that disagrees after any
/// other code path re-orders the window, and the menu tick would then be
/// confidently wrong -- which is the shape of the bug that made read-only
/// per-surface.
pub fn is_float_on_top() -> bool {
    let frame = crate::tabs::frame_hwnd();
    if frame.0.is_null() {
        return false;
    }
    let ex = unsafe { GetWindowLongPtrW(frame, GWL_EXSTYLE) } as u32;
    ex & WS_EX_TOPMOST.0 != 0
}

/// Put the window above the others, or stop. **Main thread only.**
fn float_window(mode: i32) {
    let frame = crate::tabs::frame_hwnd();
    if frame.0.is_null() {
        logf!("[action] float_window {mode}: no frame window");
        return;
    }
    let was = is_float_on_top();
    let want = match mode {
        FLOAT_ON => true,
        FLOAT_OFF => false,
        FLOAT_TOGGLE => !was,
        other => {
            logf!("[action] float_window: unknown mode {other}; nothing changed");
            return;
        }
    };
    let after = unsafe {
        let _ = SetWindowPos(
            frame,
            Some(if want { HWND_TOPMOST } else { HWND_NOTOPMOST }),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
        is_float_on_top()
    };
    // **Read back rather than assume.** `SetWindowPos` can fail quietly, and
    // "we asked for it" is what a menu tick would then be drawn from.
    logf!(
        "[action] float_window mode={mode} was={was} wanted={want} now={after}{}",
        if after == want { "" } else { "  -- the window did NOT change" }
    );
}

/// Pending title requests: the scope, and **which surface asked**.
///
/// A queue rather than one slot, because the message and its argument have to
/// travel together: two requests in flight would otherwise take each other's
/// surface, and the box would rename a terminal nobody pointed at.
static PENDING: std::sync::Mutex<Vec<(i32, usize)>> = std::sync::Mutex::new(Vec::new());

/// Ask for the title box. **Safe from any thread.**
///
/// `surface` is the terminal the core asked about; `None` means the request
/// did not name one, and then the box falls back to the focused surface and
/// says so.
pub fn request_title(scope: i32, surface: Option<crate::ffi::Surface>) {
    if let Ok(mut q) = PENDING.lock() {
        q.push((scope, surface.map(|s| s as usize).unwrap_or(0)));
    }
    post(REQ_TITLE, scope, "title prompt");
}

/// Ask for the window to float, or stop. **Safe from any thread.**
pub fn request_float(mode: i32) {
    post(REQ_FLOAT, mode, "float window");
}

fn post(kind: usize, arg: i32, what: &str) {
    let h = MAILBOX.load(std::sync::atomic::Ordering::Acquire);
    if h.is_null() {
        // Dropped rather than done here: doing it here would make a window on
        // whatever thread the core happened to call us on.
        // process-wide: the mailbox is one message-only window for the whole
        // process, and a request that arrives before it exists has not been
        // resolved to a terminal window yet -- there is nothing to name.
        plogf!("[prompt] {what} asked for before the mailbox existed; dropped");
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_HOST_REQUEST, WPARAM(kind), LPARAM(arg as isize)) };
}

static MAILBOX: std::sync::atomic::AtomicPtr<std::ffi::c_void> =
    std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());

/// Create the message-only window these requests land on.
///
/// **Main thread, once.** Called from `menu.rs`'s one-time setup, which runs
/// on the first paint of the tab strip -- that is the main thread by
/// construction, and it is early. A request that arrives before it says so and
/// is dropped rather than making a window on the core's thread.
pub fn init() {
    unsafe {
        register_class();
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("PolterTitlePrompt"),
            PCWSTR::null(),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            None,
            None,
        );
        match hwnd {
            Ok(h) => {
                MAILBOX.store(h.0, std::sync::atomic::Ordering::Release);
                // process-wide: one message-only window per process, created
                // before any terminal window is involved.
                plogf!("[prompt] ready");
            }
            // process-wide: same window as above; its absence disables the
            // title box and float for every window there will ever be.
            Err(e) => plogf!("[prompt] mailbox window failed: {e:?} -- title box and float will not work"),
        }
    }
}

/// Ask for a title. **Main thread only** -- it makes windows.
///
/// `surface` is the terminal the answer will be applied to; 0 means the
/// request named none, and the focused one is used instead -- said out loud,
/// because that fallback is the failure mode this parameter exists to avoid.
pub fn prompt_title(scope: i32, surface: usize) {
    // **Fetched before the first thing that can fail**, so the lines below can
    // say which window did not get a box. The value is not used for anything
    // else until the box is built.
    let frame = crate::tabs::frame_hwnd();

    let Some((action, label)) = scope_of(scope) else {
        // Said rather than swallowed: a new scope in the core would otherwise
        // look exactly like a menu row that does nothing.
        wlogf!(frame, "[prompt] title requested for unknown scope {scope}; nothing shown");
        return;
    };
    close(false);

    if frame.0.is_null() {
        // process-wide: there is no window to name -- that is what this line
        // reports. Naming one here would have to invent it.
        plogf!("[prompt] no frame window; {label} box not shown");
        return;
    }
    let scale = crate::tabs::scale_of();
    let s = |v: i32| ((v as f64) * scale).round() as i32;

    // The tab's current name, so the box opens on what is being changed
    // rather than on nothing. **Read from the model, not remembered here.**
    let (tabs_now, active) = crate::tabs::strip_snapshot();
    let current = tabs_now.get(active).map(|(_, t)| t.clone()).unwrap_or_default();

    let mut fr = RECT::default();
    let _ = unsafe { GetWindowRect(frame, &mut fr) };
    let (w, h) = (s(420), s(96));
    let x = fr.left + ((fr.right - fr.left) - w) / 2;
    let y = fr.top + s(120);

    unsafe {
        register_class();
        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            w!("PolterTitlePrompt"),
            PCWSTR::null(),
            WS_POPUP | WS_BORDER,
            x,
            y,
            w,
            h,
            Some(frame),
            None,
            None,
            None,
        );
        let Ok(hwnd) = hwnd else {
            wlogf!(frame, "[prompt] CreateWindowExW failed; {label} box not shown");
            return;
        };

        let mut wide: Vec<u16> = current.encode_utf16().collect();
        wide.push(0);
        let edit = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            PCWSTR(wide.as_ptr()),
            WS_CHILD | WS_VISIBLE | WS_BORDER | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            s(PAD),
            s(44),
            w - s(PAD * 2),
            s(26),
            Some(hwnd),
            None,
            None,
            None,
        );
        let Ok(edit) = edit else {
            let _ = DestroyWindow(hwnd);
            wlogf!(frame, "[prompt] CreateWindowExW(EDIT) failed; {label} box not shown");
            return;
        };

        let prev_proc = SetWindowLongPtrW(edit, GWLP_WNDPROC, edit_proc as *const () as isize);
        SetWindowLongPtrW(edit, GWLP_USERDATA, prev_proc);
        // Select everything, so typing replaces the old name.
        const EM_SETSEL: u32 = 0x00B1;
        SendMessageW(edit, EM_SETSEL, Some(WPARAM(0)), Some(LPARAM(-1)));

        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        // The shared contract, not a private copy of it: the terminal's TSF
        // document must be released *before* the edit takes focus, or the box
        // cannot compose Chinese and nothing anywhere says why.
        let prev = crate::overlay::focus_to_edit(edit, "title prompt");

        OPEN.with(|c| {
            *c.borrow_mut() = Some(Open {
                hwnd: hwnd.0 as isize,
                edit: edit.0 as isize,
                frame: frame.0 as isize,
                surface,
                action,
                label,
                prev: prev.0 as isize,
            });
        });
    }
    wlogf!(
        frame,
        "[prompt] {label} box open, scope={scope}, surface={surface:#x}, current title {current:?}"
    );
}

/// Close the box. `accept` sends what was typed back through the core.
fn close(accept: bool) {
    let open = OPEN.with(|c| c.borrow_mut().take());
    let Some(open) = open else { return };
    let hwnd = HWND(open.hwnd as *mut std::ffi::c_void);
    let edit = HWND(open.edit as *mut std::ffi::c_void);
    let frame = HWND(open.frame as *mut std::ffi::c_void);

    let text = if accept {
        let mut buf = [0u16; 512];
        let n = unsafe { GetWindowTextW(edit, &mut buf) };
        String::from_utf16_lossy(&buf[..n as usize])
    } else {
        String::new()
    };

    unsafe {
        let _ = DestroyWindow(hwnd);
    }
    crate::overlay::focus_back(HWND(open.prev as *mut std::ffi::c_void), "title prompt");

    if !accept {
        wlogf!(frame, "[prompt] {} cancelled", open.label);
        return;
    }
    if text.trim().is_empty() {
        // An empty name would clear the title, which is a different request
        // from the one the menu row makes.
        wlogf!(frame, "[prompt] {} accepted with an empty name; nothing sent", open.label);
        return;
    }
    let binding = format!("{}:{}", open.action, text);
    let ok = if open.surface != 0 {
        crate::binding_on(open.surface as crate::ffi::Surface, &binding)
    } else {
        wlogf!(frame, "[prompt] {} had no surface of its own; applying to the focused one", open.label);
        crate::binding(&binding)
    };
    // The action name is in the line because that is the half that says which
    // of the three this box was.
    wlogf!(frame, "[prompt] {} -> {:?} ok={}", open.label, binding, ok as i32);
}

fn register_class() {
    use std::sync::OnceLock;
    static DONE: OnceLock<()> = OnceLock::new();
    if DONE.set(()).is_err() {
        return;
    }
    unsafe {
        let wc = WNDCLASSW {
            lpfnWndProc: Some(prompt_proc),
            lpszClassName: w!("PolterTitlePrompt"),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        };
        RegisterClassW(&wc);
    }
}

unsafe extern "system" fn prompt_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HOST_REQUEST => {
                match wp.0 {
                    REQ_TITLE => {
                        let pending = PENDING.lock().ok().and_then(|mut q| {
                            if q.is_empty() { None } else { Some(q.remove(0)) }
                        });
                        let (scope, surface) = pending.unwrap_or((lp.0 as i32, 0));
                        prompt_title(scope, surface);
                    }
                    REQ_FLOAT => float_window(lp.0 as i32),
                    // process-wide: this is the mailbox's own window, one per
                    // process, and an unrecognised kind carries no window.
                    other => plogf!("[prompt] unknown host request {other}"),
                }
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let label = OPEN.with(|c| c.borrow().as_ref().map(|o| o.label).unwrap_or(""));
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(hwnd, &mut rc);
                    let b = CreateSolidBrush(COLORREF(COL_BG));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                    SetBkMode(hdc, TRANSPARENT);
                    SetTextColor(hdc, COLORREF(COL_TEXT));
                    let font = GetStockObject(DEFAULT_GUI_FONT);
                    let old = SelectObject(hdc, font);
                    let mut wide: Vec<u16> = label.encode_utf16().collect();
                    let mut r = RECT { left: 12, top: 12, right: rc.right - 12, bottom: 40 };
                    DrawTextW(hdc, &mut wide, &mut r, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
                    SelectObject(hdc, old);
                }
                let _ = EndPaint(hwnd, &ps);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Enter accepts, Escape cancels. **An `EDIT` eats both and tells nobody**,
/// which is why this subclass exists -- the same reason the tab rename box
/// has one.
unsafe extern "system" fn edit_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if msg == WM_KEYDOWN {
            let vk = wp.0 as u16;
            if vk == VK_RETURN.0 {
                close(true);
                return LRESULT(0);
            }
            if vk == VK_ESCAPE.0 {
                close(false);
                return LRESULT(0);
            }
        }
        if msg == WM_KILLFOCUS {
            // Clicking away cancels rather than commits: a title box is not a
            // rename-in-place, and a half-typed name landing because the
            // pointer moved is not something to explain afterwards.
            close(false);
            return LRESULT(0);
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT =
            std::mem::transmute(prev);
        f(hwnd, msg, wp, lp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **The two rows must not become one again.** Each scope has its own
    /// binding; wiring two of them to the same one is the defect this file
    /// was written next to, and it is invisible on screen -- a box opens
    /// either way and a plausible name lands somewhere.
    #[test]
    fn each_scope_sends_its_own_binding() {
        assert_eq!(scope_of(SCOPE_SURFACE).unwrap().0, "set_surface_title");
        assert_eq!(scope_of(SCOPE_TAB).unwrap().0, "set_tab_title");
        assert_eq!(scope_of(SCOPE_WINDOW).unwrap().0, "set_window_title");
        let surface = scope_of(SCOPE_SURFACE).unwrap();
        let tab = scope_of(SCOPE_TAB).unwrap();
        assert_ne!(surface.0, tab.0, "the two menu rows must not share a binding");
        assert_ne!(surface.1, tab.1, "nor a label");
    }

    /// An unknown scope shows nothing rather than guessing one of the three.
    #[test]
    fn an_unknown_scope_has_no_binding() {
        assert!(scope_of(3).is_none());
        assert!(scope_of(-1).is_none());
    }

    /// Two requests keep their own surfaces. **Sharing one slot instead of a
    /// queue is how the second box renames the first box's terminal** -- and
    /// on screen both boxes look identical.
    #[test]
    fn two_requests_do_not_take_each_others_surface() {
        if let Ok(mut q) = PENDING.lock() {
            q.clear();
        }
        // The mailbox does not exist in a test, so these only queue.
        request_title(SCOPE_TAB, Some(0x1111 as crate::ffi::Surface));
        request_title(SCOPE_SURFACE, Some(0x2222 as crate::ffi::Surface));
        let q = PENDING.lock().unwrap().clone();
        assert_eq!(q, vec![(SCOPE_TAB, 0x1111), (SCOPE_SURFACE, 0x2222)]);
        PENDING.lock().unwrap().clear();
    }

    /// The scope numbers are the core's, in the core's order.
    #[test]
    fn the_scope_numbers_match_the_c_enum() {
        assert_eq!((SCOPE_SURFACE, SCOPE_TAB, SCOPE_WINDOW), (0, 1, 2));
    }
}
