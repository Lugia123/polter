//! The control room's chat page (task 2015; the design's v1 `C1-chat`): a
//! terminal running `polter +chat --group=<group>`, one a group, put where
//! the right side's page goes when the chat page is in front.
//!
//! **Not a pane, the way the quick terminal is not one** (`quick.rs`): the
//! control room's tab has no terminals in it and says so (`Tab::panes`,
//! `dev-docs/windows/control-room.md` §2.1), and a chat surface is not one of
//! anybody's terminals either -- the core leaves it out of `terminal_list`
//! and of the snapshot. It is a `PolterSurface` window of the frame, so the
//! shared window procedure draws it and sends it its keys
//! (`tabs::surface_of` falls through to `surface_of` here), and each place
//! that has to find it asks this module by name:
//!
//!  * `tabs::layout` hands `place` the page's rectangle when the control
//!    room is in front, and none otherwise;
//!  * `cb_close_surface` hands `closed_by_core` a pane id it does not know
//!    -- the chat's TUI ended -- and this module puts it away on the UI thread;
//!  * the control room `prune`s the chats of groups gone from the snapshot,
//!    and `close_all` when its panel goes.
//!
//! **What it speaks as** is the person: `poltergeist_chat = true` makes the
//! core count it as a chat surface (`isChatSurface`), the same flag the
//! menu's chat tab sets (`ACTION_TOGGLE_POLTERGEIST_CHAT`).
//!
//! Four are kept at most; past that, the one looked at longest ago is
//! closed. Main thread only, but for `closed_by_core`.
//!
//! # The keyboard (W4b)
//!
//! A click on a chat is no pane's (`tabs::focus_pane_reached` asks
//! `take_keyboard` before it gives up on a window in no tab); whether the
//! keyboard is in a chat is kept here (`focus_went_to`, from the shared
//! window procedure's `WM_SETFOCUS` and the panel's), and `tabs::focus_active`
//! gives it back to the chat in front when the control room comes back to
//! the front (`keyboard_hwnd`). A chat hidden with the keyboard in it -- its
//! page left, another group's chat shown -- hands it to the panel first, so
//! keys never go into a terminal nobody can see.

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::Mutex;

use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_split_tree::Rect as TreeRect;

use crate::ffi::*;
use crate::{api, plogf, wlogf};

/// The most kept open at once.
pub const KEPT: usize = 4;

/// Posted to the control room's panel when the core closes a chat's
/// surface: `wparam` is its id.
pub const WM_CHAT_GONE: u32 = WM_APP + 72;

struct Chat {
    group: String,
    id: u64,
    hwnd: isize,
    surface: usize,
    /// Its size when it was last placed, in pixels.
    size: (i32, i32),
    /// When it was last in front: what decides which goes past `KEPT`.
    seen: std::time::Instant,
    shown: bool,
}

thread_local! {
    static CHATS: RefCell<Vec<Chat>> = const { RefCell::new(Vec::new()) };
    /// The group whose chat could not be made the last time it was wanted:
    /// not tried again until another is wanted, or every paint would lay the
    /// window out to try (`settled`).
    static FAILED: RefCell<Option<String>> = const { RefCell::new(None) };
    /// The keyboard was last in a chat: given back to the one in front when
    /// the control room is.
    static KEYBOARD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// The focus is being moved off a chat that is being hidden: that move
    /// is not the person leaving the chat.
    static HIDING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// The groups whose chat's program ended: their page says so and opens
    /// nothing until the person asks (`reopen`). Group seq 223, after
    /// 0x4881 saw a new chat opened 30 ms after the last one ended -- one
    /// whose program ends as it starts would be opened for ever.
    static ENDED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

/// Whether `group`'s chat ended and has not been asked for again.
pub fn ended(group: &str) -> bool {
    ENDED.with(|e| e.borrow().iter().any(|g| g == group))
}

/// The person asked for `group`'s chat again: made at the next layout.
pub fn reopen(group: &str) {
    ENDED.with(|e| e.borrow_mut().retain(|g| g != group));
    // process-wide: the chat is the control room's, of which the process has one
    plogf!("[chat-page] chat for {:?} asked for again", group);
}

/// Whether `hwnd` is a chat's window.
pub fn owns(hwnd: HWND) -> bool {
    let key = hwnd.0 as isize;
    CHATS.with(|c| c.try_borrow().is_ok_and(|c| c.iter().any(|x| x.hwnd == key)))
}

/// A click on a chat: the keyboard goes into it.
pub fn take_keyboard(hwnd: HWND) {
    // process-wide: the chat is the control room's, of which the process has one
    plogf!("[chat-page] click on chat window {:?}: the keyboard goes into it", hwnd.0);
    crate::with_host_shuffle(|| unsafe {
        crate::ime_set_window(hwnd);
        let _ = windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(hwnd));
    });
}

