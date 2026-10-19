//! The pages of a project while the host has it in hand: which page of the
//! file each open tab is, where each sits, and what a save makes of the
//! tabs that are open and the pages that are not.

use std::collections::{BTreeMap, BTreeSet};

use polter_projectfile::{leaves, leaves_mut, Agent, Frame, PaneColor, SavedLeaf, SavedNode, Snapshot, Tab, Who, Window, Workers};

/// A page's name for as long as the host has the project in hand.
pub type PageId = usize;

/// Which window on screen a tab is in: any number that is the same for the
/// tabs of one window and differs between windows.
pub type WindowToken = isize;

#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub id: PageId,
    pub tab: Tab,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PagesWindow {
    pub frame: Option<Frame>,
    /// The id of the page that is in front. Always one of `pages`.
    pub front: PageId,
    /// Never empty.
    pub pages: Vec<Page>,
}

/// The pages of one project, each with an id that lasts as long as the host
/// has the project in hand.
///
/// **Why a page has an id here when the file has none.** In the file a page
/// is a position: the third tab of the first window. That cannot say which
/// open tab is which page once a tab is dragged, closed or put in another
/// window -- a position quietly starts naming a different page. So a page is
/// given an id when the file is read, an open tab holds the id of its page,
/// and positions are worked out again from where the tabs are at every save
/// (`updated`). The id is never written.
///
/// **A page that is not open stays.** Closing a tab is not taking it out of
/// the project: its page keeps the layout it was last saved with, and comes
/// back when the project is opened again. Only `remove` takes a page out.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Pages {
    windows: Vec<PagesWindow>,
    next_id: PageId,
}

/// One open tab of the project, as a save finds it.
#[derive(Clone, Debug, PartialEq)]
pub struct Live {
    /// The page it is.
    pub id: PageId,
    pub window: WindowToken,
    /// Where it stands among that window's tabs. Only the order matters;
    /// tabs that are not the project's leave gaps.
    pub index: usize,
    /// Whether it is the tab showing in its window.
    pub selected: bool,
    pub root: SavedNode,
    /// The name somebody gave the tab on this host (`title_override` on
    /// Windows, whoever pinned it), or `None` for none said. **Not the
    /// program's title**: that is written per pane, as what it showed, and
    /// is never put back (`apprt/title.zig`, issue #9).
    ///
    /// `None` does not overwrite the name the file has for the page
    /// (`saving`): a page opened from the file is named back right after its
    /// tab is made (`restored_name`), and a save that came first must not
    /// write "no name" over the one it is about to get. This host has no way
    /// to take a chosen name off a tab, so "said none" never has to beat
    /// the file's word; **a host that adds one must make this a third
    /// state** rather than let `None` mean both.
    pub title: Option<String>,
}

/// What a save finds on screen: the open tabs, the frame of each window
/// they are in, and whether it is a closing tab's save (see `updated`).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Screen {
    pub live: Vec<Live>,
    pub frames: BTreeMap<WindowToken, Frame>,
    pub keeping_front: bool,
}

/// What the file says of a pane that a save may not be able to say again.
#[derive(Clone, Debug, PartialEq)]
pub struct Known {
    /// Where it was working; empty when the file did not say.
    pub cwd: String,
    /// Who was in it; `Unknown` when the file did not say.
    pub agent: Agent,
    /// Whether the project's supervisor opened it as a worker. Once it was,
    /// it stays so: the agent leaving does not undo it (#1495), and a save
    /// that cannot tell -- no supervisor in the project right now -- is not
    /// a "no" (`keeping_what_the_file_knew`).
    pub by_supervisor: bool,
    /// The four marks of format 3, as the file has them: a file always
    /// says, so these are never "not known" (a format 2 file says the
    /// defaults, and its supervisor's pane is the seat).
    pub supervisor_seat: bool,
    pub color: PaneColor,
    pub workers: Workers,
    pub shielded: bool,
}

impl Pages {
    /// A project with no page yet.
    pub fn new() -> Pages {
        Pages::default()
    }

