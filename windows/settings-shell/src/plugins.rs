//! The plugins section's rules (settings.md §5), with nothing drawn: which
//! status dot a plugin gets, which required parameters are still empty,
//! where the sidebar's plugin rows and the detail's blocks go, and what the
//! plugin's own page (§5.3) may load.
//!
//! Here rather than in `polter-host` for the reason the rest of this crate
//! is: those tests run only on Windows, so a rule left there could be broken
//! on the Mac with everything green.

use crate::grid::*;
use crate::{scale, Layout, Rect, Section};

// ============================================================ status dots

/// The five dots of §5.1.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dot {
    /// ↻ The settings saved are not the ones the running copy was started
    /// with.
    Changed,
    /// ○ Switched off.
    Off,
    /// ◐ A required parameter is empty.
    Missing,
    /// ▲ The running copy has failed, or the core has something to say about
    /// a plugin that is on.
    Error,
    /// ● On, and nothing wrong that anybody reported.
    On,
}

impl Dot {
    /// All five, for whoever measures the widest word.
    pub const ALL: [Dot; 5] = [Dot::Changed, Dot::Off, Dot::Missing, Dot::Error, Dot::On];

    pub fn glyph(self) -> &'static str {
        match self {
            Dot::Changed => "\u{21bb}",
            Dot::Off => "\u{25cb}",
            Dot::Missing => "\u{25d0}",
            Dot::Error => "\u{25b2}",
            Dot::On => "\u{25cf}",
        }
    }

    /// The word beside the dot, as an English msgid (settings.md §5.1's
    /// table: 已开 / 缺配置 / 已关 / 出错 / 改了未重启).
    pub fn msgid(self) -> &'static str {
        match self {
            Dot::Changed => "Restart to apply",
            Dot::Off => "Off",
            Dot::Missing => "Needs setup",
            Dot::Error => "Error",
            Dot::On => "On",
        }
    }
}

/// What the core says about a plugin's running copy -- `plugin_list`'s
/// `state` / `failures` / `note`, the same data MCP hands an agent.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Runtime {
    /// `state` was present: a copy is running. Absent means none is.
    pub running: bool,
    pub failures: u32,
    pub note: String,
}

/// Everything the dot is decided from.
///
/// **`runtime` is an `Option` on purpose** (AGENTS.md 验证 §5): `None` is
/// "the core was not asked, or could not answer" -- the host is paired with
/// a core that has no `ghostty_app_plugin_list` -- and `Some` with nothing
/// in it is "asked, and nothing is wrong". The two must not draw the same
/// thing by accident, so the caller says which it has.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facts {
    pub enabled: bool,
    /// How many required parameters are still empty.
    pub missing: usize,
    pub restart_pending: bool,
    pub runtime: Option<Runtime>,
}

/// The dot (§5.1). **The first that holds wins**, in the order the spec
/// fixed on 2026-10-01: ↻ > ○ > ◐ > ▲ > ●. The core's `note` is never empty
/// for a plugin that is off ("installed but switched off") or one switched
/// on and not yet running ("no copy of it is running"), which is why ○ and
/// ↻ are asked before ▲ reads it.
///
/// With no runtime to read, ▲ cannot be told from ●; the answer is ●, and
/// the detail says the core gave no running state (`Facts::runtime`).
pub fn dot(f: &Facts) -> Dot {
    if f.restart_pending {
        return Dot::Changed;
    }
    if !f.enabled {
        return Dot::Off;
    }
    if f.missing > 0 {
        return Dot::Missing;
    }
    match &f.runtime {
        Some(r) if (r.running && r.failures > 0) || !r.note.trim().is_empty() => Dot::Error,
        _ => Dot::On,
    }
}

/// A plugin's saved settings: on or off, and every parameter value, sorted
/// by name. What the running copy was started with is one of these; what is
/// on disk now is another.
pub type Settings = (bool, Vec<(String, String)>);

/// Whether ↻ holds: a copy is running, and it was started with settings
/// other than the ones saved now.
///
/// `running_with` is what the host recorded -- the settings at startup, and
/// again after every save made while no copy was running (the core starts
/// one then, with what was saved: settings.md §5.2). `running` is `None`
/// when the core gave no running state, and then the answer leans towards
/// saying so: a difference nobody can rule out is shown, not hidden.
pub fn restart_pending(running_with: Option<&Settings>, now: &Settings, running: Option<bool>) -> bool {
    if running == Some(false) {
        return false;
    }
    match running_with {
        Some(w) => normalised(w) != normalised(now),
        // Installed after the copy that is running was started, or never
        // seen: whatever is running is not this.
        None => running == Some(true),
    }
}

/// Empty values dropped and the rest sorted, so "a field left blank" and "a
/// field never written" compare equal -- the host saves neither.
fn normalised(s: &Settings) -> Settings {
    let mut v: Vec<(String, String)> = s.1.iter().filter(|(_, val)| !val.is_empty()).cloned().collect();
    v.sort();
    (s.0, v)
}

/// The required parameters still empty, by title, in the manifest's order.
/// `params` is `(name, title, required)`.
pub fn missing_required(params: &[(String, String, bool)], values: &[(String, String)]) -> Vec<String> {
    params
        .iter()
        .filter(|(name, _, required)| *required && !values.iter().any(|(k, v)| k == name && !v.trim().is_empty()))
        .map(|(_, title, _)| title.clone())
        .collect()
}

/// Whether the switch may be turned **on** (§5.2 item 2): not while a
/// required parameter is empty. Turning it off is always allowed.
pub fn switch_enabled(currently_on: bool, missing: usize) -> bool {
    currently_on || missing == 0
}

// ================================================================ sidebar

/// The sidebar with the plugins listed under their section (§2.3): the four
/// section rows, and one row per plugin between Plugins and General.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sidebar {
    /// One per `Section::ALL`, in order; the selected highlight's box.
    pub sections: [Rect; 4],
    /// One per plugin shown, in order.
    pub plugins: Vec<Rect>,
    /// Where a plugin row's dot starts: `PAD` further in than a section's
    /// label, so the rows read as belonging to the one above.
    pub plugin_text_left: i32,
}

