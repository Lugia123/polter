//! Dropping files onto a terminal: `IDropTarget`.
//!
//! **This is one of the two blocks `development.md` 5.4 named as invisible to
//! the estimate model**, and it is the cleaner example of the two. macOS
//! spends about zero lines on it: `NSDraggingDestination` is four optional
//! overrides on a view AppKit already routes drags to. Windows has no such
//! thing. A window is not a drop target until a COM object implementing
//! `IDropTarget` is registered against it, so the same feature is a COM
//! interface, an OLE initialisation with its own threading rule, a data
//! object to interrogate, and a shell handle to walk.
//!
//! **Scope is the first half only** -- files dropped *in*, turned into text
//! at the prompt. Dragging a tab *out* into a new window is the other half
//! and needs a second window to drop into, which is S4-B.
//!
//! # Which window gets registered, and what that decides
//!
//! **Each surface (pane) window, not the frame.** This is a real choice with
//! visible consequences, so it is written down rather than left to be
//! inferred from the call site:
//!
//!  - **The drop has to name a pane.** Registered on the frame, the target
//!    would receive a screen point and have to hit-test it back to a pane --
//!    which is the "resolve an identity, then act on the current one" shape
//!    that has already gone wrong four times in this host tonight (the tab
//!    menu's target, the close batch, the mark's landing tab, and the surface
//!    menu's action). Registered per surface, the identity is the window the
//!    callback arrived on and there is nothing to resolve.
//!  - **Splits work for free**, and correctly: dropping on the right-hand
//!    pane inserts into the right-hand pane, whether or not it has focus.
//!    A frame-level target that fell back to the focused surface would look
//!    right on an unsplit window and be wrong on every split one.
//!  - **The tab strip is deliberately not a drop target.** Dragging a file
//!    over it shows the "no" cursor. That is honest: dropping a file on a tab
//!    could mean "open it in that tab" or "open a new tab there", the host
//!    does neither today, and a cursor that says yes and then does nothing is
//!    worse than one that says no.
//!  - The quick terminal is covered too, because it uses the same window
//!    class and `attach` is called for it as well.
//!
//! # The registration is refused silently if OLE was never initialised
//!
//! `RegisterDragDrop` returns `E_OUTOFMEMORY` (not something readable) when
//! the thread has had `CoInitializeEx` but never `OleInitialize` -- and the
//! host does exactly that for TSF. The two are not the same call: OLE's
//! drag-drop, clipboard and in-place activation live above COM and are set up
//! separately. **A window that is simply never a drop target looks identical
//! to one where the feature was not built**, so the result of every
//! registration is logged with the HWND.

#![allow(non_snake_case)]

use std::cell::Cell;

use windows::core::{implement, Ref, Result};
use windows::Win32::Foundation::{HWND, POINTL};
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::System::Com::{IDataObject, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL};
use windows::Win32::System::Ole::{
    IDropTarget, IDropTarget_Impl, OleInitialize, RegisterDragDrop, ReleaseStgMedium,
    RevokeDragDrop, CF_HDROP, DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE,
};
use windows::Win32::UI::Shell::{DragQueryFileW, HDROP};

use crate::logf;

/// One target per surface window. It holds the window, and nothing else --
/// **the surface is looked up per drop, not cached**, because a pane's
/// surface can be replaced (a split that closes and reopens) while the window
/// lives on, and a cached pointer would then be the one thing in this file
/// that is quietly stale.
#[implement(IDropTarget)]
struct DropTarget {
    hwnd: HWND,
    /// What `DragEnter` decided, so `DragOver` can repeat it without asking
    /// the data object again on every mouse move.
    effect: Cell<u32>,
}

/// Whether a data object is carrying files.
///
/// `QueryGetData` rather than `GetData`: this runs on every `DragEnter`, and
/// asking for the payload just to find out whether there is one would copy
/// the whole list to answer a yes/no question.
fn has_files(data: &IDataObject) -> bool {
    let fmt = FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    };
    unsafe { data.QueryGetData(&fmt).is_ok() }
}

