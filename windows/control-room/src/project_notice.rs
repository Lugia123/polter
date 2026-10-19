//! What the control room's right-hand frame says about the selected
//! group's project, between its title bar and its terminal (task 1714,
//! designs `project-link-v1` A c/d and `-v2` A1, D): the line saying a
//! project was made, or the banner that asks what to do when one was not.
//! The terminal moves down by the band's height; nothing covers it.
//!
//! In points from the band's own top left; the host measures words with
//! `measure` and paints the items, as for every other part of the frame.
//! A press is answered by [`Band::press_at`].

use crate::layout::Rect;
use crate::look::{font, pane, radius, side, space, Theme};
use crate::project_link::Item as Menu;
use crate::project_words::Banner;
use crate::scene::{Align, Face, Item, Style};
use crate::hint_bar;

/// What is said.
#[derive(Clone, Copy, Debug)]
pub enum Notice<'a> {
    /// The line saying a project was made; `undo` the Undo button's words,
    /// none on the line that says what was undone.
    Hint { text: &'a str, undo: Option<&'a str> },
    Banner(&'a Banner),
}

/// What a press on the band does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Press {
    Undo,
    Close,
    /// One of the banner's buttons: the menu's item of the same name.
    Button(Menu),
    /// For several projects: "Use “X”".
    Use(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Band {
    pub h: f64,
    pub items: Vec<Item>,
    /// What is pressed where; the cross is the host's to draw at the
    /// `Close` rectangle, as all its crosses.
    pub presses: Vec<(Rect, Press)>,
}

impl Band {
    pub fn press_at(&self, at: (f64, f64)) -> Option<&Press> {
        self.presses.iter().find(|(r, _)| at.0 >= r.x && at.0 < r.x + r.w && at.1 >= r.y && at.1 < r.y + r.h).map(|(_, p)| p)
    }
}

fn body(color: crate::look::Rgba) -> Style {
    Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color }
}

/// `text` in lines no wider than `w`, broken where the host's block
/// painter breaks them (`layout::wrap`): the most characters `measure`
/// says fit, back to the last space when there is one.
fn wrap(text: &str, w: f64, measure: &dyn Fn(&str) -> f64) -> Vec<String> {
    let fits = |s: &str| {
        let mut n = 0;
        let mut upto = String::new();
        for ch in s.chars() {
            upto.push(ch);
            if measure(&upto) > w {
                break;
            }
            n += 1;
        }
        n
    };
    crate::layout::wrap(text, &fits)
}

