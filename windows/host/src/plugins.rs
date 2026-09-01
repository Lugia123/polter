//! Reading the plugin catalogue, and writing what the user says about it.
//!
//! **This host is the third reader of the same files, not a second source of
//! truth.** `src/poltergeist/Plugin.zig` reads them for the core; the macOS
//! app reads them for its settings UI and says so in its own header. Nothing
//! is cached past the moment it is shown, so a file edited by hand and a file
//! edited here cannot drift apart.
//!
//! **Two files per plugin, and only one of them is ours to write:**
//!
//! | file | who writes it |
//! | --- | --- |
//! | `<dir>/plugin.json` | the plugin author. Read only. |
//! | `<config>/polter/plugins/<key>.json` | **this, and the macOS app.** |
//!
//! **The config directory has to be the one the core computes**, or the
//! symptom is "the setting saved and the plugin did not change", with nothing
//! logged anywhere. `src/os/xdg.zig` uses `XDG_CONFIG_HOME` and falls back to
//! **`LOCALAPPDATA`** on Windows (`windows_env = "LOCALAPPDATA"`, three call
//! sites), then appends `polter/plugins`. That is reproduced here, and the
//! resolved path is logged on the first read so a mismatch is visible without
//! a debugger.
//!
//! **The written shape is fixed by the reader**, `Settings.readMaybe` in
//! `Plugin.zig`:
//!
//! ```json
//! {"enabled": true, "params": {"url": "cmd:op read op://Private/hook"}}
//! ```
//!
//! `params` values are strings on both sides of the wire -- a boolean
//! parameter is the text `true` or `false` -- because that is what
//! `Plugin.Param` holds.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::logf;

/// What a value is allowed to be, and therefore what control to put on screen.
///
/// Mirrors `Plugin.Parameter.Control` in the macOS app. **Anything the schema
/// says that this build cannot make a control out of falls back to `Text`** --
/// refusing to show it would hide a setting the plugin needs, which is worse
/// than showing a text box.
#[derive(Clone, PartialEq, Debug)]
pub enum Control {
    Text,
    Choice(Vec<String>),
    Flag,
}

#[derive(Clone, Debug)]
pub struct Parameter {
    pub name: String,
    pub title: String,
    pub help: String,
    pub required: bool,
    /// The manifest said `"secret": true`. The core reads the same field and
    /// treats it as the only thing that decides it.
    pub secret: bool,
    pub control: Control,
    /// The schema's `default`, as text. **Shown as a starting point and not
    /// written to the file until the user saves** -- writing it on sight would
    /// turn a default into a decision.
    pub default: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Plugin {
    /// Directory name; the name every file and message uses.
    pub key: String,
    pub name: String,
    pub summary: String,
    /// Where the plugin itself lives. Kept because a settings page that
    /// cannot say *which* file it is configuring is a page you cannot check
    /// by hand, and hand-checking is how the first plugin gets debugged.
    #[allow(dead_code)]
    pub dir: PathBuf,
    pub params: Vec<Parameter>,
    /// What the user has said. Missing file reads as "not configured", which
    /// is the same as off.
    pub enabled: bool,
    pub values: BTreeMap<String, String>,
}

// ------------------------------------------------------------------ paths

/// `<config>/polter/plugins`, the same directory `xdg.zig` computes.
pub fn user_dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .or_else(|| std::env::var_os("LOCALAPPDATA").filter(|v| !v.is_empty()))?;
    Some(PathBuf::from(base).join("polter").join("plugins"))
}

/// The settings file for one plugin.
pub fn settings_path(key: &str) -> Option<PathBuf> {
    Some(user_dir()?.join(format!("{key}.json")))
}

