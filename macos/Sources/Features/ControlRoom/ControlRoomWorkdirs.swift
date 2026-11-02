import CoreGraphics
import Foundation

/// The working directories of a group, as the core's `workdirs` page says
/// them (task 2634, #2140 M2; `files/Workdirs.zig`, `API.md`, `control-room.md`
/// §8.1). The right-hand side's working-directory page draws these, and a
/// preview finds the directory its ticket is minted for in them.
///
/// **Asked for through the door that already exists.** `ghostty_app_control_page`
/// answers `{"page":"workdirs","group":…}` -- the core has had
/// `renderWorkdirs` since task 2145 C1 -- so nothing here needs a new C
/// entry point or a new field on the control room snapshot. What was
/// missing was only the host's half: this file is the request and the
/// reading of the answer. `ControlRoomPerfPage.swift` holds the call
/// itself (it names `GhosttyKit`); this file decides nothing about how the
/// answer arrives, which is why it is in the package that runs with no
/// app.
///
/// **No view and no terminal in here.** Every rule below is worth a test
/// on numbers and words.
enum ControlRoomWorkdirs {
    /// One working directory, as the page says it. Every key is always
    /// there (`API.md` §2.0), and the names are the core's (`Dir`).
    ///
    /// ⚠️ **A subset, and deliberately.** The page sends more than this --
    /// `kind` (`terminal` or `tree`), `tree_name`, and later more besides --
    /// and none of it is decoded here. It is not that those keys are
    /// uninteresting; it is that a host **draws** the control room and does
    /// not decide what it says, and the gate that holds that rule refuses a
    /// host that reads `kind` at all, on the ground that there is nothing a
    /// kind is for except comparing it (which is deciding a second time).
    /// Nothing here reads one, and decoding it "just in case" is how the
    /// second answer gets written.
    struct Dir: Decodable, Equatable {
        /// 16 hex digits of a hash of `path`. **This is what `files_open`
        /// wants as `workdir_id`**, so a ticket is asked for by this and
        /// not by a path.
        var id: String
        /// Real: every link followed.
        var path: String
        /// `path` with the home directory written `~`.
        var short: String
        /// The terminals standing in this directory.
        var who: [Who]
        /// Other groups a terminal of this row is in.
        var also_in: [String]
        /// False for a row the page lists but nothing may be read from
        /// (`/`, the home directory, above it); the reason is in `why`.
        var readable: Bool
        /// See `Workdirs.Why`. Nil when `readable`.
        var why: String?
        /// Files an agent is changing now (C5); 0 until then.
        var editing: UInt64

        struct Who: Decodable, Equatable {
            /// The core's id, as `0x…` (`Workdirs.writeJson`).
            var id: String
            var title: String
            /// `supervisor`, `worker` or `own` (`Workdirs.roleName`).
            var role: String
        }
    }

    /// The whole page.
    struct Answer: Decodable, Equatable {
        var page: String
        var group: String
        var dirs: [Dir]
    }

    /// The request the core is asked with.
    static func request(group: String) -> String {
        "{\"page\":\"workdirs\",\"group\":\(ControlRoomPageRequest.quoted(group))}"
    }

    /// The answer, or what could not be read of it.
    ///
    /// ⚠️ **Three outcomes, not two.** The core has one page wire shape for
    /// every page and its refusals come back **in that shape**
    /// (`{"error":"NoSuchGroup"}` -- `App.zig`'s `renderWorkdirs` answers it
    /// for a group the core does not have). A reader that folded that into
    /// "not JSON" would answer about a perfectly well-formed JSON document
    /// that it was unparseable, and would throw away the core's own word for
    /// what was wrong -- the one thing a person reading a blank pane needs.
    /// The three sibling pages have had this branch since they were written
    /// (`ControlRoomResources.decode`, `ControlRoomTasks.decode`,
    /// `ControlRoomOverall.decode`); this one was the fourth and was missing
    /// it. Caught by the test seat building a one-file probe against this
    /// file and running the core's real refusal through it (task 2634).
    static func read(_ text: String) -> Result<Answer, Failure> {
        guard let data = text.data(using: .utf8) else { return .failure(.notJSON) }
        if let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = v["error"] as? String {
            return .failure(.refused(error))
        }
        do {
            return .success(try JSONDecoder().decode(Answer.self, from: data))
        } catch {
            return .failure(.notJSON)
        }
    }

    enum Failure: Error, Equatable {
        /// The answer is not the object this page takes, or is not UTF-8.
        case notJSON
        /// The core answered, and said no: `{"error": …}`. **This is not
        /// "unreadable"** -- the bytes are fine and the core named the
        /// reason. `NoSuchGroup` is the one a host is most likely to see,
        /// and a page that reported it as a parse failure would send
        /// whoever read the message looking in the wrong place.
        case refused(String)
        /// The core refused a **files** request, in that door's own shape:
        /// `{"refused":"access","reason":"outside","why":"it is not in this
        /// working directory, or there is nothing at that path"}`.
        ///
        /// ⚠️ **A second case and not the one above.** The page door answers
        /// `{"error":"NoSuchGroup"}` -- one name and nothing else -- while
        /// this door answers a code, a reason and a sentence, and the
        /// sentence is the core's own (`Access.Refusal.say`). Folding the
        /// two together would either drop the sentence, which is the half a
        /// person reads, or invent one here, which would be a second answer
        /// about why a directory may not be listed.
        case refusedFile(code: String, why: String?)
    }

    /// The directory a ticket for `path` is minted from: **the longest
    /// `path` among the readable rows that contains it**, or nil when there
    /// is none.
    ///
    /// Longest and not first, because the rows are nested: a worktree
    /// standing inside the person's own directory is two rows, and a file
    /// in the worktree belongs to the nearer one. `Dir.path` is real on
    /// both sides (`Workdirs` realpaths, and so does the host), so this is
    /// a prefix test on whole path components and never a substring: `/a/bc`
    /// does not contain `/a/b`.
    ///
    /// A row with `readable` false is passed over rather than returned: the
    /// core refuses a ticket for one (`too_wide` -- `/`, the home directory,
    /// anything above it), and a caller that asked anyway would be asking
    /// for a refusal it could have predicted.
    ///
    /// ⚠️ **Nil is an answer and not a reason to go on and ask.** What a
    /// caller does with it is `NoDirectory`, below: no workdir row holds
    /// this file, so there is nothing to mint a ticket from and **no
    /// request is made**. A host that sent `files_open` anyway would be
    /// sending a path with no working directory behind it, and the refusal
    /// that came back would name the core's rules rather than the simple
    /// fact -- that this file is not in a directory this group has.
    static func directory(holding path: String, in answer: Answer) -> Dir? {
        answer.dirs
            .filter { $0.readable && contains($0.path, path) }
            .max { $0.path.count < $1.path.count }
    }

    /// What to tell the person when `directory(holding:in:)` found nothing.
    ///
    /// **A named refusal rather than an empty preview**, and deliberately
    /// the same shape `PreviewTicket.Failure.refused` carries: a caller
    /// that has both can show one line either way, and the two say
    /// different things -- this one never left the host.
    static let noDirectory = "no working directory of this group holds that file"

