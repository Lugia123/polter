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

use crate::plogf;

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
    /// What the manifest's `wants.events` asks to be handed, **as the wire
    /// spells it**. Kept raw on purpose: the phrase table below is
    /// presentation and is allowed to go stale, and a build that has never
    /// heard of an event still has to be able to say the plugin asked for it.
    pub events: Vec<String>,
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
        // process-wide: a plugin's manifest on disk; the same file whatever window is in front
        .map_err(|e| plogf!("[plug] {}: manifest will not parse: {}", key, e))
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

    // `wants.events`, verbatim. **Read here rather than looked up somewhere
    // else**: what a plugin is handed is a fact about its manifest, and the
    // page's job is to show it, not to decide it.
    let events: Vec<String> = v
        .get("wants")
        .and_then(|w| w.get("events"))
        .and_then(|e| e.as_array())
        .map(|a| a.iter().map(as_str).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default();

    Some(Plugin {
        key: key.to_string(),
        name,
        summary,
        dir: dir.to_path_buf(),
        params,
        events,
        enabled: false,
        values: BTreeMap::new(),
    })
}

// ------------------------------------------------------------- a plugin's
// own translations
//
// **Why a plugin carries its own strings.** Polter's own text goes through
// gettext (`po/`, `src/os/i18n.zig`); a third party's cannot -- their
// sentences are not in our catalogues and never will be. So a plugin ships a
// sidecar beside its manifest:
//
//     plugins/archive/
//       plugin.json          the manifest, English, values are plain strings
//       i18n/zh-Hans.json    only the fields that need saying differently
//
// **This is the settings page only.** `plugin_list` answers an agent, and it
// answers with the manifest verbatim: an agent reading different tool
// descriptions on a Chinese machine and an English one stops being
// reproducible. A person gets their own language; an agent gets the same
// words everywhere. See `docs/poltergeist/boundary.md` §4 and the macOS
// original, `PluginLocale.swift`.

/// Whether a candidate is a language tag and nothing more.
///
/// It is about to be spelled into a file name. The preferred languages come
/// from Windows rather than from anywhere hostile, but the check costs
/// nothing and the alternative is a path built out of a string somebody else
/// chose.
fn is_tag(text: &str) -> bool {
    if text.is_empty() || text.len() > 35 {
        return false;
    }
    let mut subtags = 0;
    for subtag in text.split('-') {
        subtags += 1;
        if !(2..=8).contains(&subtag.len()) {
            return false;
        }
        if !subtag.chars().all(|c| c.is_ascii_alphanumeric()) {
            return false;
        }
    }
    subtags > 0
}

/// `zh_CN.UTF-8` -> `zh-CN`, `ZH-HANS` -> `zh-Hans`, `en_GB@euro` -> `en-GB`.
///
/// A POSIX-shaped locale is not what Windows hands out, but it is what an
/// environment variable hands out, and both end up here.
fn tidy_tag(raw: &str) -> String {
    let cut = raw
        .split(['.', '@'])
        .next()
        .unwrap_or("")
        .replace('_', "-");
    let mut out = String::new();
    for (i, part) in cut.split('-').filter(|p| !p.is_empty()).enumerate() {
        if i > 0 {
            out.push('-');
        }
        // Language lower, script Titlecase, region UPPER -- the shapes BCP-47
        // writes them in, so `zh_hans` and `ZH-HANS` land on one file name.
        let cased: String = match (i, part.len()) {
            (0, _) => part.to_ascii_lowercase(),
            (_, 4) => {
                let mut c = part.chars();
                match c.next() {
                    Some(f) => f.to_ascii_uppercase().to_string() + &c.as_str().to_ascii_lowercase(),
                    None => String::new(),
                }
            }
            _ => part.to_ascii_uppercase(),
        };
        out.push_str(&cased);
    }
    out
}