/// A plugin row: `SECTION_ROW_H` like a section's, so the sidebar keeps one
/// rhythm.
pub fn sidebar(l: &Layout, dpi: i32, plugins: usize) -> Sidebar {
    let s = |v| scale(v, dpi);
    let row_h = s(SECTION_ROW_H);
    let mut sections = l.rows;
    let first_plugin = l.rows[2].bottom;
    let plugin_rows: Vec<Rect> = (0..plugins as i32)
        .map(|i| {
            let t = first_plugin + i * row_h;
            Rect::new(l.rows[2].left, t, l.rows[2].right, t + row_h)
        })
        .collect();
    let shift = plugins as i32 * row_h;
    sections[3] = Rect::new(l.rows[3].left, l.rows[3].top + shift, l.rows[3].right, l.rows[3].bottom + shift);
    Sidebar { sections, plugins: plugin_rows, plugin_text_left: l.sidebar_text_left + s(PAD) }
}

/// The sidebar scrolled by `scroll` pixels (task 990: at the smallest
/// window the plugins pushed General under the bottom band). The search
/// field stays in the top band; only the rows move, and they are drawn
/// clipped to [`sidebar_view`].
pub fn sidebar_at(l: &Layout, dpi: i32, plugins: usize, scroll: i32) -> Sidebar {
    let mut sb = sidebar(l, dpi, plugins);
    let up = |r: &Rect| Rect::new(r.left, r.top - scroll, r.right, r.bottom - scroll);
    sb.sections = sb.sections.map(|r| up(&r));
    sb.plugins = sb.plugins.iter().map(up).collect();
    sb
}

/// The rows' window: under the top rule, over the bottom rule.
pub fn sidebar_view(l: &Layout) -> (i32, i32) {
    (l.top_rule.bottom, l.bottom_rule.top)
}

/// How far the rows can scroll: the last row (General) and a row gap under
/// it fit above the bottom rule at the end.
pub fn sidebar_max_scroll(l: &Layout, dpi: i32, plugins: usize) -> i32 {
    let sb = sidebar(l, dpi, plugins);
    (sb.sections[3].bottom + scale(ROW_GAP, dpi) - sidebar_view(l).1).max(0)
}

/// The scroll that shows `row` (unscrolled), moved as little as possible,
/// held inside `0..=max`.
pub fn sidebar_scroll_to(l: &Layout, row: Rect, scroll: i32, max: i32) -> i32 {
    let (top, bottom) = sidebar_view(l);
    let s = if row.top - scroll < top {
        row.top - top
    } else if row.bottom - scroll > bottom {
        row.bottom - bottom
    } else {
        scroll
    };
    s.clamp(0, max.max(0))
}

/// A plugin row's two columns: the dot's word on the right, `word_w` wide
/// -- the widest of the five words as the host's font measures them, so
/// "改了未重启" is never cut (task 990) -- and the name in what is left,
/// cut with an ellipsis if it must be.
pub fn plugin_columns(row: Rect, text_left: i32, word_w: i32, dpi: i32) -> (Rect, Rect) {
    let s = |v| scale(v, dpi);
    let right = row.right - s(PAD_SIDEBAR);
    let word = Rect::new((right - word_w).max(text_left), row.top, right, row.bottom);
    let name = Rect::new(text_left, row.top, (word.left - s(BUTTONS_GAP)).max(text_left), row.bottom);
    (name, word)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    Section(Section),
    /// The index into the plugins shown.
    Plugin(usize),
}

/// What a click at `(x, y)` is on. Only inside the sidebar, and only above
/// the bottom rule: a row that has run into the bottom band is not a row a
/// click can find.
pub fn hit(l: &Layout, sb: &Sidebar, x: i32, y: i32) -> Option<Hit> {
    // Rows scrolled out of the window are not under the pointer.
    let (top, bottom) = sidebar_view(l);
    if x < l.sidebar.left || x >= l.sidebar.right || y >= bottom || y < top {
        return None;
    }
    let inside = |r: &Rect| y >= r.top && y < r.bottom;
    if let Some(i) = sb.sections.iter().position(inside) {
        return Some(Hit::Section(Section::ALL[i]));
    }
    sb.plugins.iter().position(inside).map(Hit::Plugin)
}

/// ↑ / ↓ through the sidebar, plugins included: the row after or before
/// `current`, stopping at the ends.
pub fn step_sidebar(current: Option<Hit>, plugins: usize, down: bool) -> Hit {
    let order: Vec<Hit> = [Hit::Section(Section::Roles), Hit::Section(Section::Projects), Hit::Section(Section::Plugins)]
        .into_iter()
        .chain((0..plugins).map(Hit::Plugin))
        .chain(Some(Hit::Section(Section::General)))
        .collect();
    let i = current.and_then(|c| order.iter().position(|h| *h == c));
    order[crate::step(i, order.len(), down).unwrap_or(0)]
}

// ================================================================= detail

/// What the detail's layout needs measured by whoever has the fonts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DetailInput {
    /// The restart banner is up (§5.2 item 6).
    pub banner: bool,
    /// The title block -- name, version and author, summary, what it is
    /// handed -- measured at the editor's width, in pixels.
    pub head_h: i32,
    /// One line of the log's font, in pixels.
    pub log_line_h: i32,
}

/// How many log lines the log box shows at once. The file's last 20 are in
/// it (§5.2 item 5); the rest are a scroll away.
pub const LOG_VISIBLE: i32 = 4;
/// The fewest log lines shown when the window is short: the log gives way
/// to the form first, down to this (task 990).
pub const LOG_MIN: i32 = 2;
/// How many lines of the log are read.
pub const LOG_LINES: usize = 20;
/// The restart banner's height, the roles section's banner's.
pub const BANNER_H: i32 = 44;
/// The least room the tab's body is left, so a form row and a half show at
/// the smallest window (§2.2: nothing cut off).
pub const BODY_MIN: i32 = CONTROL_H * 2 + ROW_GAP;

