//! The settings search (screenshot.md §12.2, §12.3), with nothing drawn:
//! what the host hands the core to search, in which order, and where a
//! result's breadcrumb line goes.
//!
//! **Matching and ranking are the core's** (`form.zig`'s `search`, reached
//! through `ghostty_app_config_form_search`). The host lists what can be
//! found -- one entry for each thing a result can be -- and gets back
//! indices into that list, already in order. What an entry *is* and where a
//! click on it goes is the host's alone; this file keeps the two lists side
//! by side so an index can never name the wrong thing.

use crate::general::{choice_titles, items_in, row_title, Control, Group, Item, Kind, Sections};
use crate::plugins::FormRow;
use crate::Rect;

/// One thing the search can find, as the core reads it. Every field but the
/// name may be absent.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub aliases: Vec<String>,
    pub key: Option<String>,
    pub summary: Option<String>,
    pub choices: Vec<String>,
    /// The group it is drawn in, as the breadcrumb names it. Only a General
    /// row has one: `字体 大小` is then a way to ask for the size under Font.
    pub group: Option<String>,
}

/// What the result list says when the query finds nothing: the core's
/// msgid (`src/input/screenshot.zig`, `search_empty`).
pub const NO_RESULTS: &str = "No settings match.";

/// Whether the box holds a search at all: an empty box, or one of spaces,
/// is the page as it was.
pub fn is_search(query: &str) -> bool {
    !query.trim().is_empty()
}

/// What a change of the box means for where the window is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// Nothing was being searched and nothing is.
    Idle,
    /// The first character: remember where the window is, then show results.
    Begin,
    /// Still searching: show this query's results.
    Continue,
    /// The box was cleared: go back to where the search began.
    End,
}

pub fn step(searching: bool, query: &str) -> Step {
    match (searching, is_search(query)) {
        (false, false) => Step::Idle,
        (false, true) => Step::Begin,
        (true, true) => Step::Continue,
        (true, false) => Step::End,
    }
}

/// The General section's own entries: every row of every group the core's
/// table fills, group by group in the list's order, each group's rows in
/// the table's. A key in two groups would be found twice and is not -- the
/// first group has it. All Options' unnamed keys are not entries: a result
/// is a row with a name.
///
/// Returns each entry with the item it is (an index into `items`) and the
/// group it lives in.
pub fn form_entries(items: &[Item], sections: &Sections, translate: impl Fn(&str) -> String) -> Vec<(usize, Group, Entry)> {
    let mut out: Vec<(usize, Group, Entry)> = Vec::new();
    for group in Group::ALL {
        if group.core().is_none() {
            continue;
        }
        for i in items_in(group, items, sections, "") {
            if out.iter().any(|(seen, _, _)| *seen == i) {
                continue;
            }
            let mut entry = form_entry(&items[i], &translate);
            entry.group = Some(translate(group.msgid()));
            out.push((i, group, entry));
        }
    }
    out
}

/// One row as an entry (§12.3's table): its name in the user's language;
/// the table's aliases, and the English name too when the name shown is not
/// English, so `font` still finds 字体; the key (a shortcut row's is its
/// action); its sentence; and what its values are called.
pub fn form_entry(it: &Item, translate: impl Fn(&str) -> String) -> Entry {
    let name = row_title(it, &translate);
    let mut aliases = it.aliases.clone();
    if let Some(english) = it.label.as_deref().filter(|l| it.kind != Kind::Jump && **l != name) {
        aliases.push(english.to_string());
    }
    let summary = match it.kind {
        Kind::Jump => it.summary.clone(),
        _ => it.summary.as_deref().map(&translate),
    };
    let choices = if it.control == Control::Choice { choice_titles(it, &translate) } else { Vec::new() };
    Entry { name, aliases, key: (!it.key.is_empty()).then(|| it.key.clone()), summary, choices, group: None }
}

/// A JSON string literal. This crate has no dependencies, so no serializer;
/// the entries are names people typed, and a quote or a newline in one must
/// not end the document early.
fn quoted(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn list(items: &[String], out: &mut String) {
    out.push('[');
    for (i, s) in items.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        quoted(s, out);
    }
    out.push(']');
}

/// The `entries` document: an array, **one object per entry, in order** --
/// an entry with nothing but a name is still an object, because a hit is
/// an index into this array.
pub fn json(entries: &[Entry]) -> String {
    let mut out = String::from("[");
    for (i, e) in entries.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str("{\"name\":");
        quoted(&e.name, &mut out);
        if !e.aliases.is_empty() {
            out.push_str(",\"aliases\":");
            list(&e.aliases, &mut out);
        }
        if let Some(k) = &e.key {
            out.push_str(",\"key\":");
            quoted(k, &mut out);
        }
        if let Some(s) = &e.summary {
            out.push_str(",\"summary\":");
            quoted(s, &mut out);
        }
        if !e.choices.is_empty() {
            out.push_str(",\"choices\":");
            list(&e.choices, &mut out);
        }
        if let Some(g) = &e.group {
            out.push_str(",\"group\":");
            quoted(g, &mut out);
        }
        out.push('}');
    }
    out.push(']');
    out
}

