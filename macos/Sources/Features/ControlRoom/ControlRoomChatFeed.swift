import Combine
import Foundation

/// The chat page's messages, and where they come from (task 2791, #2791).
///
/// **The door is handed in.** `Ask` is the same three-outcome shape
/// `ControlRoomOverall.Ask` is (`notReady` is not a fault, `refused` is),
/// and the file names no core: what actually asks is
/// `ControlRoomChatCoreAdapter`, which is outside the package the logic
/// tests build because it names `GhosttyKit`. A test drives this with a
/// closure, which is the whole point -- "the list is empty" and "the answer
/// never arrived" must not look the same from a running window.
///
/// **Only the group in front is asked** (`start`/`stop` are the page's
/// `onAppear`/`onDisappear` and its `onChange(of: group)`): nothing here
/// polls a group nobody is looking at, and leaving the page cancels the
/// timer.
///
/// ⚠️ **An answer about another group is thrown away.** Switching groups
/// while a request is in flight is the ordinary case, not a rare one, and a
/// batch merged into the wrong group's list would put one group's words
/// under another's name with nothing on screen to say so. `Batch.group` is
/// the core's own word for which group it answered about, so it is checked
/// against the group that asked.
///
/// **`since` is ours and moves nothing in the core.** The request carries
/// the cursor this feed has reached; it never carries a "the person has
/// read this" marker, because that is the `seen` act's
/// (`ControlRoomSeenTracker`), and a read that advanced the person's cursor
/// would be a window deciding what the person has seen.
final class ControlRoomChatFeed: ObservableObject {
    typealias D = ControlRoomChatData

    /// What the door answers, in this file's own spelling.
    enum Reply: Equatable {
        /// The core's own bytes.
        case answer(String)
        /// Nothing yet: the core has no reading, and nothing is drawn.
        case notReady
        /// Refused, with words worth writing down.
        case refused(String)
    }

    typealias Ask = (String) -> Reply

    /// What became of a post, **the core's three states and not a bool**
    /// (`ghostty_chat_send_result_e`): the two a bool has do not cover it,
    /// because a post that may or may not have gone is not a post that did
    /// not go.
    enum Posted: Equatable {
        /// It went. `answer` is the core's own reply, when there was one.
        case confirmed(String?)
        /// Nothing was written, and that is certain: sending again is safe.
        case refused(String)
        /// It may or may not have gone. **Never sent again on this
        /// side.**
        case unknown(String)
    }

    typealias Send = (String) -> Posted

    /// The messages of the group in front, oldest first.
    @Published private(set) var messages: [D.Message] = []
    /// Why there is nothing new, when there is a reason worth saying. Nil
    /// while the answers are arriving.
    @Published private(set) var trouble: String?
    /// What the last post became of, said under the box until the person
    /// types again. **Nil is "nothing was posted"**, which is not the same
    /// as "the post is fine".
    @Published private(set) var posted: Posted?
    /// What the person has typed but not sent, **per group**: a draft is the
    /// person's own words about one conversation, and carrying it to
    /// another group's box would offer to send it somewhere they were not
    /// writing.
    @Published var drafts: [String: String] = [:]

    /// How often to ask again while the page is in front. Two seconds, the
    /// same bound `ProjectLinker` watches its directory on: a chat that has
    /// quietly stopped updating looks exactly like a quiet room, which is
    /// the worst shape a failure can have.
    var period: TimeInterval = 2

    /// The group the page is showing; nil when it is not drawn.
    private(set) var group: String?

    private let ask: Ask
    /// The post door; nil where this build has none.
    private let send: Send?
    private var timer: Timer?
    /// Per group: what to pass as `since` next.
    private var next: [String: UInt64] = [:]
    /// Per group: the messages held, so that coming back to a group shows
    /// what it had rather than an empty list while the first answer is in
    /// flight.
    private var held: [String: [D.Message]] = [:]
    /// Per group: the identity of every message already held.
    private var kept: [String: Set<String>] = [:]
    /// What was last written down, so the log gets one line per fact rather
    /// than one per tick.
    private var said: String?

