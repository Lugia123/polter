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

/// Where the plugins that ship with the build live: beside the executable.
pub fn shipped_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    Some(exe.parent()?.join("plugins"))
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