/// The hits that name an entry there is, in the order given. An index past
/// the end -- the list changed between the asking and the answer -- is left
/// out rather than shown as some other row.
pub fn valid_hits(hits: &[usize], entries: usize) -> Vec<usize> {
    let mut out: Vec<usize> = Vec::new();
    for &h in hits {
        if h < entries && !out.contains(&h) {
            out.push(h);
        }
    }
    out
}

/// The result list's rows: `rows` as the form lays them out, each moved
/// down to make room for one breadcrumb line above it, `crumb_h` tall and
/// `gap` clear of its row. Returns the rows, each row's breadcrumb line
/// (from the label column's left to the control column's right), and the
/// new content height.
pub fn with_crumbs(rows: &[FormRow], total: i32, crumb_h: i32, gap: i32) -> (Vec<FormRow>, Vec<Rect>, i32) {
    let step = crumb_h + gap;
    let down = |r: Rect, by: i32| Rect::new(r.left, r.top + by, r.right, r.bottom + by);
    let mut out = Vec::with_capacity(rows.len());
    let mut crumbs = Vec::with_capacity(rows.len());
    for (i, r) in rows.iter().enumerate() {
        let before = i as i32 * step;
        let by = before + step;
        let top = r.label.top.min(r.control.top) + before;
        crumbs.push(Rect::new(r.label.left, top, r.control.right, top + crumb_h));
        out.push(FormRow { label: down(r.label, by), control: down(r.control, by), help: r.help.map(|h| down(h, by)) });
    }
    (out, crumbs, total + rows.len() as i32 * step)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::general::Source;
    use crate::plugins::form_labeled;

    fn item(key: &str, group: &str, control: Control, label: &str) -> Item {
        Item {
            kind: Kind::Key,
            key: key.into(),
            group: Some(group.into()),
            control,
            choices: Vec::new(),
            choice_labels: Vec::new(),
            choice_template: None,
            on: None,
            off: None,
            aliases: Vec::new(),
            min: None,
            max: None,
            default: String::new(),
            value: String::new(),
            doc: None,
            label: Some(label.into()),
            summary: None,
            source: Source::Default,
            readonly: None,
        }
    }

    fn zh(s: &str) -> String {
        match s {
            "Font Size" => "字号".into(),
            "Font" => "字体".into(),
            "Screenshot" => "截图".into(),
            "Screenshot Folder" => "截图保存位置".into(),
            "Where screenshots are saved." => "截图存在哪里。".into(),
            "Screenshot Shortcut" => "截图快捷键".into(),
            "Off" => "关".into(),
            "%s + Click" => "%s + 单击".into(),
            other => other.to_string(),
        }
    }

    #[test]
    fn a_change_of_the_box_begins_continues_or_ends_a_search() {
        assert!(!is_search("") && !is_search("  \t") && is_search(" a "));
        assert_eq!(step(false, ""), Step::Idle);
        assert_eq!(step(false, "  "), Step::Idle);
        assert_eq!(step(false, "s"), Step::Begin);
        assert_eq!(step(true, "sc"), Step::Continue);
        assert_eq!(step(true, ""), Step::End);
        assert_eq!(step(true, "   "), Step::End);
    }

    #[test]
    fn the_forms_entries_are_its_rows_group_by_group_in_list_order() {
        let mut folder = item("screenshot-directory", "screenshot", Control::Directory, "Screenshot Folder");
        folder.summary = Some("Where screenshots are saved.".into());
        folder.aliases = vec!["capture".into(), "截屏".into()];
        let mut shortcut = item("screenshot", "screenshot", Control::ReadOnly, "Screenshot Shortcut");
        shortcut.kind = Kind::Shortcut;
        let mut unnamed = item("keybind", "", Control::ReadOnly, "");
        unnamed.group = None;
        unnamed.label = None;
        let items = vec![folder, item("font-size", "font", Control::Number, "Font Size"), unnamed, shortcut];
        // The core lists the screenshot group last; the list shows Font first.
        let sections: Sections = vec![
            ("screenshot".into(), vec!["screenshot-directory".into(), "screenshot".into()]),
            ("font".into(), vec!["font-size".into()]),
        ];
        let got = form_entries(&items, &sections, zh);
        let order: Vec<(usize, Group)> = got.iter().map(|(i, g, _)| (*i, *g)).collect();
        assert_eq!(order, [(1, Group::Font), (0, Group::Screenshot), (3, Group::Screenshot)]);
        // The name is the translated one; the English one is an alias, after
        // the table's own.
        assert_eq!(got[0].2, Entry { name: "字号".into(), aliases: vec!["Font Size".into()], key: Some("font-size".into()), summary: None, choices: vec![], group: Some("字体".into()) });
        // Each row says which group it is in, in the language shown.
        assert_eq!(got[1].2.group.as_deref(), Some("截图"));
        assert_eq!(got[2].2.group.as_deref(), Some("截图"));
        assert_eq!(got[1].2.name, "截图保存位置");
        assert_eq!(got[1].2.aliases, ["capture", "截屏", "Screenshot Folder"]);
        assert_eq!(got[1].2.summary.as_deref(), Some("截图存在哪里。"));
        // A shortcut row's key is its action.
        assert_eq!(got[2].2.key.as_deref(), Some("screenshot"));
        // In English the name is the label and is not repeated as an alias.
        let en = form_entries(&items, &sections, |s| s.to_string());
        assert_eq!(en[0].2.aliases, Vec::<String>::new());
        assert_eq!(en[1].2.aliases, ["capture", "截屏"]);
    }

    #[test]
    fn a_choices_values_are_searchable_by_the_names_shown() {
        let mut it = item("screenshot-mouse-trigger", "screenshot", Control::Choice, "Mouse Trigger");
        it.choices = vec!["none".into(), "ctrl+shift".into()];
        it.choice_labels = vec![Some("Off".into()), None];
        it.choice_template = Some("%s + Click".into());
        it.value = "none".into();
        assert_eq!(form_entry(&it, zh).choices, ["关", "Ctrl+Shift + 单击"]);
        // A switch has no value names.
        assert!(form_entry(&item("a", "font", Control::Toggle, "A"), zh).choices.is_empty());
    }

    #[test]
    fn a_jump_entry_is_its_text_as_given() {
        let mut it = item("", "", Control::ReadOnly, "Off");
        it.kind = Kind::Jump;
        // Both are words the catalogue has: neither is looked up, because
        // they are a role's own name and sentence, not msgids.
        it.summary = Some("Font Size".into());
        let e = form_entry(&it, zh);
        assert_eq!(e, Entry { name: "Off".into(), aliases: vec![], key: None, summary: Some("Font Size".into()), choices: vec![], group: None });
    }

    #[test]
    fn the_document_is_one_object_per_entry_and_escapes_what_people_type() {
        let entries = vec![
            Entry { name: "a \"b\"\\\n\tc\u{1}".into(), ..Default::default() },
            Entry::default(),
            Entry {
                name: "字号".into(),
                aliases: vec!["Font Size".into(), "x".into()],
                key: Some("font-size".into()),
                summary: Some("s".into()),
                choices: vec!["关".into()],
                group: Some("字体".into()),
            },
        ];
        assert_eq!(
            json(&entries),
            "[{\"name\":\"a \\\"b\\\"\\\\\\n\\tc\\u0001\"},{\"name\":\"\"},\
             {\"name\":\"字号\",\"aliases\":[\"Font Size\",\"x\"],\"key\":\"font-size\",\"summary\":\"s\",\"choices\":[\"关\"],\"group\":\"字体\"}]"
        );
        assert_eq!(json(&[]), "[]");
    }

    #[test]
    fn a_hit_past_the_end_or_given_twice_is_left_out() {
        assert_eq!(valid_hits(&[2, 0, 5, 2, 1], 3), [2, 0, 1]);
        assert_eq!(valid_hits(&[3], 3), Vec::<usize>::new());
        assert_eq!(valid_hits(&[], 3), Vec::<usize>::new());
    }

    #[test]
    fn each_result_has_a_breadcrumb_line_above_it() {
        let dpi = 96;
        let (rows, total) = form_labeled(500, dpi, &[(0, 18), (0, 0), (40, 18)]);
        let (crumb_h, gap) = (16, 4);
        let (moved, crumbs, tall) = with_crumbs(&rows, total, crumb_h, gap);
        assert_eq!((moved.len(), crumbs.len()), (3, 3));
        assert_eq!(tall, total + 3 * (crumb_h + gap));
        for i in 0..3 {
            // The line sits `gap` above its own row, whole width.
            assert_eq!(crumbs[i].height(), crumb_h);
            assert_eq!(moved[i].label.top - crumbs[i].bottom, gap, "row {i}");
            assert_eq!((crumbs[i].left, crumbs[i].right), (moved[i].label.left, moved[i].control.right));
            // The row itself is as it was, only lower.
            assert_eq!(moved[i].control.height(), rows[i].control.height());
            assert_eq!(moved[i].label.top - rows[i].label.top, (i as i32 + 1) * (crumb_h + gap));
            assert_eq!(moved[i].help.map(|h| h.top - moved[i].control.bottom), rows[i].help.map(|h| h.top - rows[i].control.bottom));
        }
        // And clear of the row before it.
        for i in 1..3 {
            let before = moved[i - 1].help.map(|h| h.bottom).unwrap_or(moved[i - 1].control.bottom).max(moved[i - 1].label.bottom);
            assert!(crumbs[i].top >= before, "row {i}: {} < {before}", crumbs[i].top);
        }
        assert_eq!(with_crumbs(&[], 0, crumb_h, gap), (Vec::new(), Vec::new(), 0));
    }
}