/// Why the shipped plugin directory is or is not there.
///
/// **Three outcomes, not an `Option`.** "There is no plugin directory" and
/// "the plugin directory is there and holds nothing" are different facts about
/// the installation, and the page has to be able to say which -- one is a
/// broken install, the other is a build that shipped no plugins. Collapsing
/// them is how this defect hid: the page said *no plugins found* while the
/// resources check said `has_polter/plugins=true`, and both were telling the
/// truth about two different directories.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Shipped {
    /// The directory exists. Contents still unknown.
    Found(PathBuf),
    /// `POLTER_RESOURCES_DIR` is not set, so there is nothing to look under.
    NoResourcesDir,
    /// It is set, and this path under it does not exist.
    Missing(PathBuf),
}

/// Where the plugins that ship with the build live.
///
/// # This used to look beside the executable, and nothing agreed with it
///
/// The core reads `{resources}/polter/plugins` (`App.zig:717`). This host read
/// `<exe dir>/plugins`. **The two never once pointed at the same place**, so
/// the core could list eight plugins while this page said there were none --
/// and because each was internally consistent, neither reported a problem.
///
/// The fix is to read the core's directory, **not to copy the plugins next to
/// the executable**. A copy would be a second set of plugin manifests that
/// starts identical and diverges the first time one side is updated, and the
/// symptom then is a settings page describing a plugin that behaves
/// differently from what it describes.
pub fn shipped() -> Shipped {
    // The same variable `main.rs` sets before `ghostty_init`, and the same one
    // `os/resourcesdir.zig` reads. **Deliberately not falling back to the
    // executable's directory**: that fallback is exactly the state this
    // function is being fixed out of, and it fails by looking like an empty
    // plugin directory rather than like a missing one.
    let Some(res) = std::env::var_os("POLTER_RESOURCES_DIR").filter(|v| !v.is_empty()) else {
        return Shipped::NoResourcesDir;
    };
    let dir = PathBuf::from(res).join("polter").join("plugins");
    if dir.is_dir() {
        Shipped::Found(dir)
    } else {
        Shipped::Missing(dir)
    }
}

/// The shipped directory, when there is one.
pub fn shipped_dir() -> Option<PathBuf> {
    match shipped() {
        Shipped::Found(d) => Some(d),
        _ => None,
    }
}

/// One line saying which of the three cases holds, for the startup log and
/// for the settings page's empty state.
///
/// **The wording distinguishes the cases on purpose.** "I could not find the
/// plugin directory" sends someone to look at the install; "the directory is
/// there and empty" sends them to look at the build. Telling them the wrong
/// one costs a whole investigation, which is what this defect already cost.
pub fn shipped_note() -> String {
    match shipped() {
        Shipped::Found(d) => {
            let n = std::fs::read_dir(&d).map(|e| e.flatten().count()).unwrap_or(0);
            format!("shipped plugins: {} entries in {}", n, d.display())
        }
        Shipped::NoResourcesDir => {
            "shipped plugins: POLTER_RESOURCES_DIR is not set, so the bundled \
             plugin directory could not be located at all"
                .into()
        }
        Shipped::Missing(d) => {
            format!("shipped plugins: {} does not exist", d.display())
        }
    }
}

// --------------------------------------------------------------- manifest