/// The detail's blocks, top to bottom (§5.2), in the section's coordinates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Detail {
    pub banner: Option<Rect>,
    pub head: Rect,
    /// The switch: in the control column, one control tall.
    pub switch: Rect,
    /// Beside the switch: which required parameters are missing.
    pub switch_note: Rect,
    pub tabs: Rect,
    /// The selected tab's body: the form (scrolls) or the page.
    pub body: Rect,
    /// The log's heading row, with Show Log and Show Plugin Folder on its
    /// right.
    pub log_head: Rect,
    pub log_buttons: [Rect; 2],
    pub log: Rect,
    /// Left edges: the editor's margin and the form's control column.
    pub left: i32,
    pub control_left: i32,
}

/// Width of one of the log's two buttons.
pub const LOG_BUTTON_W: i32 = 144;
/// Width of one tab in the tab row.
pub const TAB_W: i32 = 112;

/// The detail inside `editor` (`SectionGrid::editor`), at `dpi`.
pub fn detail(editor: Rect, dpi: i32, input: DetailInput) -> Detail {
    let s = |v| scale(v, dpi);
    let left = editor.left + s(PAD);
    let right = editor.right - s(PAD);
    let control_left = left + s(LABEL_W) + s(LABEL_GAP);
    let line = input.log_line_h.max(1);
    let log_h = |lines: i32| line * lines + 2;
    let banner_h = if input.banner { s(BANNER_H) + s(ROW_GAP) } else { 0 };

    // **What the form is owed comes first** (task 990: at 144 DPI the
    // smallest window left it 68px). Everything but the title block and the
    // log is fixed; the form keeps `BODY_MIN`; the log gives way down to
    // `LOG_MIN` lines; and only then is the title block cut -- to at least
    // one control's height, its first line, the plugin's name.
    let fixed = s(PAD) + banner_h + s(GROUP_GAP) + s(CONTROL_H) + s(ROW_GAP) + s(CONTROL_H) + s(ROW_GAP)
        + s(GROUP_GAP) + s(CONTROL_H) + s(ROW_GAP) + s(PAD);
    let room = editor.height() - fixed - s(BODY_MIN);
    let mut lines = LOG_VISIBLE;
    while lines > LOG_MIN && input.head_h.max(0) + log_h(lines) > room {
        lines -= 1;
    }
    let head_h = input.head_h.max(0).min((room - log_h(lines)).max(s(CONTROL_H)));

    let mut y = editor.top + s(PAD);
    let banner = input.banner.then(|| {
        let r = Rect::new(left, y, right, y + s(BANNER_H));
        y = r.bottom + s(ROW_GAP);
        r
    });
    let head = Rect::new(left, y, right, y + head_h);
    y = head.bottom + s(GROUP_GAP);
    let switch_w = s(ACTION_W[0]);
    let switch = Rect::new(control_left, y, (control_left + switch_w).min(right), y + s(CONTROL_H));
    let switch_note = Rect::new((switch.right + s(BUTTONS_GAP)).min(right), y, right, switch.bottom);
    // The tabs belong to the switch's plugin as much as the switch does:
    // a row gap, not a group gap.
    y = switch.bottom + s(ROW_GAP);
    let tabs = Rect::new(left, y, right, y + s(CONTROL_H));
    y = tabs.bottom + s(ROW_GAP);

    // The log from the bottom up, then the body takes what is between.
    let bottom = editor.bottom - s(PAD);
    let log = Rect::new(left, (bottom - log_h(lines)).max(y), right, bottom);
    let log_head = Rect::new(left, log.top - s(ROW_GAP) - s(CONTROL_H), right, log.top - s(ROW_GAP));
    let b1 = Rect::new(right - s(LOG_BUTTON_W), log_head.top, right, log_head.bottom);
    let b0 = Rect::new(b1.left - s(BUTTONS_GAP) - s(LOG_BUTTON_W), log_head.top, b1.left - s(BUTTONS_GAP), log_head.bottom);
    let body = Rect::new(left, y, right, (log_head.top - s(GROUP_GAP)).max(y));
    Detail { banner, head, switch, switch_note, tabs, body, log_head, log_buttons: [b0, b1], log, left, control_left }
}

/// One tab's box in the tab row, `index` from the left.
pub fn tab_rect(d: &Detail, dpi: i32, index: usize) -> Rect {
    let w = scale(TAB_W, dpi);
    let l = d.tabs.left + index as i32 * w;
    Rect::new(l, d.tabs.top, l + w, d.tabs.bottom)
}

/// The tabs of §5.2 item 3: Settings always, Page when the plugin brings
/// one -- **and Page stays even when WebView2 cannot show it** (§5.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Settings,
    Page,
}

pub fn tabs(has_page: bool) -> Vec<Tab> {
    if has_page {
        vec![Tab::Settings, Tab::Page]
    } else {
        vec![Tab::Settings]
    }
}

/// One parameter's row in the form: label column right-aligned (§2.3a),
/// control in the control column, the manifest's help under the control.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FormRow {
    pub label: Rect,
    pub control: Rect,
    pub help: Option<Rect>,
}

/// The form inside the body, in the body's own coordinates, before
/// scrolling. `helps` holds each parameter's measured help height (0 for
/// none). Returns the rows and the content height.
pub fn form(body_w: i32, dpi: i32, helps: &[i32]) -> (Vec<FormRow>, i32) {
    let rows: Vec<(i32, i32)> = helps.iter().map(|&h| (0, h)).collect();
    form_labeled(body_w, dpi, &rows)
}

