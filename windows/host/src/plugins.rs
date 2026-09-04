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

/// How many options of a drop-down a person can reach with the mouse.
///
/// **Not a number anybody chose.** It is the documented default for
/// `CB_SETMINVISIBLE`, and it is what two measurements on the test machine
/// came back with independently: a 40-option list drew 602px at our 20px rows
/// and 572px at the system's 19px rows -- thirty rows both times.
///
/// Past it the list **scrolls and the keyboard arrives** (`LB_SETTOPINDEX(10)`
/// moves it, `End` selects item 39) but **grows no scroll bar**, so a mouse
/// cannot get there. Task 138 has the whole shape, including the one-line fix
/// that was tried and is dead.
const MOUSE_REACHABLE_OPTIONS: usize = 30;

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
    // **`description`, not `summary`.** The manifest has no `summary` field;
    // reading one gave every plugin an empty self-description, and the only
    // line left on the page was the one about what it subscribes to. The core
    // and the macOS app both read `description`
    // (`Plugin.swift:375  text.summary ?? root["description"]`).
    let summary = v.get("description").map(as_str).unwrap_or_default();

    // **`params.properties`, not `schema.properties`.**
    //
    // The comment that stood here said "`schema.properties` is the shape both
    // the core and the macOS app read", and **that sentence was false in both
    // halves**: `Plugin.zig:619` reads `obj.get("params")` and then
    // `"properties"`; `Plugin.swift:378` reads `root["params"]` and then
    // `schema["properties"]` -- the Swift *local* is called `schema`, which is
    // probably where the wrong word came from.
    //
    // A manifest has no `schema` key, so this read found nothing in every
    // plugin, every plugin declared no parameters, and the settings page drew
    // an on/off switch and nothing else. **That is the defect a person
    // reported as "mac shows each plugin's own settings and Windows only has a
    // switch"** -- and the prose above it said the code was right, which is
    // what made it take a round to find.
    let params_schema = v.get("params");
    let props = params_schema
        .and_then(|s| s.get("properties"))
        .and_then(|p| p.as_object());
    let required: Vec<String> = params_schema
        .and_then(|s| s.get("required"))
        .and_then(|r| r.as_array())
        .map(|a| a.iter().map(as_str).collect())
        .unwrap_or_default();

    let mut params = Vec::new();
    if let Some(props) = props {
        for (pname, spec) in props {
            let control = control_of(spec);
            // **Said at the moment the manifest is read, which is the moment
            // the person who can fix it is looking.**
            //
            // This file's rule at the top is that a schema this build cannot
            // turn into a control falls back rather than disappearing,
            // "because refusing to show a setting is how a plugin ends up
            // unconfigurable with no error anywhere". **A field the mouse
            // cannot reach the end of is the same family** -- the setting is
            // on the page and the person cannot get to it -- so it gets the
            // same treatment: it still works, and the fact is said out loud.
            //
            // **A notice, not a gate.** Nothing here refuses the manifest and
            // nothing stops the author; the options past the thirtieth are
            // still reachable by keyboard. Making it a gate would mean the
            // settings page saying it on screen, which is a larger change and
            // is deliberately not proposed here.
            if let Control::Choice(opts) = &control {
                if opts.len() > MOUSE_REACHABLE_OPTIONS {
                    // process-wide: a plugin's manifest on disk; the same file
                    // whatever window is in front
                    plogf!(
                        "[plug] {}: parameter {} declares {} options; only the first {} \
                         can be reached with the mouse (the list scrolls and the keyboard \
                         reaches the rest -- see task 138)",
                        key,
                        pname,
                        opts.len(),
                        MOUSE_REACHABLE_OPTIONS
                    );
                }
            }
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
                control: control,
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

/// The nearest name Windows *supports* for this tag. **It does not add a
/// script, and it takes one away.**
///
/// This function used to be documented as filling the script in -- "so
/// `zh-CN` comes back as `zh-Hans-CN`" -- and that sentence was wrong from
/// the day it was written. It was carried across from the macOS side, where
/// `Locale(identifier:).language.script` really does maximise a tag, and the
/// reasoning came with it while the API semantics did not:
///
///   * ICU's maximise answers **"what is the fullest form of this tag"**;
///   * `ResolveLocaleName` answers **"which name that this system supports
///     is closest to it"**.
///
/// On `zh` the two run in opposite directions. Measured on Win11 26200:
///
/// ```text
/// ResolveLocaleName("zh-CN")      -> "zh-CN"     unchanged
/// ResolveLocaleName("zh-Hans-CN") -> "zh-CN"     the script is REMOVED
/// LOCALE_SNAME     ("zh-Hans-CN") -> "zh-CN"     a second path, same answer
/// ```
///
/// And the mechanism was read directly rather than inferred from those
/// samples, by listing the supported set with `EnumSystemLocalesEx`:
/// **`zh-CN` is in it and `zh-Hans-CN` is not.** A name that is in the set is
/// a fixed point, and a fixed point cannot grow a script. That is why this is
/// not a quirk of one machine or one build -- it holds wherever `zh-CN` is
/// the supported spelling, which it has been since Vista.
///
/// So this call is kept for what it is actually good at -- normalising to a
/// name the system knows -- and the script is asked for separately, in
/// `scripts_of`.
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

/// The scripts Windows says this locale is written in, in the order it gives.
///
/// `LOCALE_SSCRIPTS` is the half `ResolveLocaleName` cannot do, and it means
/// the mapping does not have to live in a table here -- which was the good
/// half of the original reasoning and is still good. Measured on Win11 26200:
///
/// ```text
/// zh-CN  -> "Hani;Hans;"      en-US -> "Latn;"
/// sr-RS  -> "Latn;"           de-DE -> "Latn;"
/// ```
///
/// # Do not take the first one
///
/// **`zh-CN` answers `Hani;Hans;` and the one we want is second.** `Hani` is
/// Han script in general; `Hans` is the simplified writing a translator
/// actually ships a `zh-Hans.json` for, and no translator ships a
/// `zh-Hani.json`.
///
/// This is worth stating loudly because of its shape: **taking the first
/// entry is correct for `en-US`, `de-DE` and `sr-RS`, and wrong for `zh-CN`.**
/// Three of the four samples agree with the wrong rule, and the one that
/// disagrees is the only one this whole file exists for. It is the same shape
/// as the comment above it -- a rule that holds everywhere it was looked at
/// and fails where it matters.
///
/// So the caller does not choose at all. **Every script goes into the ladder
/// and the translator's file name decides**, which is the rule this file
/// already runs on ("the first file that exists wins whole"). The order here
/// only ever settles a plugin that ships both `zh-Hani.json` and
/// `zh-Hans.json`, and serving the generic one to a `zh-CN` reader is not a
/// wrong answer, so nothing rests on it.
///
/// # What this field is not
///
/// `sr-RS` answers `Latn;` although Serbian is written in both Latin and
/// Cyrillic. **It is the scripts of this locale, not of this language** -- a
/// narrower question than the name suggests, and the right one here.
fn scripts_of(tag: &str) -> Vec<String> {
    let wide: Vec<u16> = tag.encode_utf16().chain(Some(0)).collect();
    let mut out = [0u16; 128];
    let n = unsafe {
        windows::Win32::Globalization::GetLocaleInfoEx(
            windows::core::PCWSTR(wide.as_ptr()),
            windows::Win32::Globalization::LOCALE_SSCRIPTS,
            Some(&mut out),
        )
    };
    if n <= 1 {
        return Vec::new();
    }
    String::from_utf16_lossy(&out[..(n - 1) as usize])
        .split(';')
        .filter(|s| s.len() == 4 && s.chars().all(|c| c.is_ascii_alphabetic()))
        .map(|s| {
            let mut c = s.chars();
            let head = c.next().unwrap().to_ascii_uppercase();
            format!("{head}{}", c.as_str().to_ascii_lowercase())
        })
        .collect()
}

/// Which sidecar files to look for, in the order they should be tried.
///
/// Each preferred language is expanded into a ladder from most specific to
/// least:
///
/// ```text
/// zh-Hans-CN  ->  zh-Hans-CN, zh-Hans, zh-Hani-CN, zh-Hani, zh-CN, zh
/// zh_CN.UTF-8 ->  zh-Hani-CN, zh-Hani, zh-Hans-CN, zh-Hans, zh-CN, zh
/// zh-Hans     ->  zh-Hans, zh-Hani, zh
/// en-GB       ->  en-Latn-GB, en-Latn, en-GB, en
/// ```
///
/// **Script beats region.** `zh-Hans` is tried before `zh-CN`, because what a
/// reader cannot read is the other script, while the region only changes
/// vocabulary. A translator who ships one `zh-Hans.json` must reach somebody
/// whose machine says `zh_CN`.
///
/// **A locale can be written in more than one script and all of them go in.**
/// Windows answers `Hani;Hans;` for `zh-CN`, and choosing between those two
/// here would mean choosing `Hani`, which no translator ships a file for.
/// Nothing chooses: the ladder carries both and the file that exists wins.
/// `scripts_of` has the reading and why the obvious rule is wrong.
pub fn locale_candidates(preferred: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in preferred {
        let tidy = tidy_tag(raw);
        if tidy.is_empty() {
            continue;
        }
        // Normalise to a name the system knows. **This does not add a script
        // and may remove one** -- see `resolved`; the script is asked for
        // separately below.
        let full = resolved(&tidy).map(|r| tidy_tag(&r)).unwrap_or_else(|| tidy.clone());

        let mut lang = String::new();
        let mut written: Option<String> = None;
        let mut region: Option<String> = None;
        for (i, part) in full.split('-').enumerate() {
            if i == 0 {
                lang = part.to_string();
            } else if part.len() == 4 && written.is_none() {
                written = Some(part.to_string());
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
        // And a script the person wrote down that the system then normalised
        // away: `zh-Hans-CN` comes back as `zh-CN`. **Somebody who spelled
        // the script out must not lose it to a round trip through Windows.**
        if written.is_none() {
            if let Some(given) = tidy.split('-').nth(1).filter(|p| p.len() == 4) {
                written = Some(given.to_string());
            }
        }
        if lang.is_empty() || !is_tag(&lang) {
            continue;
        }

        // The script the tag itself names comes first, because it is the one
        // statement of intent we have; then whatever Windows says this locale
        // is written in. **Nothing here picks one of them** -- `zh-CN` answers
        // `Hani;Hans;` and picking would be picking `Hani`. See `scripts_of`.
        let mut scripts: Vec<String> = Vec::new();
        if let Some(w) = written {
            scripts.push(w);
        }
        for s in scripts_of(&full) {
            if !scripts.contains(&s) {
                scripts.push(s);
            }
        }

        let mut ladder: Vec<String> = Vec::new();
        for s in &scripts {
            if let Some(r) = &region {
                ladder.push(format!("{lang}-{s}-{r}"));
            }
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

fn read_settings(key: &str, dir: &Path) -> (bool, BTreeMap<String, String>) {
    // The user's own file first, then whatever the release ships inside the
    // plugin's own directory.
    let mut paths: Vec<PathBuf> = Vec::new();
    if let Some(p) = settings_path(key) {
        paths.push(p);
    }
    paths.push(dir.join("settings.json"));
    read_first(key, &paths)
}

/// The first of `paths` that **has a file**, nearest first.
///
/// **Chosen by which file exists, not by merging their contents**, and the
/// core says why (`Plugin.Settings.readFirst`): a settings value cannot tell
/// "switched off" from "never configured" -- both are `enabled = false` -- so
/// folding the two together would let an upgrade switch a plugin back on for
/// somebody who had deliberately switched it off.
///
/// **A file that is there wins even when it says off, and even when it will
/// not parse.** Falling through to the shipped default because the user's
/// file has a typo in it is the one outcome that turns something on behind
/// their back.
///
/// Without this, a plugin a release ships configured -- `claude-code` arrives
/// as `{"enabled":true,"params":{"scope":"user","skills":"yes"}}` -- showed
/// in this page as **off with empty fields** on a machine that had never
/// configured it, while the core was running it from those very values. The
/// page was the convincing one and it was the wrong one.
fn read_first(key: &str, paths: &[PathBuf]) -> (bool, BTreeMap<String, String>) {
    for path in paths {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        return parse_settings(key, &text);
    }
    (false, BTreeMap::new())
}

/// One plugin's settings file, as the page reads it.
///
/// **Values that are not strings are dropped, and that is not this file being
/// fussy -- it is agreeing with the reader that decides what actually runs.**
/// `Plugin.Settings.read` in the core keeps only string values (`plugins.md`:
/// 「只认得 `enabled` 和 `params` 里的**字符串**值；别的键、非字符串的值，读的
/// 时候被丢掉」). A page that read `{"skills": true}` as a ticked box would
/// show a value the core has already thrown away -- the page and the terminal
/// would disagree about what is configured, and the page would be the
/// convincing one.
fn parse_settings(key: &str, text: &str) -> (bool, BTreeMap<String, String>) {
    let mut values = BTreeMap::new();
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else {
        // process-wide: a plugin's settings file on disk, read once
        plogf!("[plug] {}: settings will not parse, treating as unconfigured", key);
        return (false, values);
    };
    let Some(obj) = v.as_object() else {
        return (false, values);
    };

    let mut take = |k: &String, val: &serde_json::Value| match val {
        serde_json::Value::String(sv) => {
            values.insert(k.clone(), sv.clone());
        }
        other => {
            // process-wide: a plugin's settings file on disk, read once
            plogf!(
                "[plug] {}: params.{} is {}, not a string; the core drops it and so does this page",
                key,
                k,
                match other {
                    serde_json::Value::Bool(_) => "a JSON boolean",
                    serde_json::Value::Number(_) => "a number",
                    serde_json::Value::Null => "null",
                    _ => "not a string",
                }
            );
        }
    };

    // The older shape was the parameters alone, with "is it on" living in the
    // main config. `Plugin.zig` reads such a file as enabled, and reading it
    // any other way here would show "off" for a plugin the core is happily
    // running.
    let modern = obj.contains_key("params") || obj.contains_key("enabled");
    if !modern {
        for (k, val) in obj {
            take(k, val);
        }
        return (true, values);
    }

    let enabled = obj.get("enabled").and_then(|b| b.as_bool()).unwrap_or(false);
    if let Some(p) = obj.get("params").and_then(|p| p.as_object()) {
        for (k, val) in p {
            take(k, val);
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
                let (enabled, values) = read_settings(key, &dir);
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

    /// What Windows answered, put into a failure message.
    ///
    /// **The tests below are integration tests wearing a unit test's
    /// clothes.** `locale_candidates` asks Windows what a tag means, so the
    /// candidate list belongs partly to the machine running the test and not
    /// only to this file.
    ///
    /// Without the reading, a red says the candidate list was wrong and
    /// nothing else -- and **"the product is wrong" and "this machine is
    /// unusual" print exactly the same failure.** Those two need different
    /// people to look at them, and the second one cannot even be *proposed*
    /// by somebody holding only the old message.
    ///
    /// The note in brackets is mechanical -- did the answer differ from the
    /// question -- and deliberately not an interpretation. Reading
    /// `"zh-Hans" -> "zh-CN"` and deciding what it means is the reader's job;
    /// a helper that decided it would be one more thing that can be wrong
    /// while looking authoritative.
    fn what_windows_said(tags: &[&str]) -> String {
        let mut parts = Vec::new();
        for tag in tags {
            parts.push(match resolved(tag) {
                Some(r) if r.eq_ignore_ascii_case(tag) => format!("{tag:?} -> {r:?} (unchanged)"),
                Some(r) => format!("{tag:?} -> {r:?} (rewritten)"),
                None => format!("{tag:?} -> no answer"),
            });
        }
        format!("ResolveLocaleName on this machine: {}", parts.join(", "))
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
        // `zh_CN.UTF-8` is tidied to `zh-CN` before Windows is asked, so
        // `zh-CN` is the reading that decides this test. The other two are
        // there because **whether this API ever puts a script in is the
        // question**, and one tag cannot answer it.
        let said = what_windows_said(&["zh-CN", "zh-Hans", "zh-Hans-CN"]);
        assert!(hans.is_some(), "no zh-Hans candidate in {c:?}\n  {said}");
        assert!(
            c.contains(&"zh".to_string()),
            "no bare zh in {c:?}\n  {said}"
        );
        if let (Some(h), Some(r)) = (hans, cn) {
            assert!(h < r, "script must be tried before region: {c:?}\n  {said}");
        }
    }

    /// **The defect this file was reopened for.** A machine that says `zh-CN`
    /// must reach the one file a translator shipped, `zh-Hans.json`.
    ///
    /// Windows will not spell the script into the tag -- `zh-CN` is a name it
    /// supports, so it comes back unchanged -- and it answers `Hani;Hans;`
    /// when asked what scripts the locale uses. **A version of this that took
    /// the first script would look for `zh-Hani.json` and find nothing**,
    /// which is why this test writes only `zh-Hans.json` and nothing else:
    /// the generic script must not be able to satisfy it.
    #[test]
    fn a_zh_cn_machine_reaches_the_hans_file_and_not_a_hani_one() {
        let dir = scratch("hans-from-cn");
        write(&dir, "zh-Hans", r#"{"name":"简体"}"#);

        let text = load_text(&dir, &["zh-CN".to_string()]);
        assert_eq!(
            text.name.as_deref(),
            Some("简体"),
            "a zh-CN machine did not reach zh-Hans.json\n  {}\n  scripts: {:?}\n  candidates: {:?}",
            what_windows_said(&["zh-CN"]),
            scripts_of("zh-CN"),
            locale_candidates(&["zh-CN".to_string()])
        );
        let _ = std::fs::remove_dir_all(&dir);
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
        let said = what_windows_said(&["zh-Hans"]);
        let ladder = locale_candidates(&["zh-Hans".to_string()]);
        assert_eq!(
            text.name.as_deref(),
            Some("从 zh-Hans 来"),
            "zh-Hans.json was not the file that won\n  {said}\n  candidates: {ladder:?}"
        );
        // The description exists in `zh.json` and only there. A merge would
        // put it here; the rule says the manifest's own English is what fills
        // that gap instead.
        assert_eq!(
            text.summary, None,
            "zh.json must not be laid under zh-Hans.json\n  {said}\n  candidates: {ladder:?}"
        );
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
        assert_eq!(
            text,
            PluginText::default(),
            "the search must stop, not continue to zh.json\n  {}\n  candidates: {:?}",
            what_windows_said(&["zh-Hans"]),
            locale_candidates(&["zh-Hans".to_string()])
        );
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

// --------------------------------------- the three control shapes, and the
// string round-trip the boolean one implies
#[cfg(test)]
mod control_tests {
    use super::*;

    /// The fixture that exists because no shipped plugin declares a boolean.
    /// Kept as text here rather than read from `windows/test-fixtures/`: this
    /// test is about the parse and the round-trip, and a test that needs a
    /// file to be somewhere is a test that stops running when somebody moves
    /// the file.
    const FIXTURE: &str = r#"{
      "key": "w1-controls",
      "name": "Control shapes",
      "summary": "one of each",
      "exec": "controls.ps1",
      "wants": { "events": ["provision"] },
      "params": {
        "type": "object",
        "required": ["a_text"],
        "properties": {
          "a_text":   { "type": "string",  "title": "A text field" },
          "b_choice": { "type": "string",  "title": "A closed set", "enum": ["first", "second"] },
          "c_flag":   { "type": "boolean", "title": "A boolean" }
        }
      }
    }"#;

    fn fixture() -> Plugin {
        parse_manifest("w1-controls", std::path::Path::new("."), FIXTURE).expect("fixture parses")
    }

    /// **One of each shape, from one manifest.** The page draws three
    /// different native controls off this, and until this fixture existed the
    /// checkbox branch had never run: every shipped plugin spells its
    /// yes/no as `enum: ["yes","no"]`, which is a dropdown.
    #[test]
    fn a_manifest_can_ask_for_all_three_shapes() {
        let p = fixture();
        let by = |n: &str| p.params.iter().find(|x| x.name == n).expect(n).control.clone();
        assert!(matches!(by("a_text"), Control::Text));
        assert!(matches!(by("b_choice"), Control::Choice(ref c) if c.len() == 2));
        assert!(matches!(by("c_flag"), Control::Flag));
        assert!(p.params.iter().find(|x| x.name == "a_text").unwrap().required);
    }

    /// **A closed set beats the declared type.** A `string` with an `enum` is
    /// a dropdown; if this ever flipped, the page would offer a text box for
    /// a field that takes three values -- the defect the docs cite Tinia for.
    #[test]
    fn an_enum_wins_over_the_type() {
        let spec: serde_json::Value =
            serde_json::from_str(r#"{"type":"string","enum":["a","b"]}"#).unwrap();
        assert!(matches!(control_of(&spec), Control::Choice(_)));
        let boolean: serde_json::Value = serde_json::from_str(r#"{"type":"boolean"}"#).unwrap();
        assert!(matches!(control_of(&boolean), Control::Flag));
        let plain: serde_json::Value = serde_json::from_str(r#"{"type":"string"}"#).unwrap();
        assert!(matches!(control_of(&plain), Control::Text));
    }

    /// **The round trip the checkbox implies, and the only place it can be
    /// checked.** The core never reads `type`: every value it stores and
    /// hands to a plugin is a string. So a ticked box has to be spelled as
    /// one, and the spelling is this host's own -- nothing in the core or in
    /// any shipped plugin says which string a boolean is.
    #[test]
    fn a_ticked_box_is_written_as_the_string_true_and_read_back_as_one() {
        let mut values = BTreeMap::new();
        values.insert("c_flag".to_string(), "true".to_string());
        let text = render_settings(true, &values);
        assert!(text.contains("\"c_flag\": \"true\""), "not a JSON string: {text}");
        assert!(!text.contains("\"c_flag\": true"), "written as a JSON boolean: {text}");

        let (enabled, back) = parse_settings("w1-controls", &text);
        assert!(enabled);
        assert_eq!(back.get("c_flag").map(String::as_str), Some("true"));

        // And unticked is the other string, not a missing key: a page that
        // dropped the value would leave the plugin reading whatever it
        // shipped with.
        values.insert("c_flag".to_string(), "false".to_string());
        let text = render_settings(true, &values);
        let (_, back) = parse_settings("w1-controls", &text);
        assert_eq!(back.get("c_flag").map(String::as_str), Some("false"));
    }

    /// **The floor for the test above.** A JSON boolean in the file is not a
    /// value: the core drops it (`plugins.md`), so the page must drop it too.
    /// If this came back as `"true"`, the page would show a ticked box for a
    /// setting the terminal does not have.
    #[test]
    fn a_json_boolean_in_the_file_is_not_read_as_a_value() {
        let (enabled, values) =
            parse_settings("w1-controls", r#"{"enabled": true, "params": {"c_flag": true}}"#);
        assert!(enabled, "`enabled` itself is a real JSON boolean and is read");
        assert_eq!(values.get("c_flag"), None, "a non-string param value must be dropped");

        // A number is the same case, and so is null.
        let (_, values) =
            parse_settings("k", r#"{"params": {"a": 1, "b": null, "c": "kept"}}"#);
        assert_eq!(values.get("a"), None);
        assert_eq!(values.get("b"), None);
        assert_eq!(values.get("c").map(String::as_str), Some("kept"));
    }
}

// ------------------------------- the shipped default, and why it is a search
// over files rather than a merge
#[cfg(test)]
mod fallback_tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("polter-fallback-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    const SHIPPED: &str = r#"{"enabled": true, "params": {"scope": "user", "skills": "yes"}}"#;

    /// **A machine that has never configured the plugin still sees what the
    /// release configured.** This is the case that was wrong: `claude-code`
    /// ships enabled with two values, and the page showed off with empty
    /// fields while the core ran it from those values.
    #[test]
    fn with_no_file_of_their_own_the_shipped_one_is_read() {
        let dir = scratch("shipped");
        let user = dir.join("user-does-not-exist.json");
        let shipped = dir.join("settings.json");
        std::fs::write(&shipped, SHIPPED).unwrap();

        let (enabled, values) = read_first("claude-code", &[user, shipped]);
        assert!(enabled);
        assert_eq!(values.get("scope").map(String::as_str), Some("user"));
        assert_eq!(values.get("skills").map(String::as_str), Some("yes"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The floor for the test above.** The fallback happens because no file
    /// of the user's exists -- not unconditionally. A user's file saying
    /// "off" must win over a shipped file saying "on", or an upgrade switches
    /// something back on for somebody who deliberately switched it off.
    #[test]
    fn a_file_of_their_own_wins_even_when_it_says_off() {
        let dir = scratch("theirs-off");
        let user = dir.join("user.json");
        let shipped = dir.join("settings.json");
        std::fs::write(&user, r#"{"enabled": false, "params": {}}"#).unwrap();
        std::fs::write(&shipped, SHIPPED).unwrap();

        let (enabled, values) = read_first("claude-code", &[user, shipped]);
        assert!(!enabled, "the shipped default must not switch it back on");
        assert!(values.is_empty(), "nor supply its values");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Existence decides, and there is no merging.** A user's file that
    /// says only "on" does not get the shipped parameters laid under it: with
    /// merging, "switched off" and "never configured" become the same thing
    /// on the way through, which is exactly what a settings value cannot tell
    /// apart.
    #[test]
    fn the_two_files_are_never_merged() {
        let dir = scratch("nomerge");
        let user = dir.join("user.json");
        let shipped = dir.join("settings.json");
        std::fs::write(&user, r#"{"enabled": true, "params": {}}"#).unwrap();
        std::fs::write(&shipped, SHIPPED).unwrap();

        let (enabled, values) = read_first("claude-code", &[user, shipped]);
        assert!(enabled);
        assert!(
            values.is_empty(),
            "the shipped params must not appear under the user's file: {values:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A file that is there but will not parse still wins**, and reads as
    /// off. Falling through to the shipped default because the user's file
    /// has a typo in it is the one outcome that turns something on behind
    /// their back.
    #[test]
    fn a_broken_file_of_their_own_does_not_fall_through_to_the_shipped_one() {
        let dir = scratch("broken");
        let user = dir.join("user.json");
        let shipped = dir.join("settings.json");
        std::fs::write(&user, "{ not json").unwrap();
        std::fs::write(&shipped, SHIPPED).unwrap();

        let (enabled, values) = read_first("claude-code", &[user, shipped]);
        assert!(!enabled, "a typo must not switch the plugin on");
        assert!(values.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Neither file is the ordinary case for a plugin nobody ships settings
    /// for: off, no values, and not an error.
    #[test]
    fn neither_file_is_off_and_empty() {
        let dir = scratch("none");
        let (enabled, values) =
            read_first("k", &[dir.join("user.json"), dir.join("settings.json")]);
        assert!(!enabled);
        assert!(values.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}

// -------------------------------- the shipped manifests, as an outside ruler
#[cfg(test)]
mod shipped_manifest_tests {
    use super::*;

    // **Baked in from the real plugin directory, not written here.** A fixture
    // of my own would carry my own mistake: this parser read
    // `schema.properties` for weeks, and a fixture written against it would
    // have had a `schema` key and passed. These four files are somebody
    // else's, they are what ships, and they are the only thing in reach that
    // can say the reader is looking in the wrong place.
    const ARCHIVE: &str = include_str!("../../../plugins/archive/plugin.json");
    const CLAUDE_CODE: &str = include_str!("../../../plugins/claude-code/plugin.json");
    const CODEX: &str = include_str!("../../../plugins/codex/plugin.json");
    const GEMINI: &str = include_str!("../../../plugins/gemini/plugin.json");
    const KIMI: &str = include_str!("../../../plugins/kimi/plugin.json");

    fn parse(key: &str, text: &str) -> Plugin {
        parse_manifest(key, std::path::Path::new("."), text).expect("a shipped manifest parses")
    }

    /// **The count is the whole test.** Every one of these was read as zero,
    /// and zero parameters is exactly what "the page has only an on/off
    /// switch" looks like from a chair.
    ///
    /// **All five are compared in one assertion, on purpose.** Written as five
    /// `assert_eq!`s it stopped at the first mismatch, and when `rules` was
    /// added to three manifests the failure named only `claude-code`. Fixing
    /// that one moved the red to `codex`, and then to `gemini`: three rounds
    /// to learn what one run could have said. **A test that stops at the
    /// first disagreement reports the first cause, and a reader has no way to
    /// tell that from the only cause.**
    ///
    /// The expectation carries the names rather than a bare number, so a
    /// failure says *which* parameter appeared or went missing. A count alone
    /// answers "how many" to a question that is always really "which".
    #[test]
    fn the_shipped_manifests_declare_the_parameters_they_declare() {
        let names = |k: &str, text: &str| {
            let mut v: Vec<String> = parse(k, text).params.iter().map(|p| p.name.clone()).collect();
            v.sort();
            (k.to_string(), v)
        };
        let found = vec![
            names("archive", ARCHIVE),
            names("claude-code", CLAUDE_CODE),
            names("codex", CODEX),
            names("gemini", GEMINI),
            // And one that really does declare none, so a parser that answered
            // "two" to everything would not pass either.
            names("kimi", KIMI),
        ];
        let expected: Vec<(String, Vec<String>)> = [
            ("archive", &["dir", "sign_key"][..]),
            ("claude-code", &["rules", "scope", "skills"][..]),
            ("codex", &["rules", "skills"][..]),
            ("gemini", &["rules", "skills"][..]),
            ("kimi", &[][..]),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.iter().map(|s| s.to_string()).collect()))
        .collect();
        assert_eq!(found, expected, "a shipped manifest's parameters changed");
    }

    /// The shapes, from the same outside ruler: a closed set is a dropdown and
    /// a plain string is a text box.
    #[test]
    fn a_shipped_enum_becomes_a_dropdown() {
        let p = parse("claude-code", CLAUDE_CODE);
        let scope = p.params.iter().find(|x| x.name == "scope").expect("scope");
        assert!(matches!(scope.control, Control::Choice(ref c) if c.len() == 2), "{:?}", scope.control);
        let a = parse("archive", ARCHIVE);
        let dir = a.params.iter().find(|x| x.name == "dir").expect("dir");
        assert!(matches!(dir.control, Control::Text));
    }

    /// **The self-description is `description`.** Reading a field the
    /// manifests do not have left every plugin with an empty one, and the
    /// page showed only the line about what it subscribes to.
    #[test]
    fn a_shipped_manifest_has_a_self_description() {
        let a = parse("archive", ARCHIVE);
        assert!(!a.summary.is_empty(), "archive has no summary");
        assert!(a.summary.starts_with("Keeps an extra copy"), "{}", a.summary);
        assert!(!parse("kimi", KIMI).summary.is_empty(), "kimi has no summary");
    }

    /// And what it subscribes to, from the same files.
    #[test]
    fn a_shipped_manifest_says_what_it_wants() {
        assert_eq!(parse("archive", ARCHIVE).events, vec!["chat".to_string()]);
        assert_eq!(parse("kimi", KIMI).events, vec!["provision".to_string()]);
    }
}
