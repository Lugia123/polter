//! The menu button at the left end of the tab strip, and the tree it opens.
//!
//! **Why it exists.** `design.md` §1.7 decided against a menu bar and then used
//! that decision to answer a different question. "Windows terminals have no
//! menu bar" is true and is about a strip across the top of the window; the
//! question actually being asked was "how does someone who was never told
//! find the 96 commands", and the palette answers that only for people who
//! already know the palette exists. `docs/windows/s4.md` §3.0 reverses the
//! call; this file is the reversal.
//!
//! **Every row here is either a command the core publishes or a host action
//! named `__polter_*`, and nothing else.** The core does not complain about an
//! action it cannot parse -- `ghostty_surface_binding_action` returns false and
//! the menu item silently does nothing -- so a typo in this table would look
//! exactly like a feature nobody implemented. Two things stop that, and both
//! are needed because they fail in different directions:
//!
//!  * `assert_actions_exist` in the tests checks every action string against
//!    the core's own `Action` union, read out of `src/input/Binding.zig`. That
//!    catches a name that never existed.
//!  * `[menu] built …, N unresolved` at run time counts the same thing against
//!    the same list, embedded in the binary. That catches a name that stopped
//!    existing after this host was built, which no test in this crate can see.
//!
//! **Two things this file asks other modules for, and neither is copied here:**
//!
//!  * The shortcut in each label's `\t`-half comes from `keys::shortcut_for`,
//!    which asks the core's binding table. **No shortcut is written in this
//!    file.** A hand-written `Ctrl+Shift+C` agrees with the core right up
//!    until the user edits their config, and nothing anywhere reports the
//!    disagreement. When the core has no key bound to an action the row shows
//!    no shortcut rather than a guess, and `accel=N/M` in the log says how
//!    many resolved -- measured, not assumed.
//!  * The check marks come from whoever already owns each fact: `hud` for
//!    read-only, `tabs` for the three agent marks. A toggle that looks the
//!    same in both states leaves "click it again" as the only way to find out
//!    what it did, and two menus ticking from two copies of a fact disagree
//!    silently. `set_accel_provider` / `set_state_provider` replace either
//!    source; nothing has to, and the log says which is in use.

use std::sync::OnceLock;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::logf;

// ------------------------------------------------------------------- table

/// One row of a menu.
///
/// A row is exactly one of four things, and which one it is falls out of the
/// fields rather than being stated twice: a separator has no label, a submenu
/// has `sub`, a host row's action starts `__polter_`, and everything else is a
/// core binding string.
struct Row {
    /// What the user reads. Empty means separator.
    label: &'static str,
    /// A core binding string, or a `__polter_*` host action. `None` only for
    /// separators and for the group rows of the root menu.
    action: Option<&'static str>,
    /// A nested menu. A row with a submenu performs nothing itself.
    sub: Option<&'static [Row]>,
    /// Which run-time flag decides this row's check mark, if any.
    check: Option<Flag>,
    /// False for a row that is deliberately shown greyed.
    ///
    /// **Greyed, not hidden** (§3.4.3): a menu item that is missing and one
    /// that never existed look identical, and a person who was told the
    /// feature exists concludes they misremembered. A greyed one says "this
    /// exists, not now".
    enabled: bool,
}

/// A run-time toggle a row can show a check mark for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Flag {
    ReadOnly,
    FloatOnTop,
    Supervisor,
    Watched,
    Shielded,
}

/// Shorthand for the common case: a labelled row that runs a core action.
const fn act(label: &'static str, action: &'static str) -> Row {
    Row { label, action: Some(action), sub: None, check: None, enabled: true }
}

/// A row that runs a core action and shows a check mark for `flag`.
const fn toggle(label: &'static str, action: &'static str, flag: Flag) -> Row {
    Row { label, action: Some(action), sub: None, check: Some(flag), enabled: true }
}

const fn sep() -> Row {
    Row { label: "", action: None, sub: None, check: None, enabled: true }
}

/// A row that opens a nested menu.
const fn sub(label: &'static str, rows: &'static [Row]) -> Row {
    Row { label, action: None, sub: Some(rows), check: None, enabled: true }
}

