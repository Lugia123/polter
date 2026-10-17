//! A terminal lit up for the person to find: the core's `polter_highlight`
//! (`terminal_highlight`, task 1690; the interface is #1689's
//! `highlight-interface.md`, the design `highlight-v1/README.md`).
//!
//! **Everything about a highlight lives here, and nothing of it in the
//! core.** The core says "light this one for so long, with this label" and
//! reads back what was switched and whether the window came forward; which
//! one is lit, how long is left, the key that ends it and the reason it
//! ended are this file's. One at a time, for the whole process.
//!
//! **What is on screen, and why it is three windows.** A pane is a child
//! window with a GL surface bound to it (`windows/AGENTS.md`), so nothing can
//! be painted over a terminal by the frame. Over it go owned, layered,
//! click-through popups, as `panedrag`'s veils are:
//!
//!  * the **dim**: one window over the content area with the lit pane's
//!    place cut out of its region, black at the theme's `dim` alpha;
//!  * the **edge**: a window over the lit pane whose region is a ring. It
//!    breathes by its window alpha alone, so a breath costs no repaint;
//!  * the **card**: in the pane's middle, painted -- label, title, id, the
//!    countdown bar and how to end it -- with its own edge breathing in step.
//!    A pane too small for it wears the edge alone, thicker, and a small card
//!    at its top right with the label and the seconds (the design's A).
//!
//! The tab strip and a stack's strip read [`tab_breath`] / [`pane_breath`]
//! as they paint: the lit terminal's tab carries a dot and a breathing
//! ground until the end, whichever tab is in front.
//!
//! **The first plain key ends it and goes nowhere** ([`pre_translate`],
//! called by the pump before TSF can see the key): the person was most
//! likely talking to the supervisor, and the keyboard may have moved with
//! the tab. **A chord, and a click on the tab strip, do not end it** -- the
//! person moving to another tab is what the breathing tab is for (the
//! supervisor's option A of 2026-10-18; the design's README ended it on
//! both).
//!
//! **Main thread only.** The op runs on the window thread (`run_ops`), the
//! timer is a thread timer there, and the strips paint there.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_control_room::highlight::{self as rule, Key, Why};
use polter_control_room::look::{font, highlight as h, Rgba, Theme};
use polter_split_tree::PaneId;

use crate::ffi::Surface;
use crate::i18n::{n_, tr};
use crate::tabs::{self, TabId};
use crate::{plogf, wlogf};

/// The dot before the lit terminal's name on its tab, across.
pub const TAB_DOT: f64 = h::TAB_DOT;
/// How often the breath and the countdown move. A breath of 1.2 s in
/// steps of this is smooth enough, and each step is a window alpha and a
/// small card's repaint.
const TICK_MS: u32 = 50;

/// The highlight in progress.
struct Lit {
    frame: isize,
    pane: PaneId,
    surface: usize,
    tab: TabId,
    /// The terminal's id as the core spells it, for the closing line.
    id: String,
    title: String,
    label: Option<String>,
    from_ms: u64,
    until_ms: u64,
    /// Ending by time: when the fade began. The other endings do not fade.
    fading_from: Option<u64>,
}

thread_local! {
    static LIT: RefCell<Option<Lit>> = const { RefCell::new(None) };
    /// The dim, the edge and the card, in that order: made once, hidden
    /// between uses.
    static LAYERS: Cell<[isize; 3]> = const { Cell::new([0; 3]) };
    static TIMER: Cell<usize> = const { Cell::new(0) };
}

fn wall_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn handle_of(v: isize) -> HWND {
    HWND(v as *mut c_void)
}

// ------------------------------------------------------------- the action

