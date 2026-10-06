//! The mouse trigger: a double left click with exactly the configured
//! modifier keys held (`screenshot-mouse-trigger`, `ctrl+shift` by default).
//!
//! **This runs inside a low-level mouse hook**, which sees every click made
//! anywhere on the machine and can eat it. So what it decides is two things
//! at once -- "is this the trigger" and "does the application under the
//! pointer get this click" -- and the second is the one that hurts when it is
//! wrong: a click eaten by mistake is a click that silently did nothing, in
//! somebody else's program.
//!
//! The rule: the first press always passes. The second press is eaten only
//! when it completes the trigger, and then its release is eaten with it, so
//! the application does not see a button come up that never went down.

/// Which modifier keys are down. Left and right are not told apart.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mods {
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    pub win: bool,
}

impl Mods {
    pub const NONE: Mods = Mods { ctrl: false, shift: false, alt: false, win: false };
    pub const CTRL_SHIFT: Mods = Mods { ctrl: true, shift: true, alt: false, win: false };

    /// The modifiers by name, joined with `+`, in the order the setting's
    /// documentation lists them: `ctrl+shift`, `alt`, `shift+super`. `none`
    /// when there are none. For log lines, so one that reports a trigger
    /// names the modifiers it was actually made with.
    pub fn label(&self) -> String {
        let names: Vec<&str> = [(self.shift, "shift"), (self.ctrl, "ctrl"), (self.alt, "alt"), (self.win, "super")]
            .into_iter()
            .filter_map(|(on, name)| on.then_some(name))
            .collect();
        match names.as_slice() {
            [] => "none".to_string(),
            // The one everybody says the other way round.
            ["shift", "ctrl"] => "ctrl+shift".to_string(),
            _ => names.join("+"),
        }
    }
}

/// What `screenshot-mouse-trigger` asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Setting {
    /// `none`: the mouse trigger is off.
    Off,
    On(Mods),
}

impl Setting {
    /// From the value the core hands over for `screenshot-mouse-trigger`: the
    /// bits of `ghostty_input_mods_e` -- shift 1, ctrl 2, alt 4, super 8 --
    /// and 0 for `none`. The core has already parsed and validated the words.
    ///
    /// Bits above those four (the lock keys, the sided variants) are not
    /// modifiers a trigger can ask for and are ignored; a value with none of
    /// the four is off, never "no modifiers held".
    pub fn from_bits(bits: u32) -> Setting {
        let m = Mods { shift: bits & 1 != 0, ctrl: bits & 2 != 0, alt: bits & 4 != 0, win: bits & 8 != 0 };
        if m == Mods::NONE {
            Setting::Off
        } else {
            Setting::On(m)
        }
    }
}

/// The system's idea of a double click, read by the host at the moment of
/// the press.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rule {
    /// `GetDoubleClickTime`: the longest gap between the two presses, ms.
    pub interval_ms: u32,
    /// `SM_CXDOUBLECLK` / `SM_CYDOUBLECLK`: the width and height of the
    /// rectangle, centred on the first press, the second must land in.
    pub width: i32,
    pub height: i32,
    pub trigger: Setting,
}

/// One left-button press as the hook sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Press {
    /// The event's time in milliseconds. It is a tick count and wraps.
    pub time_ms: u32,
    pub x: i32,
    pub y: i32,
    pub mods: Mods,
}

/// What to do with the event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Let it through to whatever is under the pointer.
    Pass,
    /// A press that completed the trigger: eat it and take the screenshot at
    /// its position.
    Trigger,
    /// The release of that press: eat it, nothing else.
    Swallow,
}

/// The hook's memory between events.
#[derive(Debug, Default)]
pub struct Detector {
    first: Option<Press>,
    eat_release: bool,
}

impl Detector {
    pub const fn new() -> Detector {
        Detector { first: None, eat_release: false }
    }

    /// A left button press.
    ///
    /// The modifiers must be **exactly** the trigger's on both presses: one
    /// more held, or one fewer, and it is some other chord that belongs to
    /// the application. A press that does not qualify also forgets the one
    /// before it, so `ctrl+shift` click, plain click, `ctrl+shift` click is
    /// not a double click.
    pub fn press(&mut self, p: Press, rule: &Rule) -> Verdict {
        self.eat_release = false;
        let Setting::On(wanted) = rule.trigger else {
            self.first = None;
            return Verdict::Pass;
        };
        if p.mods != wanted {
            self.first = None;
            return Verdict::Pass;
        }
        let second = self.first.is_some_and(|f| {
            // Twice the distance against the whole width, so an odd width is
            // not rounded: the rectangle is centred on the first press.
            p.time_ms.wrapping_sub(f.time_ms) <= rule.interval_ms
                && (p.x - f.x).abs() * 2 <= rule.width
                && (p.y - f.y).abs() * 2 <= rule.height
        });
        if second {
            // Forgotten, so a third quick press starts over rather than
            // triggering again.
            self.first = None;
            self.eat_release = true;
            Verdict::Trigger
        } else {
            self.first = Some(p);
            Verdict::Pass
        }
    }

