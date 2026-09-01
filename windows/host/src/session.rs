//! Where the window was last time.
//!
//! **This is window geometry only, and that is a smaller thing than "session
//! restore".** macOS has two mechanisms and they are not the same feature:
//! `TerminalRestorableState` remembers the tabs and the split tree and is
//! gated on `window-save-state`, while `LastWindowPosition` remembers where
//! the window was and is gated on **nothing at all** -- its four call sites in
//! `TerminalController.swift` do not mention `windowSaveState` once. This file
//! is the second of the two, so it deliberately does not consult
//! `window-save-state`: doing so would take the remembered position away from
//! anyone who set that to `never`, which is a thing macOS users keep.
//!
//! **Saved as it changes, not on the way out.** A host that writes this in its
//! exit path writes nothing when it is killed with `taskkill` or when it
//! crashes -- and that is exactly the run whose window position a person most
//! wants back. So the geometry is marked dirty by the window messages that
//! change it and flushed by the main loop; the exit path is not involved.
//!
//! **Not remembered here, on purpose:** which tabs were open, and whether the
//! last exit was clean. Both belong to the tab-restoring tier, which is not
//! built. The "clean exit" marker in particular is a separate *file* rather
//! than a field in this one, so adding it later changes no format and no line
//! of this module.

use std::path::PathBuf;

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::Graphics::Gdi::{
    GetMonitorInfoW, MonitorFromRect, MONITORINFO, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::wlogf;

/// `%LOCALAPPDATA%/polter/session.json`, the sibling of `plugins/`.
fn path() -> Option<PathBuf> {
    Some(crate::plugins::user_dir()?.parent()?.join("session.json"))
}

/// The saved rectangle, plus whether the window was maximized.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Geometry {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub maximized: bool,
}

impl Geometry {
    /// `823x471+137+89`, the shape `xdpyinfo` and friends use, so the saved
    /// line and the restored line can be compared by eye without arithmetic.
    pub fn to_line(self) -> String {
        format!(
            "{}x{}+{}+{}{}",
            self.w,
            self.h,
            self.x,
            self.y,
            if self.maximized { " maximized" } else { "" }
        )
    }
}

/// Read a window's geometry.
///
/// **`GetWindowPlacement`, not `GetWindowRect`.** The placement carries the
/// *restored* rectangle even while the window is maximized, which is what has
/// to be remembered: saving the maximized rectangle would restore a window
/// that fills the screen and cannot be un-maximized back to anywhere sensible.
fn read(frame: HWND) -> Option<Geometry> {
    // **Only while the window is visible.** During creation the frame passes
    // through sizes that are not the user's -- macOS guards the same way and
    // says why: a decoration added after creation changes the frame, and the
    // intermediate value would overwrite the good one.
    if !unsafe { IsWindowVisible(frame).as_bool() } {
        return None;
    }
    let mut wp = WINDOWPLACEMENT {
        length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
        ..Default::default()
    };
    if unsafe { GetWindowPlacement(frame, &mut wp) }.is_err() {
        return None;
    }
    let r: RECT = wp.rcNormalPosition;
    let (w, h) = (r.right - r.left, r.bottom - r.top);
    if w <= 0 || h <= 0 {
        return None;
    }
    Some(Geometry {
        x: r.left,
        y: r.top,
        w,
        h,
        maximized: wp.showCmd == SW_SHOWMAXIMIZED.0 as u32,
    })
}