/// The op `run_ops` runs for the core's `polter_highlight`: the answer is
/// the JSON the interface's section 2 spells, or a coded refusal.
pub fn light_up(frame: HWND, surface: usize, seconds: u32, label: Option<String>) -> Result<String, String> {
    if seconds == 0 {
        let was = LIT.with(|l| l.borrow().as_ref().is_some_and(|x| x.surface == surface));
        if was {
            finish(Why::Cancelled);
        }
        return Ok(format!("{{\"ended\":{was}}}"));
    }
    let Some(pane_hwnd) = tabs::pane_hwnd_of_surface(surface as Surface) else {
        return Err(crate::layout::coded("NotShown", "that terminal is in no pane of a window"));
    };
    let Some((pane_frame, _, pane)) = tabs::pane_of(pane_hwnd) else {
        return Err(crate::layout::coded("NotShown", "that terminal's pane is in no tab"));
    };
    if pane_frame != frame {
        return Err(crate::layout::coded("NotShown", "that terminal moved to another window"));
    }
    let Some((_, tab)) = tabs::tab_of_surface(surface as Surface) else {
        return Err(crate::layout::coded("NotShown", "that terminal's tab is gone"));
    };

    // One at a time: another terminal's ends now; the same one starts again.
    let replaced = LIT.with(|l| l.borrow().as_ref().filter(|x| x.surface != surface).map(|x| x.surface)).unwrap_or(0);
    if replaced != 0 {
        finish(Why::Replaced);
    }

    // The window, then the tab and the stack, then the foreground, read back.
    let iconic = unsafe { IsIconic(frame) }.as_bool();
    let in_front_before = unsafe { GetForegroundWindow() } == frame;
    let (tab_switched, stack_switched) = tabs::reveal_for_highlight(frame, pane);
    let front = unsafe {
        if iconic {
            let _ = ShowWindow(frame, SW_RESTORE);
        }
        let ok = SetForegroundWindow(frame).as_bool();
        if !IsWindow(Some(frame)).as_bool() {
            wlogf!(frame, "[highlight] the window went while it was being brought forward; front unknown");
            "unknown"
        } else if GetForegroundWindow() == frame {
            if iconic {
                "minimized_restored"
            } else {
                "yes"
            }
        } else {
            flash_taskbar(frame);
            wlogf!(frame, "[highlight] SetForegroundWindow ok={} but another window is in front; the taskbar button flashes", ok as u8);
            "refused"
        }
    };
    let window_switched = iconic || !in_front_before;

    // **From now, whatever the front said**: in front, the person sees it
    // from now; refused, the design counts from the call (README, "Windows
    // 怎么到前台" 4), so `timer` is always running here.
    let from = wall_ms();
    let id = terminal_key(surface);
    let title = tabs::title_of_pane(pane).unwrap_or_else(|| tabs::title_of_tab(tab));
    LIT.with(|l| {
        *l.borrow_mut() = Some(Lit {
            frame: frame.0 as isize,
            pane,
            surface,
            tab,
            id,
            title,
            label,
            from_ms: from,
            until_ms: from + seconds as u64 * 1000,
            fading_from: None,
        })
    });
    ensure_highlight_layers(frame);
    sync_highlight();
    start_highlight_clock();
    Ok(format!(
        "{{\"switched\":{{\"window\":{window_switched},\"tab\":{tab_switched},\"stack\":{stack_switched}}},\"front\":\"{front}\",\"timer\":\"running\",\"replaced\":{replaced}}}"
    ))
}

fn terminal_key(surface: usize) -> String {
    polter_control_room::rules::key(unsafe { (crate::api().surface_poltergeist_id)(surface as Surface) })
}

/// The taskbar button, until the window is brought forward: `notify`'s.
fn flash_taskbar(frame: HWND) {
    let fw = FLASHWINFO {
        cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
        hwnd: frame,
        dwFlags: FLASHW_TRAY | FLASHW_TIMERNOFG,
        uCount: 0,
        dwTimeout: 0,
    };
    let _ = unsafe { FlashWindowEx(&fw) };
}

/// End the highlight in progress, if there is one, and say why.
fn finish(why: Why) {
    let taken = LIT.with(|l| l.borrow_mut().take());
    let Some(was) = taken else { return };
    hide_highlight_layers();
    stop_highlight_clock();
    let frame = handle_of(was.frame);
    unsafe {
        let _ = InvalidateRect(Some(frame), None, false);
    }
    wlogf!(frame, "[highlight] end id={} reason={}", was.id, why.word());
}

// ------------------------------------------------------------ the person