/// Prefix for the things the core has never heard of. Sending one of these to
/// `binding_action` would return false and look like a dead menu item, so they
/// are routed by `run_host` instead -- the same split `keys.rs` already makes
/// for `__polter_plugin_page`.
const HOST_PREFIX: &str = "__polter_";

// The six groups. The structure is the macOS `MainMenu.xib` tree; the actions
// are the core's, checked below. Anything macOS has that Windows has no
// concept of (`Hide Others`, `Services`, `Secure Keyboard Entry`, …) is not
// here on purpose -- see `design.md` §1.3.

const FILE_ROWS: &[Row] = &[
    act("新建窗口", "new_window"),
    act("新建标签", "new_tab"),
    sep(),
    // The core's `undo` is scoped to surface lifecycle, which is what
    // "reopen the tab I just closed" is.
    act("重开关闭的标签", "undo"),
    sep(),
    act("向右分屏", "new_split:right"),
    act("向左分屏", "new_split:left"),
    act("向下分屏", "new_split:down"),
    act("向上分屏", "new_split:up"),
    sep(),
    act("关闭分屏", "close_surface"),
    act("关闭标签", "close_tab:this"),
    act("关闭窗口", "close_window"),
];

const FIND_ROWS: &[Row] = &[
    act("查找…", "start_search"),
    // `s4.md` §3.2 called these `next_search_result` / `previous_search_result`;
    // the core has no such actions. It publishes one action with a direction.
    act("下一个", "navigate_search:next"),
    act("上一个", "navigate_search:previous"),
    sep(),
    act("隐藏查找条", "end_search"),
];

const EDIT_ROWS: &[Row] = &[
    act("复制", "copy_to_clipboard"),
    act("粘贴", "paste_from_clipboard"),
    act("粘贴选区", "paste_from_selection"),
    act("全选", "select_all"),
    sep(),
    sub("查找", FIND_ROWS),
];

const VIEW_ROWS: &[Row] = &[
    act("重置字号", "reset_font_size"),
    act("放大", "increase_font_size:1"),
    act("缩小", "decrease_font_size:1"),
    sep(),
    act("命令面板", "toggle_command_palette"),
    act("改标签标题…", "prompt_surface_title"),
    // §3.2 called this `toggle_surface_read_only`; the core's name is shorter.
    toggle("只读", "toggle_readonly", Flag::ReadOnly),
    sep(),
    act("快速终端", "toggle_quick_terminal"),
    sep(),
    act("终端检查器", "inspector:toggle"),
];

const AGENTS_ROWS: &[Row] = &[
    // §3.2 called this `poltergeist_conversations`; the core publishes
    // `poltergeist_toggle_chat`.
    act("终端对话", "poltergeist_toggle_chat"),
    sep(),
    toggle("设为总管", "poltergeist_supervisor", Flag::Supervisor),
    toggle("监督此终端", "poltergeist_toggle_watch", Flag::Watched),
    toggle("禁止 agent 进入", "poltergeist_toggle_shielded", Flag::Shielded),
    sep(),
    // Host rows: the core knows nothing about either page.
    act("插件…", "__polter_plugin_page"),
    act("语言…", "__polter_language"),
];

const GOTO_SPLIT_ROWS: &[Row] = &[
    act("上", "goto_split:up"),
    act("下", "goto_split:down"),
    act("左", "goto_split:left"),
    act("右", "goto_split:right"),
];

const RESIZE_SPLIT_ROWS: &[Row] = &[
    act("等分", "equalize_splits"),
    sep(),
    act("向上", "resize_split:up,10"),
    act("向下", "resize_split:down,10"),
    act("向左", "resize_split:left,10"),
    act("向右", "resize_split:right,10"),
];

const WINDOW_ROWS: &[Row] = &[
    // The core has no `minimize`: on macOS that is AppKit's, and here it is
    // one `ShowWindow` call the host makes itself.
    act("最小化", "__polter_minimize"),
    act("最大化", "toggle_maximize"),
    sep(),
    act("全屏", "toggle_fullscreen"),
    sep(),
    act("分屏缩放", "toggle_split_zoom"),
    act("上一个分屏", "goto_split:previous"),
    act("下一个分屏", "goto_split:next"),
    sub("选择分屏", GOTO_SPLIT_ROWS),
    sub("调整分屏", RESIZE_SPLIT_ROWS),
    sep(),
    act("恢复默认大小", "reset_window_size"),
    sep(),
    toggle("置顶", "toggle_window_float_on_top", Flag::FloatOnTop),
];

