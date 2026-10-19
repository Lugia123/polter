//! The Plugins submenu of the menu bar's Agents menu (task 1758): what it
//! lists and what each row does, decided here and drawn by `menu.rs`.
//!
//! **macOS's menu, row for row** (`PluginMenu.swift`): each installed plugin
//! by its name and what it is for, ticked when it is switched on, opening
//! onto Settings…, Switch On / Off and Show Log; then Open Plugins Folder
//! and Open Plugin Logs. Before this the row was «Plugins…», which opened
//! the settings window and nothing else.
//!
//! **Greyed, with the reason in the label, rather than hidden** -- the macOS
//! rule, kept: switching on a plugin with a required setting still empty
//! would look like it worked and then send nothing, and a log row that comes
//! and goes teaches nobody where the logs are.
//!
//! Rebuilt each time the menu opens, from the catalogue as it is then:
//! plugins are directories somebody can add or edit outside the app.

use crate::n_;

/// What one installed plugin is, as far as this menu needs to know.
#[derive(Clone, Debug)]
pub struct Facts {
    pub key: String,
    pub name: String,
    /// What its manifest subscribes to, as the wire spells it.
    pub events: Vec<String>,
    pub enabled: bool,
    /// How many required parameters are still empty.
    pub missing: usize,
    /// Whether it has written a log yet.
    pub has_log: bool,
}

/// What a row does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Act {
    /// The plugin's page in the settings window.
    Settings(String),
    /// Switch it on (`true`) or off.
    Switch(String, bool),
    /// Show this plugin's log file in Explorer, selected.
    ShowLog(String),
    /// Show the plugins directory.
    OpenFolder,
    /// Show the directory the logs are in.
    OpenLogs,
}

/// A row that does something, or says why it cannot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Leaf {
    /// Already translated.
    pub label: String,
    pub enabled: bool,
    pub act: Act,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Line {
    /// One plugin: its title, ticked when on, and its own rows.
    Plugin { title: String, checked: bool, rows: Vec<Leaf> },
    /// «No plugins installed», greyed.
    Nothing(String),
    Separator,
    Leaf(Leaf),
}

/// What a plugin subscribing to an event is for, in macOS's words
/// (`Plugin.phrase`). An event with no phrase adds nothing to the title: the
/// plugin is still listed under its name.
const PHRASES: &[(&str, &str)] = &[
    ("chat", n_("Keeps the conversations")),
    ("terminal.quiet", n_("Notifies you")),
    ("provision", n_("Sets your agent up to reach Polter")),
];

/// The plugin's name, and what it is for beside it when this build has a
/// phrase for anything it subscribes to: «name — phrase · phrase».
pub fn title(f: &Facts, tr: &dyn Fn(&str) -> String) -> String {
    let roles: Vec<String> = PHRASES.iter().filter(|(wire, _)| f.events.iter().any(|e| e == wire)).map(|(_, p)| tr(p)).collect();
    if roles.is_empty() {
        f.name.clone()
    } else {
        format!("{} — {}", f.name, roles.join(" · "))
    }
}

/// The whole submenu. `logs_exist` is whether the logs' directory is there.
pub fn menu(plugins: &[Facts], logs_exist: bool, tr: &dyn Fn(&str) -> String) -> Vec<Line> {
    let mut out = Vec::new();
    if plugins.is_empty() {
        out.push(Line::Nothing(tr(n_("No plugins installed"))));
    }
    for f in plugins {
        let switch = if f.enabled {
            Leaf { label: tr(n_("Switch Off")), enabled: true, act: Act::Switch(f.key.clone(), false) }
        } else if f.missing > 0 {
            Leaf { label: tr(n_("Switch On (needs settings first)")), enabled: false, act: Act::Switch(f.key.clone(), true) }
        } else {
            Leaf { label: tr(n_("Switch On")), enabled: true, act: Act::Switch(f.key.clone(), true) }
        };
        let log = if f.has_log {
            Leaf { label: tr(n_("Show Log")), enabled: true, act: Act::ShowLog(f.key.clone()) }
        } else {
            Leaf { label: tr(n_("Show Log (nothing written yet)")), enabled: false, act: Act::ShowLog(f.key.clone()) }
        };
        out.push(Line::Plugin {
            title: title(f, tr),
            checked: f.enabled,
            rows: vec![Leaf { label: tr(n_("Settings…")), enabled: true, act: Act::Settings(f.key.clone()) }, switch, log],
        });
    }
    out.push(Line::Separator);
    out.push(Line::Leaf(Leaf { label: tr(n_("Open Plugins Folder")), enabled: true, act: Act::OpenFolder }));
    out.push(Line::Leaf(if logs_exist {
        Leaf { label: tr(n_("Open Plugin Logs")), enabled: true, act: Act::OpenLogs }
    } else {
        Leaf { label: tr(n_("Open Plugin Logs (nothing written yet)")), enabled: false, act: Act::OpenLogs }
    }));
    out
}

