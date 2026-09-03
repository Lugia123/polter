//! TSF wired to a real terminal.
//!
//! The probe this grew from (#56) owned its own text: a line buffer it drew
//! itself, on a grid it made up. Here the terminal owns the text and the
//! geometry, and this file owns exactly one thing -- **the composition**.
//!
//! That is the whole shape of it. A terminal is not an editable document, so
//! the store never pretends to hold one. `GetText` answers with the preedit
//! and nothing else; committed text leaves through `ghostty_surface_text` and
//! is gone from here. Everything TSF asks about position is answered from the
//! core's own cursor via `ghostty_surface_ime_point`, never from a guess.
//!
//! Two things here are load-bearing and neither fails loudly if broken:
//!
//!  1. **`RequestLock` is re-entrant.** TSF calls back into `GetText` /
//!     `SetText` / `GetTextExt` from inside the `OnLockGranted` we call. No
//!     `RefCell` borrow may cross it. Verified in the probe; kept identical.
//!  2. **ACP counts UTF-16 code units, columns count grapheme clusters.**
//!     Those are three different numbers for one string (units, codepoints,
//!     cells) and mixing them shows up as a candidate window a few pixels
//!     off, not as a crash.

#![allow(non_snake_case)]

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use windows::core::{implement, Interface, Ref, Result, BOOL, GUID, HRESULT, PCWSTR, PWSTR};
use windows::Win32::Foundation::{E_INVALIDARG, E_NOTIMPL, HWND, POINT, RECT};
use windows::Win32::System::Com::{IDataObject, FORMATETC};
use windows::Win32::UI::TextServices::*;
use windows::Win32::UI::WindowsAndMessaging::GetClientRect;

const S_OK: HRESULT = HRESULT(0);

/// The composition, and nothing else.
pub struct Ime {
    pub hwnd: HWND,
    /// The preedit as TSF sees it: UTF-16 code units, because that is what an
    /// ACP indexes. Converting to UTF-8 happens at the edge, per call.
    pub text: Vec<u16>,
    pub sel_start: i32,
    pub sel_end: i32,
    pub composing: bool,
}

impl Ime {
    pub fn new(hwnd: HWND) -> Self {
        Ime { hwnd, text: Vec::new(), sel_start: 0, sel_end: 0, composing: false }
    }
    fn len(&self) -> i32 {
        self.text.len() as i32
    }
}

#[implement(ITextStoreACP, ITfContextOwnerCompositionSink)]
pub struct TextStore {
    ime: Rc<RefCell<Ime>>,
    sink: RefCell<Option<ITextStoreACPSink>>,
    sink_mask: Cell<u32>,
    lock: Cell<u32>,
    pending: Cell<u32>,
}

impl TextStore {
    pub fn new(ime: Rc<RefCell<Ime>>) -> Self {
        TextStore {
            ime,
            sink: RefCell::new(None),
            sink_mask: Cell::new(0),
            lock: Cell::new(0),
            pending: Cell::new(0),
        }
    }

    fn locked_read(&self) -> bool {
        self.lock.get() & TS_LF_READ.0 != 0
    }
    fn locked_write(&self) -> bool {
        self.lock.get() & TS_LF_READWRITE.0 == TS_LF_READWRITE.0
    }

    /// Hand the current preedit to the terminal so it renders inline.
    /// Called after every edit, never while holding a borrow.
    fn push_preedit(&self) {
        let s = {
            let ime = self.ime.borrow();
            String::from_utf16_lossy(&ime.text)
        };
        crate::ime_set_preedit(&s);
    }

    /// Window moved, resized, or the terminal scrolled: the composition is in
    /// a different place on screen even though its text did not change. TSF
    /// does not ask again on its own.
    pub fn notify_layout_change(&self) {
        let sink = self.sink.borrow().clone();
        if let Some(sink) = sink {
            if self.sink_mask.get() & TS_AS_LAYOUT_CHANGE != 0 {
                unsafe { let _ = sink.OnLayoutChange(TS_LC_CHANGE, 0); }
            }
        }
    }
}

impl ITextStoreACP_Impl for TextStore_Impl {
    fn AdviseSink(&self, riid: *const GUID, punk: Ref<windows::core::IUnknown>, dwmask: u32) -> Result<()> {
        unsafe {
            if riid.is_null() || *riid != ITextStoreACPSink::IID {
                return Err(TS_E_NOOBJECT.into());
            }
        }
        let sink: ITextStoreACPSink = punk.ok()?.cast()?;
        *self.sink.borrow_mut() = Some(sink);
        self.sink_mask.set(dwmask);
        crate::ime_log(&format!("AdviseSink mask=0x{dwmask:x}"));
        Ok(())
    }

