import Foundation

// The pages of a project while the app has it in hand: which page of the
// file each open tab is, where each sits, and what a save makes of the tabs
// that are open and the pages that are not.
//
// Foundation-only on purpose, like `ProjectAutosave.swift`: every rule here
// is decided without a window or a terminal, so it can be run without the
// app (`tools/mac-logic-tests`). The half that holds real tabs is
// `ProjectSession.swift`.

/// The pages of one project, each with a name that lasts as long as the app
/// has the project in hand.
///
/// **Why a page has an id here when the file has none.** In the file a page
/// is a position: the third tab of the first window. That cannot say which
/// open tab is which page once a tab is dragged, closed or put in another
/// window -- a position quietly starts naming a different page. So a page is
/// given an id when the file is read, an open tab holds the id of its page,
/// and positions are worked out again from where the tabs are at every save
/// (`updated`). The id is never written: across a restart a tab finds its
/// page by the snapshot names of its panes (`page(sharing:excluding:)`).
///
/// **A page that is not open stays.** Closing a tab is not taking it out of
/// the project: its page keeps the layout it was last saved with, and comes
/// back when the project is opened again. Only `remove` takes a page out.
struct ProjectPages: Equatable {
    struct Page: Equatable {
        let id: Int
        var tab: ProjectTab
    }

    struct Window: Equatable {
        var frame: ProjectFrame?
        /// The id of the page that is in front. Always one of `pages`.
        var front: Int
        /// Never empty.
        var pages: [Page]
    }

    private(set) var windows: [Window]
    private var nextID: Int

    /// A project with no page yet.
    init() {
        windows = []
        nextID = 0
    }

    /// The pages of `file`, none of them open.
    init(file: ProjectFile) {
        var next = 0
        windows = file.windows.compactMap { window in
            let pages = window.tabs.map { tab -> Page in
                defer { next += 1 }
                return Page(id: next, tab: tab)
            }
            guard !pages.isEmpty else { return nil }
            let front = pages.indices.contains(window.front) ? window.front : 0
            return Window(frame: window.frame, front: pages[front].id, pages: pages)
        }
        nextID = next
    }

    /// An id for a page that is being added. The page itself arrives with
    /// the next `updated`, as a tab that is open.
    mutating func newPageID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// What goes in the file.
    var fileWindows: [ProjectWindow] {
        windows.map { window in
            ProjectWindow(
                frame: window.frame,
                front: window.pages.firstIndex { $0.id == window.front } ?? 0,
                tabs: window.pages.map(\.tab))
        }
    }

    var pageIDs: [Int] {
        windows.flatMap { $0.pages.map(\.id) }
    }

    func page(_ id: Int) -> Page? {
        for window in windows {
            if let page = window.pages.first(where: { $0.id == id }) { return page }
        }
        return nil
    }

    /// Every snapshot name any page refers to, open or not -- what a save
    /// must count as taken and must not prune.
    var scrollbackFilenames: [String] {
        windows.flatMap { $0.pages.flatMap(\.tab.root.scrollbackFilenames) }
    }

    /// Take a page out of the project. Its window goes with it when it was
    /// the window's only page; the page in front, when it was this one,
    /// becomes the first that is left.
    mutating func remove(_ id: Int) {
        windows = windows.compactMap { window in
            var window = window
            window.pages.removeAll { $0.id == id }
            guard let first = window.pages.first else { return nil }
            if window.front == id { window.front = first.id }
            return window
        }
    }

    // MARK: A save

