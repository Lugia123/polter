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