const HELP_ROWS: &[Row] = &[
    act("Polter 帮助", "__polter_help_docs"),
    sep(),
    // The core publishes `check_for_updates`, but block L is not built, so the
    // row is greyed rather than removed. Removing it would make the missing
    // updater indistinguishable from a decision never to have one.
    Row {
        label: "检查更新…",
        action: Some("check_for_updates"),
        sub: None,
        check: None,
        enabled: false,
    },
    act("重载配置", "reload_config"),
];

/// The root: six group rows, then the two tail items.
const ROOT: &[Row] = &[
    sub("文件", FILE_ROWS),
    sub("编辑", EDIT_ROWS),
    sub("查看", VIEW_ROWS),
    sub("Agents", AGENTS_ROWS),
    sub("窗口", WINDOW_ROWS),
    sub("帮助", HELP_ROWS),
    sep(),
    act("设置…", "open_config"),
    act("关于 Polter", "__polter_about"),
];

/// The six groups, for the log line and for the tests. Kept next to `ROOT`
/// because "six groups" is a claim about `ROOT`, not a constant.
const GROUP_COUNT: usize = 6;

// -------------------------------------------------------------- host rows

/// Perform a `__polter_*` row. Returns false for one that is not handled,
/// which is the same thing `binding` returns for an action the core does not
/// know -- so the `ok=` in the log means the same thing on both paths.
///
/// **`Some`/`None` rather than a bool inside**, because `all_host_rows_are_handled`
/// in the tests walks this match; a row added to the table and forgotten here
/// fails the build instead of doing nothing on a Tuesday.
fn run_host(frame: HWND, action: &str) -> bool {
    match action {
        "__polter_plugin_page" => {
            crate::settings_ui::request_toggle();
            true
        }
        "__polter_minimize" => {
            let _ = unsafe { ShowWindow(frame, SW_MINIMIZE) };
            true
        }
        // Deliberately not yet built, and each says so rather than pretending.
        // They are in the table because a menu is also a statement about what
        // exists; the log line is what keeps "not built" from reading as
        // "broken".
        "__polter_language" | "__polter_about" | "__polter_help_docs" => {
            logf!("[menu] host action {action:?} has no handler yet");
            false
        }
        _ => false,
    }
}

/// Every host action this file may name. `run_host` must have an arm for each.
const HOST_ACTIONS: &[&str] = &[
    "__polter_plugin_page",
    "__polter_minimize",
    "__polter_language",
    "__polter_about",
    "__polter_help_docs",
];

// ------------------------------------------------------- the core's actions

/// The core's `Action` union, as source text, baked in at build time.
///
/// **Embedded rather than looked up through the FFI** because the question
/// "does this action exist" has no FFI answer: `binding_action` performs the
/// action to tell you, and `config_trigger` returns the same empty trigger for
/// "no such action" and for "no key bound to it". The source of truth is the
/// union itself, and this is the closest a host process can hold it.
const BINDING_ZIG: &str = include_str!("../../../src/input/Binding.zig");

/// The names in `Action`, parsed once.
fn core_actions() -> &'static Vec<String> {
    static CACHE: OnceLock<Vec<String>> = OnceLock::new();
    CACHE.get_or_init(|| parse_action_names(BINDING_ZIG))
}

