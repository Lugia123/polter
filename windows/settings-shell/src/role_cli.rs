//! Which of a role's agent CLIs its row in the `Role ▸` menu offers (#1670),
//! out here because `polter-host`'s own tests cannot run off Windows.
//!
//! A role can be set up for several CLIs -- the official ones list Claude
//! Code and Codex -- but a CLI is only startable here when the core found an
//! adapter for it: its plugin is switched on and its adapter can run on this
//! machine. That set is `ghostty_app_agent_clis`'s `clis`, read by
//! `agent_cli.discover`, the same walk the core makes when it picks a CLI
//! for a role started without one (#1667, `Persona.defaultCli`); the core
//! reads it again when a plugin is switched on or off
//! (`App.reloadPlugins`). Offering a CLI outside it is a row that says
//! "Codex" and answers "no adapter" when clicked.
//!
//! The macOS side is `RoleCliOffer.swift`, with the same cases and the same
//! tests.

/// What a role's row offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CliOffer {
    /// One row carrying the role key alone: the core decides what it means
    /// -- wear the role if an agent is here, otherwise start its CLI, or
    /// refuse and say why.
    Role,
    /// One row that starts this CLI. Carries `key,cli`: of several set up,
    /// only this one is here, and the core is told so rather than left to
    /// work it out again.
    Only(String),
    /// A submenu, one row per CLI, in the role's order.
    Choose(Vec<String>),
}

impl CliOffer {
    /// `configured`: the CLIs the role is set up for, in its order.
    /// `available`: the keys the core found adapters for, or `None` when the
    /// core has not been read yet. **`None` is not "none"**: with nothing
    /// known, every CLI the role names is offered, as before #1670, rather
    /// than the menu claiming none of them is here.
    pub fn of(configured: &[String], available: Option<&[String]>) -> CliOffer {
        let here: Vec<String> = match available {
            Some(found) => configured.iter().filter(|c| found.contains(c)).cloned().collect(),
            None => configured.to_vec(),
        };
        match here.len() {
            // None of them is here. The core still has an answer -- an agent
            // in this terminal wears the role without starting anything -- so
            // the row stays and the core says the rest.
            0 => CliOffer::Role,
            1 if configured.len() > 1 => CliOffer::Only(here[0].clone()),
            1 => CliOffer::Role,
            _ => CliOffer::Choose(here),
        }
    }

    /// What the role's own row hands the core when picked, or `None` when
    /// the row opens a submenu instead.
    pub fn row_arg(&self, key: &str) -> Option<String> {
        match self {
            CliOffer::Role => Some(key.to_string()),
            CliOffer::Only(cli) => Some(format!("{key},{cli}")),
            CliOffer::Choose(_) => None,
        }
    }

    /// The submenu's rows, as (CLI key, what the row hands the core). Empty
    /// unless the row opens one.
    pub fn choices(&self, key: &str) -> Vec<(String, String)> {
        match self {
            CliOffer::Choose(clis) => clis.iter().map(|c| (c.clone(), format!("{key},{c}"))).collect(),
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }

    fn of(configured: &[&str], available: Option<&[&str]>) -> CliOffer {
        let found = available.map(v);
        CliOffer::of(&v(configured), found.as_deref())
    }

    const BOTH: &[&str] = &["claude-code", "codex"];

    /// The official roles as they ship: Codex's plugin is off, so its
    /// adapter is not found, and the row starts Claude Code with no submenu
    /// -- saying which, so the core is not left to choose again.
    #[test]
    fn a_role_for_two_with_only_one_here_starts_that_one() {
        assert_eq!(of(BOTH, Some(&["claude-code", "gemini"])), CliOffer::Only("claude-code".into()));
        assert_eq!(of(BOTH, Some(&["codex"])), CliOffer::Only("codex".into()));
    }

    #[test]
    fn both_here_is_a_choice_in_the_roles_order() {
        assert_eq!(of(BOTH, Some(&["codex", "claude-code"])), CliOffer::Choose(v(BOTH)));
        assert_eq!(
            of(&["codex", "claude-code", "gemini"], Some(&["gemini", "codex"])),
            CliOffer::Choose(v(&["codex", "gemini"]))
        );
    }

    /// Never read is not "none here": everything set up is offered, as
    /// before #1670.
    #[test]
    fn not_read_yet_offers_everything_set_up() {
        assert_eq!(of(BOTH, None), CliOffer::Choose(v(BOTH)));
        assert_eq!(of(&["codex"], None), CliOffer::Role);
    }

    /// None of them here, one set up, or none set up: the row carries the
    /// key and the core decides.
    #[test]
    fn otherwise_the_row_carries_the_key_alone() {
        assert_eq!(of(BOTH, Some(&[])), CliOffer::Role);
        assert_eq!(of(BOTH, Some(&["gemini"])), CliOffer::Role);
        assert_eq!(of(&["codex"], Some(&[])), CliOffer::Role);
        assert_eq!(of(&["codex"], Some(&["codex"])), CliOffer::Role);
        assert_eq!(of(&[], Some(&["codex"])), CliOffer::Role);
    }

    #[test]
    fn what_each_row_hands_the_core() {
        assert_eq!(CliOffer::Role.row_arg("duo"), Some("duo".into()));
        assert_eq!(CliOffer::Only("codex".into()).row_arg("duo"), Some("duo,codex".into()));
        assert_eq!(CliOffer::Choose(v(BOTH)).row_arg("duo"), None);

        assert_eq!(
            CliOffer::Choose(v(BOTH)).choices("duo"),
            vec![("claude-code".into(), "duo,claude-code".into()), ("codex".into(), "duo,codex".into())]
        );
        assert!(CliOffer::Role.choices("duo").is_empty());
        assert!(CliOffer::Only("codex".into()).choices("duo").is_empty());
    }
}