thread_local! {
    /// What was last written, so an unchanged window does not rewrite the file
    /// on every tick, and a drag does not write once per `WM_MOVE`.
    static LAST_WRITTEN: std::cell::Cell<Option<Geometry>> = const { std::cell::Cell::new(None) };
    static DIRTY: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// The window moved, resized, or came forward.
pub fn mark_dirty() {
    DIRTY.with(|d| d.set(true));
}

/// Write the geometry if it changed. Called from the main loop, not from the
/// window procedure: dragging a window delivers `WM_MOVE` continuously, and
/// writing a file on each one would hammer the disk for a value that is only
/// interesting once the pointer stops.
pub fn flush_if_dirty(frame: HWND) {
    if !DIRTY.with(|d| d.replace(false)) {
        return;
    }
    let Some(g) = read(frame) else { return };
    if LAST_WRITTEN.with(|l| l.get()) == Some(g) {
        return;
    }
    let Some(path) = path() else {
        wlogf!(frame, "[session] no config directory; geometry not saved");
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let body = format!(
        "{{\n  \"window\": {{ \"x\": {}, \"y\": {}, \"w\": {}, \"h\": {}, \"maximized\": {} }}\n}}\n",
        g.x, g.y, g.w, g.h, g.maximized
    );

    // **Written to a temporary file and renamed**, the same eight lines
    // `plugins.rs` uses for its settings. A half-written file here is not a
    // lost setting, it is a window restored to half a rectangle on the next
    // start -- and the failure would arrive one launch after the crash that
    // caused it.
    let tmp = path.with_extension("json.tmp");
    if let Err(e) = std::fs::write(&tmp, body.as_bytes()) {
        wlogf!(frame, "[session] write failed: {}", e);
        return;
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        wlogf!(frame, "[session] rename failed: {}", e);
        let _ = std::fs::remove_file(&tmp);
        return;
    }
    LAST_WRITTEN.with(|l| l.set(Some(g)));
    wlogf!(frame, "[session] saved geometry {}", g.to_line());
}

/// What was saved last time, if anything.
pub fn load() -> Option<Geometry> {
    let text = std::fs::read_to_string(path()?).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let w = v.get("window")?;
    let num = |k: &str| -> Option<i32> { w.get(k)?.as_i64().map(|n| n as i32) };
    Some(Geometry {
        x: num("x")?,
        y: num("y")?,
        w: num("w")?,
        h: num("h")?,
        maximized: w.get("maximized").and_then(|b| b.as_bool()).unwrap_or(false),
    })
}

/// Put the window back, honouring anything the user configured explicitly.
///
/// `origin` and `size` are the two halves macOS passes to
/// `LastWindowPosition.restore`: a person who wrote `window-position-x` in
/// their config asked for that position on every launch, and remembering
/// where they dragged the window last time is not what they asked for.
pub fn restore(frame: HWND, origin: bool, size: bool) -> bool {
    if !origin && !size {
        wlogf!(frame, "[session] geometry not restored: position and size are both set in the config");
        return false;
    }
    let Some(g) = load() else {
        wlogf!(frame, "[session] nothing saved yet; leaving the window where it was placed");
        return false;
    };

    let mut wp = WINDOWPLACEMENT {
        length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
        ..Default::default()
    };
    if unsafe { GetWindowPlacement(frame, &mut wp) }.is_err() {
        wlogf!(frame, "[session] GetWindowPlacement failed; geometry not restored");
        return false;
    }
    let cur = wp.rcNormalPosition;
    let (x, y) = if origin { (g.x, g.y) } else { (cur.left, cur.top) };
    let (w, h) = if size {
        (g.w, g.h)
    } else {
        (cur.right - cur.left, cur.bottom - cur.top)
    };
    wp.rcNormalPosition = RECT { left: x, top: y, right: x + w, bottom: y + h };
    wp.showCmd = if g.maximized && size { SW_SHOWMAXIMIZED.0 as u32 } else { SW_SHOWNORMAL.0 as u32 };

    if unsafe { SetWindowPlacement(frame, &wp) }.is_err() {
        wlogf!(frame, "[session] SetWindowPlacement failed; geometry not restored");
        return false;
    }
    // **The same four numbers the save line printed.** The check is that the
    // two lines agree; a screenshot only has to confirm the window is really
    // there, which is the way round that survives a capture tool reporting a
    // scale it does not have.
    wlogf!(frame, 
        "[session] restored geometry {} (origin={} size={})",
        Geometry { x, y, w, h, maximized: wp.showCmd == SW_SHOWMAXIMIZED.0 as u32 }.to_line(),
        origin,
        size
    );
    // **Then drag it back onto a screen that exists.**
    //
    // A window remembered on a monitor that is now unplugged -- or on one the
    // laptop is no longer docked to -- restores to coordinates with nothing
    // there. macOS clamps for the same reason (`min(saved, visibleFrame)` plus
    // pushing an out-of-bounds origin back in), so this is matching behaviour
    // rather than inventing it.
    clamp_onto_a_monitor(frame);

    // Nothing has been written yet this run; remember what is on screen so the
    // first flush does not rewrite an identical file.
    LAST_WRITTEN.with(|l| l.set(read(frame)));
    true
}

/// Move the window back inside the nearest monitor's work area if it is not.
///
/// **Done after `SetWindowPlacement`, in screen coordinates, on purpose.**
/// `WINDOWPLACEMENT` is in *workspace* coordinates, which differ from screen
/// coordinates whenever the primary monitor's work area does not start at the
/// top-left (a taskbar along the top is enough to do it). `GetMonitorInfoW`
/// answers in screen coordinates. Clamping the placement rectangle against the
/// monitor rectangle would therefore be comparing two different coordinate
/// systems -- correct on the machine it was written on and off by the height
/// of a taskbar elsewhere. Letting Windows apply the placement first and then
/// reading `GetWindowRect` puts both sides in screen coordinates, and the
/// conversion is Windows' own.
fn clamp_onto_a_monitor(frame: HWND) {
    unsafe {
        let mut r = RECT::default();
        if GetWindowRect(frame, &mut r).is_err() {
            return;
        }
        let mon = MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if !GetMonitorInfoW(mon, &mut mi).as_bool() {
            return;
        }
        let work = mi.rcWork;
        let (mut w, mut h) = (r.right - r.left, r.bottom - r.top);
        // Never larger than the screen it is going onto.
        w = w.min(work.right - work.left);
        h = h.min(work.bottom - work.top);
        let x = r.left.clamp(work.left, (work.right - w).max(work.left));
        let y = r.top.clamp(work.top, (work.bottom - h).max(work.top));

        if x == r.left && y == r.top && w == r.right - r.left && h == r.bottom - r.top {
            return;
        }
        // **Said out loud.** A window that quietly appears somewhere other
        // than where the log said it was restored to is the one case where
        // these two lines would disagree, and this is the line that explains
        // the difference rather than leaving it to look like a bug.
        wlogf!(frame, 
            "[session] clamped onto the nearest monitor: {}x{}+{}+{} -> {}x{}+{}+{} (work area {}x{}+{}+{})",
            r.right - r.left, r.bottom - r.top, r.left, r.top,
            w, h, x, y,
            work.right - work.left, work.bottom - work.top, work.left, work.top
        );
        let _ = SetWindowPos(frame, None, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

#[cfg(test)]
mod tests {
    use super::Geometry;

    /// The line both `saved` and `restored` print. **The acceptance check is
    /// that two log lines carry the same four numbers**, so the formatting is
    /// part of the criterion rather than decoration.
    #[test]
    fn the_line_carries_all_four_numbers() {
        let g = Geometry { x: 137, y: 89, w: 823, h: 467, maximized: false };
        assert_eq!(g.to_line(), "823x467+137+89");
        let m = Geometry { maximized: true, ..g };
        assert_eq!(m.to_line(), "823x467+137+89 maximized");
        // A maximized window still records where it would go back to: saving
        // the maximized rectangle instead is how a window comes back filling
        // the screen with nowhere to restore to.
        assert_ne!(g.to_line(), m.to_line());
    }
}
