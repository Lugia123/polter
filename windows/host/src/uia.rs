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
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::GetWindowRect;

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

#[implement(IRawElementProviderSimple, IRawElementProviderFragment)]
struct TabItem {
    frame: isize,
    tab: TabId,
}

#[implement(
    IRawElementProviderSimple,
    IRawElementProviderFragment,
    IValueProvider
)]
struct Document {
    frame: isize,
    tab: TabId,
    pane: PaneId,
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

/// The order of the root's children, which several `Navigate` arms need to
/// agree on: the tab list first, then one document per tab in tab order.
///
/// **Computed from a fresh snapshot every time rather than stored.** A stored
/// order is a second list of tabs, which is the thing `strip.rs` rule 1
/// forbids one level up, and it goes stale in exactly the way that makes a
/// tree look right and navigate wrong.
fn root_children(frame: HWND) -> Vec<IRawElementProviderFragment> {
    let (tabs_now, _) = tabs::tab_infos(frame);
    let f = frame.0 as isize;
    let mut out: Vec<IRawElementProviderFragment> = Vec::with_capacity(tabs_now.len() + 1);
    out.push(TabList { frame: f }.into());
    for t in tabs_now.iter() {
        out.push(
            Document {
                frame: f,
                tab: t.id,
                pane: t.pane,
            }
            .into(),
        );
    }
    out
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
        // Below the strip: whichever tab is active owns the area.
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
            // The tab list is the root's first child, so it has no previous
            // sibling; its next is the first document.
            NavigateDirection_NextSibling => step(root_children(frame), 0, direction),
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

// ------------------------------------------------------------------ TabItem

impl IRawElementProviderSimple_Impl for TabItem_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> {
        Ok(ProviderOptions_ServerSideProvider)
    }
    fn GetPatternProvider(&self, _id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        // `SelectionItemPattern` belongs here and is not implemented; see the
        // scope note in `docs/windows/uia.md`. A client can read which tab is
        // active from `HasKeyboardFocus` below, but cannot *activate* one.
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
        // **`TextPattern` is what a screen reader really wants here and it is
        // not implemented.** See `docs/windows/uia.md`: the consequence is
        // that a reader gets the visible screen as one value and cannot
        // navigate it by line, word or caret.
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
            UIA_NamePropertyId => variant_bstr(&format!("Terminal: {}", tabs_now[idx].title)),
            UIA_AutomationIdPropertyId => variant_bstr(&format!("terminal-{}", self.tab.0)),
            UIA_HasKeyboardFocusPropertyId => variant_bool(idx == active),
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
                let (tabs_now, _) = tabs::tab_infos(frame);
                let Some(t) = tabs_now.iter().position(|t| t.id == self.tab) else {
                    return Err(gone());
                };
                // The documents follow the tab list, so a tab at index `t` is
                // the root's child `t + 1`.
                step(root_children(frame), t + 1, direction)
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
        runtime_id(winid::of(self.hwnd()), KIND_DOCUMENT, self.tab.0)
    }
    fn BoundingRectangle(&self) -> WResult<UiaRect> {
        let frame = self.hwnd();
        let (tabs_now, _) = tabs::tab_infos(frame);
        match tabs_now.iter().find(|t| t.id == self.tab) {
            Some(t) if t.pane_hwnd != 0 => {
                Ok(window_rect(HWND(t.pane_hwnd as *mut core::ffi::c_void)))
            }
            _ => Ok(UiaRect { left: 0.0, top: 0.0, width: 0.0, height: 0.0 }),
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
    if !anyone_listening() || !live(frame) {
        return;
    }
    let f = frame.0 as isize;
    let win = winid::of(frame);

    let list: IRawElementProviderSimple = TabList { frame: f }.into();
    let mut list_id = runtime_parts(win, KIND_TABLIST, 0);
    let root: IRawElementProviderSimple = WindowRoot { frame: f }.into();
    let mut root_id = runtime_parts(win, KIND_ROOT, 0);

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
    wlogf!(frame, "[uia] structure changed announced");
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
    if !anyone_listening() || !live(frame) {
        return;
    }
    let f = frame.0 as isize;
    let item: IRawElementProviderSimple = TabItem { frame: f, tab }.into();
    let doc: IRawElementProviderSimple = Document { frame: f, tab, pane }.into();

    let was = variant_bool(false);
    let now = variant_bool(true);
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
    wlogf!(frame, "[uia] focus change announced for tab {}", tab.0);
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
    if !anyone_listening() || !live(frame) {
        return;
    }
    let f = frame.0 as isize;
    let item: IRawElementProviderSimple = TabItem { frame: f, tab }.into();

    let old = variant_empty();
    let mut new = variant_bstr(name);
    unsafe {
        let _ = UiaRaiseAutomationPropertyChangedEvent(&item, UIA_NamePropertyId, &old, &new);
        // See the note above. `VT_EMPTY` needs no clearing; this one does.
        let _ = VariantClear(&mut new);
    }
    wlogf!(frame, "[uia] name change announced for tab {}", tab.0);
}