fn as_str(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Bool(b) => b.to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

/// Turn one JSON-Schema property into a control.
fn control_of(spec: &serde_json::Value) -> Control {
    // A closed set beats the declared type: a string with an `enum` is a
    // choice, not a text box.
    if let Some(items) = spec.get("enum").and_then(|v| v.as_array()) {
        let choices: Vec<String> = items.iter().map(as_str).filter(|s| !s.is_empty()).collect();
        if !choices.is_empty() {
            return Control::Choice(choices);
        }
    }
    match spec.get("type").and_then(|v| v.as_str()) {
        Some("boolean") => Control::Flag,
        // Everything else, including types this build does not know, is text.
        _ => Control::Text,
    }
}

fn parse_manifest(key: &str, dir: &Path, text: &str) -> Option<Plugin> {
    let v: serde_json::Value = serde_json::from_str(text)
        .map_err(|e| logf!("[plug] {}: manifest will not parse: {}", key, e))
        .ok()?;

    let name = v
        .get("name")
        .map(as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| key.to_string());
    let summary = v.get("summary").map(as_str).unwrap_or_default();

    // `schema.properties` is the shape both the core and the macOS app read.
    let props = v
        .get("schema")
        .and_then(|s| s.get("properties"))
        .and_then(|p| p.as_object());
    let required: Vec<String> = v
        .get("schema")
        .and_then(|s| s.get("required"))
        .and_then(|r| r.as_array())
        .map(|a| a.iter().map(as_str).collect())
        .unwrap_or_default();

    let mut params = Vec::new();
    if let Some(props) = props {
        for (pname, spec) in props {
            params.push(Parameter {
                name: pname.clone(),
                title: spec
                    .get("title")
                    .map(as_str)
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| pname.clone()),
                help: spec.get("description").map(as_str).unwrap_or_default(),
                required: required.iter().any(|r| r == pname),
                secret: spec.get("secret").and_then(|s| s.as_bool()).unwrap_or(false),
                control: control_of(spec),
                default: spec.get("default").map(as_str).filter(|s| !s.is_empty()),
            });
        }
    }

    Some(Plugin {
        key: key.to_string(),
        name,
        summary,
        dir: dir.to_path_buf(),
        params,
        enabled: false,
        values: BTreeMap::new(),
    })
}

// --------------------------------------------------------------- settings

/// The exact bytes this host writes for one plugin's settings.
///
/// **Kept as a free function taking plain data** so the fixture the Zig test
/// reads is produced by this and nothing else. If it were inlined into the
/// save path, the fixture and the product could drift and the test would
/// still pass.
pub fn render_settings(enabled: bool, values: &BTreeMap<String, String>) -> String {
    let params: serde_json::Map<String, serde_json::Value> = values
        .iter()
        .map(|(k, v)| (k.clone(), serde_json::Value::String(v.clone())))
        .collect();
    let doc = serde_json::json!({ "enabled": enabled, "params": params });
    // Pretty-printed because a person edits this file by hand too, and a
    // trailing newline because every other file in this tree has one.
    format!("{}\n", serde_json::to_string_pretty(&doc).unwrap_or_default())
}

fn read_settings(key: &str) -> (bool, BTreeMap<String, String>) {
    let mut values = BTreeMap::new();
    let Some(path) = settings_path(key) else {
        return (false, values);
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return (false, values);
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
        logf!("[plug] {}: settings will not parse, treating as unconfigured", key);
        return (false, values);
    };
    let Some(obj) = v.as_object() else {
        return (false, values);
    };

    // The older shape was the parameters alone, with "is it on" living in the
    // main config. `Plugin.zig` reads such a file as enabled, and reading it
    // any other way here would show "off" for a plugin the core is happily
    // running.
    let modern = obj.contains_key("params") || obj.contains_key("enabled");
    if !modern {
        for (k, val) in obj {
            values.insert(k.clone(), as_str(val));
        }
        return (true, values);
    }

    let enabled = obj.get("enabled").and_then(|b| b.as_bool()).unwrap_or(false);
    if let Some(p) = obj.get("params").and_then(|p| p.as_object()) {
        for (k, val) in p {
            values.insert(k.clone(), as_str(val));
        }
    }
    (enabled, values)
}