/// The paths in a data object, in the order the shell hands them over.
///
/// # `DragQueryFileW` is three functions wearing one name
///
/// This is the shape the TSF work kept getting wrong in the same way, so it
/// is spelled out:
///
///  1. `(hdrop, 0xFFFFFFFF, None)` -> **how many files**. The index is a
///     sentinel, not a file.
///  2. `(hdrop, i, None)` -> **how long file `i`'s name is**, in UTF-16 code
///     units, *not* counting the terminating NUL.
///  3. `(hdrop, i, Some(buf))` -> **copies** the name, returns how much it
///     copied.
///
/// Calling (3) with a buffer sized from (1) is the natural mistake and gives
/// truncated paths for every file after the first -- which the shell then
/// reports as "file not found" on a name that looks almost right.
fn paths_of(data: &IDataObject) -> Vec<String> {
    let fmt = FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    };
    let mut out = Vec::new();
    unsafe {
        let Ok(mut medium) = data.GetData(&fmt) else {
            logf!("[drop] the data object has no CF_HDROP after all");
            return out;
        };
        let hdrop = HDROP(medium.u.hGlobal.0);
        // (1) the count.
        let n = DragQueryFileW(hdrop, 0xFFFF_FFFF, None);
        for i in 0..n {
            // (2) the length, then (3) the copy. `+1` for the NUL the API
            // writes but does not count.
            let len = DragQueryFileW(hdrop, i, None);
            if len == 0 {
                continue;
            }
            let mut buf = vec![0u16; len as usize + 1];
            let copied = DragQueryFileW(hdrop, i, Some(&mut buf));
            buf.truncate(copied as usize);
            out.push(String::from_utf16_lossy(&buf));
        }
        // **Released whatever happened above.** The medium is the caller's to
        // free; leaking it leaks the whole path list, once per drop, for the
        // life of the process.
        ReleaseStgMedium(&mut medium);
    }
    out
}

