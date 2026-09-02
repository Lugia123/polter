//! The command palette: a filter box over the commands the core publishes.
//!
//! **Where the commands come from, and why none of them are written here.**
//! The core carries the list — `command-palette-entry` in the config, read
//! through `ghostty_config_get` as a `ghostty_config_command_list_s` of
//! `{action_key, action, title, description}`. Its default value is not empty:
//! `RepeatableCommand.init` preloads one entry per action that is useful
//! interactively but has no memorable shortcut. Running an entry means handing
//! its `action` string to `ghostty_surface_binding_action`, which is the same
//! entry point a macOS menu item and a key binding use. **So this file renders
//! and dispatches; it does not know what any command means.** That is also why
//! `macos/Sources/App/Base.lproj/MainMenu.xib` (103 menu items, zero Swift
//! lines) needs no Windows counterpart.
//!
//! **Why the input box is a native `EDIT` and not self-drawn.** A self-drawn
//! field would need its own caret, selection, and — the expensive part — its
//! own `ITextStoreACP`, because an IME composes into a document, not into a
//! rectangle. By the measurement in `docs/windows/design.md` §1.6 that second
//! text store alone would cost more than this whole file's budget. The native
//! `EDIT` already has a TSF document, so Chinese input works in the palette
//! for free.
//!
//! **The price of that choice is one contract, and it is about call sites, not
//! APIs.** There is exactly one TSF document manager for this thread, and
//! `ime_init` associated it with the *terminal* windows. When the palette takes
//! focus we must hand that document back (`ime_focus(false)`) so TSF switches
//! to the edit control's own; when the palette closes we must return focus to
//! the surface, whose `WM_SETFOCUS` already calls `ime_set_window` +
//! `ime_focus(true)`. Miss the first and the palette cannot compose; miss the
//! second and the terminal's IME does not come back. **Neither fails loudly.**
//!
//! **Why every mutation happens on the main thread.** `action_cb` is called
//! from whichever thread the core is on, and creating or showing a window off
//! the owning thread is undefined in Win32. Rather than add a second queue,
//! `request_toggle` posts `WM_PALETTE_TOGGLE` to *this* window; the palette's
//! own window procedure is therefore the only place that touches its state.
//! That is why the state below is a `thread_local`, not a `Mutex`: there is no
//! lock to take, and so no lock to deadlock on.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