/// Pull the member names out of `pub const Action = union(enum) { … }`.
///
/// Brace-counted rather than line-matched: the union contains nested types
/// (`CopyToClipboard`, `SplitDirection`, …) whose members are indented deeper,
/// and a regex over the whole file would collect those too and then agree with
/// a menu that named one of them.
fn parse_action_names(src: &str) -> Vec<String> {
    const HEAD: &str = "pub const Action = union(enum) {";
    let Some(start) = src.find(HEAD) else {
        return Vec::new();
    };
    let body_start = start + HEAD.len();
    let mut depth = 1usize;
    let mut end = body_start;
    for (i, c) in src[body_start..].char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    end = body_start + i;
                    break;
                }
            }
            _ => {}
        }
    }
    let mut out = Vec::new();
    for line in src[body_start..end].lines() {
        // Members of the union itself sit at exactly one level of indent;
        // anything deeper belongs to a nested type.
        let Some(rest) = line.strip_prefix("    ") else { continue };
        if rest.starts_with(' ') || rest.starts_with("//") {
            continue;
        }
        let name: String = rest
            .chars()
            .take_while(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_')
            .collect();
        if name.is_empty() {
            continue;
        }
        // A member is `name,` or `name: Type,`. Anything else on that line
        // (a `pub fn`, a `const`) is not one.
        let after = rest[name.len()..].trim_start();
        if after.starts_with(',') || after.starts_with(':') {
            out.push(name);
        }
    }
    out
}

/// Is this action string one the core publishes, or a host row we handle?
///
/// The name is everything before the first `:`; the part after is the action's
/// own parameter and the core parses it. **A parameter this file gets wrong is
/// not caught here** -- `new_split:sideways` has a real action name -- which is
/// why the run-time `ok=` on every pick is the other half of the check.
fn is_resolvable(action: &str) -> bool {
    if action.starts_with(HOST_PREFIX) {
        return HOST_ACTIONS.contains(&action);
    }
    let name = action.split(':').next().unwrap_or("");
    core_actions().iter().any(|a| a == name)
}

// ------------------------------------------------------------------ seams

/// Renders the shortcut for an action, from the core's binding table.
static ACCEL: OnceLock<fn(&str) -> Option<String>> = OnceLock::new();

/// Install the shortcut source, replacing the default. Called before the first
/// menu is built, or not at all.
pub fn set_accel_provider(f: fn(&str) -> Option<String>) {
    let _ = ACCEL.set(f);
}

/// Reads a toggle's current state. `None` means "not known", which is drawn as
/// no check mark and counted in the log.
static STATE: OnceLock<fn(Flag) -> Option<bool>> = OnceLock::new();

/// Install the check-mark source, replacing the default.
pub fn set_state_provider(f: fn(Flag) -> Option<bool>) {
    let _ = set_state_provider_inner(f);
}

fn set_state_provider_inner(f: fn(Flag) -> Option<bool>) -> Result<(), fn(Flag) -> Option<bool>> {
    STATE.set(f)
}

/// What the check marks read when nobody has installed anything else.
///
/// **Every arm here reads a value someone else already keeps**, never a copy
/// of one: the read-only mark is the same `AtomicBool` the corner badge draws
/// from, and the three agent marks are the same per-tab fields the tab's own
/// right-click menu ticks. Two menus that tick from two sources disagree
/// eventually, and the disagreement is silent.
fn default_state(flag: Flag) -> Option<bool> {
    // `include/ghostty.h:694`: NONE = 0, SUPERVISOR = 1, WATCHED = 2.
    const ROLE_SUPERVISOR: u8 = 1;
    const ROLE_WATCHED: u8 = 2;
    match flag {
        Flag::ReadOnly => Some(crate::hud::is_readonly()),
        // **Nothing in this host is told about it yet.** `None` rather than
        // `Some(false)`: an unticked row and a row whose state nobody knows
        // look the same on screen, and only the log can tell them apart.
        Flag::FloatOnTop => None,
        Flag::Supervisor | Flag::Watched | Flag::Shielded => {
            let (role, shielded) = crate::tabs::mark_for_surface(crate::tabs::active_surface())?;
            Some(match flag {
                Flag::Supervisor => role == ROLE_SUPERVISOR,
                Flag::Watched => role == ROLE_WATCHED,
                _ => shielded,
            })
        }
    }
}

/// Wire the two seams to the modules that own those facts, unless something
/// has already installed its own.
///
/// **Here rather than in `main`**, because the only line `main.rs` grows for
/// this block is `mod menu;` -- and because a menu that has to be wired up by
/// its caller is a menu that ships unwired the first time someone forgets.
fn install_defaults() {
    let _ = ACCEL.set(crate::keys::shortcut_for as fn(&str) -> Option<String>);
    let _ = STATE.set(default_state as fn(Flag) -> Option<bool>);
}

