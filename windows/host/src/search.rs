//! The search overlay: a find bar over the terminal.
//!
//! **The core owns the search; this file owns a text box and a counter.**
//! There is no `ghostty_surface_search_*` function — the entire feature is
//! driven through `ghostty_surface_binding_action` with action strings, and
//! answered through `action_cb`:
//!
//! | direction | what |
//! | --- | --- |
//! | host → core | `search:<text>` (empty cancels), `navigate_search:next` / `:previous`, `end_search`, `search_selection` |
//! | core → host | `start_search` (with an optional initial needle), `end_search`, `search_total`, `search_selected` |
//!
//! So the host never looks at the screen contents, never counts anything, and
//! **cannot disagree with the core about how many matches there are** — the
//! number it paints is the number the core sent.
//!
//! **Why the input is a native `EDIT`.** Same reason as the command palette:
//! a self-drawn field would need its own `ITextStoreACP`, because an IME
//! composes into a document rather than a rectangle. The focus contract that
//! comes with borrowing the control lives in `overlay.rs`, which is shared
//! with the palette.
//!
//! **Why there is an inbox.** `search_total` and `search_selected` arrive on
//! whichever thread the core is on, and `start_search` carries a `const char*`
//! that is only valid for the duration of that callback. Both are therefore
//! copied into a small mutex-guarded inbox and a message is posted; the
//! window procedure drains it on the main thread. The lock is never held
//! across a Win32 call -- that is the shape that deadlocked the tab layout
//! once already.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Mutex;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, WPARAM, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Controls::EM_SETSEL;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{plogf, wlogf};

/// `WM_APP + 1` is the tab op queue, `+ 2` the command palette.
const WM_SEARCH_SHOW: u32 = WM_APP + 3;
const WM_SEARCH_HIDE: u32 = WM_APP + 4;
const WM_SEARCH_COUNT: u32 = WM_APP + 5;

const WIDTH: i32 = 340;
const HEIGHT: i32 = 38;
const PAD: i32 = 8;
const BTN_W: i32 = 22;

use crate::theme;

/// **The one colour with no system source**, for the same reason
/// `theme::warn` has none: nothing in the palette means "nothing matched".
/// It gives way to plain text under high contrast, where a fixed red is what
/// stops being readable.
fn col_none() -> u32 {
    if crate::theme::high_contrast() {
        crate::theme::text()
    } else {
        0x0064_64e0
    }
}

static HWND_SEARCH: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// What the core told us, waiting to be picked up on the main thread.
#[derive(Default)]
struct Inbox {
    /// `Some(needle)` from `start_search`; the inner value may be empty.
    show: Option<String>,
    /// The surface `start_search` was aimed at, travelling with the needle so
    /// the two cannot be taken from different moments.
    owner: Option<usize>,
    total: Option<i64>,
    selected: Option<i64>,
}

static INBOX: Mutex<Inbox> = Mutex::new(Inbox {
    show: None,
    owner: None,
    total: None,
    selected: None,
});

/// The window handles, written once and never again. **Outside the `RefCell`
/// deliberately** -- see the long note on `palette::Windows`, which this
/// mirrors. In short: reading a `Cell` takes no borrow, so `Model` below can
/// hold no window, so the call that crashed the palette (a dispatching Win32
/// call made while a borrow was live) has nothing here to be made on.
///
/// This file had the same defect as the palette and had simply never been
/// asked to run it: `show` only wrote the box when the needle was non-empty,
/// and `start_search` passes an empty one.
#[derive(Clone, Copy)]
struct Windows {
    edit: HWND,
    font: HFONT,
    edit_proc: WNDPROC,
}

/// **Adding an `HWND` or `HFONT` field here re-opens that crash** -- it belongs
/// on `Windows` instead.
struct Model {
    visible: bool,
    /// **Whose search this is**, as the core said when it opened the bar.
    ///
    /// Not state: the core holds the search, and this is only the address to
    /// send back to. It is here because without it the host knows *that* a
    /// search is open and not *whose* -- half a fact, and the half it keeps is
    /// the one it cannot act on.
    ///
    /// `None` means **the core's `start_search` named no surface**, not "we
    /// forgot to look": `target_surface` already refuses a null pointer and an
    /// app-targeted action, so there is no third state where this is `Some`
    /// and useless. The log below spells the difference out, because a blank
    /// column would not.
    ///
    /// Stored as `usize` for the same reason `tabs::Pane` does it.
    surface: Option<usize>,
    /// Straight from the core. `None` means it has not answered yet, which is
    /// different from zero and is painted differently.
    total: Option<i64>,
    selected: Option<i64>,
}

