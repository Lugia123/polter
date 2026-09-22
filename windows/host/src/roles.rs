//! The role library's values and the five calls that read and write it.
//!
//! A port of `macos/Sources/Features/Roles/RoleModels.swift` (the values)
//! and `RoleLibrary.swift` (the calls). The window is `roles_ui.rs`; this
//! file draws nothing.
//!
//! **Everything is asked of the core** -- the file, its validation and the
//! CLI inventory all live there -- so this module reads nothing from disk
//! and runs nothing. Two readers of `personas.json` would be two sets of
//! rules about what a valid role is.
//!
//! ⚠️ **The calls run on the app thread**, which on this host is the UI
//! thread (`include/ghostty.h`: "All of these run on the app thread"). None
//! of them starts a process there: `clis(true)` starts the adapters' read on
//! the core's own thread and answers `refreshing` until it lands.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use crate::ffi::Surface;
use crate::i18n::tr;

/// The key of the supervisor role Polter ships (`persona.supervisor_key`).
pub const SUPERVISOR_KEY: &str = "polter-supervisor";

// ------------------------------------------------------------- the values

/// Which of a CLI's own skills or MCP servers a role keeps: a default, and
/// the ids ticked the other way.
///
/// The same shape as `persona.Selection` in the core, for the reason given
/// there: a plain list of what is on cannot tell "unticked" from "installed
/// after the role was written".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub keep_by_default: bool,
    pub except: Vec<String>,
}

impl Default for Selection {
    fn default() -> Self {
        Self { keep_by_default: true, except: Vec::new() }
    }
}

impl Selection {
    pub fn is_on(&self, id: &str) -> bool {
        if self.except.iter().any(|e| e == id) {
            !self.keep_by_default
        } else {
            self.keep_by_default
        }
    }

    /// Put `id` in the state asked for, by adding or removing it from
    /// `except` -- whichever is the difference from the default.
    pub fn set(&mut self, id: &str, on: bool) {
        let wants_exception = on != self.keep_by_default;
        let is_exception = self.except.iter().any(|e| e == id);
        if wants_exception && !is_exception {
            self.except.push(id.to_string());
        }
        if !wants_exception && is_exception {
            self.except.retain(|e| e != id);
        }
    }

    /// Change the default while leaving every listed item as it is, so that
    /// flipping "items installed later" never flips what the user can see.
    pub fn set_default(&mut self, keep: bool, visible: &[String]) {
        if keep == self.keep_by_default {
            return;
        }
        let states: Vec<(&String, bool)> = visible.iter().map(|id| (id, self.is_on(id))).collect();
        self.keep_by_default = keep;
        self.except.retain(|e| !visible.contains(e));
        for (id, on) in states {
            if on != keep && !self.except.contains(id) {
                self.except.push(id.clone());
            }
        }
    }

    fn from_json(v: Option<&Value>) -> Self {
        let Some(obj) = v.and_then(Value::as_object) else { return Self::default() };
        Self {
            keep_by_default: obj.get("default").and_then(Value::as_bool).unwrap_or(true),
            except: strings(obj.get("except")),
        }
    }

    fn to_json(&self) -> Value {
        serde_json::json!({ "default": self.keep_by_default, "except": self.except })
    }
}

/// A role's choices for one agent CLI.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CliChoice {
    pub cli: String,
    pub skills: Selection,
    pub mcp: Selection,
    pub model: String,
    pub args: Vec<String>,
}

impl CliChoice {
    pub fn new(cli: &str) -> Self {
        Self {
            cli: cli.to_string(),
            skills: Selection::default(),
            mcp: Selection::default(),
            model: String::new(),
            args: Vec::new(),
        }
    }

    fn from_json(cli: &str, v: Option<&Value>) -> Self {
        let empty = Map::new();
        let obj = v.and_then(Value::as_object).unwrap_or(&empty);
        Self {
            cli: cli.to_string(),
            skills: Selection::from_json(obj.get("skills")),
            mcp: Selection::from_json(obj.get("mcp")),
            model: obj.get("model").and_then(Value::as_str).unwrap_or("").to_string(),
            args: strings(obj.get("args")),
        }
    }

    fn to_json(&self) -> Value {
        let mut out = Map::new();
        out.insert("skills".into(), self.skills.to_json());
        out.insert("mcp".into(), self.mcp.to_json());
        let model = self.model.trim();
        if !model.is_empty() {
            out.insert("model".into(), Value::from(model));
        }
        if !self.args.is_empty() {
            out.insert("args".into(), Value::from(self.args.clone()));
        }
        Value::Object(out)
    }
}

/// Where clicking a role starts it (`persona.Polter.Open`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Open {
    /// Polter decides from what is running there.
    #[default]
    Auto,
    /// A new tab, whatever the terminal clicked in is doing.
    Tab,
}

impl Open {
    pub fn as_str(self) -> &'static str {
        match self {
            Open::Auto => "auto",
            Open::Tab => "tab",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(Open::Auto),
            "tab" => Some(Open::Tab),
            _ => None,
        }
    }
}

