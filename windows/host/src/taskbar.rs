//! The taskbar button: a progress bar on it, and a flash when a command ends.
//!
//! Two actions land here, `progress_report` (OSC 9;4) and `command_finished`,
//! because on Windows they are the same object: the button the window has in
//! the taskbar is where a program that is not in front says how it is getting
//! on. macOS puts progress on the surface itself and does nothing at all for
//! `command_finished`; there is no equivalent choice here, because the shell
//! that owns this surface is behind a window that may not be visible.
//!
//! # Why this file owns a window
//!
//! `cb_action` can arrive on the core's thread. `ITaskbarList3` is an
//! apartment-threaded COM object created on the UI thread, and calling it
//! from another thread is the kind of mistake that works until it doesn't.
//! So the action is recorded and a message is posted to a message-only window
//! this file creates on the UI thread; everything that touches COM happens in
//! its window procedure. That is the same shape `hud.rs` uses for the same
//! reason.
//!
//! # What is deliberately not done
//!
//! **The progress bar is not cleared when a surface closes.** It is cleared
//! by the core, which sends `remove` -- and a host that also cleared it on
//! its own would be a second opinion about a state only one of the two is
//! told about. If a bar is ever seen surviving its terminal, that is the
//! core's `remove` not arriving, and the fix belongs there.

use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Mutex;

use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
use windows::Win32::UI::Shell::{
    ITaskbarList3, TaskbarList, TBPFLAG, TBPF_ERROR, TBPF_INDETERMINATE, TBPF_NOPROGRESS,
    TBPF_NORMAL, TBPF_PAUSED,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{ffi, plogf, wlogf};

const WM_TASKBAR_SYNC: u32 = WM_APP + 11;

/// The message-only window every COM call in this file runs on.
static WORKER: AtomicPtr<std::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Work handed over from whichever thread `cb_action` arrived on.
///
/// **`isize` rather than `HWND`**, because the queue crosses a thread and an
/// `HWND` is not `Send`. It is turned back into one only inside the window
/// procedure, where the answer is used immediately.
enum Job {
    Progress { frame: isize, state: i32, pct: Option<u8> },
    Finished { frame: isize, code: Option<i16>, duration_ns: u64 },
}

static QUEUE: Mutex<Vec<Job>> = Mutex::new(Vec::new());

// The taskbar object, made once on the UI thread and kept.
//
// A thread local rather than a static: the interface pointer belongs to the
// apartment it was created in, and a `static` would be an invitation to use
// it from somewhere else.
thread_local! {
    static LIST: std::cell::RefCell<Option<ITaskbarList3>> = const { std::cell::RefCell::new(None) };
}

/// A command whose whole run was shorter than this is not worth a flash.
///
/// **The number is a judgement and it is written here rather than hidden in
/// the branch.** Anything a person waited for is worth being told about; a
/// prompt redrawing itself is not, and the shell reports both.
const FLASH_AFTER_NS: u64 = 10 * 1_000_000_000;

fn queue(job: Job) -> bool {
    let hwnd = WORKER.load(Ordering::Acquire);
    if hwnd.is_null() {
        return false;
    }
    match QUEUE.lock() {
        Ok(mut q) => q.push(job),
        Err(_) => return false,
    }
    unsafe { PostMessageW(Some(HWND(hwnd)), WM_TASKBAR_SYNC, WPARAM(0), LPARAM(0)) }.is_ok()
}

/// `progress_report`: OSC 9;4, as a bar on the window's taskbar button.
///
/// `pct` is `None` when the program reported a state without a percentage --
/// which is every `indeterminate`, and is allowed for the others. The bar
/// shows the state in that case and keeps whatever value it had.
pub fn on_progress(frame: Option<HWND>, state: i32, pct: Option<u8>) -> bool {
    let Some(f) = frame else {
        // process-wide: progress belongs to a window and this action named no
        // surface, so there is nothing to put a bar on
        plogf!("[taskbar] progress_report names no window (state {state}); dropped");
        return false;
    };
    let ok = queue(Job::Progress { frame: f.0 as isize, state, pct });
    wlogf!(f, "[taskbar] progress state={state} pct={pct:?} queued={ok}");
    ok
}

/// `command_finished`: flash the taskbar button when the window is not in
/// front and the command ran long enough to have been waited for.
///
/// **Nothing happens when the window is already in front.** The person is
/// looking at the output; flashing the button they are already using is noise,
/// and noise in a notification channel is how the channel stops working.
pub fn on_command_finished(frame: Option<HWND>, code: Option<i16>, duration_ns: u64) -> bool {
    let Some(f) = frame else {
        // process-wide: the action named no surface, so there is no taskbar
        // button this could belong to
        plogf!("[taskbar] command_finished names no window; dropped");
        return false;
    };
    let ok = queue(Job::Finished { frame: f.0 as isize, code, duration_ns });
    wlogf!(
        f,
        "[taskbar] command finished code={code:?} after {}ms queued={ok}",
        duration_ns / 1_000_000
    );
    ok
}

/// `ghostty_action_progress_report_state_e` to `TBPFLAG`, and whether the
/// value is worth setting.
fn flags_for(state: i32) -> Option<TBPFLAG> {
    Some(match state {
        ffi::PROGRESS_STATE_REMOVE => TBPF_NOPROGRESS,
        ffi::PROGRESS_STATE_SET => TBPF_NORMAL,
        ffi::PROGRESS_STATE_ERROR => TBPF_ERROR,
        ffi::PROGRESS_STATE_INDETERMINATE => TBPF_INDETERMINATE,
        ffi::PROGRESS_STATE_PAUSE => TBPF_PAUSED,
        _ => return None,
    })
}

fn apply(job: Job) {
    match job {
        Job::Progress { frame, state, pct } => {
            let hwnd = HWND(frame as *mut std::ffi::c_void);
            let Some(flags) = flags_for(state) else {
                wlogf!(hwnd, "[taskbar] progress state {state} is not one this host knows");
                return;
            };
            LIST.with(|c| {
                let b = c.borrow();
                let Some(list) = b.as_ref() else {
                    wlogf!(hwnd, "[taskbar] no ITaskbarList3; progress not shown");
                    return;
                };
                // The value first: setting NORMAL with a stale value shows the
                // old bar for a frame, which reads as the wrong number rather
                // than as no number.
                // **`None` means no value was offered; `Some(false)` means
                // one was and did not take.** The sibling below has been
                // matched and reported since it was written, and this one was
                // discarded two lines above it -- so the bar could keep the
                // previous run's number while the line said the new one. The
                // note above already says that a stale value reads as the
                // wrong number rather than as no number; this is that
                // sentence given somewhere to be read.
                let value_set = match pct {
                    Some(p) if flags != TBPF_NOPROGRESS && flags != TBPF_INDETERMINATE => {
                        Some(unsafe { list.SetProgressValue(hwnd, p as u64, 100) }.is_ok())
                    }
                    _ => None,
                };
                match unsafe { list.SetProgressState(hwnd, flags) } {
                    Ok(()) => wlogf!(
                        hwnd,
                        "[taskbar] progress state={state} pct={pct:?} value_set={value_set:?} shown"
                    ),
                    Err(e) => wlogf!(
                        hwnd,
                        "[taskbar] SetProgressState failed: {e:?} (value_set={value_set:?})"
                    ),
                }
            });
        }
        Job::Finished { frame, code, duration_ns } => {
            let hwnd = HWND(frame as *mut std::ffi::c_void);
            if duration_ns < FLASH_AFTER_NS {
                wlogf!(
                    hwnd,
                    "[taskbar] command finished in {}ms; under the {}s bar, not flashing",
                    duration_ns / 1_000_000,
                    FLASH_AFTER_NS / 1_000_000_000
                );
                return;
            }
            if unsafe { GetForegroundWindow() } == hwnd {
                wlogf!(hwnd, "[taskbar] command finished; window is in front, not flashing");
                return;
            }
            let mut fw = FLASHWINFO {
                cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
                hwnd,
                // Button and caption both, and **`FLASHW_TIMERNOFG`**: it
                // stops on its own the moment the window is brought forward,
                // which is the one thing a person can do about it.
                dwFlags: FLASHW_ALL | FLASHW_TIMERNOFG,
                uCount: 3,
                dwTimeout: 0,
            };
            let was_active = unsafe { FlashWindowEx(&mut fw) };
            wlogf!(
                hwnd,
                "[taskbar] command finished code={code:?} after {}ms; flashed (was_active={})",
                duration_ns / 1_000_000,
                was_active.as_bool()
            );
        }
    }
}

extern "system" fn worker_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_TASKBAR_SYNC {
        let jobs: Vec<Job> = match QUEUE.lock() {
            Ok(mut q) => std::mem::take(&mut *q),
            Err(_) => Vec::new(),
        };
        for j in jobs {
            apply(j);
        }
        return LRESULT(0);
    }
    unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
}

