//! What the agent in one terminal has in its hands, on the Windows host.
//!
//! The design is `dev-docs/poltergeist/roles.md`, and **that document is the
//! only source of truth for this file**. Three things out of it decide the
//! shape here, and each of them is a rule about not lying rather than a
//! feature:
//!
//!  * §5.2 -- a terminal carries **two** facts, the persona the user picked and
//!    the set that is actually in effect. Picking a persona resets the second to
//!    the first; changing one item afterwards moves only the second. When
//!    they disagree the screen has to show it, which is why nothing here ever
//!    renders a bare persona name: it goes through [`display_name`].
//!  * §5.3 -- the mark is the user's **intent** for that terminal, not a
//!    measurement of what is running in it. With no agent connected the persona
//!    is still stored and **is not shown as being in force**, because a stale
//!    mark and a correct one are the same pixels.
//!  * §6 -- a host that can only change its tools at its next launch must say
//!    so on the menu. "Already switched" and "waiting for a restart" must not
//!    look the same.
//!
//! # What is here and what is not
//!
//! **No storage, no validation, no switching.** §7 puts all three in the core:
//! personas are a user-defined closed set, and a host process that could write
//! one would be a host process that could grant a terminal a tool the user
//! never agreed to. This file reads what it is handed and draws it.
//!
//! **What it is handed arrives through [`set_provider`]**, and until somebody
//! calls that, every question here answers [`Catalogue::NotWired`] /
//! [`HostClass::Unknown`] -- **a third state, not an empty list**. An empty list
//! says "this machine has no personas"; not-wired says "nobody has been asked".
//! `plugins::Shipped` in this host already carries that distinction and its
//! header records what collapsing it cost: a page that said *no plugins
//! found* while the installation was fine.

use std::sync::{Mutex, OnceLock};

pub use crate::ffi::Surface;
use crate::i18n::tr;

// ------------------------------------------------------------------- model

/// One persona, as §5.1 spells it.
///
/// **Owned strings and no borrows from the core.** The core hands these over
/// a C boundary whose lifetime is the call, so keeping a pointer would be
/// keeping a dangling one the moment the menu is on screen -- the same trade
/// `i18n::tr` makes and for the same reason.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Persona {
    /// `archer`. The name every message and every file uses.
    pub key: String,
    /// What the user reads. §5.1's `name`.
    pub name: String,
    /// Polter's own skills, by name. Delivered through the tool surface
    /// (§2), never by putting files anywhere.
    pub skills: Vec<String>,
    /// Slot names, **without the `polter:` prefix** (§3.2).
    pub mcp: Vec<String>,
    /// §5.1's `prompt`: the opening prompt this persona reads, delivered
    /// through the tool surface like the skills are. `None` when the persona
    /// declares none.
    pub prompt: Option<String>,
    /// §5.1's `hint`: the part that only happens at a cold host's next
    /// launch. Kept as text because this host neither reads nor applies it --
    /// it shows it so a person can see what a restart would do.
    pub hint: Vec<(String, String)>,
}

/// What this host knows about the personas the user has defined.
///
/// **Three outcomes on purpose**, the shape `plugins::Shipped` argues for:
/// nobody asked, asked and there are none, asked and here they are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Catalogue {
    /// No provider has been installed. The core has not been asked.
    NotWired,
    /// The core answered, and the user has defined no personas.
    Empty,
    Personas(Vec<Persona>),
}

/// Whether the agent in this terminal changes its tools now or at its next
/// launch. `ghostty_action_poltergeist_host_class_e`.
///
/// ⚠️ **This host does not decide it, it decodes it.** An earlier draft here
/// kept §6's table -- claude-code hot, codex cold, and so on -- keyed by the
/// CLI's name. The contract's §3.1 has the core compute `host_class` and send
/// it, which makes a table here a **second reader with its own rules**, the
/// exact shape §① refuses for `personas.json`. The two would agree until the
/// core learned about a CLI this table had not, and the disagreement would
/// show as a cold agent drawn like a hot one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostClass {
    /// **Zero, and it is the honest answer**, not "hot". The window while an
    /// agent's handshake is unfinished is always this.
    Unknown,
    Hot,
    Warm,
    Cold,
}

impl HostClass {
    /// Decode the C enum. **Anything unrecognised is `Unknown`**, which is the
    /// only value that cannot mislead: a new class this build has not heard of
    /// drawn as `Hot` would say "already switched" about something that has
    /// not.
    pub fn from_c(v: i32) -> HostClass {
        match v {
            1 => HostClass::Hot,
            2 => HostClass::Warm,
            3 => HostClass::Cold,
            _ => HostClass::Unknown,
        }
    }
}

/// Why the persona catalogue is not what it should be (§3.5's `error_kind`).
///
/// **Its own type rather than a bare string** because the menu has to draw
/// `Parse` differently from an empty catalogue: W3's «no roles are defined»
/// would otherwise take the blame for a syntax error, and the user would go
/// and write a persona that is already there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    /// `personas.json` did not load. The previous catalogue is still in force.
    Parse,
    /// A menu built against an older roster sent an id that no longer names
    /// anything (§0.5).
    StaleId,
    /// An `error_kind` this build has not heard of. **Its own case, and it
    /// gets no sentence** -- see [`error_lead_in`].
    Unknown,
}

impl ErrorKind {
    /// Decode §3.5's `error_kind`. **Switched on the kind, never on the
    /// message text**: matching the text would make the interface's wording
    /// depend on the core's, and the two are allowed to move apart.
    pub fn from_wire(s: &str) -> ErrorKind {
        match s {
            "parse" => ErrorKind::Parse,
            "stale_id" => ErrorKind::StaleId,
            _ => ErrorKind::Unknown,
        }
    }
}

/// The sentence that goes above the core's own error text, chosen by kind.
///
/// ⚠️ **An unrecognised kind gets nothing.** The core's text is still shown;
/// what is withheld is our sentence about it. Inventing a lead-in for a kind
/// this build does not understand would put a confident explanation in front
/// of an error it has not been taught to explain -- and the user would read
/// ours, not the core's.
pub fn error_lead_in(kind: ErrorKind) -> Option<String> {
    match kind {
        ErrorKind::Parse => {
            Some(tr("The roles file could not be read, so the previous one is still in use"))
        }
        ErrorKind::StaleId => Some(tr("This menu is out of date. Close it and open it again")),
        ErrorKind::Unknown => None,
    }
}

/// One terminal's standing, as §5.2 splits it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Standing {
    /// The persona key the user picked, or `None` for a terminal that has never
    /// been given one.
    pub key: Option<String>,
    /// The name to show for that key. Carried rather than looked up so that
    /// a terminal keeps a readable label when its persona has since been
    /// deleted from the catalogue.
    pub name: Option<String>,
    /// §5.2: the effective set no longer matches the persona it came from.
    pub deviated: bool,
    /// §5.3: an agent is connected to this terminal right now.
    ///
    /// **False hides the mark, it does not clear the persona.** The persona is
    /// still stored and the menu still ticks the row that is set; what goes
    /// away is the claim that it is in force.
    pub agent_present: bool,
    /// §3.2: a shielded terminal refuses every change of persona, a
    /// supervisor included. **The bit is already in today's mark**, beside
    /// `role` and `held`; nothing new crosses the boundary for it.
    pub shielded: bool,
    /// What the core says about when a change takes effect here. Decoded,
    /// never derived.
    pub host_class: HostClass,
    /// §3.5. `None` when there is nothing wrong.
    pub error: Option<(ErrorKind, String)>,
}

impl Standing {
    /// What a terminal with nothing known about it looks like.
    pub fn unknown() -> Standing {
        Standing {
            key: None,
            name: None,
            deviated: false,
            agent_present: false,
            shielded: false,
            host_class: HostClass::Unknown,
            error: None,
        }
    }
}

/// What the slot process behind one MCP entry is doing (§4.3).
///
/// ⚠️ **This exists because `enabled` alone made two different things look
/// identical.** «the user switched argus off» and «the persona grants argus
/// but that server did not start» were both `enabled:false`, so the editor
/// could only draw one row for them -- and §4.3 says that shape sends the
/// user off to edit the persona when what they need is to go and look at the
/// server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlotState {
    /// Outside Polter: never got an answer, so the slot passes the upstream
    /// through verbatim (§4.2). **Not a failure** -- it is the state a
    /// terminal the user started outside Ghostty is supposed to be in.
    Transparent,
    Granted,
    Withheld,
    /// Granted, and the upstream is not running. The one state here that is
    /// about something being wrong.
    Broken,
}

/// One thing the terminal either hands out or does not: a skill, or an MCP
/// slot.
///
/// **Two bits, not one.** `on` is what this terminal is handing out now;
/// `in_persona` is what the persona it was given declares. The pair is the
/// whole of §5.2's "preset, plus a departure from it" -- one bit could say
/// *that* something had changed but never *which way*, and the two ways need
/// opposite actions from the user to undo.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    /// §3.5's `id`, `<roster>-<index>`. **Carried and handed back verbatim**:
    /// the contract says the apprt must not build one, because building one
    /// would make this a second place that knows the format -- and the format
    /// carries the roster number that makes a click on a stale menu
    /// detectable.
    pub id: String,
    pub name: String,
    /// In the effective set right now.
    pub on: bool,
    /// The persona this terminal was given asks for it. §3.5's `in_persona`,
    /// **computed by the core** rather than by comparing catalogues out here:
    /// two readers means two rules, and the lax one wins.
    pub in_persona: bool,
    /// §4.3, for an MCP slot. `None` for a skill, which has no process behind
    /// it and therefore none of these states.
    pub slot: Option<SlotState>,
}

/// Which way an item departs from its persona.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Departure {
    /// Not in the persona; switched on here.
    AddedByHand,
    /// In the persona; switched off here.
    SwitchedOffByHand,
}

