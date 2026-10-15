//! Desktop notifications.
//!
//! `desktop_notification` is what a program in the terminal sends when it
//! wants to be noticed while the person is looking at something else -- OSC 9,
//! OSC 777, `notify-send` over ssh. macOS hands it to
//! `UNUserNotificationCenter`; the equivalent here is the notification area.
//!
//! # Why the notification area and not the WinRT toast API
//!
//! A `ToastNotification` needs an **AppUserModelID that the shell can resolve
//! to an installed application** -- in practice a Start menu shortcut with
//! that ID on it. Polter is a directory somebody unzipped; on a machine
//! without that shortcut the toast API returns success and nothing appears,
//! which is the worst of the three possible outcomes. `Shell_NotifyIconW` with
//! `NIF_INFO` needs nothing installed.
//!
//! ⚠️ **What it does not get is the notification centre.** This note used to
//! say the shell renders a balloon "as a toast anyway -- the same panel, the
//! same history". The machine says otherwise (task 1537,
//! `verify-win-1537/shots/notify-02-not-in-action-center.jpg`): the balloon
//! goes after about five seconds and is not in the history afterwards. macOS
//! keeps its notifications there, which is why moving to the toast API is
//! task 1551's.
//!
//! **What that costs, said plainly:** a notification area icon appears while
//! Polter is running. It is added on the first notification rather than at
//! startup, so a person who never triggers one never sees it.
//!
//! # One icon for the process, and the window it points at
//!
//! There is one icon, not one per window: the notification area is a place,
//! not a window property. The frame a notification came from is remembered so
//! that clicking the balloon raises **that** window -- with two windows open,
//! a notification that raises the wrong one is worse than one that raises
//! nothing.

use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicPtr, AtomicU64, Ordering};
use std::sync::Mutex;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{LoadIconMetric, LIM_LARGE, LIM_SMALL};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO, NIIF_LARGE_ICON, NIIF_USER,
    NIM_ADD, NIM_DELETE, NIM_MODIFY, NIN_BALLOONHIDE, NIN_BALLOONTIMEOUT, NIN_BALLOONUSERCLICK, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_control_room::toast::{self as toast_rules, Launch, Route};

use crate::{plogf, wlogf};

/// Our own message for "a notification is waiting", posted from whichever
/// thread `cb_action` arrived on.
const WM_NOTIFY_SYNC: u32 = WM_APP + 12;
/// The message the shell sends us about the icon.
const WM_TRAY_CALLBACK: u32 = WM_APP + 13;
/// A toast was clicked; what it carried is in `TOAST_CLICKS`. Its own
/// number on this window.
const WM_TOAST_CLICK: u32 = WM_APP + 24;
/// The `launch` arguments of toasts clicked and not yet acted on.
static TOAST_CLICKS: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// The icon's id within this window. Any value; it only has to be stable.
const ICON_ID: u32 = 1;

static WORKER: AtomicPtr<std::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());

/// A balloon is on screen, as far as this process knows.
static BALLOON_UP: AtomicBool = AtomicBool::new(false);
/// The worker's timer that takes a balloon down.
const TIMER_BALLOON: usize = 0xBA11;
/// How long a balloon stays before Polter takes it down itself.
///
/// **Polter's own clock, because the shell keeps none** (#1579 T5). The
/// balloon's `uTimeout` has been ignored since Windows Vista, and on the
/// test machine a balloon stayed in the corner from 23:01 until Polter quit
/// at 23:24 -- over every screenshot taken in between. Ten seconds is what
/// `uTimeout` asked for; a toast that went to the notification centre would
/// have left the screen about as soon.
const BALLOON_DOWN_AFTER_MS: u32 = 10_000;
/// Has `NIM_ADD` succeeded? The icon is added on first use, not at startup.
static ICON_ADDED: AtomicBool = AtomicBool::new(false);
/// The frame the last notification came from, for the balloon's click.
static LAST_FRAME: AtomicIsize = AtomicIsize::new(0);
/// The group the last balloon was about, when the control room raised it:
/// clicking goes to the control room with that group selected, not to a
/// window. `None` for a terminal's own notification.
static LAST_GROUP: Mutex<Option<String>> = Mutex::new(None);
/// The terminal the last balloon came from, when a terminal raised it; 0
/// otherwise. A click goes to its tab and pane when it is in no group.
static LAST_TERMINAL: AtomicU64 = AtomicU64::new(0);

