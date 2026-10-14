//! Settings › General › Log Management on Windows (task 1511): where each
//! part of a row goes, what a retention field writes, and what each
//! "Clear…" asks first. The macOS side is `LogManagementRules.swift` and
//! `LogManagementColumns`; the words are the same English msgids, and the
//! numbers here are the same numbers (`log-management-windows-v1`).
//!
//! The figures themselves are the core's (`ghostty_app_storage_usage`,
//! `Storage.writeUsage`): the host reads the JSON into [`Kind`]s and asks
//! this crate everything else.

use crate::grid::{GROUP_GAP, PAD, ROW_GAP};
use crate::{n_, scale, Rect};

/// One row, as the core describes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Kind {
    pub key: String,
    /// `cycle`, `fixed` or `forever`.
    pub kept: String,
    pub bytes: u64,
    pub files: u64,
    pub days_key: Option<String>,
    pub mb_key: Option<String>,
    pub fixed_days: Option<u64>,
    /// `clear` or `compact`.
    pub action: String,
}

impl Kind {
    /// In the first group: kept going round, by setting or fixed.
    pub fn goes_round(&self) -> bool {
        self.kept != "forever"
    }
}

/// The columns, right to left from the content's right edge, in DIP.
pub const BUTTON_W: i32 = 80;
pub const SIZE_W: i32 = 72;
pub const DAYS_W: i32 = 44;
pub const MB_W: i32 = 56;
/// A field's unit after it ("天", "MB"), with the four between.
pub const UNIT_W: i32 = 28;
pub const COL_GAP: i32 = 8;
pub const ROW_H: i32 = 40;
/// A row's two lines: the name over the description.
pub const LINE_GAP: i32 = 2;

/// Where one row's parts go, in the page's coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RowParts {
    pub row: Rect,
    /// The name and the description, one over the other.
    pub text: Rect,
    /// The days field, its unit after it; or the words that stand in for
    /// both fields ("Not by days", "Fixed at …", "Kept for good").
    pub days: Rect,
    pub days_unit: Rect,
    pub mb: Rect,
    pub mb_unit: Rect,
    /// Both fields and their units: where a row with none says its rule.
    pub rule: Rect,
    pub size: Rect,
    pub button: Rect,
}

/// The parts of a row whose top is `top`, between `left` and `right`.
pub fn row_parts(left: i32, right: i32, top: i32, dpi: i32, control_h: i32) -> RowParts {
    let s = |v| scale(v, dpi);
    let row = Rect::new(left, top, right, top + s(ROW_H));
    let mid = |h: i32| top + (s(ROW_H) - h) / 2;
    let button = Rect::new(right - s(BUTTON_W), mid(control_h), right, mid(control_h) + control_h);
    let size = Rect::new(button.left - s(COL_GAP) - s(SIZE_W), top, button.left - s(COL_GAP), row.bottom);
    let mb_unit = Rect::new(size.left - s(COL_GAP) - (s(UNIT_W) - s(4)), top, size.left - s(COL_GAP), row.bottom);
    let field_h = control_h - s(6);
    let mb = Rect::new(mb_unit.left - s(4) - s(MB_W), mid(field_h), mb_unit.left - s(4), mid(field_h) + field_h);
    let days_unit = Rect::new(mb.left - s(COL_GAP) - (s(UNIT_W) - s(4)), top, mb.left - s(COL_GAP), row.bottom);
    let days = Rect::new(days_unit.left - s(4) - s(DAYS_W), mid(field_h), days_unit.left - s(4), mid(field_h) + field_h);
    let rule = Rect::new(days.left, top, mb_unit.right, row.bottom);
    let text = Rect::new(left, top, (days.left - s(COL_GAP)).max(left), row.bottom);
    RowParts { row, text, days, days_unit, mb, mb_unit, rule, size, button }
}