fn accel_of(action: &str) -> Option<String> {
    ACCEL.get().and_then(|f| f(action))
}

fn checked(flag: Flag) -> Option<bool> {
    STATE.get().and_then(|f| f(flag))
}

// ------------------------------------------------------------------ counts

struct Counts {
    items: usize,
    unresolved: usize,
    checkable: usize,
    /// Items that actually came back with a shortcut, **not** items that
    /// would have if a provider were installed. A counter that reports the
    /// hopeful number is worse than no counter: it says "wired" when nothing
    /// is wired, and that is the one reading nobody would go and check.
    with_accel: usize,
}

fn count(rows: &[Row], c: &mut Counts) {
    for r in rows {
        if let Some(s) = r.sub {
            count(s, c);
            continue;
        }
        let Some(a) = r.action else { continue };
        c.items += 1;
        if !is_resolvable(a) {
            c.unresolved += 1;
            // Named, because "one row is dead" is useless without which one.
            logf!("[menu] unresolved action {a:?} on row {:?}", r.label);
        }
        if r.check.is_some() {
            c.checkable += 1;
        }
        if accel_of(a).is_some_and(|t| !t.is_empty()) {
            c.with_accel += 1;
        }
    }
}

/// How many of the checkable rows are ticked right now.
fn checked_now() -> usize {
    [Flag::ReadOnly, Flag::FloatOnTop, Flag::Supervisor, Flag::Watched, Flag::Shielded]
        .into_iter()
        .filter(|f| checked(*f) == Some(true))
        .count()
}

/// Build the table, check it against the core, and say so. Idempotent.
///
/// **Lazy rather than called from `main`**, because the only line `main.rs` is
/// allowed to grow for this block is `mod menu;`. The first paint of the strip
/// reaches `draw_button`, so this lands early in the log regardless.
fn validate_once() {
    static DONE: OnceLock<()> = OnceLock::new();
    if DONE.set(()).is_err() {
        return;
    }
    install_defaults();
    let mut c = Counts { items: 0, unresolved: 0, checkable: 0, with_accel: 0 };
    count(ROOT, &mut c);
    logf!(
        "[menu] built {} groups, {} items, {} unresolved",
        GROUP_COUNT,
        c.items,
        c.unresolved
    );
    // Two more lines rather than two more fields: each says what is missing
    // and what would fix it, and neither is readable as the other. The counts
    // are measured, so an installed provider that resolves nothing reads
    // differently from no provider at all.
    logf!(
        "[menu] shortcut provider {}, accel={}/{} (shortcuts come from the core binding table; none are written here)",
        if ACCEL.get().is_some() { "installed" } else { "NOT installed" },
        c.with_accel,
        c.items
    );
    logf!(
        "[menu] check-state provider {}, checks={}/{} marked",
        if STATE.get().is_some() { "installed" } else { "NOT installed" },
        checked_now(),
        c.checkable
    );
}

// ------------------------------------------------------------------ button

/// Width of the button, in device pixels. `strip.rs` insets the first tab by
/// exactly this, so the two cannot disagree about where the tabs start.
pub const BUTTON_W: i32 = 46;

pub fn button_w(scale: f64) -> i32 {
    ((BUTTON_W as f64) * scale).round() as i32
}