/// What the pump asks of every message before TSF sees it. **True when the
/// message was the key that ended the highlight**, which then goes nowhere.
pub fn pre_translate(msg: &MSG) -> bool {
    let Some(frame) = LIT.with(|l| l.borrow().as_ref().filter(|x| x.fading_from.is_none()).map(|x| x.frame)) else {
        return false;
    };
    let target = msg.hwnd;
    if target.0.is_null() || unsafe { GetAncestor(target, GA_ROOT) }.0 as isize != frame {
        return false;
    }
    match msg.message {
        WM_KEYDOWN | WM_SYSKEYDOWN => {
            let vk = msg.wParam.0 as u16;
            let modifier_only = matches!(vk, 0x10 | 0x11 | 0x12 | 0x5B | 0x5C | 0xA0..=0xA5 | 0x14);
            let held = |v: u16| unsafe { GetKeyState(v as i32) } < 0;
            let chorded = held(VK_CONTROL.0) || held(VK_MENU.0) || held(VK_LWIN.0) || held(VK_RWIN.0);
            match rule::key(modifier_only, chorded) {
                Key::Ignored => false,
                Key::EndAndSwallow => {
                    finish(Why::Key);
                    true
                }
            }
        }
        WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_XBUTTONDOWN => {
            // In a pane: a terminal's window, or the frame below its strip
            // (a pane's title and a stack's strip are painted there). The
            // click goes on to where it was aimed either way.
            let in_a_pane = if target.0 as isize == frame {
                let y = (msg.lParam.0 >> 16) as i16 as i32;
                y >= crate::strip::strip_h(tabs::scale_of(target))
            } else {
                tabs::pane_of(target).is_some()
            };
            if rule::click_ends(in_a_pane) {
                finish(Why::Click);
            }
            false
        }
        _ => false,
    }
}

// --------------------------------------------------------------- the clock

fn start_highlight_clock() {
    if TIMER.get() != 0 {
        return;
    }
    let id = unsafe { SetTimer(None, 0, TICK_MS, Some(highlight_tick)) };
    TIMER.set(id);
}

fn stop_highlight_clock() {
    let id = TIMER.replace(0);
    if id != 0 {
        unsafe {
            let _ = KillTimer(None, id);
        }
    }
}

unsafe extern "system" fn highlight_tick(_h: HWND, _m: u32, _id: usize, _t: u32) {
    let now = wall_ms();
    let state = LIT.with(|l| l.borrow().as_ref().map(|x| (x.pane, x.frame, x.until_ms, x.fading_from)));
    let Some((pane, frame, until, fading)) = state else {
        stop_highlight_clock();
        return;
    };
    // **Closed or moved out is found here, not told.** `free_pane` is
    // called with a window's guard alive (`apply_layout`'s let-else), so a
    // call from it into this file would be a call made under the lock; the
    // next tick is at most `TICK_MS` later.
    if tabs::frame_of_pane(pane).map(|f| f.0 as isize) != Some(frame) {
        finish(Why::Closed);
        return;
    }
    match fading {
        None if now >= until => LIT.with(|l| {
            if let Some(x) = l.borrow_mut().as_mut() {
                x.fading_from = Some(now);
            }
        }),
        Some(f) if now.saturating_sub(f) as f64 >= h::FADE_OUT * 1000.0 => {
            finish(Why::Timeout);
            return;
        }
        _ => {}
    }
    sync_highlight();
}

/// How lit the breathing parts are now, the fade included: 0 when nothing
/// is lit.
fn breath_now(now: u64) -> f64 {
    LIT.with(|l| {
        let l = l.borrow();
        let Some(x) = l.as_ref() else { return 0.0 };
        let t = now.saturating_sub(x.from_ms) as f64 / 1000.0;
        rule::breath(t, h::BREATH_PERIOD, h::BREATH_LOW, h::BREATH_HIGH, crate::control_room_source::animations_on())
    }) * fade_now(now)
}

/// How much of the highlight is left while it fades out at its end: 1
/// until then, and 0 when nothing is lit.
fn fade_now(now: u64) -> f64 {
    LIT.with(|l| match l.borrow().as_ref() {
        None => 0.0,
        Some(x) => match x.fading_from {
            Some(f) => (1.0 - now.saturating_sub(f) as f64 / (h::FADE_OUT * 1000.0)).clamp(0.0, 1.0),
            None => 1.0,
        },
    })
}

/// The tab strip asks, for tab `tab` of `frame`: how lit its dot and its
/// ground are now, or none when it is not the lit terminal's tab.
pub fn tab_breath(frame: HWND, tab: TabId) -> Option<f64> {
    let hit = LIT.with(|l| l.borrow().as_ref().is_some_and(|x| x.frame == frame.0 as isize && x.tab == tab));
    hit.then(|| breath_now(wall_ms()))
}

/// A stack's strip asks, for member `pane` of `frame`.
pub fn pane_breath(frame: HWND, pane: PaneId) -> Option<f64> {
    let hit = LIT.with(|l| l.borrow().as_ref().is_some_and(|x| x.frame == frame.0 as isize && x.pane == pane));
    hit.then(|| breath_now(wall_ms()))
}