use windows::core::{s, w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::ffi::Config;
use crate::{logf, plogf, wlogf};

/// Posted to the palette window to open or close it. `WM_APP + 1` is taken by
/// the tab op queue (`tabs::WM_POLTER_OP`), so this is `+ 2`.
const WM_PALETTE_TOGGLE: u32 = WM_APP + 2;

/// Unscaled metrics. Everything is multiplied by the window's DPI at paint.
const ROW_H: i32 = 26;
const EDIT_H: i32 = 30;
const PAD: i32 = 8;
const MAX_ROWS: i32 = 12;
const WIDTH: i32 = 560;

const COL_BG: u32 = 0x00201f1d;
const COL_ROW_SEL: u32 = 0x00403f3d;
const COL_TEXT: u32 = 0x00ffffff;
const COL_DIM: u32 = 0x00a0a0a0;

/// The palette window, readable from any thread so `request_toggle` can post
/// to it. Null until `init` has run.
static HWND_PALETTE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// One entry as the core published it.
struct Command {
    /// The binding string, handed to `ghostty_surface_binding_action` verbatim.
    action: String,
    title: String,
    description: String,
    /// Lowercased title, kept so filtering does not re-allocate per keystroke.
    haystack: String,
    /// Extra lowercased words from `synonyms.txt`, matched separately so a
    /// synonym can win on its own without polluting the title's own score.
    aliases: Vec<String>,
}

/// Extra words that reach a command, on top of its own title.
///
/// **Why this exists.** 20 of the 69 commands on macOS's menu bar are the same
/// action the core publishes under a different word: someone typing `Find`
/// gets nothing, because the core calls it `Start Search`. **No code is wrong
/// in that story** -- the command is there, the palette works, the search
/// works -- and every acceptance criterion we had was asking whether the
/// function was correct.
///
/// **It is an index, not a naming.** A line whose command no longer exists
/// stops matching, which is the behaviour without any of this; it cannot
/// point somewhere wrong. `load_synonyms` reports how many lines found no
/// command, so a stale one is a number in the log rather than silence, and
/// `test "palette synonyms name real commands"` in `src/input/command.zig`
/// fails the build if a line names a command the core does not publish.
const SYNONYMS: &str = include_str!("synonyms.txt");

/// The window handles, written once when the palette is built and never again.
/// **They live outside the `RefCell` deliberately.**
///
/// Reading a `Cell` takes no borrow, so a Win32 call made through a handle from
/// here cannot re-enter a borrow that is still live. That is not a convenience;
/// it is the entire reason this type exists, and it is why `Model` below holds
/// no window handle of any kind.
///
/// **This structure replaces a rule that had already been rediscovered twice
/// and then failed a third time.** `tabs.rs` carries "no lock across a Win32
/// call that dispatches" and `tsf.rs` carries "no borrow across
/// `OnLockGranted`"; this module carried neither, and learned it by panicking
/// in front of a user the first time the palette was ever opened --
/// `SetWindowTextW` inside `borrow_mut` sends `WM_SETTEXT` synchronously to the
/// subclassed `edit_proc`, whose first line borrows.
///
/// A comment was never going to be enough here, because **whether a call site
/// is safe is not visible at that call site.** `SetWindowTextW(st.edit, ..)`
/// here and `SendMessageW(f.hwnd, WM_SETFONT, ..)` in `settings_ui.rs` are the
/// same shape; one panics and one does not, and separating them means checking,
/// in two other functions, whether the target window was subclassed and whether
/// that subclass borrows this cell. So the invariant moved into the types:
/// **the borrow hands out no window, so the dangerous call has nothing to be
/// made on.**
#[derive(Clone, Copy)]
struct Windows {
    edit: HWND,
    font: HFONT,
    /// The old `EDIT` window procedure, for keys we do not take.
    edit_proc: WNDPROC,
}

/// Everything that changes while the palette is open. **Adding an `HWND` or
/// `HFONT` field here re-opens the panic described on `Windows`** -- such a
/// field belongs there instead.
struct Model {
    commands: Vec<Command>,
    /// Indices into `commands`, best match first. Rebuilt on every keystroke.
    filtered: Vec<usize>,
    selected: usize,
    /// First visible row, so a long list can scroll without a scrollbar.
    top: usize,
    visible: bool,
}

thread_local! {
    static STATE: RefCell<Option<Model>> = const { RefCell::new(None) };
    static WINDOWS: Cell<Option<Windows>> = const { Cell::new(None) };
    /// The window that had focus when the palette opened, so it can be given
    /// back. A `Cell` and not a field of `Model` for the reason above: it is a
    /// window handle, and `focus_back` dispatches. It is a surface child
    /// window, and its `WM_SETFOCUS` is what restores the terminal's IME.
    static PREV_FOCUS: Cell<HWND> = const { Cell::new(HWND(std::ptr::null_mut())) };
}

/// The handles, or `None` before `init`. **Takes no borrow -- that is the
/// point of it.**
fn windows() -> Option<Windows> {
    WINDOWS.with(|w| w.get())
}

// --------------------------------------------------------------- commands

/// `ghostty_config_get` is not in `ffi.rs`'s `Api`, and adding it there would
/// mean editing a file another line of work is in. The DLL is already loaded
/// by the time this runs, so resolving the one symbol here costs nothing and
/// keeps this feature to one file.
fn load_commands(config: Config) -> Vec<Command> {
    #[repr(C)]
    struct CommandC {
        action_key: *const u8,
        action: *const u8,
        title: *const u8,
        description: *const u8,
    }
    #[repr(C)]
    struct CommandList {
        commands: *const CommandC,
        len: usize,
    }
    type ConfigGet = unsafe extern "C" fn(Config, *mut c_void, *const u8, usize) -> bool;

    unsafe fn cstr(p: *const u8) -> String {
        if p.is_null() {
            return String::new();
        }
        let mut n = 0usize;
        while unsafe { *p.add(n) } != 0 {
            n += 1;
        }
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(p, n) }).into_owned()
    }

    let get: ConfigGet = unsafe {
        let m = match GetModuleHandleA(s!("ghostty-internal.dll")) {
            Ok(m) => m,
            Err(e) => {
                // process-wide: loading the module, once, before any window exists
                plogf!("[palette] GetModuleHandleA failed: {e:?}");
                return Vec::new();
            }
        };
        match GetProcAddress(m, s!("ghostty_config_get")) {
            Some(p) => std::mem::transmute(p),
            None => {
                // process-wide: a fact about the core library this process loaded
                plogf!("[palette] ghostty_config_get not exported");
                return Vec::new();
            }
        }
    };

    let key = b"command-palette-entry";
    let mut list = CommandList { commands: std::ptr::null(), len: 0 };
    let ok = unsafe {
        get(
            config,
            &mut list as *mut CommandList as *mut c_void,
            key.as_ptr(),
            key.len(),
        )
    };
    if !ok || list.commands.is_null() {
        // Not fatal: a palette with no entries still opens and still closes,
        // which is a far better failure than a host that will not start.
        // process-wide: reading a config value: one config for the process
        plogf!("[palette] config_get(command-palette-entry) = {ok}, len={}", list.len);
        return Vec::new();
    }

    let mut out = Vec::with_capacity(list.len);
    for i in 0..list.len {
        let c = unsafe { &*list.commands.add(i) };
        let title = unsafe { cstr(c.title) };
        let action = unsafe { cstr(c.action) };
        if title.is_empty() || action.is_empty() {
            continue;
        }
        let haystack = title.to_lowercase();
        let aliases = synonyms_for(&title);
        out.push(Command {
            action,
            title,
            description: unsafe { cstr(c.description) },
            haystack,
            aliases,
        });
    }
    // process-wide: the command list, read once and shared by every palette
    plogf!("[palette] loaded {} commands from the core", out.len());
    audit_synonyms(&out);
    out
}