/// What Polter does with the terminal a role is started in -- the core's
/// `persona.Polter`. Applied once, when the role starts an agent CLI.
///
/// `supervisor`, `may_authorise` and `shielded` grant the terminal
/// something, so only the user sets them: the core refuses a supervisor's
/// `role_put` that changes them, and this window is the user's.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PolterSettings {
    pub supervisor: bool,
    pub may_authorise: bool,
    pub shielded: bool,
    pub watch: bool,
    pub open: Open,
    /// None keeps the configured default. The core refuses anything under
    /// 1000 (`polterOf`), and says so as `BadPersona` on save.
    pub quiet_ms: Option<u64>,
}

impl PolterSettings {
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }

    fn from_json(v: Option<&Value>) -> Self {
        let Some(obj) = v.and_then(Value::as_object) else { return Self::default() };
        let flag = |k: &str| obj.get(k).and_then(Value::as_bool).unwrap_or(false);
        Self {
            supervisor: flag("supervisor"),
            may_authorise: flag("may_authorise"),
            shielded: flag("shielded"),
            watch: flag("watch"),
            open: obj.get("open").and_then(Value::as_str).and_then(Open::parse).unwrap_or_default(),
            quiet_ms: obj.get("quiet_ms").and_then(Value::as_u64),
        }
    }

    fn to_json(&self) -> Value {
        let mut out = Map::new();
        out.insert("supervisor".into(), Value::from(self.supervisor));
        out.insert("may_authorise".into(), Value::from(self.may_authorise));
        out.insert("shielded".into(), Value::from(self.shielded));
        out.insert("watch".into(), Value::from(self.watch));
        out.insert("open".into(), Value::from(self.open.as_str()));
        if let Some(ms) = self.quiet_ms {
            out.insert("quiet_ms".into(), Value::from(ms));
        }
        Value::Object(out)
    }
}

/// One role from the library, in the shape the window edits.
///
/// **Fields the window does not edit are carried through untouched.** A
/// hand-written role may have `tools`, `hint`, `prompt` and the Polter-side
/// `skills`/`mcp` -- the hot half that still works on a running terminal.
/// Dropping them on save would turn "I changed the description" into "I
/// quietly took this role's tool rules away", which nobody would notice
/// until a worker had the wrong tools.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Role {
    pub key: String,
    pub name: String,
    pub summary: String,
    pub instructions: String,
    pub clis: Vec<CliChoice>,
    pub polter: PolterSettings,
    /// Shipped with Polter. Shown, launched and copied, never saved: the
    /// core refuses to replace or delete one.
    pub builtin: bool,
    /// Everything else in the object. `serde_json::Map` is ordered by key,
    /// so two roles that differ only in the order a file wrote them compare
    /// equal -- the same reason the macOS side serialises with sorted keys.
    pub passthrough: Map<String, Value>,
}

const EDITED_KEYS: &[&str] = &["key", "name", "description", "instructions", "clis", "polter", "builtin"];

impl Role {
    pub fn new(key: &str, name: &str) -> Self {
        Self {
            key: key.to_string(),
            name: name.to_string(),
            summary: String::new(),
            instructions: String::new(),
            clis: Vec::new(),
            polter: PolterSettings::default(),
            builtin: false,
            passthrough: Map::new(),
        }
    }