impl Item {
    /// ⚠️ **Two directions, never one flag.** Merging these into "changed"
    /// loses the only thing the user needs in order to put it back: one is
    /// undone by switching something off, the other by switching it on.
    pub fn departure(&self) -> Option<Departure> {
        match (self.on, self.in_persona) {
            (true, false) => Some(Departure::AddedByHand),
            (false, true) => Some(Departure::SwitchedOffByHand),
            _ => None,
        }
    }

    /// The sentence that belongs beside this row, if any.
    ///
    /// ⚠️ **`Broken` is checked first, and the order is the whole point.** An
    /// item the persona grants and whose server is not running is
    /// `in_persona` and `!on`, so by the departure rule alone it would read
    /// «switched off by hand» -- blaming the user for something they did not
    /// do, and sending them to the persona instead of to the server. That is
    /// the misattribution §4.3 exists to stop, and it is one `if` away at all
    /// times.
    pub fn aside(&self) -> String {
        // **Only two of the four slot states say anything**, which is W3's
        // call and it is right: `granted` and `withheld` are what the
        // checkbox beside them already shows, and a sentence on every row is
        // noise that drowns the one row that matters. On a build where every
        // slot is `withheld` -- which is today -- a note per row would bury
        // `broken` exactly where §4.3 needs it seen.
        match self.slot {
            Some(SlotState::Broken) => {
                return tr("This server didn't start. Your role isn't what's withholding it.")
            }
            Some(SlotState::Transparent) => {
                return tr("Polter isn't managing this server, so the agent sees all of it")
            }
            // `Granted` and `Withheld` say nothing: the checkbox does.
            _ => {}
        }
        self.departure().map(departure_note).unwrap_or_default()
    }
}

impl Item {
    /// ⚠️ **Whether this row's sentence is a warning rather than a note.**
    ///
    /// Only `Transparent`, and the reason is that the editor is the one place
    /// that state cannot legitimately appear. §4.2 says a slot passes the
    /// upstream through **only when it never got an answer**, which is a
    /// terminal started outside Ghostty -- and this window only exists inside
    /// Ghostty. So a transparent row here means a slot that *is* inside
    /// Polter fell through to pass-through, which is the hole §4.2 was
    /// written to close: anyone who can make Polter unreachable gets every
    /// upstream tool.
    ///
    /// Read outside the editor the same sentence is an ordinary statement of
    /// fact. **Here it is a symptom**, and drawing it like the others would
    /// let the one row that means something wrong sit quietly among rows that
    /// do not.
    pub fn aside_is_warning(&self) -> bool {
        self.slot == Some(SlotState::Transparent)
    }
}

/// The sentence that goes beside a departed item.
pub fn departure_note(d: Departure) -> String {
    match d {
        Departure::AddedByHand => tr("Added by hand"),
        Departure::SwitchedOffByHand => tr("Switched off by hand"),
    }
}

/// What one terminal is handing out, §5.2's "effective set".
///
/// **Three states, like everything else here.** "nobody has read the face
/// yet" and "the face was read and it hands out nothing" send the user to
/// different places, and the agreed wording has a separate sentence for each.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Handout {
    NotReported,
    Known { skills: Vec<Item>, mcp: Vec<Item> },
}

impl Default for Handout {
    /// **`NotReported`, not an empty pair.** The default is what a build with
    /// nothing wired up answers, and that is precisely "nobody has said".
    fn default() -> Handout {
        Handout::NotReported
    }
}

impl Handout {
    /// §5.2: the effective set no longer matches the persona it came from.
    ///
    /// **Derived rather than carried as a third field.** A `deviated` bool
    /// beside these lists is a second place for one fact, and the two drift --
    /// which here would mean a tab saying «Archer» over a page showing
    /// something switched off by hand.
    pub fn deviated(&self) -> bool {
        match self {
            Handout::NotReported => false,
            Handout::Known { skills, mcp } => {
                skills.iter().chain(mcp.iter()).any(|i| i.departure().is_some())
            }
        }
    }

    /// Read, and there is nothing in it. **Not the same as `NotReported`.**
    pub fn is_empty(&self) -> bool {
        matches!(self, Handout::Known { skills, mcp } if skills.is_empty() && mcp.is_empty())
    }
}

/// How well one part of one agent's installation could be read.
///
/// **Four states, not a list that might be empty.** `inventory.zig` states
/// the reason and this host copies it rather than reducing it: the four send
/// the user to four different places, and three of them would quietly become
/// "nothing here" if this were a `Vec`. §4 puts this pane on screen so the
/// user can see *where a persona stops*; a pane that says "nothing" when it
/// means "we never looked" is worse than no pane at all.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Section {
    /// Nobody has confirmed where this agent keeps this kind of thing.
    /// **Not evidence of anything** -- our gap, not theirs. The user who
    /// reads it should go and check the path, not go and install something.
    UnknownLocation,
    /// The path is known and there is nothing at it. The ordinary answer for
    /// an agent that is not installed, and **not a problem**.
    Absent,
    /// Read. An empty list here really does mean empty, which `Absent` does
    /// not.
    Read(Vec<String>),
    /// It is there and could not be read. The one to put in front of the
    /// user, with the core's own detail.
    Failed(String),
}

impl Section {
    /// The sentence for a section with nothing to list, or `None` when there
    /// is a list to draw instead.
    ///
    /// ⚠️ **`Absent` and `Read(vec![])` deliberately share a sentence.** To
    /// the user they are one fact -- there is nothing installed here -- and
    /// `inventory.zig` says so where it defines them. The three that must
    /// stay apart are "we never looked", "we looked and it is empty" and "we
    /// looked and could not read it".
    pub fn note(&self) -> Option<String> {
        match self {
            Section::UnknownLocation => Some(tr("Nobody has checked where this agent keeps these yet")),
            Section::Absent => Some(tr("Looked there, and nothing is installed")),
            Section::Read(v) if v.is_empty() => Some(tr("Looked there, and nothing is installed")),
            Section::Read(_) => None,
            Section::Failed(_) => Some(tr("Couldn't read what's installed here")),
        }
    }
}

/// One agent CLI's installation, as §3.4's JSON describes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostInventory {
    /// `claude-code`. The key the core uses.
    pub key: String,
    /// What to show. The core's own label, not a table here.
    pub label: String,
    pub plugins: Section,
    pub skills: Section,
    pub mcp: Section,
}

/// What is installed on this machine outside Polter's reach (§4).
///
/// **`stale` is not an empty list**, which the C header says in as many
/// words. An interface that draws them the same way tells the user nothing is
/// installed here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Inventory {
    NotReported,
    Known {
        hosts: Vec<HostInventory>,
        /// §4.1's `complete`. False means some agent's configuration could
        /// not be read, so **anything counted from this is a lower bound**.
        /// Said on screen rather than swallowed: a number computed from an
        /// incomplete scan looks exactly like one computed from a complete
        /// one.
        complete: bool,
    },
}

// ---------------------------------------------------------------- provider

/// Where the facts come from.
///
/// **A trait rather than a pair of function pointers** because the two
/// questions have to be answered by one party: a catalogue from the core and
/// a standing from somewhere else could name a persona key that does not exist,
/// and the menu would tick nothing while looking right.
pub trait Provider: Send + Sync {
    /// **Takes the surface** because the bit that separates «nobody has
    /// reported» from «asked, and there are none» rides on the face, and the
    /// face is per terminal. Without it this answer would have to guess from
    /// a count of zero -- and a guess there is what puts «no roles are
    /// defined» in front of a user whose file simply has not been read.
    fn catalogue(&self, surface: Surface) -> Catalogue;
    fn standing(&self, surface: Surface) -> Standing;
    /// What this terminal is handing out right now, §5.2.
    fn effective(&self, surface: Surface) -> Handout;
    /// §4's read-only list. **Provided, never gathered here**: this host
    /// would be a fourth reader of files whose layout lives in the
    /// provisioning plugins, and a fourth reader is a fourth thing to keep in
    /// agreement.
    fn installed(&self) -> Inventory;

    /// Hand one binding string to `ghostty_surface_binding_action` for this
    /// terminal, and say what came of it.
    ///
    /// **One method for all four actions** (§3.2), because all four *are* one
    /// thing on the wire: a string handed to the core. Separate `set` and
    /// `toggle` methods would each know how to spell an action, which is two
    /// places for one format -- and the format carries the epoch that makes a
    /// stale click detectable.
    ///
    /// **Returns what happened, and it is not a bool.** §6 needs "done" and
    /// "at the next launch" to stay different answers all the way out to the
    /// log; a bool would make a cold agent's successful switch and a refusal
    /// look the same.
    fn send(&self, surface: Surface, action: &str) -> SetOutcome;
}

/// Which of the two lists an item belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Skill,
    Mcp,
}

/// What came back from asking for a switch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetOutcome {
    /// The terminal's tool surface changed; the agent has already been told.
    Applied,
    /// Stored, and it happens when the agent is next started (§6, cold).
    AtNextLaunch,
    /// Refused. §7: a shielded terminal refuses every switch, supervisor
    /// included.
    Refused,
    /// Nothing is wired up to answer.
    NotWired,
}

static PROVIDER: OnceLock<Mutex<Option<Box<dyn Provider>>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<Box<dyn Provider>>> {
    PROVIDER.get_or_init(|| Mutex::new(None))
}

/// Serialises the tests that install a provider.
///
/// ⚠️ **The provider is process-wide and `cargo test` runs tests on several
/// threads of one process**, so two tests that each install their own fixture
/// overwrite each other's -- and the loser fails while reading a state the
/// winner set up. That failure is not deterministic and does not name its
/// cause, which is the worst shape a red test can have: it reads as the code
/// being wrong in a way that goes away when you look again. Every test that
/// calls `set_provider` takes this first.
///
/// A poisoned lock is taken anyway: the poison is some other test's panic,
/// and refusing to run because of it would turn one failure into many.
#[cfg(test)]
pub static TEST_LOCK: Mutex<()> = Mutex::new(());

