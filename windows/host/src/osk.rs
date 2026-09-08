//! The on-screen keyboard, for `GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD`.
//!
//! # Why this action was owed rather than inapplicable
//!
//! `src/input/Binding.zig` says of it: "Show the on-screen keyboard if one is
//! present. / Only implemented on Linux (GTK) ... **Other platforms are as of
//! now untested.**" Untested is not not-applicable, and Windows is the
//! platform where it is least applicable of all to skip: a tablet with no
//! physical keyboard is exactly the machine where a terminal needs this row.
//!
//! # Windows has two on-screen keyboards and they are not the same thing
//!
//!   * **`osk.exe`** -- the accessibility on-screen keyboard. An ordinary
//!     desktop window, present on every desktop SKU, appears on any machine
//!     whether or not it has a touch screen, and is reachable by starting the
//!     program. **This is what this file starts.**
//!   * **The touch keyboard** -- part of the shell, the one that rises from
//!     the bottom edge when you tap a text field on a tablet. It is a
//!     different program with different behaviour, and on a machine with no
//!     digitiser it behaves differently again.
//!
//! **Both are now tried, in that order** (task 307): the touch keyboard first,
//! `osk.exe` when it cannot be had. Which one ran is in the log, because
//! "nothing happened" and "this machine has no touch keyboard" used to be the
//! same line.
//!
//! # The touch keyboard is reached through an undocumented interface
//!
//! There is no public API for it. What exists is a COM class the shell
//! registers, `ITipInvocation`, with a single method `Toggle(HWND)`.
//!
//! ⚠️ **Its CLSID and IID are in no header in this tree, and they are not
//! verified here.** They arrived with the task that asked for this. That is
//! their whole provenance and it is written down rather than dressed up: an
//! earlier note in this file refused to write a GUID *from memory* for exactly
//! this reason, and the recollection it declined to use disagreed with the
//! pair below in the last eight digits of the IID. **Two sources, one of them
//! a memory, and no way to tell from this machine which is right.**
//!
//! So the constants are treated as unverified, and the design is arranged so
//! that being wrong about them costs nothing but a fallback. See
//! `touch_keyboard` for what makes that true and for the one case it does not
//! cover.
//!
//! # Shelf life
//!
//! **Undocumented means Microsoft owes nobody notice.** The class can be
//! renumbered, unregistered or removed in any Windows update, and the first
//! sign here would be `CoCreateInstance` failing. That is survivable by
//! construction rather than by hope: it is the same branch a machine with no
//! touch keyboard takes, and it ends at `osk.exe`.
//!
//! # What this machine can and cannot show about it
//!
//!   1. **The program started** -- checkable anywhere (`ShellExecuteW`'s
//!      result, and the process appears).
//!   2. **A window appeared** -- checkable anywhere for `osk.exe`, because it
//!      is an ordinary window.
//!   3. **Somebody could see it and type on it** -- not checkable by any
//!      reading; it needs a person in front of the screen.
//!
//! Layers 1 and 2 are real readings and they are what the log below is for.
//! **Layer 3 is not claimed.** And there is now a fourth question this machine
//! cannot ask at all: whether `Toggle` actually raised the touch keyboard.
//! `CoCreateInstance` succeeding proves the class is registered; the keyboard
//! appearing is a fact about a screen. The digitiser is still reported on the
//! same line, because a log that says `touch=no` is saying "the path that
//! matters here could not have been exercised anyway".

use std::ffi::c_void;

use windows::core::{Interface, GUID, HRESULT};
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::SystemInformation::GetSystemDirectoryW;
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, NID_EXTERNAL_TOUCH, NID_INTEGRATED_TOUCH, NID_READY, SM_DIGITIZER,
    SM_MAXIMUMTOUCHES,
};

use crate::wlogf;

/// Does this machine have a touch digitiser, and is it ready?
///
/// **Reported, never branched on.** Nothing here chooses a different path
/// because of this answer -- there is only one path. It goes in the log so a
/// reader can tell "the on-screen keyboard this host starts is the one this
/// machine wanted" from "there is a touch keyboard here that this host does
/// not know how to raise", which are different situations with the same log
/// line otherwise.
///
/// `SM_DIGITIZER` reports what is attached; `NID_READY` is the bit that says
/// the stack is actually up, and it is checked because a digitiser that is
/// present and not ready is a machine where touch does nothing.
fn touch() -> (bool, i32) {
    let d = unsafe { GetSystemMetrics(SM_DIGITIZER) } as u32;
    let ready = d & NID_READY != 0;
    let any = d & (NID_INTEGRATED_TOUCH | NID_EXTERNAL_TOUCH) != 0;
    (ready && any, unsafe { GetSystemMetrics(SM_MAXIMUMTOUCHES) })
}

