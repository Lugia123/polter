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
//! `NIF_INFO` needs nothing installed, and on Windows 10 and 11 the shell
//! renders it as a toast anyway -- the same panel, the same history.
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

use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicPtr, Ordering};
use std::sync::Mutex;

use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE,
    NIM_MODIFY, NIN_BALLOONUSERCLICK, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{plogf, wlogf};

/// Our own message for "a notification is waiting", posted from whichever
/// thread `cb_action` arrived on.
const WM_NOTIFY_SYNC: u32 = WM_APP + 12;
/// The message the shell sends us about the icon.
const WM_TRAY_CALLBACK: u32 = WM_APP + 13;
/// The icon's id within this window. Any value; it only has to be stable.
const ICON_ID: u32 = 1;

static WORKER: AtomicPtr<std::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());
/// Has `NIM_ADD` succeeded? The icon is added on first use, not at startup.
static ICON_ADDED: AtomicBool = AtomicBool::new(false);
/// The frame the last notification came from, for the balloon's click.
static LAST_FRAME: AtomicIsize = AtomicIsize::new(0);

struct Pending {
    frame: isize,
    title: String,
    body: String,
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
pub fn on_notification(frame: Option<HWND>, title: Option<String>, body: Option<String>) -> bool {
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
        Ok(mut q) => q.push(Pending { frame: f, title: title.clone(), body }),
        Err(_) => return false,
    }
    let posted =
        unsafe { PostMessageW(Some(HWND(hwnd)), WM_NOTIFY_SYNC, WPARAM(0), LPARAM(0)) }.is_ok();
    match frame {
        Some(fr) => wlogf!(fr, "[notify] queued {title:?} posted={posted}"),
        // process-wide: the notification named no surface
        None => plogf!("[notify] queued {title:?} posted={posted} (no window)"),
    }
    posted
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
    // **The generic application icon**, because this executable carries no
    // icon resource of its own (`polter.rc` has the manifest and nothing
    // else). Said here rather than left as a puzzle for whoever notices the
    // notification looks unbranded.
    d.hIcon = unsafe { LoadIconW(None, IDI_APPLICATION) }.unwrap_or_default();
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

fn show(p: Pending) {
    let hwnd = HWND(WORKER.load(Ordering::Acquire));
    if hwnd.0.is_null() || !ensure_icon(hwnd) {
        return;
    }
    LAST_FRAME.store(p.frame, Ordering::Release);

    let mut d = base(hwnd);
    d.uFlags = NIF_INFO;
    d.Anonymous.uTimeout = 10_000;
    d.dwInfoFlags = NIIF_INFO;
    put(&mut d.szInfoTitle, &p.title);
    // **The body must not be empty**: a balloon with an empty `szInfo` is not
    // shown at all, and a title with no body is a perfectly ordinary
    // notification to send. The title stands in for itself in that case.
    put(&mut d.szInfo, if p.body.trim().is_empty() { &p.title } else { &p.body });

    let ok = unsafe { Shell_NotifyIconW(NIM_MODIFY, &d) }.as_bool();
    let frame = HWND(p.frame as *mut std::ffi::c_void);
    if p.frame != 0 {
        wlogf!(frame, "[notify] shown {:?} -> {ok}", p.title);
    } else {
        // process-wide: the notification named no window
        plogf!("[notify] shown {:?} -> {ok} (no window)", p.title);
    }
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
            if (lp.0 as u32 & 0xFFFF) == NIN_BALLOONUSERCLICK {
                let f = LAST_FRAME.load(Ordering::Acquire);
                if f != 0 {
                    let frame = HWND(f as *mut std::ffi::c_void);
                    // **Restore before raising.** A minimised window that is
                    // only brought forward stays minimised, and the click
                    // then looks like it did nothing.
                    unsafe {
                        let _ = ShowWindow(frame, SW_RESTORE);
                        let _ = SetForegroundWindow(frame);
                    }
                    wlogf!(frame, "[notify] balloon clicked; window raised");
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
}