struct Pending {
    frame: isize,
    /// The surface that raised it, as a key; 0 for a balloon none raised.
    /// Read when it is shown: one whose terminal has the keyboard then is
    /// not shown at all (`tabs::surface_has_keyboard`).
    surface: usize,
    /// The terminal's title, under the balloon's own title -- macOS's
    /// `subtitle` (`SurfaceView_AppKit.swift`, `showUserNotification`).
    subtitle: Option<String>,
    /// The terminal that raised it (`ghostty_surface_poltergeist_id`); 0
    /// for a balloon no terminal raised.
    terminal: u64,
    title: String,
    body: String,
    /// The group a click goes to: the control room's, for its own call, or
    /// the one the core put the raising terminal in (task 1538).
    group: Option<String>,
}

static QUEUE: Mutex<Vec<Pending>> = Mutex::new(Vec::new());

/// UTF-16 into a fixed array, NUL-terminated, truncated if it must be.
///
/// **Truncation is at a `char` boundary and the terminator is unconditional.**
/// `Shell_NotifyIconW` reads until the NUL; a string that exactly fills the
/// array without one is read off the end of the struct.
fn put(dst: &mut [u16], s: &str) {
    let mut n = 0;
    for u in s.encode_utf16() {
        if n + 1 >= dst.len() {
            break;
        }
        dst[n] = u;
        n += 1;
    }
    dst[n] = 0;
}

/// `desktop_notification`. Returns whether it was handed on.
///
/// The core sends a title and a body, both NUL-terminated. Either can be
/// missing; a notification with neither is not shown, because an empty toast
/// is indistinguishable from a bug and there is no way for a reader to tell
/// which they got.
///
/// `surface` is the terminal that raised it, `None` for a balloon no
/// terminal raised. Which terminal that is and the group the core puts it in
/// are asked here, as it is raised, and decide where a click goes
/// (`alert::click_of`, task 1538).
pub fn on_notification(
    frame: Option<HWND>,
    surface: Option<crate::ffi::Surface>,
    title: Option<String>,
    body: Option<String>,
) -> bool {
    let terminal = surface.map(|s| unsafe { (crate::api().surface_poltergeist_id)(s) }).unwrap_or(0);
    let group = group_of(terminal);
    let subtitle = surface
        .and_then(crate::tabs::pane_id_of_surface)
        .and_then(crate::tabs::title_of_pane)
        .filter(|t| !t.trim().is_empty());
    let title = title.unwrap_or_default();
    let body = body.unwrap_or_default();
    if title.trim().is_empty() && body.trim().is_empty() {
        match frame {
            Some(f) => wlogf!(f, "[notify] desktop_notification with no title and no body; not shown"),
            // process-wide: nothing to attribute this to -- the action named
            // no surface and carried no text
            None => plogf!("[notify] desktop_notification with no title and no body; not shown"),
        }
        return false;
    }

    let hwnd = WORKER.load(Ordering::Acquire);
    if hwnd.is_null() {
        // process-wide: the notification worker belongs to the process
        plogf!("[notify] no worker window; notification dropped: {title:?}");
        return false;
    }

    // **The frame is optional and its absence is not fatal here.** A
    // notification with no window still deserves to be shown; it only loses
    // the ability to raise anything when clicked.
    let f = frame.map(|h| h.0 as isize).unwrap_or(0);
    match QUEUE.lock() {
        Ok(mut q) => q.push(Pending {
            frame: f,
            surface: surface.map_or(0, |s| s as usize),
            subtitle,
            terminal,
            title: title.clone(),
            body,
            group: group.clone(),
        }),
        Err(_) => return false,
    }
    let posted =
        unsafe { PostMessageW(Some(HWND(hwnd)), WM_NOTIFY_SYNC, WPARAM(0), LPARAM(0)) }.is_ok();
    match frame {
        Some(fr) => wlogf!(fr, "[notify] queued {title:?} terminal=0x{terminal:016x} group={group:?} posted={posted}"),
        // process-wide: the notification named no surface
        None => plogf!("[notify] queued {title:?} terminal=0x{terminal:016x} group={group:?} posted={posted} (no window)"),
    }
    posted
}