/// `form`, with each label's height as wrapped in the label column: a
/// label longer than `LABEL_W` wraps onto more lines instead of being cut
/// (task 990: "给每一行签名的…"), and the row is as tall as the taller of the
/// label and the control with its help. `rows` is `(label_h, help_h)`.
pub fn form_labeled(body_w: i32, dpi: i32, rows: &[(i32, i32)]) -> (Vec<FormRow>, i32) {
    let s = |v| scale(v, dpi);
    let label_left = 0;
    let control_left = s(LABEL_W) + s(LABEL_GAP);
    let right = body_w.max(control_left + s(40));
    let mut y = 0;
    let mut out = Vec::new();
    for &(label_h, help_h) in rows {
        let label = Rect::new(label_left, y, s(LABEL_W), y + label_h.max(s(CONTROL_H)));
        let control = Rect::new(control_left, y, right, y + s(CONTROL_H));
        let mut bottom = control.bottom;
        let help = (help_h > 0).then(|| {
            let r = Rect::new(control_left, bottom + s(BUTTON_GAP), right, bottom + s(BUTTON_GAP) + help_h);
            bottom = r.bottom;
            r
        });
        out.push(FormRow { label, control, help });
        y = bottom.max(label.bottom) + s(ROW_GAP);
    }
    (out, y)
}

/// The last `n` lines of a log's text, oldest first. A trailing newline
/// makes no empty last line, and CRLF is one break.
pub fn tail(text: &str, n: usize) -> Vec<String> {
    let lines: Vec<&str> = text.lines().collect();
    let from = lines.len().saturating_sub(n);
    lines[from..].iter().map(|l| l.trim_end_matches('\r').to_string()).collect()
}

// ============================================================== the page

/// The scheme a plugin's page is served over, and the one the macOS side
/// uses (`PluginPage.scheme`).
pub const SCHEME: &str = "polter-plugin";

/// The `Content-Security-Policy` sent with every response: this origin
/// only, no network of any kind. The same policy `PluginPage.swift` sends.
///
/// **The macOS side's policy, directive for directive** (`PluginPage.policy`),
/// so the two hosts allow a page the same things. `connect-src 'none'` is the
/// one that matters most and it is meant: **a page cannot `fetch` at all**,
/// not even a file of its own -- its data comes through `window.polter`, and
/// the request is stopped in the page before it is made, so `serve` never
/// sees it (task 999: `fetch('../plugin.json')` gave `TypeError`, not 403,
/// on the Windows test machine; that is this line working). The Windows
/// policy this replaces was looser than the Mac's (`'unsafe-eval'`, `blob:`
/// and `data:` everywhere).
pub const CSP: &str = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; \
img-src 'self' data:; font-src 'self' data:; connect-src 'none'; frame-src 'none'; object-src 'none'; \
form-action 'none'; base-uri 'none'; frame-ancestors 'none'";

/// The page's entry URL. The key is the host, so two plugins' pages are
/// two origins.
pub fn entry_url(key: &str) -> String {
    format!("{SCHEME}://{key}/index.html")
}

/// Why a request was not served.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refused {
    /// Not this scheme: the network, `file:`, anything.
    OtherScheme,
    /// This scheme, another plugin's origin.
    OtherPlugin,
    /// A path that would leave `ui/`, or one that cannot be read as a path.
    OutsideUi,
}

/// The file a request asks for, relative to the plugin's `ui/`, as path
/// segments -- or why it is refused. **Every request passes here**: a page
/// may not leave its own `ui/` (the fence `PluginPageBridge.resolve` is on
/// the macOS side). The query and fragment are ignored; `/` is
/// `index.html`.
pub fn resolve(url: &str, key: &str) -> Result<Vec<String>, Refused> {
    let prefix = format!("{SCHEME}://");
    let Some(rest) = url.get(..prefix.len()).filter(|p| p.eq_ignore_ascii_case(&prefix)).map(|_| &url[prefix.len()..])
    else {
        return Err(Refused::OtherScheme);
    };
    let (host, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    if !host.eq_ignore_ascii_case(key) {
        return Err(Refused::OtherPlugin);
    }
    let path = path.split(['?', '#']).next().unwrap_or("/");
    let decoded = percent_decode(path).ok_or(Refused::OutsideUi)?;
    let mut segs: Vec<String> = Vec::new();
    for seg in decoded.split(['/', '\\']) {
        match seg {
            "" | "." => {}
            ".." => return Err(Refused::OutsideUi),
            s if s.contains(':') || s.contains('\0') => return Err(Refused::OutsideUi),
            s => segs.push(s.to_string()),
        }
    }
    if segs.is_empty() {
        segs.push("index.html".into());
    }
    Ok(segs)
}

/// `%XX` decoded, as UTF-8. `None` for a malformed escape or bytes that
/// are not UTF-8: a path that cannot be read is not guessed at.
fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The `Content-Type` for a file, by extension -- the table
/// `PluginPageBridge.contentType` has.
pub fn content_type(file: &str) -> &'static str {
    let ext = file.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "ttf" => "font/ttf",
        _ => "application/octet-stream",
    }
}

/// Whether the page tab can show the page, and if not, which of the three
/// reasons (§5.3: the tab stays, and says what is missing).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PageState {
    /// `WebView2Loader.dll` is not beside the executable: the install is
    /// incomplete, and installing the Runtime would not help.
    LoaderMissing,
    /// The loader is there and finds no WebView2 Runtime on this machine.
    RuntimeMissing,
    /// The Runtime is there and making the view failed, with this HRESULT.
    Failed(i32),
    /// Being made.
    Loading,
    Ready,
}

/// Where to get the Runtime, said in the page tab when it is missing.
pub const RUNTIME_URL: &str = "https://developer.microsoft.com/microsoft-edge/webview2/";

/// Which state the probe's answers mean. `loader` is whether the DLL
/// loaded and had the entry point; `version` is what
/// `GetAvailableCoreWebView2BrowserVersionString` answered (`Err` with its
/// HRESULT, or an empty version, both mean no Runtime).
pub fn page_state(loader: bool, version: Result<&str, i32>) -> PageState {
    if !loader {
        return PageState::LoaderMissing;
    }
    match version {
        Ok(v) if !v.trim().is_empty() => PageState::Loading,
        _ => PageState::RuntimeMissing,
    }
}