thread_local! {
    static STATE: RefCell<Option<Model>> = const { RefCell::new(None) };
    static WINDOWS: Cell<Option<Windows>> = const { Cell::new(None) };
    /// The window that had focus when the bar opened. A `Cell` and not a field
    /// of `Model`, for the reason above.
    static PREV_FOCUS: Cell<HWND> = const { Cell::new(HWND(std::ptr::null_mut())) };
}

/// The handles, or `None` before `init`. **Takes no borrow.**
fn windows() -> Option<Windows> {
    WINDOWS.with(|w| w.get())
}

fn hwnd() -> HWND {
    HWND(HWND_SEARCH.load(Ordering::Acquire))
}

fn post(msg: u32) {
    let h = HWND_SEARCH.load(Ordering::Acquire);
    if h.is_null() {
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), msg, WPARAM(0), LPARAM(0)) };
}

// ------------------------------------------------------- from `action_cb`

/// `GHOSTTY_ACTION_START_SEARCH`. **Safe from any thread.**
///
/// The needle is copied here rather than passed along: the pointer belongs to
/// the core and is only valid until this call returns.
pub fn on_start(needle: Option<&str>, surface: Option<crate::ffi::Surface>) {
    if let Ok(mut inbox) = INBOX.lock() {
        inbox.show = Some(needle.unwrap_or("").to_string());
        // **Carried, not looked up later.** By the time the bar is drawn the
        // focused surface may be a different one; the only moment this is
        // knowable is the moment the core says so.
        inbox.owner = surface.map(|s| s as usize);
    }
    post(WM_SEARCH_SHOW);
}

/// `GHOSTTY_ACTION_END_SEARCH`. **Safe from any thread.**
pub fn on_end() {
    post(WM_SEARCH_HIDE);
}

/// `GHOSTTY_ACTION_SEARCH_TOTAL` / `SEARCH_SELECTED`. **Safe from any thread.**
pub fn on_count(total: Option<i64>, selected: Option<i64>) {
    if let Ok(mut inbox) = INBOX.lock() {
        if total.is_some() {
            inbox.total = total;
        }
        if selected.is_some() {
            inbox.selected = selected;
        }
    }
    post(WM_SEARCH_COUNT);
}

// ------------------------------------------------------------------ setup

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_DROPSHADOW,
            lpfnWndProc: Some(search_proc),
            hInstance: hinst,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            lpszClassName: w!("PolterSearch"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            // process-wide: registering the search window class, once per process
            plogf!("[search] RegisterClassExW failed");
            return;
        }

        let hwnd = match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            w!("PolterSearch"),
            w!("Polter"),
            WS_POPUP,
            0,
            0,
            WIDTH,
            HEIGHT,
            None,
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: creating the single search window this process has
                plogf!("[search] CreateWindowExW failed: {e:?}");
                return;
            }
        };

        let dpi = GetDpiForWindow(hwnd).max(96);
        let sc = |v: i32| v * dpi as i32 / 96;

        // Leaves room on the right for the counter and the two arrows.
        let edit_w = sc(WIDTH) - sc(PAD * 2) - sc(BTN_W * 2) - sc(64);
        let edit = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            sc(PAD),
            sc(PAD),
            edit_w,
            sc(HEIGHT - PAD * 2),
            Some(hwnd),
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: creating the single search window this process has
                plogf!("[search] edit CreateWindowExW failed: {e:?}");
                return;
            }
        };

        let font = CreateFontW(
            -(sc(14)),
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
        SendMessageW(edit, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));

        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = edit_proc;
        let old = SetWindowLongPtrW(edit, GWLP_WNDPROC, f as usize as isize);

        WINDOWS.with(|w| {
            w.set(Some(Windows {
                edit,
                font,
                edit_proc: std::mem::transmute(old),
            }))
        });
        STATE.with(|c| {
            *c.borrow_mut() = Some(Model {
                visible: false,
                surface: None,
                total: None,
                selected: None,
            });
        });
        HWND_SEARCH.store(hwnd.0, Ordering::Release);
        // process-wide: the search window exists; no terminal window owns it yet
        plogf!("[search] ready");
    }
}

