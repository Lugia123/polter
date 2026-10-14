//! Official roles and official skills in the role library (task 1507): the
//! rules the Windows window follows, out here because `polter-host`'s own
//! tests cannot run off Windows.
//!
//! The macOS side is `RoleModels.swift` (`RoleOfficial`), `OfficialWhy.swift`
//! and `RoleLibraryView.swift`; this is the same behaviour, rule for rule,
//! with one difference of placement that [`strip`] explains.
//!
//! **Nothing here translates.** Every sentence is marked `n_` so the
//! template finds it (`src/build/GhosttyI18n.zig` walks this crate). What a person reads comes back as the
//! English msgid, and the host puts it through `tr` -- the msgids are the
//! macOS side's sentences with `%@` spelt `{}`, which is how this host's
//! catalogue entries spell a place for a value.

/// Where an official role or skill stands against the one Polter ships: the
/// core's `official.State`, never worked out here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Pristine,
    Modified,
    /// Changed here, and the shipped one has changed in the same place since.
    ModifiedStale,
    /// What was changed here could not be read, so the shipped one is in use.
    Unknown,
}

impl State {
    pub fn parse(s: &str) -> Option<State> {
        Some(match s {
            "pristine" => State::Pristine,
            "modified" => State::Modified,
            "modified_stale" => State::ModifiedStale,
            "unknown" => State::Unknown,
            _ => return None,
        })
    }

    /// Whether there is anything to put back -- what greys "Restore Factory
    /// Settings…" when it is false. **`Unknown` counts**: the changes that
    /// could not be read are still there, and restoring is how they go.
    pub fn can_restore(self) -> bool {
        self != State::Pristine
    }

    /// The skill page's status row (`stateText` on the macOS side). For
    /// `Unknown` the msgid has a `{}` for the reason.
    pub fn text(self) -> &'static str {
        match self {
            State::Pristine => n_("Factory settings"),
            State::Modified => n_("Changed"),
            State::ModifiedStale => n_("Changed · The official version has changed"),
            State::Unknown => n_("Your changes weren't read: {}"),
        }
    }
}

/// Why a change could not be read, by the name the core gives it
/// (`official.WhyCode` in `src/poltergeist/official.zig`). The macOS side is
/// `OfficialWhy.swift`; `tools/official-why-codes-agree.py` holds all three
/// lists to one another, because a name missing here shows the core's
/// English with nothing to say so.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Why {
    OverridesUnreadable,
    OverridesNotJson,
    RoleNotObject,
    RoleUnknownField,
    RoleNotValueAndBase,
    RoleNoValue,
    RoleValueUnreadable,
    RoleNoBase,
    RoleBaseUnreadable,
    SkillNotObject,
    SkillNoBase,
    SkillBaseNotText,
    SkillCopyNotThisSkill,
    SkillCopyUnrecorded,
}

impl Why {
    pub const ALL: [Why; 14] = [
        Why::OverridesUnreadable,
        Why::OverridesNotJson,
        Why::RoleNotObject,
        Why::RoleUnknownField,
        Why::RoleNotValueAndBase,
        Why::RoleNoValue,
        Why::RoleValueUnreadable,
        Why::RoleNoBase,
        Why::RoleBaseUnreadable,
        Why::SkillNotObject,
        Why::SkillNoBase,
        Why::SkillBaseNotText,
        Why::SkillCopyNotThisSkill,
        Why::SkillCopyUnrecorded,
    ];