/// A window of this thread took the keyboard from `from`: a chat taking it
/// means the keyboard is in one; the panel taking it **from a chat** means
/// the person left it -- unless that chat is being hidden (`HIDING`).
///
/// **Nothing else says anything about the chat** (group seq 250, 274; W4b
/// 3). With the keyboard in a chat, going to another of the window's tabs
/// hides the chat and a terminal there takes the keyboard (W6 stopped that
/// counting); coming back, `tabs::focus_active` hands the panel the keyboard
/// from the window itself *before* `place` shows the chat again -- and W6
/// still counted that as leaving, so `place` had nothing to give back.
pub fn focus_went_to(hwnd: HWND, from: HWND) {
    if HIDING.with(|h| h.get()) {
        return;
    }
    if owns(hwnd) {
        KEYBOARD.with(|k| k.set(true));
    } else if crate::control_room::panel_hwnd() == Some(hwnd) && owns(from) {
        KEYBOARD.with(|k| k.set(false));
    }
}

/// The chat in front, when the keyboard was last in a chat: where
/// `tabs::focus_active` puts it with the control room in front.
pub fn keyboard_hwnd() -> Option<isize> {
    if !KEYBOARD.with(|k| k.get()) {
        return None;
    }
    CHATS.with(|c| c.try_borrow().ok().and_then(|c| c.iter().find(|x| x.shown).map(|x| x.hwnd)))
}

/// `frame` moved to `scale`: its chats are told, as its panes are.
pub fn rescale(frame: HWND, scale: f64) {
    let ours: Vec<usize> = CHATS.with(|c| {
        c.borrow()
            .iter()
            .filter(|x| unsafe { GetParent(HWND(x.hwnd as *mut c_void)) }.ok() == Some(frame))
            .map(|x| x.surface)
            .collect()
    });
    for s in ours {
        unsafe { (api().surface_set_content_scale)(s as Surface, scale, scale) };
    }
}

/// The chats' ids, for `closed_by_core`, which runs on whatever thread the
/// core calls from.
static IDS: Mutex<Vec<(u64, usize)>> = Mutex::new(Vec::new());
/// The control room's panel, where `WM_CHAT_GONE` is posted.
static PANEL: AtomicIsize = AtomicIsize::new(0);

/// The surface bound to `hwnd`, when it is a chat's: null otherwise.
pub fn surface_of(hwnd: HWND) -> Surface {
    let key = hwnd.0 as isize;
    CHATS
        .with(|c| c.try_borrow().ok().and_then(|c| c.iter().find(|x| x.hwnd == key).map(|x| x.surface)))
        .map_or(std::ptr::null_mut(), |s| s as Surface)
}

/// `"<polter-cli.exe>" +chat --group=<group>`, the group quoted as one
/// argument the way `splitWindowsShell` in the core reads it back.
/// `--embedded`: the one group, no list of groups beside it, and no way to
/// another (C2, 8d782a892; group seq 251).
pub fn command(exe: &str, group: &str) -> String {
    let mut arg = String::from("--group=");
    arg.push_str(group);
    format!("\"{exe}\" +chat {} --embedded", quote(&arg))
}

/// One argument for a Windows command line (the `CommandLineToArgvW`
/// rules): in quotes, a quote inside it escaped, and the backslashes before
/// a quote -- or before the closing one -- doubled.
fn quote(arg: &str) -> String {
    let mut out = String::from("\"");
    let mut slashes = 0;
    for c in arg.chars() {
        match c {
            '\\' => slashes += 1,
            '"' => {
                out.extend(std::iter::repeat_n('\\', 2 * slashes + 1));
                out.push('"');
                slashes = 0;
                continue;
            }
            _ => {}
        }
        if c != '\\' {
            out.extend(std::iter::repeat_n('\\', slashes));
            slashes = 0;
            out.push(c);
        }
    }
    out.extend(std::iter::repeat_n('\\', 2 * slashes));
    out.push('"');
    out
}

