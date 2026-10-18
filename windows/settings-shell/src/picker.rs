//! The project picker: the window "Save as Project…" and "Load Project…"
//! open. Loading is the macOS side's `ProjectPickerView.swift`, with the
//! same parts in the same order -- the search on top, the saved projects
//! under it, Cancel at the bottom. Saving is its `ProjectSaveAsView.swift`
//! (task 1754): a name, a tick box for each tab of the window, the sentence
//! saying what saving does, Cancel and Save as Project.
//!
//! What is here is where each part goes and what a key does; the window
//! itself is `host/src/project_picker.rs`.

use crate::{grid, scale, Rect};

/// The client area, in 96-DPI logical pixels: `ProjectPickerView.size`.
pub const WIDTH: i32 = 420;
pub const HEIGHT: i32 = 380;

/// A row: the project's name over when it was saved and how big it is.
pub const ROW_H: i32 = 44;
const CANCEL_W: i32 = 96;
/// One line of the field's 14-pixel font.
const FIELD_LINE: i32 = 20;

/// Where each part of "Load Project" is, in client pixels at the window's
/// DPI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Layout {
    pub field: Rect,
    /// The line between the field and the list.
    pub rule_top: Rect,
    pub list: Rect,
    /// The line between the list and Cancel.
    pub rule_bottom: Rect,
    pub cancel: Rect,
    pub row_h: i32,
}

pub fn layout(width: i32, height: i32, dpi: i32) -> Layout {
    let s = |v| scale(v, dpi);
    let (pad, control) = (s(grid::PAD), s(grid::CONTROL_H));
    let field = Rect::new(pad, pad, width - pad, pad + control);
    let line = s(1).max(1);
    let rule_top_y = field.bottom + s(grid::ROW_GAP);
    let rule_bottom_y = height - s(grid::BOTTOM);
    let cancel_top = rule_bottom_y + (s(grid::BOTTOM) - control) / 2;
    Layout {
        field,
        rule_top: Rect::new(0, rule_top_y, width, rule_top_y + line),
        list: Rect::new(0, rule_top_y + line, width, rule_bottom_y),
        rule_bottom: Rect::new(0, rule_bottom_y, width, rule_bottom_y + line),
        cancel: Rect::new(width - pad - s(CANCEL_W), cancel_top, width - pad, cancel_top + control),
        row_h: s(ROW_H),
    }
}

/// "Save as Project", laid out as the macOS `ProjectSaveAsView` is (task
/// 1754), on this window's grid: its parts top to bottom, all of them
/// starting at `PAD` and the ones at the right ending `PAD` short of the
/// edge. The macOS sheet's numbers are its structure; the sizes are this
/// grid's (`grid::PAD`, `grid::CONTROL_H`, `grid::ROW_GAP`).
pub mod save_as {
    use super::{field_text, CANCEL_W};
    use crate::{grid, scale, Rect};

    /// The client area's width: `ProjectSaveAsView.Grid.width`.
    pub const WIDTH: i32 = 460;
    /// A tab's row: `Grid.row`.
    pub const ROW_H: i32 = 28;
    /// As many rows as are shown before the list scrolls: `Grid.rowsShown`.
    pub const ROWS_SHOWN: usize = 6;
    /// "Name", "Tabs of this window to save": one line of the body font.
    pub const LABEL_H: i32 = 20;
    /// Between one part and the next: the sheet's 16, two of this grid's
    /// gaps.
    pub const SECTION_GAP: i32 = 2 * grid::ROW_GAP;
    /// The sentence under the list: two lines, as the sheet gives it.
    pub const SENTENCE_H: i32 = 36;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct Layout {
        pub name_label: Rect,
        /// The frame the name field is drawn in.
        pub field: Rect,
        /// "As the project of group “X”", when the tab has a group's
        /// supervisor in it (task 1714).
        pub tick: Option<Rect>,
        pub pages_label: Rect,
        /// The tabs, one row each, `ROWS_SHOWN` of them before it scrolls.
        pub list: Rect,
        pub sentence: Rect,
        pub cancel: Rect,
        /// "Save as Project", at the right: the button Return presses.
        pub save: Rect,
        pub row_h: i32,
        /// The client area's height.
        pub height: i32,
    }

    /// How many rows the list is high for `rows` tabs: at least one, at
    /// most `ROWS_SHOWN`.
    pub fn rows_high(rows: usize) -> i32 {
        rows.clamp(1, ROWS_SHOWN) as i32
    }