/// Where each row of the page goes, and how tall the page is: the intro
/// line, then the two groups, each a heading and its rows. `heading_h` is
/// a line of text.
pub struct PageLayout {
    pub intro: Rect,
    pub cycle_heading: Rect,
    pub forever_heading: Rect,
    /// In the order the rows are listed: every `goes_round` one, then the rest.
    pub rows: Vec<RowParts>,
    pub height: i32,
}

pub fn page_layout(width: i32, dpi: i32, line_h: i32, control_h: i32, cycle: usize, forever: usize) -> PageLayout {
    let s = |v| scale(v, dpi);
    let left = s(PAD);
    let right = width - s(PAD);
    let mut y = s(PAD);
    let intro = Rect::new(left, y, right, y + line_h);
    y += line_h + s(GROUP_GAP);
    let mut rows = Vec::new();
    let cycle_heading = Rect::new(left, y, right, y + line_h);
    y += line_h + s(ROW_GAP);
    for _ in 0..cycle {
        rows.push(row_parts(left, right, y, dpi, control_h));
        y += s(ROW_H) + s(ROW_GAP);
    }
    y += s(GROUP_GAP) - s(ROW_GAP);
    let forever_heading = Rect::new(left, y, right, y + line_h);
    y += line_h + s(ROW_GAP);
    for _ in 0..forever {
        rows.push(row_parts(left, right, y, dpi, control_h));
        y += s(ROW_H) + s(ROW_GAP);
    }
    PageLayout { intro, cycle_heading, forever_heading, rows, height: y - s(ROW_GAP) + s(PAD) }
}

/// What a retention field shows for the value in the config file.
pub fn field_text(value: &str, no_limit: &str) -> String {
    if value == "unlimited" { no_limit.to_string() } else { value.to_string() }
}

/// What to write for what was typed: a whole number, or `unlimited` for an
/// empty field, the words for no limit, or "unlimited". `None` when it is
/// neither, and then nothing is written.
pub fn value_to_write(typed: &str, no_limit: &str) -> Option<String> {
    let t = typed.trim();
    if t.is_empty() || t == no_limit || t.eq_ignore_ascii_case("unlimited") {
        return Some("unlimited".into());
    }
    t.parse::<u32>().ok().map(|n| n.to_string())
}

/// A size, the way Explorer writes one: KB, MB, GB with one decimal past
/// the first unit.
pub fn size_text(bytes: u64) -> String {
    const K: f64 = 1024.0;
    let b = bytes as f64;
    if b < K {
        format!("{bytes} B")
    } else if b < K * K {
        format!("{:.0} KB", b / K)
    } else if b < K * K * K {
        format!("{:.1} MB", b / (K * K))
    } else {
        format!("{:.2} GB", b / (K * K * K))
    }
}

/// The English msgid of a row's name.
pub fn title_msgid(key: &str) -> &'static str {
    match key {
        "group_transcripts" => n_("Terminal Records · In Groups"),
        "project_transcripts" => n_("Terminal Records · In Projects"),
        "other_transcripts" => n_("Terminal Records · Other"),
        "logs" => n_("Logs"),
        "shots" => n_("Screenshots"),
        "rename_backups" => n_("Group Rename Backups"),
        "chat" => n_("Group Chat Records"),
        "tasks" => n_("Task Records"),
        "history" => n_("Shell History"),
        _ => n_("Archive Plugin's Copy"),
    }
}

pub fn detail_msgid(key: &str) -> &'static str {
    match key {
        "group_transcripts" => n_("What terminals printed while working in a group; supervisors look back through it"),
        "project_transcripts" => n_("In a project's tabs, while in no group"),
        "other_transcripts" => n_("Terminals in no group and no project"),
        "logs" => n_("Plugins' older logs, crash reports, hourly group snapshots"),
        "shots" => n_("Polter's screenshots; nothing else in the folder is touched"),
        "rename_backups" => n_("Old files a rename set aside, only to finish an interrupted one"),
        "chat" => n_("What each group said, day by day"),
        "tasks" => n_("The task panel's history; compacting keeps where each task stands"),
        "history" => n_("Each pane's commands; clearing removes only what no project uses"),
        _ => n_("The archive plugin's own copy of the chat, not Polter's records"),
    }
}