    /// The core's name for it.
    ///
    /// ⚠️ One `Why::X => "x"` per line: the agreement gate reads them so.
    pub fn code(self) -> &'static str {
        match self {
            Why::OverridesUnreadable => "overrides_unreadable",
            Why::OverridesNotJson => "overrides_not_json",
            Why::RoleNotObject => "role_not_object",
            Why::RoleUnknownField => "role_unknown_field",
            Why::RoleNotValueAndBase => "role_not_value_and_base",
            Why::RoleNoValue => "role_no_value",
            Why::RoleValueUnreadable => "role_value_unreadable",
            Why::RoleNoBase => "role_no_base",
            Why::RoleBaseUnreadable => "role_base_unreadable",
            Why::SkillNotObject => "skill_not_object",
            Why::SkillNoBase => "skill_no_base",
            Why::SkillBaseNotText => "skill_base_not_text",
            Why::SkillCopyNotThisSkill => "skill_copy_not_this_skill",
            Why::SkillCopyUnrecorded => "skill_copy_unrecorded",
        }
    }

    pub fn parse(code: &str) -> Option<Why> {
        Why::ALL.into_iter().find(|w| w.code() == code)
    }

    /// The sentence's msgid; `{}` is where the detail goes -- a path, a
    /// field, or a file and the error reading it.
    pub fn msgid(self) -> &'static str {
        match self {
            Why::OverridesUnreadable => n_("Could not read {}"),
            Why::OverridesNotJson => n_("official-overrides.json can't be read as a file of changes."),
            Why::RoleNotObject => n_("What is written for this role is not an object."),
            Why::RoleUnknownField => n_("\"{}\" is not a field this version of Polter knows."),
            Why::RoleNotValueAndBase => n_("\"{}\" is not written as a value and its base."),
            Why::RoleNoValue => n_("\"{}\" has no value."),
            Why::RoleValueUnreadable => n_("The value of \"{}\" can't be read."),
            Why::RoleNoBase => n_("\"{}\" has no base, so it can't be compared with the official version."),
            Why::RoleBaseUnreadable => n_("The base of \"{}\" can't be read."),
            Why::SkillNotObject => n_("What is written for this skill is not an object."),
            Why::SkillNoBase => n_("The record for this skill has no base."),
            Why::SkillBaseNotText => n_("The base recorded for this skill is not text."),
            Why::SkillCopyNotThisSkill => n_("Your copy at {} doesn't read as this skill, so the shipped one is in use."),
            Why::SkillCopyUnrecorded => n_("This copy wasn't saved from Polter, so whether the official text has changed since is not known."),
        }
    }
}

/// What to show for a reason: the named sentence in the person's language
/// when the core named it, the core's own words when it did not -- an
/// older host meeting a newer core, which is why a name is never required.
/// `tr` is the host's translation.
pub fn why_text(code: Option<&str>, detail: Option<&str>, english: Option<&str>, tr: impl Fn(&str) -> String) -> Option<String> {
    match code.and_then(Why::parse) {
        Some(w) => Some(tr(w.msgid()).replacen("{}", detail.unwrap_or(""), 1)),
        None => english.map(str::to_string),
    }
}

/// A field path from the core (`official.targetOf`), as the part of the
/// page it is on: the section heading's msgid.
pub fn field_section(path: &str) -> &'static str {
    match path {
        "instructions" => n_("Instructions"),
        "polter.watch" | "polter.open" | "polter.quiet_ms" => n_("Polter"),
        _ => n_("Agent CLIs"),
    }
}

/// The sections the shipped version moved under, each once, in order --
/// the "%@" of "The official version has changed: %@". Sorted after
/// translation by the caller, as the macOS side sorts the words.
pub fn stale_sections(stale: &[String]) -> Vec<&'static str> {
    let mut out: Vec<&'static str> = Vec::new();
    for p in stale {
        let s = field_section(p);
        if !out.contains(&s) {
            out.push(s);
        }
    }
    out
}

/// What may be typed into on a role's Basics page, and why not.
///
/// **An official role is mostly editable** (#1504): what the core keeps as a
/// person's change is everything but its name, its description and the three
/// switches that grant the terminal something. Those three are one rule --
/// only the user sets them, and on an official role not even the user --
/// and "open in" is a different one, so they are two fields here. They used
/// to be one flag (`polter`) and could not be told apart.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Locks {
    pub name: bool,
    pub summary: bool,
    /// Supervisor, may-authorise, shield.
    pub standing: bool,
}

pub fn locks(official: bool) -> Locks {
    Locks { name: official, summary: official, standing: official }
}

/// The note under the three switches, by whether they are locked.
pub fn standing_note(official: bool) -> &'static str {
    if official {
        n_("These three are part of the official role and can't be changed. Duplicate the role to make one of your own.")
    } else {
        n_("These three give the terminal something, so only you can set them, here. A supervisor that edits roles can't change them.")
    }
}

/// The left half of the official strip: what this is, and where it stands.
pub fn strip_words(skill: bool, state: Option<State>) -> (&'static str, Option<&'static str>) {
    let what = if skill { n_("Official skill") } else { n_("Official role") };
    let how = match state {
        None | Some(State::Pristine) => None,
        Some(State::Modified) => Some(n_("Changed")),
        Some(State::ModifiedStale) => Some(n_("Changed · The official version has changed")),
        Some(State::Unknown) => Some(n_("Your changes weren't read, so the factory settings are in use.")),
    };
    (what, how)
}

use crate::{n_, Rect};

