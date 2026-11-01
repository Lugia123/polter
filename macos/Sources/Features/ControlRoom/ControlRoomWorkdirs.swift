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