/// Every row that can be picked, in the order `menu` lays them out: the
/// order a host numbers its command ids in, so an id is an index here.
pub fn leaves(lines: &[Line]) -> Vec<&Leaf> {
    let mut out = Vec::new();
    for l in lines {
        match l {
            Line::Plugin { rows, .. } => out.extend(rows.iter()),
            Line::Leaf(leaf) => out.push(leaf),
            Line::Nothing(_) | Line::Separator => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn same(s: &str) -> String {
        s.to_string()
    }

    fn facts(key: &str, events: &[&str], enabled: bool, missing: usize, has_log: bool) -> Facts {
        Facts { key: key.into(), name: key.to_uppercase(), events: events.iter().map(|e| e.to_string()).collect(), enabled, missing, has_log }
    }

    #[test]
    fn nothing_installed_says_so_and_still_offers_the_folder() {
        let m = menu(&[], false, &same);
        assert_eq!(m[0], Line::Nothing("No plugins installed".into()));
        assert_eq!(m[1], Line::Separator);
        let l = leaves(&m);
        assert_eq!(l.iter().map(|x| &x.act).collect::<Vec<_>>(), vec![&Act::OpenFolder, &Act::OpenLogs]);
        // No log yet anywhere: greyed, saying so.
        assert!(!l[1].enabled);
        assert_eq!(l[1].label, "Open Plugin Logs (nothing written yet)");
    }

    #[test]
    fn a_plugin_is_ticked_when_on_and_its_switch_says_the_other_way() {
        let m = menu(&[facts("archive", &["chat"], true, 0, true)], true, &same);
        let Line::Plugin { title, checked, rows } = &m[0] else { panic!("{m:?}") };
        assert_eq!(title, "ARCHIVE — Keeps the conversations");
        assert!(checked);
        assert_eq!(rows[0].act, Act::Settings("archive".into()));
        assert_eq!(rows[1], Leaf { label: "Switch Off".into(), enabled: true, act: Act::Switch("archive".into(), false) });
        assert_eq!(rows[2], Leaf { label: "Show Log".into(), enabled: true, act: Act::ShowLog("archive".into()) });
    }

    #[test]
    fn switching_on_waits_for_the_required_settings() {
        let m = menu(&[facts("notify", &["terminal.quiet"], false, 2, false)], true, &same);
        let Line::Plugin { checked, rows, .. } = &m[0] else { panic!() };
        assert!(!checked);
        assert_eq!(rows[1], Leaf { label: "Switch On (needs settings first)".into(), enabled: false, act: Act::Switch("notify".into(), true) });
        assert_eq!(rows[2].label, "Show Log (nothing written yet)");
        assert!(!rows[2].enabled);
        // Filled in: it may be switched on.
        let m = menu(&[facts("notify", &[], false, 0, false)], true, &same);
        let Line::Plugin { rows, .. } = &m[0] else { panic!() };
        assert_eq!(rows[1], Leaf { label: "Switch On".into(), enabled: true, act: Act::Switch("notify".into(), true) });
    }

    #[test]
    fn a_subscription_with_no_phrase_leaves_the_name_alone() {
        assert_eq!(title(&facts("x", &["something.new"], false, 0, false), &same), "X");
        assert_eq!(title(&facts("y", &["chat", "provision"], false, 0, false), &same), "Y — Keeps the conversations · Sets your agent up to reach Polter");
    }

    #[test]
    fn the_leaves_are_numbered_in_the_order_they_are_laid_out() {
        let m = menu(&[facts("a", &[], true, 0, true), facts("b", &[], false, 0, true)], true, &same);
        let acts: Vec<Act> = leaves(&m).into_iter().map(|l| l.act.clone()).collect();
        assert_eq!(
            acts,
            vec![
                Act::Settings("a".into()),
                Act::Switch("a".into(), false),
                Act::ShowLog("a".into()),
                Act::Settings("b".into()),
                Act::Switch("b".into(), true),
                Act::ShowLog("b".into()),
                Act::OpenFolder,
                Act::OpenLogs,
            ]
        );
    }
}
