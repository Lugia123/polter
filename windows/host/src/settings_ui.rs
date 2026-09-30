//! The config-error list, the keybind page and the about box.
//!
//! **Three windows in one file because they are one shape**: a modeless popup
//! over the frame and nothing that the terminal underneath needs to know
//! about. Splitting them would repeat the class registration, the font and
//! the paint path three more times -- `hud.rs` already makes that argument
//! for its two.
//!
//! The plugin page that lived here too is the settings window's Plugins
//! section now (`plugins_ui.rs`, settings.md §9 phase 2). These three move
//! to its General section when that is redesigned; until then they stay.
//!
//! **What the host is allowed to decide here: nothing.**
//!
//! | thing on screen | where it comes from |
//! | --- | --- |
//! | the config errors | `ghostty_config_diagnostics_count` / `_get_diagnostic` |
//! | the keybinds | `ghostty_config_keybind` |
//! | version and build | `ghostty_info()` |

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::plogf;

const WM_ERRORS_SHOW: u32 = WM_APP + 9;
/// Show the about box, asked for from somewhere that is not this window --
/// the main menu's «About Polter». Posted rather than called so the window
/// that owns the about box is the one that shows it.
const WM_ABOUT_SHOW: u32 = WM_APP + 10;
/// The keybind page. **`WM_APP + 11`**, taken because 8, 9 and 10 are spoken
/// for above -- and `menu.rs` records that `WM_APP + 9` is already used twice
/// on different windows, which is safe only because these messages are posted
/// to one window each and never broadcast.
const WM_KEYBINDS_SHOW: u32 = WM_APP + 11;

const PAD: i32 = 12;

// ------------------------------------------------------------------ colour
//
// **The palette is not here any more.** It was six literals in this file, and
// three other windows had their own copies of the same idea; the day one of
// them changed, the app was half one colour and half another. `theme.rs` is
// the single source now, and it is also what answers "is high contrast on",
// which every drawing path below has to ask before it paints a control
// itself.
//
// The names below are this page's vocabulary for that palette, not a second
// copy of it: each one is a call.

use crate::theme;


static HWND_ERRORS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_KEYBINDS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_ABOUT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// The pages' font.
///
/// **Out of `ST` on purpose, and this was the fix for a crash rather than a
/// tidy-up.** It is read on the drawing path, and the drawing path is
/// entered synchronously from inside our own code: when the plugin page
/// lived here, `SetWindowTextW` on a custom-drawn `BUTTON` sent
/// `WM_NOTIFY`/`NM_CUSTOMDRAW` to this window's procedure before it
/// returned, met a `borrow_mut` held across the call, and the page aborted
/// the instant it was opened with any plugin installed.
///
/// Narrowing the borrow would have fixed that one call. Taking the value out
/// of the cell means **the drawing path cannot reach the mutable state at
/// all** -- there is no borrow to conflict with, so there is nothing to keep
/// right in a future edit. An `AtomicPtr` rather than a `Cell` for the same
/// reason the three window handles above are: a value read from a paint that
/// might one day arrive on another thread should not silently be a different
/// value there, and a null `HFONT` is *legal* (it means "the system font"),
/// so that mistake would not announce itself.
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

fn font() -> HFONT {
    HFONT(FONT.load(Ordering::Acquire))
}


#[derive(Default)]
struct State {
    errors: Vec<String>,
    /// The keybind page's rows, read once each time it is opened rather than
    /// held: the config can be reloaded while the page is closed, and a list
    /// kept from last time would be quietly stale.
    keybinds: Vec<crate::keybinds::Row>,
    /// First visible row. Kept in rows, not pixels, so it survives a DPI
    /// change and a resize.
    keybind_top: usize,
}

thread_local! {
    static ST: RefCell<State> = RefCell::new(State::default());
}


fn dpi_scale(h: HWND) -> i32 {
    unsafe { GetDpiForWindow(h) }.max(96) as i32
}