    fn UnadviseSink(&self, _punk: Ref<windows::core::IUnknown>) -> Result<()> {
        *self.sink.borrow_mut() = None;
        self.sink_mask.set(0);
        Ok(())
    }

    /// Granting a lock means calling the sink back and letting it work inside
    /// our stack frame. Nothing may be borrowed across `OnLockGranted`, and an
    /// async request that arrives during it has to be replayed afterwards.
    fn RequestLock(&self, dwlockflags: u32) -> Result<HRESULT> {
        let sink = match self.sink.borrow().clone() {
            Some(s) => s,
            None => return Err(E_INVALIDARG.into()),
        };
        if self.lock.get() != 0 {
            if dwlockflags & TS_LF_SYNC != 0 {
                return Ok(TS_E_SYNCHRONOUS);
            }
            self.pending.set(dwlockflags & !TS_LF_SYNC);
            return Ok(TS_S_ASYNC);
        }
        let mut flags = dwlockflags & TS_LF_READWRITE.0;
        loop {
            self.lock.set(flags);
            let hr = unsafe { sink.OnLockGranted(TEXT_STORE_LOCK_FLAGS(flags)) };
            self.lock.set(0);
            if let Err(e) = hr {
                crate::ime_log(&format!("OnLockGranted -> {:?}", e.code()));
            }
            let p = self.pending.replace(0);
            if p == 0 {
                break;
            }
            flags = p & TS_LF_READWRITE.0;
        }
        Ok(S_OK)
    }

    fn GetStatus(&self) -> Result<TS_STATUS> {
        Ok(TS_STATUS { dwDynamicFlags: 0, dwStaticFlags: TS_SS_NOHIDDENTEXT })
    }

    fn QueryInsert(&self, acpteststart: i32, acptestend: i32, _cch: u32, pacpresultstart: *mut i32, pacpresultend: *mut i32) -> Result<()> {
        let end = self.ime.borrow().len();
        if acpteststart < 0 || acpteststart > acptestend || acptestend > end {
            return Err(E_INVALIDARG.into());
        }
        unsafe {
            if !pacpresultstart.is_null() { *pacpresultstart = acpteststart; }
            if !pacpresultend.is_null() { *pacpresultend = acptestend; }
        }
        Ok(())
    }

    fn GetSelection(&self, ulindex: u32, ulcount: u32, pselection: *mut TS_SELECTION_ACP, pcfetched: *mut u32) -> Result<()> {
        unsafe { if !pcfetched.is_null() { *pcfetched = 0; } }
        if ulcount == 0 || pselection.is_null() {
            return Ok(());
        }
        if ulindex != 0 && ulindex != u32::MAX {
            return Err(TS_E_NOSELECTION.into());
        }
        let ime = self.ime.borrow();
        unsafe {
            *pselection = TS_SELECTION_ACP {
                acpStart: ime.sel_start,
                acpEnd: ime.sel_end,
                style: TS_SELECTIONSTYLE { ase: TS_AE_END, fInterimChar: BOOL(0) },
            };
            if !pcfetched.is_null() { *pcfetched = 1; }
        }
        Ok(())
    }

    fn SetSelection(&self, ulcount: u32, pselection: *const TS_SELECTION_ACP) -> Result<()> {
        if !self.locked_write() {
            return Err(TS_E_NOLOCK.into());
        }
        if ulcount == 0 || pselection.is_null() {
            return Ok(());
        }
        let s = unsafe { *pselection };
        let mut ime = self.ime.borrow_mut();
        let n = ime.len();
        if s.acpStart < 0 || s.acpEnd > n || s.acpStart > s.acpEnd {
            return Err(TS_E_INVALIDPOS.into());
        }
        ime.sel_start = s.acpStart;
        ime.sel_end = s.acpEnd;
        Ok(())
    }