    /// A left button release.
    pub fn release(&mut self) -> Verdict {
        if std::mem::replace(&mut self.eat_release, false) {
            Verdict::Swallow
        } else {
            Verdict::Pass
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Windows' defaults: 500 ms, a 4 x 4 rectangle.
    const RULE: Rule =
        Rule { interval_ms: 500, width: 4, height: 4, trigger: Setting::On(Mods::CTRL_SHIFT) };

    fn at(time_ms: u32, x: i32, y: i32, mods: Mods) -> Press {
        Press { time_ms, x, y, mods }
    }

    fn cs(time_ms: u32, x: i32, y: i32) -> Press {
        at(time_ms, x, y, Mods::CTRL_SHIFT)
    }

    #[test]
    fn the_first_press_passes_and_the_second_triggers() {
        let mut d = Detector::new();
        assert_eq!(d.press(cs(1000, 50, 50), &RULE), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
        assert_eq!(d.press(cs(1200, 51, 49), &RULE), Verdict::Trigger);
    }

    #[test]
    fn the_release_of_the_eaten_press_is_eaten_and_only_that_one() {
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &RULE);
        assert_eq!(d.release(), Verdict::Pass);
        d.press(cs(1200, 50, 50), &RULE);
        assert_eq!(d.release(), Verdict::Swallow);
        assert_eq!(d.release(), Verdict::Pass);
        // And an ordinary click afterwards is whole again.
        assert_eq!(d.press(at(5000, 50, 50, Mods::NONE), &RULE), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
    }

    #[test]
    fn a_release_that_never_came_does_not_cost_the_next_click_its_release() {
        // The overlay opens on the trigger press and can take the release
        // with it, so the hook may never see one.
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &RULE);
        assert_eq!(d.press(cs(1100, 50, 50), &RULE), Verdict::Trigger);
        assert_eq!(d.press(at(9000, 50, 50, Mods::NONE), &RULE), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
    }

    #[test]
    fn the_interval_is_the_systems_and_is_inclusive() {
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &RULE);
        assert_eq!(d.press(cs(1500, 50, 50), &RULE), Verdict::Trigger);
        d.press(cs(3000, 50, 50), &RULE);
        assert_eq!(d.press(cs(3501, 50, 50), &RULE), Verdict::Pass, "one millisecond late");
        // A longer system setting admits the same pair.
        let slow = Rule { interval_ms: 900, ..RULE };
        let mut d = Detector::new();
        d.press(cs(3000, 50, 50), &slow);
        assert_eq!(d.press(cs(3501, 50, 50), &slow), Verdict::Trigger);
    }

    #[test]
    fn a_late_second_press_is_a_new_first_press() {
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &RULE);
        assert_eq!(d.press(cs(2000, 50, 50), &RULE), Verdict::Pass);
        assert_eq!(d.press(cs(2300, 50, 50), &RULE), Verdict::Trigger);
    }

    #[test]
    fn the_second_press_must_land_in_the_systems_rectangle() {
        // 4 wide, centred: two pixels either side.
        for (dx, dy, expected) in [
            (2, 0, Verdict::Trigger),
            (-2, 2, Verdict::Trigger),
            (3, 0, Verdict::Pass),
            (0, -3, Verdict::Pass),
        ] {
            let mut d = Detector::new();
            d.press(cs(1000, 50, 50), &RULE);
            assert_eq!(d.press(cs(1100, 50 + dx, 50 + dy), &RULE), expected, "({dx},{dy})");
        }
        // Width and height are separate numbers.
        let wide = Rule { width: 40, height: 4, ..RULE };
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &wide);
        assert_eq!(d.press(cs(1100, 70, 50), &wide), Verdict::Trigger);
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &wide);
        assert_eq!(d.press(cs(1100, 50, 70), &wide), Verdict::Pass);
    }

    #[test]
    fn the_modifiers_must_be_exactly_the_triggers_on_both_presses() {
        let more = Mods { alt: true, ..Mods::CTRL_SHIFT };
        let fewer = Mods { shift: false, ..Mods::CTRL_SHIFT };
        for (first, second) in [
            (Mods::CTRL_SHIFT, more),
            (more, Mods::CTRL_SHIFT),
            (more, more),
            (Mods::CTRL_SHIFT, fewer),
            (fewer, Mods::CTRL_SHIFT),
            (Mods::NONE, Mods::NONE),
            (Mods::CTRL_SHIFT, Mods { win: true, ..Mods::CTRL_SHIFT }),
        ] {
            let mut d = Detector::new();
            assert_eq!(d.press(at(1000, 50, 50, first), &RULE), Verdict::Pass);
            assert_eq!(d.press(at(1100, 50, 50, second), &RULE), Verdict::Pass, "{first:?} then {second:?}");
            assert_eq!(d.release(), Verdict::Pass);
        }
    }

    #[test]
    fn a_press_without_the_modifiers_in_between_breaks_the_pair() {
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &RULE);
        assert_eq!(d.press(at(1100, 50, 50, Mods::NONE), &RULE), Verdict::Pass);
        assert_eq!(d.press(cs(1200, 50, 50), &RULE), Verdict::Pass);
    }

    #[test]
    fn a_third_quick_press_does_not_trigger_again() {
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &RULE);
        assert_eq!(d.press(cs(1100, 50, 50), &RULE), Verdict::Trigger);
        assert_eq!(d.press(cs(1200, 50, 50), &RULE), Verdict::Pass);
        assert_eq!(d.press(cs(1300, 50, 50), &RULE), Verdict::Trigger);
    }

    #[test]
    fn the_tick_count_wrapping_between_presses_is_still_a_short_gap() {
        let mut d = Detector::new();
        d.press(cs(u32::MAX - 100, 50, 50), &RULE);
        assert_eq!(d.press(cs(150, 50, 50), &RULE), Verdict::Trigger);
    }

    #[test]
    fn switched_off_nothing_triggers_and_nothing_is_eaten() {
        let off = Rule { trigger: Setting::Off, ..RULE };
        let mut d = Detector::new();
        assert_eq!(d.press(cs(1000, 50, 50), &off), Verdict::Pass);
        assert_eq!(d.press(cs(1100, 50, 50), &off), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
        // Switched off between the two presses of a pair.
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &RULE);
        assert_eq!(d.press(cs(1100, 50, 50), &off), Verdict::Pass);
        assert_eq!(d.press(cs(1200, 50, 50), &RULE), Verdict::Pass, "the pair did not survive it");
    }

    #[test]
    fn another_combination_can_be_the_trigger() {
        let alt = Mods { alt: true, ..Mods::NONE };
        let rule = Rule { trigger: Setting::On(alt), ..RULE };
        let mut d = Detector::new();
        d.press(at(1000, 50, 50, alt), &rule);
        assert_eq!(d.press(at(1100, 50, 50, alt), &rule), Verdict::Trigger);
        let mut d = Detector::new();
        d.press(cs(1000, 50, 50), &rule);
        assert_eq!(d.press(cs(1100, 50, 50), &rule), Verdict::Pass);
    }

    #[test]
    fn modifiers_are_named_as_they_are() {
        assert_eq!(Mods::CTRL_SHIFT.label(), "ctrl+shift");
        assert_eq!(Mods { alt: true, ..Mods::NONE }.label(), "alt");
        assert_eq!(Mods { ctrl: true, ..Mods::NONE }.label(), "ctrl");
        assert_eq!(Mods { shift: true, ..Mods::NONE }.label(), "shift");
        assert_eq!(Mods { win: true, ..Mods::NONE }.label(), "super");
        assert_eq!(Mods { shift: true, win: true, ..Mods::NONE }.label(), "shift+super");
        assert_eq!(Mods { ctrl: true, alt: true, ..Mods::NONE }.label(), "ctrl+alt");
        assert_eq!(Mods { ctrl: true, shift: true, alt: true, win: true }.label(), "shift+ctrl+alt+super");
        assert_eq!(Mods::NONE.label(), "none");
    }

    #[test]
    fn the_setting_is_the_cores_modifier_bits() {
        assert_eq!(Setting::from_bits(3), Setting::On(Mods::CTRL_SHIFT), "the Windows default");
        assert_eq!(Setting::from_bits(0), Setting::Off);
        assert_eq!(Setting::from_bits(1), Setting::On(Mods { shift: true, ..Mods::NONE }));
        assert_eq!(Setting::from_bits(2), Setting::On(Mods { ctrl: true, ..Mods::NONE }));
        assert_eq!(Setting::from_bits(4), Setting::On(Mods { alt: true, ..Mods::NONE }));
        assert_eq!(Setting::from_bits(8), Setting::On(Mods { win: true, ..Mods::NONE }));
        assert_eq!(Setting::from_bits(15), Setting::On(Mods { ctrl: true, shift: true, alt: true, win: true }));
    }

    #[test]
    fn bits_that_name_no_modifier_are_off_not_no_modifiers_held() {
        // Caps lock (16) and num lock (32) alone, and the sided bits.
        for bits in [16, 32, 48, 64, 1 << 9] {
            assert_eq!(Setting::from_bits(bits), Setting::Off, "{bits}");
        }
        assert_eq!(Setting::from_bits(16 | 3), Setting::On(Mods::CTRL_SHIFT));
    }
}
