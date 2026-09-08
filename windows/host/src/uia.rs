//! UI Automation: what a screen reader, and what an automated test, can see
//! of this window.
//!
//! macOS has AppKit accessibility and Linux has ATK. **Windows had nothing**,
//! which is not a missing nicety -- it is a terminal a screen reader cannot
//! read at all. This file is the smallest thing that closes that: three
//! interfaces (`IRawElementProviderSimple`, `IRawElementProviderFragment`,
//! `IRawElementProviderFragmentRoot`) and a three-layer tree.
//!
//! ```text
//! Window            the frame                     WindowRoot
//! ├── Tab           the strip                     TabList
//! │   ├── TabItem   one tab, named, with a rect   TabItem
//! │   └── TabItem
//! ├── Document      one tab's terminal            Document  (ValuePattern)
//! └── Document
//! ```
//!
//! # Two rules, and each of them is a bug that would otherwise be written
//!
//! **1. Never call into libghostty while holding the `tabs` lock.**
//!
//! `tabs::window()` hands back a guard over a plain, non-reentrant
//! `std::sync::Mutex`. Reading the screen goes through
//! `ghostty_surface_read_text`, which takes the *core's*
//! `renderer_state.mutex` (see `readTextLocked` in `src/apprt/embedded.zig`).
//! Two locks, and the only thing keeping them out of a deadlock is that they
//! are always taken in one order. So: **take a snapshot, drop the guard,
//! then call**. `tabs::tab_infos` and `tabs::surface_of_tab_pane` both return
//! owned values for exactly this reason -- there is no borrow to accidentally
//! hold across the call. This rule is a property of the file, not of one
//! function: a future `Navigate` that reaches for a title inside a
//! `with_windows` closure and then reads text in the same closure would
//! compile.
//!
//! **2. A provider stores identity, never a `Surface`.**
//!
//! A UIA client holds its provider objects for as long as it likes, and a
//! pane can be closed between one call and the next. A cached `Surface`
//! pointer would then be freed memory handed to the core -- the failure being
//! a crash inside libghostty with this file nowhere in the stack. So every
//! provider carries `(frame, TabId, PaneId)` and resolves it again on every
//! call; an unresolvable triple is `UIA_E_ELEMENTNOTAVAILABLE`, which is a
//! different answer from "empty terminal" and has to stay different.
//!
//! The same reasoning is why `RuntimeId` is built from **ids and not
//! indices**. Clients cache runtime ids to decide whether two elements are
//! the same element; a tab's index changes when its neighbour is dragged,
//! and an index-based id would then quietly claim tab 2 is tab 1.
//!
//! # What the text costs, and what that does to the criterion
//!
//! The core's own comment on `ghostty_surface_read_text` says it is
//! expensive and asks callers to cache and throttle; macOS does, at 500ms
//! (`SurfaceView_AppKit.swift`). So does this file -- and that cache is on
//! the only path a real screen reader ever takes, so it must not be bypassed
//! for a test.
//!
//! But a cache in front of the thing under test can make a concurrency
//! criterion pass without ever running the code it claims to exercise: dump
//! the tree sixty times in a second and fifty-eight of them are the cache
//! answering. That is a green with no information in it. **`READS` below is
//! what makes that falsifiable**: every call that actually reaches
//! libghostty logs a line, so the criterion's pass condition is a count of
//! those lines, not an assumption about timing. The counter changes what is
//! visible, not which code runs.

// Every UIA constant is `PascalCase` in the Windows metadata
// (`UIA_NamePropertyId`, `NavigateDirection_Parent`), and matching on one
// trips `non_upper_case_globals`. Renaming them is not an option -- they are
// the operating system's names, and a local alias would be a second name for
// the same thing, which is how a match arm comes to test the wrong constant.
#![allow(non_upper_case_globals)]

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::core::{implement, IUnknown, Result as WResult, BSTR, HRESULT, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM, VARIANT_BOOL, VARIANT_TRUE};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::System::Com::SAFEARRAY;
use windows::Win32::System::Ole::{SafeArrayCreateVector, SafeArrayPutElement};
use windows::Win32::System::Variant::{
    VariantClear, VARIANT, VARIANT_0, VARIANT_0_0, VARIANT_0_0_0, VT_BOOL, VT_BSTR, VT_EMPTY,
    VT_I4,
};
use windows::core::BOOL;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::GetWindowRect;
use windows::Win32::UI::WindowsAndMessaging::IsWindowVisible;

use polter_split_tree::PaneId;

use crate::ffi::{Selection, Text};
use crate::tabs::{self, TabId};
use crate::{plogf, winid, wlogf};

// ---------------------------------------------------------------- constants

/// How long a read of the terminal's text stays good for.
///
/// **The same 500ms macOS uses**, and for the same reason: a screen reader
/// polls, and the core says this call is expensive. Anything that depends on
/// this number -- the verification script's pacing above all -- should read
/// it from the log line below rather than hard-coding a copy, because a copy
/// is how a criterion comes to be spaced *under* the TTL without anybody
/// noticing that it now measures the cache.
const TEXT_TTL: Duration = Duration::from_millis(500);

/// Reads that actually reached libghostty. See the note at the top of the
/// file: this is the criterion's denominator, not a statistic.
static READS: AtomicU64 = AtomicU64::new(0);
/// Reads the cache answered. Logged alongside, so a run can say what fraction
/// of a dump loop was real -- which is the number that says whether the
/// concurrency criterion measured anything.
static CACHE_HITS: AtomicU64 = AtomicU64::new(0);
/// Said once, so the log records the TTL that was actually compiled in.
static TTL_ANNOUNCED: AtomicU64 = AtomicU64::new(0);

/// Discriminates the three kinds of element inside one window's runtime ids.
/// **Distinct constants rather than "0 for the root and the id otherwise"**:
/// a tab and a document can carry the same `TabId`, and without this byte
/// their runtime ids would be equal -- which tells a client they are the
/// same element.
const KIND_ROOT: i32 = 1;
const KIND_TABLIST: i32 = 2;
const KIND_TABITEM: i32 = 3;
const KIND_DOCUMENT: i32 = 4;
const KIND_PALETTE: i32 = 5;
const KIND_PALETTE_ITEM: i32 = 6;
/// The tab strip's menu button. **Appended, never inserted**: these values
/// are baked into runtime ids a client may have written down, so renumbering
/// the existing ones would tell it that every element had been replaced.
const KIND_MENU_BUTTON: i32 = 7;

// ------------------------------------------------------------- text reading

/// Key: the triple that names one terminal.
type CacheKey = (isize, u64, u64);

static TEXT_CACHE: Mutex<Option<Vec<(CacheKey, Instant, String)>>> = Mutex::new(None);

/// The viewport's text for one pane, as a snapshot.
///
/// `None` means the triple no longer names a live terminal -- the caller
/// turns that into `UIA_E_ELEMENTNOTAVAILABLE`. It does **not** mean "no
/// text": an empty terminal answers `Some("")`.
fn read_viewport(frame: HWND, tab: TabId, pane: PaneId) -> Option<String> {
    let key: CacheKey = (frame.0 as isize, tab.0, pane);

    // Announce the TTL once, so a log has the number the criterion is paced
    // against rather than the number somebody remembers.
    if TTL_ANNOUNCED.swap(1, Ordering::Relaxed) == 0 {
        // process-wide: the TTL is a compile-time constant shared by every
        // window's terminals. Tagging it with whichever window happened to be
        // read first would read as "window 2 has a different one".
        plogf!("[uia] text cache ttl = {}ms", TEXT_TTL.as_millis());
    }

    // The cache is consulted and updated with its own lock, which is never
    // held across the FFI call either -- same rule, smaller radius.
    if let Ok(mut g) = TEXT_CACHE.lock() {
        if let Some(rows) = g.as_ref() {
            if let Some((_, at, text)) = rows.iter().find(|(k, _, _)| *k == key) {
                if at.elapsed() < TEXT_TTL {
                    let n = CACHE_HITS.fetch_add(1, Ordering::Relaxed) + 1;
                    if n <= 20 || n % 100 == 0 {
                        wlogf!(frame, "[uia] text cache hit #{} pane={}", n, pane);
                    }
                    return Some(text.clone());
                }
            }
        }
        // Drop expired rows while we are here; the list is one entry per open
        // terminal, so this stays small without a sweep of its own.
        if let Some(rows) = g.as_mut() {
            rows.retain(|(_, at, _)| at.elapsed() < TEXT_TTL);
        }
    }

    // **Rule 1.** The guard inside `surface_of_tab_pane` is taken and dropped
    // before this line; nothing of it is alive when the core's lock is taken
    // below.
    let surface = tabs::surface_of_tab_pane(frame, tab, pane);
    if surface.is_null() {
        return None;
    }

    let mut out = Text::default();
    let ok = unsafe {
        (crate::api().surface_read_text)(surface, Selection::viewport(), &mut out)
    };
    if !ok {
        // The core refused -- a selection it could not pin, usually a surface
        // torn down between the resolve above and here. Reported as "gone"
        // rather than as empty text, for the reason in rule 2.
        wlogf!(frame, "[uia] read_text refused for pane={}", pane);
        return None;
    }

    let n = READS.fetch_add(1, Ordering::Relaxed) + 1;

    // Copied out **before** the core's buffer is handed back. Holding
    // `out.text` past `free_text` would be a use-after-free that reads
    // correctly most of the time.
    let text = if out.text.is_null() {
        String::new()
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(out.text as *const u8, out.text_len) };
        String::from_utf8_lossy(bytes).into_owned()
    };
    unsafe { (crate::api().surface_free_text)(surface, &mut out) };

    // **The line the criterion counts.** Unbounded on purpose: every other
    // log in this port caps itself, and a capped counter here would make a
    // sixty-iteration criterion stop reporting after the tenth. It is one
    // line per 500ms per visible terminal at worst.
    wlogf!(
        frame,
        "[uia] read_text #{} pane={} bytes={}",
        n,
        pane,
        text.len()
    );

    if let Ok(mut g) = TEXT_CACHE.lock() {
        let rows = g.get_or_insert_with(Vec::new);
        rows.retain(|(k, _, _)| *k != key);
        rows.push((key, Instant::now(), text.clone()));
    }

    Some(text)
}

// ------------------------------------------------------------------ helpers

/// **`UIA_E_*` are plain `u32` in the metadata, not `HRESULT`s.** Written
/// out here once so no call site does the cast, because a cast that lands on
/// the wrong constant produces an error code clients read as something else
/// entirely.
fn hr(code: u32) -> windows::core::Error {
    windows::core::Error::from(HRESULT(code as i32))
}

fn gone() -> windows::core::Error {
    hr(UIA_E_ELEMENTNOTAVAILABLE)
}

/// Is this frame still one of ours?
///
/// **`winid::frame_of_window`, not a bare registry peek.** The handle came
/// from a message that may have arrived after the window left the registry,
/// and Windows recycles `HWND`s -- so "the number is in the table" is not the
/// same question as "this handle is that window".
fn live(frame: HWND) -> bool {
    winid::frame_of_window(frame).is_some()
}

fn variant_i4(v: i32) -> VARIANT {
    VARIANT {
        Anonymous: VARIANT_0 {
            Anonymous: std::mem::ManuallyDrop::new(VARIANT_0_0 {
                vt: VT_I4,
                wReserved1: 0,
                wReserved2: 0,
                wReserved3: 0,
                Anonymous: VARIANT_0_0_0 { lVal: v },
            }),
        },
    }
}

fn variant_bstr(s: &str) -> VARIANT {
    VARIANT {
        Anonymous: VARIANT_0 {
            Anonymous: std::mem::ManuallyDrop::new(VARIANT_0_0 {
                vt: VT_BSTR,
                wReserved1: 0,
                wReserved2: 0,
                wReserved3: 0,
                Anonymous: VARIANT_0_0_0 {
                    bstrVal: std::mem::ManuallyDrop::new(BSTR::from(s)),
                },
            }),
        },
    }
}

fn variant_bool(v: bool) -> VARIANT {
    VARIANT {
        Anonymous: VARIANT_0 {
            Anonymous: std::mem::ManuallyDrop::new(VARIANT_0_0 {
                vt: VT_BOOL,
                wReserved1: 0,
                wReserved2: 0,
                wReserved3: 0,
                Anonymous: VARIANT_0_0_0 {
                    boolVal: if v { VARIANT_TRUE } else { VARIANT_BOOL(0) },
                },
            }),
        },
    }
}

/// The VARIANT that means "I do not answer this property", which is what UIA
/// wants for anything not deliberately supplied.
fn variant_empty() -> VARIANT {
    VARIANT {
        Anonymous: VARIANT_0 {
            Anonymous: std::mem::ManuallyDrop::new(VARIANT_0_0 {
                vt: VT_EMPTY,
                wReserved1: 0,
                wReserved2: 0,
                wReserved3: 0,
                Anonymous: VARIANT_0_0_0 { llVal: 0 },
            }),
        },
    }
}