/// Install the thing that answers. Replacing one is allowed; the tests do it.
pub fn set_provider(p: Box<dyn Provider>) {
    if let Ok(mut g) = slot().lock() {
        *g = Some(p);
    }
}

/// The user's personas, or why there are none to show.
pub fn catalogue(surface: Surface) -> Catalogue {
    match slot().lock() {
        Ok(g) => g.as_ref().map(|p| p.catalogue(surface)).unwrap_or(Catalogue::NotWired),
        // A poisoned lock is a panic somewhere else, and the honest answer
        // then is that nothing has been established -- not an empty list.
        Err(_) => Catalogue::NotWired,
    }
}

/// One terminal's standing.
pub fn standing(surface: Surface) -> Standing {
    match slot().lock() {
        Ok(g) => g.as_ref().map(|p| p.standing(surface)).unwrap_or_else(Standing::unknown),
        Err(_) => Standing::unknown(),
    }
}

/// What this terminal is handing out. Empty when nothing is wired up, which
/// the page distinguishes from "the persona asks for nothing" by asking
/// [`catalogue`] as well.
pub fn effective(surface: Surface) -> Handout {
    match slot().lock() {
        Ok(g) => g.as_ref().map(|p| p.effective(surface)).unwrap_or_default(),
        Err(_) => Handout::default(),
    }
}

/// §4's read-only list, or the fact that nobody has reported one.
pub fn installed() -> Inventory {
    match slot().lock() {
        Ok(g) => g.as_ref().map(|p| p.installed()).unwrap_or(Inventory::NotReported),
        Err(_) => Inventory::NotReported,
    }
}

/// Hand one action string to the core.
pub fn send(surface: Surface, action: &str) -> SetOutcome {
    match slot().lock() {
        Ok(g) => g.as_ref().map(|p| p.send(surface, action)).unwrap_or(SetOutcome::NotWired),
        Err(_) => SetOutcome::NotWired,
    }
}

/// Switch one item of the effective set. This is the path that produces a
/// departure, §5.2.
///
/// The id is checked on the way past and **still sent** if it fails: see
/// [`id_is_spellable`] for why saying so is this host's job and refusing is
/// not.
pub fn toggle(surface: Surface, kind: Kind, id: &str, on: bool) -> SetOutcome {
    if !id_is_spellable(id) {
        // process-wide: an id the core minted that does not look like
        // `<epoch>-<index>`. The action goes anyway; this line is the only
        // thing that would say the format had changed under us.
        // absence: proves nothing -- silent on every healthy machine, and
        // equally silent on one where nobody touched the editor.
        crate::plogf!("[persona] id {id:?} is not <epoch>-<index>; the format may have changed");
    }
    send(surface, &action_toggle(kind, id, on))
}

// ------------------------------------------------------------------ labels

/// The name of a persona **as it may be shown**, §5.2.
///
/// ⚠️ **Nothing else in this host is allowed to print a bare persona name.**
/// The whole content of §5.2 is that "Archer" and "Archer, with one thing
/// changed since" are different states that the user cannot otherwise tell
/// apart, and a second place that formatted the name would be a second place
/// for the suffix to go missing.
///
/// ⚠️ **`{}` and not `%@`, and that is not a drift.** The Swift side carries
/// `%@ (modified)` for the same sentence. Two formatting languages cannot
/// share one placeholder, and the agreed table names both spellings on
/// purpose; anybody who arrives meaning to unify them should read this line
/// first, because unifying them breaks one of the two sides.
pub fn display_name(name: &str, deviated: bool) -> String {
    if !deviated {
        return name.to_string();
    }
    // The brackets are the translator's to place -- in Chinese they are not
    // the ASCII ones -- so the whole phrase is one msgid rather than two
    // fragments joined here.
    tr("{} (modified)").replacen("{}", name, 1)
}

/// What §6 obliges the menu to say about *when* a pick takes effect.
///
/// `None` for a hot agent: there is nothing to say, and a note reading "now"
/// on every menu would train people to stop reading it.
pub fn effect_note(c: HostClass) -> Option<String> {
    match c {
        HostClass::Hot => None,
        // Warm changes through the CLI's own runtime interface rather than
        // MCP, and it does happen while the agent runs -- §6 lists it apart
        // from hot because the mechanism differs, not the timing.
        HostClass::Warm => None,
        HostClass::Cold => Some(tr("Takes effect the next time the agent starts")),
        // **A third sentence, and it must stay one.** Nothing has said which
        // CLI is in this terminal. Calling it hot would make "not yet in
        // force" look like "already switched"; calling it cold would send a
        // Claude Code user to restart for nothing.
        HostClass::Unknown => Some(tr("May need the agent to restart before it takes effect")),
    }
}

// ------------------------------------------------------------------- menu

/// What a picked row does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pick {
    /// Set this terminal's persona, or clear it with `None`.
    Set(Option<String>),
    /// Open the persona editor.
    Editor,
    /// A row that only says something. Greyed; picking it does nothing, and
    /// it exists so that the *reason* there is nothing to pick is on screen
    /// rather than the submenu being mysteriously short.
    Nothing,
}

/// One row of the persona submenu, ready for `AppendMenuW`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub text: String,
    pub separator: bool,
    pub checked: bool,
    pub enabled: bool,
    pub pick: Pick,
}

/// Where the persona rows' command ids live.
///
/// **Its own range, above both menus' static ones.** `ctxmenu.rs` owns
/// `0x4000` plus an index into its table and `menu.rs` owns `0x5000` plus an
/// index into its flattened tree; a list whose length is only known at run
/// time cannot take ids out of either without shifting every id after it,
/// which is the failure `menu::build` already refuses to risk in its `sub`
/// arm. A test below pins that neither table can grow into this.
pub const ID_BASE: usize = 0x6000;

/// The persona submenu for one terminal.
///
/// **Built fresh every time the menu opens and handed back to the caller**,
/// because the ids are indices into *this* vector. Rebuilding it at dispatch
/// time would be a second walk that could disagree with the first -- the
/// catalogue can change between the two, and the symptom would be a menu that
/// set the persona next to the one that was clicked.
///
/// **The two notes are rows, not suffixes on every persona.** Appending «takes
/// effect the next time the agent starts» to each of nine personas says it nine
/// times, and still leaves the phrase glued together out of a translated
/// fragment and some punctuation chosen here. One greyed row above the list
/// says it once, in one msgid whose words a translator can reorder.
pub fn entries(surface: Surface) -> Vec<Entry> {
    let st = standing(surface);
    let mut out: Vec<Entry> = Vec::new();

    let note = |text: String| Entry {
        text,
        separator: false,
        checked: false,
        // Greyed rather than absent: `menu.rs`'s `Enable` makes the argument,
        // and a sentence that can be clicked reads as a thing to do.
        enabled: false,
        pick: Pick::Nothing,
    };
    let sep = || Entry {
        text: String::new(),
        separator: true,
        checked: false,
        enabled: true,
        pick: Pick::Nothing,
    };

    // §3.5's error first of all, because it changes what the list below it
    // means. Without it, a `personas.json` with a syntax error shows the
    // catalogue that was loaded *last* time under a menu that says nothing --
    // or, worse, an empty one under «no roles are defined», which sends the
    // user to write a persona they have already written.
    // §3.5. **Our sentence is chosen by `error_kind`, never by reading the
    // core's message**; and for a kind this build does not know, there is no
    // sentence at all. The core's own text follows either way, because ours
    // says that something is wrong and only the core's says which line.
    if let Some((kind, text)) = &st.error {
        if let Some(lead) = error_lead_in(*kind) {
            out.push(note(lead));
        }
        if !text.is_empty() {
            out.push(note(text.clone()));
        }
    }

    // §3.2. A shielded terminal refuses every change, a supervisor included --
    // so every row that would change one is greyed, and **the reason is on
    // screen**. Greyed rows with no reason are the shape `menu.rs`'s `Enable`
    // exists to avoid: the user concludes the feature is broken.
    if st.shielded {
        out.push(note(tr("Agents are kept out of this terminal, so its role cannot be changed")));
    }

    // §5.3, because it changes how everything under it should be read: with
    // nothing connected, none of this is in force.
    if !st.agent_present {
        out.push(note(tr("No agent is connected here, so nothing is wearing this yet")));
    }
    // §6. Said once, above the list it applies to.
    if let Some(n) = effect_note(st.host_class) {
        out.push(note(n));
    }
    if !out.is_empty() {
        out.push(sep());
    }

    match catalogue(surface) {
        // **Not «there are no personas».** Nobody has been asked yet, and a menu
        // that answered the other question would be stating a fact about the
        // user's machine that it has not established. `plugins::Shipped`
        // records what collapsing those two cost the last time.
        //
        // The wording is the agreed table's, and the macOS side shows the
        // same sentence for the same state.
        Catalogue::NotWired => out.push(note(tr("Nothing has reported which roles exist yet"))),
        Catalogue::Empty => out.push(note(tr("No roles are defined"))),
        Catalogue::Personas(personas) => {
            // §5.2's "no persona" is a real choice and not the absence of one:
            // without a row for it, a terminal that has been given a persona
            // could never be given none again.
            out.push(Entry {
                text: tr("No Role"),
                separator: false,
                checked: st.key.is_none(),
                enabled: !st.shielded,
                pick: Pick::Set(None),
            });
            for r in personas {
                if !key_is_spellable(&r.key) {
                    // process-wide: a key the core let through that this host
                    // could not spell into a binding string. Said once per
                    // menu build rather than swallowed -- the row is still
                    // offered, and the action it sends will simply come back
                    // false, which on its own is indistinguishable from a
                    // feature nobody implemented.
                    // absence: proves nothing -- the ordinary case is that
                    // every key is spellable, so this line is silent on a
                    // healthy machine and on a machine where nobody opened
                    // the menu.
                    crate::plogf!(
                        "[persona] key {:?} is not [a-z0-9-]{{1,32}}; \
                         the action built from it will not parse",
                        r.key
                    );
                }
                let on = st.key.as_deref() == Some(r.key.as_str());
                // **The suffix goes only on the row that claims a state.**
                // §5.2 again: the deviation belongs to this terminal's
                // current persona, so putting it everywhere would say that every
                // persona had been modified.
                let text = if on { display_name(&r.name, st.deviated) } else { r.name.clone() };
                out.push(Entry {
                    text,
                    separator: false,
                    // §5.3: the persona is stored either way, but with no agent
                    // connected it is not in force -- and a tick is exactly
                    // the claim that it is.
                    checked: on && st.agent_present,
                    enabled: !st.shielded,
                    pick: Pick::Set(Some(r.key.clone())),
                });
            }
        }
    }

    out.push(sep());
    out.push(Entry {
        // ⚠️ **Three ASCII dots, because the agreed table has three.** This
        // catalogue already carries a pair of msgids differing only by `...`
        // against `…`: `po/zh_CN.po` has a comment on «Rename Tab...» saying
        // the two are different actions and must not be merged. So the
        // spelling here is copied rather than tidied.
        text: tr("Role Editor (beta)..."),
        separator: false,
        checked: false,
        enabled: true,
        pick: Pick::Editor,
    });
    out
}