    /// A file's directory and the reason there is none, in one call, so a
    /// caller cannot forget the second half of the first.
    ///
    /// The success is a `Mint` and not a tuple: `Result<(A, B), _>` is not
    /// `Equatable` (Swift's tuples are not), so a test comparing what this
    /// returned would have to reach into the case instead of saying the
    /// thing it means.
    struct Mint: Equatable {
        var workdirId: String
        var path: String
    }

    /// What a `Failure` says to a person, **in the core's own words wherever
    /// the core gave any**.
    ///
    /// ⚠️ **`why` is preferred to the code, and the code is only the fallback
    /// for a refusal that carried no sentence.** `refusedFile` holds both
    /// because the core sends both (`{"refused":"access","reason":"outside",
    /// "why":"it is not in this working directory…"}`): `refused` is what a
    /// caller branches on and `why` is the half a person reads. A page that
    /// drew the code would be showing `access` where the core wrote a
    /// sentence, and one that wrote a sentence of its own here would be a
    /// second answer about why a directory may not be listed.
    static func failureWords(_ failure: Failure) -> String {
        switch failure {
        case .notJSON:
            return String(localized: "The answer was not one this page can read",
                          comment: "工作目录页：核心的回答读不懂时那一句")
        case .refused(let why):
            return why
        case .refusedFile(let code, let why):
            return why ?? code
        }
    }

    static func mint(holding path: String, in answer: Answer) -> Result<Mint, Failure> {
        guard let dir = directory(holding: path, in: answer) else {
            return .failure(.refused(noDirectory))
        }
        return .success(Mint(workdirId: dir.id, path: path))
    }

    /// `outer` is `inner` or a directory above it.
    ///
    /// On components, not on characters: a plain `hasPrefix` says
    /// `/a/bc` contains `/a/b`, which would mint a ticket out of a
    /// directory the file is not in -- and the answer would be a refusal
    /// that reads like a bug in the core. `path` is real and absolute on
    /// both sides, so the only shapes to allow for are the exact match and
    /// the separator.
    static func contains(_ outer: String, _ inner: String) -> Bool {
        if outer == inner { return true }
        // `/` is the one directory whose own path already ends in the
        // separator; anything else needs one put between the two.
        let prefix = outer.hasSuffix("/") ? outer : outer + "/"
        return inner.hasPrefix(prefix)
    }
}

// MARK: - Which roots are open

extension ControlRoomWorkdirs {
    /// What the working-directories page remembers between two draws: which
    /// roots are open, and which row the workbench is showing. The three ways
    /// the design opens and shuts a root, and the one way it moves a
    /// selection, are the methods below (task 2643, #2140 M4/W4;
    /// `polter-artifacts/2140/v3/src/12-trees-overflow-mac-dark.html` and its
    /// `CHANGES.md`: 放不下时都收起来 / 按住 ⌥ 点一个根只展开它).
    ///
    /// **No view in here, and it is here for that reason.** What the page
    /// draws for one root's twisty is `isOpen`; the three gestures call the
    /// three methods below and nothing else. That leaves every rule below
    /// worth a test on words and sets, which is why this lives beside the
    /// request and the reading of the answer rather than in the view.
    ///
    /// ⚠️ **What is remembered is the *shut* ones, not the open ones.** The
    /// design's default is open (根默认展开到第一层, `2145/PLAN.md` §2.5), and
    /// a set of *open* ids cannot tell "nobody has touched this root" from
    /// "somebody opened it": a root the page has never seen would draw shut,
    /// which is the wrong picture drawn for the right reason, and the day the
    /// default moves the set that was right is the one that never held it.
    /// Two states that look alike need a bit that separates them, and this is
    /// that bit -- absence from the set means **no decision**, not "closed".
    struct Tree: Equatable {
        /// The roots somebody has shut. Every root not in here is open.
        private(set) var shut: Set<String> = []

        /// The row the workbench is showing, or nil for none.
        ///
        /// **One at a time, and that is the whole rule**: the design draws
        /// the selected row with a bar down its left edge (`files.css`,
        /// `.tr.sel::after`), and two of those would be two answers about
        /// what is open in the pane beside them. It lives here rather than
        /// in the view because the view is a `sources.out` file -- nothing
        /// in it can be reached by a test, and the rule is worth one
        /// (task 2643's test seat asked for exactly this pair of
        /// assertions).
        ///
        /// ⚠️ **Not a `Bool` on the row.** A flag per row is a set with no
        /// rule, and the first two rows to be drawn with it would both be
        /// selected on the screen the day somebody forgot to clear the one
        /// they were on. One slot cannot forget.
        private(set) var selected: String?

        init() {}

        /// The twisty points right while the root is shut and down while it
        /// is open (`files3.css`, `.root .tw`).
        func isOpen(_ id: String) -> Bool { !shut.contains(id) }

        /// A plain click on a root: it opens if it was shut, and shuts if it
        /// was open. **The other roots are left alone** -- the design draws
        /// several roots open at once, and that is the state a plain click
        /// reaches.
        mutating func toggle(_ id: String) {
            if shut.contains(id) { shut.remove(id) } else { shut.insert(id) }
        }

        /// ⌥-click: this root opens and **every other root shuts**.
        ///
        /// On a root that is already the only one open this leaves the state
        /// as it is rather than shutting it: the design's gesture is "only
        /// this one", and a click that shut the root you pointed at would be
        /// `toggle` wearing another key. `toggle` is the way to shut one.
        mutating func solo(_ id: String, among ids: [String]) {
            shut = Set(ids).subtracting([id])
        }

        /// Whether this row is the one the workbench is showing.
        func isSelected(_ id: String) -> Bool { selected == id }

        /// The row was clicked: it is the selected one, and **the one before
        /// it is not** -- the same slot, so there is no second thing to
        /// clear. `nil` is a click on nothing, which is a selection moved
        /// off every row rather than a row selected by default.
        mutating func select(_ id: String?) { selected = id }

        /// 「全部收起」: every root shuts.
        mutating func collapseAll(_ ids: [String]) {
            shut = Set(ids)
        }

        /// Roots that have gone stop being remembered, so a directory that
        /// comes back comes back **open** rather than wearing a decision that
        /// was made about a directory the group had before. Called with what
        /// the page last drew: a group's workdirs come and go as terminals
        /// enter and leave directories (`Workdirs.compute` is worked out
        /// afresh on every ask -- its README says so, and the cost of it is
        /// written down there).
        mutating func keep(only ids: [String]) {
            shut.formIntersection(ids)
        }
    }
}

// MARK: - What the left-hand column is showing