/// A runtime id: `[UiaAppendRuntimeId, window number, kind, id lo, id hi]`.
///
/// `UiaAppendRuntimeId` asks UIA to prefix the host window's own id, which is
/// what scopes these to one window at the framework level. **The window
/// number is then included again on purpose**: it is what makes two windows'
/// ids visibly different in an external dump, and telling them apart from
/// outside is exactly what the multi-window criterion checks. A prefix only
/// UIA can see would leave that criterion unable to fail.
fn runtime_parts(win: u32, kind: i32, id: u64) -> [i32; 5] {
    [
        // A `u32` in the metadata, an `i32` in the array UIA reads.
        UiaAppendRuntimeId as i32,
        win as i32,
        kind,
        (id & 0xFFFF_FFFF) as i32,
        (id >> 32) as i32,
    ]
}

/// The same five numbers, as the SAFEARRAY `GetRuntimeId` returns.
///
/// **One source for the shape, and that is not tidiness.** A structure-changed
/// event carries a runtime id too, and it is how the client works out *which*
/// element's children changed. An event whose id is built a second way, and
/// drifts, does not fail loudly: the client receives an event about an element
/// it has never seen and ignores it, and the tree goes on looking stale for a
/// reason no log mentions.
fn runtime_id(win: u32, kind: i32, id: u64) -> WResult<*mut SAFEARRAY> {
    let parts = runtime_parts(win, kind, id);
    unsafe {
        let sa = SafeArrayCreateVector(VT_I4, 0, parts.len() as u32);
        if sa.is_null() {
            return Err(windows::core::Error::from(windows::Win32::Foundation::E_OUTOFMEMORY));
        }
        for (i, v) in parts.iter().enumerate() {
            let idx = i as i32;
            SafeArrayPutElement(sa, &idx, v as *const i32 as *const core::ffi::c_void)?;
        }
        Ok(sa)
    }
}

/// An empty SAFEARRAY of i32 -- what `GetEmbeddedFragmentRoots` returns when
/// there are none, which is every element here.
/// A `SAFEARRAY` of doubles, which is what UIA wants for rectangles.
///
/// **Separate from the `i4` one on purpose**: a rectangle array handed back
/// with the wrong element type is not a type error anywhere in this process
/// -- it crosses the ABI as a pointer and is misread on the far side.
fn f64_array(values: &[f64]) -> WResult<*mut SAFEARRAY> {
    unsafe {
        let arr = SafeArrayCreateVector(windows::Win32::System::Variant::VT_R8, 0, values.len() as u32);
        if arr.is_null() {
            return Err(hr(UIA_E_NOTSUPPORTED));
        }
        for (i, v) in values.iter().enumerate() {
            let idx = i as i32;
            SafeArrayPutElement(arr, &idx, v as *const f64 as *const core::ffi::c_void)?;
        }
        Ok(arr)
    }
}

fn empty_f64_array() -> WResult<*mut SAFEARRAY> {
    f64_array(&[])
}

/// A `SAFEARRAY` of text ranges, which is what `GetSelection` and
/// `GetVisibleRanges` hand back.
///
/// `VT_UNKNOWN` elements: `SafeArrayPutElement` takes a *reference* to the
/// interface pointer and adds a reference of its own, so the locals here stay
/// alive until it has.
fn range_array(ranges: &[ITextRangeProvider]) -> WResult<*mut SAFEARRAY> {
    unsafe {
        let arr = SafeArrayCreateVector(
            windows::Win32::System::Variant::VT_UNKNOWN,
            0,
            ranges.len() as u32,
        );
        if arr.is_null() {
            return Err(hr(UIA_E_NOTSUPPORTED));
        }
        for (i, r) in ranges.iter().enumerate() {
            let idx = i as i32;
            SafeArrayPutElement(
                arr,
                &idx,
                r as *const ITextRangeProvider as *const core::ffi::c_void,
            )?;
        }
        Ok(arr)
    }
}

fn empty_i4_array() -> WResult<*mut SAFEARRAY> {
    unsafe {
        let sa = SafeArrayCreateVector(VT_I4, 0, 0);
        if sa.is_null() {
            return Err(windows::core::Error::from(windows::Win32::Foundation::E_OUTOFMEMORY));
        }
        Ok(sa)
    }
}

fn window_rect(hwnd: HWND) -> UiaRect {
    let mut r = RECT::default();
    if unsafe { GetWindowRect(hwnd, &mut r) }.is_err() {
        return UiaRect { left: 0.0, top: 0.0, width: 0.0, height: 0.0 };
    }
    UiaRect {
        left: r.left as f64,
        top: r.top as f64,
        width: (r.right - r.left) as f64,
        height: (r.bottom - r.top) as f64,
    }
}

/// A rectangle in the frame's client coordinates, moved to the screen.
///
/// UIA wants screen coordinates; the strip works in client ones. **The two
/// corners are mapped separately rather than the origin plus the size**,
/// because a mirrored (RTL) window's client-to-screen mapping is not a
/// translation, and a width carried across it comes out negative.
fn client_rect_to_screen(frame: HWND, r: RECT) -> UiaRect {
    let mut tl = POINT { x: r.left, y: r.top };
    let mut br = POINT { x: r.right, y: r.bottom };
    unsafe {
        let _ = ClientToScreen(frame, &mut tl);
        let _ = ClientToScreen(frame, &mut br);
    }
    UiaRect {
        left: tl.x.min(br.x) as f64,
        top: tl.y.min(br.y) as f64,
        width: (br.x - tl.x).abs() as f64,
        height: (br.y - tl.y).abs() as f64,
    }
}

/// The strip's own rectangle, in screen coordinates.
fn strip_rect(frame: HWND) -> UiaRect {
    let scale = tabs::scale_of(frame);
    let h = crate::strip::strip_h(scale);
    let mut rc = RECT::default();
    if unsafe { windows::Win32::UI::WindowsAndMessaging::GetClientRect(frame, &mut rc) }.is_err() {
        return UiaRect { left: 0.0, top: 0.0, width: 0.0, height: 0.0 };
    }
    client_rect_to_screen(frame, RECT { left: 0, top: 0, right: rc.right, bottom: h })
}

/// What to call the window.
///
/// **Built from the model, not from `GetWindowTextW`.** The caption is drawn
/// by `shell.rs` rather than by Windows, so the window text is not
/// necessarily what a person sees; and `GetWindowTextW` sends `WM_GETTEXT`
/// synchronously, which is a dispatching call made from inside a UIA call --
/// a re-entrancy this file has no reason to invite.
fn root_name(frame: HWND) -> String {
    let (tabs_now, active) = tabs::tab_infos(frame);
    match tabs_now.get(active) {
        Some(t) => format!("Polter - {}", t.title),
        None => "Polter".to_string(),
    }
}

// ------------------------------------------------------------ the providers
//
// Three structs, one per layer. Each carries the frame first, and that
// ordering is a habit worth keeping: there is no constructor here that can be
// called without saying which window it is for, which is the whole of what
// stops "the current window" coming back.

/// Whether the window an element belongs to is accepting input.
///
/// # Why this property, and why it is asked of Windows rather than answered
///
/// **Every element this provider published reported `IsEnabled=false`** --
/// the tab strip, every tab, the terminal, and all ninety command-palette
/// rows, without exception. Not because anything was disabled: because
/// `UIA_IsEnabledPropertyId` was never handled at all, so it fell to
/// `variant_empty()` and the client filled in a default.
///
/// **That is not a missing feature, it is a missing answer**, and the cost is
/// out of all proportion to the line it takes: filtering on `IsEnabled` is
/// what an automation client does *first*, so every element was skipped, the
/// program read as having nothing operable in it, and the client fell back to
/// clicking screenshot coordinates -- which is the most expensive part of
/// testing this port.
///
/// # Where the value comes from, and why it is not a constant
///
/// `IsWindowEnabled` on the window the element lives in. **Returning `true`
/// everywhere would have been the same defect with the sign flipped**, and
/// worse: a constant `false` is noticed the first time somebody looks, a
/// constant `true` is believed.
///
/// It is genuinely `false` sometimes, and this host produces that state on
/// purpose: `cb_confirm_read_clipboard` puts up a modal `MessageBoxW` owned
/// by the frame, and Windows disables an owner while a modal is up. So during
/// a paste confirmation the frame, its tabs and its terminal are all
/// correctly `IsEnabled=false` -- and an automation client that skips them is
/// then right to.
///
/// **Children follow their window.** The tab strip, the tabs and the terminal
/// are drawn by the host rather than being windows of their own, so the state
/// that governs them is the frame's; the palette's rows likewise follow the
/// palette window. That is not an approximation -- it is the same rule Win32
/// applies to real child windows.
///
/// ⚠️ **That derivation rests on a premise, and the premise is not permanent:
/// these elements are *drawn*, not windows.** The day any of them is given an
/// `HWND` of its own -- a real child window for the tab strip, say -- this
/// function keeps returning the *frame's* state for it, the code still reads
/// as correct, and the answer quietly starts being wrong for that element.
/// **Whoever gives one of them a window has to come back here**, because
/// nothing else will notice.
///
/// The reason this is spelled out rather than left as an obvious caveat is
/// that this file has already had one written-down decision outlive its
/// reason: the note saying a whole-window bounding rectangle was "the error a
/// client can see" while a stale row rectangle was the invisible one. It was
/// measured the other way round -- one rectangle for every row produces
/// clicks that *succeed* on the wrong command. **A decision whose reason has
/// expired still reads as correct; only a written premise makes the
/// expiry findable.**
///
/// # What is deliberately *not* derived from here
///
/// A palette row for a command that cannot be run here is **not** shown
/// disabled: `palette.rs` removes it from the list and logs why (see
/// `UNAVAILABLE`). So every row that reaches this provider is one that can
/// run, and asking the window is the whole answer rather than half of it.
fn window_enabled(h: HWND) -> bool {
    !h.0.is_null()
        && unsafe {
            windows::Win32::UI::Input::KeyboardAndMouse::IsWindowEnabled(h)
        }
        .as_bool()
}

#[implement(
    IRawElementProviderSimple,
    IRawElementProviderFragment,
    IRawElementProviderFragmentRoot
)]
struct WindowRoot {
    frame: isize,
}

#[implement(IRawElementProviderSimple, IRawElementProviderFragment)]
struct TabList {
    frame: isize,
}

#[implement(
    IRawElementProviderSimple,
    IRawElementProviderFragment,
    ISelectionItemProvider,
    IInvokeProvider
)]
struct TabItem {
    frame: isize,
    tab: TabId,
}

#[implement(
    IRawElementProviderSimple,
    IRawElementProviderFragment,
    IValueProvider,
    ITextProvider
)]
struct Document {
    frame: isize,
    tab: TabId,
    pane: PaneId,
}

#[implement(IRawElementProviderSimple, IRawElementProviderFragment, IInvokeProvider)]
/// The tab strip's menu button.
///
/// # Why it is an element of ours rather than something Windows found
///
/// The strip is drawn by this host: there is no child window under the
/// button, so the default provider has nothing to report and the button was
/// **not in the tree at all**. A client could see the tabs beside it and not
/// the one control that opens everything else.
///
/// Its rectangle comes from `strip::menu_button_rect`, the geometry the painter uses
/// -- so it is correct on a window of any size. ⚠️ **The constant `(14, 15)`
/// that a script used before this existed was right only while the window was
/// maximised**, which is the failure this element exists to end.
struct MenuButton {
    frame: isize,
}


impl WindowRoot {
    fn hwnd(&self) -> HWND {
        HWND(self.frame as *mut core::ffi::c_void)
    }
}
impl TabList {
    fn hwnd(&self) -> HWND {
        HWND(self.frame as *mut core::ffi::c_void)
    }
}
impl TabItem {
    fn hwnd(&self) -> HWND {
        HWND(self.frame as *mut core::ffi::c_void)
    }
}
impl MenuButton {
    fn hwnd(&self) -> HWND {
        HWND(self.frame as *mut core::ffi::c_void)
    }
}

impl Document {
    fn hwnd(&self) -> HWND {
        HWND(self.frame as *mut core::ffi::c_void)
    }
}

/// The root of the window this element belongs to, as an interface.
fn root_of(frame: isize) -> IRawElementProviderFragmentRoot {
    let r: IRawElementProviderFragmentRoot = WindowRoot { frame }.into();
    r
}