/// The official strip: the band across the top of the editor column over an
/// official role or skill, with "Restore Factory Settings…" at its right.
///
/// **The one placement that differs from the macOS side**, which has the
/// button in the bottom band. Here the band at the window's narrowest leaves
/// the status text 187 DIP between the list's buttons and Launch, and the
/// English button alone is about that wide -- the status line, which is
/// where every refusal is said, would have had nowhere to go. The strip was
/// already there over every official role.
///
/// **The rule when narrow**: the button is as wide as its text plus `PAD` on
/// each side, never under `ACTION_W[1]`, never squeezed; it keeps its right
/// edge on the column's padding. The words get what is left -- one line,
/// cut with an ellipsis -- and nothing when nothing is left. They lose
/// nothing by it: the state is said in full in the notice rows under it.
///
/// `left`/`right`: the editor column's edges; `top`: where the strip starts;
/// `text_w`: the button's text, measured, in pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Strip {
    pub strip: Rect,
    pub words: Option<Rect>,
    pub restore: Rect,
}

pub const STRIP_H: i32 = 44;

pub fn strip(left: i32, right: i32, top: i32, dpi: i32, text_w: i32) -> Strip {
    use crate::grid::{ACTION_W, CONTROL_H, PAD};
    let s = |v| crate::scale(v, dpi);
    let strip = Rect::new(left, top, right, top + s(STRIP_H));
    let bw = (text_w + 2 * s(PAD)).max(s(ACTION_W[1]));
    let b_right = right - s(PAD);
    let b_top = top + (s(STRIP_H) - s(CONTROL_H)) / 2;
    // Never further left than the column's own padding: a button wider than
    // the column is cut on the right by the window, not pushed over the list.
    let b_left = (b_right - bw).max(left + s(PAD));
    let restore = Rect::new(b_left, b_top, b_right, b_top + s(CONTROL_H));
    let words_left = left + s(PAD);
    let words_right = b_left - s(PAD);
    let words = (words_right > words_left).then(|| Rect::new(words_left, top, words_right, strip.bottom));
    Strip { strip, words, restore }
}

/// One row of the list column: the roles, then the official skills under a
/// heading of their own -- one list to the eye and to the arrow keys, as on
/// the macOS side.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entry {
    /// `None` is the unsaved new role.
    Role(Option<String>),
    Heading,
    Skill(String),
}

impl Entry {
    /// Whether a click or an arrow key can land on it.
    pub fn selectable(&self) -> bool {
        matches!(self, Entry::Role(Some(_)) | Entry::Skill(_))
    }
}

/// ↑ / ↓ through the list: the next selectable row from `current`, stopping
/// at the ends. The heading is stepped over; the unsaved new role is not a
/// place to go back to (it has no key -- it is where the list starts from).
pub fn step(entries: &[Entry], current: Option<usize>, down: bool) -> Option<usize> {
    let picks: Vec<usize> = (0..entries.len()).filter(|&i| entries[i].selectable()).collect();
    if picks.is_empty() {
        return None;
    }
    let Some(cur) = current else {
        return Some(if down { picks[0] } else { *picks.last().unwrap() });
    };
    if down {
        Some(picks.iter().copied().find(|&i| i > cur).unwrap_or(*picks.last().unwrap()))
    } else {
        Some(picks.iter().rev().copied().find(|&i| i < cur).unwrap_or(picks[0]))
    }
}