/// Parse `synonyms.txt` into `(typed word, core title)` pairs.
fn synonym_pairs() -> Vec<(String, String)> {
    SYNONYMS
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| {
            let (a, b) = l.split_once('=')?;
            Some((a.trim().to_lowercase(), b.trim().to_string()))
        })
        .collect()
}

fn synonyms_for(title: &str) -> Vec<String> {
    synonym_pairs()
        .into_iter()
        .filter(|(_, t)| t == title)
        .map(|(w, _)| w)
        .collect()
}

/// **The floor.** Counts the lines whose command the core did not publish, by
/// name, at startup.
///
/// A synonym pointing at a command that no longer exists is harmless -- it
/// just never matches -- but it is also invisible, and an index nobody can
/// tell is stale is one people stop trusting. One line makes it a reading.
fn audit_synonyms(commands: &[Command]) {
    let pairs = synonym_pairs();
    let mut orphaned: Vec<&str> = Vec::new();
    for (_, title) in &pairs {
        if !commands.iter().any(|c| &c.title == title) {
            orphaned.push(title);
        }
    }
    orphaned.sort_unstable();
    orphaned.dedup();
    // process-wide: the synonyms table, read once at startup
    plogf!(
        "[palette] synonyms: {} lines, {} naming no command{}",
        pairs.len(),
        orphaned.len(),
        if orphaned.is_empty() {
            String::new()
        } else {
            format!(" -> {:?}", orphaned)
        }
    );
}

// ---------------------------------------------------------------- filtering