/// `%WINDIR%\System32\osk.exe`, built rather than assumed.
///
/// **Not the bare name left to the shell's search path.** `osk.exe` is found
/// on `PATH` today, and a search path is a thing other software edits; asking
/// for the system directory by its API is the same answer without the
/// dependency. It also documents the one way this can go wrong on Windows:
/// a **32-bit** process asking for `System32` is redirected to `SysWOW64`,
/// where `osk.exe` does not exist. This host is built for `x86_64` (see
/// `windows/AGENTS.md` on the `-gnu` target), so the redirect does not apply
/// -- but the failure it would produce is "the file is not there", which is
/// exactly what the log below would report, so a future 32-bit build would say
/// so rather than being silent.
fn osk_path() -> Option<String> {
    let mut buf = [0u16; 260];
    let n = unsafe { GetSystemDirectoryW(Some(&mut buf)) } as usize;
    if n == 0 || n >= buf.len() {
        return None;
    }
    let dir = String::from_utf16_lossy(&buf[..n]);
    Some(format!("{dir}\\osk.exe"))
}

/// The shell class that owns the touch keyboard, and the interface on it.
///
/// **Unverified constants**, for the reason the header gives: they are in no
/// header in this tree, they arrived with task 307, and a remembered spelling
/// of the IID disagreed with this one. They are written once, here, so that
/// there is exactly one place to correct if the machine says otherwise.
///
/// **How to give them a provenance, on a machine that has one.** The class is
/// registered, so it can be read back rather than believed:
///
///     reg query "HKCR\CLSID\{4ce576fa-83dc-4f88-951c-9d0782b4e376}" /s
///
/// A hit that names the input panel host is the constant checking out. No hit
/// at all is either a wrong CLSID or a Windows that no longer registers it,
/// and this file cannot tell those apart -- but it does not have to, because
/// both end in the same fallback.
const CLSID_UI_HOSTED_INPUT_PANEL: GUID =
    GUID::from_u128(0x4ce576fa_83dc_4f88_951c_9d0782b4e376);
const IID_ITIP_INVOCATION: GUID = GUID::from_u128(0x37c994e7_432b_4834_a2f7_dca7f45563ee);

/// `ITipInvocation`, by hand.
///
/// Three inherited `IUnknown` slots and one method. Hand-written because the
/// interface is in no metadata the `windows` crate is generated from, which is
/// the same reason `ffi.rs` is hand-written: **a binding that does not exist
/// cannot be imported, and inventing one in a macro hides the fact that it was
/// invented.** The layout is the only thing that has to be right, and it is
/// the standard COM one.
#[repr(C)]
struct ITipInvocationVtbl {
    query_interface:
        unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> HRESULT,
    add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    toggle: unsafe extern "system" fn(*mut c_void, HWND) -> HRESULT,
}

/// Ask the shell to raise the touch keyboard for `frame`.
///
/// # Why being wrong about the GUIDs costs only a fallback
///
/// Stated as the three ways it can fail rather than as a claim:
///
///   * a CLSID nothing registers makes `CoCreateInstance` return
///     `REGDB_E_CLASSNOTREG`; the `?` takes the error path;
///   * an IID the object does not implement makes `QueryInterface` return
///     `E_NOINTERFACE`; same path;
///   * a machine with no touch keyboard fails at one of those two.
///
/// Every one of them ends at the caller's fallback to `osk.exe`, so a wrong
/// constant degrades to today's behaviour rather than to nothing.
///
/// ⚠️ **The case this does not cover, and it is the one to watch:** the call
/// succeeds and no keyboard appears. Nothing in the process can see that --
/// `Toggle` returning `S_OK` is the whole of what is knowable here. That is
/// why the log says which route ran: the reading is on the screen, and the
/// line is what tells a person which screen to be looking at.
///
/// **It is `Toggle`, not `Show`, and the shell offers nothing else.** Invoking
/// the action twice in a row therefore hides the keyboard again. That is how
/// the taskbar's own button behaves, so it is left as the shell's behaviour
/// rather than papered over with a state this process would have to guess.
fn touch_keyboard(frame: HWND) -> windows::core::Result<()> {
    unsafe {
        // Already done on the main thread by `ime_init`; asked again so this
        // file does not depend on that order. `S_FALSE` (already initialised)
        // is success and `.ok()` reads it that way -- the same line, for the
        // same reason, as `taskbar.rs`.
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok();

        let unknown: windows::core::IUnknown =
            CoCreateInstance(&CLSID_UI_HOSTED_INPUT_PANEL, None, CLSCTX_INPROC_SERVER)?;

        let mut raw: *mut c_void = std::ptr::null_mut();
        unknown.query(&IID_ITIP_INVOCATION, &mut raw).ok()?;
        // `query` succeeding with a null pointer would be a broken object, not
        // a possible one; checked anyway because the deref below is the kind
        // that cannot be taken back.
        if raw.is_null() {
            return Err(windows::core::Error::from_hresult(windows::Win32::Foundation::E_POINTER));
        }

        let vtbl = *(raw as *const *const ITipInvocationVtbl);
        let hr = ((*vtbl).toggle)(raw, frame);
        ((*vtbl).release)(raw);
        hr.ok()
    }
}

