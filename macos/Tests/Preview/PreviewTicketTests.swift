import Foundation
import Testing

@testable import Ghostty

/// Asking the core for a capability ticket, and reading what came back
/// (`PreviewTicket`).
///
/// **This is the fence's first step**, so the tests here are about what is
/// refused as much as about what is read: a token that is not a token, a
/// refusal the core gave instead of a ticket, an answer that is neither.
struct PreviewTicketTests {
    typealias Ticket = PreviewTicket

    private let workdir = "0123456789abcdef"
    private let goodToken = "0123456789abcdef0123456789abcdef"

    private func answer(token: String = "0123456789abcdef0123456789abcdef") -> String {
        """
        {"token":"\(token)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","encoding":"utf8","eol":"lf",
        "editable":true,"not_editable":null,"version":"v1"}}
        """
    }

    // MARK: The request

    @Test func theRequestIsFilesOpenForOneFile() {
        let text = Ticket.request(workdirId: workdir, path: "docs/a.md")
        #expect(text == """
        {"method":"files_open","params":{"workdir_id":"0123456789abcdef",\
        "path":"docs/a.md","scope":"file"}}
        """)
    }

    /// **The scope is `.file` unless asked otherwise.** A preview shows one
    /// file; the whole working directory is a wider capability than the
    /// window it is drawn in needs, and the design states the widening per
    /// plugin where it is wanted.
    @Test func theScopeDefaultsToTheFileItself() {
        #expect(Ticket.request(workdirId: workdir, path: "a.md").contains("\"scope\":\"file\""))
        #expect(Ticket.request(workdirId: workdir, path: "a.md", scope: "siblings")
            .contains("\"scope\":\"siblings\""))
    }

    /// A path with a quote or a backslash in it goes into the request as
    /// JSON, not as itself: a name that is a name on disk is not a name
    /// that is a name inside a JSON string.
    @Test func aPathIsQuotedRatherThanPasted() {
        let text = Ticket.request(workdirId: workdir, path: "a\"b\\c\nd")
        #expect(text.contains(#""path":"a\"b\\c\nd""#))
        // And what it built is JSON at all: a request the core could not
        // parse would come back as a bad-params refusal that reads as a
        // bug in the request rather than as a name with a quote in it.
        let body = Data(text.utf8)
        #expect((try? JSONSerialization.jsonObject(with: body)) != nil)
    }

    // MARK: Reading the answer

    @Test func aTicketIsReadWithItsInfo() throws {
        let answer = try Ticket.read(answer()).get()
        #expect(answer.token == goodToken)
        #expect(answer.info.name == "a.md")
        #expect(answer.info.kind == "file")
        #expect(answer.info.size == 12)
        #expect(answer.info.mtime_ns == "1700000000000000000")
        #expect(answer.info.editable)
        #expect(answer.info.not_editable == nil)
        #expect(answer.info.version == "v1")
    }

    /// **A refusal is an answer, not a parse failure.** The core refuses in
    /// one shape (`{"refused":…,"why":…}`), and the sentence in `why` is the
    /// only thing that says why a preview is empty. A reader that only
    /// knew the happy shape would report every refusal as "unreadable",
    /// which names nothing.
    @Test func aRefusalKeepsTheCoresOwnSentence() {
        let text = #"{"refused":"outside","why":"it is not in this working directory"}"#
        guard case .failure(.refused(let why)) = Ticket.read(text) else {
            Issue.record("a refusal was not read as a refusal")
            return
        }
        #expect(why == "it is not in this working directory")
    }

    @Test func aRefusalWithNoReasonStillSaysWhichOne() {
        guard case .failure(.refused(let why)) = Ticket.read(#"{"refused":"no_workdir"}"#) else {
            Issue.record("a refusal was not read as a refusal")
            return
        }
        #expect(why == "no_workdir")
    }

    @Test func anAnswerThatIsNeitherIsUnreadable() {
        for text in ["", "not json", "[]", #"{"token":12}"#] {
            #expect(Ticket.read(text) == .failure(.unreadable), "at \(text)")
        }
    }

    // MARK: Who shows the file

    /// The core says which plugin answers for this file, beside the ticket
    /// (`previewAnswer`, task 2758), and -- with contract 2789 -- where that
    /// plugin's page is. The host reads all of it rather than deciding any
    /// of it for itself.
    @Test func aMatchedChoiceIsReadWithItsScope() throws {
        let text = """
        {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","encoding":"utf8","eol":"lf",
        "editable":true,"not_editable":null,"version":"v1"},
        "plugin":{"status":"matched","key":"edit-text","reads":"file"}}
        """
        let answer = try Ticket.read(text).get()
        #expect(answer.plugin == .matched(.init(
            key: "edit-text", reads: "file", render: nil, page: nil, pluginDir: nil)))
    }

    // MARK: Where the page is

    /// The three location fields are read as the core sends them, and the
    /// join is the core's `plugin_dir` plus the manifest's `page`.
    @Test func aMatchedPageIsLocatedFromWhatTheCoreSent() throws {
        let text = """
        {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","editable":true},
        "plugin":{"status":"matched","key":"edit-text","reads":"file",
        "render":"page","page":"page/index.html","plugin_dir":"/opt/polter/plugins/edit-text"}}
        """
        guard case .success(let answer) = Ticket.read(text),
              case .matched(let matched)? = answer.plugin
        else {
            Issue.record("a full matched row did not read")
            return
        }
        #expect(matched.render == "page")
        #expect(matched.page == "page/index.html")
        #expect(matched.pluginDir == "/opt/polter/plugins/edit-text")
        guard case .success(let where_) = Ticket.pageLocation(of: matched) else {
            Issue.record("a page that is all there was not located")
            return
        }
        #expect(where_ == PreviewPluginPage.Location(
            key: "edit-text", root: "/opt/polter/plugins/edit-text", page: "page/index.html"))
        #expect(where_.url?.path == "/page/index.html")
        #expect(where_.url?.host == "edit-text")
    }

    /// **A missing field is "the page is not known", never a path this host
    /// invents.** The three location fields are new, so a core that predates
    /// them leaves a matched row with none of them -- and the honest answer
    /// is that nothing here knows where to load a page from.
    @Test func notBeingToldWhereThePageIsIsNotAGuess() throws {
        let cases: [(String, Ticket.PageRefusal)] = [
            (#"{"status":"matched","key":"edit-text","reads":"file"}"#, .renderUnknown),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":""}"#, .renderUnknown),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"browser","page":"x.html","plugin_dir":"/p"}"#, .notAPagePlugin),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","plugin_dir":"/p"}"#, .pageUnknown),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"x.html"}"#, .pluginDirUnknown),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"x.html","plugin_dir":""}"#, .pluginDirUnknown),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"x.html","plugin_dir":"relative/dir"}"#, .pluginDirNotAbsolute),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"../x.html","plugin_dir":"/p"}"#, .pageNotRelative),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"/etc/x.html","plugin_dir":"/p"}"#, .pageNotRelative),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"a/../../x.html","plugin_dir":"/p"}"#, .pageNotRelative),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"c:\\x.html","plugin_dir":"/p"}"#, .pageNotRelative),
            (#"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"a:b/x.html","plugin_dir":"/p"}"#, .pageNotRelative),
        ]
        for (plugin, want) in cases {
            let text = """
            {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
            "mtime_ns":"1700000000000000000","editable":true},"plugin":\(plugin)}
            """
            guard case .success(let answer) = Ticket.read(text),
                  case .matched(let matched)? = answer.plugin
            else {
                Issue.record("did not read a matched row: \(plugin)")
                continue
            }
            #expect(Ticket.pageLocation(of: matched) == .failure(want), "at \(plugin)")
            // **One sentence whatever the cause**, and it is the product's:
            // which field the core left out is deliberately not said to a
            // person (`PageRefusal` has no words of its own).
            #expect(Ticket.pluginUnavailable == String(
                localized: "This preview plugin is not available."))
        }
    }

    /// **The must-not of S7B.** A plugin that claims the file with a page the
    /// host cannot locate must never be read as "show the file" -- that is
    /// the silent fallback where an unloadable plugin page is drawn as the
    /// file and looks exactly like success.
    ///
    /// A `browser` plugin is its own case and not the broken one: nothing is
    /// wrong with it, the host has not built that path.
    @Test func anUnloadablePluginPageIsNotTheFile() throws {
        func presentation(_ plugin: String) throws -> Ticket.Presentation {
            let text = """
            {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
            "mtime_ns":"1700000000000000000","editable":true},"plugin":\(plugin)}
            """
            return try Ticket.read(text).get().presentation
        }

        // No plugin claimed it, and a core that did not say: the file.
        #expect(try presentation(#"{"status":"none","key":null}"#) == .file)
        #expect(try Ticket.read("""
        {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","editable":true}}
        """).get().presentation == .file)

        // A page plugin, located: the page.
        #expect(try presentation(
            #"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"page/index.html","plugin_dir":"/opt/p"}"#)
            == .pluginPage(.init(key: "edit-text", root: "/opt/p", page: "page/index.html")))

        // A page plugin whose page will not load: **not `.file`**.
        for plugin in [
            #"{"status":"matched","key":"edit-text","reads":"file"}"#,
            #"{"status":"matched","key":"edit-text","reads":"file","render":"page","plugin_dir":"/p"}"#,
            #"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"x.html"}"#,
            #"{"status":"matched","key":"edit-text","reads":"file","render":"page","page":"../x.html","plugin_dir":"/p"}"#,
        ] {
            #expect(try presentation(plugin) == .unavailable, "at \(plugin)")
        }

        // `browser` is its own case, and says so; the log gets no refusal for
        // it, because nothing was refused.
        let browser = try Ticket.read("""
        {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","editable":true},
        "plugin":{"status":"matched","key":"archive","reads":"file","render":"browser","page":"x.html","plugin_dir":"/p"}}
        """).get()
        #expect(browser.presentation == .browser)
        #expect(Ticket.browserPreviewNotYet != Ticket.pluginUnavailable)
    }

    /// The page path rule is the core's (`Plugin.zig`'s `pageRefusal`: no
    /// `..`, nothing absolute, no colon, no NUL). A `..` **substring** is an
    /// ordinary name and must not be refused.
    @Test func aPagePathIsPlainAndRelative() {
        for good in ["index.html", "page/index.html", "a..b/x.html", "场景/x.html", "./x.html"] {
            #expect(Ticket.isRelativePagePath(good), "at \(good)")
        }
        for bad in ["", "/x.html", "../x.html", "a/../b.html", "..", "a\\b.html", "x\u{0}y", "c:/x.html"] {
            #expect(!Ticket.isRelativePagePath(bad), "at \(bad.debugDescription)")
        }
    }

    /// **`nil` and `Choice.none` are two different answers.** `nil` is a core
    /// that never carried the key; `Choice.none` is a core that looked and
    /// said nothing answers for this file.
    ///
    /// ⚠️ **The right-hand side has to be spelled `Ticket.Answer.Choice.none`.**
    /// Written as a bare `.none` in a comparison against an optional, Swift
    /// resolves it to `Optional.none` -- i.e. `nil` -- so the assertion would
    /// pass on a decoder that reported "nothing chose this file" as "not
    /// told", which is the exact confusion this test exists to catch.
    @Test func notBeingToldIsNotTheSameAsNothingChoseIt() throws {
        // The `answer()` fixture above has no `plugin` key at all.
        let untold = try Ticket.read(answer()).get()
        #expect(untold.plugin == nil)

        let none = try Ticket.read("""
        {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","editable":true},
        "plugin":{"status":"none","key":null}}
        """).get()
        #expect(none.plugin == Ticket.Answer.Choice.none)
        #expect(none.plugin != nil, "`Claim none` was read as `not told`")
        #expect(none.plugin != untold.plugin)
    }

    /// The four ways a named plugin does not get used, each kept apart: a
    /// caller asking for a plugin that is not there, one that is switched
    /// off, and one that is not a preview at all are three different
    /// sentences on the host's side, and collapsing them loses the one that
    /// says what to do about it.
    @Test func aNamedPluginThatIsNotUsedSaysWhichWay() throws {
        for (status, want) in [
            ("specified_not_found", Ticket.Answer.Choice.specifiedNotFound(key: "nope")),
            ("specified_disabled", .specifiedDisabled(key: "codex")),
            ("specified_unsupported", .specifiedUnsupported(key: "archive")),
        ] {
            let text = """
            {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
            "mtime_ns":"1700000000000000000","editable":true},
            "plugin":{"status":"\(status)","key":\(status == "specified_disabled" ? "\"codex\"" : status == "specified_unsupported" ? "\"archive\"" : "\"nope\"")}}
            """
            let answer = try Ticket.read(text).get()
            #expect(answer.plugin == want, "at \(status)")
        }
    }

    /// **A choice nobody here knows does not take the ticket with it.** A
    /// status a later core adds is a field this build cannot read, and the
    /// ticket beside it is still a ticket the file can be read through --
    /// so it is `nil` ("not told"), not an unreadable answer.
    @Test func anUnknownStatusLeavesTheTicketReadable() throws {
        let text = """
        {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","editable":true},
        "plugin":{"status":"something_new","key":"x"}}
        """
        let answer = try Ticket.read(text).get()
        #expect(answer.token == goodToken)
        #expect(answer.plugin == nil)
    }

    /// `matched` without its `reads` is half a row, and half a row is not
    /// filled in with a guess -- there is no default scope here, because a
    /// default would be this file inventing a permission.
    @Test func aMatchedChoiceWithNoScopeIsNotFilledIn() throws {
        let text = """
        {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
        "mtime_ns":"1700000000000000000","editable":true},
        "plugin":{"status":"matched","key":"edit-text"}}
        """
        let answer = try Ticket.read(text).get()
        #expect(answer.plugin == nil)
    }

    /// **A `matched` that names no plugin is not a match.** The core cannot
    /// write one -- it would not have loaded a manifest with such a key
    /// (`Plugin.isPlainName`) -- so a `matched` with a missing, empty or
    /// impossible key is this host reading its own answer wrong, and reading
    /// it as a match would open the preview against a plugin that does not
    /// exist. It is "not told" instead.
    @Test func aMatchThatNamesNoPluginIsNotAMatch() throws {
        // Every one of these is JSON a core could not have written; the
        // reader must not turn any of them into a plugin named something.
        for key in [#"null"#, #""""#, #"" ""#, #""a/b""#, #""../x""#,
                    #""has space""#, #""中文""#, #"42"#,
                    "\"" + String(repeating: "a", count: 65) + "\""] {
            let text = """
            {"token":"\(goodToken)","info":{"name":"a.md","kind":"file","size":12,
            "mtime_ns":"1700000000000000000","editable":true},
            "plugin":{"status":"matched","key":\(key),"reads":"file"}}
            """
            let answer = try Ticket.read(text).get()
            #expect(answer.plugin == nil, "at key \(key)")
            // The ticket itself is untouched: a choice that could not be
            // read is not a reason to lose the file.
            #expect(answer.token == goodToken)
        }
    }

    /// The key rule is `Plugin.isPlainName`'s: 1...64 of `[A-Za-z0-9._-]`,
    /// and not `.` or `..`. Both sides read the same manifests, so a key
    /// this refuses is one the core would not have loaded.
    @Test func aPluginKeyIsWhatTheCoreWouldLoad() {
        for good in ["edit-text", "codex", "opencode-v2", "a", ".hidden", "A_b-9."] {
            #expect(Ticket.isPluginKey(good), "at \(good)")
        }
        for bad in ["", ".", "..", "a/b", "a b", "../x", "中文", "a\n",
                    String(repeating: "a", count: 65)] {
            #expect(!Ticket.isPluginKey(bad), "at \(bad.debugDescription)")
        }
    }

    // MARK: What may be a token

    /// 32 lower-case hex digits: what the core mints and what
    /// `PreviewRoutes` takes as a URL's authority. **A token that is not
    /// one is refused here**, where the answer can be named as a bad
    /// answer, rather than one step later in the router, where it reads as
    /// a routing bug.
    @Test func aTokenThatIsNotATokenIsNotATicket() {
        #expect(Ticket.isToken(goodToken))
        for bad in ["", "abc", goodToken + "0", String(goodToken.dropLast()),
                    goodToken.uppercased(), String(repeating: "g", count: 32),
                    String(repeating: "0", count: 31) + " "] {
            #expect(!Ticket.isToken(bad), "at \(bad.debugDescription)")
            #expect(Ticket.read(answer(token: bad)) == .failure(.unreadable),
                    "at \(bad.debugDescription)")
        }
    }

    /// **The one that would otherwise get through.** An empty token parses
    /// as a string and would build `polter-file:///rel`, whose authority is
    /// nothing; a token with a `/` in it would build a route whose `rel` is
    /// not the one that was asked for.
    @Test func anEmptyOrSlashBearingTokenIsRefused() {
        #expect(Ticket.read(answer(token: "")) == .failure(.unreadable))
        #expect(Ticket.read(answer(token: "aaaa/bbbb")) == .failure(.unreadable))
    }

    // MARK: The whole way through

    @Test func openBuildsTheRequestAndReadsTheAnswer() {
        var asked: [String] = []
        let source = Ticket.Source { request in
            asked.append(request)
            return .success(self.answer())
        }
        let answer = try? Ticket.open(source, workdirId: workdir, path: "docs/a.md").get()
        #expect(answer?.token == goodToken)
        #expect(asked == [Ticket.request(workdirId: workdir, path: "docs/a.md")])
    }

    /// **The core not running is a failure and not an empty ticket.** A
    /// caller that treated it as success would go on to build a URL out of
    /// nothing and a page would load with an empty authority.
    @Test func aCoreThatIsNotThereIsNotATicket() {
        #expect(Ticket.open(.none, workdirId: workdir, path: "a.md") == .failure(.notReady))
    }

    @Test func aRefusalTravelsBackThroughOpen() {
        let source = Ticket.Source { _ in
            .success(#"{"refused":"out_of_scope","why":"it is outside what this preview may read"}"#)
        }
        guard case .failure(.refused(let why)) =
                Ticket.open(source, workdirId: workdir, path: "a.md") else {
            Issue.record("the refusal did not travel back")
            return
        }
        #expect(why == "it is outside what this preview may read")
    }

    // MARK: Handing the ticket back

    /// The other half of `open`. The core keeps tickets in a ledger with a
    /// cap and drops the oldest when it fills, so a host that never closed
    /// one would push other people's out -- and the symptom, somebody
    /// else's preview going blank, is nowhere near the code that caused it.
    @Test func closingAsksForFilesCloseWithTheToken() {
        var asked: [String] = []
        let source = Ticket.Source { request in
            asked.append(request)
            return .success(#"{"closed":true}"#)
        }
        #expect(Ticket.close(source, token: goodToken) == .success(Ticket.Closed()))
        #expect(asked == [Ticket.closeRequest(token: goodToken)])
        #expect(asked.first == #"{"method":"files_close","params":{"token":"0123456789abcdef0123456789abcdef"}}"#)
    }

    /// **A token that was never handed out is not asked about.** Closing
    /// nothing is a success and not a request: an empty token would address
    /// somebody else's ticket, which is the one thing a host must not do.
    @Test func closingNothingAsksForNothing() {
        var asked = 0
        let source = Ticket.Source { _ in
            asked += 1
            return .success(#"{"closed":true}"#)
        }
        #expect(Ticket.close(source, token: "") == .success(Ticket.Closed()))
        #expect(Ticket.close(source, token: "not-a-token") == .success(Ticket.Closed()))
        #expect(asked == 0)
    }

    /// A core that is not there is still a failure here: the ticket was not
    /// given back, and a caller that treated it as done would leak the slot
    /// for the rest of the run.
    @Test func closingAgainstACoreThatIsNotThereFails() {
        #expect(Ticket.close(.none, token: goodToken) == .failure(.notReady))
    }

    // MARK: The path

    /// ⚠️ **A `..` component is refused here, before the core is asked.**
    /// The core's own guard is the fence (`Access.resolve` realpaths and
    /// judges every link), but a request whose answer is already known
    /// spends a round trip and comes back as a refusal that reads like a
    /// routing fault rather than like a path that was never one to ask
    /// about.
    ///
    /// **Stricter than the core, deliberately.** `a/../b` settles back
    /// inside, and the core allows exactly that shape (`sub/../sub/a.txt`
    /// has a test pinning it). This refuses it anyway: matching the core
    /// would mean writing a second copy of its resolution, and a copy of a
    /// fence that is slightly wrong is a hole. The cost is unreachable --
    /// `files_open`'s path is painted by this host's own UI -- and the
    /// reason is written out at `pathRefusal`. Asserted here so the
    /// strictness is a decision on the record and not an accident.
    @Test func aPathThatGoesUpIsRefusedWithoutAsking() {
        for path in ["../etc/passwd", "docs/../../x", "..", "a/../b"] {
            #expect(Ticket.pathRefusal(path) != nil, "at \(path)")
        }
        var asked = 0
        let source = Ticket.Source { _ in
            asked += 1
            return .success(self.answer())
        }
        guard case .failure(.notAPath) =
                Ticket.open(source, workdirId: workdir, path: "../x") else {
            Issue.record("a `..` path was not refused")
            return
        }
        #expect(asked == 0, "the core was asked about a path refused here")
    }

    /// **A `..` substring is not a `..` component**, and an empty path is
    /// not a path either. `a..b/c.md` is an ordinary name and refusing it
    /// would refuse a file that is really there.
    @Test func aNameThatMerelyContainsDotsIsAPath() {
        for path in ["a..b/c.md", "..hidden/f", "a.md", "/abs/x", "docs/.hidden"] {
            #expect(Ticket.pathRefusal(path) == nil, "at \(path)")
        }
        #expect(Ticket.pathRefusal("") != nil)
        #expect(Ticket.pathRefusal("a\u{0}b") != nil)
    }
}
