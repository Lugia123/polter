//! The two languages the menu offers, and the startup decision about which
//! one the core is asked for. **Pure** -- no window, no environment, no file --
//! so its tests run under a bare `rustc --test` on any machine; `language.rs`
//! is the half that touches Windows and does what `decide` says.
//!
//! # Why the decision is a function of its own
//!
//! On the test machine a saved choice of Chinese came back as English after a
//! restart, and the core logged `no translation shipped for locale=en_US.UTF-8`.
//! That spelling -- underscore, `.UTF-8` -- only ever comes from `LANG`
//! (`GetUserDefaultLocaleName` answers `en-US`), and nothing in the host writes
//! `en_US.UTF-8` except a saved English. So the likeliest reading is that the
//! process was started with `LANG` already set, and `HonourInherited` below was
//! the arm that ran. The table was four arms inside `apply_before_init` with no
//! test on any of them; this is where they are pinned.

/// The languages the menu offers. `AppLanguage.allCases`, in the same order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AppLanguage {
    English,
    SimplifiedChinese,
}

impl AppLanguage {
    pub const ALL: [AppLanguage; 2] = [AppLanguage::English, AppLanguage::SimplifiedChinese];

    /// What is written to the file. `AppLanguage`'s raw values, so a file
    /// and a macOS defaults entry holding the same choice say the same thing.
    pub fn raw(self) -> &'static str {
        match self {
            AppLanguage::English => "en",
            AppLanguage::SimplifiedChinese => "zh-Hans",
        }
    }

    /// Shown in its own language, never translated -- and therefore not
    /// wrapped in `tr`. A menu that says "Chinese" to someone who cannot read
    /// English is no use to them.
    pub fn display_name(self) -> &'static str {
        match self {
            AppLanguage::English => "English",
            AppLanguage::SimplifiedChinese => "简体中文",
        }
    }

    /// What goes into `LANG`. The same strings `posixLocale` hands the core
    /// on macOS. `en_US` matches no catalogue, which is how English is chosen:
    /// the msgids are English.
    ///
    /// **This is where `zh-Hans` becomes `zh_CN`**, which is the name of the
    /// directory the catalogue is installed under. The file and the directory
    /// spelling the language differently is expected; this mapping is the
    /// bridge, and a test below pins it.
    pub fn posix_locale(self) -> &'static str {
        match self {
            AppLanguage::English => "en_US.UTF-8",
            AppLanguage::SimplifiedChinese => "zh_CN.UTF-8",
        }
    }

    /// Read back a stored or reported name. **By prefix**, as macOS does, so a
    /// hand-edited `zh-Hans-CN` still counts.
    pub fn from_name(name: &str) -> Option<AppLanguage> {
        let name = name.trim();
        AppLanguage::ALL
            .into_iter()
            .find(|l| !name.is_empty() && name.starts_with(l.raw()))
    }
}

/// What to do with `LANG` just before `ghostty_init`.
///
/// **Four outcomes, because each writes a different log line** and the log
/// line is the only place the person can find out which one happened.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Startup {
    /// `LANG` was already set and a choice was saved: the environment wins
    /// and the saved choice is **not applied**. See `language.rs`'s module
    /// comment for why a set `LANG` is honoured.
    HonourInherited { saved: AppLanguage },
    /// `LANG` was already set and nothing was saved.
    InheritedNoChoice,
    /// No `LANG`, a saved choice: put `LANG` in place for `ghostty_init`.
    Apply(AppLanguage),
    /// Neither: the core asks Windows.
    FollowSystem,
}

/// The decision. `inherited` is `LANG` as the process found it.
///
/// **An empty `LANG` counts as unset**, the same rule `i18n.zig` applies when
/// it reads the variable (`v.len > 0`). If this side called an empty value
/// "set", the saved choice would be skipped and the core would then ignore
/// the empty value too -- English, for no reason anybody could see.
pub fn decide(inherited: Option<&str>, saved: Option<AppLanguage>) -> Startup {
    let inherited_is_set = inherited.is_some_and(|v| !v.is_empty());
    match (inherited_is_set, saved) {
        (true, Some(s)) => Startup::HonourInherited { saved: s },
        (true, None) => Startup::InheritedNoChoice,
        (false, Some(s)) => Startup::Apply(s),
        (false, None) => Startup::FollowSystem,
    }
}

/// What the picker says once a choice is saved.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Notice<'a> {
    /// "The language changes the next time Polter starts." True only when
    /// nothing in the environment will stand in its way.
    NextStart,
    /// `LANG` is set -- to this value -- in the environment this Polter was
    /// started from, and a set `LANG` is honoured over the saved choice. The
    /// value is shown so the person can go and clear it.
    LangWins(&'a str),
}