    pub fn from_json(v: &Value) -> Option<Role> {
        let obj = v.as_object()?;
        let key = obj.get("key")?.as_str()?;
        let name = obj.get("name")?.as_str()?;
        let text = |k: &str| obj.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let mut clis = Vec::new();
        if let Some(map) = obj.get("clis").and_then(Value::as_object) {
            // Map iterates in key order: the same order `keys.sorted()` gives
            // the macOS side.
            for (cli, choice) in map {
                clis.push(CliChoice::from_json(cli, Some(choice)));
            }
        }
        let passthrough = obj
            .iter()
            .filter(|(k, _)| !EDITED_KEYS.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        Some(Role {
            key: key.to_string(),
            name: name.to_string(),
            summary: text("description"),
            instructions: text("instructions"),
            clis,
            polter: PolterSettings::from_json(obj.get("polter")),
            builtin: obj.get("builtin").and_then(Value::as_bool).unwrap_or(false),
            passthrough,
        })
    }

    /// The object `ghostty_app_persona_put` takes. **Never carries
    /// `builtin`**: a file cannot make a role Polter's, and the core ignores
    /// it anyway -- leaving it out keeps a copy of a built-in from claiming
    /// to be one.
    pub fn to_json(&self) -> Value {
        let mut out = self.passthrough.clone();
        out.insert("key".into(), Value::from(self.key.clone()));
        out.insert("name".into(), Value::from(self.name.trim()));
        let summary = self.summary.trim();
        if !summary.is_empty() {
            out.insert("description".into(), Value::from(summary));
        }
        if !self.instructions.trim().is_empty() {
            out.insert("instructions".into(), Value::from(self.instructions.clone()));
        }
        if !self.clis.is_empty() {
            let clis: Map<String, Value> = self.clis.iter().map(|c| (c.cli.clone(), c.to_json())).collect();
            out.insert("clis".into(), Value::Object(clis));
        }
        if !self.polter.is_default() {
            out.insert("polter".into(), self.polter.to_json());
        }
        Value::Object(out)
    }

    pub fn to_json_string(&self) -> String {
        self.to_json().to_string()
    }

    /// The name to show. A built-in role's is in the core in English, and
    /// shown here in the user's language.
    pub fn display_name(&self) -> String {
        if !self.builtin {
            return self.name.clone();
        }
        match self.key.as_str() {
            SUPERVISOR_KEY => tr("Polter Supervisor"),
            _ => self.name.clone(),
        }
    }

    pub fn display_summary(&self) -> String {
        if !self.builtin {
            return self.summary.clone();
        }
        match self.key.as_str() {
            SUPERVISOR_KEY => tr("Makes the terminal it starts in this window's supervisor: splits the work, hands it out and checks it."),
            _ => self.summary.clone(),
        }
    }

    pub fn choice(&self, cli: &str) -> Option<&CliChoice> {
        self.clis.iter().find(|c| c.cli == cli)
    }

    pub fn choice_mut(&mut self, cli: &str) -> Option<&mut CliChoice> {
        self.clis.iter_mut().find(|c| c.cli == cli)
    }

    /// A key for a new role, made from its name when the name has any
    /// letters or digits to make one from, and numbered otherwise --
    /// a Chinese name has none, and a key has to be `[a-z0-9-]`.
    pub fn suggested_key(name: &str, taken: &HashSet<String>) -> String {
        let ascii: String = name
            .to_lowercase()
            .chars()
            .map(|c| if c.is_ascii_lowercase() || c.is_ascii_digit() { c } else { '-' })
            .collect();
        let mut base = ascii.split('-').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("-");
        if base.len() > 24 {
            // All ASCII by construction, so a byte cut is a character cut.
            base.truncate(24);
        }
        if base.is_empty() {
            base = "role".to_string();
        }
        if !taken.contains(&base) && base != "role" {
            return base;
        }
        (1..)
            .map(|n| format!("{base}-{n}"))
            .find(|candidate| !taken.contains(candidate))
            .unwrap_or(base)
    }

    pub fn is_valid_key(key: &str) -> bool {
        let n = key.chars().count();
        (1..=32).contains(&n) && key.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    }
}

/// What the core said about the library: the roles, and whether that list
/// can be believed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Catalog {
    /// False until the file has been looked at. An empty list before then
    /// is "not read yet", not "no roles".
    pub loaded: bool,
    /// The file does not parse; `roles` is the last good version and the
    /// window must not offer to save over it.
    pub error: Option<String>,
    pub path: Option<String>,
    pub roles: Vec<Role>,
}

impl Catalog {
    pub fn parse(json: &str) -> Option<Catalog> {
        let v: Value = serde_json::from_str(json).ok()?;
        let obj = v.as_object()?;
        Some(Catalog {
            loaded: obj.get("loaded").and_then(Value::as_bool).unwrap_or(false),
            error: obj.get("error").and_then(Value::as_str).map(str::to_string),
            path: obj.get("path").and_then(Value::as_str).map(str::to_string),
            roles: obj
                .get("personas")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Role::from_json).collect())
                .unwrap_or_default(),
        })
    }

    pub fn role(&self, key: &str) -> Option<&Role> {
        self.roles.iter().find(|r| r.key == key)
    }
}

/// Whether an inventory item is a skill or an MCP server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Skill,
    Mcp,
}

/// One skill or MCP server a CLI has installed, as its adapter described it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CliItem {
    pub id: String,
    pub kind: ItemKind,
    pub name: String,
    pub summary: String,
    pub detail: String,
    pub source: String,
    pub group: Option<String>,
    pub group_summary: Option<String>,
    pub locked: bool,
}

impl CliItem {
    fn from_json(v: &Value) -> Option<CliItem> {
        let obj = v.as_object()?;
        let kind = match obj.get("kind")?.as_str()? {
            "skill" => ItemKind::Skill,
            "mcp" => ItemKind::Mcp,
            _ => return None,
        };
        let text = |k: &str| obj.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        Some(CliItem {
            id: obj.get("id")?.as_str()?.to_string(),
            kind,
            name: obj.get("name")?.as_str()?.to_string(),
            summary: text("description"),
            detail: text("detail"),
            source: text("source"),
            group: obj.get("group").and_then(Value::as_str).map(str::to_string),
            group_summary: obj.get("group_description").and_then(Value::as_str).map(str::to_string),
            locked: obj.get("locked").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}

/// An agent CLI a role can start, found because a plugin manages it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentCli {
    pub key: String,
    pub label: String,
    pub bin: String,
    /// The adapter could not answer; `items` is empty for that reason and
    /// not because nothing is installed.
    pub error: Option<String>,
    /// Whether the CLI's program was found. None when the adapter did not say.
    pub installed: Option<bool>,
    pub items: Vec<CliItem>,
    pub notes: Vec<String>,
}

impl AgentCli {
    pub fn items_of(&self, kind: ItemKind) -> Vec<&CliItem> {
        self.items.iter().filter(|i| i.kind == kind).collect()
    }

    fn from_json(v: &Value) -> Option<AgentCli> {
        let obj = v.as_object()?;
        let key = obj.get("key")?.as_str()?.to_string();
        let or_key = |k: &str| obj.get(k).and_then(Value::as_str).unwrap_or(&key).to_string();
        let mut cli = AgentCli {
            label: or_key("label"),
            bin: or_key("bin"),
            error: obj.get("error").and_then(Value::as_str).map(str::to_string),
            installed: None,
            items: Vec::new(),
            notes: Vec::new(),
            key: key.clone(),
        };
        if let Some(inv) = obj.get("inventory").and_then(Value::as_object) {
            cli.installed = inv.get("installed").and_then(Value::as_bool);
            cli.items = inv
                .get("items")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(CliItem::from_json).collect())
                .unwrap_or_default();
            cli.notes = strings(inv.get("notes"));
        }
        Some(cli)
    }
}

/// The core's cache of what each CLI has installed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CliSnapshot {
    /// Nothing has ever been read. Not the same as "no CLIs".
    pub stale: bool,
    /// A newer answer is on its way; ask again shortly.
    pub refreshing: bool,
    pub clis: Vec<AgentCli>,
}