/// Make `group`'s chat in `frame` at `r`: its window, then its surface, at
/// its final size (`tabs::create_pane` says why the order matters).
fn create(frame: HWND, group: &str, r: TreeRect) -> Option<Chat> {
    let app = crate::app_opt();
    if app.is_null() {
        return None;
    }
    let Some(exe) = crate::own_exe_path().and_then(|e| crate::cli_sibling(&e)) else {
        wlogf!(frame, "[chat-page] {} is not beside this executable; no chat for {:?}", crate::CLI_EXE, group);
        return None;
    };
    let cmd = command(&exe, group);
    let Ok(cmd_c) = std::ffi::CString::new(cmd.clone()) else {
        wlogf!(frame, "[chat-page] the command for {:?} has an interior NUL; not started", group);
        return None;
    };
    let hinst = unsafe { windows::Win32::Foundation::HINSTANCE(GetWindowLongPtrW(frame, GWLP_HINSTANCE) as *mut c_void) };
    let (x, y, w, h) = (r.x as i32, r.y as i32, (r.w as i32).max(1), (r.h as i32).max(1));
    let child = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterSurface"),
            windows::core::PCWSTR::null(),
            WS_CHILD | WS_CLIPSIBLINGS | WS_VISIBLE,
            x,
            y,
            w,
            h,
            Some(frame),
            None,
            Some(hinst),
            None,
        )
    };
    let Ok(child) = child else {
        wlogf!(frame, "[chat-page] its window could not be made for {:?}", group);
        return None;
    };
    let id = crate::tabs::chat_id();
    let scale = crate::dpi_for(frame) as f64 / 96.0;
    let mut sc: SurfaceConfig = unsafe { (api().surface_config_new)() }.with_size(w as u32, h as u32);
    sc.platform_tag = PLATFORM_WIN32;
    sc.platform_hwnd = child.0 as *mut c_void;
    sc.scale_factor = scale;
    // Its id, so that when the TUI ends `cb_close_surface` is handed
    // something this module recognises.
    sc.userdata = id as *mut c_void;
    sc.command = cmd_c.as_ptr();
    sc.poltergeist_chat = true;
    let s = unsafe { (api().surface_new)(app, &sc) };
    if s.is_null() {
        wlogf!(frame, "[chat-page] ghostty_surface_new returned null for {:?}; its window is destroyed", group);
        unsafe {
            let _ = DestroyWindow(child);
        }
        return None;
    }
    unsafe {
        (api().surface_set_content_scale)(s, scale, scale);
        (api().surface_set_size)(s, w as u32, h as u32);
    }
    crate::ime_attach(child);
    crate::dnd::attach(child);
    if let Ok(mut ids) = IDS.lock() {
        ids.push((id, s as usize));
    }
    wlogf!(frame, "[chat-page] chat {} for {:?}: {} (hwnd {:?}, poltergeist_chat=true)", id, group, cmd, child.0);
    Some(Chat { group: group.to_string(), id, hwnd: child.0 as isize, surface: s as usize, size: (w, h), seen: std::time::Instant::now(), shown: true })
}

/// Put one away: hidden, its surface freed, its window destroyed.
fn close(chat: Chat, why: &str) {
    let hwnd = HWND(chat.hwnd as *mut c_void);
    if let Ok(mut ids) = IDS.lock() {
        ids.retain(|(i, _)| *i != chat.id);
    }
    // process-wide: a chat belongs to the control room, of which the process has one
    plogf!("[chat-page] chat {} for {:?} closed: {}", chat.id, chat.group, why);
    unsafe {
        crate::with_host_shuffle(|| {
            let _ = ShowWindow(hwnd, SW_HIDE);
        });
        (api().surface_free)(chat.surface as Surface);
        let _ = DestroyWindow(hwnd);
    }
}

/// The group whose chat is in front now, when one is.
pub fn shown_group() -> Option<String> {
    CHATS.with(|c| c.try_borrow().ok().and_then(|c| c.iter().find(|x| x.shown).map(|x| x.group.clone())))
}

/// Whether what is in front is what `want` says: that chat, or none -- or
/// that chat could not be made, and is not tried again until another group
/// is wanted. False is the control room's cue to lay the window out.
pub fn settled(want: &Option<String>) -> bool {
    if *want == shown_group() {
        return true;
    }
    match want {
        Some(g) => FAILED.with(|f| f.borrow().as_deref() == Some(g.as_str())) || ended(g),
        None => false,
    }
}