/// Subsequence match with a score, higher is better. `None` means no match.
///
/// The three bonuses are what separate "contains the letters somewhere" from
/// "is the thing you meant": a hit at the start of the string, a hit at the
/// start of a word, and letters that stayed together.
fn score(haystack: &str, needle: &str) -> Option<i32> {
    if needle.is_empty() {
        return Some(0);
    }
    let hay: Vec<char> = haystack.chars().collect();
    let mut score = 0i32;
    let mut hi = 0usize;
    let mut last_hit: Option<usize> = None;

    for nc in needle.chars() {
        let mut found = None;
        while hi < hay.len() {
            if hay[hi] == nc {
                found = Some(hi);
                break;
            }
            hi += 1;
        }
        let at = found?;
        score += 1;
        if at == 0 {
            score += 8;
        } else if hay[at - 1] == ' ' || hay[at - 1] == ':' || hay[at - 1] == '_' {
            score += 4;
        }
        // **Worth more than the word-start bonus above, on purpose.** A
        // contiguous run is a stronger statement of intent than three scattered
        // word initials: typing `spl` means "split", not "select paste left".
        // Rank them the other way round and the obvious command sinks below a
        // coincidence.
        if last_hit == Some(at.wrapping_sub(1)) {
            score += 6;
        }
        last_hit = Some(at);
        hi = at + 1;
    }
    // Prefer the shorter of two equally good matches.
    Some(score - (hay.len() as i32) / 16)
}

/// Rebuild the visible list. It logs on every call, including the empty
/// needle at open, so the narrowing asked for by criterion 3 has a reading
/// that does not share a failure mode with the screenshot: a list that looks
/// shorter because the window was repainted wrong still logs the true count.
fn refilter(st: &mut Model, needle: &str) {
    let needle = needle.to_lowercase();
    let mut scored: Vec<(i32, usize)> = st
        .commands
        .iter()
        .enumerate()
        .filter_map(|(i, c)| {
            // The best of the title and any synonym. **A synonym never beats a
            // real title match by more than it should**: it is scored by the
            // same function, so `find` matching the alias of `Start Search`
            // ranks against `find` matching some other command's title on
            // equal terms.
            let best = std::iter::once(&c.haystack)
                .chain(c.aliases.iter())
                .filter_map(|h| score(h, &needle))
                .max()?;
            Some((best, i))
        })
        .collect();
    // Stable by score, then by the core's own ordering, so equal scores do not
    // shuffle between keystrokes.
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    st.filtered = scored.into_iter().map(|(_, i)| i).collect();
    st.selected = 0;
    st.top = 0;
    logf!(
        "[palette] filter {:?} -> {} of {}",
        needle,
        st.filtered.len(),
        st.commands.len()
    );
}

// ------------------------------------------------------------------- window

/// Register the class and create the window, hidden. Must run on the main
/// thread, after the config exists.
pub fn init(hinst: windows::Win32::Foundation::HINSTANCE, config: Config) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_DROPSHADOW,
            lpfnWndProc: Some(palette_proc),
            hInstance: hinst,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            lpszClassName: w!("PolterCommandPalette"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            // process-wide: registering the window class, once per process
            plogf!("[palette] RegisterClassExW failed");
            return;
        }

        // WS_EX_TOOLWINDOW keeps it off the taskbar; WS_EX_TOPMOST keeps it
        // over the terminal it is filtering.
        let hwnd = match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            w!("PolterCommandPalette"),
            w!("Polter"),
            WS_POPUP,
            0,
            0,
            WIDTH,
            EDIT_H + ROW_H * 6,
            None,
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: creating the single palette window this process has
                plogf!("[palette] CreateWindowExW failed: {e:?}");
                return;
            }
        };

        let dpi = GetDpiForWindow(hwnd).max(96);
        let sc = |v: i32| v * dpi as i32 / 96;

        let edit = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            sc(PAD),
            sc(PAD),
            sc(WIDTH - PAD * 2),
            sc(EDIT_H - PAD),
            Some(hwnd),
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: creating the single palette window this process has
                plogf!("[palette] edit CreateWindowExW failed: {e:?}");
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

        // Take Up/Down/Enter/Esc before the edit control sees them: it would
        // beep on Enter and ignore the arrows, and there is no other way to
        // drive a list from inside a single-line edit.
        // Coerce to a function *pointer* before the integer cast: casting a
        // function item straight to `isize` is a lint, and the value it
        // produces is not guaranteed to be the address Win32 needs.
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = edit_proc;
        let old = SetWindowLongPtrW(edit, GWLP_WNDPROC, f as usize as isize);
        let edit_proc_old: WNDPROC = std::mem::transmute(old);

        let commands = load_commands(config);

        WINDOWS.with(|w| {
            w.set(Some(Windows {
                edit,
                font,
                edit_proc: edit_proc_old,
            }))
        });
        STATE.with(|c| {
            *c.borrow_mut() = Some(Model {
                commands,
                filtered: Vec::new(),
                selected: 0,
                top: 0,
                visible: false,
            });
        });
        HWND_PALETTE.store(hwnd.0, Ordering::Release);
        // process-wide: the palette is initialised; there is one, and no window owns it yet
        plogf!("[palette] ready");
    }
}