extension ControlRoomWorkdirs {
    /// The working-directories page's left-hand column: the activity bar's
    /// two icons, the button at its foot, whether the column is drawn at
    /// all, and whether 「最近改过」 is folded (task 2670 S3; the v3 design's
    /// `files4.css` `.actbar` / `.rsec-toggle`).
    ///
    /// ⚠️ **Not `ControlRoomSidebar`.** That one is the *chat* page's
    /// preview sidebar -- the file beside the conversation, opened with ⌘\
    /// (task 2645) -- and it is a different side of a different page. This is
    /// the column that holds the explorer on the working-directories page.
    /// Two things called a sidebar in one window is how one of them gets
    /// edited by mistake.
    ///
    /// **It is here rather than in the view because all three of its bits are
    /// rules**: which icon a press leaves in front, whether that press shuts
    /// the column, and that the 「最近改过」 chevron touches nothing else. The
    /// page is a `sources.out` file -- nothing in it can be reached by a test
    /// -- and `tools/mac-logic-tests.json` says why: it draws from a model and
    /// the rules are meant to be values next to it.
    struct Activity: Equatable {
        /// The two things the activity bar stands for.
        ///
        /// **Two, and only two** (the supervisor's scope for task 2670:
        /// 活动栏只放 2 个图标 -- 资源管理器、搜索). A third icon is a third
        /// thing this struct would have to answer a press about, and the
        /// scope says there is not one.
        enum Icon: String, CaseIterable, Equatable {
            case explorer, search
        }

        /// Which icon is in front. The explorer to begin with: a page that
        /// opened on the search would be a screen with no file tree on it.
        private(set) var icon: Icon = .explorer

        /// Whether the column is drawn. **Open to begin with**, for the same
        /// reason: a page whose own panel started shut is a blank window
        /// with nothing saying why.
        private(set) var open: Bool = true

        /// Whether 「最近改过」 is folded. Unfolded to begin with -- the
        /// section is what the design's first picture shows, and its rows
        /// being empty this round is the *content's* state, not this bit's.
        private(set) var recentFolded: Bool = false

        init() {}

        /// A press on one of the activity bar's icons.
        ///
        /// **The one already in front shuts the column, and stays in front**
        /// (the supervisor's scope: 再点一次当前图标就收起). That is what
        /// makes the panel reachable again with the same press -- an icon
        /// that changed to something else on the way shut would leave the
        /// person pressing twice to get back where they were.
        ///
        /// Another icon comes in front, and **the column opens if it was
        /// shut**: on a closed column a press that changed the icon and left
        /// the panel closed would be a click with nothing to see.
        mutating func press(_ which: Icon) {
            if which == icon && open {
                open = false
                return
            }
            icon = which
            open = true
        }

        /// The button at the foot of the activity bar: the column opens or
        /// shuts and **which icon is in front is not touched**. It is the
        /// same fold `press` reaches from the other end, not a third icon.
        mutating func toggle() { open.toggle() }

        /// The 「最近改过」 chevron: one bit, and nothing else moves.
        ///
        /// ⚠️ **Nothing folds it by itself.** The supervisor's rule for this
        /// page is 不做任何自动折叠 -- and for this section that means its
        /// rows arriving (when they do) must not fold it, either. What can
        /// change it is a press, which is this method.
        mutating func toggleRecent() { recentFolded.toggle() }
    }

    /// What the activity bar draws: the three marks of the v3 design's
    /// `.actbar` (`build2665.py`'s `IC_EXPLORER`, `IC_SEARCH`, `IC_COLLAPSE`,
    /// each a 20-unit artboard), and the two chevrons of its tree
    /// (`TW_SHUT` / `TW_OPEN`, a 14-unit one).
    ///
    /// **Which mark says which thing is a rule and lives here**; turning a
    /// mark into a `Path` is the page's, the same split `Glyph` has and for
    /// the same reason (`ControlRoomWorkdirsPage` is a `sources.out` file
    /// nothing in a test can reach).
    enum Mark: String, CaseIterable, Equatable {
        case explorer, search, collapseSidebar
        case chevronShut, chevronOpen

        /// The strings of the design's `<path>` elements, copied and not
        /// redrawn, so that the day the design's icon changes there is one
        /// line to compare rather than a hand-transcription of a curve.
        ///
        /// ⚠️ **Two of the five are the design's shape written as a path, and
        /// that is said rather than glossed.** The design draws the search
        /// mark's ring as an SVG `<circle cx="8.5" cy="8.5" r="5">` and the
        /// collapse button as `<rect x="3" y="3" width="14" height="14"
        /// rx="2">`; this parser reads path commands, so both are written out
        /// as arcs whose numbers are the design's own (`r=5` is a half turn
        /// each way from the circle's rightmost point; the rect's corners are
        /// four `r=2` arcs). Everything else below is the design's `d`
        /// string character for character.
        var art: [String] {
            switch self {
            case .explorer:
                return ["M13 2H5a1.5 1.5 0 0 0-1.5 1.5v11A1.5 1.5 0 0 0 5 16h8a1.5 1.5 0 0 0 1.5-1.5V6.5L13 2z",
                        "M12.5 2v4.5H17",
                        "M7 18.5h9a1.5 1.5 0 0 0 1.5-1.5V6"]
            case .search:
                return ["M13.5 8.5a5 5 0 1 1-10 0 5 5 0 0 1 10 0z",
                        "M12.5 12.5L17 17"]
            case .collapseSidebar:
                return ["M5 3h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z",
                        "M8 3v14"]
            case .chevronShut:
                return ["M5.5 3.5L9 7 5.5 10.5"]
            case .chevronOpen:
                return ["M3.5 5.5L7 9 10.5 5.5"]
            }
        }

        /// The side of the artboard the strings above are drawn on: the
        /// activity bar's three are `g20`, the chevrons `g14`.
        var artboard: CGFloat { self == .chevronShut || self == .chevronOpen ? 14 : 20 }

        /// The drawing as segments a `Path` can be built from, read by the
        /// same parser `Glyph` uses. A mark this cannot read is **no
        /// segments**, and a test asks every mark to be readable -- a
        /// dropped command would otherwise draw an empty box where an icon
        /// belongs, which reads as a design with no icon.
        var segments: [[Segment]] { art.map(Segment.parse) }
    }

    /// The marks this could not read, for a test to name them by.
    static var unreadableMarks: [String] {
        Mark.allCases.flatMap { $0.art.filter { Segment.parse($0).isEmpty } }
    }
}

// MARK: - Which icon a tree row carries

extension ControlRoomWorkdirs {
    /// Which of the design's eight monochrome icons one row of the tree gets
    /// (task 2670 S4; `polter-artifacts/2665/v3/src/build2665.py`'s
    /// `get_node_icon` and the eight drawings above it, lines 84-143).
    ///
    /// **The rule is here and the drawing is in the page.** What is decided
    /// below -- which of eight a name is -- is a value and is tested; what a
    /// name *looks like* is `ControlRoomWorkdirsPage`'s, which turns `art`
    /// into a `Path`. That split is `tools/mac-logic-tests.json`'s: the page
    /// is a `sources.out` file and nothing in it can be reached by a test.
    ///
    /// ⚠️ **Eight, and the design chose them**: folders (open and shut), and
    /// ts/tsx, swift, zig, md, json, everything else. A ninth is a ninth
    /// drawing nobody has seen, and the supervisor's scope for this task says
    /// the eight are copied and nothing is added.
    enum Glyph: String, CaseIterable, Equatable {
        case folderShut, folderOpen
        case fileTS, fileSwift, fileZig, fileMD, fileJSON
        case fileOther