/// Write one plugin's settings.
///
/// **Written to a temporary file and renamed**, so a crash halfway through
/// leaves the previous settings rather than half of the new ones. A truncated
/// settings file reads as "not configured", which would silently switch a
/// plugin off.
pub fn save(key: &str, enabled: bool, values: &BTreeMap<String, String>) -> bool {
    let Some(path) = settings_path(key) else {
        logf!("[plug] {}: no config directory; nothing saved", key);
        return false;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("json.tmp");
    let body = render_settings(enabled, values);

    if let Err(e) = std::fs::write(&tmp, body.as_bytes()) {
        logf!("[plug] {}: write failed: {}", key, e);
        return false;
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        logf!("[plug] {}: rename failed: {}", key, e);
        let _ = std::fs::remove_file(&tmp);
        return false;
    }
    logf!("[plug] {} saved: enabled={} params={}", key, enabled, values.len());
    true
}

// ---------------------------------------------------------------- catalog

/// Every plugin this build can see, shipped first, then the user's own.
pub fn catalog() -> Vec<Plugin> {
    let mut out: Vec<Plugin> = Vec::new();

    if let Some(d) = user_dir() {
        logf!("[plug] config dir {}", d.display());
    }
    // **Which of the three cases holds, every time the catalog is built.**
    // The page's empty state and this line have to agree, and both have to
    // distinguish "no directory" from "empty directory" -- the two looked
    // identical for as long as this host read the wrong directory entirely.
    logf!("[plug] {}", shipped_note());

    for base in [shipped_dir(), user_dir()].into_iter().flatten() {
        let Ok(entries) = std::fs::read_dir(&base) else {
            continue;
        };
        for e in entries.flatten() {
            let dir = e.path();
            if !dir.is_dir() {
                continue;
            }
            let Some(key) = dir.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            // `_sdk` is a library, not a plugin: it declares no `exec` and
            // has no manifest of its own to show.
            if key.starts_with('_') {
                continue;
            }
            if out.iter().any(|p| p.key == key) {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(dir.join("plugin.json")) else {
                continue;
            };
            if let Some(mut p) = parse_manifest(key, &dir, &text) {
                let (enabled, values) = read_settings(key);
                p.enabled = enabled;
                p.values = values;
                out.push(p);
            }
        }
    }

    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    logf!("[plug] catalog: {} plugins", out.len());
    out
}

/// `--write-settings-fixture <path>`: write the file the Zig test reads.
///
/// **The fixture has to come out of the product's own writer**, otherwise the
/// cross-implementation test checks a file nobody ships. Regenerate with this
/// flag on Windows after changing `render_settings`; the Zig test then says
/// whether `std.json` still reads it.
pub fn write_fixture(path: &str) -> bool {
    let mut values = BTreeMap::new();
    values.insert("url".to_string(), "cmd:op read op://Private/hook".to_string());
    values.insert("verbose".to_string(), "true".to_string());
    values.insert(
        "quote".to_string(),
        "a \"quoted\" value, a backslash \\, and 中文".to_string(),
    );
    let body = render_settings(true, &values);
    match std::fs::write(path, body.as_bytes()) {
        Ok(()) => {
            logf!("[plug] fixture written to {}", path);
            true
        }
        Err(e) => {
            logf!("[plug] fixture write failed: {}", e);
            false
        }
    }
}

#[cfg(test)]
mod shipped_tests {
    use super::*;

    /// These tests set a process-wide environment variable, so they must not
    /// run beside each other. Rust runs tests in threads by default, so the
    /// lock is not optional -- without it the failures are intermittent and
    /// read as flakiness rather than as a shared-state bug.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    struct EnvGuard {
        old: Option<std::ffi::OsString>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }
    impl EnvGuard {
        fn set(v: Option<&std::path::Path>) -> EnvGuard {
            let lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let old = std::env::var_os("POLTER_RESOURCES_DIR");
            match v {
                Some(p) => std::env::set_var("POLTER_RESOURCES_DIR", p),
                None => std::env::remove_var("POLTER_RESOURCES_DIR"),
            }
            EnvGuard { old, _lock: lock }
        }
    }
    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match self.old.take() {
                Some(v) => std::env::set_var("POLTER_RESOURCES_DIR", v),
                None => std::env::remove_var("POLTER_RESOURCES_DIR"),
            }
        }
    }

    /// **The defect this replaces.** The shipped directory has to be the one
    /// the core reads -- `{resources}/polter/plugins` (`App.zig:717`) -- and
    /// not `<exe dir>/plugins`, which nothing else in the system has ever
    /// pointed at.
    #[test]
    fn the_shipped_directory_is_the_one_the_core_reads() {
        let tmp = std::env::temp_dir().join("polter-plug-test-found");
        let dir = tmp.join("polter").join("plugins");
        let _ = std::fs::create_dir_all(&dir);
        let _g = EnvGuard::set(Some(&tmp));

        assert_eq!(shipped(), Shipped::Found(dir.clone()));
        assert_eq!(shipped_dir().as_deref(), Some(dir.as_path()));

        // The floor: it must not be the executable's directory. If those two
        // ever coincide on some machine this assertion is vacuous, so it is
        // written against the *shape* -- the path has to end in the core's
        // two components.
        let d = shipped_dir().unwrap();
        assert!(d.ends_with("polter/plugins") || d.ends_with("polter\\plugins"), "{d:?}");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// A resources directory that has no plugin subdirectory is **missing**,
    /// which is a different report from having no plugins.
    #[test]
    fn a_resources_dir_without_the_subdirectory_is_missing_not_empty() {
        let tmp = std::env::temp_dir().join("polter-plug-test-missing");
        let _ = std::fs::create_dir_all(&tmp);
        let _g = EnvGuard::set(Some(&tmp));

        match shipped() {
            Shipped::Missing(d) => assert!(d.starts_with(&tmp)),
            other => panic!("expected Missing, got {other:?}"),
        }
        assert!(shipped_dir().is_none());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// **No fallback to the executable's directory.** That fallback is the
    /// state being fixed: it produced a path that existed on no machine, and
    /// failed by looking like an empty plugin directory instead of a missing
    /// one. An unset variable has to say so.
    #[test]
    fn an_unset_variable_does_not_fall_back_to_the_executable() {
        let _g = EnvGuard::set(None);
        assert_eq!(shipped(), Shipped::NoResourcesDir);
        assert!(shipped_dir().is_none());
    }

    /// The three cases produce three different sentences. **A single message
    /// covering all three is the defect**: "no plugins found" was true of a
    /// broken install, an empty build, and a host reading the wrong directory
    /// alike, and it sent the reader to the wrong one of the three.
    #[test]
    fn each_case_says_something_different() {
        let unset = {
            let _g = EnvGuard::set(None);
            shipped_note()
        };
        let missing = {
            let tmp = std::env::temp_dir().join("polter-plug-test-note");
            let _ = std::fs::create_dir_all(&tmp);
            let _g = EnvGuard::set(Some(&tmp));
            let n = shipped_note();
            let _ = std::fs::remove_dir_all(&tmp);
            n
        };
        let found = {
            let tmp = std::env::temp_dir().join("polter-plug-test-note2");
            let _ = std::fs::create_dir_all(tmp.join("polter").join("plugins"));
            let _g = EnvGuard::set(Some(&tmp));
            let n = shipped_note();
            let _ = std::fs::remove_dir_all(&tmp);
            n
        };
        assert_ne!(unset, missing);
        assert_ne!(missing, found);
        assert_ne!(unset, found);
        assert!(unset.contains("POLTER_RESOURCES_DIR"), "{unset}");
        assert!(missing.contains("does not exist"), "{missing}");
        assert!(found.contains("entries"), "{found}");
    }

    /// `user_dir()` is untouched by all of this: plugins a user installed
    /// themselves live under their own config directory and always did.
    #[test]
    fn the_user_directory_is_not_derived_from_resources() {
        let tmp = std::env::temp_dir().join("polter-plug-test-user");
        let _g = EnvGuard::set(Some(&tmp));
        if let Some(u) = user_dir() {
            assert!(!u.starts_with(&tmp), "user_dir must not follow the resources dir: {u:?}");
        }
    }
}
