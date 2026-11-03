import Foundation

/// Asking the core for a **capability ticket**: the one thing a preview
/// needs before it can show anything at all (task 2634, #2140 M2;
/// `files/Tickets.zig`, task 2573 C7).
///
/// **Why this exists at all.** `PreviewBridge` is handed a URL of the shape
/// `polter-file://<token>/<rel>`, and the token is what makes reading safe:
/// it was minted for one workdir and one scope, and the core judges every
/// path against *that ticket* on every call. Nothing in a host may make one
/// up -- an unguessable 32-hex token that a host could invent is a fence a
/// host could walk around. So the ticket is asked for, through
/// `ghostty_app_files`, and this file is the request and the reading of the
/// answer.
///
/// **The call itself is not here.** `Source` is a closure, the way
/// `ControlRoomPageSource` is: the app hands in the one that reaches
/// `ghostty_app_files` (which names `GhosttyKit`, so it cannot be in this
/// package), and a test hands in one that answers from a string. Everything
/// this file decides -- which request is built, what a refusal looks like,
/// what a token is -- is decided without an app.
enum PreviewTicket {
    /// A ticket, as the core's `files_open` answers it. Every key is always
    /// there; the names are `Tickets.open`'s.
    struct Answer: Decodable, Equatable {
        /// 32 lower-case hex digits, minted by the core.
        var token: String
        var info: Info

        /// Which plugin the core chose to show this file
        /// (`previewAnswer`, task 2758).
        ///
        /// **`nil` is "not told"; `Choice.none` is "told, and nothing
        /// answers".** One is a question that was never asked.
        ///
        /// ⚠️ **`== .none` on this optional means `== nil`.** `Optional` has
        /// its own `.none`, so spell the comparison `Choice.none` (or
        /// `.some(.none)`) at every call site.
        var plugin: Choice?

        private enum CodingKeys: String, CodingKey {
            case token, info, plugin
        }

        /// `plugin` is read leniently: a status or key this build cannot
        /// make sense of is `nil`, not a thrown error. Losing the ticket
        /// over a field beside it would lose the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            info = try c.decode(Info.self, forKey: .info)
            plugin = try? c.decodeIfPresent(Choice.self, forKey: .plugin)
        }

        /// The five cases `previewAnswer` writes. Anything else throws, and
        /// `Answer.init(from:)` turns that back into `nil`.
        enum Choice: Decodable, Equatable {
            /// A plugin answers for this file.
            case matched(Matched)
            /// The core looked and no plugin answers.
            case none
            /// Asked for by name: no such plugin installed.
            case specifiedNotFound(key: String)
            /// Asked for by name: installed and switched off.
            case specifiedDisabled(key: String)
            /// Asked for by name: installed, but not a preview plugin.
            case specifiedUnsupported(key: String)

            /// A `matched` row (task 2779 S7B, contract 2789).
            ///
            /// **The three location fields are optional, and a missing one
            /// is "where the page is is not known" -- never a reason to
            /// guess.** `plugin_dir` is the absolute root the plugin manager
            /// scanned, `page` is a relative path inside it, and `render` is
            /// the manifest's own tag. A host with any of them absent has no
            /// page to load and must say so.
            struct Matched: Decodable, Equatable {
                /// The plugin's key: `Plugin.isPlainName`.
                var key: String
                /// The scope the manifest declared. A declaration, not a
                /// permission: the ticket beside it was opened with the
                /// caller's own scope.
                var reads: String
                /// The manifest's `preview.render`: `page` or `browser`.
                var render: String?
                /// The manifest's `preview.page`, relative to `pluginDir`.
                /// Present for a `page` plugin only.
                var page: String?
                /// The plugin's directory, absolute, as the manager found
                /// it. Where `page` is relative to.
                var pluginDir: String?

                private enum CodingKeys: String, CodingKey {
                    case key, reads, render, page
                    case pluginDir = "plugin_dir"
                }
            }

            private enum CodingKeys: String, CodingKey {
                case status, key, reads, render, page
                case pluginDir = "plugin_dir"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let status = try c.decode(String.self, forKey: .status)