/// The band for `notice`, `w` wide, at the top left of the space between
/// the title bar and the terminal.
pub fn band(notice: Notice, w: f64, theme: &Theme, measure: &dyn Fn(&str) -> f64) -> Band {
    match notice {
        Notice::Hint { text, undo } => {
            let rect = Rect { x: 0.0, y: 0.0, w, h: hint_bar::HEIGHT };
            let undo_w = undo.map(|u| measure(u) + 2.0 * space::FRAME_TO_CONTENT);
            let g = hint_bar::geometry(rect, undo_w);
            let items = hint_bar::build(&g, text, undo, theme);
            let mut presses = Vec::new();
            if let Some(u) = g.undo {
                presses.push((u, Press::Undo));
            }
            presses.push((g.close, Press::Close));
            Band { h: hint_bar::HEIGHT, items, presses }
        }
        Notice::Banner(b) => {
            let pad = space::FRAME_TO_CONTENT;
            let gap = pane::BAR_GAP;
            let inner = (w - 2.0 * pad).max(0.0);
            let lines = wrap(&b.text, inner, measure);
            let line_h = side::ASK_LINE_HEIGHT;
            let mut items = vec![Item::Fill { rect: Rect { x: 0.0, y: 0.0, w, h: 0.0 }, color: theme.surface_row }];
            let text_h = lines.len() as f64 * line_h;
            items.push(Item::Block { rect: Rect { x: pad, y: pad, w: inner, h: text_h }, text: b.text.clone(), style: body(theme.text), lines: lines.len() });
            // The buttons in a row under the words, the first the one the
            // banner is for; a row that is full goes on to the next.
            let mut presses = Vec::new();
            let labels: Vec<(String, Press)> = b
                .buttons
                .iter()
                .enumerate()
                .flat_map(|(i, button)| {
                    let mut out = vec![(button.label.clone(), Press::Button(button.item.clone()))];
                    // "Use “X”" for each candidate stands before the last
                    // button, "This Group Has No Project".
                    if i + 1 == b.buttons.len() {
                        let uses: Vec<(String, Press)> = b.uses.iter().map(|(name, l)| (l.clone(), Press::Use(name.clone()))).collect();
                        out.splice(0..0, uses);
                    }
                    out
                })
                .collect();
            let (mut x, mut y) = (pad, pad + text_h + gap);
            for (n, (label, press)) in labels.into_iter().enumerate() {
                let bw = measure(&label) + 2.0 * pad;
                if x > pad && x + bw > pad + inner {
                    x = pad;
                    y += hint_bar::BUTTON + gap;
                }
                let r = Rect { x, y, w: bw, h: hint_bar::BUTTON };
                items.push(Item::Round { rect: r, radius: radius::ROW, color: theme.window_base, edge: Some(theme.line_faint) });
                let style = if n == 0 { Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.attention_text) } } else { body(theme.attention_text) };
                items.push(Item::Text { rect: r, text: label, style, align: Align::Centre });
                presses.push((r, press));
                x += bw + gap;
            }
            let h = y + hint_bar::BUTTON + pad;
            items[0] = Item::Fill { rect: Rect { x: 0.0, y: 0.0, w, h }, color: theme.surface_row };
            Band { h, items, presses }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look;
    use crate::project_link::note;
    use crate::project_words::{banner, Blocker};

    /// Eight points a character: enough to make lines and rows wrap.
    fn eight(s: &str) -> f64 {
        8.0 * s.chars().count() as f64
    }

    fn same(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn the_banner_asks_in_wrapped_lines_with_its_buttons_under_them() {
        let theme = look::theme(false);
        let b = Blocker { name: "polter".into(), saved: "13 Oct".into(), pages: 1 };
        let banner = banner(&note("undecided", "project_name_taken", None), "project_name_taken", Some(&b), &[], &[], &same).unwrap();
        let band = band(Notice::Banner(&banner), 420.0, &theme, &eight);
        // Four buttons, in the order of the menu's, the first the one it is for.
        let order: Vec<&Press> = band.presses.iter().map(|(_, p)| p).collect();
        assert_eq!(
            order,
            [&Press::Button(Menu::JoinExisting), &Press::Button(Menu::ReplaceExisting), &Press::Button(Menu::OpenBlocker), &Press::Button(Menu::DeclineProject)]
        );
        // Each 24 high, under the words, inside the band; a row that is full
        // went on to the next.
        let rows: std::collections::BTreeSet<i64> = band.presses.iter().map(|(r, _)| r.y as i64).collect();
        assert!(rows.len() > 1, "{:?}", band.presses);
        for (r, _) in &band.presses {
            assert_eq!(r.h, 24.0);
            assert!(r.x + r.w <= 420.0 - 12.0, "{r:?}");
            assert!(r.y + r.h <= band.h - 12.0, "{r:?}");
        }
        let pressed = band.press_at((band.presses[0].0.x + 1.0, band.presses[0].0.y + 1.0));
        assert_eq!(pressed, Some(&Press::Button(Menu::JoinExisting)));
    }

    #[test]
    fn several_projects_get_one_button_each_before_no_project() {
        let theme = look::theme(false);
        let candidates = vec!["web".to_string(), "website".to_string()];
        let banner = banner(&note("undecided", "several_projects", None), "several_projects", None, &candidates, &[], &same).unwrap();
        let band = band(Notice::Banner(&banner), 900.0, &theme, &eight);
        let order: Vec<&Press> = band.presses.iter().map(|(_, p)| p).collect();
        assert_eq!(order, [&Press::Use("web".into()), &Press::Use("website".into()), &Press::Button(Menu::DeclineProject)]);
    }

    #[test]
    fn the_hint_is_one_line_with_undo_and_its_cross() {
        let theme = look::theme(false);
        let band = band(Notice::Hint { text: "Saved.", undo: Some("Undo") }, 500.0, &theme, &eight);
        assert_eq!(band.h, 40.0);
        let presses: Vec<&Press> = band.presses.iter().map(|(_, p)| p).collect();
        assert_eq!(presses, [&Press::Undo, &Press::Close]);
        let undone = band_of_undone(&theme);
        let only_close: Vec<&Press> = undone.presses.iter().map(|(_, p)| p).collect();
        assert_eq!(only_close, [&Press::Close]);
    }

    fn band_of_undone(theme: &Theme) -> Band {
        band(Notice::Hint { text: "Undone.", undo: None }, 500.0, theme, &eight)
    }

    #[test]
    fn wrapping_breaks_at_spaces_and_inside_chinese() {
        assert_eq!(wrap("aa bb cc", 40.0, &eight), ["aa bb", "cc"]);
        assert_eq!(wrap("已有项目要加入", 24.0, &eight), ["已有项", "目要加", "入"]);
        // The same breaks the host's block painter makes of it.
        assert_eq!(wrap("aa bb cc", 40.0, &eight), crate::layout::wrap("aa bb cc", &|s: &str| s.chars().count().min(5)));
    }
}