/// Ask the palette to open or close. **Safe from any thread** — it only posts.
pub fn request_toggle() {
    let h = HWND_PALETTE.load(Ordering::Acquire);
    if h.is_null() {
        // process-wide: the palette does not exist yet, so no window can be meant
        plogf!("[palette] toggle before init, ignored");
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_PALETTE_TOGGLE, WPARAM(0), LPARAM(0)) };
}

fn hwnd() -> HWND {
    HWND(HWND_PALETTE.load(Ordering::Acquire))
}

fn show() {
    let me = hwnd();
    if me.0.is_null() {
        return;
    }
    unsafe {
        // Opens over window 1 wherever it was invoked; see `tabs::overlay_frame`.
        let frame = crate::tabs::overlay_frame();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let dpi = GetDpiForWindow(me).max(96);
        let sc = |v: i32| v * dpi as i32 / 96;

        let (w, h) = (sc(WIDTH), sc(EDIT_H + ROW_H * MAX_ROWS + PAD));
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + sc(60);

        PREV_FOCUS.set(GetFocus());
        STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.visible = true;
                refilter(st, "");
            }
        });

        // Clearing the box is a Win32 call and therefore lives outside the
        // borrow -- and here it could not live anywhere else, because `Model`
        // has no window to pass it. `WM_SETTEXT` is delivered synchronously to
        // `edit_proc`, which borrows on its first line.
        if let Some(wins) = windows() {
            let _ = SetWindowTextW(wins.edit, w!(""));
        }

        let _ = SetWindowPos(me, Some(HWND_TOPMOST), x, y, w, h, SWP_SHOWWINDOW);

        // One self-contained line, because a reader must not have to join it
        // to another: "the log said it opened" is compatible with a window
        // that is zero-sized, off-screen, or not actually visible, and each of
        // those looks like a pass. `IsWindowVisible` is the style bit, and the
        // rectangle is where it really landed.
        let mut got = RECT::default();
        let _ = GetWindowRect(me, &mut got);
        let rows = STATE.with(|c| c.borrow().as_ref().map(|s| s.filtered.len()).unwrap_or(0));
        wlogf!(
            frame,
            "[palette] shown at {},{} {}x{} visible={} rows={}",
            got.left,
            got.top,
            got.right - got.left,
            got.bottom - got.top,
            IsWindowVisible(me).as_bool() as u8,
            rows
        );

        if let Some(wins) = windows() {
            // The release-then-focus ordering lives in `overlay.rs` now:
            // three call sites reached it independently, and every way of
            // getting it wrong is silent.
            PREV_FOCUS.set(crate::overlay::focus_to_edit(wins.edit, "palette"));
        }
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
            .map(|st| std::mem::replace(&mut st.visible, false))
            .unwrap_or(false)
    });
    unsafe {
        let _ = ShowWindow(me, SW_HIDE);
        logf!(
            "[palette] hidden, was_up={} visible={}",
            was_up as u8,
            IsWindowVisible(me).as_bool() as u8
        );
    }
    if was_up {
        crate::overlay::focus_back(PREV_FOCUS.get(), "palette");
    }
}

fn run_selected() {
    let action = STATE.with(|c| {
        let b = c.borrow();
        let st = b.as_ref()?;
        let idx = *st.filtered.get(st.selected)?;
        Some(st.commands[idx].action.clone())
    });
    hide();
    if let Some(a) = action {
        let ok = crate::binding(&a);
        logf!("[palette] run {:?} -> binding_action = {}", a, ok);
    }
}