// ------------------------------------------------------------ show / hide

fn show(needle: &str, owner: Option<usize>) {
    let me = hwnd();
    if me.0.is_null() {
        return;
    }
    STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.surface = owner;
        }
    });
    unsafe {
        // Opens over window 1 wherever it was invoked; see `tabs::overlay_frame`.
        let frame = crate::tabs::overlay_frame();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let dpi = GetDpiForWindow(me).max(96);
        let sc = |v: i32| v * dpi as i32 / 96;
        let (w, h) = (sc(WIDTH), sc(HEIGHT));

        // Top-right of the frame, inset. Not a corner the terminal's cursor
        // usually occupies, and it does not move while typing.
        let x = fr.right - w - sc(16);
        let y = fr.top + sc(56);

        STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.visible = true;
            }
        });

        // A fresh search that carries a needle replaces what was there;
        // `start_search` with an empty needle keeps it, which is what "reopen
        // the bar I just closed" should do. Outside any borrow: `WM_SETTEXT`
        // reaches the subclassed `edit_proc` synchronously. This is the line
        // that crashed the palette, in the one shape that never ran.
        let wins = windows();
        if let Some(wins) = wins {
            if !needle.is_empty() {
                let wide: Vec<u16> = needle.encode_utf16().chain(Some(0)).collect();
                let _ = SetWindowTextW(wins.edit, PCWSTR(wide.as_ptr()));
            }
        }

        let _ = SetWindowPos(me, Some(HWND_TOPMOST), x, y, w, h, SWP_SHOWWINDOW);

        if let Some(wins) = wins {
            PREV_FOCUS.set(crate::overlay::focus_to_edit(wins.edit, "search"));
            // Select all, so typing replaces the previous needle.
            SendMessageW(wins.edit, EM_SETSEL, Some(WPARAM(0)), Some(LPARAM(-1)));
        }
        // `frame` is the window this bar positioned itself over, a few lines
        // up -- so the line names where it actually landed, not a guess.
        wlogf!(frame, "[search] shown, needle={:?}", needle);
    }
}

fn hide() {
    let me = hwnd();
    if me.0.is_null() {
        return;
    }
    let was_up = STATE.with(|c| {
        c.borrow_mut()
            .as_mut()
            .map(|st| {
                st.total = None;
                st.selected = None;
                // **Cleared with the bar.** A stale owner would be an address
                // for a search that has ended -- the same half-fact one step
                // later, and harder to see because it looks like knowledge.
                st.surface = None;
                std::mem::replace(&mut st.visible, false)
            })
            .unwrap_or(false)
    });
    unsafe {
        let _ = ShowWindow(me, SW_HIDE);
    }
    if was_up {
        crate::overlay::focus_back(PREV_FOCUS.get(), "search");
    }
}

/// Read the box and tell the core. An empty needle cancels the search, which
/// is the core's own rule for `search:` -- deleting the text should stop
/// highlighting, not leave the last match lit.
fn push_needle() {
    // `GetWindowTextW` sends `WM_GETTEXT` synchronously, so it is a dispatching
    // call like any other and is made with no borrow held. It happened to be
    // safe before this change -- both sides took a *shared* borrow -- but that
    // was a fact about `edit_proc`'s first line, two hundred lines away.
    let Some(wins) = windows() else { return };
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(wins.edit, &mut buf) } as usize;
    let text = String::from_utf16_lossy(&buf[..n]);

    // The core has not answered for this needle yet. Painting the old count
    // next to a new needle is worse than painting nothing.
    STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.total = None;
            st.selected = None;
        }
    });

    let action = format!("search:{}", text);
    to_owner(&action);
    let _ = unsafe { InvalidateRect(Some(hwnd()), None, true) };
}

