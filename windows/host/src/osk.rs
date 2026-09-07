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
//! **The touch keyboard is the better answer on the machine this action is
//! for, and it is deliberately not attempted here.** Reaching it from a
//! desktop process means an undocumented COM interface (`ITipInvocation`)
//! whose class and interface GUIDs are not in any header this tree has and
//! could only be written down from memory -- and a GUID written from memory is
//! a constant nobody can check, in a call that fails silently by doing
//! nothing. Starting `TabTip.exe` instead is the other folk remedy, and
//! whether it still shows the keyboard on current Windows is exactly the kind
//! of thing that cannot be established from here.
//!
//! So: the half that can be built and checked is built, and the half that
//! cannot is written down rather than guessed at. **It is a separate task, not
//! a hidden gap.**
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
//! **Layer 3 is not claimed.** Whether the *touch* keyboard would have been
//! the right thing on a touch device is a fourth question this machine cannot
//! ask at all, which is why the digitiser is reported on the same line: a log
//! that says `touch=no` is saying "the path not taken is the one that could
//! not have been checked here anyway".

use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::SystemInformation::GetSystemDirectoryW;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, NID_EXTERNAL_TOUCH, NID_INTEGRATED_TOUCH, NID_READY, SM_DIGITIZER,
    SM_MAXIMUMTOUCHES, SW_SHOWNORMAL,
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

/// Start the on-screen keyboard. Answers whether it was started.
///
/// `frame` is only for the log: the action names a surface, and which window
/// asked is the one fact a reader needs to pair this line with what they
/// pressed. The keyboard itself belongs to no window of ours.
pub fn show(frame: HWND) -> bool {
    let (has_touch, max_touches) = touch();
    let Some(path) = osk_path() else {
        wlogf!(
            frame,
            "[osk] GetSystemDirectoryW gave no path; the on-screen keyboard was not started"
        );
        return false;
    };

    let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    // **Said before the call, because this is the third site of the one that
    // has already hung this host once.** Task 292 is a `ShellExecuteW` that
    // returned and then froze the main thread; the gate that came out of it
    // caught this call the moment the two changes met in a merge, which is
    // what it is for. Same wording as `links.rs` so that a reader searching
    // the log for one finds the other.
    wlogf!(
        frame,
        "[osk] handing {path:?} to ShellExecuteW on the thread that owns the windows; \
         IF THIS IS THE LAST LINE IN THE LOG, the call did not return"
    );
    let started = std::time::Instant::now();
    let r = unsafe {
        ShellExecuteW(
            None,
            windows::core::w!("open"),
            PCWSTR(wide.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    // `ShellExecuteW` answers with a fake `HINSTANCE`; `<= 32` is a failure
    // code. Same reading `open_config` takes of the same call.
    let ok = r.0 as usize > 32;
    let took = started.elapsed().as_millis();

    // **One line, and it carries the fact that decides how much it proves.**
    // On a machine with no digitiser this says so, which is the difference
    // between "the right keyboard came up" and "a keyboard came up, and the
    // one this machine would have wanted could not have been raised by this
    // host anyway".
    wlogf!(
        frame,
        "[osk] started {:?} -> {} in {}ms; touch={} (max touches {}). The touch keyboard is a \
         different program and this host does not raise it -- see this file's header.",
        path,
        ok as u8,
        took,
        if has_touch { "yes" } else { "no" },
        max_touches
    );
    ok
}