/// The group the core puts terminal `terminal` in for a click on its
/// notification (`ghostty_app_notification_group`, task 1538); `None` when
/// it is in none, when no terminal raised it, and when the core could not
/// be asked. App thread only: asked as the notification is raised.
fn group_of(terminal: u64) -> Option<String> {
    if terminal == 0 {
        return None;
    }
    let app = crate::app_opt();
    if app.is_null() {
        return None;
    }
    let api = crate::api();
    // The persona buffer rule: the real length back, one NUL after it when
    // it fits. Zero bytes means no group.
    let need = unsafe { (api.app_notification_group)(app, terminal, std::ptr::null_mut(), 0) };
    if need == 0 {
        return None;
    }
    let mut buf = vec![0u8; need + 1];
    let wrote = unsafe { (api.app_notification_group)(app, terminal, buf.as_mut_ptr(), buf.len()) };
    if wrote == 0 || wrote > need {
        return None;
    }
    String::from_utf8(buf[..wrote].to_vec()).ok()
}

/// The template every call shares: the window, the id, and the icon.
fn base(hwnd: HWND) -> NOTIFYICONDATAW {
    NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: ICON_ID,
        ..Default::default()
    }
}

/// Add the icon, once, the first time there is something to say.
fn ensure_icon(hwnd: HWND) -> bool {
    if ICON_ADDED.load(Ordering::Acquire) {
        return true;
    }
    let mut d = base(hwnd);
    d.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    d.uCallbackMessage = WM_TRAY_CALLBACK;
    // **Polter's own icon** (task 1510; it was the generic application icon
    // while `polter.rc` had none). `LoadIconMetric` rather than the window
    // classes' `LoadImageW`: it is the call the notification area documents,
    // and it picks the size for the current DPI. The generic icon remains
    // the fallback, so a build without the resource still gets an icon added.
    let hinst = unsafe { GetModuleHandleW(None) }.ok().map(HINSTANCE::from);
    d.hIcon = unsafe { LoadIconMetric(hinst, PCWSTR(1 as _), LIM_SMALL) }
        .or_else(|_| unsafe { LoadIconW(None, IDI_APPLICATION) })
        .unwrap_or_default();
    put(&mut d.szTip, "Polter");
    let ok = unsafe { Shell_NotifyIconW(NIM_ADD, &d) }.as_bool();
    if ok {
        ICON_ADDED.store(true, Ordering::Release);
        // process-wide: one icon for the process
        plogf!("[notify] notification area icon added");
    } else {
        // process-wide: one icon for the process
        plogf!("[notify] Shell_NotifyIconW(NIM_ADD) failed; no notifications this run");
    }
    ok
}

/// `control_room_alert`: the control room calling the person (task 1505).
/// Whether, when and how often were the core's; this says it, in the
/// person's language, with the notification area's sound, and remembers
/// the group so that clicking goes there.
pub fn on_control_room_alert(kind: i32, group: String, more: u32, who: String, text: String) -> bool {
    use polter_control_room::alert;
    let Some(kind) = alert::Kind::from_c(kind) else {
        // process-wide: the control room is the application's, not a window's
        plogf!("[notify] control_room_alert of a kind this host does not know: {kind}; not shown");
        return false;
    };
    let title = alert::title(kind, &group, crate::i18n::tr);
    let body = alert::body(&who, &text, more, crate::i18n::tr);
    let hwnd = WORKER.load(Ordering::Acquire);
    if hwnd.is_null() {
        // process-wide: the notification worker belongs to the process
        plogf!("[notify] no worker window; control room alert for {group:?} dropped");
        return false;
    }
    match QUEUE.lock() {
        // No surface: whether the person is looking was the core's to decide
        // before it sent this (`ControlNotify.zig`), as on macOS.
        Ok(mut q) => q.push(Pending { frame: 0, surface: 0, subtitle: None, terminal: 0, title, body, group: Some(group.clone()) }),
        Err(_) => return false,
    }
    let posted = unsafe { PostMessageW(Some(HWND(hwnd)), WM_NOTIFY_SYNC, WPARAM(0), LPARAM(0)) }.is_ok();
    // process-wide: the control room is one per process
    plogf!("[notify] control room alert for {group:?} kind={kind:?} more={more} queued posted={posted}");
    posted
}

/// What the balloon says under its title: the terminal's name, then the
/// body. **Never empty**: a balloon with an empty `szInfo` is not shown at
/// all, and a title with no body is a perfectly ordinary notification to
/// send -- the title stands in for itself then.
fn balloon_text(title: &str, subtitle: Option<&str>, body: &str) -> String {
    let body = if body.trim().is_empty() { title } else { body };
    match subtitle {
        Some(s) if !s.trim().is_empty() => format!("{s}\n{body}"),
        _ => body.to_string(),
    }
}