/// The accent, as the strips and the layers paint it: the system's, in the
/// shade that reads on this window's ground.
pub fn accent(frame: HWND, a: f64) -> Rgba {
    let c = crate::theme::for_frame(frame).link();
    Rgba { r: (c & 0xff) as u8, g: ((c >> 8) & 0xff) as u8, b: ((c >> 16) & 0xff) as u8, a }
}

/// The lit terminal's tab -- in the window's strip or in a stack's -- at
/// `a` of a breath: the accent behind it at `TAB_GROUND`, and an accent edge
/// `TAB_EDGE` wide round it, the whole of it at `a` (the macOS host's).
/// `ground` is what the tab stands on, for the edge's colour: GDI draws a
/// line in one colour, so its strength is mixed in here.
///
/// # Safety
/// `dc` is a device context the caller is painting into.
pub unsafe fn paint_tab(dc: HDC, r: RECT, radius: i32, frame: HWND, a: f64, ground: Rgba) {
    unsafe {
        crate::control_room::round(dc, r, radius, accent(frame, h::TAB_GROUND * a), None);
        let scale = tabs::scale_of(frame);
        let c = accent(frame, 1.0);
        let mix = |v: u8, g: u8| (g as f64 + (v as f64 - g as f64) * a.clamp(0.0, 1.0)).round() as u8;
        let edge = Rgba { r: mix(c.r, ground.r), g: mix(c.g, ground.g), b: mix(c.b, ground.b), a: 1.0 };
        let width = (h::TAB_EDGE * scale).round().max(1.0) as i32;
        let pen = CreatePen(PS_INSIDEFRAME, width, colorref(edge));
        let old_pen = SelectObject(dc, pen.into());
        let old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
        let _ = RoundRect(dc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
        SelectObject(dc, old_brush);
        SelectObject(dc, old_pen);
        let _ = DeleteObject(pen.into());
    }
}

// -------------------------------------------------------------- the layers

static REGISTERED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn init(hinst: HINSTANCE) {
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        lpfnWndProc: Some(layer_proc),
        hInstance: hinst,
        lpszClassName: w!("PolterHighlight"),
        ..Default::default()
    };
    if unsafe { RegisterClassExW(&wc) } == 0 {
        // absence: means it was not reached -- the class registered.
        // process-wide: one window class for the process
        plogf!("[highlight] RegisterClassExW(PolterHighlight) failed; a highlight will light the tab only");
        return;
    }
    REGISTERED.store(true, std::sync::atomic::Ordering::Release);
}

/// The three windows, owned by `frame`: made the first time, handed to
/// another frame after that.
fn ensure_highlight_layers(frame: HWND) {
    if !REGISTERED.load(std::sync::atomic::Ordering::Acquire) {
        return;
    }
    let mut ls = LAYERS.get();
    for h in ls.iter_mut() {
        if *h != 0 && unsafe { IsWindow(Some(handle_of(*h))) }.as_bool() {
            unsafe { SetWindowLongPtrW(handle_of(*h), GWLP_HWNDPARENT, frame.0 as isize) };
            continue;
        }
        let hinst: HINSTANCE = unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }.map(Into::into).unwrap_or_default();
        let made = unsafe {
            CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                w!("PolterHighlight"),
                None,
                WS_POPUP,
                0,
                0,
                1,
                1,
                Some(frame),
                None,
                Some(hinst),
                None,
            )
        };
        match made {
            Ok(made) => *h = made.0 as isize,
            Err(e) => wlogf!(frame, "[highlight] CreateWindowExW failed: {e:?}; this part of the highlight is not drawn"),
        }
    }
    LAYERS.set(ls);
}

fn hide_highlight_layers() {
    for h in LAYERS.get() {
        if h != 0 {
            unsafe {
                let _ = ShowWindow(handle_of(h), SW_HIDE);
            }
        }
    }
}