/// After `tabs::layout` has placed the panes of `frame`: the chat of the
/// group whose chat page is in front goes at `at` -- made first when it has
/// none -- and every other chat is hidden and told it cannot be seen. `at`
/// is none when the control room is not in front, or not in this frame.
pub fn place(frame: HWND, at: Option<TreeRect>) {
    if let Some(panel) = crate::control_room::panel_hwnd() {
        PANEL.store(panel.0 as isize, Ordering::Release);
    }
    let wanted = at.and(crate::control_room::chat_group()).filter(|_| crate::control_room::frame_of_panel() == Some(frame));
    // Made outside the borrow: making a surface sends messages.
    if let (Some(group), Some(r)) = (wanted.as_ref(), at) {
        let has = CHATS.with(|c| c.borrow().iter().any(|x| &x.group == group));
        let failed = FAILED.with(|f| f.borrow().as_deref() == Some(group.as_str()));
        if !has && !failed && !ended(group) {
            match create(frame, group, r) {
                Some(chat) => CHATS.with(|c| c.borrow_mut().push(chat)),
                None => FAILED.with(|f| *f.borrow_mut() = Some(group.clone())),
            }
        }
    }
    // Another group wanted, or none: the one that failed may be tried again.
    if wanted.is_none() || FAILED.with(|f| f.borrow().as_ref() != wanted.as_ref()) {
        FAILED.with(|f| *f.borrow_mut() = None);
    }
    // What to do with each, worked out under the borrow and done after it.
    let mut show: Vec<(u64, isize, usize, TreeRect, bool)> = Vec::new();
    let mut hide: Vec<(u64, isize, usize)> = Vec::new();
    let mut gone: Vec<Chat> = Vec::new();
    CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let now = std::time::Instant::now();
        for x in c.iter_mut() {
            match (wanted.as_ref(), at) {
                (Some(g), Some(r)) if *g == x.group => {
                    let size = ((r.w as i32).max(1), (r.h as i32).max(1));
                    let resized = size != x.size;
                    x.size = size;
                    x.seen = now;
                    x.shown = true;
                    show.push((x.id, x.hwnd, x.surface, r, resized));
                }
                _ => {
                    if x.shown {
                        hide.push((x.id, x.hwnd, x.surface));
                    }
                    x.shown = false;
                }
            }
        }
        // Past `KEPT`, the ones looked at longest ago go -- never the one
        // in front.
        while c.len() > KEPT {
            let Some(oldest) = c.iter().enumerate().filter(|(_, x)| !x.shown).min_by_key(|(_, x)| x.seen).map(|(i, _)| i) else { break };
            gone.push(c.remove(oldest));
        }
    });
    // A hidden chat with the keyboard in it gives it to the panel first.
    let focused = unsafe { windows::Win32::UI::Input::KeyboardAndMouse::GetFocus() }.0 as isize;
    if hide.iter().any(|(_, h, _)| *h == focused) {
        if let Some(panel) = crate::control_room::panel_hwnd() {
            HIDING.with(|h| h.set(true));
            unsafe {
                let _ = windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(panel));
            }
            HIDING.with(|h| h.set(false));
            wlogf!(frame, "[chat-page] the keyboard was in a chat being hidden; given to the panel");
        }
    }
    unsafe {
        crate::with_host_shuffle(|| {
            for (id, hwnd, surface) in &hide {
                let _ = ShowWindow(HWND(*hwnd as *mut c_void), SW_HIDE);
                (api().surface_set_occlusion)(*surface as Surface, false);
                wlogf!(frame, "[chat-page] chat {} -> hide", id);
            }
        });
        for (id, hwnd, surface, r, resized) in show {
            let hw = HWND(hwnd as *mut c_void);
            // The control room's tab may have gone to another window since
            // this chat was made there: it goes with it.
            if GetParent(hw).ok() != Some(frame) {
                let _ = windows::Win32::UI::WindowsAndMessaging::SetParent(hw, Some(frame));
                wlogf!(frame, "[chat-page] chat {} moved into this window", id);
            }
            let (w, h) = ((r.w as i32).max(1), (r.h as i32).max(1));
            // On top: it lies over the control room's panel, as the
            // supervisor's terminal does.
            let res = SetWindowPos(hw, Some(HWND_TOP), r.x as i32, r.y as i32, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
            let s = surface as Surface;
            if resized {
                (api().surface_set_size)(s, w as u32, h as u32);
            }
            (api().surface_set_occlusion)(s, true);
            (api().surface_refresh)(s);
            wlogf!(frame, "[chat-page] chat {} -> {}x{}+{}+{} ({})", id, w, h, r.x as i32, r.y as i32, if res.is_ok() { "ok" } else { "SetWindowPos FAILED" });
        }
    }
    // **The keyboard goes back into the chat it was in** when the chat is
    // shown again with the panel holding it: the control room's tab coming
    // back gives the panel the keyboard (`tabs::focus_active`) before this
    // places the chat, so `keyboard_hwnd` had no chat in front to name
    // (group seq 250, W4b 3).
    if let Some(chat) = keyboard_hwnd() {
        let panel = crate::control_room::panel_hwnd();
        let focused = unsafe { windows::Win32::UI::Input::KeyboardAndMouse::GetFocus() };
        if panel.is_some() && panel == Some(focused) {
            let hw = HWND(chat as *mut c_void);
            crate::with_host_shuffle(|| unsafe {
                crate::ime_set_window(hw);
                let _ = windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(hw));
            });
            wlogf!(frame, "[chat-page] the keyboard was in this chat when it was hidden; given back to it");
        }
    }
    for chat in gone {
        close(chat, "more than four kept; looked at longest ago");
    }
}