fn show(p: Pending) {
    let hwnd = HWND(WORKER.load(Ordering::Acquire));
    // **Not while the person is in that terminal** -- macOS asks the same
    // of the window and the view (`Ghostty.App.swift`,
    // `shouldPresentNotification`). Asked now, as it would be shown.
    if p.surface != 0 && crate::tabs::surface_has_keyboard(p.surface) {
        let frame = HWND(p.frame as *mut std::ffi::c_void);
        wlogf!(frame, "[notify] not shown {:?}: its terminal has the keyboard", p.title);
        return;
    }
    // **A toast first, into the notification centre as on macOS** (task
    // 1551); the balloon below is the way back, and the log says why it
    // was taken.
    let launch = Launch { group: p.group.clone(), terminal: p.terminal, frame: p.frame };
    let route = crate::toast::show(&p.title, p.subtitle.as_deref(), &p.body, &launch);
    // A balloon still up from before is replaced by this one, or is older
    // than whatever went another way just now.
    if !matches!(route, Route::Balloon(_)) {
        take_balloon_down("a newer notification");
    }
    match route {
        Route::Toast => {
            let frame = HWND(p.frame as *mut std::ffi::c_void);
            if p.frame != 0 {
                wlogf!(frame, "[notify] shown as a toast {:?}", p.title);
            } else {
                // process-wide: the notification named no window
                plogf!("[notify] shown as a toast {:?} (no window)", p.title);
            }
            return;
        }
        // **Turned off: nothing pops up** (task 1575). The balloon this used
        // to take was turned off with it and appeared nowhere, logged
        // `shown -> true`; the taskbar button is what is left.
        Route::Held(off) => {
            let flashed = flash(p.frame);
            // process-wide: the notifier's setting is the process's
            plogf!("[notify] not shown {:?}: {}; {flashed}", p.title, toast_rules::held_says(off));
            return;
        }
        // process-wide: why the process's notifier was not used
        Route::Balloon(why) => plogf!("[notify] a balloon instead of a toast: {}", why.says()),
    }
    // The balloon may be turned off with Polter's toasts too -- the same
    // identity -- so the flash goes first, as the floor under it.
    if route.flashes() {
        let flashed = flash(p.frame);
        // process-wide: the fallback is the process's
        plogf!("[notify] under the balloon for {:?}: {flashed}", p.title);
    }
    if hwnd.0.is_null() || !ensure_icon(hwnd) {
        return;
    }
    LAST_FRAME.store(p.frame, Ordering::Release);
    LAST_TERMINAL.store(p.terminal, Ordering::Release);
    if let Ok(mut g) = LAST_GROUP.lock() {
        *g = p.group.clone();
    }

    let mut d = base(hwnd);
    d.uFlags = NIF_INFO;
    d.Anonymous.uTimeout = 10_000;
    // **Polter's icon in the balloon**, as macOS shows the app's: the
    // system's blue "i" otherwise (task 1551). `NIIF_USER` takes
    // `hBalloonIcon`; the stock one stays the fallback.
    let hinst = unsafe { GetModuleHandleW(None) }.ok().map(HINSTANCE::from);
    match unsafe { LoadIconMetric(hinst, PCWSTR(1 as _), LIM_LARGE) } {
        Ok(icon) => {
            d.hBalloonIcon = icon;
            d.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
        }
        Err(_) => d.dwInfoFlags = NIIF_INFO,
    }
    put(&mut d.szInfoTitle, &p.title);
    put(&mut d.szInfo, &balloon_text(&p.title, p.subtitle.as_deref(), &p.body));

    let ok = unsafe { Shell_NotifyIconW(NIM_MODIFY, &d) }.as_bool();
    if ok {
        BALLOON_UP.store(true, Ordering::Release);
        // Replaces any timer of the balloon before: the clock starts again.
        unsafe {
            let _ = SetTimer(Some(hwnd), TIMER_BALLOON, BALLOON_DOWN_AFTER_MS, None);
        }
    }
    let frame = HWND(p.frame as *mut std::ffi::c_void);
    if p.frame != 0 {
        wlogf!(frame, "[notify] shown {:?} -> {ok}", p.title);
    } else {
        // process-wide: the notification named no window
        plogf!("[notify] shown {:?} -> {ok} (no window)", p.title);
    }
}