/// What one child of the root **is**, as opposed to the interface it is
/// reached through.
///
/// **This exists so that no `Navigate` arm has to compute its own position.**
/// The arithmetic it replaces (`the documents follow the tab list, so a tab
/// at index t is the root's child t + 1`) was correct for exactly as long as
/// there was one document per tab; the moment a split produced two, it named
/// the neighbour's element. Commit `081bc0546` fixed the same family once
/// already -- a window *number* that was a position and had to become an
/// identity -- so the repair here is not "a better index" but "not an index".
#[derive(Clone, Copy, PartialEq, Eq)]
enum RootChild {
    TabList,
    /// The strip's menu button; see `MenuButton`.
    MenuButton,
    /// One terminal, named by **which pane of which tab** it is. Both halves
    /// are needed: a pane id alone is unique in the process, but checking the
    /// pair is what keeps a pane that has moved to another tab from matching
    /// here, for the reason `tabs::surface_of_tab_pane` gives at length.
    Document(TabId, PaneId),
}

/// The order of the root's children, which several `Navigate` arms need to
/// agree on: the tab list first, then **one document per pane**, tabs in tab
/// order and panes in each tab's own order.
///
/// **One document per pane, not per tab.** It used to be per tab, built from
/// `TabInfo::pane` -- the tab's *focused* pane -- and that single field is
/// where all three symptoms of task 331 came from: a split tab offered one
/// document instead of two, that document moved from one half to the other
/// as focus did, and the two halves could not have different automation ids
/// because there was only ever one element.
///
/// **Computed from a fresh snapshot every time rather than stored.** A stored
/// order is a second list of tabs, which is the thing `strip.rs` rule 1
/// forbids one level up, and it goes stale in exactly the way that makes a
/// tree look right and navigate wrong.
fn root_children_ided(frame: HWND) -> Vec<(RootChild, IRawElementProviderFragment)> {
    let (tabs_now, _) = tabs::tab_infos(frame);
    let f = frame.0 as isize;
    let mut out: Vec<(RootChild, IRawElementProviderFragment)> = Vec::with_capacity(
        tabs_now.iter().map(|t| t.panes.len()).sum::<usize>() + 1,
    );
    out.push((RootChild::TabList, TabList { frame: f }.into()));
    // **After the tab list, before the documents.** The order is what several
    // `Navigate` arms agree on, and it matches what a reader sees: the strip
    // across the top, then the terminals under it.
    out.push((RootChild::MenuButton, MenuButton { frame: f }.into()));
    for t in tabs_now.iter() {
        for p in t.panes.iter() {
            out.push((
                RootChild::Document(t.id, p.id),
                Document {
                    frame: f,
                    tab: t.id,
                    pane: p.id,
                }
                .into(),
            ));
        }
    }
    out
}

/// `root_children_ided` for the callers that only want the elements.
///
/// **Deliberately derived from the same function** rather than built beside
/// it: two functions producing "the root's children" is the shape where the
/// tree a client walks and the positions `Navigate` computes drift apart, and
/// nothing about the tree looks wrong while they do.
fn root_children(frame: HWND) -> Vec<IRawElementProviderFragment> {
    root_children_ided(frame).into_iter().map(|(_, f)| f).collect()
}

/// The window of **one particular pane**, from one snapshot.
///
/// The twin of `tabs::surface_of_tab_pane`, and it checks the same triple for
/// the same reason: a pane id alone is unique in the process, so looking one
/// up without its tab happily answers for a pane that has since moved into
/// another tab or another window. `None` is the caller's cue that this
/// element is gone, which is a different fact from "it has no rectangle".
fn pane_hwnd(frame: HWND, tab: TabId, pane: PaneId) -> Option<HWND> {
    tabs::tab_infos(frame)
        .0
        .iter()
        .find(|t| t.id == tab)
        .and_then(|t| t.panes.iter().find(|p| p.id == pane))
        .filter(|p| p.hwnd != 0)
        .map(|p| HWND(p.hwnd as *mut core::ffi::c_void))
}

/// Where `who` sits among the root's children, and the children themselves,
/// **from a single snapshot**.
///
/// Two calls would be two snapshots, and a pane closing between them turns a
/// correct index into a neighbour's element -- which is the defect this
/// helper exists to make unwriteable, not merely unlikely.
fn step_among_root_children(
    frame: HWND,
    who: RootChild,
    direction: NavigateDirection,
) -> WResult<IRawElementProviderFragment> {
    let kids = root_children_ided(frame);
    let Some(idx) = kids.iter().position(|(k, _)| *k == who) else {
        return Err(gone());
    };
    step(kids.into_iter().map(|(_, f)| f).collect(), idx, direction)
}

/// Where `idx` sits among `items`, in the direction asked for.
fn step(
    items: Vec<IRawElementProviderFragment>,
    idx: usize,
    direction: NavigateDirection,
) -> WResult<IRawElementProviderFragment> {
    // `if`/`else` rather than `match` only because there are two arms and a
    // fallthrough; the generated newtypes do derive `PartialEq`/`Eq`, so
    // matching on them works and is used elsewhere in this file.
    let want = if direction == NavigateDirection_NextSibling {
        idx.checked_add(1)
    } else if direction == NavigateDirection_PreviousSibling {
        idx.checked_sub(1)
    } else {
        None
    };
    // **`S_OK` with a null is how UIA says "there is no such element"**, not
    // an error -- but `windows`' generated wrapper turns a null return into
    // `E_POINTER` unless we hand it something. There is no way to express
    // "success and nothing" through a `Result<Interface>`, so the honest
    // failure here is an error code that means "nothing", and
    // `UIA_E_ELEMENTNOTAVAILABLE` is the one clients treat as end-of-list.
    match want.and_then(|i| items.into_iter().nth(i)) {
        Some(f) => Ok(f),
        None => Err(gone()),
    }
}

// --------------------------------------------------------------- WindowRoot

impl IRawElementProviderSimple_Impl for WindowRoot_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }

    fn GetPatternProvider(&self, _id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        // no pattern: it is the window itself. Moving, resizing and closing a
        // window are the system's to offer through the host provider below,
        // not this tree's -- a second answer here would be a second thing to
        // keep in step with the window manager.
        // No patterns on the frame itself. The window pattern a client will
        // want (minimise, maximise) comes from the host provider below, which
        // is the operating system's own and better than anything written
        // here.
        Err(gone())
    }

    fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        Ok(match id {
            UIA_ControlTypePropertyId => variant_i4(UIA_WindowControlTypeId.0),
            UIA_NamePropertyId => variant_bstr(&root_name(self.hwnd())),
            // `w<n>`. **Two limits on what this promises, and the second one
            // is a property that was silently lost rather than a bug that was
            // added** -- which is the harder of the two to find later,
            // because nothing records that it used to hold.
            //
            //  - **It is stable for one window, for one run of the process.**
            //    `NEXT_ID` restarts at 1 when the process does, so after a
            //    restart `w1` is the *new* first window. An automation script
            //    that remembers this string across runs finds a window that
            //    exists and looks entirely normal and is not the one it
            //    meant. Nothing errors.
            //  - **Its range is now unbounded.** Until `081bc0546` the number
            //    was a position in a registry, so it never exceeded the
            //    number of live windows; it is now a counter that only goes
            //    up, and a long session reaches `w17`, `w200`. Nothing in
            //    this file or in `windows/tools/` formats it into a fixed
            //    width today -- checked -- but "it is a small number" is a
            //    guarantee that no longer exists.
            //
            // Locate elements by structure and content instead. The criterion
            // script (`windows/tools/uia-tree-dump.ps1`) says the same at
            // greater length, because the person who needs it reads that file
            // and not this one.
            UIA_AutomationIdPropertyId => variant_bstr(&winid::tag(self.hwnd())),
            // Asked of Windows, never assumed; see `window_enabled`.
            UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
            UIA_IsControlElementPropertyId | UIA_IsContentElementPropertyId => variant_bool(true),
            _ => variant_empty(),
        })
    }

    fn HostRawElementProvider(&self) -> WResult<IRawElementProviderSimple> {
        // **Required, and the one line whose absence is invisible.** Without
        // the host provider UIA has no `HWND` for this element, so the window
        // has no bounding rectangle, no process id and no place in the
        // desktop tree -- the provider works and no tool can reach it.
        unsafe { UiaHostProviderFromHwnd(self.hwnd()) }
    }
}

impl IRawElementProviderFragment_Impl for WindowRoot_Impl {
    fn Navigate(&self, direction: NavigateDirection) -> WResult<IRawElementProviderFragment> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        match direction {
            // The desktop is the parent, and UIA supplies that itself from
            // the host provider. Answering here would insert a second parent.
            NavigateDirection_Parent => Err(gone()),
            NavigateDirection_FirstChild => {
                root_children(self.hwnd()).into_iter().next().ok_or_else(gone)
            }
            NavigateDirection_LastChild => {
                root_children(self.hwnd()).into_iter().last().ok_or_else(gone)
            }
            _ => Err(gone()),
        }
    }

    /// **Gated like every other entry point on this provider.**
    ///
    /// The gate is not here for uniqueness -- `UiaAppendRuntimeId` gets that
    /// from the framework. It is here because `on_get_object` refuses a
    /// window that has left the registry, and a provider whose two entry
    /// points give different answers to "is this still a window" is the same
    /// shape as a fact with two owners. A UIA client holds its elements after
    /// they are gone and keeps asking; this is the method it asks with.
    ///
    /// **Nor is it here for stability, so `081bc0546` does not retire it.**
    /// That commit made the window number an identity rather than a position,
    /// which fixed a real defect in what this method returns -- a cached
    /// runtime id stopped meaning a different window after some other window
    /// closed. The two facts are easy to run together into "the gate can go
    /// now", so: without it, a dead window's `GetRuntimeId` **succeeds**
    /// while every other method on the same element answers
    /// `UIA_E_ELEMENTNOTAVAILABLE`. That is the disagreement, and it is
    /// untouched by how the number is assigned.
    ///
    /// **`live` and `of` take the lock separately**, so a window dying
    /// between them yields a runtime id with a zero where the window number
    /// goes. It cannot collide (the host prefix still differs) and the window
    /// is leaving anyway -- but it is a value with no meaning wearing the
    /// shape of one, which is the kind that costs somebody half an hour if
    /// they ever chase it. Written down rather than locked out.
    fn GetRuntimeId(&self) -> WResult<*mut SAFEARRAY> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        runtime_id(winid::of(self.hwnd()), KIND_ROOT, 0)
    }

    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        Ok(window_rect(self.hwnd()))
    }

    fn GetEmbeddedFragmentRoots(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }

    fn SetFocus(&self) -> WResult<()> {
        // Deliberately nothing. Focus on Windows belongs to the window
        // manager, and a provider that calls `SetForegroundWindow` here would
        // let any UIA client steal focus.
        Ok(())
    }

    fn FragmentRoot(&self) -> WResult<IRawElementProviderFragmentRoot> {
        Ok(root_of(self.frame))
    }
}

impl IRawElementProviderFragmentRoot_Impl for WindowRoot_Impl {
    fn ElementProviderFromPoint(&self, x: f64, y: f64) -> WResult<IRawElementProviderFragment> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        // Screen coordinates in, client coordinates for the hit test.
        let mut p = POINT { x: x as i32, y: y as i32 };
        unsafe {
            let _ = windows::Win32::Graphics::Gdi::ScreenToClient(frame, &mut p);
        }
        for (id, r) in crate::strip::tab_rects(frame) {
            if p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom {
                return Ok(TabItem { frame: self.frame, tab: id }.into());
            }
        }
        // Below the strip the active tab owns the area -- and **which pane
        // of it is decided by the point**, not by which pane has focus. A
        // split tab used to answer with the focused half wherever you
        // pointed, so a client asking "what is under the mouse" was told
        // about the other half of the window and had no way to notice.
        let (tabs_now, active) = tabs::tab_infos(frame);
        let Some(t) = tabs_now.get(active) else {
            return Err(gone());
        };
        // The point in *screen* coordinates: `p` above was converted to the
        // frame's client space for the strip, and a pane's `GetWindowRect` is
        // in screen space. Mixing the two lands in the wrong half by exactly
        // the frame's top-left, which is a plausible-looking answer.
        let screen = POINT { x: x as i32, y: y as i32 };
        for pane in t.panes.iter() {
            if pane.hwnd == 0 {
                continue;
            }
            let h = HWND(pane.hwnd as *mut core::ffi::c_void);
            // A zoomed split hides the panes it covers, and a hidden window
            // keeps its last rectangle -- so without this, a hidden pane
            // still claims the area the zoomed one is drawn over.
            if !unsafe { IsWindowVisible(h) }.as_bool() {
                continue;
            }
            let mut r = RECT::default();
            if unsafe { GetWindowRect(h, &mut r) }.is_ok()
                && screen.x >= r.left
                && screen.x < r.right
                && screen.y >= r.top
                && screen.y < r.bottom
            {
                return Ok(Document {
                    frame: self.frame,
                    tab: t.id,
                    pane: pane.id,
                }
                .into());
            }
        }
        // No pane covers the point: it is on a divider, or on the padding
        // around them. **Answering with the focused pane rather than
        // refusing** -- the area does belong to this tab, and a client that
        // gets nothing here concludes the window has no content at all.
        Ok(Document {
            frame: self.frame,
            tab: t.id,
            pane: t.pane,
        }
        .into())
    }

    /// **The focused pane, and here that is the whole answer** -- unlike
    /// `ElementProviderFromPoint` above, which had to stop using it. This
    /// method is asked which element has the keyboard, and `TabInfo::pane` is
    /// exactly that; a split tab's other half is a different element and does
    /// not have the caret.
    fn GetFocus(&self) -> WResult<IRawElementProviderFragment> {
        let frame = self.hwnd();
        let (tabs_now, active) = tabs::tab_infos(frame);
        match tabs_now.get(active) {
            Some(t) => Ok(Document {
                frame: self.frame,
                tab: t.id,
                pane: t.pane,
            }
            .into()),
            None => Err(gone()),
        }
    }
}