/// Whether a persona key can be spelled into a binding string.
///
/// **`[a-z0-9-]`, 1 to 32.** The contract pins this, and it pins it because of
/// a gate in this crate rather than for looks: `menu.rs`'s
/// `action_strings_have_a_binding_shape` requires every character of an action
/// string to be `[a-z0-9_:,-]`, and a persona key goes into one. A key spelled
/// `Archer` produces a string that gate reddens on.
///
/// ⚠️ **This is not a second validator, and must not become one.** The
/// contract's ① puts the closed-set check in the core, and says why: two
/// readers means two validators, and the lax one wins. The core rejects a bad
/// key when it loads the file. This is the *gate* for the one path the core's
/// static checks cannot see -- the rows below are generated from the user's
/// file at the moment the menu opens, so `assert_actions_exist` and
/// `action_strings_have_a_binding_shape`, which walk the static tables, never
/// look at them. So a key that fails here is **said out loud** and still
/// offered: refusing it here would be this host deciding something §7 does not
/// let it decide.
pub fn key_is_spellable(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 32
        && key.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// The four action strings, §3.2. **The only place this host spells one.**
///
/// ⚠️ **`on,` / `off,` and not `+` / `-`.** The contract's v2 changed this,
/// and the reason is a gate in this crate: `menu.rs`'s
/// `action_strings_have_a_binding_shape` allows `[a-z0-9_:,-]`, so `-` passes
/// and `+` does not. With the old spelling «switch off» would have gone green
/// and «switch on» red -- and half-green is the state that reads most like
/// working.
pub fn action_set(key: &str) -> String {
    format!("poltergeist_persona_set:{key}")
}

/// §3.2. No parameter: clearing is one thing, not "set to nothing".
pub fn action_clear() -> String {
    "poltergeist_persona_clear".to_string()
}

/// §3.2, for one item of the effective set. `id` is the core's, verbatim.
pub fn action_toggle(kind: Kind, id: &str, on: bool) -> String {
    let what = match kind {
        Kind::Skill => "skill",
        Kind::Mcp => "mcp",
    };
    let state = if on { "on" } else { "off" };
    format!("poltergeist_persona_{what}:{state},{id}")
}

/// Whether an id from the core can be spelled into a binding string.
///
/// §0.5 mints ids as `<epoch>-<index>`, both decimal, and argues that they
/// therefore fall inside the gate's `[a-z0-9_:,-]` "by construction".
///
/// ⚠️ **"By construction" is a statement about the core, and this file is the
/// party that copies the id into the action string.** If the core ever writes
/// the epoch in hex, `8-3f` still passes the gate -- `f` is a lowercase
/// letter -- so nothing would go red, and the claim this host relies on would
/// have quietly stopped being the reason it is safe. Checked here so that the
/// day it changes is a line in a log rather than nothing at all.
///
/// Like [`key_is_spellable`], this **says so and still sends**: deciding what
/// the core may mint is not this host's to decide.
pub fn id_is_spellable(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|c| c.is_ascii_digit() || c == '-')
}

/// The label of the row the submenu hangs off.
///
/// **It carries the current persona**, because a submenu whose parent says only
/// «Role» makes the user open it to find out what this terminal is -- and
/// §5.2's whole point is that the answer has to be visible without acting.
///
/// **Task 666: `(beta)` on both branches.** 0.7's roles feature is not
/// finished, so every entry point says so. It is inside the translated
/// string itself -- `tr("Role (beta)")`, not `tr("Role")` with `" (beta)"`
/// appended after -- so a translator controls its wording the same way they
/// control every other word here, and never has to notice it was bolted on.
pub fn submenu_label(surface: Surface) -> String {
    let st = standing(surface);
    // §5.3. With nothing connected the persona is not in force, so the parent
    // states the heading and nothing more; what is stored is still in the
    // submenu, under a row that says why it is not being claimed.
    let Some(name) = st.name.as_deref().filter(|_| st.agent_present) else {
        return tr("Role (beta)");
    };
    // ⚠️ `{}` and not `%@`: see `display_name`. The Swift side carries
    // `Role (beta): %@` for this same sentence, deliberately.
    tr("Role (beta): {}").replacen("{}", &display_name(name, st.deviated), 1)
}

/// Perform one picked entry, on **one named terminal**.
///
/// ⚠️ **`surface` is an argument and is never resolved in here.** Both menus
/// already know which terminal they were opened for and both have got it
/// wrong before: `ctxmenu.rs`'s header records a right-click menu that acted
/// on the focused pane instead of the clicked one, invisible until somebody
/// had a split open. A lookup inside this function would put that decision
/// back in a third place.
///
/// `frame` is carried for the log line only.
pub fn perform(frame: windows::Win32::Foundation::HWND, surface: Surface, e: &Entry) -> bool {
    match &e.pick {
        // Greyed rows cannot be clicked, so reaching here means something
        // un-greyed one. Said out loud for the same reason `menu::run_host`
        // says it about its unbuilt row.
        Pick::Nothing => {
            crate::wlogf!(frame, "[persona] a row with nothing to do was picked: {:?}", e.text);
            false
        }
        Pick::Editor => {
            crate::personas_ui::request_toggle();
            true
        }
        Pick::Set(key) => {
            let action = match key.as_deref() {
                Some(k) => action_set(k),
                None => action_clear(),
            };
            let outcome = send(surface, &action);
            // **The outcome, not a bool.** §6 needs «done» and «at the next
            // launch» to stay apart the whole way out, and this line is the
            // only external evidence which of the two happened.
            crate::wlogf!(
                frame,
                "[persona] {} on surface {:?} -> {:?}",
                action,
                surface,
                outcome
            );
            matches!(outcome, SetOutcome::Applied | SetOutcome::AtNextLaunch)
        }
    }
}


// ------------------------------------------------------------ from the core

/// What one terminal's `mark` said about its persona, copied out of the C
/// struct while it was still valid.
///
/// ⚠️ **Copied, not borrowed.** `key` and `name` are valid for the duration of
/// the action callback and no longer -- the header says so, and it says so
/// because a port that stored the pointers would see nothing go wrong until
/// the next frame.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TabPersona {
    pub key: Option<String>,
    pub name: Option<String>,
    pub deviated: bool,
    pub agent_present: bool,
    pub host_class_raw: i32,
}