    /// One open tab of the project, as a save finds it.
    struct Live: Equatable {
        /// The page it is.
        let id: Int
        /// Which window it is in: any number that is the same for tabs of
        /// one window and differs between windows.
        let window: Int
        /// Where it stands among that window's tabs. Only the order
        /// matters; tabs that are not the project's leave gaps.
        let index: Int
        /// Whether it is the tab showing in its window.
        let selected: Bool
        let root: ProjectNode
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
    ///   in the window; otherwise the first. **With `keepingFront`, the tab
    ///   showing is not asked**: that is for the save a closing tab makes.
    ///   As the tabs of a window close one after another, the system shows
    ///   each of the ones left in turn, and a save that believed it would
    ///   record the last tab to close as the page that was in front.
    /// - A window none of whose pages is open is left exactly as it was,
    ///   and one with no page left is gone.
    /// - **The order of the windows does not change**, and new ones go
    ///   last. Following which window is in front would reorder the file,
    ///   and with it what counts as its layout, every time a person clicked
    ///   on another window.
    func updated(live: [Live], frames: [Int: ProjectFrame], keepingFront: Bool) -> ProjectPages {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = liveByID.values.sorted { ($0.window, $0.index, $0.id) < ($1.window, $1.index, $1.id) }

        // Which window on screen each window of the file goes on as.
        var claimed: Set<Int> = []
        let tokens: [Int?] = windows.map { window in
            var order: [Int] = []
            var count: [Int: Int] = [:]
            for page in window.pages {
                guard let tab = liveByID[page.id] else { continue }
                if count[tab.window] == nil { order.append(tab.window) }
                count[tab.window, default: 0] += 1
            }
            // Most pages first; `sorted` is not stable, so the tie is said.
            let ranked = order.enumerated().sorted {
                (count[$0.element] ?? 0, -$0.offset) > (count[$1.element] ?? 0, -$1.offset)
            }
            guard let token = ranked.map(\.element).first(where: { !claimed.contains($0) }) else { return nil }
            claimed.insert(token)
            return token
        }

        func pages(in token: Int) -> [Page] {
            tabs.filter { $0.window == token }.map { Page(id: $0.id, tab: ProjectTab(root: $0.root)) }
        }
        func front(in token: Int, of pages: [Page], was: Int?) -> Int {
            if !keepingFront, let showing = tabs.first(where: { $0.window == token && $0.selected }) { return showing.id }
            if let was, pages.contains(where: { $0.id == was }) { return was }
            return pages[0].id
        }

        var result = self
        result.windows = []
        for (window, token) in zip(windows, tokens) {
            let closed = window.pages.filter { liveByID[$0.id] == nil }
            guard let token else {
                guard let first = closed.first else { continue }
                result.windows.append(Window(
                    frame: window.frame,
                    front: closed.contains { $0.id == window.front } ? window.front : first.id,
                    pages: closed))
                continue
            }
            var now = pages(in: token)
            for (place, page) in window.pages.enumerated() where liveByID[page.id] == nil {
                let before = window.pages[..<place].last { earlier in now.contains { $0.id == earlier.id } }
                let at = before.flatMap { anchor in now.firstIndex { $0.id == anchor.id } }.map { $0 + 1 } ?? 0
                now.insert(page, at: at)
            }
            result.windows.append(Window(
                frame: frames[token] ?? window.frame,
                front: front(in: token, of: now, was: window.front),
                pages: now))
        }

        // Windows on screen that no window of the file went on as.
        var seen = claimed
        for tab in tabs where !seen.contains(tab.window) {
            seen.insert(tab.window)
            let now = pages(in: tab.window)
            result.windows.append(Window(
                frame: frames[tab.window],
                front: front(in: tab.window, of: now, was: nil),
                pages: now))
        }
        return result
    }

    /// What a save finds on screen: the open tabs, the frame of each window
    /// they are in, and whether it is a closing tab's save (see `updated`).
    struct Screen {
        let live: [Live]
        let frames: [Int: ProjectFrame]
        let keepingFront: Bool
    }

    /// The whole of a save, short of touching the disk: the pages after it
    /// and the file to write.
    ///
    /// `live` is every open tab as it was captured -- which for some things
    /// means "as far as could be told": each is first given what the file
    /// knew and the capture could not say (`keepingWhatTheFileKnew`), and
    /// only then takes the place of the page it is.
    func saving(
        name: String,
        savedAt: Int,
        group: String?,
        nextScrollback: Int?,
        screen: Screen
    ) -> (pages: ProjectPages, file: ProjectFile) {
        let (live, frames, keepingFront) = (screen.live, screen.frames, screen.keepingFront)
        let known = self.known
        let told = live.map {
            Live(id: $0.id, window: $0.window, index: $0.index, selected: $0.selected,
                 root: $0.root.keepingWhatTheFileKnew(known))
        }
        let pages = updated(live: told, frames: frames, keepingFront: keepingFront)
        return (pages, ProjectFile(
            name: name, savedAt: savedAt, group: group,
            windows: pages.fileWindows, nextScrollback: nextScrollback))
    }