// ------------------------------------------------------------------ setup

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        for (proc_fn, class) in [
            (
                errors_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT,
                w!("PolterConfigErrors"),
            ),
            (about_proc, w!("PolterAbout")),
            (keybinds_proc, w!("PolterKeybinds")),
        ] {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                style: CS_DROPSHADOW,
                lpfnWndProc: Some(proc_fn),
                hInstance: hinst,
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hbrBackground: HBRUSH(std::ptr::null_mut()),
                lpszClassName: class,
                ..Default::default()
            };
            if RegisterClassExW(&wc) == 0 {
                // process-wide: registering the window class, once per process
                plogf!("[set] RegisterClassExW failed");
                return;
            }
        }

        // **No `WS_EX_TOPMOST`.** These three windows had it, which is not
        // "above Polter" -- it is above *everything*, including other programs
        // and the system's own surfaces. A person switched to Notepad and this
        // page was still in front of it. What was wanted all along is an
        // **owned** window: always above the terminal it belongs to,
        // minimising and restoring with it, and behind whatever the person
        // switches to. The owner is set at show time; see `own_and_place`.
        let make = |class: PCWSTR, w: i32, h: i32| {
            CreateWindowExW(
                WS_EX_TOOLWINDOW,
                class,
                w!("Polter"),
                WS_POPUP | WS_CLIPCHILDREN,
                0,
                0,
                w,
                h,
                None,
                None,
                Some(hinst),
                None,
            )
        };

        let he = match make(w!("PolterConfigErrors"), 560, 320) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the errors window: one per process
                plogf!("[set] errors CreateWindowExW failed: {e:?}");
                return;
            }
        };

        let sc = dpi_scale(he);
        let font = CreateFontW(
            -(14 * sc / 96),
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            w!("Segoe UI"),
        );

        FONT.store(font.0, Ordering::Release);
        let ha = match make(w!("PolterAbout"), 420, 220) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the about window: one per process
                plogf!("[set] about CreateWindowExW failed: {e:?}");
                return;
            }
        };
        let hk = match make(w!("PolterKeybinds"), 760, 560) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the keybind page, one per process like the rest
                plogf!("[set] keybinds CreateWindowExW failed: {e:?}");
                return;
            }
        };
        HWND_KEYBINDS.store(hk.0, Ordering::Release);
        HWND_ERRORS.store(he.0, Ordering::Release);
        HWND_ABOUT.store(ha.0, Ordering::Release);
        // process-wide: the three windows are up; no terminal window is involved
        plogf!("[set] ready");
    }
}


/// Show the about box. **Safe from any thread.**
///
/// **Here rather than a second dialog in `menu.rs`.** A host with two about
/// boxes has two version strings to keep in step, and they disagree exactly
/// when it matters -- in a bug report. Same reason `about_lines` asks the core
/// instead of composing the version itself.
pub fn request_about() {
    let h = HWND_ABOUT.load(Ordering::Acquire);
    if h.is_null() {
        // process-wide: the about window does not exist yet, so no window could be meant
        plogf!("[set] about was asked for before its window existed");
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_ABOUT_SHOW, WPARAM(0), LPARAM(0)) };
}

/// Show the keybind page. **Safe from any thread.**
///
/// **The listing is read here, not cached**: `config_keybind` walks the
/// config the process is holding right now, and a page that showed what was
/// bound at startup would be wrong for exactly the person who just changed a
/// binding and came to check.
pub fn request_keybinds() {
    let h = HWND_KEYBINDS.load(Ordering::Acquire);
    if h.is_null() {
        // process-wide: the keybind window does not exist yet
        plogf!("[set] keybinds was asked for before its window existed");
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_KEYBINDS_SHOW, WPARAM(0), LPARAM(0)) };
}

/// Show the config errors, if the core reported any. **Safe from any thread.**
pub fn request_errors() {
    let h = HWND_ERRORS.load(Ordering::Acquire);
    if h.is_null() {
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_ERRORS_SHOW, WPARAM(0), LPARAM(0)) };
}

// ------------------------------------------------------------- parameters



// ------------------------------------------------------- drawing controls
//
// **Why the buttons are custom drawn and the fields are not.** A themed
// `EDIT`, `STATIC` or list box asks its parent what colours to use, through
// `WM_CTLCOLOR*`, and honours the answer -- so those need no drawing code at
// all, only an answer. A themed `BUTTON` asks nobody: it is painted by the
// visual style, and the only ways in are to owner-draw it or to answer its
// custom-draw notification. Custom draw is the one that keeps the control's
// own behaviour -- a check box stays an auto check box, `BM_GETCHECK` still
// answers, and the hot state arrives as a flag rather than as mouse tracking
// this file would have to write.
//
// Every path here begins by asking `theme::custom_drawing()`. Under high
// contrast none of them run and the system paints its own controls.






