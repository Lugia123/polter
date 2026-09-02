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
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{plogf, wlogf};

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
    /// What has to be true before this row can succeed. See `Ready`.
    ready: Ready,
    /// Whether the row can be picked. See `Enable`.
    ///
    /// **Greyed, not hidden** (§3.4.3): a menu item that is missing and one
    /// that never existed look identical, and a person who was told the
    /// feature exists concludes they misremembered. A greyed one says "this
    /// exists, not now".
    enabled: Enable,
}

/// Whether a row is live, and what decides it.
///
/// **The third case is why this is not a `bool`.** Greying used to be a
/// constant: three rows were greyed because nobody had built them, and they
/// would be greyed forever. «重开关闭的标签» is the first row whose greying is
/// a fact about right now -- there is nothing to reopen until something has
/// been closed -- so the count in the `built` line moves, and a count that
/// moves is a reading rather than a constant.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Enable {
    Yes,
    /// Greyed always: §3.4.3, "this exists, not now", for something nobody
    /// has built yet.
    No,
    /// Greyed while the closed-tab stack is empty.
    WhenReopenable,
}

fn row_enabled(r: &Row) -> bool {
    match r.enabled {
        Enable::Yes => true,
        Enable::No => false,
        Enable::WhenReopenable => crate::reopen::can_reopen(),
    }
}

/// Why a row can come back `ok=0` with nothing wrong.
///
/// **`binding_action` returning false means three different things**, and
/// until they were told apart the self-test's summary could not distinguish
/// "the terminal had no selection" from "this host never implemented that".
/// The first is the normal state of a menu; the second is work not done; only
/// the third is a defect. A single `failed` count made all three look like the
/// third, which is how a green run and a broken menu look the same.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Ready {
    /// Nothing outside the menu has to hold. **`ok=0` here is a defect.**
    Always,
    /// Needs the terminal to be in some state: a selection to copy, a search
    /// to step through. The core returns false and is right to.
    NeedsState(&'static str),
    /// The core performs this by asking *this host*, and this host does not
    /// answer yet -- `cb_action` in `main.rs` ends in `_ => false`, and the
    /// stub clipboard callbacks return false the same way. Not a defect in
    /// the menu; a piece of the host that is not built.
    HostGap(&'static str),
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
    Row { label, action: Some(action), sub: None, check: None, ready: Ready::Always, enabled: Enable::Yes }
}

/// A row the terminal's own state can legitimately refuse.
const fn act_state(label: &'static str, action: &'static str, why: &'static str) -> Row {
    Row {
        label,
        action: Some(action),
        sub: None,
        check: None,
        ready: Ready::NeedsState(why),
        enabled: Enable::Yes,
    }
}

/// A row the core hands to this host, which does not answer it yet.
const fn act_gap(label: &'static str, action: &'static str, why: &'static str) -> Row {
    Row {
        label,
        action: Some(action),
        sub: None,
        check: None,
        ready: Ready::HostGap(why),
        enabled: Enable::Yes,
    }
}

/// A row that runs a core action and shows a check mark for `flag`.
const fn toggle(label: &'static str, action: &'static str, flag: Flag, ready: Ready) -> Row {
    Row { label, action: Some(action), sub: None, check: Some(flag), ready, enabled: Enable::Yes }
}

const fn sep() -> Row {
    Row { label: "", action: None, sub: None, check: None, ready: Ready::Always, enabled: Enable::Yes }
}

/// A row that opens a nested menu.
const fn sub(label: &'static str, rows: &'static [Row]) -> Row {
    Row { label, action: None, sub: Some(rows), check: None, ready: Ready::Always, enabled: Enable::Yes }
}

// The prefix that marks a row as the host's own, and the predicate for it,
// live in `keys.rs`: `crate::keys::HOST_ACTION_PREFIX` and `is_host_action`.
//
// **They were here as well, and the comment that used to sit on this line
// said so out loud** -- "the same split `keys.rs` already makes for
// `__polter_plugin_page`". Two spellings of one rule stay in step until the
// day they do not, and the failure would be silent on both sides: a row this
// file called the host's own and `keys.rs` did not would go to the core and
// come back as an unattributable warning, which is precisely the defect that
// was just fixed. The definition belongs on the side that is already depended
// on -- this file calls `keys.rs`, so putting it there adds no back edge.

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
    // **Not `undo`.** The core's `undo` action is handed to the host
    // (`GHOSTTY_ACTION_UNDO`, tag 55) and the host is where a closed-tab
    // stack has to live, so this row runs the host's own stack directly
    // rather than going out to the core and back for nothing. Greyed while
    // the stack is empty -- the first row in this menu whose greying is a
    // fact about right now.
    Row {
        label: "重开关闭的标签",
        action: Some("__polter_reopen_tab"),
        sub: None,
        check: None,
        ready: Ready::NeedsState("needs a tab closed in this session; the row is greyed until then"),
        enabled: Enable::WhenReopenable,
    },
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
    act_state("下一个", "navigate_search:next", "needs an open search"),
    act_state("上一个", "navigate_search:previous", "needs an open search"),
    sep(),
    act_state("隐藏查找条", "end_search", "reports performed only if a search was open"),
];