/// Take the balloon down, if one is up, and say why.
///
/// **By removing the icon** (`NIM_DELETE`), the one way the documentation
/// gives that does not depend on the shell honouring a timeout -- which it
/// did not. The icon only exists for notifications and is added back by the
/// next one (`ensure_icon`).
fn take_balloon_down(why: &str) {
    if !BALLOON_UP.swap(false, Ordering::AcqRel) {
        return;
    }
    let hwnd = HWND(WORKER.load(Ordering::Acquire));
    if hwnd.0.is_null() {
        return;
    }
    unsafe {
        let _ = KillTimer(Some(hwnd), TIMER_BALLOON);
    }
    let gone = ICON_ADDED.swap(false, Ordering::AcqRel) && unsafe { Shell_NotifyIconW(NIM_DELETE, &base(hwnd)) }.as_bool();
    // process-wide: one balloon for the process
    plogf!("[notify] balloon taken down ({why}); icon removed -> {gone}");
}

/// A terminal window came to the front: the person is back, and a balloon
/// still up is old news (#1579 T5). Main thread, from `WM_ACTIVATE`.
pub fn on_window_activated() {
    take_balloon_down("a window came to the front");
}

/// Flash the taskbar button of the window a notification came from, until
/// the person brings it forward -- what is left to see when no toast went
/// (task 1575). A notification that names no window (the control room's)
/// flashes the window the control room is in, or else the first window.
/// Says what it did, for the log.
fn flash(frame: isize) -> String {
    let named = HWND(frame as *mut std::ffi::c_void);
    let target = if frame != 0 && unsafe { IsWindow(Some(named)) }.as_bool() {
        Some(named)
    } else {
        crate::control_room::frame_of_panel().or_else(|| crate::winid::all().into_iter().next())
    };
    let Some(hwnd) = target else {
        return "no window to flash".to_string();
    };
    if unsafe { GetForegroundWindow() } == hwnd {
        return format!("window {:#x} is in front, not flashed", hwnd.0 as usize);
    }
    let fw = FLASHWINFO {
        cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
        hwnd,
        // The button only, and until it is brought forward: the caption
        // flashing too would be louder than a notification is.
        dwFlags: FLASHW_TRAY | FLASHW_TIMERNOFG,
        uCount: 0,
        dwTimeout: 0,
    };
    let _ = unsafe { FlashWindowEx(&fw) };
    format!("flashed the taskbar button of window {:#x}", hwnd.0 as usize)
}

extern "system" fn worker_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_NOTIFY_SYNC => {
            let jobs: Vec<Pending> = match QUEUE.lock() {
                Ok(mut q) => std::mem::take(&mut *q),
                Err(_) => Vec::new(),
            };
            for j in jobs {
                show(j);
            }
            LRESULT(0)
        }
        // The shell packs the event into the low word of `lParam`.
        WM_TRAY_CALLBACK => {
            let event = lp.0 as u32 & 0xFFFF;
            if event == NIN_BALLOONUSERCLICK {
                let group = LAST_GROUP.lock().ok().and_then(|g| g.clone());
                let terminal = LAST_TERMINAL.load(Ordering::Acquire);
                let f = LAST_FRAME.load(Ordering::Acquire);
                go(polter_control_room::alert::click_of(group.as_deref(), terminal, f), f, "balloon");
                take_balloon_down("clicked");
            } else if event == NIN_BALLOONTIMEOUT || event == NIN_BALLOONHIDE {
                // The shell took it down itself: nothing left for the timer.
                if BALLOON_UP.swap(false, Ordering::AcqRel) {
                    unsafe {
                        let _ = KillTimer(Some(hwnd), TIMER_BALLOON);
                    }
                    // process-wide: one balloon for the process
                    plogf!("[notify] the shell took the balloon down itself (event {event:#x})");
                }
            }
            LRESULT(0)
        }
        WM_TIMER if wp.0 == TIMER_BALLOON => {
            take_balloon_down("timed out");
            LRESULT(0)
        }
        // A toast's click, carried here from the system's thread: each toast
        // says where it goes itself, so a click on an old one in the
        // notification centre goes where *it* was about.
        WM_TOAST_CLICK => {
            let clicks: Vec<String> = TOAST_CLICKS.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default();
            for args in clicks {
                match Launch::decode(&args) {
                    Some(l) => go(l.click(), l.frame, "toast"),
                    // process-wide: a click on a toast this host did not write
                    None => plogf!("[notify] toast clicked with arguments this host did not write: {args:?}"),
                }
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            if ICON_ADDED.swap(false, Ordering::AcqRel) {
                let d = base(hwnd);
                let _ = unsafe { Shell_NotifyIconW(NIM_DELETE, &d) };
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

/// Where a click on a notification goes -- a balloon's or a toast's, by the
/// one rule (`alert::click_of`, task 1538).
fn go(click: polter_control_room::alert::Click, f: isize, via: &str) {
    use polter_control_room::alert::Click;
    match click {
        // Anything with a group: to the control room, at it.
        Click::ControlRoom(group) => {
            crate::control_room::go_to(&group);
            // process-wide: the control room is one per process
            plogf!("[notify] {via} clicked; going to the control room at {group:?}");
        }
        // A terminal in no group: its tab and its pane.
        Click::Terminal(id) => {
            let key = polter_control_room::rules::key(id);
            if crate::tabs::go_to_terminal(&key) {
                // process-wide: keyed by a terminal's id, which is unique in the process
                plogf!("[notify] {via} clicked; went to terminal {key}");
            } else if f != 0 {
                raise(HWND(f as *mut std::ffi::c_void), "its terminal is gone; window raised");
            }
        }
        Click::Window(f) => raise(HWND(f as *mut std::ffi::c_void), "window raised"),
        Click::Nothing => {}
    }
}

/// A toast was clicked: what it carried, from whatever thread the system
/// raised `Activated` on, to the worker's.
pub fn on_toast_click(arguments: String) {
    if let Ok(mut q) = TOAST_CLICKS.lock() {
        q.push(arguments);
    }
    let hwnd = WORKER.load(Ordering::Acquire);
    if !hwnd.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(hwnd)), WM_TOAST_CLICK, WPARAM(0), LPARAM(0)) };
    }
}