    /// `@escaping` because the door outlives the call that hands it in: the
    /// feed keeps it for every tick of the timer.
    ///
    /// **`send` is optional and separate from `ask`** (task 2791, slice 2):
    /// a build with the read door and not the post door still shows the
    /// conversation, and the box is not drawn rather than being drawn and
    /// doing nothing.
    init(ask: @escaping Ask, send: Send? = nil) {
        self.ask = ask
        self.send = send
    }

    // MARK: - The page's two moments

    // MARK: - Sending

    /// The post the core is handed: **the group named outright, and no
    /// `task`**.
    ///
    /// ⚠️ **The channel is not guessed.** `group_post` takes an optional
    /// `task`, and a host that filled it from the last message it happened
    /// to be showing would post a public remark into a task's channel (or
    /// the reverse) on the strength of where the scroll happened to be. A
    /// box on the chat page writes to the group's public channel -- which is
    /// what `task` absent means -- and nothing here reads the conversation
    /// to decide otherwise.
    static func postRequest(group: String, text: String) -> String {
        "{\"method\":\"group_post\",\"params\":{\"group\":\(ControlRoomPageRequest.quoted(group)),\"text\":\(ControlRoomPageRequest.quoted(text))}}"
    }

    /// What the box holds for `group`, and the one way it is written.
    ///
    /// **Per group.** Leaving a group and coming back finds what was typed,
    /// and the draft never travels: `drafts` is keyed by the group it was
    /// written for.
    func draft(for group: String) -> String { drafts[group] ?? "" }

    func setDraft(_ text: String, for group: String) {
        drafts[group] = text
        // **Typing is the person moving on.** What the last post became of
        // belongs to the words it was about; leaving it under the box while
        // they write the next line would put "not sent" over a message that
        // has nothing to do with it.
        posted = nil
    }

    /// Whether this build has a post door at all. **False and the box is not
    /// drawn**: a text field nobody can send from is worse than no field,
    /// because it looks like the chat can be answered.
    var hasSendDoor: Bool { send != nil }

    /// Whether the person may post to the group in front right now: there is
    /// a door for it, the page is showing a group, and the box has something
    /// in it that is not only whitespace.
    ///
    /// **Only the group in front**: a page nobody can see must not be where
    /// a post goes, for the same reason a page nobody can see is not where a
    /// key goes (`ControlRoomChatPage.offerFocus`).
    var canPost: Bool {
        guard let group, send != nil else { return false }
        return !draft(for: group).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Post what the box holds for the group in front, once.
    ///
    /// **Once, and never on its own again.** Which of the three outcomes
    /// came back decides only what is *said* and whether the box is
    /// emptied:
    ///
    ///  * `confirmed` -- it went: the draft goes, and the conversation is
    ///    asked for again at once, because the core's own copy is the one
    ///    worth showing and the person just changed it.
    ///  * `refused` -- nothing was written and that is certain: the draft
    ///    stays, with the core's reason beside it, so the person can press
    ///    again themselves. **This is the only one that may be sent again.**
    ///  * `unknown` -- it may or may not have gone: the draft **stays** and
    ///    the page says so. Nothing here sends it again, and nothing here
    ///    offers to: a second send of a post that landed is the duplicate
    ///    the three states exist to prevent.
    func post() {
        guard let group, let send, canPost else { return }
        let text = draft(for: group)
        posted = send(Self.postRequest(group: group, text: text))
        switch posted {
        case .confirmed:
            drafts[group] = ""
            fetch()
        case .refused, .unknown, nil:
            // The draft stays, and the conversation is refreshed: what the
            // core holds is the truth about whether the post landed, and
            // the person reads it there. `unknown` is not retried.
            fetch()
        }
    }

    /// The page is in front, on `group`. From nothing when it is another
    /// group's.
    func start(group: String) {
        if self.group != group {
            self.group = group
            messages = held[group] ?? []
            // **Another group's post is another group's news.** What became
            // of the last one is about words this box is not holding.
            posted = nil
            said = nil
        }
        arm()
        Ghostty.logger.notice("control room: chat page of \(group, privacy: .public) in front; asking every \(self.period)s")
        fetch()
    }

    /// The page is out of sight: nothing is asked until it is back.
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        group = nil
        Ghostty.logger.notice("control room: chat page out of sight; its timer is stopped")
    }