const EDIT_ROWS: &[Row] = &[
    act_state("复制", "copy_to_clipboard", "needs a selection: Surface.zig returns false when there is none"),
    act("粘贴", "paste_from_clipboard"),
    // **«粘贴选区» is gone, and its absence is the point.** It pastes the
    // *selection* clipboard, which X11 and macOS have and Windows does not.
    // This host declares no selection support and `cb_write_clipboard`
    // refuses that kind outright, so the row could never do anything --
    // and `s4.md` §3.2's own rule is that a concept Windows does not have
    // is not ported. A row that can never work is worse than a missing one:
    // it is the "click does nothing" this whole menu was audited to remove.
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
    // **Two rows, because the core has two actions and they do different
    // things.** `prompt_tab_title` renames the tab and keeps the name against
    // whatever the shell sets; `prompt_surface_title` renames this pane's
    // terminal. macOS lists both side by side under View. This table had one
    // row labelled for the first and wired to the second, which is a defect
    // that looks like a working menu item: the dialog opens, a name is typed,
    // and the wrong thing is renamed.
    act("改标签标题…", "prompt_tab_title"),
    act("改终端标题…", "prompt_surface_title"),
    // §3.2 called this `toggle_surface_read_only`; the core's name is shorter.
    toggle("只读", "toggle_readonly", Flag::ReadOnly, Ready::Always),
    sep(),
    act("快速终端", "toggle_quick_terminal"),
    sep(),
    // **Blocked on the core's C API, not on host work.** The only inspector
    // renderer libghostty publishes is `ghostty_inspector_metal_*`, and that
    // block of `include/ghostty.h` sits inside `#ifdef __APPLE__`. The tag is
    // handled now -- it says this in the log instead of falling through
    // silently -- but there is nothing on Windows to render into.
    act_gap(
        "终端检查器",
        "inspector:toggle",
        "libghostty publishes no inspector renderer outside Apple (ghostty_inspector_metal_* is \
         inside #ifdef __APPLE__)",
    ),
];

const AGENTS_ROWS: &[Row] = &[
    // §3.2 called this `poltergeist_conversations`; the core publishes
    // `poltergeist_toggle_chat`.
    // The chat is a TUI (`polter +chat`), so opening it is opening a terminal
    // with a command and one flag set -- and both of those are `create_pane`'s
    // to set, in `tabs.rs`. The tag is handled and says so.
    act("终端对话", "poltergeist_toggle_chat"),
    sep(),
    toggle("设为总管", "poltergeist_supervisor", Flag::Supervisor, Ready::Always),
    toggle("监督此终端", "poltergeist_toggle_watch", Flag::Watched, Ready::Always),
    toggle("禁止 agent 进入", "poltergeist_toggle_shielded", Flag::Shielded, Ready::Always),
    sep(),
    // Host rows: the core knows nothing about either page.
    act("插件…", "__polter_plugin_page"),
    // Greyed: nothing behind it yet. `s4.md` §3.4.3 -- greyed says "this
    // exists, not now"; a row that is missing and a row that never existed
    // look the same, and a row that does nothing is worse than both.
    Row {
        label: "语言…",
        action: Some("__polter_language"),
        sub: None,
        check: None,
        ready: Ready::HostGap("no language picker exists yet"),
        enabled: Enable::No,
    },
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
    toggle("置顶", "toggle_window_float_on_top", Flag::FloatOnTop, Ready::Always),
];