/// What "Clear…" asks: a title and lines, each an English msgid that may
/// hold `%@` (a size) or, for the first line of most, `%1$@` and `%2$lld`
/// (a size and a count of files) -- the macOS side's format strings, so
/// the two hosts share their translations' wording.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Confirmation {
    /// "Clear “%@”?" (the row's name goes in), or a whole question.
    pub title: &'static str,
    pub lines: Vec<&'static str>,
    /// The button that does it; "Cancel" is the other, and the default.
    pub button: &'static str,
}

pub fn confirmation(key: &str) -> Confirmation {
    const DELETED: &str = n_("%1$@ (%2$lld files) will be deleted. This cannot be undone.");
    const LOOK_BACK: &str = n_("After this, the AI can no longer find them when it looks back.");
    const TODAY: &str = n_("Today's file that is still being written is kept.");
    const NAMED: &str = n_("Clear “%@”?");
    const CLEAR: &str = n_("Clear Now");
    let c = |title, lines: Vec<&'static str>, button| Confirmation { title, lines, button };
    match key {
        "group_transcripts" => c(NAMED, vec![DELETED, n_("These are what terminals printed while working in a group."), LOOK_BACK, TODAY], CLEAR),
        "project_transcripts" => c(NAMED, vec![DELETED, n_("These are what terminals printed in a project's tabs while in no group."), LOOK_BACK, TODAY], CLEAR),
        "other_transcripts" => c(NAMED, vec![DELETED, n_("These are what terminals printed while in no group and no project's tab."), LOOK_BACK, TODAY], CLEAR),
        "logs" => c(NAMED, vec![DELETED, n_("They are only for finding out what went wrong; nothing Polter does depends on them."), TODAY], CLEAR),
        "shots" => c(NAMED, vec![DELETED, n_("Only Polter's own screenshots go; nothing else in the folder is touched. The AI can no longer list or open them.")], CLEAR),
        "rename_backups" => c(NAMED, vec![DELETED, n_("They are only needed to finish a rename that was interrupted, and none is under way.")], CLEAR),
        "chat" => c(
            n_("Clear the group chat records?"),
            vec![
                n_("Every group's chat before today will be deleted, at most %@. This cannot be undone."),
                n_("The list of groups, their notes, the last supervisor and project ties are kept."),
                n_("The chat page and the AI reading back a group can no longer reach messages before today."),
            ],
            CLEAR,
        ),
        "tasks" => c(
            n_("Compact the task records?"),
            vec![
                n_("Each task keeps only where it stands now: title, owner, progress, open or closed. The history of changes before today, at most %@, will be deleted. This cannot be undone."),
                n_("The task panel is unchanged and task numbers stay the same."),
                n_("The history of task changes and the statistics page will no longer show events before today."),
            ],
            n_("Compact"),
        ),
        "history" => c(
            n_("Clear shell history?"),
            vec![
                n_("History files no saved project and no open pane uses will be deleted, at most %@. This cannot be undone."),
                n_("Panes opened from a project, and panes open now, keep their history."),
            ],
            CLEAR,
        ),
        _ => c(
            NAMED,
            vec![
                n_("The archive plugin's copies before today will be deleted, at most %@. This cannot be undone."),
                n_("This is the archive plugin's own copy of the chat; Polter's chat records are not touched."),
            ],
            CLEAR,
        ),
    }
}