fn move_selection(delta: i32) {
    STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            let n = st.filtered.len();
            if n == 0 {
                return;
            }
            let cur = st.selected as i32;
            let next = (cur + delta).rem_euclid(n as i32) as usize;
            st.selected = next;
            // Keep the selection on screen.
            let rows = MAX_ROWS as usize;
            if next < st.top {
                st.top = next;
            } else if next >= st.top + rows {
                st.top = next + 1 - rows;
            }
        }
    });
    let _ = unsafe { InvalidateRect(Some(hwnd()), None, true) };
}

// ------------------------------------------------------------- window procs

extern "system" fn palette_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_PALETTE_TOGGLE => {
                let vis = STATE.with(|c| c.borrow().as_ref().map(|s| s.visible).unwrap_or(false));
                if vis {
                    hide();
                } else {
                    show();
                }
                LRESULT(0)
            }

            // Clicking elsewhere closes it. Without this the palette would sit
            // on top of the terminal with focus somewhere else, which looks
            // like the app hanging.
            WM_ACTIVATE => {
                if (wp.0 & 0xFFFF) == WA_INACTIVE as usize {
                    let vis =
                        STATE.with(|c| c.borrow().as_ref().map(|s| s.visible).unwrap_or(false));
                    if vis {
                        hide();
                    }
                }
                LRESULT(0)
            }

            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(hwnd);
                LRESULT(0)
            }

            WM_LBUTTONDOWN => {
                let y = ((lp.0 >> 16) & 0xFFFF) as i32;
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                if y > sc(EDIT_H) {
                    let row = (y - sc(EDIT_H)) / sc(ROW_H);
                    let hit = STATE.with(|c| {
                        c.borrow_mut().as_mut().map(|st| {
                            let i = st.top + row.max(0) as usize;
                            if i < st.filtered.len() {
                                st.selected = i;
                                true
                            } else {
                                false
                            }
                        })
                    });
                    if hit == Some(true) {
                        run_selected();
                    }
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

/// The edit control's procedure. Everything not listed falls through to the
/// original, which is what keeps text editing, selection and the IME working.
unsafe extern "system" fn edit_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let old = windows().and_then(|w| w.edit_proc);

    unsafe {
        match msg {
            WM_KEYDOWN => match VIRTUAL_KEY(wp.0 as u16) {
                VK_ESCAPE => {
                    hide();
                    return LRESULT(0);
                }
                VK_RETURN => {
                    run_selected();
                    return LRESULT(0);
                }
                VK_UP => {
                    move_selection(-1);
                    return LRESULT(0);
                }
                VK_DOWN => {
                    move_selection(1);
                    return LRESULT(0);
                }
                _ => {}
            },

            // Swallow the characters that go with the keys above, or the edit
            // control beeps at every Enter and Escape.
            WM_CHAR => {
                let c = wp.0 as u16;
                if c == 0x0D || c == 0x1B {
                    return LRESULT(0);
                }
            }

            _ => {}
        }

        let r = CallWindowProcW(old, hwnd, msg, wp, lp);

        // Re-filter after the control has applied the edit, not before, so the
        // text we read is the text the user now sees.
        if msg == WM_CHAR || msg == WM_PASTE || (msg == WM_KEYDOWN && wp.0 as u16 == VK_BACK.0) {
            let mut buf = [0u16; 256];
            let n = GetWindowTextW(hwnd, &mut buf) as usize;
            let text = String::from_utf16_lossy(&buf[..n]);
            STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    refilter(st, &text);
                }
            });
            let _ = InvalidateRect(Some(crate::palette::hwnd()), None, true);
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

        let bg = CreateSolidBrush(COLORREF(COL_BG));
        FillRect(hdc, &rc, bg);
        let _ = DeleteObject(bg.into());

        SetBkMode(hdc, TRANSPARENT);

        let Some(wins) = windows() else { return };
        STATE.with(|c| {
            let b = c.borrow();
            let Some(st) = b.as_ref() else { return };
            let old_font = SelectObject(hdc, wins.font.into());

            if st.filtered.is_empty() {
                SetTextColor(hdc, COLORREF(COL_DIM));
                let mut wide: Vec<u16> = "no matching command".encode_utf16().collect();
                let mut tr = RECT {
                    left: sc(PAD * 2),
                    top: sc(EDIT_H + PAD),
                    right: rc.right - sc(PAD),
                    bottom: rc.bottom,
                };
                DrawTextW(hdc, &mut wide, &mut tr, DT_LEFT | DT_SINGLELINE);
                SelectObject(hdc, old_font);
                return;
            }

            let rows = MAX_ROWS as usize;
            for (n, &ci) in st.filtered.iter().skip(st.top).take(rows).enumerate() {
                let cmd = &st.commands[ci];
                let idx = st.top + n;
                let y = sc(EDIT_H) + n as i32 * sc(ROW_H);
                let row = RECT {
                    left: 0,
                    top: y,
                    right: rc.right,
                    bottom: y + sc(ROW_H),
                };
                if idx == st.selected {
                    let sel = CreateSolidBrush(COLORREF(COL_ROW_SEL));
                    FillRect(hdc, &row, sel);
                    let _ = DeleteObject(sel.into());
                }

                SetTextColor(hdc, COLORREF(COL_TEXT));
                let mut wide: Vec<u16> = cmd.title.encode_utf16().collect();
                let mut tr = RECT {
                    left: sc(PAD * 2),
                    top: y + sc(4),
                    right: rc.right / 2,
                    bottom: y + sc(ROW_H),
                };
                DrawTextW(
                    hdc,
                    &mut wide,
                    &mut tr,
                    DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS,
                );

                if !cmd.description.is_empty() {
                    SetTextColor(hdc, COLORREF(COL_DIM));
                    let mut dw: Vec<u16> = cmd.description.encode_utf16().collect();
                    let mut dr = RECT {
                        left: rc.right / 2,
                        top: y + sc(4),
                        right: rc.right - sc(PAD * 2),
                        bottom: y + sc(ROW_H),
                    };
                    DrawTextW(
                        hdc,
                        &mut dw,
                        &mut dr,
                        DT_RIGHT | DT_SINGLELINE | DT_END_ELLIPSIS,
                    );
                }
            }
            SelectObject(hdc, old_font);
        });

        let _ = EndPaint(hwnd, &ps);
    }
}