impl Default for CliSnapshot {
    fn default() -> Self {
        Self { stale: true, refreshing: false, clis: Vec::new() }
    }
}

impl CliSnapshot {
    pub fn parse(json: &str) -> Option<CliSnapshot> {
        let v: Value = serde_json::from_str(json).ok()?;
        let obj = v.as_object()?;
        Some(CliSnapshot {
            stale: obj.get("stale").and_then(Value::as_bool).unwrap_or(true),
            refreshing: obj.get("refreshing").and_then(Value::as_bool).unwrap_or(false),
            clis: obj
                .get("clis")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(AgentCli::from_json).collect())
                .unwrap_or_default(),
        })
    }

    pub fn cli(&self, key: &str) -> Option<&AgentCli> {
        self.clis.iter().find(|c| c.key == key)
    }

    pub fn label(&self, key: &str) -> String {
        self.cli(key).map(|c| c.label.clone()).unwrap_or_else(|| key.to_string())
    }
}

/// The skills or MCP servers of one CLI, in groups a person recognises:
/// their own, this project's, and one per plugin.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ItemGroup {
    pub id: String,
    pub title: String,
    pub summary: Option<String>,
    pub items: Vec<CliItem>,
}

impl ItemGroup {
    pub fn groups(items: &[CliItem]) -> Vec<ItemGroup> {
        let mut order: Vec<String> = Vec::new();
        let mut by_key: HashMap<String, ItemGroup> = HashMap::new();
        for item in items {
            let key = match &item.group {
                Some(g) => format!("plugin:{g}"),
                None => item.source.clone(),
            };
            by_key
                .entry(key.clone())
                .or_insert_with(|| {
                    order.push(key.clone());
                    ItemGroup {
                        id: key.clone(),
                        title: Self::title_for(item),
                        summary: item.group_summary.clone(),
                        items: Vec::new(),
                    }
                })
                .items
                .push(item.clone());
        }
        let rank = |key: &str| match key {
            "user" => 0,
            "project" => 1,
            "local" => 2,
            _ => 3,
        };
        // Case-insensitive by title within a rank, as the macOS side's
        // `localizedCaseInsensitiveCompare`; ties keep first-seen order.
        order.sort_by(|a, b| {
            rank(a).cmp(&rank(b)).then_with(|| {
                let ta = by_key[a].title.to_lowercase();
                let tb = by_key[b].title.to_lowercase();
                ta.cmp(&tb)
            })
        });
        order.into_iter().filter_map(|k| by_key.remove(&k)).collect()
    }

    fn title_for(item: &CliItem) -> String {
        if let Some(g) = &item.group {
            return g.clone();
        }
        match item.source.as_str() {
            "user" => tr("Yours"),
            "project" => tr("This Project"),
            "local" => tr("This Project, Only on This Machine"),
            other => other.to_string(),
        }
    }
}

/// Split the extra-arguments field.
///
/// One line in the window, a list in the file: typed the way a shell would
/// take it, with quotes around anything that has a space in it.
pub fn args_split(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut started = false;
    for c in text.chars() {
        if let Some(q) = quote {
            if c == q {
                quote = None;
            } else {
                current.push(c);
            }
        } else if c == '"' || c == '\'' {
            quote = Some(c);
            started = true;
        } else if c.is_whitespace() {
            if started || !current.is_empty() {
                out.push(std::mem::take(&mut current));
            }
            started = false;
        } else {
            current.push(c);
        }
    }
    if started || !current.is_empty() {
        out.push(current);
    }
    out
}