// ------------------------------------------------------------------ TabList

impl IRawElementProviderSimple_Impl for TabList_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }
    fn GetPatternProvider(&self, _id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        // no pattern: SelectionPattern is what belongs here, and its
        // GetSelection hands back a raw SAFEARRAY that nothing in this port
        // can exercise where it is written -- an untested hand-built one is a
        // memory bug waiting for a client. Each tab answers
        // SelectionItemPattern instead, which is what a client asks when it
        // wants to know, or change, which tab is active.
        Err(gone())
    }
    fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        Ok(match id {
            UIA_ControlTypePropertyId => variant_i4(UIA_TabControlTypeId.0),
            UIA_NamePropertyId => variant_bstr("Tabs"),
            UIA_AutomationIdPropertyId => variant_bstr("tab-strip"),
            // Asked of Windows, never assumed; see `window_enabled`.
            UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
            UIA_IsControlElementPropertyId | UIA_IsContentElementPropertyId => variant_bool(true),
            _ => variant_empty(),
        })
    }
    fn HostRawElementProvider(&self) -> WResult<IRawElementProviderSimple> {
        // **Null, not the frame's host provider.** Only the fragment root
        // names an HWND; giving a child the same one makes UIA treat it as a
        // second root for that window, and the tree folds in on itself.
        Err(gone())
    }
}

impl IRawElementProviderFragment_Impl for TabList_Impl {
    fn Navigate(&self, direction: NavigateDirection) -> WResult<IRawElementProviderFragment> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        match direction {
            NavigateDirection_Parent => {
                let r: IRawElementProviderFragment = WindowRoot { frame: self.frame }.into();
                Ok(r)
            }
            NavigateDirection_FirstChild | NavigateDirection_LastChild => {
                let (tabs_now, _) = tabs::tab_infos(frame);
                let pick = if direction == NavigateDirection_FirstChild {
                    tabs_now.first()
                } else {
                    tabs_now.last()
                };
                match pick {
                    Some(t) => Ok(TabItem { frame: self.frame, tab: t.id }.into()),
                    None => Err(gone()),
                }
            }
            // The tab list has no previous sibling; its next is the first
            // document. **Found by identity even though the answer is always
            // 0**: the constant was another copy of "where the tab list sits
            // among the root's children", and a second copy of a position is
            // how the two come to disagree.
            NavigateDirection_NextSibling => {
                step_among_root_children(frame, RootChild::TabList, direction)
            }
            _ => Err(gone()),
        }
    }

    /// **Gated like every other entry point on this provider.**
    ///
    /// The gate is not here for uniqueness -- `UiaAppendRuntimeId` gets that
    /// from the framework. It is here because `on_get_object` refuses a
    /// window that has left the registry, and a provider whose two entry
    /// points give different answers to "is this still a window" is the same
    /// shape as a fact with two owners. A UIA client holds its elements after
    /// they are gone and keeps asking; this is the method it asks with.
    ///
    /// **Nor is it here for stability, so `081bc0546` does not retire it.**
    /// That commit made the window number an identity rather than a position,
    /// which fixed a real defect in what this method returns -- a cached
    /// runtime id stopped meaning a different window after some other window
    /// closed. The two facts are easy to run together into "the gate can go
    /// now", so: without it, a dead window's `GetRuntimeId` **succeeds**
    /// while every other method on the same element answers
    /// `UIA_E_ELEMENTNOTAVAILABLE`. That is the disagreement, and it is
    /// untouched by how the number is assigned.
    ///
    /// **`live` and `of` take the lock separately**, so a window dying
    /// between them yields a runtime id with a zero where the window number
    /// goes. It cannot collide (the host prefix still differs) and the window
    /// is leaving anyway -- but it is a value with no meaning wearing the
    /// shape of one, which is the kind that costs somebody half an hour if
    /// they ever chase it. Written down rather than locked out.
    fn GetRuntimeId(&self) -> WResult<*mut SAFEARRAY> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        runtime_id(winid::of(self.hwnd()), KIND_TABLIST, 0)
    }
    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        Ok(strip_rect(self.hwnd()))
    }
    fn GetEmbeddedFragmentRoots(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }
    fn SetFocus(&self) -> WResult<()> {
        Ok(())
    }
    fn FragmentRoot(&self) -> WResult<IRawElementProviderFragmentRoot> {
        Ok(root_of(self.frame))
    }
}

// --------------------------------------------------------------- MenuButton

impl IRawElementProviderSimple_Impl for MenuButton_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }
    fn GetPatternProvider(&self, id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        if id == UIA_InvokePatternId {
            let p: IInvokeProvider = MenuButton { frame: self.frame }.into();
            return Ok(p.into());
        }
        // **No ExpandCollapse, on purpose.** The pattern would promise a
        // client it can read whether the menu is open and close it again, and
        // this host has no way to answer the second half: the menu is a
        // `TrackPopupMenu` that runs its own loop. A pattern that answers one
        // of its two questions is worse than one that is not offered.
        Err(gone())
    }
    fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        Ok(match id {
            UIA_ControlTypePropertyId => variant_i4(UIA_ButtonControlTypeId.0),
            // The name a person would say. Through `tr` like the rest of the
            // host's user-visible text, so it follows the catalogue rather
            // than being a second English string.
            UIA_NamePropertyId => variant_bstr(&crate::i18n::tr("Menu")),
            // ⚠️ **The stable handle, and the reason it is not the name.** A
            // client that writes down "Menu" has written down a word that
            // changes with the display language; this does not.
            UIA_AutomationIdPropertyId => variant_bstr("tab-strip-menu-button"),
            // Asked of Windows, never assumed; see `window_enabled`.
            UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
            UIA_IsControlElementPropertyId | UIA_IsContentElementPropertyId => variant_bool(true),
            _ => variant_empty(),
        })
    }
    fn HostRawElementProvider(&self) -> WResult<IRawElementProviderSimple> {
        // Null for the same reason the tab list gives: only the fragment root
        // names an HWND.
        Err(gone())
    }
}

impl IRawElementProviderFragment_Impl for MenuButton_Impl {
    fn Navigate(&self, direction: NavigateDirection) -> WResult<IRawElementProviderFragment> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        match direction {
            NavigateDirection_Parent => {
                let r: IRawElementProviderFragment = WindowRoot { frame: self.frame }.into();
                Ok(r)
            }
            // A leaf: the menu it opens is a `TrackPopupMenu`, which Windows
            // provides for itself and which is not a child of this element.
            NavigateDirection_FirstChild | NavigateDirection_LastChild => Err(gone()),
            // Found by identity rather than by a constant index, for the
            // reason `TabList::Navigate` gives: a written-down position is a
            // second copy of the order in `root_children_ided`.
            _ => step_among_root_children(frame, RootChild::MenuButton, direction),
        }
    }
    fn GetRuntimeId(&self) -> WResult<*mut SAFEARRAY> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        runtime_id(winid::of(self.hwnd()), KIND_MENU_BUTTON, 0)
    }
    /// The button's rectangle, on screen.
    ///
    /// **Read from the strip's own geometry every time.** The button moves
    /// with the window, and a client that was handed a constant would click
    /// where the button is on a maximised window -- which is exactly what a
    /// hard-coded `(14, 15)` did, and why it worked in one screenshot and
    /// nowhere else.
    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        Ok(client_rect_to_screen(frame, crate::strip::menu_button_rect(frame)))
    }
    fn GetEmbeddedFragmentRoots(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }
    fn SetFocus(&self) -> WResult<()> {
        Ok(())
    }
    fn FragmentRoot(&self) -> WResult<IRawElementProviderFragmentRoot> {
        Ok(root_of(self.frame))
    }
}

impl IInvokeProvider_Impl for MenuButton_Impl {
    /// Open the menu.
    ///
    /// **Posted to the window's own thread, not run here.** This call arrives
    /// on the automation core's thread, and `TrackPopupMenu` runs a modal
    /// loop that must belong to the thread that owns the window -- the same
    /// reason `activate_from_uia` posts.
    fn Invoke(&self) -> WResult<()> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        crate::strip::request_root_menu(frame);
        Ok(())
    }
}

// ------------------------------------------------------------------ TabItem

impl IRawElementProviderSimple_Impl for TabItem_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }
    fn GetPatternProvider(&self, id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        // **Both, and offering both is the deliberate part.** A tab strip is
        // a selection container, so `SelectionItemPattern` is the correct
        // answer and the one a screen reader looks for. `InvokePattern` is
        // what a generic automation client reaches for first, and a client
        // that finds neither falls back to synthesising a click at a
        // coordinate -- which is the thing this exists to stop.
        //
        // ⚠️ Offering both is normally discouraged, because on most controls
        // "select" and "invoke" are different events. On a tab they are not:
        // there is nothing to do with a tab but make it the active one, and
        // refusing `Invoke` would leave the commonest client with nothing.
        if id == UIA_SelectionItemPatternId {
            let p: ISelectionItemProvider = TabItem { frame: self.frame, tab: self.tab }.into();
            return Ok(p.into());
        }
        if id == UIA_InvokePatternId {
            let p: IInvokeProvider = TabItem { frame: self.frame, tab: self.tab }.into();
            return Ok(p.into());
        }
        Err(gone())
    }
    fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        let (tabs_now, active) = tabs::tab_infos(frame);
        let Some(idx) = tabs_now.iter().position(|t| t.id == self.tab) else {
            return Err(gone());
        };
        Ok(match id {
            UIA_ControlTypePropertyId => variant_i4(UIA_TabItemControlTypeId.0),
            UIA_NamePropertyId => variant_bstr(&tabs_now[idx].title),
            // The tab's own id, not its position -- the same rule the runtime
            // id follows, and for the same reason: a test that pins
            // `AutomationId` would otherwise be pinning "third from the left".
            UIA_AutomationIdPropertyId => variant_bstr(&format!("tab-{}", self.tab.0)),
            UIA_HasKeyboardFocusPropertyId => variant_bool(idx == active),
            // Asked of Windows, never assumed; see `window_enabled`.
            UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
            UIA_IsControlElementPropertyId | UIA_IsContentElementPropertyId => variant_bool(true),
            _ => variant_empty(),
        })
    }
    fn HostRawElementProvider(&self) -> WResult<IRawElementProviderSimple> {
        Err(gone())
    }
}

impl IRawElementProviderFragment_Impl for TabItem_Impl {
    fn Navigate(&self, direction: NavigateDirection) -> WResult<IRawElementProviderFragment> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        match direction {
            NavigateDirection_Parent => {
                let r: IRawElementProviderFragment = TabList { frame: self.frame }.into();
                Ok(r)
            }
            NavigateDirection_NextSibling | NavigateDirection_PreviousSibling => {
                let (tabs_now, _) = tabs::tab_infos(frame);
                let Some(idx) = tabs_now.iter().position(|t| t.id == self.tab) else {
                    return Err(gone());
                };
                let items: Vec<IRawElementProviderFragment> = tabs_now
                    .iter()
                    .map(|t| TabItem { frame: self.frame, tab: t.id }.into())
                    .collect();
                step(items, idx, direction)
            }
            _ => Err(gone()),
        }
    }
    /// **Gated like every other entry point on this provider.**
    ///
    /// The gate is not here for uniqueness -- `UiaAppendRuntimeId` gets that
    /// from the framework. It is here because `on_get_object` refuses a
    /// window that has left the registry, and a provider whose two entry
    /// points give different answers to "is this still a window" is the same
    /// shape as a fact with two owners. A UIA client holds its elements after
    /// they are gone and keeps asking; this is the method it asks with.
    ///
    /// **Nor is it here for stability, so `081bc0546` does not retire it.**
    /// That commit made the window number an identity rather than a position,
    /// which fixed a real defect in what this method returns -- a cached
    /// runtime id stopped meaning a different window after some other window
    /// closed. The two facts are easy to run together into "the gate can go
    /// now", so: without it, a dead window's `GetRuntimeId` **succeeds**
    /// while every other method on the same element answers
    /// `UIA_E_ELEMENTNOTAVAILABLE`. That is the disagreement, and it is
    /// untouched by how the number is assigned.
    ///
    /// **`live` and `of` take the lock separately**, so a window dying
    /// between them yields a runtime id with a zero where the window number
    /// goes. It cannot collide (the host prefix still differs) and the window
    /// is leaving anyway -- but it is a value with no meaning wearing the
    /// shape of one, which is the kind that costs somebody half an hour if
    /// they ever chase it. Written down rather than locked out.
    fn GetRuntimeId(&self) -> WResult<*mut SAFEARRAY> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        runtime_id(winid::of(self.hwnd()), KIND_TABITEM, self.tab.0)
    }
    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        let frame = self.hwnd();
        match crate::strip::tab_rects(frame)
            .into_iter()
            .find(|(id, _)| *id == self.tab)
        {
            Some((_, r)) => Ok(client_rect_to_screen(frame, r)),
            // Scrolled out of the strip: a real state, and an empty rectangle
            // is what UIA means by "off screen".
            None => Ok(UiaRect { left: 0.0, top: 0.0, width: 0.0, height: 0.0 }),
        }
    }
    fn GetEmbeddedFragmentRoots(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }
    fn SetFocus(&self) -> WResult<()> {
        Ok(())
    }
    fn FragmentRoot(&self) -> WResult<IRawElementProviderFragmentRoot> {
        Ok(root_of(self.frame))
    }
}