/// Version, commit and build mode -- **all three straight out of the core**.
///
/// The host composing its own version string would be a second one to keep in
/// step with the first, and the two would disagree exactly when it mattered:
/// in a bug report.
fn about_lines() -> Vec<String> {
    let api = crate::api();
    let info = unsafe { (api.info)() };
    let version = if info.version.is_null() || info.version_len == 0 {
        "unknown".to_string()
    } else {
        let bytes =
            unsafe { std::slice::from_raw_parts(info.version as *const u8, info.version_len) };
        String::from_utf8_lossy(bytes).into_owned()
    };
    let mode = match info.build_mode {
        0 => "Debug",
        1 => "ReleaseSafe",
        2 => "ReleaseFast",
        3 => "ReleaseSmall",
        other => return vec![format!("Polter {version}"), format!("build mode {other} (unknown)")],
    };
    // **The same string the `[build]` log line carries**, from the same
    // function -- not a second hash computed here. A bug report that quotes
    // the about box and a log that quotes the build line have to be talking
    // about the same binary, and the only way to be sure of that is for one
    // of them not to exist twice.
    let build = std::env::current_exe()
        .map(|p| crate::binary_identity(&p))
        .unwrap_or_else(|_| "build identity unavailable".to_string());
    // **The host's own commit, next to the core's.**
    //
    // The two halves of this program can be built from different trees, and
    // when they are, the symptom is that a feature behaves as though nobody
    // ever wrote it -- the core declines an action it does not know, and a
    // declined action is indistinguishable from an absent one. The log says
    // so at startup (`log_pairing`), but **a log is read afterwards by
    // somebody investigating, and this box is read during, by somebody who is
    // confused right now**. That is the moment the two lines need to be
    // side by side.
    //
    // It is deliberately the raw stamp rather than a verdict: the verdict
    // needs both halves parsed and belongs where it can say what to do about
    // it. Here it is enough that the two strings are visible together, so a
    // person can see they differ without knowing anything about how either
    // was produced.
    let host = match crate::HOST_COMMIT {
        "" => "host build: commit unknown (not built from a git checkout)".to_string(),
        c => format!(
            "host build: {c}{}",
            if crate::HOST_DIRTY == "1" { " (uncommitted changes)" } else { "" }
        ),
    };
    vec![
        "Polter".to_string(),
        format!("libghostty {version}"),
        host,
        format!("{mode} build"),
        build,
        String::new(),
        tr("MIT licensed. A fork of Ghostty."),
    ]
}

fn show_about() {
    let h = HWND(HWND_ABOUT.load(Ordering::Acquire));
    if h.0.is_null() {
        return;
    }
    unsafe {
        let frame = crate::tabs::overlay_frame();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let sc = dpi_scale(h);
        let (w, hh) = (420 * sc / 96, 220 * sc / 96);
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + ((fr.bottom - fr.top) - hh) / 2;
        own_and_place(h, x, y, w, hh);
        let _ = InvalidateRect(Some(h), None, true);
    }
    // process-wide: the about window is one per process
    plogf!("[set] about shown");
}

unsafe extern "system" fn about_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_ABOUT_SHOW => {
                show_about();
                LRESULT(0)
            }
            WM_KEYDOWN if VIRTUAL_KEY(wp.0 as u16) == VK_ESCAPE => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            // **A theme change is a repaint, because the colours are the
            // system's now.** Without this the page keeps the old ones until
            // something else invalidates it -- and "it did not follow the
            // theme" is exactly what a second, private copy of the colours
            // would look like, which would make the two indistinguishable
            // from outside.
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                theme::repaint_all(win);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(win, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let sc = dpi_scale(win);
                    let s = |v: i32| v * sc / 96;
                    let b = CreateSolidBrush(COLORREF(theme::panel()));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                    SetBkMode(hdc, TRANSPARENT);
                    ST.with(|_c| {
                        // The borrow that used to be here read one field, `font`, and
                        // that field is no longer in the cell: this paint touches no
                        // shared state at all.
                        let old = SelectObject(hdc, font().into());
                        let mut y = s(PAD * 2);
                        for (i, line) in about_lines().iter().enumerate() {
                            let mut r = RECT {
                                left: s(PAD * 2),
                                top: y,
                                right: rc.right - s(PAD),
                                bottom: y + s(24),
                            };
                            draw_text(
                                hdc,
                                line,
                                &mut r,
                                DT_LEFT | DT_SINGLELINE,
                                if i == 0 { theme::text() } else { theme::dim() },
                            );
                            y += s(24);
                        }
                        let mut fr = RECT {
                            left: s(PAD * 2),
                            top: rc.bottom - s(30),
                            right: rc.right - s(PAD),
                            bottom: rc.bottom,
                        };
                        draw_text(
                            hdc,
                            &tr("Esc or click to dismiss"),
                            &mut fr,
                            DT_LEFT | DT_SINGLELINE,
                            theme::dim(),
                        );
                        SelectObject(hdc, old);
                    });
                    let _ = EndPaint(win, &ps);
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}