/// Ask Windows what a tag means, so `zh-CN` comes back as `zh-Hans-CN`.
///
/// **The script is filled in by the system, not by a table here.** A table of
/// regions would go stale and would only ever have Chinese in it; `zh-CN`
/// names no script, and what a Chinese reader cannot read is the other
/// script. `ResolveLocaleName` is the same answer macOS gets from `Locale`.
fn resolved(tag: &str) -> Option<String> {
    let mut wide: Vec<u16> = tag.encode_utf16().chain(Some(0)).collect();
    let mut out = [0u16; 85];
    let n = unsafe {
        windows::Win32::Globalization::ResolveLocaleName(
            windows::core::PCWSTR(wide.as_mut_ptr()),
            Some(&mut out),
        )
    };
    if n <= 1 {
        return None;
    }
    let s = String::from_utf16_lossy(&out[..(n - 1) as usize]);
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Which sidecar files to look for, in the order they should be tried.
///
/// Each preferred language is expanded into a ladder from most specific to
/// least:
///
/// ```text
/// zh-Hans-CN  ->  zh-Hans-CN, zh-Hans, zh-CN, zh
/// zh_CN.UTF-8 ->  zh-Hans-CN, zh-Hans, zh-CN, zh
/// zh          ->  zh-Hans, zh
/// en-GB       ->  en-Latn-GB, en-Latn, en-GB, en
/// ```
///
/// **Script beats region.** `zh-Hans` is tried before `zh-CN`, because what a
/// reader cannot read is the other script, while the region only changes
/// vocabulary. A translator who ships one `zh-Hans.json` must reach somebody
/// whose machine says `zh_CN`.
pub fn locale_candidates(preferred: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in preferred {
        let tidy = tidy_tag(raw);
        if tidy.is_empty() {
            continue;
        }
        // The system's own expansion first, so a tag with no script written
        // down gets one; then the tag as it was given, in case the system
        // knows nothing about it.
        let full = resolved(&tidy).map(|r| tidy_tag(&r)).unwrap_or_else(|| tidy.clone());

        let mut lang = String::new();
        let mut script: Option<String> = None;
        let mut region: Option<String> = None;
        for (i, part) in full.split('-').enumerate() {
            if i == 0 {
                lang = part.to_string();
            } else if part.len() == 4 && script.is_none() {
                script = Some(part.to_string());
            } else {
                region = Some(part.to_string());
            }
        }
        // A tag given as `zh-CN` also names a region even when the system
        // rewrote it; keep the one the person actually has.
        if region.is_none() {
            if let Some(given) = tidy.split('-').nth(1).filter(|p| p.len() != 4) {
                region = Some(given.to_string());
            }
        }
        if lang.is_empty() || !is_tag(&lang) {
            continue;
        }

        let mut ladder: Vec<String> = Vec::new();
        if let (Some(s), Some(r)) = (&script, &region) {
            ladder.push(format!("{lang}-{s}-{r}"));
        }
        if let Some(s) = &script {
            ladder.push(format!("{lang}-{s}"));
        }
        if let Some(r) = &region {
            ladder.push(format!("{lang}-{r}"));
        }
        ladder.push(lang);

        for candidate in ladder {
            if is_tag(&candidate) && !out.contains(&candidate) {
                out.push(candidate);
            }
        }
    }
    out
}

/// The languages this person prefers, most wanted first.
///
/// **The whole list, not just the default.** Somebody whose machine is
/// English with Chinese second still reads Chinese; taking only
/// `GetUserDefaultLocaleName` would never reach their second choice, and
/// macOS asks for `Locale.preferredLanguages` for the same reason.
pub fn preferred_languages() -> Vec<String> {
    use windows::Win32::Globalization::{GetUserPreferredUILanguages, MUI_LANGUAGE_NAME};
    let mut count: u32 = 0;
    let mut chars: u32 = 0;
    unsafe {
        if GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &mut count, None, &mut chars).is_err() {
            // process-wide: the person's language list, asked of Windows once
            plogf!("[plug] GetUserPreferredUILanguages sizing failed; plugin text stays English");
            return Vec::new();
        }
        let mut buf = vec![0u16; chars as usize];
        if GetUserPreferredUILanguages(
            MUI_LANGUAGE_NAME,
            &mut count,
            Some(windows::core::PWSTR(buf.as_mut_ptr())),
            &mut chars,
        )
        .is_err()
        {
            // process-wide: same call as above, the second half of it
            plogf!("[plug] GetUserPreferredUILanguages failed; plugin text stays English");
            return Vec::new();
        }
        // A double-NUL-terminated list of NUL-separated tags.
        buf.split(|&c| c == 0)
            .filter(|s| !s.is_empty())
            .map(String::from_utf16_lossy)
            .collect()
    }
}

/// What one sidecar file says, or nothing when there is no sidecar.
///
/// Every field is optional and every missing one means "the manifest already
/// says it well enough". A sidecar holding one line is a legitimate sidecar.
#[derive(Default, Debug, PartialEq)]
pub struct PluginText {
    pub name: Option<String>,
    pub summary: Option<String>,
    /// Parameter name -> (title, description).
    pub fields: BTreeMap<String, (Option<String>, Option<String>)>,
}