/// Making a tab active, from a client that is not on this window's thread.
///
/// **Queued, never done here.** `set_active` moves child windows around, and
/// a UI Automation call arrives on whichever thread the automation core felt
/// like using; showing and hiding windows off the owning thread is undefined.
/// `post_op` is the road every other cross-thread request in this port takes.
///
/// **The op carries the `TabId`.** `Op::GotoTab` would have been one line
/// less and takes an index, and an index resolved after the queue drains can
/// name a different tab than the one the client pointed at.
fn activate_from_uia(frame_raw: isize, tab: TabId, how: &str) -> WResult<()> {
    let frame = HWND(frame_raw as *mut core::ffi::c_void);
    if !live(frame) {
        return Err(gone());
    }
    wlogf!(frame, "[uia] {} tab {} -> queued", how, tab.0);
    tabs::post_op(frame, tabs::Op::ActivateTab(tab), "uia");
    Ok(())
}

impl ISelectionItemProvider_Impl for TabItem_Impl {
    fn Select(&self) -> WResult<()> {
        activate_from_uia(self.frame, self.tab, "Select")
    }

    /// **The same as `Select`.** A tab strip holds exactly one selection, so
    /// "add to the selection" can only mean "become the selection"; refusing
    /// would make a client that reaches for this first conclude the tab
    /// cannot be selected at all.
    fn AddToSelection(&self) -> WResult<()> {
        activate_from_uia(self.frame, self.tab, "AddToSelection")
    }

    /// **Refused, and that is the honest answer.** There is no state in which
    /// no tab is active; deselecting one would have to activate another, and
    /// the client did not say which.
    fn RemoveFromSelection(&self) -> WResult<()> {
        Err(gone())
    }

    fn IsSelected(&self) -> WResult<windows_core::BOOL> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        let (tabs_now, active) = tabs::tab_infos(frame);
        let Some(idx) = tabs_now.iter().position(|t| t.id == self.tab) else {
            return Err(gone());
        };
        Ok((idx == active).into())
    }

    fn SelectionContainer(&self) -> WResult<IRawElementProviderSimple> {
        Ok(TabList { frame: self.frame }.into())
    }
}

impl IInvokeProvider_Impl for TabItem_Impl {
    fn Invoke(&self) -> WResult<()> {
        activate_from_uia(self.frame, self.tab, "Invoke")
    }
}

// ----------------------------------------------------------------- Document

impl IRawElementProviderSimple_Impl for Document_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }
    fn GetPatternProvider(&self, id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        if id == UIA_ValuePatternId {
            let v: IValueProvider = Document {
                frame: self.frame,
                tab: self.tab,
                pane: self.pane,
            }
            .into();
            return Ok(v.into());
        }
        // **`TextPattern`, which is what a screen reader really wants here.**
        // `ValuePattern` above hands out the visible screen as one string and
        // nothing else -- no selection, no ranges, no idea where on screen a
        // piece of output is. What this one can and cannot answer, and where
        // every coordinate it reports comes from, is argued at `TermRange`.
        if id == UIA_TextPatternId {
            let t: ITextProvider = Document {
                frame: self.frame,
                tab: self.tab,
                pane: self.pane,
            }
            .into();
            return Ok(t.into());
        }
        Err(gone())
    }
    fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        let (tabs_now, active) = tabs::tab_infos(frame);
        let Some(idx) = tabs_now.iter().position(|t| t.id == self.tab) else {
            return Err(gone());
        };
        Ok(match id {
            UIA_ControlTypePropertyId => variant_i4(UIA_DocumentControlTypeId.0),
            // ⚠️ **Both halves of a split answer with the same name**, and
            // this change does not fix that. The title belongs to the tab --
            // there is no per-pane title anywhere in the model to use -- and
            // the obvious substitute, "pane 1 of 2", is a position: it
            // renumbers when a pane closes, which is the thing the automation
            // id above went out of its way not to do. So the halves are told
            // apart by their automation id and their rectangle, not by name,
            // and a client that only reads names still cannot tell them
            // apart. Left as a known gap rather than papered over.
            UIA_NamePropertyId => variant_bstr(&format!("Terminal: {}", tabs_now[idx].title)),
            // **The number here is the pane's, and it used to be the tab's.**
            //
            // It has to change, because the automation id has to be unique
            // and two panes of one tab are two elements: keyed on the tab
            // they would both answer `terminal-2`, and a client that picks an
            // element by automation id would get whichever it found first.
            //
            // ⚠️ **A client that wrote down an old `terminal-N` will not find
            // it after this change** -- the same tab now answers with a
            // different number. That is not avoidable, and the reason is
            // worth stating rather than regretting: the only way to keep the
            // old ids meaningful would be to keep one document per tab that
            // points at whichever pane has focus, **and that element is the
            // defect this change exists to remove**.
            //
            // Stable in the sense that matters, which is not "unchanging
            // across this release": a pane id is handed out once by
            // `tabs::take_id` and never reused, so it names this half of this
            // split for as long as it exists, and closing another pane does
            // not renumber it. That is the same argument `tab-<id>` makes.
            // **It is not a fourth counter**: panes and tabs come out of the
            // one process-wide allocator, which is why the numbers a client
            // sees skip (1, 3, ...) -- the gaps are the tabs.
            UIA_AutomationIdPropertyId => variant_bstr(&format!("terminal-{}", self.pane)),
            // **Both halves of a split are in the active tab; only one of
            // them has the caret.** While there was one document per tab,
            // "my tab is active" and "I have the keyboard" were the same
            // sentence. They are not any more, and leaving this arm as it
            // stood would have had two elements answering true -- which a
            // screen reader resolves by believing the first one it finds.
            UIA_HasKeyboardFocusPropertyId => {
                variant_bool(idx == active && tabs_now[idx].pane == self.pane)
            }
            // Asked of Windows, never assumed; see `window_enabled`.
            UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
            UIA_IsControlElementPropertyId | UIA_IsContentElementPropertyId => variant_bool(true),
            _ => variant_empty(),
        })
    }
    fn HostRawElementProvider(&self) -> WResult<IRawElementProviderSimple> {
        Err(gone())
    }
}

impl IRawElementProviderFragment_Impl for Document_Impl {
    fn Navigate(&self, direction: NavigateDirection) -> WResult<IRawElementProviderFragment> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        match direction {
            NavigateDirection_Parent => {
                let r: IRawElementProviderFragment = WindowRoot { frame: self.frame }.into();
                Ok(r)
            }
            NavigateDirection_NextSibling | NavigateDirection_PreviousSibling => {
                // **This element finds itself by identity.** What stood here
                // was `step(root_children(frame), t + 1, direction)` -- the
                // tab's index plus one -- which is a correct position only
                // while every tab contributes exactly one document. A split
                // makes it name the neighbour, and the fix is not a corrected
                // sum: an arithmetic that has to be re-derived every time an
                // element is added is one that will be wrong the next time
                // one is.
                step_among_root_children(
                    frame,
                    RootChild::Document(self.tab, self.pane),
                    direction,
                )
            }
            _ => Err(gone()),
        }
    }
    /// **Gated like every other entry point on this provider.**
    ///
    /// The gate is not here for uniqueness -- `UiaAppendRuntimeId` gets that
    /// from the framework. It is here because `on_get_object` refuses a
    /// window that has left the registry, and a provider whose two entry
    /// points give different answers to "is this still a window" is the same
    /// shape as a fact with two owners. A UIA client holds its elements after
    /// they are gone and keeps asking; this is the method it asks with.
    ///
    /// **Nor is it here for stability, so `081bc0546` does not retire it.**
    /// That commit made the window number an identity rather than a position,
    /// which fixed a real defect in what this method returns -- a cached
    /// runtime id stopped meaning a different window after some other window
    /// closed. The two facts are easy to run together into "the gate can go
    /// now", so: without it, a dead window's `GetRuntimeId` **succeeds**
    /// while every other method on the same element answers
    /// `UIA_E_ELEMENTNOTAVAILABLE`. That is the disagreement, and it is
    /// untouched by how the number is assigned.
    ///
    /// **`live` and `of` take the lock separately**, so a window dying
    /// between them yields a runtime id with a zero where the window number
    /// goes. It cannot collide (the host prefix still differs) and the window
    /// is leaving anyway -- but it is a value with no meaning wearing the
    /// shape of one, which is the kind that costs somebody half an hour if
    /// they ever chase it. Written down rather than locked out.
    fn GetRuntimeId(&self) -> WResult<*mut SAFEARRAY> {
        if !live(self.hwnd()) {
            return Err(gone());
        }
        // Keyed on the pane for the reason the automation id is: two panes
        // of one tab are two elements, and a runtime id they share tells the
        // client they are one.
        runtime_id(winid::of(self.hwnd()), KIND_DOCUMENT, self.pane)
    }
    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        // **This pane's window, not the tab's focused one.** What stood
        // here read the focused pane's window, which gave both halves of a
        // split the same rectangle -- so a client hit-testing or drawing a
        // highlight put it on the wrong half of the window and was told, by
        // the tree, that it was right.
        match pane_hwnd(self.hwnd(), self.tab, self.pane) {
            Some(h) => Ok(window_rect(h)),
            None => Ok(UiaRect { left: 0.0, top: 0.0, width: 0.0, height: 0.0 }),
        }
    }
    fn GetEmbeddedFragmentRoots(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }
    fn SetFocus(&self) -> WResult<()> {
        Ok(())
    }
    fn FragmentRoot(&self) -> WResult<IRawElementProviderFragmentRoot> {
        Ok(root_of(self.frame))
    }
}

impl IValueProvider_Impl for Document_Impl {
    fn SetValue(&self, _val: &PCWSTR) -> WResult<()> {
        // Read-only, and it must stay that way: a writable value on a
        // terminal document is a UIA client able to type into the shell.
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn Value(&self) -> WResult<BSTR> {
        match read_viewport(self.hwnd(), self.tab, self.pane) {
            Some(text) => Ok(BSTR::from(text.as_str())),
            None => Err(gone()),
        }
    }

    fn IsReadOnly(&self) -> WResult<windows::core::BOOL> {
        Ok(true.into())
    }
}

// -------------------------------------------------------- the command palette
//
// **A second fragment root, on a second window, and that is the shape the
// palette needs rather than a subtree under the frame.** The palette is its
// own top-level window; UI Automation reaches a window through that window's
// own `WM_GETOBJECT`, and hanging its rows off the frame's tree would put
// them somewhere no client looks.
//
// **What was there before: one anonymous `EDIT` and nothing else.** The
// palette answers `WM_GETOBJECT` nowhere, so it fell to `DefWindowProcW` and
// the default provider described the window and its one real child control.
// Every row is drawn by us, so every row was invisible -- a list a client can
// type into and cannot read.

#[implement(
    IRawElementProviderSimple,
    IRawElementProviderFragment,
    IRawElementProviderFragmentRoot
)]
struct PaletteRoot {
    hwnd: isize,
}

#[implement(
    IRawElementProviderSimple,
    IRawElementProviderFragment,
    IInvokeProvider,
    ISelectionItemProvider
)]
struct PaletteItem {
    hwnd: isize,
    /// Position in the visible list. **Not a command id**, because the list is
    /// rebuilt on every keystroke and there is no id to be had; `run_index`
    /// re-reads the row at this position and refuses if the list moved.
    index: usize,
}