    /// The parts for `rows` tabs at `dpi`, `width` wide. `save_w`: the Save
    /// as Project button's width, its words measured by the host; never
    /// narrower than Cancel.
    pub fn layout(width: i32, rows: usize, tick: bool, save_w: i32, dpi: i32) -> Layout {
        let s = |v| scale(v, dpi);
        let (pad, control, gap) = (s(grid::PAD), s(grid::CONTROL_H), s(grid::ROW_GAP));
        let (left, right) = (pad, width - pad);
        let band = |top: i32, h: i32| Rect::new(left, top, right, top + h);
        let name_label = band(pad, s(LABEL_H));
        let field = band(name_label.bottom + gap, control);
        let tick = tick.then(|| band(field.bottom + gap, control));
        let pages_label = band(tick.unwrap_or(field).bottom + s(SECTION_GAP), s(LABEL_H));
        let row_h = s(ROW_H);
        let list = band(pages_label.bottom + gap, rows_high(rows) * row_h);
        let sentence = band(list.bottom + s(SECTION_GAP), s(SENTENCE_H));
        let buttons = sentence.bottom + s(SECTION_GAP);
        let save = Rect::new(right - save_w.max(s(CANCEL_W)), buttons, right, buttons + control);
        let cancel = Rect::new(save.left - s(grid::BUTTONS_GAP) - s(CANCEL_W), buttons, save.left - s(grid::BUTTONS_GAP), buttons + control);
        Layout { name_label, field, tick, pages_label, list, sentence, cancel, save, row_h, height: save.bottom + pad }
    }

    /// Where the name's text sits in its frame, as the load window's.
    pub fn name_text(l: &Layout, dpi: i32) -> Rect {
        field_text(l.field, dpi)
    }

    /// The parts of one tab's row `row`: the tick box at its left, the
    /// tab's title one box and one gap in, the note ("This page", "2
    /// pane(s)") ending at its right. `note_w`: the note's width, measured.
    /// The title gets what the note leaves, less a gap; the note is never
    /// cut for it.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct RowParts {
        pub check: Rect,
        pub title: Rect,
        pub note: Rect,
    }

    pub fn row_parts(row: Rect, note_w: i32, dpi: i32) -> RowParts {
        let side = crate::check_box(dpi, row.height());
        let top = row.top + (row.height() - side) / 2;
        let check = Rect::new(row.left, top, row.left + side, top + side);
        let note_w = note_w.clamp(0, row.width() - side);
        let note = Rect::new(row.right - note_w, row.top, row.right, row.bottom);
        let title_left = check.right + scale(grid::CHECK_GAP, dpi);
        let title = Rect::new(title_left, row.top, (note.left - scale(grid::ROW_GAP, dpi)).max(title_left), row.bottom);
        RowParts { check, title, note }
    }
}

/// Where the text of a field sits inside the frame drawn at `field`, when
/// the window draws the frame itself: one line high, in the middle, clear of
/// the frame's sides. A bare `EDIT` the height of the frame puts its text
/// against the top-left corner.
pub fn field_text(field: Rect, dpi: i32) -> Rect {
    let line = scale(FIELD_LINE, dpi).min(field.height());
    let top = field.top + (field.height() - line) / 2;
    Rect::new(field.left + scale(grid::ROW_GAP, dpi), top, field.right - scale(grid::ROW_GAP, dpi), top + line)
}

/// Where a window `width` × `height` goes to sit in the middle of `work`
/// (the monitor's work area). Kept on the monitor when it is larger.
pub fn centred(work: Rect, width: i32, height: i32) -> (i32, i32) {
    let x = work.left + (work.width() - width) / 2;
    let y = work.top + (work.height() - height) / 2;
    (x.max(work.left), y.max(work.top))
}

/// What Return in the search field opens: the highlighted row, else the
/// project when the search has left exactly one. With several left and none
/// highlighted it is still a choice, and nothing opens.
pub fn enter_target(visible: usize, selected: Option<usize>) -> Option<usize> {
    match selected {
        Some(i) if i < visible => Some(i),
        _ if visible == 1 => Some(0),
        _ => None,
    }
}