// ------------------------------------------------------------ show / hide


/// Give `win` an owner, put it over that owner, and show it.
///
/// **Owned, not topmost.** An owned window is always above its owner, hides
/// when the owner is minimised and comes back with it, and never covers
/// another program. That is the behaviour these three windows were reaching
/// for with `WS_EX_TOPMOST`, which buys the first half by taking the whole
/// screen hostage.
///
/// **The owner is set here rather than at creation**, and that is not
/// bookkeeping: these windows are made once, at startup, and there is going
/// to be more than one terminal window. Which window this page belongs to is
/// a fact about *this* opening -- the one whose keystroke asked for it -- so
/// it is answered every time it opens. `GWLP_HWNDPARENT` on an already-made
/// window is how Win32 spells "re-own".
///
/// **`overlay_frame()` is the answer, and it is a named gap rather than a
/// value.** This page belongs to the window the person is looking at; this
/// host cannot yet say which one that is, so `overlay_frame` answers with the
/// first window and says so in one place, for all fifteen callers that want
/// it. B1-f replaces its body, and this call needs no edit when it does.
///
/// This line was written as `frame_hwnd()` so that the ownership fix could
/// land without waiting for the split, on the understanding that whichever
/// batch landed second would change the one word. The split landed second.
fn own_and_place(win: HWND, x: i32, y: i32, w: i32, h: i32) {
    let owner = crate::tabs::overlay_frame();
    unsafe {
        if !owner.0.is_null() {
            SetWindowLongPtrW(win, GWLP_HWNDPARENT, owner.0 as isize);
        }
        // `HWND_TOP`, not `HWND_TOPMOST`: at the front of its own owner's
        // stack. The z-order this window needs is the one being owned gives it.
        let _ = SetWindowPos(win, Some(HWND_TOP), x, y, w, h, SWP_SHOWWINDOW);
    }
}


// ------------------------------------------------------------ window proc


fn draw_text(hdc: HDC, s: &str, r: &mut RECT, flags: DRAW_TEXT_FORMAT, colour: u32) {
    unsafe {
        SetTextColor(hdc, COLORREF(colour));
        let mut wide: Vec<u16> = s.encode_utf16().collect();
        if wide.is_empty() {
            return;
        }
        DrawTextW(hdc, &mut wide, r, flags);
    }
}


// --------------------------------------------------------- config errors

/// Ask the core what is wrong with the config. Empty means nothing is.
fn read_diagnostics() -> Vec<String> {
    let cfg = crate::config_handle();
    if cfg.is_null() {
        return Vec::new();
    }
    let api = crate::api();
    let n = unsafe { (api.config_diagnostics_count)(cfg) };
    let mut out = Vec::new();
    for i in 0..n {
        let d = unsafe { (api.config_get_diagnostic)(cfg, i) };
        if d.message.is_null() {
            continue;
        }
        let s = unsafe { std::ffi::CStr::from_ptr(d.message) }
            .to_string_lossy()
            .into_owned();
        if !s.is_empty() {
            out.push(s);
        }
    }
    out
}

/// Rows visible at once. The page is sized for this; scrolling covers the
/// rest.
const KB_VISIBLE: usize = 18;
/// How far down the first row starts, and how tall a row is, before scaling.
///
/// ⚠️ **Named so that there is something to say "written once" about.**
/// `one-place-decides-where-a-row-is.py` is the floor for this page as well
/// as for the palette, and a floor that had to recognise `56` and `24` as
/// literals would go quiet the day somebody wrote `28 * 2`.
const KB_HEADER: i32 = 56;
const KB_ROW_H: i32 = 24;

/// What a UI Automation client is shown for one row.
#[derive(Clone, Default)]
pub struct KbSnapshotRow {
    pub action: String,
    pub name: String,
    pub keys: String,
    pub note: String,
}