#[cfg(test)]
mod tests {
    use super::score;

    #[test]
    fn empty_needle_matches_everything() {
        assert_eq!(score("new tab", ""), Some(0));
    }

    #[test]
    fn non_subsequence_does_not_match() {
        assert_eq!(score("new tab", "zzz"), None);
        assert_eq!(score("new tab", "bat"), None); // right letters, wrong order
    }

    #[test]
    fn subsequence_matches_out_of_order_positions() {
        assert!(score("new tab", "nt").is_some());
        assert!(score("toggle fullscreen", "tfs").is_some());
    }

    #[test]
    fn prefix_beats_midword() {
        let pre = score("tab: new", "ta").unwrap();
        let mid = score("about tab", "ta").unwrap();
        assert!(pre > mid, "prefix {pre} should beat midword {mid}");
    }

    /// Isolates the start-of-string bonus: both candidates match contiguously
    /// and neither hit is at a word boundary, so contiguity and word-start
    /// cancel out and only the prefix bonus can separate them.
    ///
    /// Added after a mutation run: with only the tests above, zeroing the
    /// prefix bonus changed nothing and every test still passed.
    #[test]
    fn start_of_string_beats_the_same_run_elsewhere() {
        let at_start = score("tab", "ta").unwrap();
        let inside = score("stab", "ta").unwrap();
        assert!(at_start > inside, "start {at_start} should beat inside {inside}");
    }

    #[test]
    fn word_start_beats_midword() {
        let word = score("new tab", "t").unwrap();
        let mid = score("scatter", "t").unwrap();
        assert!(word > mid, "word start {word} should beat midword {mid}");
    }

    #[test]
    fn contiguous_beats_scattered() {
        let together = score("split right", "spl").unwrap();
        let apart = score("select paste left", "spl").unwrap();
        assert!(together > apart, "contiguous {together} vs scattered {apart}");
    }

    #[test]
    fn shorter_wins_when_otherwise_equal() {
        let short = score("new tab", "new").unwrap();
        let long = score("new tab in a very long command name here", "new").unwrap();
        assert!(short > long);
    }
}