/// Where the lit pane's place is in its frame's pixels -- its frame, title
/// included, when it wears one -- or none when it is not on screen: its tab
/// is behind, or the window is minimized.
fn lit_spot(frame: HWND, pane: PaneId, pane_hwnd: HWND) -> Option<RECT> {
    unsafe {
        if IsIconic(frame).as_bool() || !IsWindowVisible(pane_hwnd).as_bool() {
            return None;
        }
    }
    let framed = tabs::window(frame).and_then(|w| {
        w.pane_frames
            .panes
            .iter()
            .find(|p| p.pane == pane || p.stack.as_ref().is_some_and(|s| s.members.get(s.current) == Some(&pane)))
            .map(|p| RECT { left: p.rect.x, top: p.rect.y, right: p.rect.x + p.rect.w, bottom: p.rect.y + p.rect.h })
    });
    framed.or_else(|| {
        let mut r = RECT::default();
        unsafe {
            let _ = GetWindowRect(pane_hwnd, &mut r);
            let mut tl = POINT { x: r.left, y: r.top };
            let mut br = POINT { x: r.right, y: r.bottom };
            let _ = ScreenToClient(frame, &mut tl);
            let _ = ScreenToClient(frame, &mut br);
            Some(RECT { left: tl.x, top: tl.y, right: br.x, bottom: br.y })
        }
    })
}

fn spot_on_screen(frame: HWND, r: RECT) -> RECT {
    let mut tl = POINT { x: r.left, y: r.top };
    unsafe {
        let _ = ClientToScreen(frame, &mut tl);
    }
    RECT { left: tl.x, top: tl.y, right: tl.x + (r.right - r.left), bottom: tl.y + (r.bottom - r.top) }
}

fn place_layer(h: isize, r: RECT) {
    unsafe {
        let _ = SetWindowPos(
            handle_of(h),
            None,
            r.left,
            r.top,
            (r.right - r.left).max(1),
            (r.bottom - r.top).max(1),
            SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW,
        );
    }
}

/// What is drawn over this window's terminal is light or dark as its
/// background is, as the strip is (`termcolor::chrome`).
fn theme_of(frame: HWND) -> &'static Theme {
    crate::termcolor::chrome(frame).theme()
}

fn colorref(c: Rgba) -> COLORREF {
    COLORREF((c.r as u32) | (c.g as u32) << 8 | (c.b as u32) << 16)
}

/// Put the layers where the lit pane is now, as lit as it is now, and
/// repaint what breathes. Every tick: windows move, tabs change, and a
/// layout puts panes elsewhere, and none of them tells this file.
fn sync_highlight() {
    let Some((frame, pane, surface, labelled)) =
        LIT.with(|l| l.borrow().as_ref().map(|x| (handle_of(x.frame), x.pane, x.surface, x.label.is_some())))
    else {
        return;
    };
    let now = wall_ms();
    let a = breath_now(now);
    // The tab strip and the stack's strip breathe in the frame's own paint.
    unsafe {
        let _ = InvalidateRect(Some(frame), None, false);
    }
    let [dim, edge, card] = LAYERS.get();
    let Some(pane_hwnd) = tabs::pane_hwnd_of_surface(surface as Surface) else { return };
    let Some(spot) = lit_spot(frame, pane, pane_hwnd) else {
        // Not on screen: only the tab breathes.
        hide_highlight_layers();
        return;
    };
    let scale = tabs::scale_of(frame);
    let theme = theme_of(frame);
    let fade = fade_now(now);
    let mut client = RECT::default();
    unsafe {
        let _ = GetClientRect(frame, &mut client);
    }
    let content = RECT { top: crate::strip::strip_h(scale), ..client };
    let fits = rule::fits_card(
        (spot.right - spot.left) as f64 / scale,
        (spot.bottom - spot.top) as f64 / scale,
        h::CARD_MIN_PANE_WIDTH,
        h::CARD_MIN_PANE_HEIGHT,
    );

    // The scrim: the content area with the lit place cut out of it. The
    // strip is not covered (the design's B).
    if dim != 0 {
        unsafe {
            let all = CreateRectRgn(0, 0, content.right - content.left, content.bottom - content.top);
            let hole = CreateRectRgn(spot.left - content.left, spot.top - content.top, spot.right - content.left, spot.bottom - content.top);
            let _ = CombineRgn(Some(all), Some(all), Some(hole), RGN_DIFF);
            let _ = DeleteObject(hole.into());
            SetWindowLongPtrW(handle_of(dim), GWLP_USERDATA, colorref(theme.highlight_scrim).0 as isize);
            // The region is the window's from here on; not deleted.
            let _ = SetWindowRgn(handle_of(dim), Some(all), true);
            let _ = SetLayeredWindowAttributes(handle_of(dim), COLORREF(0), (theme.highlight_scrim.a * fade * 255.0).round() as u8, LWA_ALPHA);
            place_layer(dim, spot_on_screen(frame, content));
        }
    }

    if edge != 0 {
        draw_edge(edge, frame, spot, scale, fits, a);
    }

    // The card: in the middle, or the small one at the top right.
    if card != 0 {
        let r = card_rect(spot, scale, fits, labelled);
        unsafe {
            let d = (h::CARD_RADIUS * scale).round() as i32 * 2;
            let rgn = CreateRoundRectRgn(0, 0, r.right - r.left + 1, r.bottom - r.top + 1, d, d);
            let _ = SetWindowRgn(handle_of(card), Some(rgn), true);
            SetWindowLongPtrW(handle_of(card), GWLP_USERDATA, fits as isize);
            let _ = SetLayeredWindowAttributes(handle_of(card), COLORREF(0), (theme.highlight_card.a * fade * 255.0).round() as u8, LWA_ALPHA);
            place_layer(card, spot_on_screen(frame, r));
            let _ = InvalidateRect(Some(handle_of(card)), None, false);
        }
    }
}