const HELP_ROWS: &[Row] = &[
    // Greyed for the same reason as «语言…»: the docs URL has no opener yet.
    Row {
        label: "Polter 帮助",
        action: Some("__polter_help_docs"),
        sub: None,
        check: None,
        ready: Ready::HostGap("no docs opener exists yet"),
        enabled: Enable::No,
    },
    sep(),
    // The core publishes `check_for_updates`, but block L is not built, so the
    // row is greyed rather than removed. Removing it would make the missing
    // updater indistinguishable from a decision never to have one.
    Row {
        label: "检查更新…",
        action: Some("check_for_updates"),
        sub: None,
        check: None,
        ready: Ready::HostGap("block L is not built"),
        enabled: Enable::No,
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
        // **The about box this host already has**, not a second one. It shows
        // the product, the core's own version string, the build mode and the
        // running binary's identity -- the same line `[build]` logs.
        "__polter_about" => {
            crate::settings_ui::request_about();
            true
        }
        // The stack, and the tab it makes, both live in the host: see
        // `reopen.rs`. It answers false when there is nothing to reopen,
        // which is also what the greyed row is saying.
        "__polter_reopen_tab" => crate::reopen::reopen_last(),
        "__polter_minimize" => {
            let _ = unsafe { ShowWindow(frame, SW_MINIMIZE) };
            true
        }
        // Not built, and **greyed in the table** rather than live: a row that
        // is clickable and does nothing is worse than one that is greyed, and
        // it is the exact defect this menu exists to stop. A click cannot
        // reach these, so this arm is only a backstop -- if it ever fires,
        // something un-greyed them.
        "__polter_language" | "__polter_help_docs" => {
            // process-wide: a row naming a host action with no handler is a gap in the table, the same one for every window
            plogf!("[menu] host action {action:?} is not built; the row should have been greyed");
            false
        }
        _ => false,
    }
}