/// Stand up the worker window and the COM object, on the UI thread.
///
/// **A failure here is reported and not fatal.** Every one of these is a
/// decoration: a machine with no taskbar object still runs terminals, and
/// turning "the shell extension did not answer" into "the program does not
/// start" is a trade nobody would take.
pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(worker_proc),
            hInstance: hinst,
            lpszClassName: w!("PolterTaskbarWorker"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            // process-wide: one worker window for the whole process
            plogf!("[taskbar] RegisterClassExW failed; no taskbar progress this run");
            return;
        }
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("PolterTaskbarWorker"),
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
        );
        let Ok(hwnd) = hwnd else {
            // process-wide: one worker window for the whole process
            plogf!("[taskbar] CreateWindowExW failed; no taskbar progress this run");
            return;
        };

        // Already initialised on this thread by `ime_init` in the ordinary
        // run; asked again here so this file does not depend on that order.
        // `S_FALSE` (already initialised) is success, and `.ok()` reads it
        // that way.
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok();
        match CoCreateInstance::<_, ITaskbarList3>(&TaskbarList, None, CLSCTX_INPROC_SERVER) {
            Ok(list) => {
                match list.HrInit() {
                    Ok(()) => {
                        LIST.with(|c| *c.borrow_mut() = Some(list));
                        WORKER.store(hwnd.0, Ordering::Release);
                        // process-wide: the taskbar object is one per process
                        plogf!("[taskbar] ready");
                    }
                    Err(e) => {
                        // process-wide: the taskbar object is one per process
                        plogf!("[taskbar] ITaskbarList3::HrInit failed: {e:?}; no progress bars");
                    }
                }
            }
            Err(e) => {
                // **The worker still runs.** `command_finished` flashes the
                // button through user32 and needs no COM at all, so losing the
                // taskbar object must not take that with it.
                WORKER.store(hwnd.0, Ordering::Release);
                // process-wide: the taskbar object is one per process
                plogf!("[taskbar] CoCreateInstance(TaskbarList) failed: {e:?}; flashing still works");
            }
        }
    }
}