        /// The icon for one row.
        ///
        /// `isDir` and `open` are the two facts the core sends: `is_dir` from
        /// the listing (`Level.Row.is_dir`) and whether this row's level is
        /// being drawn. **Nothing else about the name is read** -- not
        /// `.gitignore`, not whether it is executable, not a mode -- because
        /// the design's rule is the extension and a second rule here would be
        /// a second answer about what a row is.
        static func of(name: String, isDir: Bool, open: Bool) -> Glyph {
            // A directory is a folder, and the design draws two of them.
            if isDir { return open ? .folderOpen : .folderShut }
            switch Self.extension(of: name) {
            case "ts", "tsx": return .fileTS
            case "swift": return .fileSwift
            case "zig": return .fileZig
            case "md", "markdown": return .fileMD
            case "json": return .fileJSON
            default: return .fileOther
            }
        }

        /// The extension the design's rule reads: **what follows the last dot,
        /// lower-cased**, and the empty string when there is no dot.
        ///
        /// ⚠️ **`name.split` in the design is `str.split` in Python**, which
        /// is why a leading dot is not special there: `.gitignore` splits to
        /// `["", "gitignore"]` and its last piece is `gitignore`, so the
        /// design is really "the part after the last dot, dot or not". That
        /// is copied here rather than corrected, because the alternative --
        /// treating a dot-file as extensionless -- is a rule the design does
        /// not have, and the two differ on exactly the names a working
        /// directory is full of. The consequence is one a person can see:
        /// a file called `.md` draws the markdown icon. A test pins it, so
        /// the day somebody means "extensionless" the change is deliberate.
        static func `extension`(of name: String) -> String {
            guard let dot = name.lastIndex(of: ".") else { return "" }
            return name[name.index(after: dot)...].lowercased()
        }

        /// The drawing, as the design writes it: one string per `<path>`,
        /// each in the SVG path syntax of
        /// `polter-artifacts/2665/v3/src/build2665.py` lines 84-143, on the
        /// glyphs' 14-unit artboard.
        ///
        /// **Copied, not redrawn.** Every string below is that file's, taken
        /// as it is so that the day the design's icon changes there is one
        /// line to compare rather than a hand-transcription of a curve.
        var art: [String] {
            switch self {
            case .folderShut:
                return ["M1.5 3h3.5l1.5 1.5H12a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H1.5a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1z"]
            case .folderOpen:
                return ["M1.5 3.5h3.5l1.5 1.5H11a1 1 0 0 1 1 1V7M2 7h10.5l-1.5 5H1L2 7z"]
            case .fileTS:
                return [Glyph.fileBody, Glyph.fileFold,
                        "M5.2 8.5L4 10l1.2 1.5M8.8 8.5L10 10l-1.2 1.5"]
            case .fileSwift:
                return [Glyph.fileBody, Glyph.fileFold,
                        "M4.5 11.2c1.8 0 4-1.2 5-3-.9.4-2 .4-2.8.1 1.2-.7 1.8-1.8 1.8-1.8-1.8.8-3 1.2-4 1.2"]
            case .fileZig:
                return [Glyph.fileBody, Glyph.fileFold, "M5 8h4l-3 2.5h3.5"]
            case .fileMD:
                return [Glyph.fileBody, Glyph.fileFold,
                        "M4.5 11.2v-2.7l1.3 1.5 1.3-1.5v2.7M9.2 8.5v2.7M8.3 10.3l.9.9.9-.9"]
            case .fileJSON:
                return [Glyph.fileBody, Glyph.fileFold,
                        "M5.5 8c-.5 0-.7.3-.7.7v.3c0 .3-.3.7-.7.7.4 0 .7.4.7.7v.3c0 .4.2.7.7.7M8.5 8c.5 0 .7.3.7.7v.3c0 .3.3.7.7.7-.4 0-.7.4-.7.7v.3c0 .4-.2.7-.7.7"]
            case .fileOther:
                return [Glyph.fileBody, Glyph.fileFold]
            }
        }

        /// The sheet every file icon is drawn on: a page with a folded top
        /// right corner. The five file icons differ only in what is inside
        /// it, which is how the design draws them too (the same two `d`
        /// strings begin all five).
        static let fileBody = "M3 1.5h5l3.5 3.5v7.5a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1v-10a1 1 0 0 1 1-1z"
        static let fileFold = "M8 1.5v3.5h3.5"

        /// The artboard's side, in the same units as the strings above
        /// (`svg class="g14" viewBox="0 0 14 14"`).
        static let artboard: CGFloat = 14

        /// The drawing as segments a `Path` can be built from.
        ///
        /// A string this cannot read is **no segments**, not a guess: a
        /// dropped `c` in a hand-edited string would otherwise draw a file
        /// icon missing its mark, which looks like a design that has no mark
        /// rather than like a string nobody could read. `unreadable` names
        /// them, and a test asks every one of the eight to be readable.
        var segments: [[Segment]] { art.map(Self.parse) }

        /// The strings this could not read, for a test to name them by.
        static var unreadable: [String] {
            allCases.flatMap { $0.art.filter { parse($0).isEmpty } }
        }

        /// One SVG path string as segments. See `Segment` for what is
        /// supported and what happens to anything else.
        static func parse(_ d: String) -> [Segment] {
            Segment.parse(d)
        }
    }

    /// One segment of a drawing on the 14-unit artboard.
    ///
    /// **A closed, small set, and that is the point.** The eight drawings use
    /// `M m L l H h V v C c A a Z z` and nothing else; the parser below reads
    /// those and answers **nothing** for anything else, rather than skipping
    /// it. A parser that skipped what it did not know would draw a
    /// slightly-wrong icon that nobody could tell from the right one.
    enum Segment: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
        case close

        var end: CGPoint {
            switch self {
            case .move(let p), .line(let p): return p
            case .cubic(_, _, let p): return p
            case .close: return .zero
            }
        }