/// Every host action this file may name. `run_host` must have an arm for each.
const HOST_ACTIONS: &[&str] = &[
    "__polter_reopen_tab",
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
    if crate::keys::is_host_action(action) {
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
    let _ = STATE.set(f);
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
        // **Of this surface, not of "the terminal".** Read-only is per
        // surface; asking the global question ticked the row for a pane the
        // menu was not about, which is task 108. The root menu acts on the
        // active surface, so that is the one it must ask about -- a menu
        // opened on some other surface (the tab and surface context menus)
        // has to pass its own.
        Flag::ReadOnly => {
            // **The first window's active surface.** `state_for` is asked by
            // a menu that already knows its window; threading that through is
            // a change to the check-mark plumbing rather than to this batch,
            // so the assumption is written down instead of hidden.
            let s = crate::tabs::active_surface(crate::tabs::frame_hwnd()) as usize;
            if s == 0 {
                None
            } else {
                Some(crate::hud::is_readonly_for(s))
            }
        }
        // **Asked of the window itself** (`WS_EX_TOPMOST`), which is the
        // state rather than a record of it. This row used to answer `None`
        // -- nothing in the host knew -- and that showed up in the log as
        // `4 evaluable` out of five.
        Flag::FloatOnTop => Some(crate::prompt::is_float_on_top()),
        Flag::Supervisor | Flag::Watched | Flag::Shielded => {
            let active = crate::tabs::active_surface(crate::tabs::frame_hwnd());
            let (role, shielded) = crate::tabs::mark_for_surface(active)?;
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
    // The title box and the float-on-top request need a window on this
    // thread. **This is the main thread**: the first paint of the strip is
    // what got us here.
    crate::prompt::init();
    let _ = ACCEL.set(crate::keys::shortcut_for as fn(&str) -> Option<String>);
    let _ = STATE.set(default_state as fn(Flag) -> Option<bool>);
}

/// Is this an action the *core* could have a key bound to?
///
/// **A `__polter_*` row is the host's own**, and asking the core for its
/// trigger is asking about a name the core has never heard of. The core
/// answers by logging `error finding trigger err=error.InvalidAction` -- one
/// line, **with no action string in it** -- and returning an empty trigger.
/// Five such lines have been in every run's log for as long as this menu has
/// existed, and they could not be acted on because nothing said which five.
/// They were these rows.
fn asks_the_core(action: &str) -> bool {
    !crate::keys::is_host_action(action)
}

fn accel_of(action: &str) -> Option<String> {
    if !asks_the_core(action) {
        return None;
    }
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
    /// Rows shown greyed on purpose. Reported because "greyed" is a claim
    /// about the menu that nobody can check from a log that does not say it.
    greyed: usize,
    /// Core actions that came back with no shortcut, by name.
    no_accel: Vec<&'static str>,
    /// Rows that are the host's own, which the core is never asked about.
    host_rows: usize,
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
            // process-wide: a row naming an action the core does not publish; a property of the table, not of a window
            plogf!("[menu] unresolved action {a:?} on row {:?}", r.label);
        }
        if r.check.is_some() {
            c.checkable += 1;
        }
        if !row_enabled(r) {
            c.greyed += 1;
        }
        if !asks_the_core(a) {
            c.host_rows += 1;
        } else if accel_of(a).is_some_and(|t| !t.is_empty()) {
            c.with_accel += 1;
        } else {
            c.no_accel.push(a);
        }
    }
}

/// Every flag a row can be ticked by.
const ALL_FLAGS: &[Flag] = &[
    Flag::ReadOnly,
    Flag::FloatOnTop,
    Flag::Supervisor,
    Flag::Watched,
    Flag::Shielded,
];