/// The groups whose chats are kept: one whose group `alive` no longer
/// knows -- deleted, renamed, archived -- is closed.
pub fn prune(alive: impl Fn(&str) -> bool) {
    let gone: Vec<Chat> = CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let (keep, gone): (Vec<Chat>, Vec<Chat>) = c.drain(..).partition(|x| alive(&x.group));
        *c = keep;
        gone
    });
    for chat in gone {
        close(chat, "its group is gone");
    }
}

/// Every chat, when the control room's panel goes.
pub fn close_all() {
    let all: Vec<Chat> = CHATS.with(|c| c.borrow_mut().drain(..).collect());
    for chat in all {
        close(chat, "the control room closed");
    }
}

/// `cb_close_surface` was handed `id`: whether it is a chat's. When it is,
/// the panel is told to put it away; that is done on the UI thread. **Any
/// thread.**
pub fn closed_by_core(id: u64) -> bool {
    let ours = IDS.lock().map(|ids| ids.iter().any(|(i, _)| *i == id)).unwrap_or(false);
    if !ours {
        return false;
    }
    let panel = PANEL.load(Ordering::Acquire);
    // process-wide: the callback names no window; the chat is the control room's
    plogf!("[chat-page] the core closed chat {}; telling the panel {:#x}", id, panel);
    tell_panel(panel, id);
    true
}

/// The core's `show_child_exited` for `surface`: whether it is a chat's.
/// When it is, the chat is put away now, as `closed_by_core` does -- **not
/// left showing the exited program until a key is pressed** (group seq
/// 250: the core keeps the surface until then, and the page was blank all
/// that while). A `cb_close_surface` that still comes for it finds nothing.
/// **Any thread.**
pub fn child_exited(surface: Surface) -> bool {
    let key = surface as usize;
    let id = IDS.lock().ok().and_then(|ids| ids.iter().find(|(_, s)| *s == key).map(|(i, _)| *i));
    let Some(id) = id else { return false };
    let panel = PANEL.load(Ordering::Acquire);
    // process-wide: the action names a surface, not a window; the chat is the control room's
    plogf!("[chat-page] chat {}'s program ended; telling the panel {:#x}", id, panel);
    tell_panel(panel, id);
    true
}

fn tell_panel(panel: isize, id: u64) {
    if panel != 0 {
        let _ = unsafe { PostMessageW(Some(HWND(panel as *mut c_void)), WM_CHAT_GONE, WPARAM(id as usize), LPARAM(0)) };
    }
}

/// `WM_CHAT_GONE` arrived: chat `id` is put away. Opened again the next
/// time its page is in front.
pub fn gone(id: u64) {
    let chat = CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let at = c.iter().position(|x| x.id == id)?;
        Some(c.remove(at))
    });
    if let Some(chat) = chat {
        let group = chat.group.clone();
        // With the keyboard in it, the panel takes the keyboard: a window
        // destroyed with the focus leaves the focus nowhere, and every key
        // after it would go nowhere too.
        let focused = unsafe { windows::Win32::UI::Input::KeyboardAndMouse::GetFocus() };
        if focused.0 as isize == chat.hwnd {
            if let Some(panel) = crate::control_room::panel_hwnd() {
                unsafe {
                    let _ = windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(panel));
                }
            }
        }
        close(chat, "its program ended; not opened again until asked");
        ENDED.with(|e| {
            let mut e = e.borrow_mut();
            if !e.contains(&group) {
                e.push(group);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_group_is_one_argument_however_it_is_named() {
        assert_eq!(command(r"C:\Program Files\Polter\polter-cli.exe", "web-app"), r#""C:\Program Files\Polter\polter-cli.exe" +chat "--group=web-app" --embedded"#);
        assert_eq!(quote("--group=a b"), r#""--group=a b""#);
        assert_eq!(quote(r#"--group=say "hi""#), r#""--group=say \"hi\"""#);
        assert_eq!(quote(r"--group=a\"), r#""--group=a\\""#);
        assert_eq!(quote(r"--group=a\b"), r#""--group=a\b""#);
    }
}