    // MARK: Across a restart

    /// The page a tab that came back from a restart is: the first page not
    /// in `taken` that has a pane with one of the snapshot names the tab's
    /// panes have. Nil when no page does.
    ///
    /// **The file decides, not the tab.** A tab comes back saying which
    /// project it was in; that is a claim made when the window's state was
    /// last written down, which is not when the project was last saved. A
    /// tab the file has no page for -- it was taken out, the project was
    /// replaced, the file is gone -- is not in the project, whatever it
    /// says. And a snapshot name is the one thing a pane keeps for life and
    /// the file records, so it is what the two are matched by; a position
    /// would match a tab to whatever page now stands where its own did.
    func page(sharing names: [String], excluding taken: Set<Int>) -> Int? {
        let wanted = Set(names.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        for window in windows {
            for page in window.pages where !taken.contains(page.id) {
                if !wanted.isDisjoint(with: page.tab.root.scrollbackFilenames) { return page.id }
            }
        }
        return nil
    }

    // MARK: The supervisor's pane

    /// The snapshot name of the pane the project marks as its
    /// supervisor's, if it marks one. A pane with no snapshot name cannot
    /// be found again and is not one.
    var supervisorPane: String? {
        for window in windows {
            for page in window.pages {
                if let name = page.tab.root.supervisorPane { return name }
            }
        }
        return nil
    }

    /// The snapshot names of the panes the project's supervisor opened.
    var workerPanes: [String] {
        windows.flatMap { $0.pages.flatMap(\.tab.root.workerPanes) }
    }

    /// Mark the pane called `name` as the supervisor's, **and no other**: a
    /// project has one, and a file in which two panes say they are it reads
    /// as having none (`ProjectFile.puttingRight`). What the pane's agent
    /// otherwise was is kept; a pane nobody could say anything about, or
    /// nobody was in, becomes an agent of which only this is known.
    mutating func makeSupervisor(pane name: String) {
        guard !name.isEmpty else { return }
        for w in windows.indices {
            for p in windows[w].pages.indices {
                windows[w].pages[p].tab = ProjectTab(root: windows[w].pages[p].tab.root.markingSupervisor(name))
            }
        }
    }

    // MARK: What a save cannot tell

    /// What the file says of a pane that a save may not be able to say
    /// again.
    struct Known: Equatable {
        /// Where it was working; empty when the file did not say.
        var cwd: String
        /// Who was in it; `.unknown` when the file did not say.
        var agent: ProjectAgent
        /// Whether the project's supervisor opened it.
        var bySupervisor: Bool
    }

    /// What the file says of each of its panes, by the pane's snapshot
    /// name -- the one thing a pane keeps for life.
    var known: [String: Known] {
        var known: [String: Known] = [:]
        for window in windows {
            for page in window.pages {
                page.tab.root.collectKnown(into: &known)
            }
        }
        return known
    }
}

extension ProjectNode {
    fileprivate var supervisorPane: String? {
        switch self {
        case .leaf(_, _, _, let scrollback, _, let agent):
            return agent.isSupervisor && !scrollback.isEmpty ? scrollback : nil
        case .split(_, _, let left, let right):
            return left.supervisorPane ?? right.supervisorPane
        }
    }

    fileprivate var workerPanes: [String] {
        switch self {
        case .leaf(_, _, _, let scrollback, let bySupervisor, _):
            return bySupervisor && !scrollback.isEmpty ? [scrollback] : []
        case .split(_, _, let left, let right):
            return left.workerPanes + right.workerPanes
        }
    }