/// Join a list of arguments back into the one line `args_split` reads.
pub fn args_join(args: &[String]) -> String {
    args.iter()
        .map(|arg| {
            let needs = arg.is_empty() || arg.chars().any(|c| c.is_whitespace() || c == '"' || c == '\'');
            if !needs {
                arg.clone()
            } else if arg.contains('"') {
                format!("'{arg}'")
            } else {
                format!("\"{arg}\"")
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// The core's error names, in words. An unknown name is shown as it is
/// rather than swallowed: it is the only clue there is.
pub fn message(code: &str) -> String {
    match code {
        "BadPersona" => tr("This role can't be saved: it needs a name, and a key of lowercase letters, digits and dashes."),
        "FileUnreadable" => tr("The role library file has an error in it, so saving would overwrite it. Fix the file first."),
        "NoSuchPersona" => tr("That role no longer exists."),
        "WriteNotLoaded" => tr("The role was written but didn't read back. This is a bug in Polter."),
        "CouldNotWrite" => tr("The role library file couldn't be written."),
        "NotSetUpForCli" => tr("This role isn't set up for that agent CLI."),
        "NoCli" => tr("This role isn't set up for any agent CLI yet. Pick one in the role library."),
        "ChooseCli" => tr("This role is set up for more than one agent CLI. Choose one."),
        "NotYetOpen" => tr("A tab was opened but didn't appear in time, so nothing was started in it."),
        "NoApp" => tr("Polter isn't ready yet."),
        // The window offers neither save nor delete on a built-in role, and
        // never changes the three user-only fields on someone else's behalf,
        // so these two mean something got past it. Worded after
        // `roleWriteFailure` in rpc.zig, which says the same to an agent.
        "BuiltinPersona" => tr("This role comes with Polter and can't be changed or deleted. Duplicate it to make one of your own."),
        "NotPermitted" => tr("Only you can make a role's terminal a supervisor, let it answer permission prompts, or keep agents out of it."),
        other => other.to_string(),
    }
}

fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default()
}

// -------------------------------------------------------------- the calls

/// Ask the core for a JSON document by the persona buffer rule: the real
/// length back, one NUL after it when it fits. `personas::ask_json` is the
/// reading this follows; it is private there, and one copy of eight lines
/// is cheaper than widening that module's surface for it.
fn ask_json(mut call: impl FnMut(*mut u8, usize) -> usize) -> Option<String> {
    let need = call(std::ptr::null_mut(), 0);
    if need == 0 {
        return None;
    }
    let mut buf = vec![0u8; need + 1];
    let wrote = call(buf.as_mut_ptr(), buf.len());
    if wrote != need {
        // The answer changed between the two calls. Not retried: the window
        // asks again on its next refresh anyway.
        // process-wide: the library is app-scoped, not any one window's.
        crate::plogf!("[roles] the core's answer changed size between asking and reading");
        return None;
    }
    String::from_utf8(buf[..need].to_vec()).ok()
}

/// The error name a failed bool call wrote: NUL-terminated, cut to the cap.
fn err_name(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

/// Every role in the library. `Catalog::default()` -- `loaded: false`, "not
/// read yet" -- when the app is not up or the answer could not be read;
/// never an empty library that was never looked at.
pub fn catalog() -> Catalog {
    let Some(api) = crate::api_opt() else { return Catalog::default() };
    let app = crate::app_opt();
    if app.is_null() {
        return Catalog::default();
    }
    ask_json(|b, c| unsafe { (api.app_persona_catalog)(app, b, c) })
        .and_then(|text| Catalog::parse(&text))
        .unwrap_or_default()
}

/// The core's cache of each agent CLI's inventory. With `refresh`, a new
/// read starts on the core's own thread and the answer says `refreshing`
/// until it lands; the caller polls. `CliSnapshot::default()` (stale) when
/// it could not be read.
pub fn clis(refresh: bool) -> CliSnapshot {
    let Some(api) = crate::api_opt() else { return CliSnapshot::default() };
    let app = crate::app_opt();
    if app.is_null() {
        return CliSnapshot::default();
    }
    ask_json(|b, c| unsafe { (api.app_agent_clis)(app, refresh, b, c) })
        .and_then(|text| CliSnapshot::parse(&text))
        .unwrap_or_default()
}

/// Save a role. `Err` is a sentence for the person.
pub fn put(role: &Role) -> Result<(), String> {
    let Some(api) = crate::api_opt() else { return Err(message("NoApp")) };
    let app = crate::app_opt();
    if app.is_null() {
        return Err(message("NoApp"));
    }
    let json = role.to_json_string();
    let mut err = [0u8; 128];
    let ok = unsafe { (api.app_persona_put)(app, json.as_ptr(), json.len(), err.as_mut_ptr(), err.len()) };
    if ok {
        Ok(())
    } else {
        Err(message(&err_name(&err)))
    }
}

/// Delete a role. `Err` is a sentence for the person.
pub fn delete(key: &str) -> Result<(), String> {
    let Some(api) = crate::api_opt() else { return Err(message("NoApp")) };
    let app = crate::app_opt();
    if app.is_null() {
        return Err(message("NoApp"));
    }
    let mut err = [0u8; 128];
    let ok = unsafe { (api.app_persona_delete)(app, key.as_ptr(), key.len(), err.as_mut_ptr(), err.len()) };
    if ok {
        Ok(())
    } else {
        Err(message(&err_name(&err)))
    }
}

/// Open a tab beside `surface` and start `cli` in it wearing `key`. `cli`
/// may be empty for a role set up for exactly one. `Err` is a sentence for
/// the person.
pub fn launch(surface: Surface, key: &str, cli: &str) -> Result<(), String> {
    let Some(api) = crate::api_opt() else { return Err(message("NoApp")) };
    if surface.is_null() {
        return Err(message("NoApp"));
    }
    let mut err = [0u8; 128];
    let ok = unsafe {
        (api.surface_persona_launch)(surface, key.as_ptr(), key.len(), cli.as_ptr(), cli.len(), err.as_mut_ptr(), err.len())
    };
    if ok {
        Ok(())
    } else {
        Err(message(&err_name(&err)))
    }
}

// -------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    // ------------------------------------------------------------ Selection

    #[test]
    fn set_adds_or_removes_the_difference_from_the_default() {
        let mut s = Selection::default();
        assert!(s.is_on("a"));
        s.set("a", false);
        assert_eq!(s.except, ids(&["a"]));
        assert!(!s.is_on("a"));
        s.set("a", false);
        assert_eq!(s.except, ids(&["a"]), "no duplicate");
        s.set("a", true);
        assert!(s.except.is_empty());
    }

    /// Flipping the default must not flip anything the user can see, and
    /// must flip everything they cannot.
    #[test]
    fn set_default_keeps_every_visible_item_where_it_was() {
        let mut s = Selection { keep_by_default: true, except: ids(&["b", "hidden-off"]) };
        let visible = ids(&["a", "b", "c"]);
        s.set_default(false, &visible);
        assert!(!s.keep_by_default);
        for (id, on) in [("a", true), ("b", false), ("c", true)] {
            assert_eq!(s.is_on(id), on, "{id}");
        }
        // Not listed but still an exception, so it stays in `except` and now
        // reads the other way: `setDefault` in RoleModels.swift only holds
        // the visible items still, and this pins that the port does the same.
        assert!(s.is_on("hidden-off"));
        // Not listed and never mentioned: it follows the new default.
        assert!(!s.is_on("installed-tomorrow"));
        let mut e = s.except.clone();
        e.sort();
        assert_eq!(e, ids(&["a", "c", "hidden-off"]));
    }

    #[test]
    fn set_default_to_the_same_value_changes_nothing() {
        let mut s = Selection { keep_by_default: false, except: ids(&["x"]) };
        let before = s.clone();
        s.set_default(false, &ids(&["x", "y"]));
        assert_eq!(s, before);
    }

    // --------------------------------------------------------------- polter

    #[test]
    fn a_default_polter_is_not_written() {
        let r = Role::new("w", "worker");
        assert!(r.to_json().get("polter").is_none());
    }

    #[test]
    fn polter_round_trips_with_quiet_ms() {
        let v = json!({"key":"w","name":"worker","polter":{"watch":true,"open":"tab","quiet_ms":600000}});
        let r = Role::from_json(&v).unwrap();
        assert!(r.polter.watch && !r.polter.supervisor);
        assert_eq!(r.polter.open, Open::Tab);
        assert_eq!(r.polter.quiet_ms, Some(600_000));
        let out = r.to_json();
        let p = &out["polter"];
        assert_eq!(p["quiet_ms"], json!(600000));
        assert_eq!(p["open"], json!("tab"));
        assert_eq!(p["supervisor"], json!(false));
        assert_eq!(Role::from_json(&out).unwrap(), r);
    }

    #[test]
    fn polter_without_quiet_ms_writes_none() {
        let mut r = Role::new("w", "worker");
        r.polter.supervisor = true;
        let out = r.to_json();
        assert!(out["polter"].get("quiet_ms").is_none());
        assert_eq!(out["polter"]["open"], json!("auto"));
    }

    // -------------------------------------------------------------- builtin

    /// The supervisor role as `writePersona` renders it (persona.zig
    /// `builtins`), trimmed to what these tests read.
    fn supervisor_json() -> Value {
        json!({
            "key": SUPERVISOR_KEY,
            "name": "Polter Supervisor",
            "description": "Makes the terminal it starts in this window's supervisor: splits the work, hands it out and checks it.",
            "instructions": "You are the supervisor.",
            "clis": {"claude-code": {"skills": {"default": false, "except": ["skill:polter-supervising"]},
                                      "mcp": {"default": false, "except": []}}},
            "polter": {"supervisor": true, "may_authorise": false, "shielded": false, "watch": false, "open": "auto"},
            "builtin": true
        })
    }

    #[test]
    fn a_builtin_role_is_read_as_builtin_and_shown_by_key() {
        let r = Role::from_json(&supervisor_json()).unwrap();
        assert!(r.builtin);
        assert!(r.polter.supervisor);
        assert_eq!(r.polter.open, Open::Auto);
        // Tests run with no DLL, so `tr` answers the msgid.
        assert_eq!(r.display_name(), "Polter Supervisor");
        assert!(r.display_summary().starts_with("Makes the terminal it starts in"));
        let c = r.choice("claude-code").unwrap();
        assert!(!c.skills.keep_by_default && c.skills.is_on("skill:polter-supervising"));
        assert!(!c.mcp.keep_by_default);
    }

    /// A user's role named like a built-in shows its own name: only
    /// `builtin` makes a name Polter's to translate.
    #[test]
    fn display_name_is_only_translated_for_a_builtin() {
        let mut r = Role::from_json(&supervisor_json()).unwrap();
        r.builtin = false;
        r.name = "我的总管".into();
        r.summary = "mine".into();
        assert_eq!(r.display_name(), "我的总管");
        assert_eq!(r.display_summary(), "mine");
        // A built-in this build does not know yet falls back to the core's.
        let mut other = Role::new("polter-future", "Future");
        other.builtin = true;
        assert_eq!(other.display_name(), "Future");
    }

    #[test]
    fn builtin_is_never_written_back() {
        let r = Role::from_json(&supervisor_json()).unwrap();
        let out = r.to_json();
        assert!(out.get("builtin").is_none(), "{out}");
        assert!(r.to_json_string().find("builtin").is_none());
    }

    // ---------------------------------------------------------- passthrough

    #[test]
    fn fields_the_window_does_not_edit_survive_a_save() {
        let v = json!({
            "key": "a", "name": "A", "description": "old",
            "tools": {"deny": ["Bash"]},
            "hint": {"disable_host_plugins": ["x"], "model": "opus"},
            "prompt": "hi", "skills": ["1-0"]
        });
        let mut r = Role::from_json(&v).unwrap();
        assert!(r.passthrough.get("key").is_none(), "edited keys are not passthrough");
        r.summary = "new".into();
        let out = r.to_json();
        assert_eq!(out["tools"], json!({"deny": ["Bash"]}));
        assert_eq!(out["hint"], json!({"disable_host_plugins": ["x"], "model": "opus"}));
        assert_eq!(out["prompt"], json!("hi"));
        assert_eq!(out["skills"], json!(["1-0"]));
        assert_eq!(out["description"], json!("new"));
    }

    #[test]
    fn empty_fields_are_left_out_and_names_trimmed() {
        let mut r = Role::new("a", "  A  ");
        r.summary = "   ".into();
        r.instructions = "\n".into();
        let mut c = CliChoice::new("claude-code");
        c.model = "  ".into();
        r.clis.push(c);
        let out = r.to_json();
        assert_eq!(out["name"], json!("A"));
        assert!(out.get("description").is_none());
        assert!(out.get("instructions").is_none());
        let cc = &out["clis"]["claude-code"];
        assert!(cc.get("model").is_none() && cc.get("args").is_none());
        assert_eq!(cc["skills"], json!({"default": true, "except": []}));
    }

    // --------------------------------------------------------------- parsing

    #[test]
    fn a_catalog_parses_and_keeps_loaded_apart_from_empty() {
        let c = Catalog::parse(r#"{"loaded":true,"error":null,"path":"C:\\p.json","personas":[{"key":"a","name":"A"},{"name":"no key"}]}"#).unwrap();
        assert!(c.loaded && c.error.is_none());
        assert_eq!(c.path.as_deref(), Some("C:\\p.json"));
        assert_eq!(c.roles.len(), 1, "a role with no key is dropped, not invented");
        assert!(c.role("a").is_some());
        assert!(!Catalog::default().loaded);
        assert!(Catalog::parse("not json").is_none());
    }

    /// The core's own render-failure answer, read out of its source rather
    /// than copied here (the trick `personas.rs` uses): it must come in as a
    /// named error on a library that was not loaded, not as "no roles".
    #[test]
    fn the_cores_catalog_fallback_is_an_error_not_an_empty_library() {
        const EMBEDDED_ZIG: &str = include_str!("../../../src/apprt/embedded.zig");
        let lit = |name: &str| -> String {
            let at = EMBEDDED_ZIG.find(name).expect("the literal is in the core");
            EMBEDDED_ZIG[at..]
                .lines()
                .skip(1)
                .map_while(|l| l.trim_start().strip_prefix("\\\\"))
                .collect()
        };
        let c = Catalog::parse(&lit("const catalog_fallback")).expect("parses");
        assert!(!c.loaded);
        assert!(c.error.is_some());
        let s = CliSnapshot::parse(&lit("const clis_fallback")).expect("parses");
        assert!(s.stale && s.clis.is_empty());
    }

    #[test]
    fn a_cli_snapshot_parses() {
        let s = CliSnapshot::parse(
            r#"{"stale":false,"refreshing":true,"clis":[
                {"key":"claude-code","label":"Claude Code","bin":"claude",
                 "inventory":{"installed":true,"notes":["n"],"items":[
                   {"id":"skill:a","kind":"skill","name":"a","source":"user"},
                   {"id":"mcp:polter","kind":"mcp","name":"polter","source":"user","locked":true},
                   {"id":"x","kind":"weird","name":"x"}]}},
                {"key":"bare","error":"boom"}]}"#,
        )
        .unwrap();
        assert!(!s.stale && s.refreshing);
        let cc = s.cli("claude-code").unwrap();
        assert_eq!(cc.installed, Some(true));
        assert_eq!(cc.items.len(), 2, "an unknown kind is dropped");
        assert_eq!(cc.items_of(ItemKind::Mcp)[0].locked, true);
        assert_eq!(cc.notes, ids(&["n"]));
        let bare = s.cli("bare").unwrap();
        assert_eq!((bare.label.as_str(), bare.bin.as_str()), ("bare", "bare"));
        assert_eq!(bare.installed, None);
        assert_eq!(bare.error.as_deref(), Some("boom"));
        assert_eq!(s.label("nobody"), "nobody");
        assert!(CliSnapshot::default().stale);
    }

    // ------------------------------------------------------------- grouping

    fn item(id: &str, source: &str, group: Option<&str>) -> CliItem {
        CliItem {
            id: id.into(),
            kind: ItemKind::Skill,
            name: id.into(),
            summary: String::new(),
            detail: String::new(),
            source: source.into(),
            group: group.map(str::to_string),
            group_summary: group.map(|g| format!("about {g}")),
            locked: false,
        }
    }

    #[test]
    fn groups_come_user_project_local_then_plugins_by_title() {
        let items = vec![
            item("p1", "plugin", Some("zeta")),
            item("l1", "local", None),
            item("p2", "plugin", Some("Alpha")),
            item("u1", "user", None),
            item("pr1", "project", None),
            item("u2", "user", None),
            item("p3", "plugin", Some("zeta")),
        ];
        let g = ItemGroup::groups(&items);
        let order: Vec<&str> = g.iter().map(|g| g.id.as_str()).collect();
        assert_eq!(order, ["user", "project", "local", "plugin:Alpha", "plugin:zeta"]);
        assert_eq!(g[0].title, "Yours");
        assert_eq!(g[1].title, "This Project");
        assert_eq!(g[2].title, "This Project, Only on This Machine");
        assert_eq!(g[3].title, "Alpha");
        assert_eq!(g[4].summary.as_deref(), Some("about zeta"));
        let u: Vec<&str> = g[0].items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(u, ["u1", "u2"], "items keep their order inside a group");
        assert_eq!(g[4].items.len(), 2);
    }

    // ------------------------------------------------------------------ keys

    #[test]
    fn suggested_key_comes_from_the_name_or_is_numbered() {
        let none = HashSet::new();
        assert_eq!(Role::suggested_key("Code Reviewer!", &none), "code-reviewer");
        // A Chinese name has nothing to make a key from.
        assert_eq!(Role::suggested_key("代码审查", &none), "role-1");
        let taken: HashSet<String> = ["role-1".to_string(), "code-reviewer".to_string()].into();
        assert_eq!(Role::suggested_key("代码审查", &taken), "role-2");
        assert_eq!(Role::suggested_key("Code Reviewer", &taken), "code-reviewer-1");
        // Mixed: the ASCII part is kept.
        assert_eq!(Role::suggested_key("审查 v2", &none), "v2");
        let long = Role::suggested_key("abcdefghijklmnopqrstuvwxyz0123", &none);
        assert_eq!(long.len(), 24);
        assert!(Role::is_valid_key(&long));
    }

    #[test]
    fn valid_keys_are_short_lowercase_digits_and_dashes() {
        assert!(Role::is_valid_key("a-1"));
        assert!(!Role::is_valid_key(""));
        assert!(!Role::is_valid_key("A"));
        assert!(!Role::is_valid_key("a_b"));
        assert!(!Role::is_valid_key("角色"));
        assert!(Role::is_valid_key(&"a".repeat(32)));
        assert!(!Role::is_valid_key(&"a".repeat(33)));
    }

    // ------------------------------------------------------------------ args

    #[test]
    fn args_split_on_spaces_and_honour_quotes() {
        assert_eq!(args_split(r#"--a "b c" 'd "e"' """#), ids(&["--a", "b c", "d \"e\"", ""]));
        assert_eq!(args_split("  x   y "), ids(&["x", "y"]));
        assert!(args_split("   ").is_empty());
    }

    #[test]
    fn args_join_quotes_what_needs_it_and_round_trips() {
        let args = ids(&["--a", "b c", "d \"e\"", "", "it's"]);
        let line = args_join(&args);
        assert_eq!(line, r#"--a "b c" 'd "e"' "" "it's""#);
        assert_eq!(args_split(&line), args);
    }

    // ---------------------------------------------------------------- errors

    #[test]
    fn error_names_become_sentences_and_unknown_ones_pass_through() {
        assert!(message("BadPersona").starts_with("This role can't be saved"));
        assert_eq!(message("NoApp"), "Polter isn't ready yet.");
        assert!(message("BuiltinPersona").starts_with("This role comes with Polter"));
        assert!(message("NotPermitted").starts_with("Only you can"));
        assert_eq!(message("SomethingNew"), "SomethingNew");
        assert_eq!(err_name(b"NoCli\0garbage"), "NoCli");
        assert_eq!(err_name(b"Cut"), "Cut");
    }
}