/// Read the first sidecar that exists, nearest language first.
///
/// **The first file that exists wins whole; there is no merging.** Laying a
/// `zh-Hans` over a `zh` would mean a key added to one file silently changes
/// what readers of the other see, and neither translator could see the
/// result. What a sidecar leaves out falls back to the manifest, which is
/// English -- one clearly-marked fallback instead of a chain.
///
/// **A file that is there but will not parse ends the search.** Falling
/// through to the next language would show half of somebody's typo as
/// somebody else's language.
pub fn load_text(dir: &Path, preferred: &[String]) -> PluginText {
    let base = dir.join("i18n");
    for candidate in locale_candidates(preferred) {
        let path = base.join(format!("{candidate}.json"));
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
            // process-wide: a plugin's own translation file on disk; the same
            // file whatever window the settings page is in front of
            plogf!("[plug] {}: will not parse; the manifest's own words are used", path.display());
            return PluginText::default();
        };
        let Some(obj) = v.as_object() else {
            return PluginText::default();
        };
        let mut out = PluginText {
            name: obj.get("name").map(as_str).filter(|s| !s.is_empty()),
            summary: obj.get("description").map(as_str).filter(|s| !s.is_empty()),
            fields: BTreeMap::new(),
        };
        if let Some(params) = obj.get("params").and_then(|p| p.as_object()) {
            for (name, spec) in params {
                let Some(spec) = spec.as_object() else { continue };
                out.fields.insert(
                    name.clone(),
                    (
                        spec.get("title").map(as_str).filter(|s| !s.is_empty()),
                        spec.get("description").map(as_str).filter(|s| !s.is_empty()),
                    ),
                );
            }
        }
        return out;
    }
    PluginText::default()
}

/// Lay a sidecar's sentences over the manifest's.
///
/// **Only the sentences.** A sidecar carries no `type`, no `required` and no
/// `enum`: it is the list of things to translate, not a second copy of the
/// schema.
fn apply_text(p: &mut Plugin, text: PluginText) {
    if let Some(name) = text.name {
        p.name = name;
    }
    if let Some(summary) = text.summary {
        p.summary = summary;
    }
    for param in p.params.iter_mut() {
        let Some((title, help)) = text.fields.get(&param.name) else { continue };
        if let Some(t) = title {
            param.title = t.clone();
        }
        if let Some(h) = help {
            param.help = h.clone();
        }
    }
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
        // process-wide: a plugin's settings file on disk, read once
        plogf!("[plug] {}: settings will not parse, treating as unconfigured", key);
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
        // process-wide: the process's config directory, or the absence of one
        plogf!("[plug] {}: no config directory; nothing saved", key);
        return false;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("json.tmp");
    let body = render_settings(enabled, values);

    if let Err(e) = std::fs::write(&tmp, body.as_bytes()) {
        // process-wide: writing a plugin's settings file
        plogf!("[plug] {}: write failed: {}", key, e);
        return false;
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        // process-wide: writing a plugin's settings file
        plogf!("[plug] {}: rename failed: {}", key, e);
        let _ = std::fs::remove_file(&tmp);
        return false;
    }
    // process-wide: writing a plugin's settings file
    plogf!("[plug] {} saved: enabled={} params={}", key, enabled, values.len());
    true
}

// ---------------------------------------------------------------- catalog