/// Send an action **to the surface this search belongs to**.
///
/// `crate::binding` sends to "the first window's focused surface", and its own
/// documentation calls that a gap rather than a decision. A find bar is
/// exactly where that gap bites: the core starts a search on one surface, and
/// by the time anything is sent back the focused surface can be a different
/// one -- another pane of a split, another tab, another window. Then
/// `end_search` ends nothing (`performable`, so it declines and returns
/// false), and worse, **`search:<text>` searches the wrong terminal and shows
/// the wrong count**.
///
/// The address was available the whole time: the core names the surface in the
/// action it sends. See `Model::surface`.
///
/// **When there is no owner this falls back to the old behaviour and says so.**
/// Refusing instead would make the bar impossible to close if the core ever
/// sends an app-targeted `start_search`; a guess that announces itself is the
/// lesser of the two, and the line below is what tells a reader which of them
/// happened.
fn to_owner(action: &str) -> bool {
    let owner = STATE.with(|c| c.borrow().as_ref().and_then(|st| st.surface));
    let (surface, how) = match owner {
        Some(s) => (s as crate::ffi::Surface, "owner"),
        // Named separately from `crate::binding` so the line below can say
        // what it actually reached rather than "somewhere".
        None => (
            crate::tabs::active_surface(crate::tabs::overlay_frame()),
            "guess: start_search named no surface, so this is the active surface of the overlay frame",
        ),
    };
    let ok = crate::binding_on(surface, action);
    // **Tagged with the window the surface belongs to, not the one in front.**
    // A search is a fact about one terminal, and the whole point of this
    // function is that those two can differ.
    match crate::tabs::frame_of_surface(surface) {
        Some(frame) => wlogf!(
            frame,
            "[search] {} -> binding_action = {} (to {:?}, {})",
            action, ok, surface, how
        ),
        // process-wide: the surface belongs to no live window, so there is no
        // window this line is about -- which is itself the reading
        None => plogf!(
            "[search] {} -> binding_action = {} (to {:?}, {}; that surface is in no live window)",
            action, ok, surface, how
        ),
    }
    ok
}

fn navigate(next: bool) {
    let action = if next {
        "navigate_search:next"
    } else {
        "navigate_search:previous"
    };
    to_owner(action);
}

fn end_from_host() {
    // **Tell the core first, and tell the right one.**
    //
    // The core owns the search state and the highlighting, so hiding the bar
    // without ending the search leaves the matches lit with no way to clear
    // them -- the entry point that would clear them is the bar that just
    // disappeared.
    //
    // **The risk this guards against has moved.** It used to be "the host
    // forgets to tell the core"; that has not been possible since this call
    // existed. What remained was telling the *wrong* surface, which produces
    // the same lit-and-unclearable screen while the log shows a call that was
    // made -- so it reads as done. `to_owner` is what closes that, and the
    // line it logs is how a reader tells the two apart afterwards.
    to_owner("end_search");
    hide();
}

// ------------------------------------------------------------ window procs