        /// Parse `d`, or `[]` when it contains something this does not read.
        ///
        /// An arc is turned into cubics by the SVG specification's own
        /// endpoint-to-centre conversion (F.6.5), split so that no piece is
        /// more than a quarter turn -- which is the largest a cubic
        /// approximates a circle well over, and it is what makes the four
        /// corner radii of `fileBody` come out round. The last piece's end is
        /// put on the arc's own end point exactly, so the drawing closes
        /// where the string says it does rather than a rounding error away.
        static func parse(_ d: String) -> [Segment] {
            var scanner = Scanner(d)
            var out: [Segment] = []
            var command: Character?
            var current = CGPoint.zero
            var start = CGPoint.zero
            // The previous control point, for a smooth `s`/`t` -- not used by
            // the eight, and therefore not read at all.
            while true {
                if let c = scanner.letter() {
                    guard "MmLlHhVvCcAaZz".contains(c) else { return [] }
                    command = c
                } else if command == nil {
                    return scanner.done ? out : []
                }
                guard let c = command else { return [] }
                // `Z` takes no arguments and may be followed by anything, so
                // it is answered before the numbers are asked for.
                if c == "Z" || c == "z" {
                    out.append(.close)
                    current = start
                    command = nil
                    if scanner.done { return out }
                    continue
                }
                let relative = c.isLowercase
                func point(_ x: Double, _ y: Double) -> CGPoint {
                    relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                }
                switch c.uppercased() {
                case "M":
                    guard let x = scanner.number(), let y = scanner.number() else { return [] }
                    let p = point(x, y)
                    out.append(.move(p))
                    current = p
                    start = p
                    // Extra pairs after an `M` are `L`s (SVG's own rule).
                    command = relative ? "l" : "L"
                case "L":
                    guard let x = scanner.number(), let y = scanner.number() else { return [] }
                    let p = point(x, y)
                    out.append(.line(p))
                    current = p
                case "H":
                    guard let x = scanner.number() else { return [] }
                    let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    out.append(.line(p))
                    current = p
                case "V":
                    guard let y = scanner.number() else { return [] }
                    let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    out.append(.line(p))
                    current = p
                case "C":
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number()
                    else { return [] }
                    let c1 = point(x1, y1), c2 = point(x2, y2), p = point(x, y)
                    out.append(.cubic(c1, c2, p))
                    current = p
                case "A":
                    guard let rx = scanner.number(), let ry = scanner.number(),
                          let rot = scanner.number(),
                          let large = scanner.flag(), let sweep = scanner.flag(),
                          let x = scanner.number(), let y = scanner.number()
                    else { return [] }
                    let p = point(x, y)
                    out.append(contentsOf: Arc.segments(from: current, rx: rx, ry: ry,
                                                        rot: rot, large: large, sweep: sweep, to: p))
                    current = p
                default:
                    return []
                }
                if scanner.done { return out }
            }
        }

        /// Where a string is read from: letters, numbers and the separators
        /// between them.
        private struct Scanner {
            private let s: [Character]
            private var i = 0
            init(_ text: String) { s = Array(text) }

            var done: Bool {
                mutating get {
                    skip()
                    return i >= s.count
                }
            }

            /// Whitespace and commas, which separate exactly as a space does.
            private mutating func skip() {
                while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 }
            }

            /// The next command letter, if the next thing is one.
            mutating func letter() -> Character? {
                skip()
                guard i < s.count, s[i].isLetter else { return nil }
                i += 1
                return s[i - 1]
            }

            /// One number. Sign and decimal point, as the SVG grammar allows;
            /// no exponent is used by the eight and none is read.
            mutating func number() -> Double? {
                skip()
                let from = i
                if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
                var digits = false
                while i < s.count, s[i].isNumber { i += 1; digits = true }
                if i < s.count, s[i] == "." {
                    i += 1
                    while i < s.count, s[i].isNumber { i += 1; digits = true }
                }
                guard digits else { i = from; return nil }
                return Double(String(s[from..<i]))
            }

            /// An arc's flag: **exactly one `0` or `1`**, and not a number
            /// that happens to start with one. The SVG grammar says a flag is
            /// a single character, so `a1 1 0 011 1` is radius 1, radius 1,
            /// rotation 0, large 0, sweep 1, then 1 and 1 -- and reading it
            /// with `number()` would take `011` as eleven.
            mutating func flag() -> Bool? {
                skip()
                guard i < s.count, s[i] == "0" || s[i] == "1" else { return nil }
                i += 1
                return s[i - 1] == "1"
            }
        }

        /// SVG's elliptical arc, as cubics (specification F.6.5).
        private enum Arc {
            static func segments(from p0: CGPoint, rx rxIn: Double, ry ryIn: Double,
                                 rot: Double, large: Bool, sweep: Bool, to p1: CGPoint) -> [Segment] {
                // A radius of zero is a straight line, by the specification's
                // own rule; so is an arc that goes nowhere.
                if rxIn == 0 || ryIn == 0 { return [.line(p1)] }
                if p0 == p1 { return [] }
                var rx = abs(rxIn), ry = abs(ryIn)
                let phi = rot * .pi / 180
                let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
                let x1p = cos(phi) * dx + sin(phi) * dy
                let y1p = -sin(phi) * dx + cos(phi) * dy
                // Radii too small to reach: grown until they just do.
                let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
                if lambda > 1 {
                    let k = lambda.squareRoot()
                    rx *= k
                    ry *= k
                }
                let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
                let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
                let sign: Double = (large == sweep) ? -1 : 1
                let co = sign * (max(num / den, 0)).squareRoot()
                let cxp = co * rx * y1p / ry
                let cyp = -co * ry * x1p / rx
                let cx = cos(phi) * cxp - sin(phi) * cyp + (p0.x + p1.x) / 2
                let cy = sin(phi) * cxp + cos(phi) * cyp + (p0.y + p1.y) / 2

                func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
                    let dot = ux * vx + uy * vy
                    let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
                    var a = acos(min(max(dot / len, -1), 1))
                    if ux * vy - uy * vx < 0 { a = -a }
                    return a
                }
                let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
                let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
                let theta1 = angle(1, 0, ux, uy)
                var dtheta = angle(ux, uy, vx, vy)
                if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
                if sweep && dtheta < 0 { dtheta += 2 * .pi }

                // No piece past a quarter turn: one cubic through more of a
                // circle than that is visibly flat, which is what a corner
                // radius of 1 would come out as.
                let n = max(1, Int((abs(dtheta) / (.pi / 2)).rounded(.up)))
                let delta = dtheta / Double(n)
                let t = 4.0 / 3.0 * tan(delta / 4)
                var out: [Segment] = []
                for step in 0..<n {
                    let th1 = theta1 + Double(step) * delta
                    let th2 = th1 + delta
                    func at(_ ex: Double, _ ey: Double) -> CGPoint {
                        CGPoint(x: cx + cos(phi) * rx * ex - sin(phi) * ry * ey,
                                y: cy + sin(phi) * rx * ex + cos(phi) * ry * ey)
                    }
                    let c1 = at(cos(th1) - t * sin(th1), sin(th1) + t * cos(th1))
                    let c2 = at(cos(th2) + t * sin(th2), sin(th2) - t * cos(th2))
                    // The last piece ends exactly on `p1`: a cubic run that
                    // stops a rounding error short of it leaves a drawing
                    // that does not close.
                    out.append(.cubic(c1, c2, step == n - 1 ? p1 : at(cos(th2), sin(th2))))
                }
                return out
            }
        }
    }
}

// MARK: - Looking for a file by name