/// The keybind page, as something another thread may read.
///
/// **The provider does not run on the window's thread.** `ST` is a
/// `thread_local`, so a UIA client asking about this page from the automation
/// core's thread cannot see a single row of it. The palette solved the same
/// problem the same way one window over; this follows it rather than
/// inventing a second answer.
static KB_SNAPSHOT: std::sync::Mutex<Vec<KbSnapshotRow>> = std::sync::Mutex::new(Vec::new());
/// First visible row, the page's DPI, its width, and whether it is on screen
/// at all. `usize::MAX` in `KB_TOP` means the page is not showing, which is a
/// different fact from "showing, scrolled to the top".
static KB_TOP: AtomicUsize = AtomicUsize::new(usize::MAX);
static KB_DPI: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(96);
static KB_WIDTH: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);



pub fn kb_row_rect_at(top: usize, dpi: i32, width: i32, index: usize) -> Option<RECT> {
    if top == usize::MAX {
        return None;
    }
    let n = index.checked_sub(top)?;
    if n >= KB_VISIBLE {
        return None;
    }
    let sc = |v: i32| v * dpi / 96;
    let y = sc(PAD + KB_HEADER) + n as i32 * sc(KB_ROW_H);
    Some(RECT { left: sc(PAD), top: y, right: width - sc(PAD), bottom: y + sc(KB_ROW_H) })
}

/// `kb_row_rect_at` against the page as it is right now.
pub fn kb_row_rect(index: usize) -> Option<RECT> {
    kb_row_rect_at(
        KB_TOP.load(Ordering::Acquire),
        KB_DPI.load(Ordering::Acquire),
        KB_WIDTH.load(Ordering::Acquire),
        index,
    )
}

/// How many rows the page is showing. Zero when it has never been opened.
pub fn kb_row_count() -> usize {
    KB_SNAPSHOT.lock().map(|r| r.len()).unwrap_or(0)
}

/// Row `index`, or `None` past the end.
pub fn kb_row(index: usize) -> Option<KbSnapshotRow> {
    KB_SNAPSHOT.lock().ok()?.get(index).cloned()
}


/// Publish what a client may read. Called from the page's own thread, on
/// every change that moves a row: opening it, and scrolling it.
fn kb_publish(win: HWND, showing: bool) {
    ST.with(|c| {
        let st = c.borrow();
        if let Ok(mut rows) = KB_SNAPSHOT.lock() {
            rows.clear();
            for r in &st.keybinds {
                rows.push(KbSnapshotRow {
                    action: r.action.to_string(),
                    name: r.title.clone().unwrap_or_else(|| r.action.to_string()),
                    keys: crate::keybinds::keys_label(r),
                    note: crate::keybinds::note(r).to_string(),
                });
            }
        }
        KB_TOP.store(
            if showing { st.keybind_top } else { usize::MAX },
            Ordering::Release,
        );
    });
    kb_publish_geometry(win);
}

/// The page's width and DPI, without touching `ST`.
///
/// **Called from the paint path**, because that is the one place guaranteed
/// to run after the page is moved to a monitor with a different scale: there
/// is no `WM_DPICHANGED` arm on this window, and a stale scale would put
/// every row's rectangle somewhere the row is not.
fn kb_publish_geometry(win: HWND) {
    let mut rc = RECT::default();
    if unsafe { GetClientRect(win, &mut rc) }.is_ok() {
        KB_WIDTH.store(rc.right, Ordering::Release);
    }
    KB_DPI.store(dpi_scale(win), Ordering::Release);
}