/// The picker's words, **decided by the same table the next start uses.**
///
/// The picker used to say "next time" unconditionally, and on a machine whose
/// environment set `LANG` the next start then did not apply the choice --
/// the only trace was a log line. Asking `decide` here, with the `LANG` this
/// process was started with, means the sentence and the startup cannot
/// disagree: whatever makes the next start take `HonourInherited` makes the
/// picker say so now.
///
/// `lang` is read at the moment of the pick. `restore_after_init` has put
/// back whatever the process was started with by then, so it is the
/// environment the person launched Polter from -- **a fact that can be read,
/// and nothing more is claimed**: not which shell set it, nor why.
pub fn notice_after_save(lang: Option<&str>, saved: AppLanguage) -> Notice<'_> {
    match decide(lang, Some(saved)) {
        Startup::HonourInherited { .. } => Notice::LangWins(lang.unwrap_or_default()),
        Startup::Apply(_) | Startup::InheritedNoChoice | Startup::FollowSystem => Notice::NextStart,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The file holds macOS's raw values, and reading one back is by prefix.
    #[test]
    fn stored_names_read_back() {
        assert_eq!(AppLanguage::from_name("en"), Some(AppLanguage::English));
        assert_eq!(AppLanguage::from_name("zh-Hans\r\n"), Some(AppLanguage::SimplifiedChinese));
        assert_eq!(AppLanguage::from_name("zh-Hans-CN"), Some(AppLanguage::SimplifiedChinese));
        assert_eq!(AppLanguage::from_name(""), None);
        assert_eq!(AppLanguage::from_name("de"), None);
    }

    /// **The bridge between the file and the catalogue directory.** A saved
    /// `zh-Hans` must reach the core as `zh_CN.UTF-8`: the core strips the
    /// encoding and looks for `locale\zh_CN\`. If this ever said `zh_Hans`,
    /// the core would find no catalogue and draw English.
    #[test]
    fn a_saved_chinese_asks_the_core_for_zh_cn() {
        let saved = AppLanguage::from_name("zh-Hans").unwrap();
        assert_eq!(saved.posix_locale(), "zh_CN.UTF-8");
        assert_eq!(decide(None, Some(saved)), Startup::Apply(AppLanguage::SimplifiedChinese));
    }

    /// The four cells of the table, one each.
    #[test]
    fn each_cell_of_the_table() {
        let zh = AppLanguage::SimplifiedChinese;
        assert_eq!(decide(Some("en_US.UTF-8"), Some(zh)), Startup::HonourInherited { saved: zh });
        assert_eq!(decide(Some("en_US.UTF-8"), None), Startup::InheritedNoChoice);
        assert_eq!(decide(None, Some(zh)), Startup::Apply(zh));
        assert_eq!(decide(None, None), Startup::FollowSystem);
    }

    /// **The case the test machine most likely hit**, stated as its own test
    /// so its name says what it means: a shell that exports `LANG` starts
    /// Polter, and a saved Chinese is not applied.
    #[test]
    fn an_inherited_lang_keeps_a_saved_choice_from_applying() {
        let zh = AppLanguage::SimplifiedChinese;
        assert_ne!(decide(Some("en_US.UTF-8"), Some(zh)), Startup::Apply(zh));
    }

    /// **The picker tells the truth when `LANG` is set**, and names the value.
    /// The sentence it used to say regardless -- "next time" -- is the
    /// mutation this test exists to redden.
    #[test]
    fn with_lang_set_the_picker_says_lang_wins_and_shows_it() {
        let zh = AppLanguage::SimplifiedChinese;
        assert_eq!(notice_after_save(Some("en_US.UTF-8"), zh), Notice::LangWins("en_US.UTF-8"));
        assert_eq!(notice_after_save(None, zh), Notice::NextStart);
        // Empty is unset here exactly as it is at startup.
        assert_eq!(notice_after_save(Some(""), zh), Notice::NextStart);
    }

    /// The picker and the next start answer from one table: every `LANG` for
    /// which the start would not apply the choice is one the picker warns
    /// about, and no other.
    #[test]
    fn the_picker_and_the_next_start_never_disagree() {
        for lang in [None, Some(""), Some("en_US.UTF-8"), Some("zh_CN.UTF-8"), Some("C")] {
            for saved in AppLanguage::ALL {
                let applies = decide(lang, Some(saved)) == Startup::Apply(saved);
                let warned = matches!(notice_after_save(lang, saved), Notice::LangWins(_));
                assert_eq!(applies, !warned, "LANG={lang:?} saved={saved:?}");
            }
        }
    }

    /// An empty `LANG` is no `LANG`, on both sides of the DLL boundary.
    #[test]
    fn an_empty_lang_is_unset() {
        let zh = AppLanguage::SimplifiedChinese;
        assert_eq!(decide(Some(""), Some(zh)), Startup::Apply(zh));
        assert_eq!(decide(Some(""), None), Startup::FollowSystem);
    }
}