extension ControlRoomWorkdirs {
    /// A search for a file name across the working directories (task 2670
    /// S5).
    ///
    /// # What it does not do
    ///
    /// **No file is read.** The only thing a search looks at is the names the
    /// core already handed over in a `files_list`; nothing here opens a file,
    /// asks for its size, or reads a byte. That is the scope the supervisor
    /// set (只做「搜文件名」，最多 200 条，不读文件内容), and it is also why the
    /// page keeps the design's 「搜内容」 tab drawn and greyed: a search of
    /// contents is a different kind of request, and drawing the tab as if it
    /// worked would be a control that answers nothing.
    ///
    /// **Directories are walked but never reported.** What a person searches
    /// for is a file, so a directory whose name matches is not a hit -- it is
    /// somewhere further to look.
    ///
    /// # Why the walk is here
    ///
    /// A listing is one level deep (`Listing.zig`), so looking for a name
    /// anywhere is a walk, and a walk has rules: where it starts, what order
    /// it goes in, when it stops. Those are values and are tested; the *asks*
    /// are the page's, because a rule cannot call the core.
    ///
    /// ⚠️ **`max_results` is a cap and the walk gives up at it.** 「最多 200
    /// 条」: once two hundred names match, the search stops reading
    /// directories rather than walking a whole tree to count matches nobody
    /// will be shown. `more` is how many more matched *in what was already
    /// read*, so the page can say 「还有 N 个」 -- and the count is exact for
    /// what was read and silent about what was not, which is why `capped` is
    /// told apart from a walk that emptied its queue.
    ///
    /// ⚠️ **And it is asked for a few directories at a time.** A search that
    /// walked a whole tree before drawing would do one `files_list` per
    /// directory on the app thread, and `files/README.md` says what that
    /// costs: `Workdirs.compute` already does one `realpath` per terminal per
    /// ask and a directory on a network mount can block the thread that
    /// draws, and a listing is the same kind of ask. So a search reads at
    /// most `max_asks` directories per round and says so (`stopped`) when
    /// there are more; the page's refresh continues the same walk where it
    /// left off rather than starting over.
    struct Search: Equatable {
        /// The most names one search answers with (the supervisor's ruling
        /// of 2026-11-02: 最多 200 条).
        static let max_results = 200

        /// The most directories one round of a search reads.
        ///
        /// **Not in the design and not decoration**: see the header. A round
        /// is one pass on the app thread, and this is what keeps it short.
        /// What it is not is a limit on the search -- the walk keeps its
        /// queue and the next round carries on.
        static let max_asks = 32

        /// The two tabs the design draws above the field, and **which of
        /// them is drawn as working**.
        ///
        /// The supervisor's scope for this task keeps both tabs on screen and
        /// greys one of them out (界面上保留「搜内容」那个切换按钮，但让它置
        /// 置灰). `enabled` is the rule and the page only reads it: a page that
        /// decided for itself which tab worked would be a second answer about
        /// what a search searches, and the day contents are searched the two
        /// would not move together.
        enum Mode: String, CaseIterable, Equatable {
            /// Looking inside files. **Drawn and not offered.**
            case content
            /// Looking at file names, which is the whole of this round.
            case filename

            /// Whether a press on this tab does anything.
            var enabled: Bool { self == .filename }
        }

        /// The tab the page opens on, which is the one that works: a field
        /// under a greyed tab is a field nothing can be typed into.
        static let mode: Mode = .filename

        /// One directory the walk has looked at or still has to look at.
        ///
        /// **`workdirId` and not a path**, because that is what a ticket is
        /// minted for (`files_open` wants the workdir's id and a path) and
        /// what the page has to know to ask for the next level. `path` is the
        /// real one, built from the root the core sent plus the names it
        /// sent -- never from anything the host made up. `rel` is where the
        /// directory sits under the root, which is what `files_list` wants.
        struct Place: Equatable, Hashable {
            var workdirId: String
            var path: String
            var rel: String
        }

        /// A file whose name matched. **A file**: see the type's header.
        struct Hit: Equatable, Hashable {
            var workdirId: String
            var path: String
            var name: String
        }

        private(set) var query: String
        private(set) var hits: [Hit] = []
        /// Matches past `max_results` seen in what was read; 0 when the walk
        /// finished inside the cap.
        private(set) var more: UInt64 = 0
        /// What is left to look at, in the order it will be.
        private(set) var queue: [Place] = []
        /// Whether the walk stopped because it had two hundred names rather
        /// than because there was nowhere left to look. **Two states, on
        /// purpose**: a page that drew 「还有 N 个」 for a walk that simply
        /// ended would be saying there are more when there are not.
        private(set) var capped = false
        /// How many directories this search has folded in.
        private(set) var read: UInt64 = 0

        init(roots: [Place], query: String) {
            self.query = query
            queue = roots
        }

        /// Whether a name is what the person is looking for.
        ///
        /// **The whole rule**, and it is deliberately this small: the query
        /// contained in the name, ASCII case ignored. Not a prefix, not a
        /// glob, not a regular expression -- the design's second search mode
        /// is 文件名 and the two options the design draws beside the field
        /// (case, whole word) are not in the scope the supervisor set. A
        /// wider rule here is a rule the page's status line would have to
        /// explain, and the field has nowhere to explain it.
        ///
        /// An empty query matches nothing: a search that has not been typed
        /// into shows no results rather than every file in the group.
        static func matches(name: String, query: String) -> Bool {
            guard !query.isEmpty else { return false }
            return name.range(of: query, options: .caseInsensitive) != nil
        }

        /// Whether the walk is over: nothing left to look at, or two hundred
        /// names already found.
        var done: Bool { capped || queue.isEmpty }

        /// Whether there is more of this walk to do **after this round**.
        ///
        /// ⚠️ **Its own question, and not `!done` wearing a second name.**
        /// A search that read `max_asks` directories and has more to read is
        /// not a search that found nothing: the page draws one of two
        /// sentences from this, and "no file by that name" is the other one.
        var moreToCome: Bool { !capped && !queue.isEmpty }

        /// The next directory to read, or nil when there is none.
        ///
        /// ⚠️ **A level already read is folded in and not returned.** The
        /// page may run a second search over a tree it has already walked --
        /// and the whole point of the page keeping the levels (`Levels`) is
        /// that a directory is read once. So anything already in the store is
        /// taken from the store, and only a directory nobody has read comes
        /// back to be asked for.
        ///
        /// A directory whose read was **refused** is stepped over rather than
        /// returned again: the core has already said it may not be listed,
        /// and asking a second time would be the same refusal.
        ///
        /// ⚠️ **Past `max_asks` a round stops with places still in the queue**,
        /// which is what `moreToCome` is for: what is left is the page's own
        /// record of directories nobody has looked in, and a walk that
        /// emptied its queue when it gave up could not be told from one that
        /// finished.
        mutating func next(in levels: Levels) -> Place? {
            while !capped, !queue.isEmpty {
                let place = queue.removeFirst()
                if let level = levels.level(place.path) {
                    read += 1
                    look(level, at: place)
                    continue
                }
                if levels.refusal(place.path) != nil { continue }
                return place
            }
            return nil
        }

        /// One round of the walk: read up to `budget` directories through
        /// `ask`, fold each answer in, and stop.
        ///
        /// **The whole walk, and the `ask` is handed in.** A rule cannot
        /// reach the core, so what the core is asked with is a closure the
        /// page passes (`ControlRoomWorkdirs.listingRequest` and its reading
        /// are the two halves of it) and a test passes one that answers from
        /// a table. Everything a walk *decides* -- which directory is next,
        /// what order, when to stop, what a refusal at one directory does to
        /// the rest -- is here and is a value.
        ///
        /// ⚠️ **A refusal is remembered and the walk goes on.** A directory
        /// the core will not list is one directory the person cannot see
        /// into; it is not a reason to answer nothing for the other roots,
        /// and `Levels.keepRefusal` is what makes the next round skip it
        /// rather than ask again.
        ///
        /// The budget is spent on **asks**, not on levels folded in from the
        /// page's store: a directory already read costs nothing, and charging
        /// for it would make a second search over a walked tree slower for no
        /// reason.
        mutating func round(in levels: inout Levels,
                            budget: Int = Search.max_asks,
                            ask: (Place) -> Result<Level, Failure>) {
            var left = budget
            while left > 0, let place = next(in: levels) {
                left -= 1
                switch ask(place) {
                case .success(let level):
                    levels.keep(level, at: place.path)
                    read += 1
                    look(level, at: place)
                case .failure(let why):
                    levels.keepRefusal(why, at: place.path)
                    read += 1
                }
            }
        }