unsafe extern "system" fn keybinds_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_KEYBINDS_SHOW => {
                let rows = crate::keybinds::rows();
                // process-wide: the listing is about the config, not a window
                plogf!(
                    "[set] keybinds: {} actions, {} of them with no key",
                    rows.len(),
                    rows.iter().filter(|r| r.triggers.is_empty()).count()
                );
                if rows.is_empty() {
                    // Nothing to show means the core was not reachable, which
                    // is not the same as "you have no shortcuts" -- so say
                    // nothing rather than show an empty page claiming that.
                    return LRESULT(0);
                }
                ST.with(|c| {
                    let mut st = c.borrow_mut();
                    st.keybinds = rows;
                    st.keybind_top = 0;
                });
                let frame = crate::tabs::overlay_frame();
                let mut fr = RECT::default();
                if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
                    return LRESULT(0);
                }
                let sc = dpi_scale(win);
                let (w, h) = (760 * sc / 96, 560 * sc / 96);
                let x = fr.left + ((fr.right - fr.left) - w) / 2;
                let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
                own_and_place(win, x, y, w, h);
                kb_publish(win, true);
                let _ = InvalidateRect(Some(win), None, true);
                LRESULT(0)
            }

            // **Esc closes; a click does not.** The errors box dismisses on
            // any click because it is one short message. This page is a list
            // the reader scrolls and points at, and a list that vanishes when
            // you click it cannot be read.
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if vk == VK_ESCAPE {
                    let _ = ShowWindow(win, SW_HIDE);
                    // A hidden page has no rows on screen. Said out loud
                    // rather than left at the last scroll position, which a
                    // client would read as rectangles it could click.
                    kb_publish(win, false);
                    return LRESULT(0);
                }
                let step: i32 = match vk {
                    VK_DOWN => 1,
                    VK_UP => -1,
                    VK_NEXT => KB_VISIBLE as i32,
                    VK_PRIOR => -(KB_VISIBLE as i32),
                    _ => return DefWindowProcW(win, msg, wp, lp),
                };
                kb_scroll(win, step);
                LRESULT(0)
            }

            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xffff) as i16;
                kb_scroll(win, if delta > 0 { -3 } else { 3 });
                LRESULT(0)
            }

            // **Without this the page is not there at all.** It draws
            // everything itself and creates no child windows, so the default
            // provider has nothing to enumerate: a client asking for the
            // tree got the window and zero descendants, and reading the page
            // meant taking a screenshot of it.
            WM_GETOBJECT => match crate::uia::on_get_object_keybinds(win, wp, lp) {
                Some(r) => r,
                None => DefWindowProcW(win, msg, wp, lp),
            },

            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                theme::repaint_all(win);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(win, &mut ps);
                if !hdc.is_invalid() {
                    kb_paint(win, hdc);
                    let _ = EndPaint(win, &ps);
                    kb_publish_geometry(win);
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

/// Move the first visible row, clamped so the list cannot be scrolled past
/// either end.
fn kb_scroll(win: HWND, by: i32) {
    ST.with(|c| {
        let mut st = c.borrow_mut();
        let n = st.keybinds.len();
        let last = n.saturating_sub(KB_VISIBLE);
        let next = (st.keybind_top as i32 + by).clamp(0, last as i32) as usize;
        if next == st.keybind_top {
            return;
        }
        st.keybind_top = next;
    });
    kb_publish(win, true);
    let _ = unsafe { InvalidateRect(Some(win), None, true) };
}

unsafe fn kb_paint(win: HWND, hdc: HDC) {
    unsafe {
        let mut rc = RECT::default();
        let _ = GetClientRect(win, &mut rc);
        let sc = dpi_scale(win);
        let s = |v: i32| v * sc / 96;

        let b = CreateSolidBrush(COLORREF(theme::panel()));
        FillRect(hdc, &rc, b);
        let _ = DeleteObject(b.into());
        SetBkMode(hdc, TRANSPARENT);

        ST.with(|c| {
            let st = c.borrow();
            let old = SelectObject(hdc, font().into());

            let mut r = RECT { left: s(PAD), top: s(PAD), right: rc.right - s(PAD), bottom: s(PAD + 24) };
            // **Not `Keyboard Shortcuts…`.** `uia.rs`'s `GetPropertyValue`
            // for `keybinds-list` already names this same page `Keyboard
            // Shortcuts` for a screen reader, and the two have to agree. The spelling with U+2026 is a *different* msgid
            // and a deliberate one: it is the menu row, where the ellipsis
            // says "this opens a window" (`MainMenu.xib:111` has it too).
            // Folding the two together would read as tidying up a duplicate
            // and would silently orphan one translation.
            draw_text(hdc, &tr("Keyboard Shortcuts"), &mut r, DT_LEFT | DT_SINGLELINE, theme::text());

            // ⚠️ **The legend is not decoration.** This page has an action
            // count, a binding count and a command count in the same
            // neighbourhood and they are different numbers; saying which one
            // the list is keeps the next reader from taking it for another.
            let mut lr = RECT {
                left: s(PAD),
                top: s(PAD + 26),
                right: rc.right - s(PAD),
                bottom: s(PAD + 48),
            };
            // TRANSLATORS: `{}` is how many actions the list holds. It is
            // not at the start of the sentence on purpose, so a language that
            // needs the number elsewhere can move it.
            let legend = tr("This page lists actions; {} in all. Some actions have no shortcut assigned.")
                .replace("{}", &st.keybinds.len().to_string());
            draw_text(hdc, &legend, &mut lr, DT_LEFT | DT_SINGLELINE, theme::dim());

            let name_w = s(230);
            let key_w = s(180);

            let end = (st.keybind_top + KB_VISIBLE).min(st.keybinds.len());
            for (offset, row) in st.keybinds[st.keybind_top..end].iter().enumerate() {
                // **The same function the provider reads**, so what a client
                // is told to click and what is drawn cannot drift. See
                // `kb_row_rect_at`.
                let Some(rr) = kb_row_rect_at(
                    st.keybind_top,
                    sc,
                    rc.right,
                    st.keybind_top + offset,
                ) else {
                    continue;
                };
                let y = rr.top;
                // The tag is always shown; the human title only exists for
                // some actions, so it cannot be the column you navigate by.
                let name = row.title.as_deref().unwrap_or(row.action);
                let mut nr =
                    RECT { left: s(PAD), top: y, right: s(PAD) + name_w, bottom: rr.bottom };
                draw_text(hdc, name, &mut nr, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS, theme::text());

                let keys = crate::keybinds::keys_label(row);
                let mut kr = RECT {
                    left: s(PAD) + name_w,
                    top: y,
                    right: s(PAD) + name_w + key_w,
                    bottom: rr.bottom,
                };
                let key_colour = if row.triggers.is_empty() { theme::dim() } else { theme::text() };
                draw_text(hdc, &keys, &mut kr, DT_LEFT | DT_SINGLELINE, key_colour);

                let note = crate::keybinds::note(row);
                if !note.is_empty() {
                    let mut tr = RECT {
                        left: s(PAD) + name_w + key_w,
                        top: y,
                        right: rc.right - s(PAD),
                        bottom: rr.bottom,
                    };
                    let colour = if row.hidden_from_menu { theme::warn() } else { theme::dim() };
                    // Spelled out rather than `tr(note)`: the `RECT` a line
                    // above is also called `tr`, and the shadowing is only
                    // visible if you are looking for it.
                    let note = crate::i18n::tr(note);
                    draw_text(hdc, &note, &mut tr, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS, colour);
                }
            }

            let mut fr = RECT {
                left: s(PAD),
                top: rc.bottom - s(28),
                right: rc.right - s(PAD),
                bottom: rc.bottom,
            };
            // ⚠️ **One msgid for the whole line, runs of spaces included.**
            // Splitting out the two verbs would hand the word order to this
            // `format!`, which is the same defect the close-confirmation box
            // had in `tabs.rs`. A translator needs to be able to move
            // "Scroll" and "Close" around the key names, and in some
            // languages to put them first.
            //
            // The four spaces are column padding rather than prose; they are
            // called out to the translator in the extractor comment below so
            // a run of whitespace does not read as a typo to be tidied.
            //
            // TRANSLATORS: the runs of four spaces are column padding that
            // separates the three groups; please keep them. `{}-{} / {}` is
            // first-shown, last-shown, total.
            let footer = tr("{}–{} / {}    ↑↓ PgUp PgDn Scroll    Esc Close")
                .replacen("{}", &(st.keybind_top + 1).to_string(), 1)
                .replacen("{}", &end.to_string(), 1)
                .replacen("{}", &st.keybinds.len().to_string(), 1);
            draw_text(hdc, &footer, &mut fr, DT_LEFT | DT_SINGLELINE, theme::dim());
            SelectObject(hdc, old);
        });
    }
}

unsafe extern "system" fn errors_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_ERRORS_SHOW => {
                let errors = read_diagnostics();
                // process-wide: diagnostics about the config this process loaded
                plogf!("[set] config diagnostics: {}", errors.len());
                if errors.is_empty() {
                    let _ = ShowWindow(win, SW_HIDE);
                    return LRESULT(0);
                }
                ST.with(|c| c.borrow_mut().errors = errors);
                let frame = crate::tabs::overlay_frame();
                let mut fr = RECT::default();
                if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
                    return LRESULT(0);
                }
                let sc = dpi_scale(win);
                let (w, h) = (560 * sc / 96, 320 * sc / 96);
                let x = fr.left + ((fr.right - fr.left) - w) / 2;
                let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
                own_and_place(win, x, y, w, h);
                let _ = InvalidateRect(Some(win), None, true);
                LRESULT(0)
            }
            WM_KEYDOWN if VIRTUAL_KEY(wp.0 as u16) == VK_ESCAPE => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            // **A theme change is a repaint, because the colours are the
            // system's now.** Without this the page keeps the old ones until
            // something else invalidates it -- and "it did not follow the
            // theme" is exactly what a second, private copy of the colours
            // would look like, which would make the two indistinguishable
            // from outside.
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                theme::repaint_all(win);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(win, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let sc = dpi_scale(win);
                    let s = |v: i32| v * sc / 96;
                    let b = CreateSolidBrush(COLORREF(theme::panel()));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                    SetBkMode(hdc, TRANSPARENT);
                    ST.with(|c| {
                        let st = c.borrow();
                        let old = SelectObject(hdc, font().into());
                        let mut r = RECT {
                            left: s(PAD),
                            top: s(PAD),
                            right: rc.right - s(PAD),
                            bottom: s(PAD + 24),
                        };
                        draw_text(
                            hdc,
                            "Configuration errors",
                            &mut r,
                            DT_LEFT | DT_SINGLELINE,
                            theme::warn(),
                        );
                        let mut y = s(PAD + 30);
                        for e in &st.errors {
                            let mut er = RECT {
                                left: s(PAD),
                                top: y,
                                right: rc.right - s(PAD),
                                bottom: y + s(40),
                            };
                            draw_text(hdc, e, &mut er, DT_LEFT | DT_WORDBREAK, theme::text());
                            y += s(42);
                        }
                        let mut fr = RECT {
                            left: s(PAD),
                            top: rc.bottom - s(28),
                            right: rc.right - s(PAD),
                            bottom: rc.bottom,
                        };
                        draw_text(
                            hdc,
                            &tr("Esc or click to dismiss"),
                            &mut fr,
                            DT_LEFT | DT_SINGLELINE,
                            theme::dim(),
                        );
                        SelectObject(hdc, old);
                    });
                    let _ = EndPaint(win, &ps);
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}