/// Whether the dot goes on a list row: unsaved here, or changed from the
/// factory settings -- the macOS rule, both reasons on one dot.
pub fn dot(unsaved: bool, state: Option<State>) -> bool {
    unsaved || state.is_some_and(State::can_restore)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_reason_round_trips_by_its_name_and_says_its_detail() {
        for w in Why::ALL {
            assert_eq!(Why::parse(w.code()), Some(w), "{w:?}");
        }
        let names: std::collections::HashSet<_> = Why::ALL.iter().map(|w| w.code()).collect();
        assert_eq!(names.len(), Why::ALL.len(), "two reasons share a name");
        let id = |s: &str| s.to_string();
        assert_eq!(
            why_text(Some("role_no_value"), Some("instructions"), Some("english"), id).as_deref(),
            Some("\"instructions\" has no value.")
        );
        // A reason with no place for a detail ignores one.
        assert_eq!(
            why_text(Some("skill_no_base"), Some("x"), None, id).as_deref(),
            Some("The record for this skill has no base.")
        );
    }

    #[test]
    fn a_name_this_host_does_not_know_shows_the_cores_words() {
        let id = |s: &str| s.to_string();
        assert_eq!(why_text(Some("from_a_newer_core"), Some("x"), Some("The core's words"), id).as_deref(), Some("The core's words"));
        assert_eq!(why_text(None, None, Some("The core's words"), id).as_deref(), Some("The core's words"));
        assert_eq!(why_text(None, None, None, id), None);
    }

    #[test]
    fn the_translation_is_asked_for_the_msgid_and_the_detail_goes_into_it() {
        let zh = |s: &str| if s == "\"{}\" has no value." { "「{}」没有值。".to_string() } else { s.to_string() };
        assert_eq!(why_text(Some("role_no_value"), Some("model"), None, zh).as_deref(), Some("「model」没有值。"));
    }

    #[test]
    fn restoring_is_offered_for_every_state_but_factory_settings() {
        assert!(!State::Pristine.can_restore());
        assert!(State::Modified.can_restore());
        assert!(State::ModifiedStale.can_restore());
        assert!(State::Unknown.can_restore(), "the unreadable changes are still there to put back");
        assert_eq!(State::parse("modified_stale"), Some(State::ModifiedStale));
        assert_eq!(State::parse("stale"), None);
    }

    #[test]
    fn an_official_role_locks_its_name_description_and_standing_only() {
        assert_eq!(locks(true), Locks { name: true, summary: true, standing: true });
        assert_eq!(locks(false), Locks::default());
        assert!(standing_note(true).starts_with("These three are part of the official role"));
        assert!(standing_note(false).starts_with("These three give the terminal"));
    }

    #[test]
    fn stale_paths_become_their_sections_each_once() {
        let paths = ["polter.open", "instructions", "polter.quiet_ms", "clis.claude.model"].map(String::from);
        assert_eq!(stale_sections(&paths), vec!["Polter", "Instructions", "Agent CLIs"]);
        assert!(stale_sections(&[]).is_empty());
    }

    /// The section's width at the settings window's smallest and at its
    /// first size, at three DPIs: the button is whole, inside the strip,
    /// right-aligned on the padding, and the words never reach it.
    #[test]
    fn the_restore_button_is_never_squeezed_and_the_words_give_way() {
        let (min_w, _) = crate::content_size(crate::MIN_W, crate::MIN_H);
        let (first_w, _) = crate::content_size(crate::FIRST_W, crate::FIRST_H);
        for dpi in [96, 144, 192] {
            let s = |v| crate::scale(v, dpi);
            for w in [min_w, first_w] {
                let (left, right) = (s(crate::grid::LIST) + 1, s(w));
                // The longest the English button is: about 170 DIP of text.
                for text in [s(60), s(170)] {
                    let st = strip(left, right, 0, dpi, text);
                    assert_eq!(st.strip.height(), s(STRIP_H));
                    assert_eq!(st.restore.right, right - s(crate::grid::PAD), "dpi {dpi} w {w}");
                    assert_eq!(st.restore.width(), (text + 2 * s(crate::grid::PAD)).max(s(crate::grid::ACTION_W[1])));
                    assert!(st.restore.left >= left + s(crate::grid::PAD));
                    assert!(st.restore.top >= st.strip.top && st.restore.bottom <= st.strip.bottom);
                    if let Some(words) = st.words {
                        assert!(words.right <= st.restore.left - s(crate::grid::PAD), "dpi {dpi} w {w}");
                        assert_eq!(words.left, left + s(crate::grid::PAD));
                    }
                }
            }
        }
    }

    #[test]
    fn a_short_button_is_the_bands_button_width() {
        let st = strip(261, 1000, 0, 96, 10);
        assert_eq!(st.restore.width(), crate::grid::ACTION_W[1]);
    }

    #[test]
    fn the_arrow_keys_walk_roles_then_skills_and_step_over_the_heading() {
        let e = vec![
            Entry::Role(None),
            Entry::Role(Some("a".into())),
            Entry::Role(Some("b".into())),
            Entry::Heading,
            Entry::Skill("s1".into()),
            Entry::Skill("s2".into()),
        ];
        assert_eq!(step(&e, Some(2), true), Some(4), "over the heading");
        assert_eq!(step(&e, Some(4), false), Some(2), "back over it");
        assert_eq!(step(&e, Some(5), true), Some(5), "stops at the end");
        assert_eq!(step(&e, Some(1), false), Some(1), "the new role is not a place to go");
        assert_eq!(step(&e, None, true), Some(1));
        assert_eq!(step(&e, None, false), Some(5));
        assert_eq!(step(&[Entry::Heading], None, true), None);
    }

    #[test]
    fn the_dot_says_unsaved_or_changed_from_factory_settings() {
        assert!(dot(true, None));
        assert!(dot(false, Some(State::Modified)));
        assert!(dot(false, Some(State::Unknown)));
        assert!(!dot(false, Some(State::Pristine)));
        assert!(!dot(false, None));
    }

    #[test]
    fn the_strip_says_what_it_is_and_where_it_stands() {
        assert_eq!(strip_words(false, Some(State::Pristine)), ("Official role", None));
        assert_eq!(strip_words(true, Some(State::Modified)), ("Official skill", Some("Changed")));
        assert_eq!(strip_words(false, None).1, None);
    }
}