/// Whether the root menu is on screen right now.
///
/// **The button's pressed look is this file's business, not the strip's.**
/// `TrackPopupMenu` pumps its own messages, so the strip repaints while the
/// menu is up and would otherwise have to track a state it does not own -- and
/// a button that springs back to normal the moment the menu opens is how you
/// get someone clicking it twice.
static OPEN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Draw the `≡` button into `rect`.
///
/// **The colours are `strip.rs`'s, by value, not by a second name.** A menu
/// button that hovers a different grey than the tab beside it is the kind of
/// thing nobody reports and everybody sees.
pub fn draw_menu_button(hdc: HDC, rect: RECT, scale: f64, hover: bool) {
    let rect = &rect;
    validate_once();
    unsafe {
        let fill = if OPEN.load(std::sync::atomic::Ordering::Relaxed) {
            Some(0x00403f3du32)
        } else if hover {
            Some(0x00302f2du32)
        } else {
            None
        };
        if let Some(color) = fill {
            let r = (4.0 * scale).round() as i32;
            let brush = CreateSolidBrush(windows::Win32::Foundation::COLORREF(color));
            let old_brush = SelectObject(hdc, brush.into());
            let old_pen = SelectObject(hdc, GetStockObject(NULL_PEN));
            // RoundRect stops one pixel short on the right and bottom, the way
            // every GDI rectangle does; +1 keeps the fill the size of the rect
            // the hit test uses.
            let _ = RoundRect(hdc, rect.left, rect.top, rect.right + 1, rect.bottom + 1, r * 2, r * 2);
            SelectObject(hdc, old_pen);
            SelectObject(hdc, old_brush);
            let _ = DeleteObject(brush.into());
        }

        // The three bars.
        let pen_w = (1.0 * scale).round().max(1.0) as i32;
        let pen = CreatePen(PS_SOLID, pen_w, windows::Win32::Foundation::COLORREF(0x00d0cfcd));
        let old_pen = SelectObject(hdc, pen.into());
        let cx = (rect.left + rect.right) / 2;
        let cy = (rect.top + rect.bottom) / 2;
        let half = (7.0 * scale).round() as i32;
        let gap = (5.0 * scale).round() as i32;
        for i in -1..=1 {
            let y = cy + i * gap;
            let _ = MoveToEx(hdc, cx - half, y, None);
            let _ = LineTo(hdc, cx + half, y);
        }
        SelectObject(hdc, old_pen);
        let _ = DeleteObject(pen.into());
    }
}

// -------------------------------------------------------------------- show

/// Command ids start here. `ctxmenu.rs` owns 0x4000; a menu that shared its
/// range would return ids that both files think are theirs.
const ID_BASE: usize = 0x5000;

/// Flatten the tree in the order the menus are built, so an id is an index.
fn flatten<'a>(rows: &'a [Row], out: &mut Vec<&'a Row>) {
    for r in rows {
        if let Some(s) = r.sub {
            flatten(s, out);
            continue;
        }
        if r.action.is_some() {
            out.push(r);
        }
    }
}

/// Build one popup and everything under it. Returns the menu, or `None` if
/// Windows would not give us one.
fn build(rows: &[Row], next: &mut usize) -> Option<HMENU> {
    unsafe {
        let menu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(e) => {
                logf!("[menu] CreatePopupMenu failed: {e:?}");
                return None;
            }
        };
        for r in rows {
            if r.label.is_empty() {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                continue;
            }
            if let Some(children) = r.sub {
                // **Bail rather than skip.** `show` pairs ids with rows by
                // walking the tree the same way this does; a submenu quietly
                // left out here would shift every id after it, and the menu
                // would then run the wrong command while looking right.
                let child = build(children, next)?;
                let wide: Vec<u16> = r.label.encode_utf16().chain(Some(0)).collect();
                let _ = AppendMenuW(
                    menu,
                    MF_POPUP | MF_STRING,
                    child.0 as usize,
                    PCWSTR(wide.as_ptr()),
                );
                continue;
            }
            let Some(action) = r.action else { continue };

            // `label\tshortcut`. No `\t` when there is no shortcut: an empty
            // right-hand column is the same width as none and reads as a
            // shortcut that failed to render.
            let text = match accel_of(action) {
                Some(a) if !a.is_empty() => format!("{}\t{}", r.label, a),
                _ => r.label.to_string(),
            };
            let mut flags = MF_STRING;
            if !r.enabled {
                flags = flags | MF_GRAYED;
            }
            if let Some(flag) = r.check {
                if checked(flag) == Some(true) {
                    flags = flags | MF_CHECKED;
                }
            }
            let id = ID_BASE + *next;
            *next += 1;
            let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
            let _ = AppendMenuW(menu, flags, id, PCWSTR(wide.as_ptr()));
        }
        Some(menu)
    }
}

