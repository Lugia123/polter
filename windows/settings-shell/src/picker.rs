//! The project picker: the window "Save as Project…" and "Load Project…"
//! open. The macOS side's `ProjectPickerView.swift`, with the same parts in
//! the same order -- a field on top (the new project's name with Save beside
//! it, or the search), the saved projects under it, Cancel at the bottom.
//!
//! What is here is where each part goes and what a key does; the window
//! itself is `host/src/project_picker.rs`.

use crate::{grid, scale, Rect};

/// The client area, in 96-DPI logical pixels: `ProjectPickerView.size`.
pub const WIDTH: i32 = 420;
pub const HEIGHT: i32 = 380;

/// A row: the project's name over when it was saved and how big it is.
pub const ROW_H: i32 = 44;
const SAVE_W: i32 = 80;
const CANCEL_W: i32 = 96;
const CAPTION_H: i32 = 18;
const CAPTION_GAP: i32 = 4;
/// One line of the field's 14-pixel font.
const FIELD_LINE: i32 = 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// The field names a new project; picking a row overwrites that one.
    SaveAs,
    /// The field searches; picking a row opens it.
    Load,
}

/// Where each part is, in client pixels at the window's DPI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Layout {
    pub field: Rect,
    /// Save, beside the name field. `SaveAs` only.
    pub save: Option<Rect>,
    /// "Saves this tab: N pane(s)", under the name field. `SaveAs` only.
    pub caption: Option<Rect>,
    /// The line between the field and the list.
    pub rule_top: Rect,
    pub list: Rect,
    /// The line between the list and Cancel.
    pub rule_bottom: Rect,
    pub cancel: Rect,
    pub row_h: i32,
}

pub fn layout(mode: Mode, width: i32, height: i32, dpi: i32) -> Layout {
    let s = |v| scale(v, dpi);
    let (pad, control) = (s(grid::PAD), s(grid::CONTROL_H));
    let field_top = pad;
    let (field, save, caption) = match mode {
        Mode::Load => (Rect::new(pad, field_top, width - pad, field_top + control), None, None),
        Mode::SaveAs => {
            let save = Rect::new(width - pad - s(SAVE_W), field_top, width - pad, field_top + control);
            let field = Rect::new(pad, field_top, save.left - s(grid::ROW_GAP), field_top + control);
            let top = field.bottom + s(CAPTION_GAP);
            (field, Some(save), Some(Rect::new(pad, top, width - pad, top + s(CAPTION_H))))
        }
    };
    let line = s(1).max(1);
    let rule_top_y = caption.map_or(field.bottom, |c| c.bottom) + s(grid::ROW_GAP);
    let rule_bottom_y = height - s(grid::BOTTOM);
    let cancel_top = rule_bottom_y + (s(grid::BOTTOM) - control) / 2;
    Layout {
        field,
        save,
        caption,
        rule_top: Rect::new(0, rule_top_y, width, rule_top_y + line),
        list: Rect::new(0, rule_top_y + line, width, rule_bottom_y),
        rule_bottom: Rect::new(0, rule_bottom_y, width, rule_bottom_y + line),
        cancel: Rect::new(width - pad - s(CANCEL_W), cancel_top, width - pad, cancel_top + control),
        row_h: s(ROW_H),
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
    fn load_has_a_full_width_field_and_no_save() {
        let l = layout(Mode::Load, WIDTH, HEIGHT, 96);
        assert_eq!(l.field, Rect::new(16, 16, 404, 44));
        assert_eq!((l.save, l.caption), (None, None));
        assert_eq!(l.rule_top.top, 52);
        assert_eq!(l.list, Rect::new(0, 53, 420, 328));
        assert_eq!(l.cancel, Rect::new(308, 340, 404, 368));
    }

    #[test]
    fn save_as_puts_save_beside_the_name_and_the_caption_under_it() {
        let l = layout(Mode::SaveAs, WIDTH, HEIGHT, 96);
        let (save, caption) = (l.save.unwrap(), l.caption.unwrap());
        assert_eq!(save, Rect::new(324, 16, 404, 44));
        assert_eq!(l.field, Rect::new(16, 16, 316, 44));
        assert_eq!(caption, Rect::new(16, 48, 404, 66));
        assert_eq!(l.list.top, 75);
        // The bottom band is the same in both.
        assert_eq!(l.cancel, layout(Mode::Load, WIDTH, HEIGHT, 96).cancel);
    }

    #[test]
    fn nothing_overlaps_and_everything_is_inside_at_every_dpi() {
        for dpi in [96, 120, 144, 192] {
            for mode in [Mode::SaveAs, Mode::Load] {
                let (w, h) = (scale(WIDTH, dpi), scale(HEIGHT, dpi));
                let l = layout(mode, w, h, dpi);
                let mut down = vec![l.field.bottom];
                down.extend(l.caption.map(|c| c.top));
                down.extend(l.caption.map(|c| c.bottom));
                down.extend([l.rule_top.top, l.list.top, l.list.bottom, l.cancel.top, l.cancel.bottom, h]);
                assert!(down.windows(2).all(|p| p[0] <= p[1]), "{mode:?} at {dpi}: {down:?}");
                assert!(l.list.height() >= 4 * l.row_h, "{mode:?} at {dpi}: the list shows four rows");
                if let Some(s) = l.save {
                    assert!(l.field.right < s.left && s.right <= w);
                }
            }
        }
    }

    #[test]
    fn the_field_text_is_one_line_in_the_middle_of_its_frame() {
        let f = layout(Mode::Load, WIDTH, HEIGHT, 96).field;
        assert_eq!(field_text(f, 96), Rect::new(24, 20, 396, 40));
        for dpi in [96, 120, 144, 192] {
            let f = layout(Mode::SaveAs, scale(WIDTH, dpi), scale(HEIGHT, dpi), dpi).field;
            let t = field_text(f, dpi);
            assert!(t.left > f.left && t.right < f.right && t.top >= f.top && t.bottom <= f.bottom, "{dpi}: {t:?} in {f:?}");
            assert!(((t.top - f.top) - (f.bottom - t.bottom)).abs() <= 1, "{dpi}: centred");
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