/// Flags something can currently answer, and flags ticked right now.
///
/// **Two numbers, because they fail in opposite directions and looked
/// identical when they were one.** "0 ticked" is the normal state at startup
/// and says nothing about wiring; "0 evaluable" means nothing can answer, and
/// then every unticked row is unticked for a reason that has nothing to do
/// with its state. Reported as one line so neither can be read alone.
fn check_state_counts() -> (usize, usize, Vec<&'static str>) {
    let mut evaluable = 0;
    let mut ticked = 0;
    let mut no_source = Vec::new();
    for f in ALL_FLAGS {
        match checked(*f) {
            Some(v) => {
                evaluable += 1;
                if v {
                    ticked += 1;
                }
            }
            None => no_source.push(match f {
                Flag::ReadOnly => "ReadOnly",
                Flag::FloatOnTop => "FloatOnTop",
                Flag::Supervisor => "Supervisor",
                Flag::Watched => "Watched",
                Flag::Shielded => "Shielded",
            }),
        }
    }
    (evaluable, ticked, no_source)
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
    let mut c = Counts {
        items: 0,
        unresolved: 0,
        checkable: 0,
        with_accel: 0,
        greyed: 0,
        no_accel: Vec::new(),
        host_rows: 0,
    };
    count(ROOT, &mut c);
    // process-wide: the static menu tree, built once at startup and shared by every window
    plogf!(
        "[menu] built {} groups, {} items, {} greyed, {} unresolved",
        GROUP_COUNT,
        c.items,
        c.greyed,
        c.unresolved
    );
    // Two more lines rather than two more fields: each says what is missing
    // and what would fix it, and neither is readable as the other. The counts
    // are measured, so an installed provider that resolves nothing reads
    // differently from no provider at all.
    // process-wide: where the shortcut text comes from: one provider for the process
    plogf!(
        "[menu] shortcut provider {}, accel={}/{} (shortcuts come from the core binding table; none are written here)",
        if ACCEL.get().is_some() { "installed" } else { "NOT installed" },
        c.with_accel,
        c.items
    );
    // **Named, on one line.** "Eighteen of fifty-four have a shortcut" cannot
    // be acted on; the other thirty-six by name can. And a row that *should*
    // have one -- because the user bound it -- shows up here the moment the
    // lookup starts failing, which is otherwise indistinguishable from the
    // user never having bound it.
    if !c.no_accel.is_empty() {
        // process-wide: a count over the static table
        plogf!(
            "[menu] no shortcut for {} of {} core actions: {}",
            c.no_accel.len(),
            c.items - c.host_rows,
            c.no_accel.join(", ")
        );
    }
    // process-wide: a count over the static table
    plogf!(
        "[menu] {} rows are the host's own and are never asked of the core (a `__polter_*` name \
         makes it log error.InvalidAction with no name attached)",
        c.host_rows
    );
    arm_selftest();
    let (evaluable, ticked, no_source) = check_state_counts();
    // process-wide: a count over the static table
    plogf!(
        "[menu] check-state: {} rows, {} evaluable, {} ticked now{}",
        c.checkable,
        evaluable,
        ticked,
        if no_source.is_empty() {
            String::new()
        } else {
            format!("; no source for: {}", no_source.join(", "))
        }
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
/// `frame` is carried only so the one failure in here can say which window's
/// menu did not open. **It is not used to build anything** -- the tree is the
/// same for every window -- but the line below is printed exactly on the day
/// somebody needs to know which of two windows lost its menu, and a line that
/// cannot say is a line that arrives too late to be worth having.
fn build(frame: HWND, rows: &[Row], next: &mut usize) -> Option<HMENU> {
    unsafe {
        let menu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(e) => {
                wlogf!(frame, "[menu] CreatePopupMenu failed: {e:?}");
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
                let child = build(frame, children, next)?;
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
            if !row_enabled(r) {
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
    let Some(menu) = build(frame, ROOT, &mut next) else { return };

    // Items on the root itself, which is what a person sees when it opens:
    // the six groups plus the two tail rows. Not the 50-odd leaves below.
    let root_items = ROOT.iter().filter(|r| !r.label.is_empty()).count();
    wlogf!(frame, "[menu] root shown at {screen_x},{screen_y} items={root_items}");

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
        wlogf!(frame, "[menu] dismissed without a choice");
        return;
    }
    let Some(row) = order.get(id - ID_BASE) else {
        wlogf!(frame, "[menu] returned an id outside the table: {id}");
        return;
    };
    perform(frame, row);
}

/// Run one row and say so. **The single place a menu row turns into an
/// action** -- a mouse pick and `--menu-selftest` both come through here, and
/// that is the whole reason the self-test is worth anything. A self-test with
/// its own dispatch would prove that 54 action strings parse, which is what
/// `assert_actions_exist` already proves for free.
fn perform(frame: HWND, row: &Row) -> bool {
    let Some(action) = row.action else { return false };
    let ok = if crate::keys::is_host_action(action) {
        run_host(frame, action)
    } else {
        crate::binding(action)
    };
    // The label is in the log because that is the word the person clicked, and
    // the action is there because that is the word that failed.
    wlogf!(frame, "[menu] pick {:?} -> {} ok={}", row.label, action, ok as i32);
    ok
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

// --------------------------------------------------------------- self-test

/// Rows that end the session, in the order they are least destructive.
///
/// **Dispatching a menu row does the thing.** The self-test is not a dry run:
/// `binding_action` performs the action, so by the time it reaches these three
/// the window is on its way out and nothing after them would be logged. They
/// go last so that everything else is already on record.
const ENDS_THE_SESSION: &[&str] = &["close_surface", "close_tab:this", "close_window"];

/// Was `--menu-selftest` on the command line?
fn selftest_requested() -> bool {
    static FLAG: OnceLock<bool> = OnceLock::new();
    *FLAG.get_or_init(|| std::env::args().any(|a| a == "--menu-selftest"))
}

/// Run every row through `perform`, in table order, session-enders last.
///
/// **This proves the dispatch, not the pointer.** Every row here is reached by
/// its table entry, not by a click, so a menu whose hit test is broken -- a
/// button nobody can press, a rectangle at the wrong x -- passes this with 54
/// green lines. W4 samples real clicks for that half; *only* the self-test
/// means 54 green lines on a stretch of code nobody can reach.
fn run_selftest(frame: HWND) {
    let mut order: Vec<&Row> = Vec::new();
    flatten(ROOT, &mut order);
    let (last, first): (Vec<&Row>, Vec<&Row>) = order
        .iter()
        .partition(|r| r.action.is_some_and(|a| ENDS_THE_SESSION.contains(&a)));

    // process-wide: the whole-process self test; it dispatches through one window but reports on the table
    plogf!(
        "[menu] selftest: {} items through the same call a mouse pick makes, {} of them last because they end the session",
        order.len(),
        last.len()
    );
    let mut ok = 0usize;
    let mut nothing_to_do = 0usize;
    let mut not_built = 0usize;
    let mut failed = 0usize;
    let mut skipped = 0usize;
    for row in first.into_iter().chain(last) {
        if !row_enabled(row) {
            // A greyed row cannot be picked with a mouse either, so dispatching
            // it here would test a path that does not exist.
            // process-wide: the whole-process self test, reporting on a row rather than on a window
            plogf!("[menu] selftest skip {:?} (greyed; a click cannot reach it)", row.label);
            skipped += 1;
            continue;
        }
        if perform(frame, row) {
            ok += 1;
            // **The one that must not pass unnoticed.** A row marked as a
            // missing piece of the host that now works means someone built it
            // and this table still says they did not -- and the next reader
            // takes the stale note as fact.
            if let Ready::HostGap(why) = row.ready {
                // process-wide: the whole-process self test, reporting on a row rather than on a window
                plogf!(
                    "[menu] selftest {:?} works now but is still marked not-built: {}",
                    row.label,
                    why
                );
            }
            continue;
        }
        // **A false is sorted here, not counted here.** Which bucket it lands
        // in was decided when the row was written, by someone who had read the
        // core; deciding it from the result instead would make every failure
        // explain itself away.
        match row.ready {
            Ready::Always => {
                failed += 1;
                // process-wide: the whole-process self test, reporting on a row rather than on a window
                plogf!("[menu] selftest FAILED {:?}: nothing had to be true for this one", row.label);
            }
            Ready::NeedsState(why) => {
                nothing_to_do += 1;
                // process-wide: the whole-process self test, reporting on a row rather than on a window
                plogf!("[menu] selftest nothing-to-do {:?}: {}", row.label, why);
            }
            Ready::HostGap(why) => {
                not_built += 1;
                // process-wide: the whole-process self test, reporting on a row rather than on a window
                plogf!("[menu] selftest not-built {:?}: {}", row.label, why);
            }
        }
    }
    // **Five numbers, because they mean five things.** `failed` is the only
    // one that is a defect; a run with `failed=0` and `not-built=7` is a menu
    // working correctly on top of a host with seven pieces missing, and that
    // is a different report from `failed=7`.
    // process-wide: the whole-process self test: one run, whatever the window count
    plogf!(
        "[menu] selftest done: {} ok, {} nothing-to-do (state), {} not-built (host gap), {} failed (should have worked), {} skipped",
        ok, nothing_to_do, not_built, failed, skipped
    );
}

/// `WM_APP` on the self-test's own window: the run happens here rather than in
/// the paint that armed it. **Dispatching 54 actions from inside `WM_PAINT`**
/// -- with a memory DC selected and `BeginPaint` open -- reenters painting
/// through every action that opens a window, and that is a hang, not a test.
// `WM_APP + 9` is taken twice already (main.rs and settings_ui.rs, on their
// own windows); a third same-numbered message is a thing someone misreads.
const WM_MENU_SELFTEST: u32 = WM_APP + 11;

/// How many times the timer has looked for a surface and not found one.
static SELFTEST_TRIES: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
const SELFTEST_MAX_TRIES: u32 = 40;

extern "system" fn selftest_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_MENU_SELFTEST || msg == WM_TIMER {
        // **Wait for a surface.** Every action would fail against a null one,
        // and 54 red lines that mean "the app had not finished starting" look
        // exactly like 54 red lines that mean "the menu is wrong".
        let frame = crate::frame_hwnd_cached();
        if crate::tabs::active_surface(frame).is_null() || frame.is_invalid() {
            let n = SELFTEST_TRIES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if n >= SELFTEST_MAX_TRIES {
                unsafe { let _ = KillTimer(Some(hwnd), 1); }
                // process-wide: the whole-process self test never dispatched; nothing window-specific happened
                plogf!(
                    "[menu] selftest gave up: no surface after {} tries; nothing was dispatched",
                    n
                );
                return LRESULT(0);
            }
            unsafe { SetTimer(Some(hwnd), 1, 250, None) };
            return LRESULT(0);
        }
        unsafe { let _ = KillTimer(Some(hwnd), 1); }
        run_selftest(frame);
        return LRESULT(0);
    }
    unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
}

/// Arm the self-test, once, if it was asked for.
fn arm_selftest() {
    static DONE: OnceLock<()> = OnceLock::new();
    if !selftest_requested() || DONE.set(()).is_err() {
        return;
    }
    unsafe {
        let hinst = windows::Win32::System::LibraryLoader::GetModuleHandleW(PCWSTR::null())
            .unwrap_or_default();
        let class = windows::core::w!("PolterMenuSelftest");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(selftest_proc),
            hInstance: hinst.into(),
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassW(&wc);
        // Message-only: it never shows, and its messages are pumped by the
        // main loop like any other window this thread owns.
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR::null(),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            Some(hinst.into()),
            None,
        );
        match hwnd {
            Ok(h) => {
                // process-wide: the whole-process self test being armed, before any window is involved
                plogf!("[menu] selftest armed by --menu-selftest; waiting for a surface");
                let _ = PostMessageW(Some(h), WM_MENU_SELFTEST, WPARAM(0), LPARAM(0));
            }
            // Said out loud: a self-test that quietly did not run reads as a
            // menu that has never been exercised, and there is no line to tell
            // the two apart.
            // process-wide: the whole-process self test failed to arm; no window is involved
            Err(e) => plogf!("[menu] selftest could NOT arm: {e:?}"),
        }
    }
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

    /// The host's own rows are never handed to the core's trigger lookup.
    ///
    /// **This is the whole of the fix for those five nameless log lines**, so
    /// it is worth a test that fails if someone drops the guard: the symptom
    /// of dropping it is not a bug anyone would notice, it is five more
    /// unattributable warnings per menu build.
    #[test]
    fn host_rows_are_never_asked_of_the_core() {
        for a in HOST_ACTIONS {
            assert!(crate::keys::is_host_action(a), "{a} is not a host action name");
            assert!(!asks_the_core(a), "{a} would be handed to the core");
        }
        for r in all_rows() {
            let Some(a) = r.action else { continue };
            assert_eq!(
                asks_the_core(a),
                !crate::keys::is_host_action(a),
                "{a} is classified inconsistently"
            );
        }
        assert!(asks_the_core("copy_to_clipboard"));
        // A core action with a parameter is still the core's: the parameter is
        // parsed by the core, and a lookup that failed on it would be a real
        // finding rather than noise.
        assert!(asks_the_core("resize_split:up,10"));
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
            if crate::keys::is_host_action(a) {
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

    /// Three rows are greyed **always**, and the list is spelled out: when one
    /// of them gets built, this test is what says "un-grey it" rather than the
    /// menu quietly staying grey forever. The conditional one is next door.
    #[test]
    fn the_greyed_rows_are_the_three_that_are_not_built() {
        let mut greyed: Vec<_> = all_rows()
            .iter()
            .filter(|r| r.enabled == Enable::No)
            .map(|r| r.label)
            .collect();
        greyed.sort_unstable();
        // Sorted, not in table order: this test is about *which* rows are
        // greyed. Pinning the traversal order here would make it fail the next
        // time a group is reordered, for a reason it does not care about.
        let mut want = vec!["语言…", "检查更新…", "Polter 帮助"];
        want.sort_unstable();
        assert_eq!(greyed, want);
    }

    /// The three buckets, counted. **Pinned so that building one of the
    /// missing pieces has to come here and say so**: a row that starts
    /// working while the table still calls it not-built turns the self-test's
    /// summary into a stale note nobody rereads. The run-time counterpart is
    /// the "works now but is still marked not-built" line.
    #[test]
    fn the_three_readiness_buckets_are_what_we_think() {
        let rows = all_rows();
        let leaves: Vec<_> = rows.iter().filter(|r| r.action.is_some()).collect();
        let n = |f: fn(&Ready) -> bool| leaves.iter().filter(|r| f(&r.ready)).count();
        assert_eq!(leaves.len(), 54);
        assert_eq!(n(|r| matches!(r, Ready::Always)), 45, "unconditional rows");
        assert_eq!(n(|r| matches!(r, Ready::NeedsState(_))), 5, "state-dependent rows");
        assert_eq!(n(|r| matches!(r, Ready::HostGap(_))), 4, "rows this host does not answer yet");
    }

    /// Both non-trivial buckets have to say why, because the reason is what
    /// the log line prints and a blank one reads as no reason at all.
    #[test]
    fn every_excused_row_says_why() {
        for r in all_rows() {
            match r.ready {
                Ready::Always => {}
                Ready::NeedsState(why) | Ready::HostGap(why) => {
                    assert!(!why.trim().is_empty(), "{} is excused without a reason", r.label)
                }
            }
        }
    }

    /// The two "rename" rows name the two different core actions. **They were
    /// one row**, labelled for the tab and wired to the surface, and nothing
    /// on screen could have told you: the dialog opens either way and the
    /// wrong name lands somewhere plausible.
    #[test]
    fn the_two_title_rows_are_not_the_same_action() {
        let rows = all_rows();
        let find = |label: &str| {
            rows.iter().find(|r| r.label == label).and_then(|r| r.action).unwrap_or("")
        };
        assert_eq!(find("改标签标题…"), "prompt_tab_title");
        assert_eq!(find("改终端标题…"), "prompt_surface_title");
    }

    /// Exactly one row's greying depends on the moment rather than on
    /// whether somebody has built it. **That is what makes the `greyed` count
    /// in the log a reading**: a number that can only be 3 says nothing, and a
    /// second conditional row added without noticing would make the count move
    /// for a reason nobody wrote down.
    #[test]
    fn one_row_is_greyed_by_state_and_it_is_the_reopen_one() {
        let conditional: Vec<_> = all_rows()
            .iter()
            .filter(|r| matches!(r.enabled, Enable::WhenReopenable))
            .map(|r| r.label)
            .collect();
        assert_eq!(conditional, vec!["重开关闭的标签"]);
    }

    /// A greyed row still names something. **Greying is not a way to park a
    /// row with no action** -- the row has to be a real command that is not
    /// available yet, or it should not be in the menu at all.
    #[test]
    fn greyed_rows_still_name_an_action() {
        for r in all_rows().iter().filter(|r| r.enabled != Enable::Yes) {
            assert!(r.action.is_some(), "greyed row {} names nothing", r.label);
        }
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