        /// Fold one level in: every matching file is a hit, and every
        /// directory is somewhere further to look.
        ///
        /// **The core's order, and never a sort.** The level arrives
        /// directories-first and by name (`Listing.zig`), and the hits come
        /// out in the order the walk met them: a second order worked out here
        /// would be a second answer about what a search found, and
        /// `tools/control-room-hosts-do-not-decide.py` refuses a host that
        /// sorts at all.
        mutating func look(_ level: Level, at place: Place) {
            for entry in level.entries {
                if entry.is_dir {
                    guard !capped else { continue }
                    queue.append(Place(workdirId: place.workdirId,
                                       path: place.path + "/" + entry.name,
                                       rel: place.rel.isEmpty ? entry.name : place.rel + "/" + entry.name))
                    continue
                }
                guard Self.matches(name: entry.name, query: query) else { continue }
                if hits.count >= Self.max_results {
                    // The cap is what stops the walk: the count past it is
                    // kept so the page can say there are more, and nothing
                    // further is read.
                    more += 1
                    capped = true
                    continue
                }
                hits.append(Hit(workdirId: place.workdirId,
                                path: place.path + "/" + entry.name,
                                name: entry.name))
            }
        }
    }
}

// MARK: - What is in a directory

extension ControlRoomWorkdirs {
    /// One level of one directory, as the core's `files_list` answers it
    /// (task 2668).
    ///
    /// **The order and the exclusions are the core's**, and this type is the
    /// reading of them: `entries` arrives directories-first and by name, with
    /// the build output already gone (`files/Listing.zig`). Nothing here
    /// sorts, filters or reorders -- `tools/control-room-hosts-do-not-decide.py`
    /// refuses a host that does, and the reason is that a second order worked
    /// out here is a second answer about what the tree looks like.
    ///
    /// ⚠️ **`is_dir` and not the core's `kind`.** The five `files_*` requests
    /// beside this one answer `{"kind":"directory"}` for a path; a listing
    /// answers `is_dir`, a `Bool`, because a kind is a word to compare and a
    /// row that has to draw an icon needs one fact. The gate refuses a host
    /// that reads a `kind` anywhere, on the ground that there is nothing a
    /// kind is for in a host except comparing it.
    struct Level: Decodable, Equatable {
        var entries: [Row]
        /// How many entries were past the core's own limit and are not here
        /// (`Listing.max_entries`); the design draws 「还有 N 个」 for it. 0
        /// when the whole level came.
        var more: UInt64

        struct Row: Decodable, Equatable {
            /// The name only. The directory it is in is the one this level
            /// was asked about, so a row carries no path of its own.
            var name: String
            /// A directory, or a link that leads to one: which icon, and
            /// whether the row opens.
            var is_dir: Bool
        }
    }

    /// `files_list` for the directory the ticket `token` was made for, or
    /// for the directory `rel` names under it. **Empty `rel` is the ticket's
    /// own path**, which is one level of the directory the ticket is on.
    ///
    /// The `rel` is quoted rather than pasted, on `ControlRoomPageRequest`'s
    /// reason: a name with a quote in it would otherwise build a request that
    /// is not JSON, and the core would answer a parse failure about a request
    /// this host wrote.
    static func listingRequest(token: String, rel: String = "") -> String {
        "{\"method\":\"files_list\",\"params\":{"
            + "\"token\":\(ControlRoomPageRequest.quoted(token)),"
            + "\"rel\":\(ControlRoomPageRequest.quoted(rel))}}"
    }

    /// The level, or what could not be read of it.
    ///
    /// ⚠️ **Three outcomes, the same three `read(_:)` has**, and for the same
    /// reason: the core answers a refusal **inside the same shape**
    /// (`{"refused":"access","reason":"outside","why":…}` from `Tickets`, and
    /// `{"refused":"bad_request",…}` from the door), so a reader that folded
    /// those into "not JSON" would call a well-formed refusal a parse failure
    /// and throw away the core's own word for what was wrong.
    ///
    /// The refusal's `why` is kept as well as its name: `refused` is what a
    /// caller branches on and `why` is the sentence a person reads, and the
    /// two are the core's own (`Access.Refusal.say`, `Tickets.Refusal`).
    static func readListing(_ text: String) -> Result<Level, Failure> {
        guard let data = text.data(using: .utf8) else { return .failure(.notJSON) }
        if let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let error = v["error"] as? String { return .failure(.refused(error)) }
            if let refused = v["refused"] as? String {
                return .failure(.refusedFile(code: refused, why: v["why"] as? String))
            }
        }
        do {
            return .success(try JSONDecoder().decode(Level.self, from: data))
        } catch {
            return .failure(.notJSON)
        }
    }
}

// MARK: - What the tree has asked for, and what is open under a root

extension ControlRoomWorkdirs {
    /// One level of a directory per directory, and which of those
    /// directories the person has opened.
    ///
    /// **What a directory holds is asked for once and kept.** The side of the
    /// page this belongs to redraws on every keystroke in the search field
    /// and on every notice from the core, and a `files_list` per redraw would
    /// be a directory read per redraw -- on the app thread, for the same
    /// reason `files/README.md` gives about `realpath`. Nothing here expires:
    /// what is in a directory changes, and the page says so by asking again
    /// (`forget` then a redraw), which is a person's act rather than a
    /// clock's.
    ///
    /// **Lazy, so a directory under a root starts shut.** The design's tree
    /// draws a folder's children only when it is opened (the supervisor's
    /// scope for task 2670: 文件树按目录懒加载), and a level nobody has
    /// opened is a directory nobody has walked. `open` below says the rest.
    ///
    /// ⚠️ **A directory is named by its path, and the path is the real one.**
    /// Two rows of the tree can reach the same directory by two spellings
    /// (`.`, `sub/..`), so a key of the spelling the page drew would be two
    /// entries for one directory -- one of them stale, and the page would
    /// draw whichever it looked up. What the page has is the level's path
    /// under its parent, so the key is that path joined onto the parent it
    /// was read under; the root's own path is the one the core sent in the
    /// directory row.
    ///
    /// **A level that could not be read is not stored.** Empty and "the core
    /// refused" are two states the page draws differently -- one is a
    /// directory with nothing in it, the other is a sentence about why -- so
    /// a refusal stored as an empty level would draw the wrong one for ever.
    /// The refusal is kept beside it instead, for the one row it belongs to.
    ///
    /// **Roots are not here.** Which roots are open is `Tree`'s, which the
    /// page already has and which its own tests hold; this type is about the
    /// directories *under* them, so the two do not both remember a root.
    struct Levels: Equatable {
        private(set) var levels: [String: Level] = [:]
        /// What went wrong for a directory, by the same key, for the rows
        /// that could not be read. Drawn instead of a level.
        private(set) var refused: [String: Failure] = [:]
        /// The directories under the roots somebody has opened, by path.
        ///
        /// ⚠️ **Open, and not shut, which is `Tree`'s choice the other way
        /// round.** A *root* is open the moment it appears (the supervisor's
        /// ruling of 2026-11-02: 根第一次出现时展开), and a set of shut ids
        /// is how `Tree` says that. A directory *under* a root is the
        /// opposite: its level is a `files_list` the core has to walk, and a
        /// page that treated every directory as open would read the whole
        /// tree the first time a root was opened. So the untouched state
        /// here is **shut**, and the bit that is kept is the one that
        /// separates "nobody has decided" from "somebody opened it" -- which
        /// is the same bit `Tree` keeps, pointed the other way because the
        /// expensive default is the other one.
        ///
        /// ⚠️ **`Search` ignores this.** A filename search walks every
        /// directory it has a level for, open or shut: what a search shows
        /// is not what the tree happens to be drawn with (`Search` says so).
        private(set) var open: Set<String> = []