/// Put a translated format string's values in: `%@` / `%1$@` the first
/// string, `%2$lld` / `%lld` the number. Only these, which are all the
/// format strings above use.
pub fn fill(format: &str, first: &str, number: u64) -> String {
    format
        .replace("%1$@", first)
        .replace("%@", first)
        .replace("%2$lld", &number.to_string())
        .replace("%lld", &number.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_columns_are_the_drawings() {
        // log-management-windows-v1/README.md, at 96 DPI, in the editor
        // that starts at 482 and ends at 1180: content 498..1164.
        let p = row_parts(498, 1164, 0, 96, 24);
        assert_eq!((p.button.left, p.button.right), (1084, 1164));
        assert_eq!((p.size.left, p.size.right), (1004, 1076));
        assert_eq!((p.mb.left, p.mb_unit.right), (912, 996));
        assert_eq!((p.days.left, p.days_unit.right), (832, 904));
        assert_eq!(p.text.right, 824);
        assert_eq!((p.rule.left, p.rule.right), (832, 996));
    }

    #[test]
    fn the_columns_scale_with_the_dpi() {
        let p = row_parts(0, 2000, 0, 192, 48);
        assert_eq!(p.button.right - p.button.left, 160);
        assert_eq!(p.row.bottom - p.row.top, 80);
    }

    #[test]
    fn rows_follow_their_headings_a_row_gap_apart() {
        let l = page_layout(698, 96, 17, 24, 2, 1);
        assert_eq!(l.rows.len(), 3);
        assert_eq!(l.rows[0].row.top, l.cycle_heading.bottom + ROW_GAP);
        assert_eq!(l.rows[1].row.top - l.rows[0].row.top, ROW_H + ROW_GAP);
        assert_eq!(l.forever_heading.top, l.rows[1].row.bottom + GROUP_GAP);
        assert_eq!(l.rows[2].row.top, l.forever_heading.bottom + ROW_GAP);
        assert_eq!(l.height, l.rows[2].row.bottom + PAD);
    }

    #[test]
    fn a_field_writes_a_number_or_unlimited_and_nothing_else() {
        assert_eq!(value_to_write("30", "不限").as_deref(), Some("30"));
        assert_eq!(value_to_write(" 512 ", "不限").as_deref(), Some("512"));
        assert_eq!(value_to_write("", "不限").as_deref(), Some("unlimited"));
        assert_eq!(value_to_write("不限", "不限").as_deref(), Some("unlimited"));
        assert_eq!(value_to_write("Unlimited", "不限").as_deref(), Some("unlimited"));
        assert_eq!(value_to_write("-1", "不限"), None);
        assert_eq!(value_to_write("1.5", "不限"), None);
        assert_eq!(field_text("unlimited", "不限"), "不限");
        assert_eq!(field_text("14", "不限"), "14");
    }

    #[test]
    fn sizes_read_the_way_explorer_writes_them() {
        assert_eq!(size_text(512), "512 B");
        assert_eq!(size_text(2048), "2 KB");
        assert_eq!(size_text(5 * 1024 * 1024 + 200 * 1024), "5.2 MB");
        assert_eq!(size_text(3 * 1024 * 1024 * 1024), "3.00 GB");
    }

    /// The user (2026-10-15): no tool names or inner words in what a person
    /// reads before deleting something.
    #[test]
    fn no_confirmation_names_a_tool() {
        for key in ["group_transcripts", "project_transcripts", "other_transcripts", "logs", "shots", "rename_backups", "chat", "tasks", "history", "archive"] {
            let c = confirmation(key);
            let text = [vec![c.title], c.lines.clone()].concat().join(" ");
            for word in ["record_", "task_history", "group_history", "log_list", "log_read", "_transcripts", "retention"] {
                assert!(!text.contains(word), "{key}: {word}");
            }
            assert!(c.lines.len() >= 2, "{key}");
        }
        assert_eq!(confirmation("tasks").button, "Compact");
    }

    #[test]
    fn a_format_takes_its_size_and_count() {
        assert_eq!(fill("%1$@ (%2$lld files) will be deleted.", "5 MB", 3), "5 MB (3 files) will be deleted.");
        assert_eq!(fill("将删除 %1$@（%2$lld 个文件）", "5 MB", 3), "将删除 5 MB（3 个文件）");
        assert_eq!(fill("Clear “%@”?", "Logs", 0), "Clear “Logs”?");
    }
}