/// Every plugin this build can see, shipped first, then the user's own.
pub fn catalog() -> Vec<Plugin> {
    let mut out: Vec<Plugin> = Vec::new();
    // Asked once for the whole listing rather than once per plugin: it is a
    // property of the person, not of any plugin.
    let prefs = preferred_languages();

    if let Some(d) = user_dir() {
        // process-wide: the directory the catalog is read from: one per process
        plogf!("[plug] config dir {}", d.display());
    }
    // **Which of the three cases holds, every time the catalog is built.**
    // The page's empty state and this line have to agree, and both have to
    // distinguish "no directory" from "empty directory" -- the two looked
    // identical for as long as this host read the wrong directory entirely.
    // process-wide: which of the three catalog cases holds; a fact about a directory
    plogf!("[plug] {}", shipped_note());

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
                // The plugin's own translations, if it carries any for this
                // person's language. Read here, next to the manifest, so the
                // page never has to know that two files were involved.
                apply_text(&mut p, load_text(&dir, &prefs));
                let (enabled, values) = read_settings(key);
                p.enabled = enabled;
                p.values = values;
                out.push(p);
            }
        }
    }

    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    // process-wide: the plugin catalog, built from disk and shared by every window
    plogf!("[plug] catalog: {} plugins", out.len());
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
            // process-wide: a fixture file written for the cross-implementation check
            plogf!("[plug] fixture written to {}", path);
            true
        }
        Err(e) => {
            // process-wide: a fixture file written for the cross-implementation check
            plogf!("[plug] fixture write failed: {}", e);
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

// ------------------------------------------------- the sidecar's own tests
#[cfg(test)]
mod locale_tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("polter-i18n-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("i18n")).unwrap();
        dir
    }

    fn write(dir: &std::path::Path, tag: &str, body: &str) {
        std::fs::write(dir.join("i18n").join(format!("{tag}.json")), body).unwrap();
    }

    /// **A POSIX locale must reach a translator's one file.** `zh_CN.UTF-8`
    /// names no script, and the file a translator ships is `zh-Hans.json`.
    /// Also pins the order: script before region, because what a reader
    /// cannot read is the other script while the region only changes
    /// vocabulary.
    #[test]
    fn a_posix_chinese_locale_reaches_the_hans_sidecar() {
        let c = locale_candidates(&["zh_CN.UTF-8".to_string()]);
        let hans = c.iter().position(|x| x == "zh-Hans");
        let cn = c.iter().position(|x| x == "zh-CN");
        assert!(hans.is_some(), "no zh-Hans candidate in {c:?}");
        assert!(c.contains(&"zh".to_string()), "no bare zh in {c:?}");
        if let (Some(h), Some(r)) = (hans, cn) {
            assert!(h < r, "script must be tried before region: {c:?}");
        }
    }

    /// Casing and separators are normalised before anything becomes a file
    /// name, so `zh_hans` and `ZH-HANS` land on one file.
    #[test]
    fn spellings_of_one_tag_land_on_one_file() {
        assert_eq!(tidy_tag("zh_hans"), "zh-Hans");
        assert_eq!(tidy_tag("ZH-HANS"), "zh-Hans");
        assert_eq!(tidy_tag("en_GB@euro"), "en-GB");
        assert_eq!(tidy_tag("zh_CN.UTF-8"), "zh-CN");
    }

    /// A tag is about to be spelled into a path.
    #[test]
    fn only_a_language_tag_can_become_a_file_name() {
        assert!(is_tag("zh-Hans"));
        assert!(!is_tag("../etc/passwd"));
        assert!(!is_tag("zh/Hans"));
        assert!(!is_tag(""));
        assert!(!is_tag("z"));
    }

    /// **The first file that exists wins whole.** Laying `zh-Hans` over `zh`
    /// would mean a key added to one file silently changes what readers of
    /// the other see, and neither translator could see the result.
    #[test]
    fn the_first_sidecar_wins_and_is_not_merged_over_the_next() {
        let dir = scratch("nomerge");
        write(&dir, "zh", r#"{"name":"从 zh 来","description":"只有 zh 有这句"}"#);
        write(&dir, "zh-Hans", r#"{"name":"从 zh-Hans 来"}"#);

        let text = load_text(&dir, &["zh-Hans".to_string()]);
        assert_eq!(text.name.as_deref(), Some("从 zh-Hans 来"));
        // The description exists in `zh.json` and only there. A merge would
        // put it here; the rule says the manifest's own English is what fills
        // that gap instead.
        assert_eq!(text.summary, None, "zh.json must not be laid under zh-Hans.json");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A file that is there but will not parse ends the search.** Falling
    /// through to the next language would show half of somebody's typo as
    /// somebody else's language.
    #[test]
    fn a_broken_sidecar_falls_back_to_the_manifest_not_to_the_next_language() {
        let dir = scratch("broken");
        write(&dir, "zh-Hans", "{ this is not json ");
        write(&dir, "zh", r#"{"name":"从 zh 来"}"#);

        let text = load_text(&dir, &["zh-Hans".to_string()]);
        assert_eq!(text, PluginText::default(), "the search must stop, not continue to zh.json");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// No sidecar at all is the ordinary case: everything falls back to the
    /// manifest, and nothing is an error.
    #[test]
    fn no_sidecar_is_not_a_failure() {
        let dir = scratch("none");
        assert_eq!(load_text(&dir, &["zh-Hans".to_string()]), PluginText::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Only the sentences are laid over; the schema is not touched.
    #[test]
    fn a_sidecar_changes_words_and_nothing_else() {
        let mut p = Plugin {
            key: "k".into(),
            name: "Archive".into(),
            summary: "English summary".into(),
            dir: std::path::PathBuf::from("."),
            params: vec![Parameter {
                name: "dir".into(),
                title: "Where".into(),
                help: "English help".into(),
                required: true,
                secret: false,
                control: Control::Choice(vec!["a".into(), "b".into()]),
                default: Some("a".into()),
            }],
            events: vec!["chat".into()],
            enabled: false,
            values: BTreeMap::new(),
        };
        let mut fields = BTreeMap::new();
        fields.insert("dir".to_string(), (Some("存到哪".to_string()), None));
        apply_text(&mut p, PluginText {
            name: Some("存档".into()),
            summary: None,
            fields,
        });
        assert_eq!(p.name, "存档");
        assert_eq!(p.summary, "English summary", "a sidecar without the field leaves it alone");
        assert_eq!(p.params[0].title, "存到哪");
        assert_eq!(p.params[0].help, "English help");
        assert!(p.params[0].required, "required is the schema's, not the sidecar's");
        assert!(matches!(p.params[0].control, Control::Choice(_)));
    }
}