#[cfg(test)]
mod keybind_geometry_tests {
    use super::*;

    /// Task 328 was ninety rows sharing one rectangle: every click landed on
    /// the first command. **Adjacent rows must not overlap**, and the check
    /// has to be on the rectangles rather than on the arithmetic that made
    /// them, or it only re-derives the bug.
    #[test]
    fn rows_do_not_share_a_rectangle() {
        let mut prev: Option<RECT> = None;
        for i in 0..KB_VISIBLE {
            let r = kb_row_rect_at(0, 96, 800, i).expect("visible row");
            assert!(r.bottom > r.top, "row {i} has no height");
            if let Some(p) = prev {
                assert!(r.top >= p.bottom, "row {i} overlaps the one above it");
            }
            prev = Some(r);
        }
    }

    /// Scrolling moves which rows are drawn, not where the page draws them:
    /// row 40 at the top of the view occupies the same place row 0 did.
    #[test]
    fn scrolling_reuses_the_same_slots() {
        let first = kb_row_rect_at(0, 96, 800, 0).unwrap();
        let after = kb_row_rect_at(40, 96, 800, 40).unwrap();
        assert_eq!(first.top, after.top);
        assert_eq!(first.bottom, after.bottom);
    }

    /// Off the view in either direction has **no rectangle at all**. An
    /// invented one would be a coordinate a client can click, landing on
    /// whatever is really there.
    #[test]
    fn rows_outside_the_view_have_no_rectangle() {
        assert!(kb_row_rect_at(40, 96, 800, 39).is_none(), "above the view");
        assert!(kb_row_rect_at(40, 96, 800, 40 + KB_VISIBLE).is_none(), "below it");
    }

    /// The page not being shown is not the same as a row being scrolled
    /// away, but it answers the same: nothing.
    #[test]
    fn a_page_that_is_not_showing_answers_nothing() {
        assert!(kb_row_rect_at(usize::MAX, 96, 800, 0).is_none());
    }

    /// Everything scales, so a rectangle taken at one DPI cannot be reported
    /// at another -- which is what a provider reading a stale `KB_DPI` would
    /// do.
    #[test]
    fn dpi_scales_the_rows() {
        let at96 = kb_row_rect_at(0, 96, 800, 3).unwrap();
        let at192 = kb_row_rect_at(0, 192, 1600, 3).unwrap();
        assert_eq!(at192.top, at96.top * 2);
        assert_eq!(at192.bottom - at192.top, (at96.bottom - at96.top) * 2);
    }
}