impl PaletteRoot {
    fn hwnd(&self) -> HWND {
        HWND(self.hwnd as *mut core::ffi::c_void)
    }
}
impl PaletteItem {
    fn hwnd(&self) -> HWND {
        HWND(self.hwnd as *mut core::ffi::c_void)
    }
    /// This row's `(title, action)` right now, or `None` if it has gone.
    fn row(&self) -> Option<(String, String)> {
        crate::palette::row(self.index)
    }
}

impl IRawElementProviderSimple_Impl for PaletteRoot_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }
    fn GetPatternProvider(&self, _id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        // no pattern: the same reason `TabList` gives -- SelectionPattern
        // would be correct and its SAFEARRAY cannot be exercised here. Each
        // row answers SelectionItemPattern and InvokePattern, which is what
        // a client needs to read the list and run a row.
        Err(gone())
    }
    fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
        Ok(match id {
            UIA_ControlTypePropertyId => variant_i4(UIA_ListControlTypeId.0),
            UIA_NamePropertyId => variant_bstr("Command palette"),
            UIA_AutomationIdPropertyId => variant_bstr("command-palette"),
            // Asked of Windows, never assumed; see `window_enabled`.
            UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
            UIA_IsControlElementPropertyId | UIA_IsContentElementPropertyId => variant_bool(true),
            _ => variant_empty(),
        })
    }
    /// **The window's own default provider, kept.** The palette has a real
    /// `EDIT` child; handing back the host provider is what lets the window's
    /// own properties and that control keep working rather than being
    /// replaced by this tree.
    fn HostRawElementProvider(&self) -> WResult<IRawElementProviderSimple> {
        unsafe { UiaHostProviderFromHwnd(self.hwnd()) }
    }
}

impl IRawElementProviderFragment_Impl for PaletteRoot_Impl {
    fn Navigate(&self, direction: NavigateDirection) -> WResult<IRawElementProviderFragment> {
        let n = crate::palette::row_count();
        match direction {
            NavigateDirection_FirstChild if n > 0 => {
                let r: IRawElementProviderFragment =
                    PaletteItem { hwnd: self.hwnd, index: 0 }.into();
                Ok(r)
            }
            NavigateDirection_LastChild if n > 0 => {
                let r: IRawElementProviderFragment =
                    PaletteItem { hwnd: self.hwnd, index: n - 1 }.into();
                Ok(r)
            }
            _ => Err(gone()),
        }
    }
    fn GetRuntimeId(&self) -> WResult<*mut SAFEARRAY> {
        // **Keyed by the palette's own window handle**, low 32 bits, the way
        // the frame providers are keyed by `winid::of`. There is one palette
        // for the process, so any stable number does; using the handle keeps
        // it derivable from what a client already has.
        runtime_id(self.hwnd as u32, KIND_PALETTE, 0)
    }
    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        Ok(window_rect(self.hwnd()))
    }
    fn GetEmbeddedFragmentRoots(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }
    fn SetFocus(&self) -> WResult<()> {
        Ok(())
    }
    fn FragmentRoot(&self) -> WResult<IRawElementProviderFragmentRoot> {
        Ok(PaletteRoot { hwnd: self.hwnd }.into())
    }
}

impl IRawElementProviderFragmentRoot_Impl for PaletteRoot_Impl {
    fn ElementProviderFromPoint(&self, _x: f64, _y: f64) -> WResult<IRawElementProviderFragment> {
        // **Not implemented, and it is the one a coordinate-driven client
        // uses.** Hit-testing a row would mean a second copy of the row
        // geometry `palette.rs` paints with, and the two would disagree the
        // first time either changed. A client that can enumerate and invoke
        // does not need to point at anything, which is the whole aim here.
        Err(gone())
    }
    fn GetFocus(&self) -> WResult<IRawElementProviderFragment> {
        match crate::palette::selected_row() {
            Some(i) => {
                let r: IRawElementProviderFragment =
                    PaletteItem { hwnd: self.hwnd, index: i }.into();
                Ok(r)
            }
            None => Err(gone()),
        }
    }
}

impl IRawElementProviderSimple_Impl for PaletteItem_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }
    fn GetPatternProvider(&self, id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        if id == UIA_InvokePatternId {
            let p: IInvokeProvider = PaletteItem { hwnd: self.hwnd, index: self.index }.into();
            return Ok(p.into());
        }
        if id == UIA_SelectionItemPatternId {
            let p: ISelectionItemProvider =
                PaletteItem { hwnd: self.hwnd, index: self.index }.into();
            return Ok(p.into());
        }
        Err(gone())
    }
    fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
        let Some((title, action)) = self.row() else {
            return Err(gone());
        };
        Ok(match id {
            UIA_ControlTypePropertyId => variant_i4(UIA_ListItemControlTypeId.0),
            UIA_NamePropertyId => variant_bstr(&title),
            // **The core's action string, not the position.** It is the only
            // stable name a row has: the list is rebuilt on every keystroke,
            // so `palette-row-3` would name a different command a moment
            // later -- the same rule the tab items follow.
            UIA_AutomationIdPropertyId => variant_bstr(&action),
            // Asked of Windows, never assumed; see `window_enabled`.
            UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
            UIA_IsControlElementPropertyId | UIA_IsContentElementPropertyId => variant_bool(true),
            // **This is what makes a zero rectangle readable.**
            //
            // Only about a dozen of the rows are drawn; the rest have no
            // place, and `BoundingRectangle` answers zero for them. But zero
            // was also what a row answered when the window went away between
            // the snapshot and the call -- so a client saw one value for two
            // situations it must treat differently: *scroll to it* and *ask
            // again, something is wrong*.
            //
            // Derived from `row_rect` and nothing else, which is what keeps
            // the pair meaningful:
            //
            //   zero rectangle + IsOffscreen true   -> not in view; expected
            //   zero rectangle + IsOffscreen false  -> the provider could not
            //                                          answer; not expected
            //
            // ⚠️ **NOT COVERED: tabs scrolled out of the strip.** `TabItem`
            // has the same question and does not answer it here; this arm is
            // about the palette's rows, which is where it was measured.
            UIA_IsOffscreenPropertyId => {
                variant_bool(crate::palette::row_rect(self.index).is_none())
            }
            _ => variant_empty(),
        })
    }
    fn HostRawElementProvider(&self) -> WResult<IRawElementProviderSimple> {
        Err(gone())
    }
}

impl IRawElementProviderFragment_Impl for PaletteItem_Impl {
    fn Navigate(&self, direction: NavigateDirection) -> WResult<IRawElementProviderFragment> {
        let n = crate::palette::row_count();
        if self.index >= n {
            return Err(gone());
        }
        let sibling = |i: usize| -> WResult<IRawElementProviderFragment> {
            let r: IRawElementProviderFragment = PaletteItem { hwnd: self.hwnd, index: i }.into();
            Ok(r)
        };
        match direction {
            NavigateDirection_Parent => {
                let r: IRawElementProviderFragment = PaletteRoot { hwnd: self.hwnd }.into();
                Ok(r)
            }
            NavigateDirection_NextSibling if self.index + 1 < n => {
                sibling(self.index + 1)
            }
            NavigateDirection_PreviousSibling if self.index > 0 => sibling(self.index - 1),
            _ => Err(gone()),
        }
    }
    fn GetRuntimeId(&self) -> WResult<*mut SAFEARRAY> {
        runtime_id(self.hwnd as u32, KIND_PALETTE_ITEM, self.index as u64)
    }
    /// This row's rectangle, on screen.
    ///
    /// # What was here, and why it was wrong in the way it warned about
    ///
    /// This answered with the **window's** rectangle for every row, and said
    /// why: a row rectangle would be "a second copy of the geometry
    /// `palette.rs` paints with", and reporting the window was "wrong in a way
    /// a client can see" while a stale row rectangle would be "wrong in a way
    /// it cannot".
    ///
    /// **Both halves were untrue, and the second one mattered.** Measured on
    /// the machine: ninety rows all answered `x=440 y=52 w=560 h=350`. A
    /// client cannot see that -- it takes the centre of the rectangle it was
    /// given, clicks, and **the click succeeds and runs a different command**.
    /// That is precisely the "wrong in a way it cannot see" the old comment
    /// judged to be the worse of the two, and it is what the old answer
    /// produced.
    ///
    /// And the copy it was avoiding already existed: `palette.rs`'s
    /// `WM_LBUTTONDOWN` carried the inverse of the same formula. The choice
    /// was never one copy against two; it was two against three. There is now
    /// **one** -- `palette::row_rect`, which the painter and the hit test also
    /// call, so this cannot drift from what is drawn without all three moving.
    ///
    /// # An empty rectangle means "not on screen"
    ///
    /// Only twelve of the rows are drawn; the rest have no place. They answer
    /// with a zero rectangle rather than an invented coordinate somewhere off
    /// the edge, because an invented one invites a client to scroll to it and
    /// click, which lands on whatever is really there.
    ///
    /// **`IsOffscreen` now answers alongside this**, so a zero rectangle is
    /// no longer the only signal: see the arm in `GetPropertyValue`. A zero
    /// rectangle with `IsOffscreen` false is a provider that could not
    /// answer, which is a different fact from a row that is merely not in
    /// view.
    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        let Some(r) = crate::palette::row_rect(self.index) else {
            return Ok(UiaRect { left: 0.0, top: 0.0, width: 0.0, height: 0.0 });
        };
        // Client to screen, through the palette's own window: the rectangle
        // `palette.rs` works in is its client area, and a client wants pixels
        // on a desktop.
        let mut origin = windows::Win32::Foundation::POINT { x: r.left, y: r.top };
        if unsafe { windows::Win32::Graphics::Gdi::ClientToScreen(self.hwnd(), &mut origin) }
            .as_bool()
        {
            return Ok(UiaRect {
                left: origin.x as f64,
                top: origin.y as f64,
                width: (r.right - r.left) as f64,
                height: (r.bottom - r.top) as f64,
            });
        }
        // The window went between the snapshot and this call. A zero
        // rectangle is the honest answer; the window's would be a place.
        Ok(UiaRect { left: 0.0, top: 0.0, width: 0.0, height: 0.0 })
    }
    fn GetEmbeddedFragmentRoots(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }
    fn SetFocus(&self) -> WResult<()> {
        Ok(())
    }
    fn FragmentRoot(&self) -> WResult<IRawElementProviderFragmentRoot> {
        Ok(PaletteRoot { hwnd: self.hwnd }.into())
    }
}

impl IInvokeProvider_Impl for PaletteItem_Impl {
    fn Invoke(&self) -> WResult<()> {
        if self.row().is_none() {
            return Err(gone());
        }
        // Posted, for the reason `activate_from_uia` is: this call arrives on
        // the automation core's thread and running a command closes a window.
        if crate::palette::invoke_row(self.index) {
            Ok(())
        } else {
            Err(gone())
        }
    }
}

impl ISelectionItemProvider_Impl for PaletteItem_Impl {
    /// **Selecting a palette row runs it**, which is what selecting one with
    /// the keyboard does: there is no state in which a row is chosen and not
    /// yet run.
    fn Select(&self) -> WResult<()> {
        IInvokeProvider_Impl::Invoke(self)
    }
    fn AddToSelection(&self) -> WResult<()> {
        IInvokeProvider_Impl::Invoke(self)
    }
    fn RemoveFromSelection(&self) -> WResult<()> {
        Err(gone())
    }
    fn IsSelected(&self) -> WResult<windows_core::BOOL> {
        Ok((crate::palette::selected_row() == Some(self.index)).into())
    }
    fn SelectionContainer(&self) -> WResult<IRawElementProviderSimple> {
        Ok(PaletteRoot { hwnd: self.hwnd }.into())
    }
}

/// `WM_GETOBJECT` for the palette window. Called from `palette.rs`'s own
/// window procedure, the way `on_get_object` is called from the frame's.
pub fn on_get_object_palette(hwnd: HWND, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
    if lp.0 as i32 != UiaRootObjectId {
        return None;
    }
    let provider: IRawElementProviderSimple = PaletteRoot { hwnd: hwnd.0 as isize }.into();
    // process-wide: there is one command palette for the process, and this
    // line is about that window rather than about any terminal window
    plogf!("[uia] palette WM_GETOBJECT -> root provider");
    Some(unsafe { UiaReturnRawElementProvider(hwnd, wp, lp, &provider) })
}

// ------------------------------------------------------------- the entry