                // `none` is the only status with no key. The other four name
                // a plugin, and a name the core could not have loaded
                // (`Plugin.isPlainName`) is not a choice to act on -- an
                // empty key from a missing field must not read as a match.
                switch status {
                case "none": self = .none
                case "matched":
                    guard let key = try c.decodeIfPresent(String.self, forKey: .key),
                          PreviewTicket.isPluginKey(key)
                    else { throw Self.notAChoice(c, "matched with no usable key") }
                    self = .matched(Matched(
                        key: key,
                        // A `matched` with no scope is half a row, and there
                        // is no default: a default would be this file
                        // inventing a permission.
                        reads: try c.decode(String.self, forKey: .reads),
                        render: try c.decodeIfPresent(String.self, forKey: .render),
                        page: try c.decodeIfPresent(String.self, forKey: .page),
                        pluginDir: try c.decodeIfPresent(String.self, forKey: .pluginDir)))
                case "specified_not_found":
                    self = .specifiedNotFound(key: try Self.named(c, status))
                case "specified_disabled":
                    self = .specifiedDisabled(key: try Self.named(c, status))
                case "specified_unsupported":
                    self = .specifiedUnsupported(key: try Self.named(c, status))
                default:
                    throw Self.notAChoice(c, "unknown status")
                }
            }

            private static func named(
                _ c: KeyedDecodingContainer<CodingKeys>, _ status: String
            ) throws -> String {
                guard let key = try c.decodeIfPresent(String.self, forKey: .key),
                      PreviewTicket.isPluginKey(key)
                else { throw notAChoice(c, "\(status) with no usable key") }
                return key
            }

            private static func notAChoice(
                _ c: KeyedDecodingContainer<CodingKeys>, _ said: String
            ) -> DecodingError {
                .dataCorrupted(.init(
                    codingPath: c.codingPath,
                    debugDescription: "not a preview choice: \(said)"))
            }
        }

        struct Info: Decodable, Equatable {
            /// The file's own name, not the path.
            var name: String
            /// `file` or `directory`.
            var kind: String
            var size: UInt64
            /// Nanoseconds since the epoch, as a string: it is an `i128`
            /// on the core's side and does not fit a JSON number a decoder
            /// would take.
            var mtime_ns: String
            var encoding: String?
            var eol: String?
            var editable: Bool
            /// Why it may not be edited, when it may not; nil otherwise.
            var not_editable: String?
            var version: String?
        }

