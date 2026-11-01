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
    }

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