    private func arm() {
        if timer != nil { return }
        let t = Timer(timeInterval: period, repeats: true) { [weak self] _ in self?.fetch() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Asking

    /// The request the core is asked with: the same envelope the tool
    /// speaks (`{"method":"group_read","params":{"group":…,"since":…}}`),
    /// so that what the door is handed is what a person would have written.
    static func request(group: String, since: UInt64) -> String {
        "{\"method\":\"group_read\",\"params\":{\"group\":\(ControlRoomPageRequest.quoted(group)),\"since\":\(since)}}"
    }

    /// One message's identity inside this feed.
    ///
    /// `logSeq` when there is one -- it is the record's own number and
    /// survives a restart -- and the group's `seq` when there is not, which
    /// is a message that was never written down and cannot outlive the core
    /// run it was said in. **The two never collide**: a `seq` of 7 and a
    /// `logSeq` of 7 are different messages, and folding them would drop
    /// one of the two.
    static func identity(_ m: D.Message) -> String {
        m.logSeq != 0 ? "l\(m.logSeq)" : "m\(m.seq)"
    }

    /// The answer, or nothing when it is not the shape this takes.
    static func decode(_ text: String) -> D.Batch? {
        try? JSONDecoder().decode(D.Batch.self, from: Data(text.utf8))
    }

    /// How many times one tick may go straight back for the next batch when
    /// the core says there is more. Bounded, because the alternative to a
    /// bound here is a tick that never returns.
    static let lookAhead = 8

    private func fetch(depth: Int = 0) {
        guard let group else { return }
        let since = next[group] ?? 0
        switch ask(Self.request(group: group, since: since)) {
        case let .answer(text):
            guard let batch = Self.decode(text) else {
                note("the answer is not the object this page takes")
                return
            }
            guard batch.group == group else {
                // The selection moved between asking and now. Its messages
                // are the other group's, and are not this list's.
                note("an answer about \(batch.group) arrived while showing \(group); thrown away")
                return
            }
            let added = take(batch, for: group)
            said = nil
            trouble = nil
            // More waiting right now: the batch was cut short. **Asked again
            // only while something is still moving** -- a core that answered
            // `more` without advancing would otherwise be asked for ever,
            // and a tick that never returns is a hang, not a slow page.
            if batch.more, depth < Self.lookAhead, added > 0 || batch.next > since {
                fetch(depth: depth + 1)
            }
        case .notReady:
            // Nothing yet is not a fault, and is not said.
            trouble = nil
        case let .refused(why):
            note(why)
        }
    }

    /// Merge `batch` into `group`'s list, skipping what is already held, and
    /// carry the cursor forward.
    @discardableResult
    func take(_ batch: D.Batch, for group: String) -> Int {
        var list = held[group] ?? []
        var known = kept[group] ?? []
        var added = 0
        for m in batch.messages where !known.contains(Self.identity(m)) {
            known.insert(Self.identity(m))
            list.append(m)
            added += 1
        }
        held[group] = list
        kept[group] = known
        // **Forward only.** A batch that repeats or trails an earlier one
        // must not walk the cursor back and have the same messages asked
        // for again.
        next[group] = max(next[group] ?? 0, batch.next)
        if self.group == group { messages = list }
        return added
    }

    private func note(_ why: String?) {
        guard why != said else { return }
        said = why
        trouble = why
        if let why {
            Ghostty.logger.notice("control room: chat page: \(why, privacy: .public)")
        }
    }
}