        /// **What the host should put in the pane.** The one product-facing
        /// reading of `plugin`, and deliberately four cases rather than the
        /// two an optional gives: "no plugin page", "a `browser` plugin the
        /// host has not built", and "a page plugin whose page will not load"
        /// must not be one value, because one of them is a successful answer
        /// and another is a refusal that would otherwise be drawn as success
        /// -- **the file rendered as though the plugin had loaded**.
        ///
        /// Which of the six ways the location was unusable is
        /// `PageRefusal`'s and is deliberately not said to a person, who gets
        /// one sentence (`PreviewTicket.pluginUnavailable`).
        var presentation: Presentation {
            guard case .matched(let matched)? = plugin else {
                // Nothing claimed this file -- no plugin answers for it
                // (`.none`), or the answer did not say (a core that predates
                // the field). Either way the file is shown as it was before
                // plugins could claim one, which is not a guess: nothing
                // promised a page.
                return .file
            }
            switch PreviewTicket.pageLocation(of: matched) {
            case .success(let at): return .pluginPage(at)
            // **A `browser` plugin is not a broken page.** The core said how
            // this file is shown and the answer is "the file itself, in a view
            // of its own, scripts and network allowed" -- a different thing
            // from a page plugin whose page is missing. Drawing the two as one
            // sentence would tell a person their plugin is broken when it is
            // configured exactly as it meant to be.
            case .failure(.notAPagePlugin): return .browser
            case .failure: return .unavailable
            }
        }
    }

    /// What the pane shows. **The four cases are the whole of the must-not**:
    /// an unavailable plugin page must never be drawn as the file, and a
    /// `browser` plugin must never be drawn as a broken one.
    enum Presentation: Equatable {
        /// The file itself, through the ticket. What a preview was before
        /// plugins, and what it stays for a file no plugin claims.
        case file
        /// The plugin's own page, at a location the core named.
        case pluginPage(PreviewPluginPage.Location)
        /// The plugin declared `render: browser`: the file itself, in a view
        /// with no bridge. **Its own case rather than `.unavailable`** --
        /// nothing is wrong with the plugin and nothing is missing from the
        /// core's answer; this host has not built that path yet.
        case browser
        /// A page plugin whose page could not be located: the host says so.
        /// **Not `.file`** -- the file is there and could be drawn, and
        /// drawing it is exactly the silent fallback this case exists to
        /// prevent.
        case unavailable
    }

    /// The one sentence a person sees when a page plugin claims the file and
    /// the host cannot load its page. **One, not six**: which field the core
    /// left out is `PageRefusal`'s, and saying it to the person would be
    /// handing them the inside of the protocol.
    static let pluginUnavailable = String(
        localized: "This preview plugin is not available.",
        comment: "预览：插件认领了这个文件但页面加载不了时，给用户看的那一句")

    /// The sentence for a plugin that asked to be shown as the file itself in
    /// a view of its own, which this host does not serve yet. **Not the
    /// sentence above**: this plugin is working as declared.
    static let browserPreviewNotYet = String(
        localized: "This plugin shows the file in a browser view, which is not available here yet.",
        comment: "预览：插件声明 render=browser，宿主还没做这条路径时，给用户看的那一句")

    /// The core said no, in the one shape the core refuses in.
    struct Refusal: Decodable, Equatable {
        var refused: String
        var why: String?
    }

    /// How this file reaches the core.
    struct Source {
        var ask: (String) -> Result<String, Failure>

        /// Nothing is running: every ask fails.
        static let none = Source { _ in .failure(.notReady) }
    }

    enum Failure: Error, Equatable {
        /// The core is not running, or has no answer for this request.
        case notReady
        /// The core refused, and said why (`Refusal.why`).
        case refused(String)
        /// The answer is not the shape this takes.
        case unreadable
        /// The path is not one a ticket may be asked about at all, so none
        /// was asked for. See `rel(_:)`.
        case notAPath(String)
    }

    /// `files_open` for `path` in the workdir `workdirId`, as one ticket
    /// covering the file itself (`.file`).
    ///
    /// **`.file` and not `.project`.** A preview shows one file and what
    /// that file refers to (`siblings`, the design's relative `<img src>` and
    /// the html page's own default); handing it the whole working directory
    /// would be a wider capability than the window it is drawn in needs. The
    /// design states the widening where it is wanted, per plugin
    /// (`reads: file | siblings | project`), and it is a thing to ask for
    /// deliberately rather than a default.
    ///
    /// The scope is written into the request as a JSON string, and the core
    /// validates it (`Access.Scope`'s own parse): a scope name this file
    /// spells wrong is a `BadParams` from the core and not a wider ticket.
    static func request(workdirId: String, path: String, scope: String = "file") -> String {
        "{\"method\":\"files_open\",\"params\":{"
            + "\"workdir_id\":\(quoted(workdirId)),"
            + "\"path\":\(quoted(path)),"
            + "\"scope\":\(quoted(scope))}}"
    }

    /// `s` as a JSON string, quotes included. Same reason as
    /// `ControlRoomPageRequest.quoted`: `JSONEncoder` throws where a string
    /// can never fail, and the throw cannot be forced.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// What the core answered: a ticket, or the refusal it gave instead.
    ///
    /// **The refusal is read from the same bytes as the ticket**, because
    /// the core answers both in one shape (`{"refused":…}` is a normal
    /// answer, not an error) and a caller that parsed only the happy shape
    /// would report every refusal as "unreadable" -- losing the core's own
    /// sentence, which is the only thing that says *why* a preview is
    /// empty.
    static func read(_ text: String) -> Result<Answer, Failure> {
        guard let data = text.data(using: .utf8) else { return .failure(.unreadable) }
        let decoder = JSONDecoder()
        if let refusal = try? decoder.decode(Refusal.self, from: data) {
            return .failure(.refused(refusal.why ?? refusal.refused))
        }
        guard let answer = try? decoder.decode(Answer.self, from: data) else {
            return .failure(.unreadable)
        }
        // **A token that is not a token is not a ticket.** The fence is
        // that it cannot be guessed and cannot be made up; one that arrived
        // empty, or with a character outside the alphabet the core mints
        // in, would be put into a URL and refused by `PreviewRoutes` later
        // -- a refusal one step too late, and one that reads as a routing
        // bug rather than as a bad answer. Said here instead.
        guard isToken(answer.token) else { return .failure(.unreadable) }
        return .success(answer)
    }

    /// 32 lower-case hex digits: what the core mints (`Tickets.newId`) and
    /// what `PreviewRoutes` takes as a URL's authority.
    static func isToken(_ s: String) -> Bool {
        guard s.count == 32 else { return false }
        return s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A plugin key, as the core loads one (`Plugin.isPlainName`): 1...64
    /// characters of `[A-Za-z0-9._-]`, and never `.` or `..`.
    ///
    /// Used to refuse a `matched` choice that names nothing. The core cannot
    /// emit one -- it would not have loaded a manifest with such a key -- so
    /// this is about the host's own reading, where an empty key out of a
    /// missing field would otherwise become a plugin called "".
    static func isPluginKey(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        guard s != ".", s != ".." else { return false }
        return s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".")
        }
    }

    // MARK: Where a matched plugin's page is

    /// Why a matched plugin has no page the host may load. **Every one of
    /// these is "the page is not known", and not one of them is a path
    /// invented to cover the gap.**
    enum PageRefusal: Error, Equatable {
        /// The core did not say how the file is shown.
        case renderUnknown
        /// `render` is `browser`: the file itself is loaded, in a separate
        /// web view with no bridge. There is no plugin page in that case.
        case notAPagePlugin
        /// A page plugin whose page the core did not name.
        case pageUnknown
        /// The core did not say which directory the plugin is in.
        case pluginDirUnknown
        /// A root that is not an absolute path is not a root this host can
        /// join anything onto.
        case pluginDirNotAbsolute
        /// The page is not a plain relative path inside the plugin.
        case pageNotRelative
    }

    /// Where the page for a matched plugin is, or why it is not known.
    ///
    /// **A missing field is `pluginDirUnknown`/`pageUnknown`, never a guess.**
    /// The three location fields are new (contract 2789) and a core that
    /// predates them, or a manifest that names none, leaves the host with
    /// nothing to load -- which it says out loud rather than falling back to
    /// a path of its own invention.
    ///
    /// The answer is a `PreviewPluginPage.Location` -- the type the loader
    /// and the scheme handler already take -- rather than a second type that
    /// means the same thing. The key comes from the choice, so the page is
    /// its own origin.
    static func pageLocation(
        of matched: Answer.Choice.Matched
    ) -> Result<PreviewPluginPage.Location, PageRefusal> {
        guard let render = matched.render, !render.isEmpty else { return .failure(.renderUnknown) }
        guard render == "page" else { return .failure(.notAPagePlugin) }
        guard let page = matched.page, !page.isEmpty else { return .failure(.pageUnknown) }
        guard let root = matched.pluginDir, !root.isEmpty else { return .failure(.pluginDirUnknown) }
        guard root.hasPrefix("/") else { return .failure(.pluginDirNotAbsolute) }
        guard isRelativePagePath(page) else { return .failure(.pageNotRelative) }
        return .success(PreviewPluginPage.Location(key: matched.key, root: root, page: page))
    }

    /// Whether `path` is a plain relative path inside a plugin directory:
    /// no `..` component, nothing absolute, no drive letter or scheme colon,
    /// no NUL, no backslash.
    ///
    /// ⚠️ **Deliberately the same rule as the core's** (`Plugin.zig`'s
    /// `pageRefusal`, which refuses `..`, a leading `/`, a `:` and NUL): the
    /// host is the second reader of the same field, and a page the core
    /// would refuse must not become loadable just because this host was the
    /// one that read it.
    ///
    /// A `..` *substring* is not a `..` *component* -- `a..b/x.html` is an
    /// ordinary name -- which is why this splits rather than searching.
    static func isRelativePagePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") { return false }
        if path.contains("\\") || path.contains("\0") { return false }
        // A colon is a drive letter or a scheme; the core refuses it and so
        // does this.
        if path.contains(":") { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." }
    }

    // MARK: Handing the ticket back

    /// `files_close`, for a ticket a preview is done with.
    ///
    /// **The other half of `open`, and the half that is easy to skip.** The
    /// core holds a ticket in a ledger with a cap (`Tickets.max_tickets`)
    /// and drops the oldest when it fills; a host that never closed one
    /// would push other people's tickets out of that ledger, and the
    /// symptom -- somebody else's preview going blank -- would be nowhere
    /// near the code that caused it. So a cell that is gone gives its token
    /// back, which is what `PreviewSlot.Store.forget` hands out.
    ///
    /// **Closing is idempotent on the core's side** (`Tickets.close` finds
    /// the entry or does not, and answers `{"closed":true}` either way), so
    /// a token closed twice is not an error worth reporting. What is
    /// reported is only the ask having failed.
    ///
    /// The success is a `Closed` and not `Void`: `Result<Void, _>` is not
    /// `Equatable` (Swift's `Void` is not), so a test could not say "this
    /// returned what it should have" -- it would have to reach into the
    /// case. One empty value buys the whole comparison back.
    struct Closed: Equatable {}

    static func close(_ source: Source, token: String) -> Result<Closed, Failure> {
        // Nothing to give back for a token that was never handed out --
        // and asking anyway would be a request about somebody else's
        // ticket, which is the one thing a host must not do.
        guard isToken(token) else { return .success(Closed()) }
        guard case .success = source.ask(closeRequest(token: token)) else {
            return .failure(.notReady)
        }
        return .success(Closed())
    }

    static func closeRequest(token: String) -> String {
        "{\"method\":\"files_close\",\"params\":{\"token\":\(quoted(token))}}"
    }

    /// The whole thing: check the path, build the request, ask, read the
    /// answer.
    static func open(_ source: Source, workdirId: String, path: String,
                     scope: String = "file") -> Result<Answer, Failure> {
        // **Checked here as well as in the core**, and not instead of it:
        // the core would refuse a `..` path (that guard is the fence), but
        // asking anyway spends a round trip on a request whose answer is
        // already known, and the refusal that comes back reads like a
        // routing fault rather than like a path that was never one to ask
        // about. Refusing it here names it as what it is, first.
        if let why = pathRefusal(path) { return .failure(.notAPath(why)) }
        switch source.ask(request(workdirId: workdirId, path: path, scope: scope)) {
        case .failure(let why): return .failure(why)
        case .success(let text): return read(text)
        }
    }

    /// Why `path` is not one to ask about, or nil when it is.
    ///
    /// **A `rel` and not a path on this machine.** What `files_open` takes
    /// is either absolute or relative to the working directory, and the
    /// core puts it through `realpath` and judges every link against the
    /// ticket's workdir.
    ///
    /// ⚠️ **This is deliberately stricter than the core, and it says so
    /// rather than claiming to be the same rule.** The core *allows* a `..`
    /// that settles back inside (`sub/../sub/a.txt` -- `Access.zig` has a
    /// test pinning that), and this refuses **any** `..` component, before
    /// the request is built. Measured, same tree, same path string: core
    /// allows it, host refuses it and asks nothing (`asked == 0`).
    ///
    /// That is on purpose, for one reason: **the alternative is a second
    /// copy of the core's resolution.** Matching the core here would mean
    /// re-doing its `realpath`-and-judge-every-link, and a copy of a fence
    /// that gets it slightly wrong is a hole rather than a stricter fence.
    /// A host path that is stricter is safe in the one direction that
    /// matters.
    ///
    /// What it costs is nothing reachable today: `files_open`'s `path` is
    /// what this host's own UI painted (a click in the file list), which is
    /// a normal absolute or relative path and never has a `..` in it. A
    /// relative path that a *page* supplies (`<img src>`) goes the other
    /// way -- `PreviewBridge` → the core's `files_resolve`, which realpaths
    /// and refuses what leaves the workdir (`rpc.zig` tests it three
    /// times) -- and never reaches this function.
    ///
    /// ⚠️ **A `..` substring is not a `..` component**: `a..b/c.md` is an
    /// ordinary name, and a check that looked for the characters would
    /// refuse a file that is really there. That is why this splits on the
    /// separator rather than calling `contains`.
    static func pathRefusal(_ path: String) -> String? {
        if path.isEmpty { return "no path was given" }
        if path.utf8.contains(0) { return "the path contains a NUL byte" }
        for component in path.split(separator: "/", omittingEmptySubsequences: true) where component == ".." {
            return "the path goes up out of the working directory"
        }
        return nil
    }
}