thread_local! {
    /// The edge as last worked out, at full strength: its size, its look,
    /// and its premultiplied pixels. A breath only changes how much of it
    /// is shown, so the pixels are worked out again only when the place or
    /// the colour changes.
    static EDGE_PIXELS: RefCell<Option<((i32, i32, bool, u32), Vec<u32>)>> = const { RefCell::new(None) };
}

/// The edge round the lit place, as one bitmap with an alpha of its own:
/// B's line just outside it, or A's thicker ring and its glow. Shown at
/// `a` of its strength -- which is all a breath changes.
fn draw_edge(layer: isize, frame: HWND, spot: RECT, scale: f64, fits: bool, a: f64) {
    let (line, glow) = if fits { (h::EDGE * scale, 0.0) } else { (h::RING_A * scale, h::GLOW_A * scale) };
    let o = (line + glow).ceil() as i32 + 1;
    let (pw, ph) = (spot.right - spot.left, spot.bottom - spot.top);
    let (w, hh) = (pw + 2 * o, ph + 2 * o);
    if w <= 0 || hh <= 0 {
        return;
    }
    let color = accent(frame, 1.0);
    let key = (pw, ph, fits, colorref(color).0);
    let radius = h::EDGE_RADIUS_WINDOWS * scale;
    let pixels = EDGE_PIXELS.with(|c| {
        if let Some((k, px)) = c.borrow().as_ref() {
            if *k == key {
                return px.clone();
            }
        }
        let mut px = vec![0u32; (w * hh) as usize];
        for y in 0..hh {
            for x in 0..w {
                let d = rule::outside(x as f64 + 0.5 - o as f64, y as f64 + 0.5 - o as f64, pw as f64, ph as f64, radius);
                let cover = rule::edge_coverage(d, line, glow);
                if cover > 0.0 {
                    let al = (cover * 255.0).round() as u32;
                    let pm = |v: u8| (v as u32 * al + 127) / 255;
                    px[(y * w + x) as usize] = (al << 24) | (pm(color.r) << 16) | (pm(color.g) << 8) | pm(color.b);
                }
            }
        }
        *c.borrow_mut() = Some((key, px.clone()));
        px
    });
    let at = spot_on_screen(frame, RECT { left: spot.left - o, top: spot.top - o, right: spot.right + o, bottom: spot.bottom + o });
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                // Top-down.
                biHeight: -hh,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut c_void = std::ptr::null_mut();
        if let Ok(bmp) = CreateDIBSection(Some(mem), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            if !bits.is_null() {
                std::ptr::copy_nonoverlapping(pixels.as_ptr(), bits as *mut u32, pixels.len());
            }
            let old = SelectObject(mem, bmp.into());
            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER as u8,
                BlendFlags: 0,
                SourceConstantAlpha: (a.clamp(0.0, 1.0) * 255.0).round() as u8,
                AlphaFormat: AC_SRC_ALPHA as u8,
            };
            let dst = POINT { x: at.left, y: at.top };
            let size = windows::Win32::Foundation::SIZE { cx: w, cy: hh };
            let src = POINT { x: 0, y: 0 };
            let _ = UpdateLayeredWindow(handle_of(layer), Some(screen), Some(&dst), Some(&size), Some(mem), Some(&src), COLORREF(0), Some(&blend), ULW_ALPHA);
            SelectObject(mem, old);
            let _ = DeleteObject(bmp.into());
        }
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        let _ = SetWindowPos(handle_of(layer), None, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}