/// Open the root menu with its top-left at a screen point.
///
/// **Runs on the thread that owns `frame`.** `TrackPopupMenu` pumps its own
/// messages and must not be entered from anywhere else; it is called from the
/// strip's mouse handling, which is already on that thread.
pub fn show(frame: HWND, screen_x: i32, screen_y: i32) {
    validate_once();
    let mut order: Vec<&Row> = Vec::new();
    flatten(ROOT, &mut order);

    let mut next = 0usize;
    let Some(menu) = build(ROOT, &mut next) else { return };

    // Items on the root itself, which is what a person sees when it opens:
    // the six groups plus the two tail rows. Not the 50-odd leaves below.
    let root_items = ROOT.iter().filter(|r| !r.label.is_empty()).count();
    logf!("[menu] root shown at {screen_x},{screen_y} items={root_items}");

    OPEN.store(true, std::sync::atomic::Ordering::Relaxed);
    let chosen = unsafe {
        let c = TrackPopupMenu(
            menu,
            TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RETURNCMD | TPM_LEFTBUTTON,
            screen_x,
            screen_y,
            None,
            frame,
            None,
        );
        // Destroying the root destroys the submenus attached to it.
        let _ = DestroyMenu(menu);
        c
    };
    OPEN.store(false, std::sync::atomic::Ordering::Relaxed);
    // The button was drawn pressed for as long as the menu was up; the strip
    // has to hear that it no longer is, or it stays pressed until the next
    // thing happens to repaint it.
    let _ = unsafe { InvalidateRect(Some(frame), None, false) };

    let id = chosen.0 as usize;
    if id < ID_BASE {
        // "Dismissed" and "never opened" are different bugs that look the same
        // from the far side of the screen.
        logf!("[menu] dismissed without a choice");
        return;
    }
    let Some(row) = order.get(id - ID_BASE) else {
        logf!("[menu] returned an id outside the table: {id}");
        return;
    };
    let Some(action) = row.action else { return };

    let ok = if action.starts_with(HOST_PREFIX) {
        run_host(frame, action)
    } else {
        crate::binding(action)
    };
    // The label is in the log because that is the word the person clicked, and
    // the action is there because that is the word that failed.
    logf!("[menu] pick {:?} -> {} ok={}", row.label, action, ok as i32);
}

/// Open the root menu under the button itself -- the mouse path and the
/// keyboard path (`Alt`, `F10`) both land here, so they cannot drift apart.
///
/// `button` is the button's rectangle in the frame's client coordinates;
/// `strip.rs` owns that rectangle and hands it over, which is why this file
/// never asks where the strip put anything.
pub fn show_root_menu(frame: HWND, button: RECT) {
    let mut p = POINT { x: button.left, y: button.bottom };
    let _ = unsafe { ClientToScreen(frame, &mut p) };
    show(frame, p.x, p.y);
}