extern "system" fn search_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_SEARCH_SHOW => {
                let (needle, owner) = INBOX
                    .lock()
                    .ok()
                    .map(|mut i| (i.show.take(), i.owner.take()))
                    .unwrap_or((None, None));
                show(&needle.unwrap_or_default(), owner);
                LRESULT(0)
            }
            WM_SEARCH_HIDE => {
                let vis = STATE.with(|c| c.borrow().as_ref().map(|s| s.visible).unwrap_or(false));
                if vis {
                    hide();
                }
                LRESULT(0)
            }
            WM_SEARCH_COUNT => {
                if let Ok(mut inbox) = INBOX.lock() {
                    let (t, s) = (inbox.total.take(), inbox.selected.take());
                    drop(inbox); // never hold the lock across a Win32 call
                    STATE.with(|c| {
                        if let Some(st) = c.borrow_mut().as_mut() {
                            if t.is_some() {
                                st.total = t;
                            }
                            if s.is_some() {
                                st.selected = s;
                            }
                        }
                    });
                }
                let _ = InvalidateRect(Some(hwnd), None, true);
                LRESULT(0)
            }

            // The needle box is a native `EDIT`: it asks its parent what
            // colours to use and honours the answer, which is the whole of
            // making it dark. Under high contrast `ctl_color` answers `None`,
            // this falls through, and the system's colours stand.
            WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC => {
                match crate::theme::ctl_color(windows::Win32::Graphics::Gdi::HDC(
                    wp.0 as *mut std::ffi::c_void,
                )) {
                    Some(b) => LRESULT(b.0 as isize),
                    None => DefWindowProcW(hwnd, msg, wp, lp),
                }
            }
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                crate::theme::repaint_all(hwnd);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(hwnd);
                LRESULT(0)
            }

            WM_LBUTTONDOWN => {
                let x = (lp.0 & 0xFFFF) as i16 as i32;
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                let mut rc = RECT::default();
                let _ = GetClientRect(hwnd, &mut rc);
                let next_x = rc.right - sc(PAD) - sc(BTN_W);
                let prev_x = next_x - sc(BTN_W);
                if x >= next_x {
                    navigate(true);
                } else if x >= prev_x {
                    navigate(false);
                }
                LRESULT(0)
            }

            WM_DESTROY => {
                if let Some(wins) = windows() {
                    let _ = DeleteObject(wins.font.into());
                }
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Everything not listed falls through to the original, which is what keeps
/// editing, selection and the IME working.
unsafe extern "system" fn edit_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let old = windows().and_then(|w| w.edit_proc);

    unsafe {
        match msg {
            WM_KEYDOWN => match VIRTUAL_KEY(wp.0 as u16) {
                VK_ESCAPE => {
                    end_from_host();
                    return LRESULT(0);
                }
                VK_RETURN => {
                    // Shift+Enter walks backwards, the convention every find
                    // bar uses.
                    navigate(!(GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000 != 0));
                    return LRESULT(0);
                }
                VK_F3 => {
                    navigate(true);
                    return LRESULT(0);
                }
                _ => {}
            },

            // Otherwise the edit control beeps on Enter and Escape.
            WM_CHAR => {
                let c = wp.0 as u16;
                if c == 0x0D || c == 0x1B {
                    return LRESULT(0);
                }
            }

            _ => {}
        }

        let r = CallWindowProcW(old, hwnd, msg, wp, lp);

        // After the control has applied the edit, so what we read is what the
        // user now sees.
        if msg == WM_CHAR || msg == WM_PASTE || (msg == WM_KEYDOWN && wp.0 as u16 == VK_BACK.0) {
            push_needle();
        }
        r
    }
}

// ------------------------------------------------------------------- paint

fn paint(hwnd: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        let dpi = GetDpiForWindow(hwnd).max(96) as i32;
        let sc = |v: i32| v * dpi / 96;

        let bg = CreateSolidBrush(COLORREF(theme::bg()));
        FillRect(hdc, &rc, bg);
        let _ = DeleteObject(bg.into());
        SetBkMode(hdc, TRANSPARENT);

        let Some(wins) = windows() else { return };
        STATE.with(|c| {
            let b = c.borrow();
            let Some(st) = b.as_ref() else { return };
            let old_font = SelectObject(hdc, wins.font.into());

            // The counter. Three distinct states, and they must look
            // different: not answered yet, answered zero, answered n.
            let (label, colour) = match (st.total, st.selected) {
                (None, _) => (String::new(), theme::dim()),
                (Some(0), _) => ("0/0".to_string(), col_none()),
                (Some(t), Some(s)) => (format!("{}/{}", s, t), theme::text()),
                (Some(t), None) => (format!("-/{}", t), theme::dim()),
            };

            let next_x = rc.right - sc(PAD) - sc(BTN_W);
            let prev_x = next_x - sc(BTN_W);

            if !label.is_empty() {
                SetTextColor(hdc, COLORREF(colour));
                let mut wide: Vec<u16> = label.encode_utf16().collect();
                let mut tr = RECT {
                    left: prev_x - sc(70),
                    top: sc(PAD + 2),
                    right: prev_x - sc(6),
                    bottom: rc.bottom,
                };
                DrawTextW(hdc, &mut wide, &mut tr, DT_RIGHT | DT_SINGLELINE);
            }

            SetTextColor(hdc, COLORREF(theme::dim()));
            for (x, glyph) in [(prev_x, "\u{2039}"), (next_x, "\u{203A}")] {
                let mut g: Vec<u16> = glyph.encode_utf16().collect();
                let mut br = RECT {
                    left: x,
                    top: sc(PAD),
                    right: x + sc(BTN_W),
                    bottom: rc.bottom - sc(PAD - 2),
                };
                DrawTextW(hdc, &mut g, &mut br, DT_CENTER | DT_SINGLELINE);
            }

            SelectObject(hdc, old_font);
        });

        let _ = EndPaint(hwnd, &ps);
    }
}