    /// The pages of `file`, none of them open.
    pub fn from_file(file: &Snapshot) -> Pages {
        let mut next = 0;
        let windows = file
            .windows
            .iter()
            .filter_map(|window| {
                let pages: Vec<Page> = window
                    .tabs
                    .iter()
                    .map(|tab| {
                        let page = Page { id: next, tab: tab.clone() };
                        next += 1;
                        page
                    })
                    .collect();
                let first = pages.first()?.id;
                let front = pages.get(window.front).map_or(first, |p| p.id);
                Some(PagesWindow { frame: window.frame, front, pages })
            })
            .collect();
        Pages { windows, next_id: next }
    }

    /// An id for a page that is being added. The page itself arrives with
    /// the next `updated`, as a tab that is open.
    pub fn new_page_id(&mut self) -> PageId {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    pub fn windows(&self) -> &[PagesWindow] {
        &self.windows
    }

    /// What goes in the file.
    pub fn file_windows(&self) -> Vec<Window> {
        self.windows
            .iter()
            .map(|window| Window {
                frame: window.frame,
                front: window.pages.iter().position(|p| p.id == window.front).unwrap_or(0),
                tabs: window.pages.iter().map(|p| p.tab.clone()).collect(),
            })
            .collect()
    }

    pub fn page_ids(&self) -> Vec<PageId> {
        self.windows.iter().flat_map(|w| w.pages.iter().map(|p| p.id)).collect()
    }

    pub fn page(&self, id: PageId) -> Option<&Page> {
        self.windows.iter().flat_map(|w| w.pages.iter()).find(|p| p.id == id)
    }

    /// Every snapshot name any page refers to, open or not -- what a save
    /// must count as taken and must not prune.
    pub fn scrollback_names(&self) -> Vec<String> {
        self.windows
            .iter()
            .flat_map(|w| w.pages.iter())
            .flat_map(|p| leaves(&p.tab.root).into_iter().filter(|l| !l.scrollback.is_empty()).map(|l| l.scrollback.clone()))
            .collect()
    }

    /// Take a page out of the project. Its window goes with it when it was
    /// the window's only page; the page in front, when it was this one,
    /// becomes the first that is left.
    pub fn remove(&mut self, id: PageId) {
        self.windows = std::mem::take(&mut self.windows)
            .into_iter()
            .filter_map(|mut window| {
                window.pages.retain(|p| p.id != id);
                let first = window.pages.first()?.id;
                if window.front == id {
                    window.front = first;
                }
                Some(window)
            })
            .collect();
    }

    /// The pages after a save: every open tab as it is now and where it is
    /// now, every page that is not open as it was.
    ///
    /// - A window of the file goes on as the window most of its open pages
    ///   are in now (the earliest page deciding a tie), and takes that
    ///   window's frame from `frames`. Each window on screen is one window
    ///   of the file: a second that would claim it keeps only its pages
    ///   that are not open.
    /// - Its open pages are in the order of the tabs. A page that is not
    ///   open keeps its place: after the page it followed, or first.
    /// - A page whose tab was dragged to another window is in that window.
    ///   Tabs in a window no window of the file claims make a new one.
    /// - The page in front is the tab showing, when that tab is the
    ///   project's; otherwise the page that was in front, when it is still
    ///   in the window; otherwise the first. **With `keeping_front`, the tab
    ///   showing is not asked**: that is for the save a closing tab makes.
    ///   As the tabs of a window close one after another, the host shows
    ///   each of the ones left in turn, and a save that believed it would
    ///   record the last tab to close as the page that was in front.
    /// - A window none of whose pages is open is left exactly as it was,
    ///   and one with no page left is gone.
    /// - **The order of the windows does not change**, and new ones go
    ///   last. Following which window is in front would reorder the file
    ///   every time a person clicked on another window.
    pub fn updated(&self, live: &[Live], frames: &BTreeMap<WindowToken, Frame>, keeping_front: bool) -> Pages {
        // The first to claim an id is the tab that is that page.
        let mut by_id: BTreeMap<PageId, &Live> = BTreeMap::new();
        for tab in live {
            by_id.entry(tab.id).or_insert(tab);
        }
        let mut tabs: Vec<&Live> = by_id.values().copied().collect();
        tabs.sort_by_key(|t| (t.window, t.index, t.id));

        // Which window on screen each window of the file goes on as.
        let mut claimed: BTreeSet<WindowToken> = BTreeSet::new();
        let tokens: Vec<Option<WindowToken>> = self
            .windows
            .iter()
            .map(|window| {
                let mut order: Vec<WindowToken> = Vec::new();
                let mut count: BTreeMap<WindowToken, usize> = BTreeMap::new();
                for page in &window.pages {
                    let Some(tab) = by_id.get(&page.id) else { continue };
                    if !count.contains_key(&tab.window) {
                        order.push(tab.window);
                    }
                    *count.entry(tab.window).or_insert(0) += 1;
                }
                // Most pages first, the earliest deciding a tie: a stable
                // sort over the order they were met in.
                let mut ranked = order.clone();
                ranked.sort_by(|a, b| count[b].cmp(&count[a]));
                let token = ranked.into_iter().find(|t| !claimed.contains(t))?;
                claimed.insert(token);
                Some(token)
            })
            .collect();

        let pages_in = |token: WindowToken| -> Vec<Page> {
            tabs.iter().filter(|t| t.window == token).map(|t| Page { id: t.id, tab: Tab { root: t.root.clone(), title: t.title.clone() } }).collect()
        };
        let front_in = |token: WindowToken, pages: &[Page], was: Option<PageId>| -> PageId {
            if !keeping_front {
                if let Some(showing) = tabs.iter().find(|t| t.window == token && t.selected) {
                    return showing.id;
                }
            }
            match was {
                Some(was) if pages.iter().any(|p| p.id == was) => was,
                _ => pages[0].id,
            }
        };

        let mut windows = Vec::new();
        for (window, token) in self.windows.iter().zip(&tokens) {
            let closed: Vec<Page> = window.pages.iter().filter(|p| !by_id.contains_key(&p.id)).cloned().collect();
            let Some(token) = *token else {
                let Some(first) = closed.first() else { continue };
                let front = if closed.iter().any(|p| p.id == window.front) { window.front } else { first.id };
                windows.push(PagesWindow { frame: window.frame, front, pages: closed });
                continue;
            };
            let mut now = pages_in(token);
            for (place, page) in window.pages.iter().enumerate() {
                if by_id.contains_key(&page.id) {
                    continue;
                }
                let before = window.pages[..place].iter().rev().find(|earlier| now.iter().any(|p| p.id == earlier.id));
                let at = before.and_then(|anchor| now.iter().position(|p| p.id == anchor.id)).map_or(0, |i| i + 1);
                now.insert(at, page.clone());
            }
            let front = front_in(token, &now, Some(window.front));
            windows.push(PagesWindow { frame: frames.get(&token).copied().or(window.frame), front, pages: now });
        }

        // Windows on screen that no window of the file went on as.
        let mut seen = claimed;
        for tab in &tabs {
            if !seen.insert(tab.window) {
                continue;
            }
            let now = pages_in(tab.window);
            let front = front_in(tab.window, &now, None);
            windows.push(PagesWindow { frame: frames.get(&tab.window).copied(), front, pages: now });
        }
        Pages { windows, next_id: self.next_id }
    }

    /// The whole of a save, short of touching the disk: the pages after it
    /// and the file to write.
    ///
    /// `screen.live` is every open tab as it was captured -- which for some
    /// things means "as far as could be told": each is first given what the
    /// file knew and the capture could not say (`keeping_what_the_file_knew`),
    /// and only then takes the place of the page it is.
    pub fn saving(
        &self,
        name: &str,
        saved_at: i64,
        group: Option<String>,
        color: PaneColor,
        next_scrollback: Option<u64>,
        screen: &Screen,
    ) -> (Pages, Snapshot) {
        let known = self.known();
        let mut told: Vec<Live> = screen
            .live
            .iter()
            .map(|l| Live {
                root: keeping_what_the_file_knew(&l.root, &known),
                // Not said is not "no name" (`Live::title`).
                title: l.title.clone().or_else(|| self.page(l.id).and_then(|p| restored_name(&p.tab))),
                ..l.clone()
            })
            .collect();
        one_seat(&screen.live, &mut told);
        let pages = self.updated(&told, &screen.frames, screen.keeping_front);
        let file = Snapshot { name: name.to_string(), saved_at, group, color, windows: pages.file_windows(), next_scrollback };
        (pages, file)
    }

    /// The page a tab that came back from a restart is: the first page not
    /// in `taken` that has a pane with one of the snapshot names the tab's
    /// panes have. None when no page does.
    ///
    /// **The file decides, not the tab.** A tab the file has no page for is
    /// not in the project, whatever it says. And a snapshot name is the one
    /// thing a pane keeps for life and the file records, so it is what the
    /// two are matched by; a position would match a tab to whatever page
    /// now stands where its own did.
    pub fn page_sharing(&self, names: &[&str], taken: &BTreeSet<PageId>) -> Option<PageId> {
        let wanted: BTreeSet<&str> = names.iter().copied().filter(|n| !n.is_empty()).collect();
        if wanted.is_empty() {
            return None;
        }
        self.windows
            .iter()
            .flat_map(|w| w.pages.iter())
            .filter(|p| !taken.contains(&p.id))
            .find(|p| leaves(&p.tab.root).iter().any(|l| wanted.contains(l.scrollback.as_str())))
            .map(|p| p.id)
    }

    /// The pane called `scrollback` is the supervisor's from now on, and no
    /// other pane of the project is (a project has one). False, and nothing
    /// changed, when no pane is called that.
    ///
    /// The mark is the pane's `supervisor_seat` (task 1794), as on macOS and
    /// as `Stated::of_open` reads it. Who is in the pane is left as the file
    /// said: a pane nobody was written down for is not made an agent's to
    /// carry the mark. An agent's own `supervisor` flag, a format 2 field,
    /// follows the seat where there is an agent, for a reader that still
    /// looks there.
    pub fn mark_supervisor(&mut self, scrollback: &str) -> bool {
        fn has(node: &SavedNode, name: &str) -> bool {
            match node {
                SavedNode::Leaf(leaf) => leaf.scrollback == name,
                // A stack's members are panes like any other.
                SavedNode::Stack { members, .. } => members.iter().any(|m| m.scrollback == name),
                SavedNode::Split { left, right, .. } => has(left, name) || has(right, name),
            }
        }
        fn mark_leaf(leaf: &mut SavedLeaf, name: &str) {
            let it = leaf.scrollback == name;
            leaf.supervisor_seat = Some(it);
            if let Agent::Agent(who) = &mut leaf.agent {
                who.supervisor = it;
            }
        }
        fn mark(node: &mut SavedNode, name: &str) {
            match node {
                SavedNode::Leaf(leaf) => mark_leaf(leaf, name),
                SavedNode::Stack { members, .. } => members.iter_mut().for_each(|m| mark_leaf(m, name)),
                SavedNode::Split { left, right, .. } => {
                    mark(left, name);
                    mark(right, name);
                }
            }
        }
        if scrollback.is_empty() || !self.windows.iter().flat_map(|w| w.pages.iter()).any(|p| has(&p.tab.root, scrollback)) {
            return false;
        }
        for page in self.windows.iter_mut().flat_map(|w| w.pages.iter_mut()) {
            mark(&mut page.tab.root, scrollback);
        }
        true
    }

    /// What the file says of each of its panes, by the pane's snapshot name
    /// -- the one thing a pane keeps for life. The first pane to have a
    /// name is the one it names.
    pub fn known(&self) -> BTreeMap<String, Known> {
        let mut known = BTreeMap::new();
        for page in self.windows.iter().flat_map(|w| w.pages.iter()) {
            for leaf in leaves(&page.tab.root) {
                if !leaf.scrollback.is_empty() {
                    known.entry(leaf.scrollback.clone()).or_insert_with(|| Known {
                        cwd: leaf.cwd.clone(),
                        agent: leaf.agent.clone(),
                        by_supervisor: leaf.by_supervisor,
                        supervisor_seat: leaf.supervisor_seat.unwrap_or(false),
                        color: leaf.color.unwrap_or(PaneColor::None),
                        workers: leaf.workers.unwrap_or(Workers::Allowed),
                        shielded: leaf.shielded.unwrap_or(false),
                    });
                }
            }
        }
        known
    }
}

/// The name a tab opened from `tab` is given back, as a name somebody chose
/// (Windows: `NamedBy::Restored`): the tab's own, or else -- for a file
/// whose tab has none -- the one pane name in it somebody chose, when there
/// is exactly one. `None` for neither, and then nothing is named: **a
/// program's title is never put back** (`apprt/title.zig`, issue #9), since
/// the program says its own again and the restored one would outrank it.
///
/// Why a pane's chosen name can name the tab: a host with a chosen name per
/// tab and not per pane (Windows) takes `set_surface_title` as naming the
/// pane's tab, so one chosen pane name in a tab is what that would have
/// done live. Two or more name the tab nothing -- which one it would be is
/// not something to guess.
pub fn restored_name(tab: &Tab) -> Option<String> {
    if let Some(title) = tab.title.as_deref().filter(|t| !t.is_empty()) {
        return Some(title.to_string());
    }
    let all = leaves(&tab.root);
    let mut chosen = all.iter().filter(|l| l.title_chosen && !l.title.is_empty());
    match (chosen.next(), chosen.next()) {
        (Some(one), None) => Some(one.title.clone()),
        _ => None,
    }
}

/// **The seat moves to where the supervisor is now, and only then.** A host
/// that can say which pane the supervisor is in says `Some(true)` there and
/// `None` everywhere else (the Windows host: `pane-color-interface.md`
/// §7.1), so the panes it did not name take the file's seat back -- which,
/// once the supervisor has moved, is a second seat, and two seats read as
/// none. So when any pane on screen was said to be the seat, every other
/// pane on screen is not. When none was -- no supervisor is in the project
/// right now -- the file's seat stands.
///
/// `asked` is what the host said, before the file was asked; `told` the
/// same tabs after. A page that is not open keeps its own seat either way.
fn one_seat(asked: &[Live], told: &mut [Live]) {
    let said = |l: &&SavedLeaf| l.supervisor_seat == Some(true);
    if !asked.iter().any(|l| leaves(&l.root).iter().any(said)) {
        return;
    }
    for (a, t) in asked.iter().zip(told.iter_mut()) {
        let named: Vec<bool> = leaves(&a.root).iter().map(said).collect();
        for (leaf, seat) in leaves_mut(&mut t.root).into_iter().zip(named) {
            leaf.supervisor_seat = Some(seat);
        }
    }
}

/// Who is in a pane, from the core's three answers (the snapshot's
/// `who`: `is` as `WhoIs::name` spells it, and the three words beside it),
/// as a save writes it (task 1800). macOS's `ProjectLink.pane`, the same
/// mapping: the core's `unknown` is the file's `unknown` -- not known, which
/// the file's own answer is then kept over (`keeping_what_the_file_knew`)
/// -- and an agent is never written as the supervisor here: that is the
/// file's mark, kept by `agent_kept`. A word this build does not know is
/// `unknown` too: nothing is written over what the file says on a guess.
pub fn agent_said(is: &str, role: Option<&str>, cli: Option<&str>, session: Option<&str>) -> Agent {
    match is {
        "none" => Agent::None,
        "agent" => Agent::Agent(Who {
            role: role.unwrap_or_default().to_string(),
            cli: cli.unwrap_or_default().to_string(),
            session: session.unwrap_or_default().to_string(),
            supervisor: false,
        }),
        _ => Agent::Unknown,
    }
}

/// Write who is in each pane of a tree being saved (task 1800): `agent_of`
/// asked of the terminal behind each leaf, in the order `leaves_mut` walks
/// them. A leaf with no terminal yet stays as the capture left it
/// (`Unknown`).
pub fn fill_agents(root: &mut SavedNode, terminals: &[Option<String>], agent_of: &dyn Fn(&str) -> Agent) {
    for (leaf, terminal) in leaves_mut(root).into_iter().zip(terminals) {
        if let Some(terminal) = terminal {
            leaf.agent = agent_of(terminal);
        }
    }
}

/// Who a save writes into a pane: what it was told `now`, except where that
/// would lose what the file `was` (macOS's `ProjectPages.agent(now:was:)`,
/// case for case).
///
/// - Not known now: the file's answer stands.
/// - **The supervisor's pane** -- `seat`, the pane's `supervisor_seat` as
///   this save writes it (task 1794; never the agent's own `supervisor`
///   flag, which a file macOS wrote leaves `false` on the very pane it
///   seats): `none` or not known keeps the file's answer, and an agent now
///   fills in the words it has over the file's. The agent's flag follows
///   the seat, as `Pages::mark_supervisor` writes it, for a reader that
///   still looks there.
/// - Anywhere else, an answer replaces what was there: `none` is a pane
///   whose agent has gone, which is so.
fn agent_kept(now: &Agent, was: &Agent, seat: bool) -> Agent {
    if !seat {
        return if *now == Agent::Unknown { was.clone() } else { now.clone() };
    }
    let Agent::Agent(said) = now else { return was.clone() };
    let (role, cli, session) = match was {
        Agent::Agent(chief) => (chief.role.as_str(), chief.cli.as_str(), chief.session.as_str()),
        _ => ("", "", ""),
    };
    let pick = |n: &str, w: &str| if n.is_empty() { w.to_string() } else { n.to_string() };
    Agent::Agent(Who { role: pick(&said.role, role), cli: pick(&said.cli, cli), session: pick(&said.session, session), supervisor: true })
}

/// Mark the panes of a tree being saved that the project's supervisor
/// opened as its workers (`by_supervisor`, #1495, task 1799): a pane is one
/// when the core says its terminal was opened as a worker of `supervisor`,
/// the terminal in the project's supervisor pane now (the snapshot's
/// `who.worker_of`). macOS's `ProjectLink.pane`, the same rule.
///
/// `terminals` is the terminal behind each leaf, in the order `leaves_mut`
/// walks them; `None` for a pane that has none yet. With no `supervisor` --
/// the project has none, or its pane is not open -- nothing can be told,
/// and nothing is marked here: the file's mark is kept by
/// `keeping_what_the_file_knew`, not written over with a "no".
pub fn mark_workers(root: &mut SavedNode, terminals: &[Option<String>], supervisor: Option<&str>, worker_of: &dyn Fn(&str) -> Option<String>) {
    let Some(supervisor) = supervisor else { return };
    for (leaf, terminal) in leaves_mut(root).into_iter().zip(terminals) {
        let Some(terminal) = terminal else { continue };
        if worker_of(terminal).as_deref() == Some(supervisor) {
            leaf.by_supervisor = true;
        }
    }
}

/// `node` with what a save could not tell about a pane filled in from what
/// the file said of it, by snapshot name.
///
/// **Not known is not an answer to write over one.** Two things a save asks
/// of a pane can come back empty without being so:
///
/// - *Who is in it.* Where nothing can tell, the pane comes back `Unknown`,
///   and writing that would wipe out what the file knew -- a worker's pane
///   would be a pane nobody knows anything about after the first title
///   change. An answer that *is* one -- `None`, or an agent -- always
///   replaces what was there.
/// - *Where it is working.* A pane has no directory to report until its
///   shell has said one, which is some time after it opens and, without
///   shell integration, never. A project just opened is saved within
///   seconds; written as they come, its panes would all lose the
///   directories they were opened in.
/// - *What a person marked on it* -- colour, workers, shield, seat (task
///   1700). A pane restored from the file is not told its marks until the
///   core has taken them back, and the core's first word on a new terminal
///   is the defaults; the host says `None` until then
///   (`pane-color-interface.md` §7.2). Written as the defaults, the first
///   save after opening would take every colour and shield off the file.
pub fn keeping_what_the_file_knew(node: &SavedNode, known: &BTreeMap<String, Known>) -> SavedNode {
    fn keep(leaf: &SavedLeaf, known: &BTreeMap<String, Known>) -> SavedLeaf {
        let Some(was) = known.get(&leaf.scrollback) else { return leaf.clone() };
        let mut leaf = leaf.clone();
        if leaf.cwd.is_empty() {
            leaf.cwd = was.cwd.clone();
        }
        leaf.by_supervisor = leaf.by_supervisor || was.by_supervisor;
        leaf.supervisor_seat = leaf.supervisor_seat.or(Some(was.supervisor_seat));
        leaf.agent = agent_kept(&leaf.agent, &was.agent, leaf.supervisor_seat == Some(true));
        leaf.color = leaf.color.or(Some(was.color));
        leaf.workers = leaf.workers.or(Some(was.workers));
        leaf.shielded = leaf.shielded.or(Some(was.shielded));
        leaf
    }
    match node {
        SavedNode::Leaf(leaf) => SavedNode::Leaf(keep(leaf, known)),
        // Each member of a stack is a pane of its own.
        SavedNode::Stack { shown, members } => {
            SavedNode::Stack { shown: *shown, members: members.iter().map(|m| keep(m, known)).collect() }
        }
        SavedNode::Split { axis, ratio, left, right } => SavedNode::Split {
            axis: *axis,
            ratio: *ratio,
            left: Box::new(keeping_what_the_file_knew(left, known)),
            right: Box::new(keeping_what_the_file_knew(right, known)),
        },
    }
}