/// Where ↓ (`down`) or ↑ goes from `selected` in a list of `visible` rows.
/// It stops at the ends; from nothing highlighted ↓ takes the first row and
/// ↑ the last.
pub fn step(selected: Option<usize>, visible: usize, down: bool) -> Option<usize> {
    if visible == 0 {
        return None;
    }
    Some(match (selected, down) {
        (Some(i), true) => (i + 1).min(visible - 1),
        (Some(i), false) => i.saturating_sub(1).min(visible - 1),
        (None, true) => 0,
        (None, false) => visible - 1,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_has_a_full_width_field() {
        let l = layout(WIDTH, HEIGHT, 96);
        assert_eq!(l.field, Rect::new(16, 16, 404, 44));
        assert_eq!(l.rule_top.top, 52);
        assert_eq!(l.list, Rect::new(0, 53, 420, 328));
        assert_eq!(l.cancel, Rect::new(308, 340, 404, 368));
    }

    #[test]
    fn nothing_overlaps_and_everything_is_inside_at_every_dpi() {
        for dpi in [96, 120, 144, 192] {
            let (w, h) = (scale(WIDTH, dpi), scale(HEIGHT, dpi));
            let l = layout(w, h, dpi);
            let down = [l.field.bottom, l.rule_top.top, l.list.top, l.list.bottom, l.cancel.top, l.cancel.bottom, h];
            assert!(down.windows(2).all(|p| p[0] <= p[1]), "at {dpi}: {down:?}");
            assert!(l.list.height() >= 4 * l.row_h, "at {dpi}: the list shows four rows");
        }
    }

    #[test]
    fn the_field_text_is_one_line_in_the_middle_of_its_frame() {
        let f = layout(WIDTH, HEIGHT, 96).field;
        assert_eq!(field_text(f, 96), Rect::new(24, 20, 396, 40));
        for dpi in [96, 120, 144, 192] {
            let f = save_as::layout(scale(save_as::WIDTH, dpi), 2, false, 0, dpi).field;
            let t = field_text(f, dpi);
            assert!(t.left > f.left && t.right < f.right && t.top >= f.top && t.bottom <= f.bottom, "{dpi}: {t:?} in {f:?}");
            assert!(((t.top - f.top) - (f.bottom - t.bottom)).abs() <= 1, "{dpi}: centred");
        }
    }

    // ---- Save as Project (task 1754)

    /// The macOS sheet's order, top to bottom: "Name", the field, (the
    /// group's box), "Tabs of this window to save", one row per tab, the
    /// sentence, Cancel and Save as Project side by side at the right.
    #[test]
    fn save_as_is_the_macos_sheet_top_to_bottom() {
        let l = save_as::layout(save_as::WIDTH, 2, false, 120, 96);
        assert_eq!(l.name_label, Rect::new(16, 16, 444, 36));
        assert_eq!(l.field, Rect::new(16, 44, 444, 72));
        assert_eq!(l.tick, None);
        assert_eq!(l.pages_label, Rect::new(16, 88, 444, 108));
        assert_eq!(l.list, Rect::new(16, 116, 444, 116 + 2 * 28));
        assert_eq!(l.sentence, Rect::new(16, 188, 444, 224));
        assert_eq!(l.save, Rect::new(324, 240, 444, 268));
        assert_eq!(l.cancel, Rect::new(220, 240, 316, 268));
        assert_eq!(l.height, 284);
    }

    #[test]
    fn the_list_is_one_row_per_tab_up_to_six_then_it_scrolls() {
        let h = |rows| save_as::layout(save_as::WIDTH, rows, false, 0, 96).list.height();
        assert_eq!(h(0), 28, "never an empty list: one row high");
        assert_eq!(h(1), 28);
        assert_eq!(h(3), 3 * 28);
        assert_eq!(h(6), 6 * 28);
        assert_eq!(h(9), 6 * 28);
        // The window grows with the list and with nothing else.
        let tall = |rows| save_as::layout(save_as::WIDTH, rows, false, 0, 96).height;
        assert_eq!(tall(4) - tall(1), 3 * 28);
        assert_eq!(tall(9), tall(6));
    }

    #[test]
    fn the_groups_box_goes_under_the_name_and_moves_the_rest_down_by_itself() {
        let plain = save_as::layout(save_as::WIDTH, 2, false, 0, 96);
        let with = save_as::layout(save_as::WIDTH, 2, true, 0, 96);
        let tick = with.tick.unwrap();
        assert_eq!(tick, Rect::new(16, plain.field.bottom + 8, 444, plain.field.bottom + 8 + 28));
        let extra = with.pages_label.top - plain.pages_label.top;
        assert_eq!(extra, 8 + 28);
        assert_eq!(with.list.height(), plain.list.height());
        assert_eq!(with.save.top - plain.save.top, extra);
        assert_eq!(with.height - plain.height, extra);
    }

    #[test]
    fn save_as_project_is_never_narrower_than_cancel_and_both_end_at_the_pad() {
        let narrow = save_as::layout(save_as::WIDTH, 1, false, 10, 96);
        assert_eq!(narrow.save.width(), narrow.cancel.width());
        let wide = save_as::layout(save_as::WIDTH, 1, false, 150, 96);
        assert_eq!(wide.save.width(), 150);
        assert_eq!(wide.save.right, save_as::WIDTH - grid::PAD);
        assert_eq!(wide.save.left - wide.cancel.right, grid::BUTTONS_GAP);
    }

    #[test]
    fn save_as_parts_stay_inside_and_in_order_at_every_dpi() {
        for dpi in [96, 120, 144, 192, 240] {
            for (rows, tick) in [(1, false), (3, true), (8, true)] {
                let w = scale(save_as::WIDTH, dpi);
                let l = save_as::layout(w, rows, tick, scale(130, dpi), dpi);
                let mut down = vec![l.name_label.top, l.name_label.bottom, l.field.top, l.field.bottom];
                if let Some(t) = l.tick {
                    down.extend([t.top, t.bottom]);
                }
                down.extend([l.pages_label.top, l.pages_label.bottom, l.list.top, l.list.bottom, l.sentence.top, l.sentence.bottom, l.save.top, l.save.bottom, l.height]);
                assert!(down.windows(2).all(|p| p[0] <= p[1]), "{dpi} {rows}: {down:?}");
                assert_eq!(l.list.height(), save_as::rows_high(rows) * l.row_h);
                assert!(l.cancel.left >= scale(grid::PAD, dpi) && l.cancel.right < l.save.left && l.save.right <= w, "{dpi}");
                assert_eq!(l.cancel.top, l.save.top);
            }
        }
    }

    /// A row on the sheet's grid: the box at the left edge, the title one
    /// box and one gap in, the note ending at the right edge and never cut
    /// for the title.
    #[test]
    fn a_rows_box_title_and_note_do_not_overlap() {
        let row = Rect::new(16, 116, 444, 144);
        let p = save_as::row_parts(row, 60, 96);
        assert_eq!(p.check, Rect::new(16, 122, 32, 138));
        assert_eq!(p.title.left, 32 + grid::CHECK_GAP);
        assert_eq!(p.note, Rect::new(444 - 60, 116, 444, 144));
        assert_eq!(p.title.right, p.note.left - grid::ROW_GAP);
        // A note wider than the row: it takes the row less the box, and
        // the title is left nothing rather than overlapping.
        let p = save_as::row_parts(row, 1000, 96);
        assert_eq!(p.note.left, p.check.right);
        assert!(p.title.right >= p.title.left);
        for dpi in [96, 144, 192] {
            let r = Rect::new(0, 0, scale(428, dpi), scale(save_as::ROW_H, dpi));
            let p = save_as::row_parts(r, scale(70, dpi), dpi);
            assert!(p.check.right < p.title.left && p.title.right < p.note.left, "{dpi}: {p:?}");
            assert!(p.check.top >= r.top && p.check.bottom <= r.bottom, "{dpi}");
        }
    }

    #[test]
    fn centred_is_the_middle_of_the_work_area() {
        // The reading the macOS fix was checked against: 420 wide on 1800.
        assert_eq!(centred(Rect::new(0, 0, 1800, 1130), 420, 412), (690, 359));
        // A second monitor to the left of the first.
        assert_eq!(centred(Rect::new(-1920, 0, 0, 1040), 420, 412), (-1170, 314));
        // Larger than the work area: its top-left stays on the monitor.
        assert_eq!(centred(Rect::new(0, 0, 300, 300), 420, 412), (0, 0));
    }

    #[test]
    fn return_opens_the_highlighted_row_or_the_only_one() {
        assert_eq!(enter_target(3, Some(2)), Some(2));
        assert_eq!(enter_target(1, None), Some(0));
        assert_eq!(enter_target(3, None), None);
        assert_eq!(enter_target(0, None), None);
        // A highlight the search has since removed is no highlight.
        assert_eq!(enter_target(2, Some(5)), None);
        assert_eq!(enter_target(1, Some(5)), Some(0));
    }

    #[test]
    fn arrows_stop_at_the_ends() {
        assert_eq!(step(None, 3, true), Some(0));
        assert_eq!(step(None, 3, false), Some(2));
        assert_eq!(step(Some(2), 3, true), Some(2));
        assert_eq!(step(Some(0), 3, false), Some(0));
        assert_eq!(step(Some(1), 3, true), Some(2));
        assert_eq!(step(Some(7), 3, false), Some(2));
        assert_eq!(step(None, 0, true), None);
    }
}