/// Bring a balloon's window forward. **Restore before raising**: a
/// minimised window that is only brought forward stays minimised, and the
/// click then looks like it did nothing.
fn raise(frame: HWND, said: &str) {
    unsafe {
        let _ = ShowWindow(frame, SW_RESTORE);
        let _ = SetForegroundWindow(frame);
    }
    wlogf!(frame, "[notify] balloon clicked; {said}");
}

/// Stand up the worker window. The icon itself waits for a first
/// notification.
pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(worker_proc),
            hInstance: hinst,
            lpszClassName: w!("PolterNotifyWorker"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            // process-wide: one worker window for the whole process
            plogf!("[notify] RegisterClassExW failed; no desktop notifications this run");
            return;
        }
        match CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("PolterNotifyWorker"),
            w!(""),
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
            Ok(hwnd) => {
                WORKER.store(hwnd.0, Ordering::Release);
                // process-wide: one worker window for the whole process
                plogf!("[notify] ready (the notification area icon is added on first use)");
            }
            // process-wide: one worker window for the whole process
            Err(e) => plogf!("[notify] CreateWindowExW failed: {e:?}; no desktop notifications"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **The terminator, which is the part with the sharp edge.** A string
    /// that exactly fills the array must still end in a NUL, or the shell
    /// reads past it.
    #[test]
    fn text_is_always_terminated_even_when_it_had_to_be_cut() {
        let mut buf = [0xFFFFu16; 8];
        put(&mut buf, "abcdefghijkl");
        assert_eq!(buf[7], 0, "the last unit must be the terminator");
        assert_eq!(&buf[..7], &"abcdefg".encode_utf16().collect::<Vec<_>>()[..]);

        let mut buf = [0xFFFFu16; 8];
        put(&mut buf, "ab");
        assert_eq!(buf[2], 0);

        let mut buf = [0xFFFFu16; 8];
        put(&mut buf, "");
        assert_eq!(buf[0], 0);
    }

    /// The terminal's name goes first, as macOS's subtitle sits between the
    /// title and the body, and the text is never empty (task 1551).
    #[test]
    fn the_balloon_names_its_terminal_and_is_never_empty() {
        assert_eq!(balloon_text("Done", Some("build"), "make finished"), "build\nmake finished");
        assert_eq!(balloon_text("Done", None, "make finished"), "make finished");
        assert_eq!(balloon_text("Done", Some("  "), "make finished"), "make finished");
        // No body: the title stands in, under the name.
        assert_eq!(balloon_text("Done", Some("build"), ""), "build\nDone");
        assert_eq!(balloon_text("Done", None, " "), "Done");
    }
}