/// Read the `persona` pointer off a mark action. `None` when the core sent
/// null, which the header calls a bug rather than a state.
///
/// # Safety
/// The caller must be inside the action callback the mark arrived on.
pub unsafe fn persona_from_mark(action: &crate::ffi::Action) -> Option<TabPersona> {
    let p = action.as_poltergeist_persona();
    if p.is_null() {
        return None;
    }
    let m = unsafe { &*p };
    let cstr = |ptr: *const std::ffi::c_char| -> Option<String> {
        if ptr.is_null() {
            None
        } else {
            Some(unsafe { std::ffi::CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
        }
    };
    Some(TabPersona {
        key: cstr(m.key),
        name: cstr(m.name),
        deviated: m.deviated,
        agent_present: m.agent_present,
        host_class_raw: m.host_class,
    })
}

/// The face of one terminal, parsed out of §3.5's JSON.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Face {
    pub stale: bool,
    pub prompt: Option<String>,
    pub skills: Vec<Item>,
    pub mcp: Vec<Item>,
    pub error: Option<(ErrorKind, String)>,
}

/// Parse §3.5's face JSON.
///
/// **Anything unreadable comes back as `stale`**, not as an empty face: a
/// face we could not parse is one nobody has successfully reported, and the
/// sentence for that is already written. Returning `Default` instead would
/// say this terminal hands out nothing, which is a claim about the terminal
/// rather than about our reading of it.
pub fn parse_face(text: &str) -> Face {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else {
        return Face { stale: true, ..Default::default() };
    };
    let items = |key: &str, with_slot: bool| -> Vec<Item> {
        v.get(key)
            .and_then(|x| x.as_array())
            .map(|rows| {
                rows.iter()
                    .filter_map(|r| {
                        // **A row with no id is dropped, not given one.** The
                        // id is what goes into the action string; inventing
                        // one -- from the name, or from the position -- would
                        // send a click at whatever now sits there. A row the
                        // user cannot act on is better than a row that acts
                        // on something else.
                        let id = r.get("id")?.as_str()?.to_string();
                        Some(Item {
                            id,
                            name: r.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                            on: r.get("enabled").and_then(|x| x.as_bool()).unwrap_or(false),
                            in_persona: r
                                .get("in_persona")
                                .and_then(|x| x.as_bool())
                                .unwrap_or(false),
                            slot: if with_slot {
                                // **A missing or unknown `slot` is `None`, not
                                // `Granted`.** Guessing the friendly value
                                // here would draw a broken server as a
                                // working one.
                                r.get("slot").and_then(|x| x.as_str()).and_then(slot_from_wire)
                            } else {
                                None
                            },
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let error = v.get("error").and_then(|x| x.as_str()).map(|text| {
        let kind = v
            .get("error_kind")
            .and_then(|x| x.as_str())
            .map(ErrorKind::from_wire)
            .unwrap_or(ErrorKind::Unknown);
        (kind, text.to_string())
    });
    Face {
        stale: v.get("stale").and_then(|x| x.as_bool()).unwrap_or(false),
        prompt: v.get("prompt").and_then(|x| x.as_str()).map(|s| s.to_string()),
        // **Skills carry no `slot`**, and asking for one would invent a state
        // for something with no process behind it.
        skills: items("skills", false),
        mcp: items("mcp", true),
        error,
    }
}

fn slot_from_wire(s: &str) -> Option<SlotState> {
    match s {
        "transparent" => Some(SlotState::Transparent),
        "granted" => Some(SlotState::Granted),
        "withheld" => Some(SlotState::Withheld),
        "broken" => Some(SlotState::Broken),
        _ => None,
    }
}

/// Parse §3.4's installed-inventory JSON.
pub fn parse_inventory(text: &str) -> Inventory {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else {
        return Inventory::NotReported;
    };
    // `stale` is **not** an empty list; the header says so, and an interface
    // that collapses them tells the user nothing is installed here.
    if v.get("stale").and_then(|x| x.as_bool()).unwrap_or(true) {
        return Inventory::NotReported;
    }
    let section = |h: &serde_json::Value, key: &str| -> Section {
        let Some(sec) = h.get(key) else { return Section::UnknownLocation };
        let names = || -> Vec<String> {
            sec.get("items")
                .and_then(|x| x.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|i| i.get("name").and_then(|n| n.as_str()))
                        .map(|s| s.to_string())
                        .collect()
                })
                .unwrap_or_default()
        };
        match sec.get("status").and_then(|x| x.as_str()) {
            Some("absent") => Section::Absent,
            Some("read") => Section::Read(names()),
            Some("failed") => Section::Failed(
                sec.get("detail").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            ),
            // **`unknown_location` and anything unrecognised land together,
            // and that is the safe side**: it is the state that says "we did
            // not look", so a status this build has not heard of is reported
            // as our gap rather than as the machine having nothing.
            _ => Section::UnknownLocation,
        }
    };
    let hosts = v
        .get("hosts")
        .and_then(|x| x.as_array())
        .map(|a| {
            a.iter()
                .map(|h| HostInventory {
                    key: h.get("key").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                    label: h
                        .get("label")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string(),
                    plugins: section(h, "plugins"),
                    skills: section(h, "skills"),
                    mcp: section(h, "mcp"),
                })
                .collect()
        })
        .unwrap_or_default();
    Inventory::Known {
        hosts,
        complete: v
            .get("slot_budget")
            .and_then(|b| b.get("complete"))
            .and_then(|x| x.as_bool())
            // **Absent reads as incomplete**, because the sentence it turns on
            // only ever says "this count may be low" -- being wrong in that
            // direction costs a line on screen, the other direction costs the
            // user a number they believe.
            .unwrap_or(false),
    }
}


// ----------------------------------------------------------- the provider

/// Ask a core function that writes what fits and returns the real byte count.
///
/// **Two calls, never one with a hopeful buffer.** The first asks with
/// `cap = 0`, which the header makes legal for exactly this; the second
/// allocates the answer. Guessing a size and silently taking the truncation
/// is the failure the whole convention exists to stop -- and a truncated JSON
/// document does not fail to parse in an obvious way, it fails to parse at
/// all, which this host would then report as "nobody has said".
fn ask_json(mut call: impl FnMut(*mut u8, usize) -> usize) -> Option<String> {
    let need = call(std::ptr::null_mut(), 0);
    if need == 0 {
        return None;
    }
    // One more byte than the count, because the core writes a NUL after the
    // text when it fits. We read by length, but asking for less than it wants
    // to write means it writes nothing.
    let mut buf = vec![0u8; need + 1];
    let wrote = call(buf.as_mut_ptr(), buf.len());
    if wrote != need {
        // The answer changed between the two calls. **Not retried in a loop**
        // -- a loop here would spin on a terminal whose face is changing, and
        // the menu is rebuilt on every open anyway.
        // absence: proves nothing -- silent whenever the two calls agree,
        // which is every ordinary build of a menu.
        // process-wide: this is about the core's answer to a query, not about
        // any one window. `ask_json` is handed a closure and never learns
        // which terminal -- or whether a terminal is involved at all, since
        // the inventory query is app-scoped.
        crate::plogf!("[persona] the core's answer changed size between asking and reading");
        return None;
    }
    String::from_utf8(buf[..need].to_vec()).ok()
}

/// The provider that reads the running core.
pub struct CoreProvider;

impl CoreProvider {
    fn face(&self, surface: Surface) -> Face {
        if surface.is_null() {
            return Face { stale: true, ..Default::default() };
        }
        let Some(api) = crate::api_opt() else {
            return Face { stale: true, ..Default::default() };
        };
        match ask_json(|b, c| unsafe { (api.surface_persona_face)(surface, b, c) }) {
            Some(text) => parse_face(&text),
            // **Stale, not empty.** We failed to read it; that is not a fact
            // about what the terminal hands out.
            None => Face { stale: true, ..Default::default() },
        }
    }
}

impl Provider for CoreProvider {
    fn catalogue(&self, surface: Surface) -> Catalogue {
        let Some(api) = crate::api_opt() else { return Catalogue::NotWired };
        let app = crate::app_opt();
        if app.is_null() {
            return Catalogue::NotWired;
        }
        let n = unsafe { (api.app_personas)(app, std::ptr::null_mut(), 0) };
        if n == 0 {
            // **Which kind of nothing this is comes from the face**, §3.5's
            // `stale`. A count of zero on its own cannot tell «the file has
            // not been read» from «the file has no personas in it», and
            // guessing the second is what puts «no roles are defined» in
            // front of somebody whose file was never opened.
            return if self.face(surface).stale { Catalogue::NotWired } else { Catalogue::Empty };
        }
        let mut rows = vec![crate::ffi::PersonaRow { key: std::ptr::null(), name: std::ptr::null() }; n];
        let got = unsafe { (api.app_personas)(app, rows.as_mut_ptr(), n) };
        // **Copied here and nowhere later.** The header gives these strings
        // until the next call or the next config reload; a `&str` kept past
        // this loop would be a dangling one by the time a menu is on screen.
        let out: Vec<Persona> = rows
            .iter()
            .take(got.min(n))
            .filter_map(|r| {
                if r.key.is_null() || r.name.is_null() {
                    return None;
                }
                let key = unsafe { std::ffi::CStr::from_ptr(r.key) }.to_string_lossy().into_owned();
                let name =
                    unsafe { std::ffi::CStr::from_ptr(r.name) }.to_string_lossy().into_owned();
                Some(Persona { key, name, skills: Vec::new(), mcp: Vec::new(), prompt: None, hint: Vec::new() })
            })
            .collect();
        if out.is_empty() {
            return Catalogue::NotWired;
        }
        Catalogue::Personas(out)
    }

    fn standing(&self, surface: Surface) -> Standing {
        let face = self.face(surface);
        // The persona half of the mark, stored where every other mark bit is
        // stored -- `tabs.rs` -- rather than in a second copy here.
        let tp = crate::tabs::persona_for_surface(surface).unwrap_or_default();
        // §3.2's bit is already in today's mark, beside `role` and `held`.
        let shielded =
            crate::tabs::mark_for_surface(surface).map(|(_, s, ..)| s).unwrap_or(false);
        Standing {
            key: tp.key,
            name: tp.name,
            deviated: tp.deviated,
            agent_present: tp.agent_present,
            shielded,
            host_class: HostClass::from_c(tp.host_class_raw),
            error: face.error,
        }
    }

    fn send(&self, surface: Surface, action: &str) -> SetOutcome {
        if surface.is_null() {
            return SetOutcome::NotWired;
        }
        let Some(api) = crate::api_opt() else { return SetOutcome::NotWired };
        let ok = unsafe {
            (api.surface_binding_action)(surface, action.as_ptr(), action.len())
        };
        if !ok {
            // §0.5: the core refuses visibly -- it writes the reason into the
            // face and sends a mark, so the next read shows it. **False here
            // is not reported as a refusal of its own**, because the reason is
            // the core's to give and this host would otherwise be inventing
            // one.
            return SetOutcome::Refused;
        }
        // **Not `Applied`.** Whether it is in force now or at the agent's next
        // start is `host_class`'s answer, not this call's; saying `Applied`
        // here would be this host claiming something §6 says only the core
        // knows.
        match HostClass::from_c(
            crate::tabs::persona_for_surface(surface).unwrap_or_default().host_class_raw,
        ) {
            HostClass::Cold => SetOutcome::AtNextLaunch,
            _ => SetOutcome::Applied,
        }
    }

    fn effective(&self, surface: Surface) -> Handout {
        let f = self.face(surface);
        if f.stale {
            return Handout::NotReported;
        }
        Handout::Known { skills: f.skills, mcp: f.mcp }
    }

    fn installed(&self) -> Inventory {
        let Some(api) = crate::api_opt() else { return Inventory::NotReported };
        let app = crate::app_opt();
        if app.is_null() {
            return Inventory::NotReported;
        }
        match ask_json(|b, c| unsafe { (api.app_persona_hosts)(app, b, c) }) {
            Some(text) => parse_inventory(&text),
            None => Inventory::NotReported,
        }
    }
}

/// Install the provider that reads the core. Called once, at start-up.
pub fn install_core_provider() {
    set_provider(Box::new(CoreProvider));
    // process-wide: said once, so that a build where this was never reached
    // can be told apart from one where the core answers nothing.
    // absence: means it was not reached -- this line has no gate above it, so
    // a log without it is a start-up that never got here.
    crate::plogf!("[persona] reading the core");
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed {
        cat: Catalogue,
        st: Standing,
    }

    impl Provider for Fixed {
        fn catalogue(&self, _s: Surface) -> Catalogue {
            self.cat.clone()
        }
        fn standing(&self, _s: Surface) -> Standing {
            self.st.clone()
        }
        fn send(&self, _s: Surface, _a: &str) -> SetOutcome {
            SetOutcome::Applied
        }
        fn effective(&self, _s: Surface) -> Handout {
            Handout::default()
        }
        fn installed(&self) -> Inventory {
            Inventory::NotReported
        }
    }

    const NO_SURFACE: Surface = std::ptr::null_mut();

    fn persona(key: &str, name: &str) -> Persona {
        Persona {
            key: key.to_string(),
            name: name.to_string(),
            skills: Vec::new(),
            mcp: Vec::new(),
            prompt: None,
            hint: Vec::new(),
        }
    }

    /// Hold for the whole of a test that installs a provider. See
    /// `TEST_LOCK`.
    fn serialised() -> std::sync::MutexGuard<'static, ()> {
        TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn install(cat: Catalogue, st: Standing) {
        set_provider(Box::new(Fixed { cat, st }));
    }

    /// The floor under every test below: with nothing installed the answer is
    /// the third state, and **not** an empty catalogue.
    ///
    /// ⚠️ Run on its own. `set_provider` is process-wide and the tests in this
    /// module share a process, so this asserts the distinction rather than
    /// the initial value -- an initial-value test would pass or fail on test
    /// ordering, which is the shape that looks flaky rather than wrong.
    #[test]
    fn not_wired_is_not_the_same_as_empty() {
        assert_ne!(Catalogue::NotWired, Catalogue::Empty);
        assert_ne!(Catalogue::Empty, Catalogue::Personas(Vec::new()));
    }

    /// §6, and §3.1.1's rule about zero values.
    ///
    /// **The unrecognised case is the point.** A decoder that mapped an
    /// unknown number onto `Hot` would draw a cold agent as one that had
    /// already switched -- which is the one sentence §6 forbids -- and it
    /// would do it only for a class invented after this build, which is
    /// exactly when nobody is looking.
    #[test]
    fn an_unrecognised_host_class_decodes_to_unknown_and_not_to_hot() {
        assert_eq!(HostClass::from_c(0), HostClass::Unknown);
        assert_eq!(HostClass::from_c(1), HostClass::Hot);
        assert_eq!(HostClass::from_c(2), HostClass::Warm);
        assert_eq!(HostClass::from_c(3), HostClass::Cold);
        for stray in [4, 99, -1, i32::MIN, i32::MAX] {
            assert_eq!(HostClass::from_c(stray), HostClass::Unknown, "{stray}");
        }
    }

    /// The three sentences §6 needs, and that they are three.
    #[test]
    fn each_class_says_its_own_thing_and_hot_says_nothing() {
        assert!(effect_note(HostClass::Hot).is_none());
        let cold = effect_note(HostClass::Cold);
        let unknown = effect_note(HostClass::Unknown);
        assert!(cold.is_some() && unknown.is_some());
        // Folding `unknown` into `cold` is what the agreed table added a
        // third sentence to stop.
        assert_ne!(cold, unknown);
    }

    /// §5.2. The suffix is the only difference between the two states, so a
    /// build where it went missing has to fail here.
    #[test]
    fn a_deviated_role_does_not_render_as_the_role() {
        let plain = display_name("Archer", false);
        let moved = display_name("Archer", true);
        assert_eq!(plain, "Archer");
        assert_ne!(plain, moved);
        assert!(moved.contains("Archer"), "{moved}");
        // The placeholder is consumed. A msgid whose `%s` survived would put
        // the literal two characters on screen.
        assert!(!moved.contains("%s"), "{moved}");
    }

    /// §5.3. No agent connected: the persona is still listed and still known,
    /// and **nothing claims it is in force**.
    #[test]
    fn with_no_agent_connected_nothing_ticks_and_the_parent_says_only_role() {
        let _g = serialised();
        install(
            Catalogue::Personas(vec![persona("archer", "Archer")]),
            Standing {
                key: Some("archer".into()),
                name: Some("Archer".into()),
                deviated: false,
                agent_present: false,
                shielded: false,
            host_class: HostClass::Hot,
            error: None,
            },
        );
        assert_eq!(submenu_label(NO_SURFACE), tr("Role (beta)"));
        let e = entries(NO_SURFACE);
        assert!(
            e.iter().all(|x| !x.checked),
            "a tick is the claim the persona is in force: {e:?}"
        );
        // It is still there to be read, which is the other half of §5.3.
        assert!(e.iter().any(|x| x.text.contains("Archer")), "{e:?}");
    }

    /// The same terminal with an agent on it: the parent carries the name and
    /// the row ticks.
    #[test]
    fn with_an_agent_the_parent_carries_the_name_and_the_row_ticks() {
        let _g = serialised();
        install(
            Catalogue::Personas(vec![persona("archer", "Archer")]),
            Standing {
                key: Some("archer".into()),
                name: Some("Archer".into()),
                deviated: false,
                agent_present: true,
                shielded: false,
            host_class: HostClass::Hot,
            error: None,
            },
        );
        assert!(submenu_label(NO_SURFACE).contains("Archer"));
        let e = entries(NO_SURFACE);
        let ticked: Vec<&Entry> = e.iter().filter(|x| x.checked).collect();
        assert_eq!(ticked.len(), 1, "{e:?}");
        assert_eq!(ticked[0].pick, Pick::Set(Some("archer".into())));
    }

    /// §5.2 once more, through the menu rather than through the formatter:
    /// the deviation reaches the row and the parent, and it reaches **only**
    /// the persona that is set.
    #[test]
    fn the_deviation_marks_the_set_role_and_not_the_others() {
        let _g = serialised();
        install(
            Catalogue::Personas(vec![persona("archer", "Archer"), persona("scribe", "Scribe")]),
            Standing {
                key: Some("archer".into()),
                name: Some("Archer".into()),
                deviated: true,
                agent_present: true,
                shielded: false,
            host_class: HostClass::Hot,
            error: None,
            },
        );
        let marker = display_name("", true);
        assert!(submenu_label(NO_SURFACE).contains(marker.trim()), "{marker:?}");
        let e = entries(NO_SURFACE);
        let archer = e.iter().find(|x| x.pick == Pick::Set(Some("archer".into()))).unwrap();
        let scribe = e.iter().find(|x| x.pick == Pick::Set(Some("scribe".into()))).unwrap();
        assert_ne!(archer.text, "Archer");
        assert_eq!(scribe.text, "Scribe");
    }

    /// §6, and it is the note row that carries it.
    ///
    /// **Three cells, not two.** A test with only cold and hot would pass on
    /// a build that folded `unknown` into either of them, and folding it is
    /// the exact thing the agreed table added a third sentence to stop.
    #[test]
    fn each_host_class_puts_its_own_sentence_on_the_menu_and_hot_puts_none() {
        let _g = serialised();
        let with = |host: HostClass| {
            install(
                Catalogue::Personas(vec![persona("archer", "Archer")]),
                Standing {
                    key: None,
                    name: None,
                    deviated: false,
                    // True, so the §5.3 note is not also present and this
                    // test is looking at one sentence rather than two.
                    agent_present: true,
                    shielded: false,
                    host_class: host,
                    error: None,
                },
            );
            entries(NO_SURFACE)
        };
        let texts = |v: &Vec<Entry>| v.iter().map(|e| e.text.clone()).collect::<Vec<_>>();

        let cold = effect_note(HostClass::Cold).unwrap();
        let unknown = effect_note(HostClass::Unknown).unwrap();
        assert_ne!(cold, unknown, "folding unknown into cold is what this stops");

        assert!(texts(&with(HostClass::Cold)).contains(&cold));
        assert!(texts(&with(HostClass::Unknown)).contains(&unknown));

        // The floor: on a hot agent **neither** sentence appears. Without
        // this, a build that pasted both notes onto every menu would pass
        // both assertions above.
        let hot = texts(&with(HostClass::Hot));
        assert!(!hot.contains(&cold) && !hot.contains(&unknown), "{hot:?}");
    }

    /// The three catalogue states produce three different menus, and the two
    /// with no personas produce **different sentences**. One says nothing has
    /// reported, the other says the user has defined none; collapsing them is
    /// the `plugins::Shipped` defect this enum exists to avoid.
    #[test]
    fn the_empty_menu_says_which_kind_of_empty_it_is() {
        let _g = serialised();
        // Connected and hot, so the two note rows are absent and the first
        // row is the catalogue's own answer rather than a note about
        // something else. Without this the test would be reading §5.3's
        // sentence and passing whatever the catalogue said.
        let here = Standing {
            key: None,
            name: None,
            deviated: false,
            agent_present: true,
            shielded: false,
            host_class: HostClass::Hot,
            error: None,
        };
        install(Catalogue::NotWired, here.clone());
        let a = entries(NO_SURFACE);
        install(Catalogue::Empty, here.clone());
        let b = entries(NO_SURFACE);
        assert_ne!(a[0].text, b[0].text, "{:?} / {:?}", a[0].text, b[0].text);
        // Neither is pickable, and both say so by being greyed rather than by
        // being absent -- `menu.rs`'s `Enable` makes the same argument.
        assert!(!a[0].enabled && !b[0].enabled);
        assert_eq!(a[0].pick, Pick::Nothing);
        assert_eq!(b[0].pick, Pick::Nothing);
    }

    /// The editor row is always reachable, including from a build that can
    /// answer nothing else. It is the only way in on a machine where the
    /// catalogue is empty, so losing it would be losing the way to fix that.
    #[test]
    fn the_editor_row_is_there_in_every_state() {
        let _g = serialised();
        for cat in [Catalogue::NotWired, Catalogue::Empty, Catalogue::Personas(Vec::new())] {
            install(cat.clone(), Standing::unknown());
            let e = entries(NO_SURFACE);
            assert_eq!(e.last().map(|x| x.pick.clone()), Some(Pick::Editor), "{cat:?}");
            assert!(e.last().unwrap().enabled);
        }
    }

    /// The charset the contract pins, and **the negative cases are the
    /// point**: a predicate that only accepted the good ones would pass while
    /// accepting everything.
    ///
    /// Each rejected spelling below is one that produces an action string
    /// `menu.rs`'s `action_strings_have_a_binding_shape` reddens on -- which
    /// is the reason the charset is this and not something wider.
    #[test]
    fn a_key_is_only_spellable_if_the_binding_gate_would_take_it() {
        for good in ["archer", "a", "read-only-recon", "x9", &"a".repeat(32)] {
            assert!(key_is_spellable(good), "{good:?}");
        }
        for bad in [
            "",                 // nothing to name
            "Archer",           // capitals
            "my_persona",       // underscore: allowed in an action string, not in a key
            "射手",             // not ASCII at all
            "a b",              // a space, which the gate rejects by name
            "a:b",              // the separator itself
            "a,b",              // the other separator
            "+on",              // the prefix the contract puts before a name
            &"a".repeat(33),    // one over
        ] {
            assert!(!key_is_spellable(bad), "{bad:?}");
        }

        // **The floor, and it is the whole reason the charset is this one.**
        // Every accepted key, spelled into the action the contract gives,
        // must satisfy `menu.rs`'s predicate character for character. If that
        // predicate is ever widened, this stops being a constraint and
        // somebody should know.
        let gate = |a: &str| {
            !a.contains(' ')
                && a.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "_:,-".contains(c))
        };
        assert!(gate("poltergeist_persona_set:archer"));
        assert!(gate("poltergeist_persona_clear"));
        // And the negative control for the gate itself: it does reject.
        assert!(!gate("poltergeist_persona_set:Archer"));
    }

    /// §3.2. A shielded terminal refuses every change, **and the menu says so
    /// rather than going quiet.**
    ///
    /// The floor is the second half: the same catalogue unshielded must offer
    /// the same rows live. Without it, a build that greyed every row always --
    /// or that dropped them -- would pass the first half.
    #[test]
    fn a_shielded_terminal_greys_everything_that_would_change_it_and_says_why() {
        let _g = serialised();
        let with = |shielded: bool| {
            install(
                Catalogue::Personas(vec![persona("archer", "Archer")]),
                Standing {
                    key: None,
                    name: None,
                    deviated: false,
                    agent_present: true,
                    shielded,
                    host_class: HostClass::Hot,
                    error: None,
                },
            );
            entries(NO_SURFACE)
        };

        let on = with(true);
        let settable: Vec<&Entry> = on.iter().filter(|e| matches!(e.pick, Pick::Set(_))).collect();
        assert!(!settable.is_empty(), "the rows must still be there: {on:?}");
        assert!(settable.iter().all(|e| !e.enabled), "{on:?}");
        // **Greyed with a reason.** `menu.rs`'s `Enable` makes the argument:
        // a greyed row with nothing saying why reads as a broken feature.
        let why = tr("Agents are kept out of this terminal, so its role cannot be changed");
        assert!(on.iter().any(|e| e.text == why), "{on:?}");
        // The editor row stays live: it is how the user reads what is set,
        // and reading is not changing.
        assert!(on.last().unwrap().enabled);

        let off = with(false);
        assert!(
            off.iter().filter(|e| matches!(e.pick, Pick::Set(_))).all(|e| e.enabled),
            "{off:?}"
        );
        assert!(!off.iter().any(|e| e.text == why), "{off:?}");
    }

    /// §3.5. **A file that failed to parse must not be drawn as a catalogue
    /// with nothing in it.**
    ///
    /// This is the one the contract calls out by name: with no error row,
    /// W3's «no roles are defined» takes the blame for a syntax error, and the
    /// user goes off to write a persona that is already in the file.
    #[test]
    fn a_broken_file_is_not_drawn_as_a_catalogue_with_nothing_in_it() {
        let _g = serialised();
        let stand = |error| Standing {
            key: None,
            name: None,
            deviated: false,
            agent_present: true,
            shielded: false,
            host_class: HostClass::Hot,
            error,
        };
        install(Catalogue::Empty, stand(None));
        let clean = entries(NO_SURFACE);
        install(
            Catalogue::Empty,
            stand(Some((ErrorKind::Parse, "line 4: expected ','".to_string()))),
        );
        let broken = entries(NO_SURFACE);

        // Both say «no roles are defined» -- that part is true either way.
        let none_defined = tr("No roles are defined");
        assert!(clean.iter().any(|e| e.text == none_defined));
        assert!(broken.iter().any(|e| e.text == none_defined));
        // And only one of them says why the list may be lying.
        assert!(broken.len() > clean.len(), "{broken:?}");
        // **The core's own sentence reaches the screen**, not just our
        // paraphrase of it. Without this the user has our wording and no way
        // to find the line.
        assert!(broken.iter().any(|e| e.text.contains("line 4")), "{broken:?}");
    }

    /// The four action strings, and **that the gate would take every one of
    /// them**.
    ///
    /// ⚠️ The `on,` / `off,` spelling is the whole point of this test. The
    /// contract's first draft used `+` / `-`, and `+` is not in the gate's
    /// character set while `-` is -- so «switch off» would have passed and
    /// «switch on» failed, which is the half-green that reads most like a
    /// working feature.
    #[test]
    fn every_action_this_host_spells_would_pass_the_binding_gate() {
        // `menu.rs`'s predicate, rebuilt here so this test fails if that one
        // is ever widened -- at which point this stops being a constraint and
        // somebody should find out from a red test rather than from a menu.
        let gate = |a: &str| {
            !a.is_empty()
                && !a.contains(' ')
                && a.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "_:,-".contains(c))
        };
        // The negative control for the gate itself: it does reject something.
        assert!(!gate("poltergeist_persona_set:Archer"));
        assert!(!gate("poltergeist_persona_skill:+8-3"));

        let all = [
            action_set("archer"),
            action_clear(),
            action_toggle(Kind::Skill, "8-3", true),
            action_toggle(Kind::Skill, "8-3", false),
            action_toggle(Kind::Mcp, "12-0", true),
            action_toggle(Kind::Mcp, "12-0", false),
        ];
        for a in &all {
            assert!(gate(a), "{a:?}");
        }
        // The names before the `:` are the four the contract names, and they
        // are what `assert_actions_exist` compares against the core's union.
        let names: Vec<&str> = all.iter().map(|a| a.split(':').next().unwrap()).collect();
        for want in [
            "poltergeist_persona_set",
            "poltergeist_persona_clear",
            "poltergeist_persona_skill",
            "poltergeist_persona_mcp",
        ] {
            assert!(names.contains(&want), "{want} missing from {names:?}");
        }
        // On and off differ in the prefix and nowhere else -- one switch, two
        // spellings, which is why the contract did not make them two actions.
        assert_eq!(action_toggle(Kind::Skill, "8-3", true), "poltergeist_persona_skill:on,8-3");
        assert_eq!(action_toggle(Kind::Skill, "8-3", false), "poltergeist_persona_skill:off,8-3");
    }

    /// The id guard, **negative cases first** for the same reason
    /// `key_is_spellable`'s are: a predicate that only accepted the good ones
    /// would accept everything.
    #[test]
    fn an_id_is_only_the_shape_the_contract_mints() {
        for good in ["8-3", "0-0", "12-0", "18446744073709551615-7"] {
            assert!(id_is_spellable(good), "{good:?}");
        }
        for bad in [
            "",      // nothing at all
            "8_3",   // the separator the contract did not pick
            "8-3f",  // a hex epoch: passes the binding gate, is not this shape
            "argus", // a name where an id should be
            "8 3",   // a space, which the gate rejects by name
            "+8-3",  // the prefix the first draft of the contract used
        ] {
            assert!(!id_is_spellable(bad), "{bad:?}");
        }
    }

    // ---------------------------------------------------- reading the core

    /// The core's own source, baked in.
    ///
    /// **Read out of the core rather than copied into this file**, the same
    /// trick `menu.rs` uses for `Binding.zig`. A literal pasted here would be
    /// a transcription, and a transcription can only ever be diffed against
    /// itself: the day the core changes its answer, a hand-copied fixture
    /// keeps passing and keeps testing last week's core.
    const EMBEDDED_ZIG: &str = include_str!("../../../src/apprt/embedded.zig");

    /// Pull the JSON literal a stub export answers with, out of the Zig
    /// multiline string that follows it.
    fn stub_json(after_fn: &str) -> String {
        let at = EMBEDDED_ZIG.find(after_fn).expect("the export is in the core");
        let rest = &EMBEDDED_ZIG[at..];
        let mut out = String::new();
        for line in rest.lines() {
            let t = line.trim_start();
            if let Some(body) = t.strip_prefix("\\\\") {
                out.push_str(body);
                continue;
            }
            if !out.is_empty() {
                break;
            }
        }
        assert!(out.starts_with('{'), "{after_fn}: found {out:?}");
        out
    }

    /// **The floor under the two tests below.** If the extractor stops finding
    /// the literal it would hand them an empty string, both would parse it as
    /// unreadable, and "the core answers nothing" is a result those tests are
    /// allowed to report -- so the failure would look like a finding.
    #[test]
    fn the_core_literals_are_found_and_are_json() {
        for f in ["ghostty_surface_persona_face", "ghostty_app_persona_hosts"] {
            let s = stub_json(f);
            assert!(s.len() > 10, "{f}: {s:?}");
            serde_json::from_str::<serde_json::Value>(&s).unwrap_or_else(|e| panic!("{f}: {e}"));
        }
    }

    /// The literal the face export still carries is its **render-failure**
    /// answer, and this pins that this host reads it correctly.
    ///
    /// ⚠️ **This test used to assert the opposite**, because that literal used
    /// to be the whole of the function: a stub with no persona, no rows and
    /// no error. The core now renders the face for real and the literal that
    /// remains is the `catch` arm. **The test noticed** -- which is the entire
    /// reason it reads the core's source instead of a copy pasted in here.
    ///
    /// The case it now covers is the interesting one anyway: `render` is an
    /// `error_kind` this build has never been taught, so it must get **no
    /// sentence of ours** and still show the core's own.
    #[test]
    fn the_cores_render_failure_answer_is_read_without_being_explained_away() {
        let f = parse_face(&stub_json("ghostty_surface_persona_face"));
        // Not an empty face. Drawing "you have nothing" would be a lie the
        // interface could not detect.
        assert!(f.stale);
        assert!(f.skills.is_empty() && f.mcp.is_empty());
        let (kind, text) = f.error.expect("the render failure names itself");
        assert_eq!(kind, ErrorKind::Unknown, "this build has never heard of `render`");
        assert_eq!(error_lead_in(kind), None, "so it invents no sentence");
        assert!(!text.is_empty(), "and the core's own words still reach the screen");
    }

    /// The inventory the core answers with today: `stale`, which **must not**
    /// become an empty list on the way in.
    #[test]
    fn todays_inventory_from_the_core_is_not_reported_rather_than_empty() {
        let inv = parse_inventory(&stub_json("ghostty_app_persona_hosts"));
        assert_eq!(inv, Inventory::NotReported);
        assert_ne!(inv, Inventory::Known { hosts: Vec::new(), complete: true });
    }

    /// The shape the core produces **once a persona is loaded**, as W1 posted
    /// it. Not the contract's example -- the contract's example is a
    /// specification and this is what the program emits.
    const REAL_FACE: &str = concat!(
        r#"{"key":"archer","name":"Archer","deviated":false,"epoch":1,"roster":1,"#,
        r#""agent_present":true,"host_class":"unknown","prompt":null,"#,
        r#""skills":[{"id":"1-0","name":"reading-a-terminal","enabled":true,"in_persona":true}],"#,
        r#""mcp":[{"id":"1-0","name":"argus","enabled":true,"in_persona":true,"slot":"withheld"}],"#,
        r#""error":null,"error_kind":null,"stale":false}"#
    );

    #[test]
    fn a_loaded_face_parses_into_rows_that_can_be_acted_on() {
        let f = parse_face(REAL_FACE);
        assert!(!f.stale);
        assert_eq!(f.skills.len(), 1);
        assert_eq!(f.mcp.len(), 1);

        let skill = &f.skills[0];
        assert_eq!(skill.id, "1-0");
        assert_eq!(skill.name, "reading-a-terminal");
        assert!(skill.on && skill.in_persona);
        // **A skill has no slot**, and asking the core for one would be
        // asking about a process that does not exist.
        assert_eq!(skill.slot, None);
        // The id survives into the action string, verbatim.
        assert_eq!(action_toggle(Kind::Skill, &skill.id, false), "poltergeist_persona_skill:off,1-0");

        let mcp = &f.mcp[0];
        assert_eq!(mcp.slot, Some(SlotState::Withheld));
        assert_eq!(action_toggle(Kind::Mcp, &mcp.id, true), "poltergeist_persona_mcp:on,1-0");
        // Both ids are `1-0` and the two actions are still different, because
        // the kind is in the action name. A single id space would have made
        // these collide.
        assert_ne!(
            action_toggle(Kind::Skill, &skill.id, true),
            action_toggle(Kind::Mcp, &mcp.id, true)
        );
    }

    /// ⚠️ **A row with no id is dropped, not given one.**
    ///
    /// The id is what goes into the action string. Falling back to the name,
    /// or to the position, would send a click at whatever now sits there --
    /// and a row the user cannot act on is much better than a row that acts
    /// on something else.
    #[test]
    fn a_row_without_an_id_is_dropped_rather_than_given_one() {
        let f = parse_face(
            r#"{"stale":false,"skills":[{"name":"nameless","enabled":true,"in_persona":true},
                 {"id":"1-1","name":"fine","enabled":true,"in_persona":true}],"mcp":[]}"#,
        );
        assert_eq!(f.skills.len(), 1);
        assert_eq!(f.skills[0].name, "fine");
    }

    /// An unreadable face is **stale**, not empty. Those are different claims:
    /// one is about our reading, the other about the terminal.
    #[test]
    fn an_unparseable_face_is_stale_and_not_a_terminal_that_hands_out_nothing() {
        for bad in ["", "not json", "{", "[]"] {
            let f = parse_face(bad);
            assert!(f.stale || f.skills.is_empty(), "{bad:?}");
        }
        assert!(parse_face("not json").stale);
    }

    /// ⚠️ **An unknown `slot` is `None`, never `Granted`.** Guessing the
    /// friendly value would draw a server that is not running as one that is.
    #[test]
    fn an_unknown_slot_state_is_not_guessed_to_be_the_working_one() {
        let f = parse_face(
            r#"{"stale":false,"skills":[],"mcp":[
                 {"id":"1-0","name":"a","enabled":true,"in_persona":true,"slot":"quantum"},
                 {"id":"1-1","name":"b","enabled":true,"in_persona":true}]}"#,
        );
        assert_eq!(f.mcp[0].slot, None);
        assert_eq!(f.mcp[1].slot, None);
        // And the four it does know decode to four different things.
        let one = |s: &str| {
            parse_face(&format!(
                r#"{{"stale":false,"skills":[],"mcp":[{{"id":"1-0","name":"a","enabled":true,"in_persona":true,"slot":"{s}"}}]}}"#
            ))
            .mcp[0]
                .slot
        };
        assert_eq!(one("transparent"), Some(SlotState::Transparent));
        assert_eq!(one("granted"), Some(SlotState::Granted));
        assert_eq!(one("withheld"), Some(SlotState::Withheld));
        assert_eq!(one("broken"), Some(SlotState::Broken));
    }

    /// §3.5's error channel, **including a kind this build has never heard
    /// of**.
    ///
    /// `render` is real -- the core gained it after this host was written --
    /// and it is exactly the case the rule was made for: no sentence of ours,
    /// the core's text shown anyway. A build that invented a lead-in for it
    /// would put a confident explanation in front of an error it cannot
    /// explain, and the user would read ours instead of the core's.
    #[test]
    fn an_error_kind_this_build_does_not_know_still_shows_the_cores_words() {
        let f = parse_face(
            r#"{"stale":false,"skills":[],"mcp":[],"error":"line 4: expected ','","error_kind":"render"}"#,
        );
        let (kind, text) = f.error.expect("an error");
        assert_eq!(kind, ErrorKind::Unknown);
        assert_eq!(error_lead_in(kind), None, "no sentence of ours");
        assert_eq!(text, "line 4: expected ','", "the core's own words survive");

        // The two it does know each get their own sentence, and the two
        // sentences are different.
        assert_eq!(ErrorKind::from_wire("parse"), ErrorKind::Parse);
        assert_eq!(ErrorKind::from_wire("stale_id"), ErrorKind::StaleId);
        assert_ne!(error_lead_in(ErrorKind::Parse), error_lead_in(ErrorKind::StaleId));
        assert!(error_lead_in(ErrorKind::Parse).is_some());
    }

    /// §4.3's rendering rule: **two of the four states speak, two do not.**
    ///
    /// `granted` and `withheld` say nothing because the checkbox beside them
    /// already does. On a build where every slot is `withheld` -- which is
    /// today's -- a sentence on every row would bury `broken`, and burying
    /// `broken` is the one outcome §4.3 exists to prevent.
    #[test]
    fn only_broken_and_transparent_say_anything_beside_a_row() {
        let row = |slot: SlotState| Item {
            id: "1-0".into(),
            name: "argus".into(),
            on: true,
            in_persona: true,
            slot: Some(slot),
        };
        assert_eq!(row(SlotState::Granted).aside(), "");
        assert_eq!(row(SlotState::Withheld).aside(), "");
        assert!(!row(SlotState::Broken).aside().is_empty());
        assert!(!row(SlotState::Transparent).aside().is_empty());
        assert_ne!(row(SlotState::Broken).aside(), row(SlotState::Transparent).aside());
    }

    /// The ids these rows take cannot collide with either menu's own.
    ///
    /// **Both bounds are computed from the tables, not written down.** A
    /// number copied out of `menu.rs` would agree until that table grew.
    #[test]
    fn the_persona_ids_are_above_everything_both_menus_can_reach() {
        assert!(ID_BASE > crate::ctxmenu::max_static_id(), "{ID_BASE:#x}");
        assert!(ID_BASE > crate::menu::max_static_id(), "{ID_BASE:#x}");
        // And below the range `TrackPopupMenu` will not carry: ids are an
        // `i32` out of the call and the high end is where system commands
        // live.
        assert!(ID_BASE + 512 < 0xF000);
    }
}
