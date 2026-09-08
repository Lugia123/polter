//! Keeping the window out of screen captures while secure input is on.
//!
//! `secure_input` is the core telling the host that the person is at a
//! password prompt. macOS answers it by taking the keyboard away from every
//! other process; Windows has no equivalent, and what it does have is
//! `SetWindowDisplayAffinity` with `WDA_EXCLUDEFROMCAPTURE`: a capture sees
//! black where the window is, while the window is unchanged on the screen in
//! front of the person.
//!
//! # What this protects and what it does not
//!
//! **Pixels only.** Measured, not assumed: with the protection on, the UI
//! Automation tree is untouched -- the window, its tabs and its terminals are
//! all still there and still named. That is the right shape twice over: a
//! screen reader must not go silent at a password prompt, and an automation
//! client that drives this terminal through the tree keeps working. What
//! stops working is anything that drives it by **looking at pixels**.
//!
//! ⚠️ **So "our own automation goes blind" is half true, and the half matters:**
//! a screenshot goes black, `ui_snapshot` does not.
//!
//! # How this is reached today, which is not how it reads
//!
//! The sentence above is how `secure_input` works on macOS. **On Windows the
//! automatic half does not exist**: the core detects a password prompt by
//! polling the pty's termios for `canonical && !echo`, and that timer is
//! never started on this platform -- `src/termio/Exec.zig` guards it with
//! `builtin.os.tag == .windows` and its callback panics with
//! `TODO: support on windows` if it ever fires.
//!
//! So the only thing that reaches this file today is the person choosing
//! **Toggle Secure Input** in the command palette (`toggle_secure_input`,
//! which has no default binding and is not in the menu). That is worth
//! knowing before reading a real-machine log: **no `[capture]` line at a
//! `sudo` prompt is correct behaviour, not a broken feature.** This code is
//! written for the day the detection arrives, and works now for the person
//! who asks for it by name.
//!
//! # Why the frame and not the pane
//!
//! Secure input is per surface; display affinity is a property of a window.
//! `SetWindowDisplayAffinity` is documented for top-level windows, and this
//! host's panes are child windows -- so the affinity goes on the frame.
//!
//! **That makes the off-switch the dangerous half.** With a split, one pane
//! can leave a password prompt while the other is still in one; restoring the
//! window then would take the protection away from a surface that still has
//! it, and **nothing on screen would say so** -- the capture would simply
//! start working again. So the frame is protected while *any* surface in it
//! is secure, and restored only when the last one leaves.

use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::{
    SetWindowDisplayAffinity, WDA_EXCLUDEFROMCAPTURE, WDA_NONE,
};

use crate::{plogf, wlogf};

/// The config key. Declared in the core (`src/config/Config.zig`), so this is
/// the only place the host spells it.
const KEY: &str = "windows-secure-input-exclude-from-capture";

/// Is the protection turned on in the config?
///
/// **Read at the moment it is used, not cached.** A config reload changes the
/// answer, and a value captured at startup is a copy that stops following it
/// -- the same rule `theme.rs` states for colours.
///
/// **Defaults to on when the config cannot be asked.** The core's default is
/// `true`, and the failure this must not have is "the protection quietly did
/// not happen because a lookup failed".
fn enabled() -> bool {
    let cfg = crate::config_handle();
    if cfg.is_null() {
        return true;
    }
    let mut on: bool = true;
    let ok = unsafe {
        (crate::api().config_get)(
            cfg,
            &mut on as *mut bool as *mut std::ffi::c_void,
            KEY.as_ptr(),
            KEY.len(),
        )
    };
    if !ok {
        // process-wide: a fact about the config this process loaded, not
        // about any one window
        plogf!("[capture] {KEY} could not be read; assuming on");
        return true;
    }
    on
}

/// Bring `frame`'s capture protection in line with whether any of its surfaces
/// has secure input on.
///
/// Called after every `secure_input` action, from the arm that already knows
/// which window it was for.
pub fn sync(frame: HWND) {
    if frame.0.is_null() {
        // process-wide: the action named no window, so there is nothing whose
        // capture affinity this could be about
        plogf!("[capture] secure input changed but the action named no window; nothing protected");
        return;
    }
    let want = crate::hud::any_secure_in_frame(frame);

    if want && !enabled() {
        wlogf!(
            frame,
            "[capture] secure input is on and {KEY}=false; this window is NOT excluded from \
             screen capture"
        );
        return;
    }

    let affinity = if want { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE };
    match unsafe { SetWindowDisplayAffinity(frame, affinity) } {
        Ok(()) => wlogf!(
            frame,
            "[capture] secure input {}; window display affinity -> {} (screen capture {})",
            if want { "on" } else { "off for every surface here" },
            if want { "WDA_EXCLUDEFROMCAPTURE" } else { "WDA_NONE" },
            if want { "now shows black" } else { "works again" }
        ),
        // ⚠️ **The line that matters more than the feature.**
        // `SetWindowDisplayAffinity` fails on some compositors and in some
        // remote sessions. A person who believes they are protected and is
        // not is worse off than one who knows they are not -- and the two
        // look identical from the screen, because the window looks the same
        // either way.
        Err(e) => wlogf!(
            frame,
            "[capture] SetWindowDisplayAffinity({}) FAILED: {e:?}. Secure input is {} and this \
             window is NOT hidden from screen capture -- anything recording this screen can read \
             it.",
            if want { "WDA_EXCLUDEFROMCAPTURE" } else { "WDA_NONE" },
            if want { "on" } else { "off" }
        ),
    }
}
