//! The persona editor.
//!
//! **The page is a list of rows and the rows are computed by a pure
//! function.** `page()` takes a surface and returns [`Page`]; painting walks
//! it and never decides anything. That split is the only way the substance
//! here is testable at all -- this crate's tests build for Windows but run
//! without a window, so anything decided inside `WM_PAINT` is decided where
//! no test can look. `settings_ui.rs` learned the same thing one page over:
//! its `head_layout` exists because two functions were each holding a copy of
//! one measurement.
//!
//! **What this page may decide: nothing.**
//!
//! | on screen | where it comes from |
//! | --- | --- |
//! | the persona list | the core, through `personas::catalogue` |
//! | what this terminal hands out | the core, through `personas::effective` |
//! | what is installed on this machine | the core, through `personas::installed` |
//! | switching a persona or one item | the core, through `personas::perform` / `toggle` |
//!
//! `dev-docs/poltergeist/personas-contract.md` §① puts storage and the
//! closed-set check in the core and says why: two readers means two
//! validators, and the lax one wins. So there is no path from this file to a
//! file on disk, and that absence is the implementation of roles.md §7's
//! "personas are a user-defined closed set" -- a rule in the program rather
//! than in a prompt.
//!
//! **Three things on this page exist only so that it cannot lie**, and each
//! has a test below rather than only a comment:
//!
//!  * §4's sentence about the read-only list is **on the page**, not in this
//!    comment. Without it a person reads a list with no switches next to it
//!    as a page that is broken.
//!  * "nobody has reported" is drawn differently from "there is nothing".
//!  * a departure from the persona says **which way** it went: added by hand
//!    and switched off by hand need different actions to undo, so one word
//!    for both would be a word that cannot be acted on.

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::VK_ESCAPE;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::personas::{self, Catalogue, Departure, Inventory, Kind};
use crate::plogf;

/// Open or close the page. **`WM_APP + 12`**: `settings_ui.rs` records that 8
/// through 11 are taken, and says why reusing one is only safe because these
/// are posted to a single window each and never broadcast. This window is a
/// different one, so it takes the next free number rather than borrowing.
const WM_PERSONAS_TOGGLE: u32 = WM_APP + 12;

const W: i32 = 720;
const H: i32 = 520;
const LIST_W: i32 = 220;
const ROW_H: i32 = 28;
const PAD: i32 = 12;

// --------------------------------------------------------------- the page

/// What one row of the right-hand pane is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RowKind {
    /// A section heading.
    Heading,
    /// A sentence. Not actionable, and drawn so it does not look it.
    Note,
    /// A skill or a slot this terminal either hands out or does not.
    ///
    /// **`id` and not `name`.** §3.5: the id is the core's, carried through
    /// verbatim into the action string. The name is for the screen only --
    /// sending it instead would be this host inventing an identifier, and
    /// worse, one with no epoch in it, so a click on a stale menu would land
    /// on whatever now sits at that name.
    Toggle { kind: Kind, id: String, on: bool, departed: Option<Departure>, settable: bool },
    /// Something read from outside Polter's reach (§4), or a part of the
    /// persona this page shows but does not switch. **Never actionable.**
    ReadOnly,
    /// Put the effective set back to what the persona declares, §5.2.
    ResetToPersona,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub text: String,
    pub kind: RowKind,
    /// The `aside` is a warning rather than a note. See
    /// `personas::Item::aside_is_warning`.
    pub warn: bool,
    /// The sentence beside a departed toggle, or beside a heading that needs
    /// one. Empty when there is none.
    pub aside: String,
}

/// The whole right-hand pane, plus the list on the left.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Page {
    /// The personas, in the order the file gives them. The contract's §① made
    /// `personas` an array rather than a map for exactly this.
    pub list: Vec<(String, String)>,
    /// A sentence to put where the list would be, when there is no list.
    /// **Empty is not the same as absent**: `list` empty and `list_note`
    /// empty together would be a blank column with nothing saying why.
    pub list_note: String,
    pub rows: Vec<Row>,
}

fn heading(text: String) -> Row {
    Row { text, kind: RowKind::Heading, aside: String::new(), warn: false }
}
fn note(text: String) -> Row {
    Row { text, kind: RowKind::Note, aside: String::new(), warn: false }
}