    fn GetText(&self, acpstart: i32, acpend: i32, pchplain: PWSTR, cchplainreq: u32, pcchplainret: *mut u32, prgruninfo: *mut TS_RUNINFO, cruninforeq: u32, pcruninforet: *mut u32, pacpnext: *mut i32) -> Result<()> {
        if !self.locked_read() {
            return Err(TS_E_NOLOCK.into());
        }
        let ime = self.ime.borrow();
        let n = ime.len();
        let start = acpstart;
        let end = if acpend < 0 { n } else { acpend };
        if start < 0 || start > n || end > n || start > end {
            return Err(TS_E_INVALIDPOS.into());
        }
        let avail = (end - start) as u32;
        let copied = if pchplain.is_null() { 0 } else { avail.min(cchplainreq) };
        unsafe {
            if copied > 0 {
                std::ptr::copy_nonoverlapping(
                    ime.text.as_ptr().add(start as usize),
                    pchplain.0,
                    copied as usize,
                );
            }
            if !pcchplainret.is_null() { *pcchplainret = copied; }
            if !prgruninfo.is_null() && cruninforeq > 0 {
                *prgruninfo = TS_RUNINFO { uCount: copied, r#type: TS_RT_PLAIN };
                if !pcruninforet.is_null() { *pcruninforet = 1; }
            } else if !pcruninforet.is_null() {
                *pcruninforet = 0;
            }
            if !pacpnext.is_null() { *pacpnext = start + copied as i32; }
        }
        Ok(())
    }

    fn SetText(&self, _dwflags: u32, acpstart: i32, acpend: i32, pchtext: &PCWSTR, cch: u32) -> Result<TS_TEXTCHANGE> {
        if !self.locked_write() {
            return Err(TS_E_NOLOCK.into());
        }
        let new_end;
        {
            let mut ime = self.ime.borrow_mut();
            let n = ime.len();
            if acpstart < 0 || acpstart > acpend || acpend > n {
                return Err(TS_E_INVALIDPOS.into());
            }
            let src: &[u16] = if cch == 0 || pchtext.is_null() {
                &[]
            } else {
                unsafe { std::slice::from_raw_parts(pchtext.0, cch as usize) }
            };
            ime.text.splice(acpstart as usize..acpend as usize, src.iter().copied());
            new_end = acpstart + cch as i32;
            ime.sel_start = new_end;
            ime.sel_end = new_end;
            crate::ime_log(&format!(
                "SetText {acpstart}..{acpend} <- {:?}",
                String::from_utf16_lossy(src)
            ));
        }
        // Borrow released before this: the terminal call can come back around.
        self.push_preedit();
        Ok(TS_TEXTCHANGE { acpStart: acpstart, acpOldEnd: acpend, acpNewEnd: new_end })
    }

    fn InsertTextAtSelection(&self, dwflags: u32, pchtext: &PCWSTR, cch: u32, pacpstart: *mut i32, pacpend: *mut i32, pchange: *mut TS_TEXTCHANGE) -> Result<()> {
        let (sel_start, sel_end) = {
            let ime = self.ime.borrow();
            (ime.sel_start, ime.sel_end)
        };
        if dwflags & TS_IAS_QUERYONLY != 0 {
            if !self.locked_read() {
                return Err(TS_E_NOLOCK.into());
            }
            unsafe {
                if !pacpstart.is_null() { *pacpstart = sel_start; }
                if !pacpend.is_null() { *pacpend = sel_end; }
            }
            return Ok(());
        }
        if !self.locked_write() {
            return Err(TS_E_NOLOCK.into());
        }
        let new_end;
        {
            let src: &[u16] = if cch == 0 || pchtext.is_null() {
                &[]
            } else {
                unsafe { std::slice::from_raw_parts(pchtext.0, cch as usize) }
            };
            let mut ime = self.ime.borrow_mut();
            ime.text.splice(sel_start as usize..sel_end as usize, src.iter().copied());
            new_end = sel_start + cch as i32;
            ime.sel_start = new_end;
            ime.sel_end = new_end;
        }
        self.push_preedit();
        unsafe {
            if dwflags & TS_IAS_NOQUERY == 0 {
                if !pacpstart.is_null() { *pacpstart = sel_start; }
                if !pacpend.is_null() { *pacpend = new_end; }
            }
            if !pchange.is_null() {
                *pchange = TS_TEXTCHANGE { acpStart: sel_start, acpOldEnd: sel_end, acpNewEnd: new_end };
            }
        }
        Ok(())
    }

    fn GetEndACP(&self) -> Result<i32> {
        if !self.locked_read() {
            return Err(TS_E_NOLOCK.into());
        }
        Ok(self.ime.borrow().len())
    }

    fn GetActiveView(&self) -> Result<u32> {
        Ok(0)
    }

    fn GetWnd(&self, _vcview: u32) -> Result<HWND> {
        Ok(self.ime.borrow().hwnd)
    }

    /// Where the candidate window goes. Screen coordinates.
    ///
    /// The base rectangle is the terminal's own cursor cell, from
    /// `ghostty_surface_ime_point` -- so this tracks whatever the core thinks
    /// the cursor is doing, including the preedit it is already rendering.
    /// The offset within the composition is columns, measured with the core's
    /// own width table, so a wide character advances by exactly the two cells
    /// the terminal will draw it in.
    fn GetTextExt(&self, _vcview: u32, acpstart: i32, acpend: i32, prc: *mut RECT, pfclipped: *mut BOOL) -> Result<()> {
        if !self.locked_read() {
            return Err(TS_E_NOLOCK.into());
        }
        let (hwnd, cols0, cols1) = {
            let ime = self.ime.borrow();
            let n = ime.len();
            if acpstart < 0 || acpstart > n || acpend > n || acpstart > acpend {
                return Err(TS_E_INVALIDPOS.into());
            }
            (
                ime.hwnd,
                crate::ime_columns(&ime.text[..acpstart as usize]),
                crate::ime_columns(&ime.text[..acpend as usize]),
            )
        };

        // No cursor yet means no answer; TSF understands that better than a
        // rectangle we made up.
        let Some(cell) = crate::ime_caret_cell() else {
            return Err(TS_E_NOLAYOUT.into());
        };
        let (cw, _ch) = crate::ime_cell_size();

        let left = cell.left + cols0 * cw;
        let right = if cols1 == cols0 { left + 2 } else { cell.left + cols1 * cw };
        let mut r = RECT { left, top: cell.top, right, bottom: cell.bottom };

        let mut tl = POINT { x: r.left, y: r.top };
        let mut br = POINT { x: r.right, y: r.bottom };
        unsafe {
            use windows::Win32::Graphics::Gdi::ClientToScreen;
            let _ = ClientToScreen(hwnd, &mut tl);
            let _ = ClientToScreen(hwnd, &mut br);
        }
        r = RECT { left: tl.x, top: tl.y, right: br.x, bottom: br.y };

        // **Logged after the writes, not before, and the reason is a reading
        // we could not take.** A process died with a completed `GetTextExt`
        // line as its last word, which left two possibilities that the log
        // could not separate: it died in the two stores below, or it died
        // after returning into the text service. Emitting the line last makes
        // the line itself mean "all of our code ran" -- so next time, the line
        // being *absent* while the previous one is present says the death was
        // ours. It costs nothing: the rectangle is already computed.
        unsafe {
            if !prc.is_null() { *prc = r; }
            if !pfclipped.is_null() { *pfclipped = BOOL(0); }
        }
        crate::ime_log(&format!(
            "GetTextExt {acpstart}..{acpend} cols {cols0}..{cols1} -> ({},{})-({},{})",
            r.left, r.top, r.right, r.bottom
        ));
        Ok(())
    }

    fn GetScreenExt(&self, _vcview: u32) -> Result<RECT> {
        let hwnd = self.ime.borrow().hwnd;
        let mut rc = RECT::default();
        unsafe { GetClientRect(hwnd, &mut rc)?; }
        let mut tl = POINT { x: rc.left, y: rc.top };
        let mut br = POINT { x: rc.right, y: rc.bottom };
        unsafe {
            use windows::Win32::Graphics::Gdi::ClientToScreen;
            let _ = ClientToScreen(hwnd, &mut tl);
            let _ = ClientToScreen(hwnd, &mut br);
        }
        Ok(RECT { left: tl.x, top: tl.y, right: br.x, bottom: br.y })
    }

    fn GetACPFromPoint(&self, _vcview: u32, _ptscreen: *const POINT, _dwflags: u32) -> Result<i32> {
        // Mouse-driven reconversion inside a composition. Not wired; the
        // honest answer is better than a plausible wrong one.
        Err(TS_E_INVALIDPOINT.into())
    }

    // ---- attributes: the probe answered nothing here and pinyin never cared ----

    fn RequestSupportedAttrs(&self, _dwflags: u32, _cfilterattrs: u32, _pafilterattrs: *const GUID) -> Result<()> {
        Ok(())
    }
    fn RequestAttrsAtPosition(&self, _acppos: i32, _cfilterattrs: u32, _pafilterattrs: *const GUID, _dwflags: u32) -> Result<()> {
        Ok(())
    }
    fn RequestAttrsTransitioningAtPosition(&self, _acppos: i32, _cfilterattrs: u32, _pafilterattrs: *const GUID, _dwflags: u32) -> Result<()> {
        Ok(())
    }
    fn FindNextAttrTransition(&self, _acpstart: i32, _acphalt: i32, _cfilterattrs: u32, _pafilterattrs: *const GUID, _dwflags: u32, pacpnext: *mut i32, pffound: *mut BOOL, plfoundoffset: *mut i32) -> Result<()> {
        unsafe {
            if !pacpnext.is_null() { *pacpnext = 0; }
            if !pffound.is_null() { *pffound = BOOL(0); }
            if !plfoundoffset.is_null() { *plfoundoffset = 0; }
        }
        Ok(())
    }
    fn RetrieveRequestedAttrs(&self, _ulcount: u32, _paattrvals: *mut TS_ATTRVAL, pcfetched: *mut u32) -> Result<()> {
        unsafe { if !pcfetched.is_null() { *pcfetched = 0; } }
        Ok(())
    }

    // ---- embedded objects: a terminal has none ----

    fn GetFormattedText(&self, _acpstart: i32, _acpend: i32) -> Result<IDataObject> {
        Err(E_NOTIMPL.into())
    }
    fn GetEmbedded(&self, _acppos: i32, _rguidservice: *const GUID, _riid: *const GUID) -> Result<windows::core::IUnknown> {
        Err(E_NOTIMPL.into())
    }
    fn QueryInsertEmbedded(&self, _pguidservice: *const GUID, _pformatetc: *const FORMATETC) -> Result<BOOL> {
        Ok(BOOL(0))
    }
    fn InsertEmbedded(&self, _dwflags: u32, _acpstart: i32, _acpend: i32, _pdataobject: Ref<IDataObject>) -> Result<TS_TEXTCHANGE> {
        Err(E_NOTIMPL.into())
    }
    fn InsertEmbeddedAtSelection(&self, _dwflags: u32, _pdataobject: Ref<IDataObject>, _pacpstart: *mut i32, _pacpend: *mut i32, _pchange: *mut TS_TEXTCHANGE) -> Result<()> {
        Err(E_NOTIMPL.into())
    }
}

/// Composition start and end. The end is where a commit becomes real: whatever
/// the IME left in the buffer is the text the user chose, so it goes to the
/// terminal as input and the preedit is cleared. A cancelled composition ends
/// with an empty buffer and so commits nothing, which is the same code path.
impl ITfContextOwnerCompositionSink_Impl for TextStore_Impl {
    fn OnStartComposition(&self, _pcomposition: Ref<ITfCompositionView>) -> Result<BOOL> {
        self.ime.borrow_mut().composing = true;
        crate::ime_log("OnStartComposition");
        Ok(BOOL(1))
    }