    fileprivate func markingSupervisor(_ name: String) -> ProjectNode {
        switch self {
        case .leaf(let cwd, let title, let history, let scrollback, let bySupervisor, let agent):
            let isIt = scrollback == name
            let marked: ProjectAgent
            switch agent {
            case .agent(let role, let cli, let session, _):
                marked = .agent(role: role, cli: cli, session: session, supervisor: isIt)
            case .unknown, .none:
                marked = isIt ? .agent(role: "", cli: "", session: "", supervisor: true) : agent
            }
            return .leaf(
                cwd: cwd, title: title, history: history, scrollback: scrollback,
                bySupervisor: bySupervisor, agent: marked)
        case .split(let direction, let ratio, let left, let right):
            return .split(
                direction: direction, ratio: ratio,
                left: left.markingSupervisor(name), right: right.markingSupervisor(name))
        }
    }

    fileprivate func collectKnown(into known: inout [String: ProjectPages.Known]) {
        switch self {
        case .leaf(let cwd, _, _, let scrollback, let bySupervisor, let agent):
            if !scrollback.isEmpty, known[scrollback] == nil {
                known[scrollback] = ProjectPages.Known(cwd: cwd, agent: agent, bySupervisor: bySupervisor)
            }
        case .split(_, _, let left, let right):
            left.collectKnown(into: &known)
            right.collectKnown(into: &known)
        }
    }

    /// Who is written as being in a pane, given what a save found (`now`)
    /// and what the file said (`was`).
    ///
    /// An answer replaces what was there; "cannot tell" does not. **The
    /// supervisor's pane is the exception, and stays the supervisor's
    /// whatever is found in it**: the mark is the project's, put there by
    /// `ProjectPages.makeSupervisor` and by nothing a save sees, and the
    /// pane is where the group's supervisor is started again -- most of all
    /// when nobody is in it. So that pane goes on recording an agent: the
    /// one in it now, each part the core does not know yet (an empty one)
    /// kept as the file had it -- the session is what "go on with the last
    /// session" needs -- or, with nobody in it, the one that was.
    private static func agent(now: ProjectAgent, was: ProjectAgent) -> ProjectAgent {
        guard case .agent(let role, let cli, let session, true) = was else {
            return now == .unknown ? was : now
        }
        guard case .agent(let nowRole, let nowCLI, let nowSession, _) = now else { return was }
        return .agent(
            role: nowRole.isEmpty ? role : nowRole,
            cli: nowCLI.isEmpty ? cli : nowCLI,
            session: nowSession.isEmpty ? session : nowSession,
            supervisor: true)
    }