/// Build the page for one terminal.
///
/// **Pure, and that is the point.** Everything it needs it asks for; nothing
/// it returns depends on a window existing. The tests drive it against a
/// fixed provider, which is the only way the properties above are checked
/// rather than asserted in prose.
pub fn page(surface: personas::Surface) -> Page {
    let mut p = Page::default();
    let st = personas::standing(surface);

    match personas::catalogue(surface) {
        Catalogue::Personas(list) if !list.is_empty() => {
            p.list = list.into_iter().map(|x| (x.key, x.name)).collect();
        }
        Catalogue::NotWired => p.list_note = tr("Nothing has reported which roles exist yet"),
        _ => p.list_note = tr("No roles are defined"),
    }

    // §3.5's error above everything, because it changes what the list below
    // it means. **The core's own words, not a paraphrase**: ours would say
    // that something is wrong, the core's says which line. W3's checklist
    // item 18 asks for exactly this.
    if let Some((kind, text)) = &st.error {
        if let Some(lead) = personas::error_lead_in(*kind) {
            p.rows.push(note(lead));
        }
        if !text.is_empty() {
            p.rows.push(note(text.clone()));
        }
    }
    // §3.2. Shielded is about what may be changed, so it belongs above the
    // things that can be changed.
    if st.shielded {
        p.rows.push(note(tr("Agents are kept out of this terminal, so its role cannot be changed")));
    }
    // §5.3, because it changes how everything under it should be read.
    if !st.agent_present {
        p.rows.push(note(tr("No agent is connected here, so nothing is wearing this yet")));
    }
    if let Some(n) = personas::effect_note(st.host_class) {
        p.rows.push(note(n));
    }

    // §5.2's «put it back». Offered **only when there is something to put
    // back**: a row that is always there says nothing about the state, and
    // the whole of §5.2 is that the state has to be visible.
    let eff = personas::effective(surface);
    if st.key.is_some() && eff.deviated() && !st.shielded {
        p.rows.push(Row {
            text: tr("Reset to the Role"),
            kind: RowKind::ResetToPersona,
            aside: String::new(),
            warn: false,
        });
    }

    p.rows.push(heading(tr("What This Terminal Hands Out")));
    match &eff {
        // The third state again, and its own sentence. Drawing this as an
        // empty list would say this terminal hands out nothing, which is a
        // claim nobody has made.
        personas::Handout::NotReported => {
            p.rows.push(note(tr("Nothing has reported what this terminal hands out yet")))
        }
        h if h.is_empty() => p.rows.push(note(tr("This terminal hands out nothing yet"))),
        personas::Handout::Known { skills, mcp } => {
            p.rows.push(heading(tr("Skills")));
            push_items(&mut p.rows, Kind::Skill, skills, st.shielded);
            p.rows.push(heading(tr("MCP Servers")));
            push_items(&mut p.rows, Kind::Mcp, mcp, st.shielded);
        }
    }

    // The persona's own declaration, for the parts this terminal cannot
    // switch item by item.
    if let Some(sel) = selected_persona(surface, &st) {
        if let Some(prompt) = sel.prompt.as_deref() {
            p.rows.push(heading(tr("Opening Prompt")));
            p.rows.push(Row {
                text: prompt.to_string(),
                kind: RowKind::ReadOnly,
                aside: String::new(),
                warn: false,
            });
        }
        if !sel.hint.is_empty() {
            // §5.1's `hint`. **Read-only here and labelled as the restart
            // half**, because that is what it is: this host does not apply
            // it, and a row that looked switchable would be claiming it did.
            p.rows.push(heading(tr("Only Applied on Restart")));
            for (k, v) in &sel.hint {
                p.rows.push(Row {
                    text: format!("{k}: {v}"),
                    kind: RowKind::ReadOnly,
                    aside: String::new(),
                    warn: false,
                });
            }
        }
    }

    // §4. The list, and the sentence that makes it readable.
    p.rows.push(heading(tr("Installed on This Machine")));
    // **On the page, not in a comment.** A read-only list with no explanation
    // sends a person looking for the switches; the agreed wording says so in
    // the words the user reads.
    // ⚠️ **On one line, and it has to stay on one line.** `i18n.rs`'s scanner
    // -- the thing that checks every msgid this host shows has a translation
    // -- reads line by line and looks for `tr(` and the opening quote
    // together. Wrapped over two lines this string still works and simply
    // stops being checked, which is the quietest way for a phrase to fall out
    // of the catalogue.
    p.rows.push(note(tr("Shown so you can see what a role doesn't cover. Polter doesn't change any of this.")));
    match personas::installed() {
        Inventory::NotReported => {
            p.rows.push(note(tr("Nothing has reported what's installed here yet")))
        }
        Inventory::Known { hosts, complete } => {
            // §4.1. A count taken from an incomplete scan is a lower bound,
            // and a lower bound drawn without saying so looks exactly like a
            // total.
            if !complete {
                // One line: see the note on the §4 sentence above.
                p.rows.push(note(tr("Some agents' configuration couldn't be read, so this count may be low")));
            }
            for h in &hosts {
                p.rows.push(heading(h.label.clone()));
                for (title, sec) in [
                    (tr("Plugins"), &h.plugins),
                    (tr("Skills"), &h.skills),
                    (tr("MCP Servers"), &h.mcp),
                ] {
                    p.rows.push(heading(title));
                    match sec.note() {
                        Some(n) => {
                            // `Failed` carries the core's detail beside our
                            // sentence, for the same reason the parse error
                            // does: ours says something is wrong, the core's
                            // says what.
                            let detail = match sec {
                                personas::Section::Failed(d) => d.clone(),
                                _ => String::new(),
                            };
                            p.rows.push(Row {
                                text: n,
                                kind: RowKind::Note,
                                aside: detail,
                                warn: false,
                            });
                        }
                        None => {
                            if let personas::Section::Read(names) = sec {
                                for n in names {
                                    p.rows.push(Row {
                                        text: n.clone(),
                                        kind: RowKind::ReadOnly,
                                        aside: String::new(),
                                        warn: false,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    p
}

fn push_items(out: &mut Vec<Row>, kind: Kind, items: &[personas::Item], shielded: bool) {
    for i in items {
        out.push(Row {
            text: i.name.clone(),
            aside: i.aside(),
            warn: i.aside_is_warning(),
            kind: RowKind::Toggle {
                kind,
                id: i.id.clone(),
                on: i.on,
                departed: i.departure(),
                // §3.2: a shielded terminal refuses every change, so these
                // are shown and not offered. **Shown, not hidden** -- reading
                // is not changing, and a row that vanishes reads as a feature
                // that was never built.
                settable: !shielded,
            },
        });
    }
}

/// Act on a row. `None` for a row that does nothing.
///
/// **A `ReadOnly` row returns `None` here and not "refused"**: it is not that
/// Polter declined, it is that there is nothing of Polter's to change. §4.
pub fn activate(surface: personas::Surface, row: &Row) -> Option<personas::SetOutcome> {
    match &row.kind {
        // **A row that is shown but not settable answers `None`**, the same
        // as a heading -- not a refusal. §3.2 has the core refuse a shielded
        // terminal too, so this is the door being closed rather than a second
        // rule about who may pass.
        RowKind::Toggle { settable: false, .. } => None,
        RowKind::Toggle { kind, id, on, .. } => {
            Some(personas::toggle(surface, *kind, id, !*on))
        }
        // **Setting the persona again is what resets it.** The contract's ②
        // table says so: "set to a persona" assigns the declaration to the
        // effective set. A separate "reset" action would be a second way to
        // say one thing, and the two would drift.
        RowKind::ResetToPersona => {
            let key = personas::standing(surface).key?;
            Some(personas::send(surface, &personas::action_set(&key)))
        }
        _ => None,
    }
}

/// The persona this terminal was given, out of the catalogue.
fn selected_persona(surface: personas::Surface, st: &personas::Standing) -> Option<personas::Persona> {
    let key = st.key.as_deref()?;
    match personas::catalogue(surface) {
        Catalogue::Personas(v) => v.into_iter().find(|p| p.key == key),
        _ => None,
    }
}

// ------------------------------------------------------------------ window

static HWND_PERSONAS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

#[derive(Default)]
struct State {
    visible: bool,
    page: Page,
    selected: usize,
}

thread_local! {
    static ST: RefCell<State> = RefCell::new(State::default());
}

fn hwnd() -> HWND {
    HWND(HWND_PERSONAS.load(Ordering::Acquire))
}

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_DROPSHADOW,
            lpfnWndProc: Some(personas_proc),
            hInstance: hinst,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            lpszClassName: w!("PolterPersonas"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            // process-wide: registering the window class, once per process
            // absence: means it was not reached -- this line exists only on
            // the failure arm of a call made exactly once at start-up, so a
            // log with no `[persona] ready` in it and no line here means
            // `init` was never called, not that the class registered.
            plogf!("[persona] RegisterClassExW failed");
            return;
        }
        // **No `WS_EX_TOPMOST`**, for the reason `settings_ui.rs` records: it
        // is above *everything*, other programs included. The owner is set
        // when the window is shown.
        let h = match CreateWindowExW(
            WS_EX_TOOLWINDOW,
            w!("PolterPersonas"),
            w!("Polter"),
            WS_POPUP | WS_CLIPCHILDREN,
            0,
            0,
            W,
            H,
            None,
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the personas window, one per process
                plogf!("[persona] CreateWindowExW failed: {e:?}");
                return;
            }
        };
        let sc = (GetDpiForWindow(h)).max(96) as i32;
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
        HWND_PERSONAS.store(h.0, Ordering::Release);
        // process-wide: the window is up; no terminal window is involved
        plogf!("[persona] ready");
    }
}

/// Open or close the page. **Safe from any thread.**
pub fn request_toggle() {
    let h = HWND_PERSONAS.load(Ordering::Acquire);
    if h.is_null() {
        // process-wide: the page was asked for before its window existed.
        // Said rather than dropped: "the row did nothing" and "the window was
        // never created" are different bugs that look the same from the far
        // side of the screen.
        plogf!("[persona] the page was asked for before its window existed");
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_PERSONAS_TOGGLE, WPARAM(0), LPARAM(0)) };
}

fn refresh(win: HWND) {
    let surface = crate::tabs::active_surface(crate::tabs::overlay_frame());
    let p = page(surface);
    // **Counted, not just drawn.** A page with no rows and a page that never
    // asked are the same picture; the numbers are what tell them apart in a
    // log somebody reads later.
    let toggles = p.rows.iter().filter(|r| matches!(r.kind, RowKind::Toggle { .. })).count();
    let readonly = p.rows.iter().filter(|r| r.kind == RowKind::ReadOnly).count();
    crate::hlogf!(
        win,
        "[persona] page built: {} personas, {} rows, {} switchable, {} read-only",
        p.list.len(),
        p.rows.len(),
        toggles,
        readonly
    );
    ST.with(|s| {
        let mut s = s.borrow_mut();
        if s.selected >= p.list.len() {
            s.selected = 0;
        }
        s.page = p;
    });
}

fn show(win: HWND) {
    refresh(win);
    let frame = crate::tabs::overlay_frame();
    let mut rc = RECT::default();
    let _ = unsafe { GetWindowRect(frame, &mut rc) };
    let x = rc.left + ((rc.right - rc.left) - W) / 2;
    let y = rc.top + ((rc.bottom - rc.top) - H) / 3;
    unsafe {
        // Owned rather than topmost: above the terminal it belongs to, behind
        // whatever the person switches to.
        SetWindowLongPtrW(win, GWLP_HWNDPARENT, frame.0 as isize);
        let _ = SetWindowPos(win, None, x, y, W, H, SWP_NOZORDER | SWP_NOACTIVATE);
        let _ = ShowWindow(win, SW_SHOWNA);
        let _ = SetForegroundWindow(win);
        let _ = InvalidateRect(Some(win), None, true);
    }
    ST.with(|s| s.borrow_mut().visible = true);
}

fn hide(win: HWND) {
    let _ = unsafe { ShowWindow(win, SW_HIDE) };
    ST.with(|s| s.borrow_mut().visible = false);
}

fn text_out(hdc: HDC, x: i32, y: i32, w: i32, s: &str, colour: u32, bold: bool) {
    let wide: Vec<u16> = s.encode_utf16().collect();
    let mut r = RECT { left: x, top: y, right: x + w, bottom: y + ROW_H };
    unsafe {
        SetTextColor(hdc, COLORREF(colour));
        SetBkMode(hdc, TRANSPARENT);
        let _ = DrawTextW(
            hdc,
            &mut wide.clone(),
            &mut r,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        );
        let _ = bold;
    }
}

fn paint(win: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(win, &mut ps);
        let mut rc = RECT::default();
        let _ = GetClientRect(win, &mut rc);
        let bg = CreateSolidBrush(COLORREF(0x1E1E1E));
        FillRect(hdc, &rc, bg);
        let _ = DeleteObject(bg.into());
        let old = SelectObject(hdc, HGDIOBJ(FONT.load(Ordering::Acquire)));

        ST.with(|s| {
            let s = s.borrow();
            let mut y = PAD;
            text_out(hdc, PAD, y, LIST_W, &tr("Choose a Role"), 0xC8C8C8, true);
            y += ROW_H;
            if s.page.list.is_empty() {
                text_out(hdc, PAD, y, LIST_W, &s.page.list_note, 0x909090, false);
            }
            for (i, (_k, name)) in s.page.list.iter().enumerate() {
                let colour = if i == s.selected { 0xFFFFFF } else { 0xB0B0B0 };
                text_out(hdc, PAD, y, LIST_W, name, colour, false);
                y += ROW_H;
            }

            let rx = PAD + LIST_W + PAD;
            let rw = (rc.right - rc.left) - rx - PAD;
            let mut y = PAD;
            text_out(hdc, rx, y, rw, &tr("Role Editor"), 0xC8C8C8, true);
            y += ROW_H;
            for row in &s.page.rows {
                let colour = match row.kind {
                    RowKind::Heading => 0xC8C8C8,
                    RowKind::Note => 0x909090,
                    // **Read-only rows are dimmer than switchable ones.** The
                    // sentence above them says Polter does not change them;
                    // drawing them identically would make the sentence the
                    // only difference, and a sentence is easy to miss.
                    RowKind::ReadOnly => 0x808080,
                    // The one action on this page that is not a switch, so
                    // it is drawn as neither a switch nor a note.
                    RowKind::ResetToPersona => 0xD0A000,
                    RowKind::Toggle { on, settable, .. } => {
                        if !settable {
                            0x707070
                        } else if on {
                            0xFFFFFF
                        } else {
                            0x8A8A8A
                        }
                    }
                };
                let line = match &row.kind {
                    RowKind::Toggle { on, .. } => {
                        format!("{} {}", if *on { "[x]" } else { "[ ]" }, row.text)
                    }
                    _ => row.text.clone(),
                };
                text_out(hdc, rx, y, rw, &line, colour, false);
                if !row.aside.is_empty() {
                    // Amber for a departure the user made; **red for a
                    // warning**, which in this window means only one thing --
                    // a slot inside Polter that fell through to pass-through.
                    // Drawing it the same amber as "switched off by hand"
                    // would put a symptom next to a preference.
                    let colour = if row.warn { 0x4040F0 } else { 0xD0A000 };
                    text_out(hdc, rx + rw / 2, y, rw / 2, &row.aside, colour, false);
                }
                y += ROW_H;
            }
        });

        SelectObject(hdc, old);
        let _ = EndPaint(win, &ps);
    }
}

extern "system" fn personas_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        m if m == WM_PERSONAS_TOGGLE => {
            let vis = ST.with(|s| s.borrow().visible);
            if vis {
                hide(win);
            } else {
                show(win);
            }
            LRESULT(0)
        }
        WM_PAINT => {
            paint(win);
            LRESULT(0)
        }
        WM_KEYDOWN if wp.0 as u32 == VK_ESCAPE.0 as u32 => {
            hide(win);
            LRESULT(0)
        }
        // **Hidden, never destroyed.** The window is created once and the
        // frame's own close takes the process with it; destroying it here
        // would leave `HWND_PERSONAS` naming a dead window, and every later
        // `request_toggle` would post into nothing and say nothing.
        WM_CLOSE => {
            hide(win);
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(win, msg, wp, lp) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::personas::{Handout, HostInventory, Item, Persona, Provider, Section, SetOutcome, SlotState, Standing, HostClass};

    struct Fixed {
        cat: Catalogue,
        st: Standing,
        eff: Handout,
        inv: Inventory,
    }

    impl Provider for Fixed {
        fn catalogue(&self, _s: personas::Surface) -> Catalogue {
            self.cat.clone()
        }
        fn standing(&self, _s: personas::Surface) -> Standing {
            self.st.clone()
        }
        fn send(&self, _s: personas::Surface, _a: &str) -> SetOutcome {
            SetOutcome::Applied
        }
        fn effective(&self, _s: personas::Surface) -> Handout {
            self.eff.clone()
        }
        fn installed(&self) -> Inventory {
            self.inv.clone()
        }
    }

    const NO_SURFACE: personas::Surface = std::ptr::null_mut();

    /// See `personas::TEST_LOCK`: the provider is process-wide and these
    /// tests each install their own, so they must not overlap.
    fn serialised() -> std::sync::MutexGuard<'static, ()> {
        personas::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn here() -> Standing {
        Standing {
            key: Some("archer".into()),
            name: Some("Archer".into()),
            deviated: true,
            agent_present: true,
            shielded: false,
            host_class: HostClass::Hot,
            error: None,
        }
    }

    fn install(eff: Handout, inv: Inventory) {
        personas::set_provider(Box::new(Fixed {
            cat: Catalogue::Personas(vec![Persona {
                key: "archer".into(),
                name: "Archer".into(),
                skills: Vec::new(),
                mcp: Vec::new(),
                prompt: None,
                hint: Vec::new(),
            }]),
            st: here(),
            eff,
            inv,
        }));
    }

    /// A skill row. Skills have no slot process, so `slot` is `None` --
    /// spelled out rather than defaulted, because the `Some(Broken)` case is
    /// the one that has to be different.
    fn item(name: &str, on: bool, in_persona: bool) -> Item {
        // The id is shaped like the core's, `<roster>-<index>`, because
        // `activate` carries it into an action string; a fixture with a
        // made-up shape would leave that path untested.
        Item { id: format!("8-{}", name.len()), name: name.into(), on, in_persona, slot: None }
    }

    /// An MCP row, whose slot state is the thing under test.
    fn slot_item(name: &str, on: bool, in_persona: bool, slot: SlotState) -> Item {
        Item {
            id: format!("8-{}", name.len()),
            name: name.into(),
            on,
            in_persona,
            slot: Some(slot),
        }
    }

    fn known(skills: Vec<Item>, mcp: Vec<Item>) -> Handout {
        Handout::Known { skills, mcp }
    }

    fn one_host(plugins: Section, skills: Section, mcp: Section) -> Inventory {
        Inventory::Known {
            hosts: vec![HostInventory {
                key: "claude-code".into(),
                label: "Claude Code".into(),
                plugins,
                skills,
                mcp,
            }],
            complete: true,
        }
    }

    /// ⚠️ **The two directions reach the page as two different sentences.**
    /// Merging them into one "changed" is the thing the agreed wording put
    /// two rows in the table to stop: one is undone by switching something
    /// off, the other by switching it on.
    #[test]
    fn a_departure_says_which_way_it_went() {
        let _g = serialised();
        install(
            known(vec![item("added", true, false), item("removed", false, true)], Vec::new()),
            Inventory::NotReported,
        );
        let p = page(NO_SURFACE);
        let aside = |name: &str| {
            p.rows.iter().find(|r| r.text == name).map(|r| r.aside.clone()).unwrap_or_default()
        };
        let a = aside("added");
        let r = aside("removed");
        assert!(!a.is_empty() && !r.is_empty(), "{p:?}");
        assert_ne!(a, r, "one word for both directions cannot be acted on");
        assert_eq!(a, personas::departure_note(Departure::AddedByHand));
        assert_eq!(r, personas::departure_note(Departure::SwitchedOffByHand));
    }

    /// The floor under the test above: an item that matches its persona --
    /// **in either state** -- carries no sentence at all. Without both cells,
    /// an implementation that marked everything would pass the test above.
    #[test]
    fn an_item_that_matches_its_persona_says_nothing() {
        let _g = serialised();
        install(
            known(vec![item("kept-on", true, true), item("kept-off", false, false)], Vec::new()),
            Inventory::NotReported,
        );
        let p = page(NO_SURFACE);
        for name in ["kept-on", "kept-off"] {
            let r = p.rows.iter().find(|r| r.text == name).unwrap();
            assert_eq!(r.aside, "", "{name}: {r:?}");
        }
    }

    /// §4. **The sentence is on the page**, and the list under it is not
    /// switchable. A test for the sentence alone would pass on a page that
    /// then offered switches next to it.
    #[test]
    fn the_read_only_list_carries_its_sentence_and_offers_nothing_to_switch() {
        let _g = serialised();
        install(
            Handout::NotReported,
            one_host(
                Section::Read(vec!["argus".into()]),
                Section::Read(vec!["argus:terminal".into()]),
                Section::Read(vec!["kanban".into()]),
            ),
        );
        let p = page(NO_SURFACE);
        let sentence =
            tr("Shown so you can see what a role doesn't cover. Polter doesn't change any of this.");
        assert!(p.rows.iter().any(|r| r.text == sentence), "{p:?}");
        for name in ["argus", "argus:terminal", "kanban"] {
            let r = p.rows.iter().find(|r| r.text == name).expect(name);
            assert_eq!(r.kind, RowKind::ReadOnly, "{name}");
            assert_eq!(activate(NO_SURFACE, r), None, "{name} must not be actionable");
        }
    }

    /// The third state is a different sentence from an empty list, and the
    /// empty list is not what is drawn for it.
    #[test]
    fn nobody_reported_is_not_drawn_as_nothing_installed() {
        let _g = serialised();
        install(Handout::NotReported, Inventory::NotReported);
        let unwired = page(NO_SURFACE);
        install(Handout::NotReported, one_host(Section::Absent, Section::Absent, Section::Absent));
        let empty = page(NO_SURFACE);
        let said = tr("Nothing has reported what's installed here yet");
        assert!(unwired.rows.iter().any(|r| r.text == said), "{unwired:?}");
        assert!(!empty.rows.iter().any(|r| r.text == said), "{empty:?}");
        // And the two pages are genuinely different, not merely different in
        // that one sentence -- the second has the three headings under it.
        assert_ne!(unwired.rows.len(), empty.rows.len());
    }

    /// A switchable row asks the core and hands back what the core said --
    /// including «at the next launch», which is the answer §6 needs to
    /// survive all the way out here.
    #[test]
    fn a_switchable_row_asks_the_core_and_relays_the_outcome() {
        let _g = serialised();
        install(
            known(vec![item("recon", true, true)], Vec::new()),
            Inventory::NotReported,
        );
        let p = page(NO_SURFACE);
        let r = p.rows.iter().find(|r| r.text == "recon").unwrap();
        assert_eq!(activate(NO_SURFACE, r), Some(SetOutcome::Applied));
        // A heading is not a switch, and neither is a note.
        let h = p.rows.iter().find(|r| r.kind == RowKind::Heading).unwrap();
        assert_eq!(activate(NO_SURFACE, h), None);
    }

    /// ⚠️ **In this window, `transparent` is a symptom, not a statement.**
    ///
    /// §4.2 lets a slot pass its upstream through only when it never got an
    /// answer -- a terminal started outside Ghostty. The editor only exists
    /// inside Ghostty. So a transparent row **here** means a slot that is
    /// inside Polter fell through to pass-through, which is the hole §4.2 was
    /// written to close. It is marked as a warning; nothing else on the page
    /// is.
    #[test]
    fn a_transparent_slot_in_the_editor_is_marked_as_a_warning() {
        let _g = serialised();
        install(
            known(
                vec![item("recon", true, false)],
                vec![
                    slot_item("loose", true, true, SlotState::Transparent),
                    slot_item("argus", false, true, SlotState::Broken),
                    slot_item("kanban", false, true, SlotState::Withheld),
                ],
            ),
            Inventory::NotReported,
        );
        let p = page(NO_SURFACE);
        let row = |n: &str| p.rows.iter().find(|r| r.text == n).expect(n);

        assert!(row("loose").warn, "a slot inside Polter fell through to pass-through");
        // **The floor, and it is the point.** Everything else that carries a
        // sentence is a preference the user expressed or a server that did
        // not start -- neither is this. If they were all warnings, the one
        // that means something is wrong would sit unnoticed among them.
        assert!(!row("argus").warn, "a broken server is reported, not warned about");
        assert!(!row("kanban").warn);
        assert!(!row("recon").warn, "a departure is the user's own doing");
        assert_eq!(p.rows.iter().filter(|r| r.warn).count(), 1, "{p:?}");
    }

    /// ⚠️ §4.3. **A server that did not start must not be blamed on the
    /// user.**
    ///
    /// A granted slot whose process is broken is `in_persona && !on`, which
    /// by the departure rule alone reads «switched off by hand» -- sending
    /// the user to edit the persona when the persona is fine. This is the
    /// misattribution §4.3 names, and it is one `if` away at all times.
    #[test]
    fn a_broken_server_is_not_reported_as_the_user_switching_it_off() {
        let _g = serialised();
        install(
            known(
                Vec::new(),
                vec![
                    slot_item("argus", false, true, SlotState::Broken),
                    slot_item("kanban", false, true, SlotState::Withheld),
                ],
            ),
            Inventory::NotReported,
        );
        let p = page(NO_SURFACE);
        let aside = |n: &str| {
            p.rows.iter().find(|r| r.text == n).map(|r| r.aside.clone()).unwrap_or_default()
        };
        let broken = aside("argus");
        let withheld = aside("kanban");

        assert_eq!(
            broken,
            tr("This server didn't start. Your role isn't what's withholding it.")
        );
        // **The floor.** The other row has identical `on`/`in_persona` bits
        // and differs only in `slot`, so without it a build that showed the
        // server sentence on every switched-off row would pass the assertion
        // above.
        assert_eq!(withheld, personas::departure_note(Departure::SwitchedOffByHand));
        assert_ne!(broken, withheld);
    }

    /// §4. **Four states, and three sentences.**
    ///
    /// `Absent` and a `Read` that came back empty share one phrase on
    /// purpose: to the user they are one fact. The three that must stay apart
    /// are «we never looked», «we looked and there is nothing» and «we looked
    /// and could not read it» -- the first sends them to check a path, the
    /// last to fix a file, and the middle one nowhere at all.
    #[test]
    fn the_inventory_states_say_which_kind_of_nothing_each_one_is() {
        use personas::Section;
        let unknown = Section::UnknownLocation.note().unwrap();
        let absent = Section::Absent.note().unwrap();
        let empty = Section::Read(Vec::new()).note().unwrap();
        let failed = Section::Failed("permission denied".into()).note().unwrap();

        assert_eq!(absent, empty, "these two are one fact to the user");
        assert_ne!(unknown, absent);
        assert_ne!(unknown, failed);
        assert_ne!(absent, failed);
        // A section with something in it draws the list rather than a
        // sentence about the list.
        assert_eq!(Section::Read(vec!["argus".into()]).note(), None);
    }

    /// The core's own detail reaches the screen beside our sentence for a
    /// section that could not be read -- the same rule the parse error
    /// follows, and for the same reason: ours says something is wrong, the
    /// core's says what.
    #[test]
    fn a_section_that_could_not_be_read_carries_the_cores_detail() {
        let _g = serialised();
        install(
            Handout::NotReported,
            one_host(
                Section::Failed("permission denied".into()),
                Section::Absent,
                Section::Absent,
            ),
        );
        let p = page(NO_SURFACE);
        let row = p
            .rows
            .iter()
            .find(|r| r.text == tr("Couldn't read what's installed here"))
            .expect("the sentence");
        assert_eq!(row.aside, "permission denied");
    }

    /// The third «nothing has reported», and that it is **its own sentence**.
    ///
    /// Three facts -- which roles exist, what this terminal hands out, what is
    /// installed here -- and the agreed table gives each its own phrase. One
    /// phrase for all three would send every reader to the same wrong place.
    #[test]
    fn the_three_nothing_reported_sentences_are_three_different_sentences() {
        let _g = serialised();
        // **The catalogue has to be unreported too**, or the left-hand
        // column has a list and carries no sentence at all -- which is what
        // the first version of this test walked into: `install` hands out a
        // catalogue with a persona in it, so `list_note` was empty and the
        // assertion below read as the sentence being wrong when it was the
        // fixture.
        personas::set_provider(Box::new(Fixed {
            cat: Catalogue::NotWired,
            st: here(),
            eff: Handout::NotReported,
            inv: Inventory::NotReported,
        }));
        let p = page(NO_SURFACE);
        let roles = tr("Nothing has reported which roles exist yet");
        let hands_out = tr("Nothing has reported what this terminal hands out yet");
        let installed = tr("Nothing has reported what's installed here yet");
        assert_ne!(roles, hands_out);
        assert_ne!(hands_out, installed);
        assert_ne!(roles, installed);
        assert!(p.rows.iter().any(|r| r.text == hands_out), "{p:?}");
        assert!(p.rows.iter().any(|r| r.text == installed), "{p:?}");
        assert_eq!(p.list_note, roles);
    }

    /// «nobody has said» against «asked, and it hands out nothing». The two
    /// are different rows, and a build that drew `NotReported` as an empty
    /// list would say the second when it meant the first.
    #[test]
    fn a_face_nobody_read_is_not_drawn_as_a_terminal_that_hands_out_nothing() {
        let _g = serialised();
        install(Handout::NotReported, Inventory::NotReported);
        let unread = page(NO_SURFACE);
        install(known(Vec::new(), Vec::new()), Inventory::NotReported);
        let empty = page(NO_SURFACE);

        let said_nothing = tr("Nothing has reported what this terminal hands out yet");
        let hands_nothing = tr("This terminal hands out nothing yet");
        assert_ne!(said_nothing, hands_nothing);
        assert!(unread.rows.iter().any(|r| r.text == said_nothing));
        assert!(!unread.rows.iter().any(|r| r.text == hands_nothing));
        assert!(empty.rows.iter().any(|r| r.text == hands_nothing));
        assert!(!empty.rows.iter().any(|r| r.text == said_nothing));
    }

    /// §4.1. A count taken from a scan that could not read everything is a
    /// lower bound, **and a lower bound drawn without saying so looks exactly
    /// like a total**.
    #[test]
    fn an_incomplete_scan_says_that_its_numbers_may_be_low() {
        let _g = serialised();
        let with = |complete: bool| {
            personas::set_provider(Box::new(Fixed {
                cat: Catalogue::Empty,
                st: here(),
                eff: Handout::NotReported,
                inv: Inventory::Known {
                    hosts: vec![HostInventory {
                        key: "claude-code".into(),
                        label: "Claude Code".into(),
                        plugins: Section::Absent,
                        skills: Section::Absent,
                        mcp: Section::Absent,
                    }],
                    complete,
                },
            }));
            page(NO_SURFACE)
        };
        let warned = tr("Some agents' configuration couldn't be read, so this count may be low");
        assert!(with(false).rows.iter().any(|r| r.text == warned));
        // The floor: a complete scan does not carry the warning, or the
        // warning would mean nothing.
        assert!(!with(true).rows.iter().any(|r| r.text == warned));
    }

    /// §3.2 on the page, not only on the menu. The rows are **shown and not
    /// offered** -- reading is not changing, and a row that vanished would
    /// read as a feature that was never built.
    #[test]
    fn a_shielded_terminal_shows_its_rows_and_refuses_to_switch_them() {
        let _g = serialised();
        let with = |shielded: bool| {
            personas::set_provider(Box::new(Fixed {
                cat: Catalogue::Personas(vec![Persona {
                    key: "archer".into(),
                    name: "Archer".into(),
                    skills: Vec::new(),
                    mcp: Vec::new(),
                    prompt: None,
                    hint: Vec::new(),
                }]),
                st: Standing { shielded, ..here() },
                eff: known(vec![item("recon", true, true)], Vec::new()),
                inv: Inventory::NotReported,
            }));
            page(NO_SURFACE)
        };

        let on = with(true);
        let row = on.rows.iter().find(|r| r.text == "recon").expect("the row is still shown");
        assert_eq!(activate(NO_SURFACE, row), None, "shielded must not switch");
        assert!(on
            .rows
            .iter()
            .any(|r| r.text
                == tr("Agents are kept out of this terminal, so its role cannot be changed")));

        // The floor: unshielded, the same row does switch. Without it, a
        // build that never switched anything would pass the half above.
        let off = with(false);
        let row = off.rows.iter().find(|r| r.text == "recon").unwrap();
        assert_eq!(activate(NO_SURFACE, row), Some(SetOutcome::Applied));
    }

    /// §6 reaches this page too, not only the menu. The page is where a
    /// person goes to change things, so a page that did not say when the
    /// change happens would be the one place the rule was not kept.
    #[test]
    fn the_page_carries_the_same_timing_sentence_the_menu_does() {
        let _g = serialised();
        personas::set_provider(Box::new(Fixed {
            cat: Catalogue::Empty,
            st: Standing {
                key: None,
                name: None,
                deviated: false,
                agent_present: true,
                shielded: false,
                host_class: HostClass::Cold,
                error: None,
            },
            eff: Handout::NotReported,
            inv: Inventory::NotReported,
        }));
        let p = page(NO_SURFACE);
        let cold = personas::effect_note(HostClass::Cold).unwrap();
        assert!(p.rows.iter().any(|r| r.text == cold), "{p:?}");
    }

    /// An empty left-hand column always says why it is empty. A blank column
    /// with nothing in it is the shape a person reads as a broken window.
    #[test]
    fn an_empty_list_always_says_why() {
        let _g = serialised();
        for cat in [Catalogue::NotWired, Catalogue::Empty] {
            personas::set_provider(Box::new(Fixed {
                cat: cat.clone(),
                st: here(),
                eff: Handout::NotReported,
                inv: Inventory::NotReported,
            }));
            let p = page(NO_SURFACE);
            assert!(p.list.is_empty());
            assert!(!p.list_note.is_empty(), "{cat:?}");
        }
    }
}