/// Where the card goes in the place `spot`: its width between the look's
/// least and that fraction of the place, its centre that far down it --
/// or, too small for it, the small one at the top right.
fn card_rect(spot: RECT, scale: f64, fits: bool, labelled: bool) -> RECT {
    let p = |v: f64| (v * scale).round() as i32;
    let (w, hh) = (spot.right - spot.left, spot.bottom - spot.top);
    if fits {
        let cw = p(h::CARD_MIN_WIDTH).min((w as f64 * h::CARD_MAX_WIDTH_FRACTION).round() as i32);
        let ch = p(card_height(labelled)).min(hh - p(8.0));
        let left = spot.left + (w - cw) / 2;
        let top = spot.top + ((hh as f64 * h::CARD_CENTER_Y).round() as i32 - ch / 2).max(0);
        let top = top.min(spot.bottom - ch);
        RECT { left, top, right: left + cw, bottom: top + ch }
    } else {
        let cw = p(160.0).min(w - p(8.0));
        let ch = p(font::BODY * font::LINE_HEIGHT_UI + 8.0);
        let right = spot.right - p(6.0);
        let top = spot.top + p(6.0);
        RECT { left: right - cw, top, right, bottom: top + ch }
    }
}

/// The card's height in points: the label (when there is one), the title,
/// the id, the bar and the hint, with the gaps and the padding the look
/// gives them.
fn card_height(label: bool) -> f64 {
    let lh = font::LINE_HEIGHT_UI;
    let label_h = if label { h::LABEL_SIZE * 1.2 } else { 0.0 };
    h::CARD_PADDING_TOP
        + label_h
        + h::TITLE_GAP
        + h::TITLE_SIZE * lh
        + h::ID_GAP
        + font::BODY * lh
        + h::BAR_GAP
        + h::BAR_HEIGHT
        + h::HINT_GAP
        + font::BODY * lh
        + h::CARD_PADDING_BOTTOM
}

// ----------------------------------------------------------------- paint

extern "system" fn layer_proc(hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hw, &mut ps);
                let mut rc = RECT::default();
                let _ = GetClientRect(hw, &mut rc);
                let [_, _, card] = LAYERS.get();
                if hw.0 as isize == card {
                    paint_card(hw, hdc, rc, GetWindowLongPtrW(hw, GWLP_USERDATA) != 0);
                } else {
                    // The scrim, in the colour it was given. (The edge is
                    // an `UpdateLayeredWindow` bitmap and is never asked.)
                    let b = CreateSolidBrush(COLORREF(GetWindowLongPtrW(hw, GWLP_USERDATA) as u32));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                }
                let _ = EndPaint(hw, &ps);
                LRESULT(0)
            }
            _ => DefWindowProcW(hw, msg, wp, lp),
        }
    }
}