/// `WM_GETOBJECT`, from the frame's window procedure.
///
/// `None` means "not ours, let `DefWindowProcW` have it" -- which covers
/// **`OBJID_CLIENT`, the MSAA request**. Older tools ask with that and get
/// nothing from us by design; the scope note records what that costs. It also
/// covers a message arriving at a handle that is not a registered frame,
/// where the wrong answer would be to invent a root for a window that does
/// not exist.
pub fn on_get_object(frame: HWND, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
    if lp.0 as i32 != UiaRootObjectId {
        return None;
    }
    if !live(frame) {
        return None;
    }
    let provider: IRawElementProviderSimple = WindowRoot {
        frame: frame.0 as isize,
    }
    .into();

    // Said once per window, so the log can distinguish "the tree was never
    // asked for" from "the tree was asked for and came back wrong". Those two
    // look identical from an external dump, and they have different causes.
    wlogf!(frame, "[uia] WM_GETOBJECT -> root provider");

    Some(unsafe { UiaReturnRawElementProvider(frame, wp, lp, &provider) })
}

/// For the log line the verification script reads: how many reads actually
/// reached libghostty, and how many the cache answered.
///
/// **Unused from Rust on purpose.** The criterion counts `[uia] read_text #`
/// lines in the log rather than calling this, because the log is what
/// survives the process ending -- which is the state a crash leaves behind,
/// and the one a concurrency criterion most needs to read.
#[allow(dead_code)]
pub fn read_counts() -> (u64, u64) {
    (
        READS.load(Ordering::Relaxed),
        CACHE_HITS.load(Ordering::Relaxed),
    )
}

// ------------------------------------------------------------------- events
//
// **Why a tree that is always fresh still has to announce itself.**
//
// Every `Navigate` here recomputes from a snapshot, so a client that walks the
// tree again always sees the truth. A screen reader does not walk it again: it
// builds its model once and then waits to be told. Without these calls the
// reader's model goes stale the moment a tab is opened, closed or switched,
// and only comes back by accident when the window is refocused. That was
// written down as the cost of leaving this out, and this is it being paid.
//
// # The one rule these functions impose on their callers
//
// **Never call one while a `tabs` guard is alive.**
//
// Raising an event hands control to UIAutomationCore, which may call straight
// back into a provider in this file to read properties -- and every one of
// those calls takes the `tabs` registry lock. That lock is a plain
// `std::sync::Mutex`, so taking it twice on one thread does not panic, it
// **hangs**.
//
// That failure is worse than the `RefCell` one this port met in the settings
// page. A double borrow aborts and leaves a stack naming the two places; a
// self-deadlock leaves a frozen main thread, and this host has already spent a
// round on exactly that shape -- closing a tab hanging the main thread for
// minutes. Anyone meeting it again will start where they started last time,
// which is not here.
//
// `windows/tools/borrow-across-dispatch.py` knows these three names, so a
// caller that puts one inside a guard is caught by a gate rather than by a
// test machine.

/// Is anyone listening?
///
/// **A speed decision, not a safety one.** When no client is attached, none of
/// the callbacks described above can happen, so the risky window does not
/// exist -- but that is a fact about the common case, and the lock ordering
/// still has to be right on its own for the day a screen reader is running.
/// Every criterion that exercises these events is, by definition, a run where
/// this returns true.
fn anyone_listening() -> bool {
    unsafe { UiaClientsAreListening() }.as_bool()
}

/// Decide whether to announce, **and say so either way**.
///
/// # Why the skip is logged as loudly as the raise
///
/// Without this, "no line in the log" means three different things -- the
/// change never happened, it happened and no client was attached, or it
/// happened and the window had already gone. On a machine where events were
/// not arriving, those are exactly the three that have to be told apart, and
/// silence tells them apart from nothing.
///
/// # And why it reports what `UiaClientsAreListening` said
///
/// **The documented meaning of that call is coarse and I did not want to rely
/// on remembering it.** The question that matters here is whether it counts a
/// client that has *registered* or one whose delivery is actually working --
/// and on the test machine those came apart: a subscription succeeded and not
/// one event was delivered. Rather than settle that from memory, the answer is
/// printed. Whatever the function means, the log says which branch was taken.
fn announce_gate(frame: HWND, what: &str) -> bool {
    let listening = anyone_listening();
    let alive = live(frame);
    if listening && alive {
        return true;
    }
    wlogf!(
        frame,
        "[uia] {} not announced (clients_listening={} window_live={})",
        what,
        listening,
        alive
    );
    false
}

/// Tabs were added, removed or reordered in this window.
///
/// **`ChildrenInvalidated`, not `ChildAdded`/`ChildRemoved`.** The honest thing
/// to say about this tree is "read this subtree again", because that is how it
/// is built. The alternatives would also mean holding on to a departed tab's
/// runtime id so it could be handed over after the tab is gone -- a second
/// record of something we deliberately do not keep.
///
/// **Two elements are announced**, because a tab shows up in two places: as a
/// `TabItem` under the tab list, and as a `Document` under the root. Telling a
/// client about only the first leaves it with a document list that no longer
/// matches the window.
pub fn tabs_changed(frame: HWND) {
    if !announce_gate(frame, "structure change") {
        return;
    }
    let f = frame.0 as isize;
    let win = winid::of(frame);

    let list: IRawElementProviderSimple = TabList { frame: f }.into();
    let mut list_id = runtime_parts(win, KIND_TABLIST, 0);
    let root: IRawElementProviderSimple = WindowRoot { frame: f }.into();
    let mut root_id = runtime_parts(win, KIND_ROOT, 0);

    // **Two lines, one on each side of the call, and that pairing is the
    // point.** Raising an event hands control to UIAutomationCore, which can
    // call straight back into this file and take the `tabs` lock a second time
    // on this thread -- which hangs rather than panicking. A hang leaves no
    // stack and no message; what it leaves is a log that stops. With only one
    // line, a log that stops *before* it says nothing about where. With this
    // pair, a log ending at `raising` and never reaching `raised` names the
    // call, and that is the difference between finding it in a round and
    // finding it in a night.
    wlogf!(frame, "[uia] raising structure change");
    unsafe {
        let _ = UiaRaiseStructureChangedEvent(
            &list,
            StructureChangeType_ChildrenInvalidated,
            list_id.as_mut_ptr(),
            list_id.len() as i32,
        );
        let _ = UiaRaiseStructureChangedEvent(
            &root,
            StructureChangeType_ChildrenInvalidated,
            root_id.as_mut_ptr(),
            root_id.len() as i32,
        );
    }
    wlogf!(frame, "[uia] structure change raised");
}

/// A different tab is now the active one.
///
/// **Not a structure change, and sending one would be saying something that
/// did not happen.** The tree keeps its shape when tabs are switched -- that
/// is why there is a `Document` per tab rather than one for "the current tab"
/// -- and the only thing that differs is which element answers true to
/// `HasKeyboardFocus`. So that is the property that is announced, on both
/// elements that carry it.
///
/// The old value is reported as `false` and the new as `true` rather than
/// tracking what was previously announced. **That is exactly true of the
/// element being named**: it is the one gaining focus. The element losing it
/// is not announced at all, which is what UIA's focus model expects.
pub fn active_tab_changed(frame: HWND, tab: TabId, pane: PaneId) {
    if !announce_gate(frame, "focus change") {
        return;
    }
    let f = frame.0 as isize;
    let item: IRawElementProviderSimple = TabItem { frame: f, tab }.into();
    let doc: IRawElementProviderSimple = Document { frame: f, tab, pane }.into();

    let was = variant_bool(false);
    let now = variant_bool(true);
    wlogf!(frame, "[uia] raising focus change for tab {}", tab.0);
    unsafe {
        // No `VariantClear` for these two: `VT_BOOL` owns nothing. The
        // string-valued one below is the case that does.
        let _ = UiaRaiseAutomationPropertyChangedEvent(
            &item,
            UIA_HasKeyboardFocusPropertyId,
            &was,
            &now,
        );
        let _ = UiaRaiseAutomationPropertyChangedEvent(
            &doc,
            UIA_HasKeyboardFocusPropertyId,
            &was,
            &now,
        );
    }
    wlogf!(frame, "[uia] focus change raised for tab {}", tab.0);
}

/// The selection changed in a surface.
///
/// **`UIA_Text_TextSelectionChangedEventId`, raised on that tab's
/// `Document`.** The document is the element a screen reader has as the
/// terminal, and a selection is a property of it -- the same choice
/// `Ghostty.App.swift` makes when it posts `ghosttySelectionDidChange` against
/// the surface view rather than against the window.
///
/// # The surface's own tab, not the active one
///
/// The core says which surface's selection changed, and it is not always the
/// one in front: a program running in a background tab can set a selection.
/// Announcing against the active tab would name the right window and the wrong
/// terminal, and **the announcement would look completely normal** -- which is
/// the substitution this port has already paid for repeatedly.
///
/// # What is announced, and what a reader will not get
///
/// **The event, not the text.** UIA's model is that an event says something
/// changed and the client then asks for the new state; announcing the
/// selection itself would need a `TextPattern` on the document, and this
/// provider does not implement one. So a listening client is told to look
/// again, and what it finds is the tree this file already publishes.
/// Recorded rather than glossed: somebody expecting the selected text to be
/// spoken will not get it from here, and the reason is a missing pattern, not
/// a missing event.
pub fn selection_changed(frame: HWND, surface: crate::ffi::Surface) {
    if !announce_gate(frame, "selection change") {
        return;
    }
    // **Two lookups, and they are made to agree rather than trusted to.**
    // `tab_of_surface` is this project's answer to "which window and tab", and
    // the pane comes the only other way there is. If the two ever named
    // different windows the announcement would carry a runtime id assembled
    // from two different terminals -- so the disagreement is a refusal with a
    // line, not something to average out.
    let Some((owner, tab)) = crate::tabs::tab_of_surface(surface) else {
        wlogf!(
            frame,
            "[uia] selection change for a surface that is in no tab; not announced"
        );
        return;
    };
    let pane = crate::tabs::pane_hwnd_of_surface(surface).and_then(crate::tabs::pane_of);
    let Some((pane_frame, _, pane_id)) = pane else {
        wlogf!(
            frame,
            "[uia] selection change for a surface with no pane window; not announced"
        );
        return;
    };
    if pane_frame != owner {
        wlogf!(
            frame,
            "[uia] selection change: tab_of_surface says window {:?} and the pane says {:?}; \
             not announced",
            owner,
            pane_frame
        );
        return;
    }

    let doc: IRawElementProviderSimple = Document {
        frame: owner.0 as isize,
        tab,
        pane: pane_id,
    }
    .into();

    // **A line on each side of the call**, for the reason written on
    // `tabs_changed`: raising an event hands control to UIAutomationCore,
    // which can call straight back into this file on this thread and take the
    // `tabs` lock a second time -- which hangs rather than panicking, and a
    // hang leaves a log that stops rather than a stack. A pair of lines names
    // the call that stopped it.
    wlogf!(owner, "[uia] raising selection change for tab {}", tab.0);
    unsafe {
        let _ = UiaRaiseAutomationEvent(&doc, UIA_Text_TextSelectionChangedEventId);
    }
    wlogf!(owner, "[uia] selection change raised for tab {}", tab.0);
}

/// A tab's name changed -- the user renamed it, or the program in it did.
///
/// **Outside the task that asked for the other two, and here for a reason
/// that is the same one.** A client told the structure is fresh but not told
/// the name is different reads out the name it recorded, which is the one the
/// user just replaced. "The tree is new and the name is old" is the same
/// defect wearing a different hat.
///
/// **The `BSTR` is freed here, and that is a real decision rather than
/// housekeeping.** `VARIANT` has no `Drop` in this crate, and a by-value
/// `VARIANT` argument is `[in]` by COM convention -- the callee reads it, the
/// caller still owns it. So the string has to be released on this side, once
/// the call has returned. Getting this wrong is a leak of one string per
/// rename, which is small until something renames on a timer.
pub fn tab_renamed(frame: HWND, tab: TabId, name: &str) {
    if !announce_gate(frame, "name change") {
        return;
    }
    let f = frame.0 as isize;
    let item: IRawElementProviderSimple = TabItem { frame: f, tab }.into();

    let old = variant_empty();
    let mut new = variant_bstr(name);
    wlogf!(frame, "[uia] raising name change for tab {}", tab.0);
    unsafe {
        let _ = UiaRaiseAutomationPropertyChangedEvent(&item, UIA_NamePropertyId, &old, &new);
        // See the note above. `VT_EMPTY` needs no clearing; this one does.
        let _ = VariantClear(&mut new);
    }
    wlogf!(frame, "[uia] name change raised for tab {}", tab.0);
}