/// A key the page's web view must hand back to the settings window rather
/// than keep (task 1003): with the keyboard in the page, WebView2 sees every
/// key first, and Ctrl+W -- the settings window's close -- went nowhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageKey {
    /// Close the settings window, through its unsaved-changes question.
    Close,
}

/// `vk` is the virtual key of a key going down, with the modifiers held.
/// Only the settings window's own chords: everything else stays the page's
/// (typing, Ctrl+C in a field, Escape -- which closes nothing here, §2.3).
pub fn page_accelerator(vk: u32, ctrl: bool, shift: bool, alt: bool) -> Option<PageKey> {
    const VK_W: u32 = 0x57;
    (vk == VK_W && ctrl && !shift && !alt).then_some(PageKey::Close)
}

/// The calls a page may make through `window.polter` -- the whole surface
/// (`PluginPageBridge`: read, write, close).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Call {
    Read,
    Write,
    Close,
}

impl Call {
    pub fn parse(method: &str) -> Option<Call> {
        match method {
            "read" => Some(Call::Read),
            "write" => Some(Call::Write),
            "close" => Some(Call::Close),
            _ => None,
        }
    }
}

/// Whether a message came from where the bridge answers: the page's own
/// origin. A frame from anywhere else gets nothing.
pub fn message_from_page(source: &str, key: &str) -> bool {
    matches!(resolve(source, key), Ok(_))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rt(running: bool, failures: u32, note: &str) -> Option<Runtime> {
        Some(Runtime { running, failures, note: note.into() })
    }

    /// **The table the macOS side's `SettingsRules` tests too** (settings.md
    /// §5.1: one table for both). Each row: enabled, missing, restart
    /// pending, runtime, expected dot.
    #[test]
    fn dot_table() {
        let off_note = "installed but switched off";
        let idle_note = "no copy of it is running";
        let rows: &[(bool, usize, bool, Option<Runtime>, Dot)] = &[
            // ↻ beats everything, off and failing included.
            (true, 0, true, rt(true, 3, "boom"), Dot::Changed),
            (false, 2, true, rt(false, 0, off_note), Dot::Changed),
            // ○: off, whatever the core's note says about it.
            (false, 0, false, rt(false, 0, off_note), Dot::Off),
            (false, 1, false, rt(false, 0, off_note), Dot::Off),
            (false, 0, false, None, Dot::Off),
            // ◐: on, a required parameter empty -- before ▲.
            (true, 1, false, rt(true, 2, "x"), Dot::Missing),
            (true, 3, false, None, Dot::Missing),
            // ▲: running with failures, or on with a note.
            (true, 0, false, rt(true, 1, ""), Dot::Error),
            (true, 0, false, rt(false, 0, idle_note), Dot::Error),
            (true, 0, false, rt(true, 0, "backing off"), Dot::Error),
            // A note of only blanks is no note.
            (true, 0, false, rt(true, 0, "  "), Dot::On),
            // Failures counted on a copy that is not running are old news
            // and the note covers what is current.
            (true, 0, false, rt(false, 4, ""), Dot::On),
            // ●
            (true, 0, false, rt(true, 0, ""), Dot::On),
            // No runtime to read: ▲ cannot be told, so ●.
            (true, 0, false, None, Dot::On),
        ];
        for (i, (enabled, missing, restart, runtime, want)) in rows.iter().enumerate() {
            let f = Facts { enabled: *enabled, missing: *missing, restart_pending: *restart, runtime: runtime.clone() };
            assert_eq!(dot(&f), *want, "row {i}: {f:?}");
        }
    }

    fn st(on: bool, kv: &[(&str, &str)]) -> Settings {
        (on, kv.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect())
    }

    #[test]
    fn restart_pending_only_when_a_running_copy_has_other_settings() {
        let a = st(true, &[("url", "x")]);
        let b = st(true, &[("url", "y")]);
        // Running, started with a, now b: pending.
        assert!(restart_pending(Some(&a), &b, Some(true)));
        // Running with what is saved: not pending.
        assert!(!restart_pending(Some(&a), &a, Some(true)));
        // Not running: the core starts it with what was saved, nothing to
        // restart (settings.md §5.2 item 6).
        assert!(!restart_pending(Some(&a), &b, Some(false)));
        // Nothing to ask: a difference is shown, not hidden.
        assert!(restart_pending(Some(&a), &b, None));
        assert!(!restart_pending(Some(&a), &a, None));
        // Blank and absent are the same thing; order does not matter.
        let c = st(true, &[("a", "1"), ("b", "")]);
        let d = st(true, &[("a", "1")]);
        assert!(!restart_pending(Some(&c), &d, Some(true)));
        let e = st(true, &[("b", "2"), ("a", "1")]);
        let f = st(true, &[("a", "1"), ("b", "2")]);
        assert!(!restart_pending(Some(&e), &f, Some(true)));
        // Switching off is a change too.
        assert!(restart_pending(Some(&a), &st(false, &[("url", "x")]), Some(true)));
        // Never seen: running means it runs with something else.
        assert!(restart_pending(None, &a, Some(true)));
        assert!(!restart_pending(None, &a, None));
    }

    #[test]
    fn missing_required_names_empty_required_ones_in_order() {
        let p = |n: &str, t: &str, r: bool| (n.to_string(), t.to_string(), r);
        let params = vec![p("url", "Webhook", true), p("tag", "Tag", false), p("token", "Token", true)];
        let v = |kv: &[(&str, &str)]| kv.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<Vec<_>>();
        assert_eq!(missing_required(&params, &v(&[])), vec!["Webhook", "Token"]);
        assert_eq!(missing_required(&params, &v(&[("url", "https://x"), ("token", "  ")])), vec!["Token"]);
        assert!(missing_required(&params, &v(&[("url", "a"), ("token", "b")])).is_empty());
    }

    #[test]
    fn the_switch_cannot_be_turned_on_with_something_missing() {
        assert!(!switch_enabled(false, 1));
        assert!(switch_enabled(false, 0));
        // Off is always a way out.
        assert!(switch_enabled(true, 2));
    }

    #[test]
    fn plugin_rows_sit_between_plugins_and_general() {
        let dpi = 96;
        let l = crate::layout(1164, 761, dpi);
        let sb = sidebar(&l, dpi, 3);
        assert_eq!(sb.plugins.len(), 3);
        assert_eq!(sb.plugins[0].top, l.rows[2].bottom);
        assert_eq!(sb.sections[3].top, sb.plugins[2].bottom);
        // The first three sections do not move.
        assert_eq!(&sb.sections[..3], &l.rows[..3]);
        // Same box as the section rows: the highlight's left and right.
        for r in &sb.plugins {
            assert_eq!((r.left, r.right), (l.rows[0].left, l.rows[0].right));
            assert_eq!(r.height(), scale(SECTION_ROW_H, dpi));
        }
        assert_eq!(sb.plugin_text_left, l.sidebar_text_left + PAD);
        // No plugins: the phase 1 sidebar exactly.
        assert_eq!(sidebar(&l, dpi, 0).sections, l.rows);
    }

    #[test]
    fn clicks_find_sections_and_plugins() {
        let dpi = 144;
        let l = crate::layout(1700, 1100, dpi);
        let sb = sidebar(&l, dpi, 2);
        let mid = |r: &Rect| (r.left + 1, (r.top + r.bottom) / 2);
        let (x, y) = mid(&sb.plugins[1]);
        assert_eq!(hit(&l, &sb, x, y), Some(Hit::Plugin(1)));
        let (x, y) = mid(&sb.sections[3]);
        assert_eq!(hit(&l, &sb, x, y), Some(Hit::Section(Section::General)));
        let (_, y) = mid(&sb.sections[2]);
        assert_eq!(hit(&l, &sb, l.sidebar.right, y), None);
        assert_eq!(hit(&l, &sb, 2, l.bottom_rule.top), None);
    }

    #[test]
    fn arrows_walk_through_the_plugins() {
        use Hit::*;
        assert_eq!(step_sidebar(Some(Section(crate::Section::Plugins)), 2, true), Plugin(0));
        assert_eq!(step_sidebar(Some(Plugin(1)), 2, true), Section(crate::Section::General));
        assert_eq!(step_sidebar(Some(Section(crate::Section::General)), 2, false), Plugin(1));
        assert_eq!(step_sidebar(Some(Section(crate::Section::General)), 0, false), Section(crate::Section::Plugins));
        assert_eq!(step_sidebar(Some(Section(crate::Section::General)), 2, true), Section(crate::Section::General));
    }

    fn at_min(dpi: i32) -> (Rect, crate::SectionGrid) {
        let (w, h) = crate::content_size(crate::MIN_W, crate::MIN_H);
        let (w, h) = (scale(w, dpi), scale(h, dpi));
        let g = crate::section_grid(w, h, dpi, false);
        (g.editor, g)
    }

    /// The title block at its tallest, as the host can build it: name and
    /// version in one line each, the summary at its 3-line cap, what it is
    /// handed at 2, the core's note at 3 -- ten lines of a 14px Segoe UI
    /// (19px a line at 96 DPI) and four 4px gaps. **The first version of
    /// this test gave the block 96px**, a sixth of that; it stayed green
    /// while the machine at 144 DPI left the form 68px (task 990).
    fn tallest_head(dpi: i32) -> i32 {
        scale(10 * 19 + 4 * BUTTON_GAP, dpi)
    }

    #[test]
    fn detail_fits_at_the_smallest_window() {
        for dpi in [96, 120, 144, 192, 240] {
            let (editor, _) = at_min(dpi);
            // The tallest title block, and the banner up.
            let d = detail(editor, dpi, DetailInput { banner: true, head_h: tallest_head(dpi), log_line_h: scale(16, dpi) });
            assert!(d.body.height() >= scale(BODY_MIN, dpi), "dpi {dpi}: body {:?}", d.body);
            // Two control rows: what the machine's reading is measured in.
            assert!(d.body.height() >= 2 * scale(CONTROL_H, dpi), "dpi {dpi}: body {:?}", d.body);
            // The log gave way, but not away; the name is still there.
            assert!(d.log.height() >= scale(16, dpi) * LOG_MIN, "dpi {dpi}: log {:?}", d.log);
            assert!(d.head.height() >= scale(CONTROL_H, dpi), "dpi {dpi}: head {:?}", d.head);
            assert!(d.log.bottom <= editor.bottom - scale(PAD, dpi) || d.log.bottom == editor.bottom - scale(PAD, dpi));
            assert!(d.log_buttons[0].left > d.left, "dpi {dpi}: buttons run off the left");
            assert!(d.switch.right <= editor.right - scale(PAD, dpi));
        }
    }

    #[test]
    fn the_sidebar_scrolls_until_general_is_above_the_band() {
        // The machine's case: the smallest window at 144 DPI, the shipped
        // plugins and the three fixtures.
        let dpi = 144;
        let (w, h) = crate::content_size(crate::MIN_W, crate::MIN_H);
        let l = crate::layout(scale(w + SIDEBAR + 1, dpi), scale(h + TOP + 1, dpi), dpi);
        let n = 12;
        let max = sidebar_max_scroll(&l, dpi, n);
        assert!(max > 0, "twelve plugins at the minimum must overflow");
        let (_, bottom) = sidebar_view(&l);
        assert!(sidebar(&l, dpi, n).sections[3].bottom > bottom, "unscrolled, General is under the band");
        let end = sidebar_at(&l, dpi, n, max);
        assert!(end.sections[3].bottom <= bottom, "scrolled to the end, General is above it");
        // Selecting General scrolls it into view; selecting Roles back.
        let general = sidebar(&l, dpi, n).sections[3];
        assert_eq!(sidebar_scroll_to(&l, general, 0, max), general.bottom - bottom);
        let roles = sidebar(&l, dpi, n).sections[0];
        let back = sidebar_scroll_to(&l, roles, max, max);
        assert!(roles.top - back >= sidebar_view(&l).0 && roles.bottom - back <= bottom, "Roles shown whole after {back}");
        assert!(back < max);
        // A click above the rows' window -- on the top band -- finds nothing.
        assert_eq!(hit(&l, &end, 5, sidebar_view(&l).0 - 1), None);
        let g = end.sections[3];
        assert_eq!(hit(&l, &end, 5, (g.top + g.bottom) / 2), Some(Hit::Section(Section::General)));
        // Few plugins: nothing to scroll.
        assert_eq!(sidebar_max_scroll(&l, dpi, 0), 0);
    }

    #[test]
    fn the_status_word_keeps_its_measured_width() {
        let dpi = 144;
        let row = Rect::new(12, 100, 318, 148);
        let word_w = 108; // "改了未重启" at 14px x 1.5
        let (name, word) = plugin_columns(row, 48, word_w, dpi);
        assert_eq!(word.width(), word_w);
        assert_eq!(word.right, row.right - scale(PAD_SIDEBAR, dpi));
        assert_eq!(name.left, 48);
        assert_eq!(name.right, word.left - scale(BUTTONS_GAP, dpi));
    }

    #[test]
    fn a_long_label_wraps_and_pushes_the_next_row_down() {
        let dpi = 96;
        let (rows, _) = form_labeled(500, dpi, &[(3 * 19, 18), (0, 0)]);
        assert_eq!(rows[0].label.height(), 3 * 19);
        assert_eq!(rows[0].label.right, LABEL_W);
        // The control stays on the first line.
        assert_eq!(rows[0].control.top, rows[0].label.top);
        let first_bottom = rows[0].label.bottom.max(rows[0].help.unwrap().bottom);
        assert_eq!(rows[1].label.top, first_bottom + ROW_GAP);
        // A short label is one control tall, as before.
        assert_eq!(rows[1].label.height(), CONTROL_H);
    }

    #[test]
    fn the_log_gives_way_before_the_title_block() {
        // A title block that fits once the log is down to its fewest lines:
        // the log shrinks, the block keeps every pixel it asked for.
        for dpi in [96, 144] {
            let (editor, _) = at_min(dpi);
            let line = scale(16, dpi);
            let probe = detail(editor, dpi, DetailInput { banner: true, head_h: 0, log_line_h: line });
            // Room for the block with the log at LOG_MIN, but not at LOG_VISIBLE.
            let spare = probe.body.height() - scale(BODY_MIN, dpi);
            let head = spare + line * (LOG_VISIBLE - LOG_MIN) - 1;
            assert!(spare > 0, "dpi {dpi}: probe leaves {spare}");
            let d = detail(editor, dpi, DetailInput { banner: true, head_h: head, log_line_h: line });
            assert_eq!(d.head.height(), head, "dpi {dpi}: the block was cut while the log could give");
            assert!(d.log.height() < line * LOG_VISIBLE + 2, "dpi {dpi}: the log did not give way");
            assert!(d.body.height() >= scale(BODY_MIN, dpi));
        }
    }

    #[test]
    fn nothing_gives_way_when_there_is_room() {
        // A full-height window and an ordinary title block: four log lines,
        // the block as asked.
        for dpi in [96, 144] {
            let (w, h) = crate::content_size(crate::FIRST_W, crate::FIRST_H);
            let g = crate::section_grid(scale(w, dpi), scale(h, dpi), dpi, false);
            let head = scale(4 * 19, dpi);
            let d = detail(g.editor, dpi, DetailInput { banner: true, head_h: head, log_line_h: scale(16, dpi) });
            assert_eq!(d.head.height(), head, "dpi {dpi}");
            assert_eq!(d.log.height(), scale(16, dpi) * LOG_VISIBLE + 2, "dpi {dpi}");
        }
    }

    #[test]
    fn detail_uses_two_left_edges_only() {
        let dpi = 96;
        let (editor, g) = at_min(dpi);
        let d = detail(editor, dpi, DetailInput { banner: true, head_h: 60, log_line_h: 16 });
        let left = editor.left + PAD;
        // The editor's margin: the same x as the bottom band's first text.
        assert_eq!(left, g.text_left);
        for r in [d.banner.unwrap(), d.head, d.tabs, d.body, d.log_head, d.log] {
            assert_eq!(r.left, left, "{r:?}");
        }
        assert_eq!(d.switch.left, left + LABEL_W + LABEL_GAP);
        assert_eq!(d.control_left, d.switch.left);
        // The form's control column is the same line, in the body's
        // coordinates.
        let (rows, _) = form(d.body.width(), dpi, &[0, 18]);
        assert_eq!(d.body.left + rows[0].control.left, d.control_left);
        assert_eq!(rows[0].label.right, LABEL_W);
    }

    #[test]
    fn form_rows_stack_with_help_under_the_control() {
        let dpi = 96;
        let (rows, h) = form(500, dpi, &[0, 20, 0]);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].help, None);
        let help = rows[1].help.unwrap();
        assert_eq!(help.left, rows[1].control.left);
        assert_eq!(help.top, rows[1].control.bottom + BUTTON_GAP);
        assert_eq!(rows[2].control.top, help.bottom + ROW_GAP);
        assert_eq!(h, rows[2].control.bottom + ROW_GAP);
    }

    #[test]
    fn page_tab_stays_when_the_page_cannot_show() {
        assert_eq!(tabs(false), vec![Tab::Settings]);
        assert_eq!(tabs(true), vec![Tab::Settings, Tab::Page]);
        assert_eq!(page_state(false, Ok("120.0")), PageState::LoaderMissing);
        assert_eq!(page_state(true, Err(-2147024894)), PageState::RuntimeMissing);
        assert_eq!(page_state(true, Ok("")), PageState::RuntimeMissing);
        assert_eq!(page_state(true, Ok("128.0.2739.42")), PageState::Loading);
    }

    #[test]
    fn requests_stay_inside_ui() {
        let k = "feishu";
        assert_eq!(resolve("polter-plugin://feishu/index.html", k), Ok(vec!["index.html".to_string()]));
        assert_eq!(resolve("polter-plugin://feishu/", k), Ok(vec!["index.html".to_string()]));
        assert_eq!(resolve("polter-plugin://feishu", k), Ok(vec!["index.html".to_string()]));
        assert_eq!(resolve("POLTER-PLUGIN://Feishu/a/b.js?v=1#x", k), Ok(vec!["a".to_string(), "b.js".to_string()]));
        assert_eq!(resolve("polter-plugin://feishu/a%20b.css", k), Ok(vec!["a b.css".to_string()]));
        assert_eq!(resolve("polter-plugin://feishu/../plugin.json", k), Err(Refused::OutsideUi));
        assert_eq!(resolve("polter-plugin://feishu/a/%2e%2e/%2e%2e/x", k), Err(Refused::OutsideUi));
        assert_eq!(resolve("polter-plugin://feishu/..%5c..%5cx", k), Err(Refused::OutsideUi));
        assert_eq!(resolve("polter-plugin://feishu/C:%5cWindows", k), Err(Refused::OutsideUi));
        assert_eq!(resolve("polter-plugin://feishu/%zz", k), Err(Refused::OutsideUi));
        assert_eq!(resolve("polter-plugin://slack/index.html", k), Err(Refused::OtherPlugin));
        assert_eq!(resolve("https://example.com/", k), Err(Refused::OtherScheme));
        assert_eq!(resolve("file:///C:/keys/id_rsa", k), Err(Refused::OtherScheme));
        assert_eq!(resolve("polter", k), Err(Refused::OtherScheme));
        assert!(message_from_page(&entry_url(k), k));
        assert!(!message_from_page("https://evil.example/", k));
    }

    #[test]
    fn content_types_are_the_macos_table() {
        assert_eq!(content_type("index.HTML"), "text/html; charset=utf-8");
        assert_eq!(content_type("app.mjs"), "text/javascript; charset=utf-8");
        assert_eq!(content_type("x.woff2"), "font/woff2");
        assert_eq!(content_type("README"), "application/octet-stream");
        assert!(CSP.contains("connect-src 'none'"));
        // The macOS policy, word for word (`PluginPage.policy`): the same
        // eleven directives in the same order.
        let mac = [
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data:",
            "font-src 'self' data:",
            "connect-src 'none'",
            "frame-src 'none'",
            "object-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
            "frame-ancestors 'none'",
        ]
        .join("; ");
        assert_eq!(CSP, mac);
        assert!(!CSP.contains("unsafe-eval") && !CSP.contains("blob:"));
    }

    #[test]
    fn the_log_tail_is_the_last_lines_oldest_first() {
        let text: String = (1..=25).map(|i| format!("line {i}\r\n")).collect();
        let t = tail(&text, LOG_LINES);
        assert_eq!(t.len(), 20);
        assert_eq!(t[0], "line 6");
        assert_eq!(t[19], "line 25");
        assert_eq!(tail("a\nb", 20), vec!["a", "b"]);
        assert!(tail("", 20).is_empty());
    }

    #[test]
    fn only_the_settings_windows_own_chord_leaves_the_page() {
        assert_eq!(page_accelerator(0x57, true, false, false), Some(PageKey::Close));
        // W alone is typing; Ctrl+Shift+W and AltGr (Ctrl+Alt) are not the chord.
        assert_eq!(page_accelerator(0x57, false, false, false), None);
        assert_eq!(page_accelerator(0x57, true, true, false), None);
        assert_eq!(page_accelerator(0x57, true, false, true), None);
        // Ctrl+C and Escape stay the page's.
        assert_eq!(page_accelerator(0x43, true, false, false), None);
        assert_eq!(page_accelerator(0x1B, false, false, false), None);
    }

    #[test]
    fn the_blocks_move_down_together_as_the_red_note_grows() {
        // A plugin turning red adds the core's note -- one or two lines --
        // to the title block (task 1003: the switch stayed where it was and
        // the note was painted under it). Every block below moves down by
        // what the block grew, none overlaps the next.
        for dpi in [96, 144] {
            let (w, h) = crate::content_size(crate::FIRST_W, crate::FIRST_H);
            let g = crate::section_grid(scale(w, dpi), scale(h, dpi), dpi, false);
            let line = scale(19, dpi);
            let base = scale(4 * 19, dpi);
            let mut prev: Option<Detail> = None;
            for lines in 0..=2 {
                let d = detail(g.editor, dpi, DetailInput { banner: false, head_h: base + lines * line, log_line_h: scale(16, dpi) });
                assert!(d.head.bottom <= d.switch.top, "dpi {dpi}, {lines} line(s): switch under the head");
                assert!(d.switch.bottom <= d.tabs.top, "dpi {dpi}, {lines}: tabs under the switch");
                assert!(d.tabs.bottom <= d.body.top, "dpi {dpi}, {lines}: body under the tabs");
                if let Some(p) = &prev {
                    assert_eq!(d.switch.top - p.switch.top, line, "dpi {dpi}, {lines}: the switch moves by the note's line");
                    assert_eq!(d.tabs.top - p.tabs.top, line, "dpi {dpi}, {lines}: so do the tabs");
                }
                prev = Some(d);
            }
        }
    }

    #[test]
    fn the_bridge_has_three_calls() {
        assert_eq!(Call::parse("read"), Some(Call::Read));
        assert_eq!(Call::parse("write"), Some(Call::Write));
        assert_eq!(Call::parse("close"), Some(Call::Close));
        assert_eq!(Call::parse("terminal_send"), None);
    }
}