/// The card: what is lit, which terminal it is, how long is left and how to
/// end it -- or, small, the label and the seconds.
unsafe fn paint_card(hw: HWND, hdc: HDC, rc: RECT, full: bool) {
    let Some((frame, title, id, label, from, until)) =
        LIT.with(|l| l.borrow().as_ref().map(|x| (handle_of(x.frame), x.title.clone(), x.id.clone(), x.label.clone(), x.from_ms, x.until_ms)))
    else {
        return;
    };
    let now = wall_ms();
    let theme = theme_of(frame);
    let dpi = unsafe { GetDpiForWindow(hw) }.max(96) as i32;
    let scale = dpi as f64 / 96.0;
    let p = |v: f64| (v * scale).round() as i32;
    let a = breath_now(now);
    let ground = Rgba { a: 1.0, ..theme.highlight_card };
    let accent_full = accent(frame, 1.0);
    let left_s = rule::seconds_left(now, until);
    unsafe {
        let mem = CreateCompatibleDC(Some(hdc));
        let bmp = CreateCompatibleBitmap(hdc, rc.right.max(1), rc.bottom.max(1));
        let old = SelectObject(mem, bmp.into());
        let b = CreateSolidBrush(colorref(ground));
        FillRect(mem, &rc, b);
        let _ = DeleteObject(b.into());
        let radius = p(h::CARD_RADIUS);
        // The accent ring round the card's edge, breathing with the pane's;
        // the hairline inside it.
        if full {
            let ring = p(h::CARD_RING).max(1);
            crate::control_room::round(mem, rc, radius, accent(frame, h::CARD_RING_ALPHA * a), None);
            let inner = RECT { left: rc.left + ring, top: rc.top + ring, right: rc.right - ring, bottom: rc.bottom - ring };
            crate::control_room::round(mem, inner, (radius - ring).max(0), ground, Some(theme.highlight_card_edge));
        } else {
            crate::control_room::round(mem, rc, radius, ground, Some(accent(frame, a)));
        }
        SetBkMode(mem, TRANSPARENT);
        let text = |dc: HDC, s: &str, r: &mut RECT, font: HFONT, color: COLORREF, flags: DRAW_TEXT_FORMAT| {
            let mut wide: Vec<u16> = s.encode_utf16().collect();
            // An empty string must not reach `DrawTextW` (task 1439).
            if wide.is_empty() || r.right <= r.left {
                return;
            }
            let before = SelectObject(dc, font.into());
            SetTextColor(dc, color);
            DrawTextW(dc, &mut wide, r, flags | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
            SelectObject(dc, before);
        };
        let seconds = tr(n_("{} s")).replace("{}", &left_s.to_string());
        let lh = font::LINE_HEIGHT_UI;
        if full {
            let mut y = rc.top + p(h::CARD_PADDING_TOP);
            let (l, r) = (rc.left + p(h::CARD_PADDING_X), rc.right - p(h::CARD_PADDING_X));
            if let Some(label) = label.as_deref() {
                let f = crate::uifont::ui(dpi, h::LABEL_SIZE as i32, FW_BOLD.0 as i32);
                let row = p(h::LABEL_SIZE * 1.2);
                text(mem, label, &mut RECT { left: l, top: y, right: r, bottom: y + row }, f, colorref(accent_full), DT_CENTER | DT_VCENTER);
                let _ = DeleteObject(f.into());
                y += row;
            }
            y += p(h::TITLE_GAP);
            let f = crate::uifont::ui(dpi, h::TITLE_SIZE as i32, FW_SEMIBOLD.0 as i32);
            let row = p(h::TITLE_SIZE * lh);
            text(mem, &title, &mut RECT { left: l, top: y, right: r, bottom: y + row }, f, colorref(theme.text), DT_CENTER | DT_VCENTER);
            let _ = DeleteObject(f.into());
            y += row + p(h::ID_GAP);
            let f = crate::uifont::make(dpi, font::BODY as i32, FW_NORMAL.0 as i32, crate::uifont::mono_face());
            let row = p(font::BODY * lh);
            text(mem, &id, &mut RECT { left: l, top: y, right: r, bottom: y + row }, f, colorref(theme.text_secondary), DT_CENTER | DT_VCENTER);
            let _ = DeleteObject(f.into());
            y += row + p(h::BAR_GAP);
            // The countdown: the track, and the accent over what is left.
            let bh = p(h::BAR_HEIGHT).max(1);
            let track = Rgba { a: 0.18, ..theme.text };
            crate::control_room::round(mem, RECT { left: l, top: y, right: r, bottom: y + bh }, bh / 2, track, None);
            let filled = l + ((r - l) as f64 * rule::bar_fraction(now, from, until)).round() as i32;
            if filled > l {
                crate::control_room::round(mem, RECT { left: l, top: y, right: filled, bottom: y + bh }, bh / 2, accent_full, None);
            }
            y += bh + p(h::HINT_GAP);
            let hint = tr(n_("Press any key or click to end · {} s left")).replace("{}", &left_s.to_string());
            let f = crate::uifont::ui(dpi, font::BODY as i32, FW_NORMAL.0 as i32);
            let row = p(font::BODY * lh);
            text(mem, &hint, &mut RECT { left: l, top: y, right: r, bottom: y + row }, f, colorref(theme.text_secondary), DT_CENTER | DT_VCENTER);
            let _ = DeleteObject(f.into());
        } else {
            let small = match label.as_deref() {
                Some(l) => format!("{l}  {seconds}"),
                None => seconds,
            };
            let f = crate::uifont::ui(dpi, font::BODY as i32, FW_SEMIBOLD.0 as i32);
            text(mem, &small, &mut RECT { left: rc.left + p(8.0), top: rc.top, right: rc.right - p(8.0), bottom: rc.bottom }, f, colorref(accent_full), DT_CENTER | DT_VCENTER);
            let _ = DeleteObject(f.into());
        }
        let _ = BitBlt(hdc, 0, 0, rc.right, rc.bottom, Some(mem), 0, 0, SRCCOPY);
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
    }
}