// ------------------------------------------------------- the text pattern
//
// **What a client could and could not ask before this.** `document` offered
// `ValuePattern`, so the whole visible screen came out as one string -- and
// nothing else. "Which line did that output land on", "what is selected
// right now" and "where on screen is this text" had no answer, so a test
// that wanted any of them fell back to comparing screenshots.
//
// # Where a range's geometry comes from, and the sentinel that is not a place
//
// **Nothing here computes a rectangle from a row height of its own.** Two
// numbers, both the core's:
//
//   * `ghostty_text_s.tl_px_x` / `tl_px_y` -- the top-left of the range, in
//     the surface's own pixels, filled in by `embedded.zig` from the core's
//     viewport;
//   * `ime_cell_size()` -- the cell size the core reported through
//     `GHOSTTY_ACTION_CELL_SIZE`, which is the same metric the renderer draws
//     with.
//
// ⚠️ **`tl_px_* == -1` is not a position.** `embedded.zig` substitutes
// `-1, -1` when `text.viewport` is null, which is what happens when the range
// is scrolled out of the viewport. It is a value-shaped absence, and anything
// that adds a cell size to it produces a rectangle pointing confidently at a
// place the text is not. That is the same defect task 328 found one element
// over -- ninety palette rows all reporting the list box's rectangle, so a
// client's click **succeeded** on the wrong command. A wrong rectangle is
// worse than no rectangle, because it is actionable.
//
// # What is refused, and why refusing is the answer
//
// Most of `ITextRangeProvider` is navigation -- move by word, expand to a
// line, select this range -- and libghostty publishes no entry point for any
// of it: there is no point-to-cell mapping, and no way to *set* a selection.
// Every one of those returns `UIA_E_NOTSUPPORTED` **by name**. An
// implementation that quietly returned the unchanged range from `Move` would
// report success while nothing moved, and a client would read that as "there
// is nothing after this line".

/// Which piece of the terminal a range stands for.
///
/// **Two cases, and no third that this host can honestly offer.** A range
/// is either the visible screen or whatever is selected right now; an
/// arbitrary sub-range would need a way to name cell coordinates that came
/// from somewhere other than the core, and there is no such thing here.
#[derive(Clone, Copy, PartialEq, Eq)]
enum RangeOf {
    Viewport,
    CurrentSelection,
}

#[implement(ITextRangeProvider)]
struct TermRange {
    frame: isize,
    tab: TabId,
    pane: PaneId,
    what: RangeOf,
}

impl TermRange {
    fn hwnd(&self) -> HWND {
        HWND(self.frame as *mut core::ffi::c_void)
    }

    /// The core's answer for this range: its text and its top-left pixel.
    ///
    /// **Rule 1 and rule 2 of this file, unchanged**: the surface is resolved
    /// with no guard alive, the bytes are copied out before `free_text`, and
    /// a refusal from the core is reported as a refusal rather than as empty
    /// text.
    fn read(&self) -> Option<(String, f64, f64)> {
        let surface = tabs::surface_of_tab_pane(self.hwnd(), self.tab, self.pane);
        if surface.is_null() {
            return None;
        }
        let mut out = Text::default();
        let ok = unsafe {
            match self.what {
                RangeOf::Viewport => {
                    (crate::api().surface_read_text)(surface, Selection::viewport(), &mut out)
                }
                RangeOf::CurrentSelection => {
                    (crate::api().surface_read_selection)(surface, &mut out)
                }
            }
        };
        if !ok {
            wlogf!(
                self.hwnd(),
                "[uia] text range read refused for pane={} ({})",
                self.pane,
                match self.what {
                    RangeOf::Viewport => "viewport",
                    RangeOf::CurrentSelection => "selection",
                }
            );
            return None;
        }
        let text = if out.text.is_null() {
            String::new()
        } else {
            let bytes =
                unsafe { std::slice::from_raw_parts(out.text as *const u8, out.text_len) };
            String::from_utf8_lossy(bytes).into_owned()
        };
        let (x, y) = (out.tl_px_x, out.tl_px_y);
        unsafe { (crate::api().surface_free_text)(surface, &mut out) };
        Some((text, x, y))
    }
}

impl ITextRangeProvider_Impl for TermRange_Impl {
    fn Clone(&self) -> WResult<ITextRangeProvider> {
        let r: ITextRangeProvider = TermRange {
            frame: self.frame,
            tab: self.tab,
            pane: self.pane,
            what: self.what,
        }
        .into();
        Ok(r)
    }

    /// **Two ranges are the same when they stand for the same thing.**
    /// There are two things a range can stand for here, so this is exact
    /// rather than an approximation of one.
    fn Compare(&self, range: windows_core::Ref<ITextRangeProvider>) -> WResult<BOOL> {
        // The other side is somebody else's object as far as this process is
        // concerned; the only thing that can be asked of it through the
        // interface is its text. Comparing that is not identity, so this
        // answers only for ranges it can recognise -- and says so rather than
        // guessing for the rest.
        let Some(other) = range.as_ref() else {
            return Ok(BOOL(0));
        };
        let mine = self.GetText(-1)?;
        let theirs = unsafe { other.GetText(-1) }?;
        Ok(BOOL((mine == theirs) as i32))
    }

    /// **Refused, not approximated.** Endpoints are positions in a buffer,
    /// and this host has no way to name a position: libghostty publishes
    /// no cell coordinate for a range it did not itself produce. Answering
    /// `0` -- "the endpoints are equal" -- would make every range look like
    /// every other one.
    fn CompareEndpoints(
        &self,
        _endpoint: TextPatternRangeEndpoint,
        _targetrange: windows_core::Ref<ITextRangeProvider>,
        _targetendpoint: TextPatternRangeEndpoint,
    ) -> WResult<i32> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    /// **Refused.** Expanding to a word or a line needs the buffer walked,
    /// and the only text this host can ask for is the whole viewport or the
    /// current selection. Silently leaving the range as it is would report
    /// success for a move that did not happen.
    fn ExpandToEnclosingUnit(&self, _unit: TextUnit) -> WResult<()> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn FindAttribute(
        &self,
        _attributeid: UIA_TEXTATTRIBUTE_ID,
        _val: &VARIANT,
        _backward: BOOL,
    ) -> WResult<ITextRangeProvider> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    /// **Refused rather than answered with a range that cannot be used.**
    /// A search could be run over the text this host *can* read, but the
    /// result would have to be handed back as a range -- and a range this
    /// host cannot express is one whose `GetBoundingRectangles` would have to
    /// invent a position. Task 328's ninety identical rectangles are what
    /// that looks like from the client's side.
    fn FindText(&self, _text: &BSTR, _backward: BOOL, _ignorecase: BOOL) -> WResult<ITextRangeProvider> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn GetAttributeValue(&self, _attributeid: UIA_TEXTATTRIBUTE_ID) -> WResult<VARIANT> {
        // The documented way to say "this provider has no opinion on that
        // attribute"; a client then falls back to its own default rather than
        // to a value we made up.
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    /// The range's rectangle, **from the core's own two numbers**.
    ///
    /// ⚠️ `tl_px_* == -1` means the range is not in the viewport (see this
    /// section's header). An empty array is the correct UIA answer for that
    /// -- *and it is logged*, because "off screen" and "we could not tell"
    /// would otherwise be the same empty array.
    fn GetBoundingRectangles(&self) -> WResult<*mut SAFEARRAY> {
        let Some((text, x, y)) = self.read() else {
            return Err(gone());
        };
        if x < 0.0 || y < 0.0 {
            wlogf!(
                self.hwnd(),
                "[uia] range has no rectangle: the core reports tl_px=({},{}), which is its \
                 way of saying the range is not in the viewport -- not a position",
                x,
                y
            );
            return empty_f64_array();
        }
        let (cw, ch) = crate::ime_cell_size();
        let rows = text.lines().count().max(1) as f64;
        let cols = text.lines().map(|l| l.chars().count()).max().unwrap_or(0).max(1) as f64;
        let mut origin = POINT { x: 0, y: 0 };
        // This range's own pane. The coordinates below are the core's, in
        // that pane's client space, so the window they are made absolute
        // against has to be that same pane -- the focused one would offset
        // every rectangle by the distance between the two halves.
        let Some(pane) = pane_hwnd(self.hwnd(), self.tab, self.pane) else {
            return Err(gone());
        };
        if unsafe { ClientToScreen(pane, &mut origin) }.as_bool() {
            f64_array(&[
                origin.x as f64 + x,
                origin.y as f64 + y,
                cols * cw as f64,
                rows * ch as f64,
            ])
        } else {
            empty_f64_array()
        }
    }

    fn GetEnclosingElement(&self) -> WResult<IRawElementProviderSimple> {
        let d: IRawElementProviderSimple = Document {
            frame: self.frame,
            tab: self.tab,
            pane: self.pane,
        }
        .into();
        Ok(d)
    }

    fn GetText(&self, maxlength: i32) -> WResult<BSTR> {
        let Some((text, _, _)) = self.read() else {
            return Err(gone());
        };
        if maxlength >= 0 && (maxlength as usize) < text.chars().count() {
            let cut: String = text.chars().take(maxlength as usize).collect();
            return Ok(BSTR::from(cut.as_str()));
        }
        Ok(BSTR::from(text.as_str()))
    }

    /// **Refused, and this is the one a client is most likely to try.**
    /// Returning `0` -- "moved nothing" -- is the tempting answer and it is a
    /// lie of the kind this port keeps finding: a client reads it as "there
    /// is nothing after this", which is a fact about the terminal that was
    /// never established.
    fn Move(&self, _unit: TextUnit, _count: i32) -> WResult<i32> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn MoveEndpointByUnit(
        &self,
        _endpoint: TextPatternRangeEndpoint,
        _unit: TextUnit,
        _count: i32,
    ) -> WResult<i32> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn MoveEndpointByRange(
        &self,
        _endpoint: TextPatternRangeEndpoint,
        _targetrange: windows_core::Ref<ITextRangeProvider>,
        _targetendpoint: TextPatternRangeEndpoint,
    ) -> WResult<()> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    /// **Refused for the same reason `SetValue` is.** libghostty publishes no
    /// entry point that sets a selection, and one written here would be a
    /// second owner of a fact the core keeps.
    fn Select(&self) -> WResult<()> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn AddToSelection(&self) -> WResult<()> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn RemoveFromSelection(&self) -> WResult<()> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn ScrollIntoView(&self, _aligntotop: BOOL) -> WResult<()> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn GetChildren(&self) -> WResult<*mut SAFEARRAY> {
        empty_i4_array()
    }
}

impl ITextProvider_Impl for Document_Impl {
    /// What is selected right now.
    ///
    /// **An empty array here means "nothing is selected", and this asks the
    /// core before saying it.** `ghostty_surface_has_selection` is the reason
    /// the empty answer is honest: without it, "there is no selection" and
    /// "the read failed" would both come back as an empty array, and a client
    /// cannot tell those apart -- it would report a terminal with nothing
    /// selected either way. A failure is an error here, not an empty array.
    fn GetSelection(&self) -> WResult<*mut SAFEARRAY> {
        let frame = self.hwnd();
        if !live(frame) {
            return Err(gone());
        }
        let surface = tabs::surface_of_tab_pane(frame, self.tab, self.pane);
        if surface.is_null() {
            return Err(gone());
        }
        if !unsafe { (crate::api().surface_has_selection)(surface) } {
            return empty_i4_array();
        }
        let r: ITextRangeProvider = TermRange {
            frame: self.frame,
            tab: self.tab,
            pane: self.pane,
            what: RangeOf::CurrentSelection,
        }
        .into();
        range_array(&[r])
    }

    /// The visible screen, which is the one range this host can name.
    fn GetVisibleRanges(&self) -> WResult<*mut SAFEARRAY> {
        let r = self.DocumentRange()?;
        range_array(&[r])
    }

    /// **Refused.** A child element of the terminal document would have to be
    /// a piece of its text, and this provider publishes none -- so there is
    /// no child whose range could be answered.
    fn RangeFromChild(
        &self,
        _childelement: windows_core::Ref<IRawElementProviderSimple>,
    ) -> WResult<ITextRangeProvider> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    /// **Refused, and this is the refusal that matters most.**
    ///
    /// Turning a screen point into a text position needs a mapping from
    /// pixels to cells, and libghostty publishes none: `ghostty_text_s`
    /// carries a top-left *out* for a range the core chose, and there is no
    /// entry point going the other way. The arithmetic looks available --
    /// there is a cell size right there -- and that is the trap: dividing a
    /// point by the cell size ignores scrollback position, wide characters
    /// and the surface's own origin, and produces a range that is wrong
    /// **without looking wrong**. Task 328 is what that costs: ninety palette
    /// rows reporting one rectangle, and a client whose click *succeeded* on
    /// the wrong command.
    fn RangeFromPoint(&self, _point: &UiaPoint) -> WResult<ITextRangeProvider> {
        Err(hr(UIA_E_NOTSUPPORTED))
    }

    fn DocumentRange(&self) -> WResult<ITextRangeProvider> {
        let r: ITextRangeProvider = TermRange {
            frame: self.frame,
            tab: self.tab,
            pane: self.pane,
            what: RangeOf::Viewport,
        }
        .into();
        Ok(r)
    }

    /// One selection at a time, which is what the core keeps.
    fn SupportedTextSelection(&self) -> WResult<SupportedTextSelection> {
        Ok(SupportedTextSelection_Single)
    }
}