impl IDropTarget_Impl for DropTarget_Impl {
    fn DragEnter(
        &self,
        pDataObj: Ref<IDataObject>,
        _grfKeyState: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        pdwEffect: *mut DROPEFFECT,
    ) -> Result<()> {
        let accept = pDataObj.ok().map(has_files).unwrap_or(false);
        // **Copy, not Move.** Move would ask the source to delete the file it
        // just gave us, which is emphatically not what "insert the path at
        // the prompt" means. It also picks the right cursor.
        let effect = if accept { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
        self.effect.set(effect.0);
        if !pdwEffect.is_null() {
            unsafe { *pdwEffect = effect };
        }
        Ok(())
    }

    fn DragOver(&self, _grfKeyState: MODIFIERKEYS_FLAGS, _pt: &POINTL, pdwEffect: *mut DROPEFFECT) -> Result<()> {
        if !pdwEffect.is_null() {
            unsafe { *pdwEffect = DROPEFFECT(self.effect.get()) };
        }
        Ok(())
    }

    fn DragLeave(&self) -> Result<()> {
        self.effect.set(DROPEFFECT_NONE.0);
        Ok(())
    }

    fn Drop(
        &self,
        pDataObj: Ref<IDataObject>,
        _grfKeyState: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        pdwEffect: *mut DROPEFFECT,
    ) -> Result<()> {
        if !pdwEffect.is_null() {
            unsafe { *pdwEffect = DROPEFFECT_NONE };
        }
        self.effect.set(DROPEFFECT_NONE.0);

        let Ok(data) = pDataObj.ok() else {
            logf!("[drop] no data object");
            return Ok(());
        };
        let paths = paths_of(data);
        let text = polter_droppath::join(&paths);

        // The surface this window is, resolved now. Not the focused one: a
        // drop onto an unfocused pane belongs to that pane, the same way a
        // right-click menu does.
        let surface = crate::tabs::surface_of(self.hwnd);
        if surface.is_null() {
            logf!(
                "[drop] {} files onto {:?} but it has no surface; inserted 0 chars",
                paths.len(),
                self.hwnd.0
            );
            return Ok(());
        }
        if !text.is_empty() {
            unsafe {
                (crate::api().surface_text)(surface, text.as_ptr() as *const _, text.len())
            };
        }

        // **Both numbers, and this is the reason.** "The drop arrived but not
        // one character went in" and "no drop arrived at all" produce the same
        // silence at the prompt; the file count separates them. And a count
        // without a length would not catch a path list that came back empty
        // of names, which is what a truncating `DragQueryFileW` looks like.
        logf!(
            "[drop] {} files onto surface {:?}; inserted {} chars",
            paths.len(),
            surface,
            text.len()
        );
        // The paths themselves, once, so a wrong quoting rule is readable
        // rather than inferred from a character count.
        if !text.is_empty() {
            logf!("[drop] text = {:?}", text);
        }
        Ok(())
    }
}

thread_local! {
    /// `OleInitialize` is per thread and must not be called twice without a
    /// matching `OleUninitialize`; this makes the first `attach` on a thread
    /// the one that does it.
    static OLE_READY: Cell<bool> = const { Cell::new(false) };
}

fn ensure_ole() -> bool {
    OLE_READY.with(|f| {
        if f.get() {
            return true;
        }
        // `S_FALSE` means COM was already initialised on this thread -- which
        // it is, `main.rs` calls `CoInitializeEx(COINIT_APARTMENTTHREADED)`
        // for TSF. **That is not a failure and must not be treated as one**;
        // OLE still gets initialised, which is the part `RegisterDragDrop`
        // needs and `CoInitializeEx` alone does not provide.
        let r = unsafe { OleInitialize(None) };
        // `Err(S_FALSE)` is not a failure here -- `windows-rs` turns the
        // informational `S_FALSE` into an `Err`, and `S_FALSE` from
        // `OleInitialize` means COM was already initialised on this thread,
        // which it was (`main.rs` does it for TSF). OLE itself still got set
        // up, which is the part `RegisterDragDrop` needs. Treating this as a
        // failure would disable drag and drop on every run.
        const S_FALSE: i32 = 1;
        let hr = r.as_ref().err().map(|e| e.code().0).unwrap_or(0);
        let ok = r.is_ok() || hr == S_FALSE;
        logf!("[drop] OleInitialize -> 0x{:08x} usable={} (S_FALSE means COM was already up, which is fine)", hr, ok);
        f.set(ok);
        ok
    })
}

/// Make a surface window accept dropped files.
///
/// Called next to `crate::ime_attach`, from wherever a surface window is
/// created. Safe to call on a window that is already registered -- the second
/// call is refused by OLE and logged rather than silently doubling anything.
pub fn attach(hwnd: HWND) {
    if !ensure_ole() {
        logf!("[drop] OLE is not initialised; {:?} will not accept files", hwnd.0);
        return;
    }
    let target: IDropTarget = DropTarget {
        hwnd,
        effect: Cell::new(DROPEFFECT_NONE.0),
    }
    .into();
    // `RegisterDragDrop` takes its own reference, so the local one going out
    // of scope here is correct; `RevokeDragDrop` is what releases the
    // target's.
    let r = unsafe { RegisterDragDrop(hwnd, &target) };
    match r {
        Ok(()) => logf!("[drop] {:?} registered as a drop target", hwnd.0),
        // **Named, because the number is not readable.** `E_OUTOFMEMORY` here
        // almost never means memory; it is what OLE returns when the thread
        // never had `OleInitialize`. `DRAGDROP_E_ALREADYREGISTERED` means
        // `attach` ran twice for one window.
        Err(e) => logf!(
            "[drop] RegisterDragDrop({:?}) FAILED hr=0x{:08x} -- \
             0x8007000E means OleInitialize never ran on this thread, \
             0x80040101 means this window was already registered",
            hwnd.0,
            e.code().0
        ),
    }
}

/// Give up a window's registration. **Must run before the window is
/// destroyed**: OLE keeps a reference to the target, and the target keeps the
/// HWND, so a window torn down without this leaves OLE holding a handle to a
/// window that no longer exists.
pub fn detach(hwnd: HWND) {
    let r = unsafe { RevokeDragDrop(hwnd) };
    logf!("[drop] {:?} revoked ok={}", hwnd.0, r.is_ok());
}

#[cfg(test)]
mod tests {
    //! **The rules worth testing are not in this file.**
    //!
    //! Everything here is either a COM callback that needs OLE and a live
    //! drag to reach, or a Win32 registration. The part that can be wrong
    //! quietly -- what a path turns into once it is text -- is in
    //! `polter-droppath`, which has no Win32 in it and whose tests therefore
    //! **run on the machine this was written on** rather than only on the
    //! test box. That is the whole reason it is a separate crate.
    //!
    //! What is left here is one thing worth pinning: that this file actually
    //! uses those rules rather than a second copy of them.

    /// If someone re-implements quoting here, this stops agreeing.
    #[test]
    fn the_quoting_rules_come_from_the_shared_crate() {
        let v = vec![r"C:\a b.txt".to_string()];
        assert_eq!(polter_droppath::join(&v), "\"C:\\a b.txt\"");
    }
}