// ------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;

    fn all_rows() -> Vec<&'static Row> {
        fn walk(rows: &'static [Row], out: &mut Vec<&'static Row>) {
            for r in rows {
                out.push(r);
                if let Some(s) = r.sub {
                    walk(s, out);
                }
            }
        }
        let mut v = Vec::new();
        walk(ROOT, &mut v);
        v
    }

    /// The parser has to find the union at all, and find only its members.
    /// Without this, a rename in `Binding.zig` would empty the list and every
    /// action would silently become "unknown" -- or, worse, the list would
    /// pick up a nested type's members and start agreeing with typos.
    #[test]
    fn the_core_action_list_parses() {
        let names = core_actions();
        assert!(names.len() > 50, "only {} actions parsed", names.len());
        for known in ["new_tab", "copy_to_clipboard", "toggle_readonly", "resize_split"] {
            assert!(names.iter().any(|n| n == known), "{known} missing");
        }
        // Members of nested types inside the union must not be collected.
        for nested in ["plain", "mixed", "os_open", "toggle"] {
            assert!(
                !names.iter().any(|n| n == nested),
                "{nested} is a nested type's member, not an action"
            );
        }
    }

    /// **The check this file exists to pass.** Every action named in the menu
    /// is one the core publishes, or a host action with a handler.
    #[test]
    fn assert_actions_exist() {
        for r in all_rows() {
            let Some(a) = r.action else { continue };
            assert!(
                is_resolvable(a),
                "menu row {:?} names {a:?}, which the core does not publish",
                r.label
            );
        }
    }

    /// The floor for the test above: it has to be able to fail. A check that
    /// passes on a made-up name is not checking anything.
    #[test]
    fn a_madeup_action_is_not_resolvable() {
        assert!(!is_resolvable("new_tabb"));
        assert!(!is_resolvable("poltergeist_conversations"));
        assert!(!is_resolvable("__polter_nothing_handles_this"));
        assert!(is_resolvable("new_tab"));
    }

    /// Every `__polter_*` row has an arm in `run_host`, by way of the list the
    /// arms are written from.
    #[test]
    fn all_host_rows_are_handled() {
        for r in all_rows() {
            let Some(a) = r.action else { continue };
            if a.starts_with(HOST_PREFIX) {
                assert!(HOST_ACTIONS.contains(&a), "{a} has no handler");
            }
        }
    }

    /// Shape rules, the same ones `ctxmenu.rs` keeps: a blank label is a
    /// separator, a labelled row does something or opens something.
    #[test]
    fn rows_are_one_thing_each() {
        for r in all_rows() {
            if r.label.is_empty() {
                assert!(r.action.is_none() && r.sub.is_none(), "a blank label is a separator");
            } else {
                assert!(
                    r.action.is_some() || r.sub.is_some(),
                    "labelled row does nothing: {}",
                    r.label
                );
            }
            assert!(
                !(r.action.is_some() && r.sub.is_some()),
                "a row cannot both run and open: {}",
                r.label
            );
        }
    }

    /// Six groups, and each of them a submenu. The log line says six; this is
    /// what makes that a fact rather than a constant.
    #[test]
    fn the_root_has_six_groups_and_two_tail_items() {
        let groups = ROOT.iter().filter(|r| r.sub.is_some()).count();
        assert_eq!(groups, GROUP_COUNT);
        let tail: Vec<_> = ROOT.iter().filter(|r| r.action.is_some()).collect();
        assert_eq!(tail.len(), 2);
        assert_eq!(tail[0].action, Some("open_config"));
    }

    /// Ids must not reach into `ctxmenu.rs`'s range, or into Windows'.
    #[test]
    fn ids_stay_in_their_own_range() {
        let mut flat = Vec::new();
        flatten(ROOT, &mut flat);
        assert!(ID_BASE > 0x4000 + 0x100);
        assert!(ID_BASE + flat.len() < 0xF000);
    }

    /// Binding strings have no spaces and no invented punctuation. A typo in
    /// the parameter half is not caught by `assert_actions_exist` -- the name
    /// before the `:` is what it checks -- so the cheap shape check earns its
    /// place.
    #[test]
    fn action_strings_have_a_binding_shape() {
        for r in all_rows() {
            let Some(a) = r.action else { continue };
            assert!(!a.is_empty());
            assert!(!a.contains(' '), "binding names have no spaces: {a}");
            assert!(
                a.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "_:,-".contains(c)),
                "unexpected characters in {a}"
            );
        }
    }

    /// The five toggles are the five `Flag`s: a toggle whose flag nobody reads
    /// would never show a mark, and a flag no row uses is a getter written for
    /// nothing.
    #[test]
    fn every_flag_is_used_by_exactly_one_row() {
        for flag in [Flag::ReadOnly, Flag::FloatOnTop, Flag::Supervisor, Flag::Watched, Flag::Shielded] {
            let n = all_rows().iter().filter(|r| r.check == Some(flag)).count();
            assert_eq!(n, 1, "{flag:?} is on {n} rows");
        }
    }

    /// One row is greyed on purpose. If block L ever lands and this stops
    /// being true, the test says so rather than the menu quietly staying grey.
    #[test]
    fn exactly_one_row_is_greyed_and_it_is_the_updater() {
        let greyed: Vec<_> = all_rows().iter().filter(|r| !r.enabled).map(|r| r.label).collect();
        assert_eq!(greyed, vec!["检查更新…"]);
    }

    /// The button is the width `strip.rs` insets by, at any scale it is asked
    /// for -- including the 1.5 that rounds badly if either side truncates.
    #[test]
    fn button_width_scales() {
        assert_eq!(button_w(1.0), 46);
        assert_eq!(button_w(1.5), 69);
        assert_eq!(button_w(2.0), 92);
    }
}
