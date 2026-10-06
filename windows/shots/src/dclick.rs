//! The mouse trigger: one left click with exactly the configured modifier
//! keys held (`screenshot-mouse-trigger`, `ctrl+shift` by default).
//!
//! It was a double click, and the window under it started out selected;
//! the module keeps the name it had then. One click now, and the screenshot
//! opens exactly as the hotkey opens it, with nothing selected: the window
//! under the pointer is the clear one there, and a second click -- which
//! lands on the overlay, not here -- is what selects it.
//!
//! **This runs inside a low-level mouse hook**, which sees every click made
//! anywhere on the machine and can eat it. So what it decides is two things
//! at once -- "is this the trigger" and "does the application under the
//! pointer get this click" -- and the second is the one that hurts when it is
//! wrong: a click eaten by mistake is a click that silently did nothing, in
//! somebody else's program.
//!
//! The rule: a press with exactly the trigger's modifiers held is the
//! trigger and is eaten, and its release is eaten with it, so the
//! application does not see a button come up that never went down. Every
//! other press, and every other release, passes.

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

/// What to do with the event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Let it through to whatever is under the pointer.
    Pass,
    /// The trigger: eat the press and take the screenshot.
    Trigger,
    /// The release of that press: eat it, nothing else.
    Swallow,
}

/// The hook's memory between events: whether the next release is the
/// trigger's.
#[derive(Debug, Default)]
pub struct Detector {
    eat_release: bool,
}

impl Detector {
    pub const fn new() -> Detector {
        Detector { eat_release: false }
    }

    /// A left button press with `held` down, while the setting is `trigger`.
    ///
    /// The modifiers must be **exactly** the trigger's: one more held, or
    /// one fewer, and it is some other chord that belongs to the
    /// application.
    pub fn press(&mut self, held: Mods, trigger: Setting) -> Verdict {
        self.eat_release = trigger == Setting::On(held);
        if self.eat_release {
            Verdict::Trigger
        } else {
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

    const ON: Setting = Setting::On(Mods::CTRL_SHIFT);

    #[test]
    fn one_press_with_the_modifiers_held_is_the_trigger() {
        let mut d = Detector::new();
        assert_eq!(d.press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
        // Not the second of two: the very first press there has ever been.
        assert_eq!(Detector::new().press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
    }

    #[test]
    fn the_release_of_the_eaten_press_is_eaten_and_only_that_one() {
        let mut d = Detector::new();
        assert_eq!(d.press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
        assert_eq!(d.release(), Verdict::Swallow);
        assert_eq!(d.release(), Verdict::Pass);
        // And an ordinary click afterwards is whole again.
        assert_eq!(d.press(Mods::NONE, ON), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
    }

    #[test]
    fn a_release_that_never_came_does_not_cost_the_next_click_its_release() {
        // The overlay opens on the trigger press and can take the release
        // with it, so the hook may never see one.
        let mut d = Detector::new();
        assert_eq!(d.press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
        assert_eq!(d.press(Mods::NONE, ON), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
    }

    #[test]
    fn the_release_is_eaten_even_though_the_trigger_is_off_by_then() {
        // The host turns the trigger off for as long as a session is open,
        // and the session opens between this press and its release.
        let mut d = Detector::new();
        assert_eq!(d.press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
        assert_eq!(d.release(), Verdict::Swallow);
        // With a session open the second click is the overlay's, whole.
        assert_eq!(d.press(Mods::CTRL_SHIFT, Setting::Off), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
    }

    #[test]
    fn the_modifiers_must_be_exactly_the_triggers() {
        let more = Mods { alt: true, ..Mods::CTRL_SHIFT };
        let fewer = Mods { shift: false, ..Mods::CTRL_SHIFT };
        for held in [more, fewer, Mods::NONE, Mods { win: true, ..Mods::CTRL_SHIFT }, Mods { shift: true, ..Mods::NONE }] {
            let mut d = Detector::new();
            assert_eq!(d.press(held, ON), Verdict::Pass, "{held:?}");
            assert_eq!(d.release(), Verdict::Pass, "{held:?}");
        }
    }

    #[test]
    fn every_press_that_qualifies_is_a_trigger_of_its_own() {
        // There is no pair to complete and none to break: a plain click in
        // between changes nothing, and a quick second one is not held back.
        // (The host has a session open after the first, and then says the
        // trigger is off.)
        let mut d = Detector::new();
        assert_eq!(d.press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
        assert_eq!(d.release(), Verdict::Swallow);
        assert_eq!(d.press(Mods::NONE, ON), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
        assert_eq!(d.press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
        assert_eq!(d.press(Mods::CTRL_SHIFT, ON), Verdict::Trigger);
    }

    #[test]
    fn switched_off_nothing_triggers_and_nothing_is_eaten() {
        let mut d = Detector::new();
        assert_eq!(d.press(Mods::CTRL_SHIFT, Setting::Off), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
        // No modifiers held is never a trigger: there is no setting for it.
        assert_eq!(d.press(Mods::NONE, Setting::Off), Verdict::Pass);
        assert_eq!(d.press(Mods::NONE, Setting::from_bits(0)), Verdict::Pass);
        assert_eq!(d.release(), Verdict::Pass);
    }

    #[test]
    fn another_combination_can_be_the_trigger() {
        let alt = Mods { alt: true, ..Mods::NONE };
        let mut d = Detector::new();
        assert_eq!(d.press(alt, Setting::On(alt)), Verdict::Trigger);
        assert_eq!(d.release(), Verdict::Swallow);
        assert_eq!(d.press(Mods::CTRL_SHIFT, Setting::On(alt)), Verdict::Pass);
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