    fn OnUpdateComposition(&self, _pcomposition: Ref<ITfCompositionView>, _prangenew: Ref<ITfRange>) -> Result<()> {
        Ok(())
    }

    fn OnEndComposition(&self, _pcomposition: Ref<ITfCompositionView>) -> Result<()> {
        let committed = {
            let mut ime = self.ime.borrow_mut();
            ime.composing = false;
            let s = String::from_utf16_lossy(&ime.text);
            ime.text.clear();
            ime.sel_start = 0;
            ime.sel_end = 0;
            s
        };
        // **Two different events arrive here, and TSF does not distinguish
        // them.** One is "the user chose this text"; the other is "something
        // took the composition away". The buffer looks the same in both.
        //
        // The comment above this impl used to say a cancelled composition
        // arrives empty, so committing whatever is present was safe. **That is
        // true of a composition the user abandoned and false of one the host
        // interrupted**: a keybinding that opens a tab moves the focus, TSF
        // ends the composition on the way out, and the half-typed syllable was
        // being typed into the terminal -- a new tab *and* a stray `ni`.
        //
        // So the one case the host can recognise is recognised: while it is
        // moving focus between its own panes, an ending composition is
        // discarded. Everything else still commits, including a genuine
        // focus loss to another application, which is what Windows users
        // expect -- and that half is confirmed on a real machine.
        //
        // **The reported symptom is still not covered, and saying so here is
        // the point.** Pressing a keybinding mid-composition still commits
        // the syllable: the composition ends 38ms before the host moves any
        // focus, so this guard is simply not up yet when the end arrives.
        // **A guard whose scope is wrong and a guard that is absent produce
        // the same log line**, which is why the scope is being measured
        // (`trace_intercept` in `main.rs`) rather than adjusted by guesswork.
        let ours = crate::ending_because_we_moved_focus();
        crate::ime_log(&format!(
            "OnEndComposition commit={:?}{}",
            committed,
            if ours { " (discarded: the host was moving focus)" } else { "" }
        ));
        crate::ime_set_preedit("");
        if !committed.is_empty() && !ours {
            crate::ime_commit(&committed);
        }
        Ok(())
    }
}