    /// This tree with what a save could not tell about a pane filled in
    /// from what the file said of it, by snapshot name.
    ///
    /// **Not known is not an answer to write over one.** Two things a save
    /// asks of a pane can come back empty without being so:
    ///
    /// - *Who is in it.* Where nothing can tell, the pane comes back
    ///   `.unknown`, and writing that would wipe out what the file knew --
    ///   a worker's pane would be a pane nobody knows anything about after
    ///   the first title change. An answer that *is* one -- `.none`, or an
    ///   agent -- replaces what was there, except in the supervisor's pane
    ///   (`agent(now:was:)`).
    /// - *Where it is working.* A pane has no directory to report until
    ///   its shell has said one, which is some time after it opens and,
    ///   without shell integration, never. A project just opened is saved
    ///   within seconds; written as they come, its panes would all lose the
    ///   directories they were opened in.
    /// - *Whether the supervisor opened it.* The core knows that only for
    ///   panes opened since the app started; for a pane that came back with
    ///   the project it is the file that knows. It is a thing about the
    ///   pane for life, so once the file says yes a save that cannot tell
    ///   does not make it no.
    func keepingWhatTheFileKnew(_ known: [String: ProjectPages.Known]) -> ProjectNode {
        switch self {
        case .leaf(let cwd, let title, let history, let scrollback, let bySupervisor, let agent):
            guard let was = known[scrollback] else { return self }
            return .leaf(
                cwd: cwd.isEmpty ? was.cwd : cwd,
                title: title, history: history, scrollback: scrollback,
                bySupervisor: bySupervisor || was.bySupervisor,
                agent: Self.agent(now: agent, was: was.agent))
        case .split(let direction, let ratio, let left, let right):
            return .split(
                direction: direction, ratio: ratio,
                left: left.keepingWhatTheFileKnew(known), right: right.keepingWhatTheFileKnew(known))
        }
    }
}

// MARK: - Where a window goes

/// Where a window of a project opens.
enum ProjectPlacement {
    /// The frame to open a window at, or nil to let it open where a new
    /// window would.
    ///
    /// The file records where the window *was* and nothing else. The screen
    /// it was on may be gone, smaller, or somewhere else, so the frame is
    /// brought back onto a screen that is there: untouched when one of
    /// `screens` (each the part of a screen a window may use) holds all of
    /// it; otherwise moved onto the screen that holds the most of it -- the
    /// first, when none holds any -- and made no bigger than that screen.
    ///
    /// Nil when nothing was recorded (every window of a format 1 file), when
    /// it was measured from the other corner (a file written on Windows:
    /// the numbers are not a place here), and when it is not a rectangle.
    static func frame(_ stored: ProjectFrame?, screens: [CGRect]) -> CGRect? {
        guard let stored, stored.origin == .bottomLeft else { return nil }
        guard stored.width >= 1, stored.height >= 1 else { return nil }
        let rect = CGRect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
        if screens.isEmpty || screens.contains(where: { $0.contains(rect) }) { return rect }

        func area(_ screen: CGRect) -> CGFloat {
            let overlap = screen.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        var screen = screens[0]
        for candidate in screens.dropFirst() where area(candidate) > area(screen) { screen = candidate }

        let width = min(rect.width, screen.width)
        let height = min(rect.height, screen.height)
        return CGRect(
            x: min(max(rect.minX, screen.minX), screen.maxX - width),
            y: min(max(rect.minY, screen.minY), screen.maxY - height),
            width: width,
            height: height)
    }

    /// Where the pages of one window of a project go when none of them is
    /// open.
    enum Place: Equatable {
        /// A window of their own: at this frame, or -- nil -- where any new
        /// window goes.
        case ownWindow(CGRect?)
        /// Tabs of a window that is there already.
        case tabs(in: Home)
    }

    enum Home: Equatable {
        /// The window the caller named: the control room's rule for where
        /// a tab it opens goes.
        case named
        /// The terminal window the person is in.
        case current
    }

    /// Where a window of a project opens.
    ///
    /// - **A window whose frame was recorded opens as its own window**, at
    ///   that frame brought back onto a screen (`frame`). Where a person
    ///   put a window is what a project is asked to remember.
    /// - **A window with no frame opens as tabs of the window the person is
    ///   in** -- every project from before frames were recorded, until it
    ///   is next saved, and that is how those always opened. With no
    ///   terminal window to go into it is a window of its own, wherever a
    ///   new window goes. "No frame" is everything `frame` answers nil to:
    ///   one recorded from the other corner is not a place here.
    /// - Each window by its own frame: a file with one of each opens one
    ///   of each.
    /// - **Opened from the control room, the first window goes where the
    ///   control room says a tab it opens goes** (`named`), frame or none;
    ///   the rest by the rules above.
    static func place(
        _ stored: ProjectFrame?,
        isFirstWindow: Bool,
        homeIsNamed: Bool,
        hasCurrentWindow: Bool,
        screens: [CGRect]
    ) -> Place {
        if isFirstWindow && homeIsNamed { return .tabs(in: .named) }
        if let rect = frame(stored, screens: screens) { return .ownWindow(rect) }
        return hasCurrentWindow ? .tabs(in: .current) : .ownWindow(nil)
    }

    /// A window's frame as the file records it.
    static func stored(_ frame: CGRect) -> ProjectFrame {
        ProjectFrame(
            origin: .bottomLeft,
            x: Double(frame.minX), y: Double(frame.minY),
            width: Double(frame.width), height: Double(frame.height))
    }
}