/// Start the on-screen keyboard. Answers whether it was started.
///
/// `frame` is only for the log: the action names a surface, and which window
/// asked is the one fact a reader needs to pair this line with what they
/// pressed. The keyboard itself belongs to no window of ours.
pub fn show(frame: HWND) -> bool {
    let (has_touch, max_touches) = touch();

    // **The touch keyboard first, because it is the one this action is for.**
    // A tablet with no physical keyboard is the machine the core had in mind,
    // and `osk.exe` is the accessibility keyboard, not that one.
    match touch_keyboard(frame) {
        Ok(()) => {
            wlogf!(
                frame,
                "[osk] raised the touch keyboard (ITipInvocation::Toggle on {:?}); \
                 touch={} (max touches {}). It is a toggle: invoking this again hides it. \
                 **The call returning success is not the keyboard appearing** -- that is a \
                 fact about the screen and nothing here can see it.",
                frame.0,
                if has_touch { "yes" } else { "no" },
                max_touches
            );
            return true;
        }
        Err(e) => {
            // **Named, not swallowed.** This is the line that separates "this
            // machine has no touch keyboard" from "the action did nothing",
            // which read identically before task 307. The fallback below is
            // then a second line, so the two together say what was tried and
            // what ran.
            //
            // ⚠️ **This used to say the HRESULT covers two situations. It
            // covers at least three, and the machine we test on is the third
            // one** -- which is worth knowing, because the third is the one a
            // reader would not have thought of. Measured there:
            //
            //     HKCR\CLSID\{4ce576fa-...}  (Default) = "UIHostNoLaunch Class"
            //                                 AppID     = {36938566-...}
            //                                 no InprocServer32, no LocalServer32
            //     HKCR\AppID\{36938566-...}  (Default) = "TabTip"
            //                                 no LocalServer32 either
            //     where TabTip.exe          -> not found
            //
            // So **the class is registered and the program implementing it is
            // absent**, and COM answers `REGDB_E_CLASSNOTREG` (`0x80040154`)
            // for that just as it does for a key that was never written. The
            // claim that this host cannot tell them apart from in here still
            // holds; what was wrong was counting the ways. **A comment that
            // enumerates cases is a claim about the world, and it goes stale
            // the same way a number does.**
            wlogf!(
                frame,
                "[osk] no touch keyboard here ({e:?}); falling back to osk.exe. \
                 The class is undocumented and this host cannot tell apart, from in \
                 here, a CLSID that was never registered, a Windows that no longer \
                 has one, and a registration whose server is missing; all three land \
                 here and the HRESULT is the only thing that narrows it."
            );
        }
    }

    let Some(path) = osk_path() else {
        wlogf!(
            frame,
            "[osk] GetSystemDirectoryW gave no path; the on-screen keyboard was not started"
        );
        return false;
    };

    // **The third site, and it goes the same way as the other two.** The gate
    // that came out of task 292 caught this call the moment the two changes
    // met in a merge; the answer that came out of 324 is that none of the
    // three may wait on the window thread. See `shellopen::detached`.
    let ok = crate::shellopen::detached(Some(frame), "[osk]", path.to_string());

    // **One line, and it carries the fact that decides how much it proves.**
    // On a machine with no digitiser this says so, which is the difference
    // between "the right keyboard came up" and "a keyboard came up, and the
    // one this machine would have wanted could not have been raised by this
    // host anyway".
    // **No elapsed time here any more, and printing a zero would have been
    // the easy way to keep the format.** The call is on a worker now, so this
    // thread does not know how long it took -- the worker's own line carries
    // the real number. A `0ms` in this line would be a measurement nobody
    // made, sitting next to two that were.
    //
    // ⚠️ **The verb this line used to use is now reserved, deliberately.**
    // `shellopen::detached` announces every site that moved off the window
    // thread with one phrase, on purpose: one grep finds them all, across
    // tags. This line means something else entirely -- the host took the
    // request; whether the shell ran it is the worker's line -- and it used
    // the same words, so one grep returned two opposite meanings sitting two
    // lines apart in the same log. Found on the real machine, not reasoned
    // about here. The phrase itself is not written out in this comment: a
    // checker that counts call sites by scanning text would count prose
    // about them too.
    wlogf!(
        frame,
        "[osk] accepted the request for {:?} -> {}; touch={} (max touches {}). The touch \
         keyboard is a different program and this host does not raise it -- see this \
         file's header. Whether the shell accepted it is on the worker's \
         `[osk] ShellExecuteW returned` line.",
        path,
        ok as u8,
        if has_touch { "yes" } else { "no" },
        max_touches
    );
    ok
}