        /// The ticket each root's tree is listed with, by workdir id.
        ///
        /// **One per root, and minted once.** `files_list` is a request the
        /// core answers only for a ticket, and a ticket is minted for one
        /// workdir and one scope (`Tickets.zig`); asking for a fresh one per
        /// directory would spend the core's ledger (`max_tickets`) on
        /// directories the person has already looked at, and would push
        /// *other* hosts' tickets out of it -- whose symptom, somebody
        /// else's preview going blank, is nowhere near the code that caused
        /// it. So a root's ticket is kept and reused for every level under
        /// it, which is also why `forget` gives them up (below).
        ///
        /// ⚠️ **The scope is `workdir`, and that is wider than a preview's
        /// `file` on purpose.** A tree shows what is *under* a directory, so
        /// a ticket that reached only its own anchor could list one level and
        /// nothing below (`Tickets`' own test says so: a `.file` ticket on a
        /// directory lists it and refuses the directory under it). This is
        /// the one place a wider ticket is asked for, and it is asked for by
        /// the thing that needs it -- the file opened in the workbench gets a
        /// ticket of its own, on itself (`PreviewTicket`).
        private(set) var tickets: [String: String] = [:]

        func ticket(_ workdirId: String) -> String? { tickets[workdirId] }

        /// Remember the ticket a root's tree is listed with. **The first one
        /// wins**: a second token for a root already held would be a second
        /// ticket for one tree, and the one the page went on listing with
        /// would be whichever the call order happened to leave behind.
        mutating func keepTicket(_ token: String, for workdirId: String) {
            guard tickets[workdirId] == nil else { return }
            tickets[workdirId] = token
        }

        init() {}

        func level(_ path: String) -> Level? { levels[path] }

        func refusal(_ path: String) -> Failure? { refused[path] }

        /// Whether this directory has ever been asked for. **Different from
        /// "its level is empty"**, which is an answer: a row nobody has
        /// asked about shows nothing yet and must ask, and a row that was
        /// asked about and came back empty must not ask again on every
        /// redraw.
        func hasAsked(_ path: String) -> Bool {
            levels[path] != nil || refused[path] != nil
        }

        mutating func keep(_ level: Level, at path: String) {
            levels[path] = level
            refused[path] = nil
        }

        /// The core refused this directory: the refusal is drawn, and the
        /// directory counts as asked about so the page does not ask again on
        /// every redraw.
        mutating func keepRefusal(_ failure: Failure, at path: String) {
            levels[path] = nil
            refused[path] = failure
        }

        /// Everything that was read is gone: the group changed, or the core
        /// was asked again from scratch. The opened directories go too, on
        /// `Tree.keep(only:)`'s reason -- a directory that comes back comes
        /// back **shut** rather than wearing a decision made about a
        /// directory the group had before (the untouched state is shut; the
        /// set above says why).
        ///
        /// ⚠️ **The tickets go with the rest**, and that half is the one easy
        /// to leave behind: a ticket is minted for one workdir of one group
        /// (`Tickets.open`), so one kept across a change of group is a token
        /// this page would go on listing with against a directory that group
        /// may not have. The core would answer `no_workdir`, and the page
        /// would draw that as a directory it may not read rather than as a
        /// request made with the wrong group's ticket. The core holds its
        /// tickets in a ledger with a cap (`Tickets.max_tickets`), which is
        /// the second reason: a page that hoarded one per group would push
        /// other hosts' tickets out of it.
        mutating func forget() {
            levels.removeAll()
            refused.removeAll()
            open.removeAll()
            tickets.removeAll()
        }

        func isOpen(_ path: String) -> Bool { open.contains(path) }

        mutating func toggle(_ path: String) {
            if open.contains(path) { open.remove(path) } else { open.insert(path) }
        }
    }
}

// MARK: - The rows the tree draws

extension ControlRoomWorkdirs {
    /// One row of the file tree under a root, as the page draws it (task 2670
    /// S4).
    ///
    /// **A row and not a view, and it carries no glyph.** Which of the eight
    /// icons a row gets is `Glyph.of(name:isDir:open:)`'s, asked by the page
    /// with the three facts below; a second answer here would be a second
    /// place for the two to come apart.
    ///
    /// `path` is the real path -- the root's own path with the names the core
    /// sent joined on -- and `rel` is where that is under the root, which is
    /// what `files_list` takes. **Both are built from the core's names and
    /// from nothing else** (the supervisor's scope: 路径只用核心给的名字来
    /// 拼): a path the host made up would name a directory the core never
    /// listed.
    struct Node: Equatable {
        var name: String
        var path: String
        var rel: String
        var isDir: Bool
        /// 1 for a row directly under the root, 2 for one under that, and so
        /// on: the design indents one step of 16 per level.
        var depth: Int
    }

    /// The rows under one root, **in the core's order and with no sort**.
    ///
    /// A directory's own rows are drawn only when the directory is open
    /// (`isOpen`) and have been read: the tree is lazy (the supervisor's
    /// scope: 文件树按目录懒加载), so a directory nobody has opened is a
    /// directory nobody has walked, and `Levels.level` has nothing for it.
    ///
    /// ⚠️ **Nothing is filtered, reordered or counted here.** The core sends
    /// the level directories-first and by name and with the build output
    /// already gone (`Listing.zig`), and
    /// `tools/control-room-hosts-do-not-decide.py` refuses a host that sorts
    /// or that works the order out a second time.
    static func nodes(under root: Dir, in levels: Levels) -> [Node] {
        var out: [Node] = []
        func walk(_ path: String, _ rel: String, _ depth: Int) {
            guard let level = levels.level(path) else { return }
            for entry in level.entries {
                let childRel = rel.isEmpty ? entry.name : rel + "/" + entry.name
                let childPath = path + "/" + entry.name
                out.append(Node(name: entry.name, path: childPath, rel: childRel,
                                isDir: entry.is_dir, depth: depth))
                if entry.is_dir, levels.isOpen(childPath) { walk(childPath, childRel, depth + 1) }
            }
        }
        walk(root.path, "", 1)
        return out
    }
}
