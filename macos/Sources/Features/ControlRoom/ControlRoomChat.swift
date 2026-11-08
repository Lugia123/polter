import AppKit
import GhosttyKit
import SwiftUI

/// The control room's chat page (task 2015; the design's v1 `C1-chat`): a
/// group's chat, one a group, where the supervisor's terminal is when the
/// chat page is in front.
///
/// **Two shapes, one page** (task 2791, #2791). What this file has always
/// made is a terminal running `polter +chat --group=<group>`. It now also
/// makes the core's own message list, natively, when the door for it is
/// handed in (`askCore`) -- and which of the two a group gets is decided
/// here and nowhere else, so the page, the keyboard chords and the pruning
/// go on saying the same things about either.
///
/// **Not one of anybody's terminals**: the core leaves a chat surface out of
/// `terminal_list` and the snapshot, and it is in no terminal window's split
/// tree, so no `TerminalController` sees it. Each place that has to find
/// one asks this container by name (group seq 235's table):
///
///  * the chat page shows the container and names its group (`show`);
///  * `ControlRoomController` hands it every `ghosttyCloseSurface`, and it
///    takes the ones that are its (`closedByCore`);
///  * the model prunes the chats of groups gone from the snapshot (`prune`).
///
/// **A native chat is not a surface at all**, so the second of those finds
/// nothing for it and no `ghosttyCloseSurface` ever names it.
///
/// **What it speaks as** is the person: `poltergeistChat`, which tells the
/// core that requests from this surface speak for the person at the
/// keyboard, and `ghostty_app_chat_read`, which tells the core the same
/// thing by taking no surface at all. This is the one place that sets the
/// flag since task 2080 took the menu's own chat tab out.
///
/// Four are kept; past that the one looked at longest ago goes. A chat
/// whose program ended is **not opened again until the person asks**
/// (group seq 223, the Windows host's `chat_page::ENDED`): one whose
/// program ends as it starts would be opened for ever. A native chat has no
/// program to end.
final class ControlRoomChatContainer: NSView {
    private struct Chat {
        let group: String
        /// The terminal this group's chat is, while it is one. **Nil for a
        /// native chat** (task 2791): the list is drawn from the core's own
        /// messages and there is no terminal, so nothing here may assume
        /// one -- which is what `keyboardHolder` and `focusChat` below are
        /// written around.
        let view: Ghostty.SurfaceView?
        let host: NSView
        /// The model behind a native chat, which is where its polling lives;
        /// nil for a terminal.
        let feed: ControlRoomChatFeed?
        /// The group search driven through the same door (task 2969 C1).
        /// Nil for a terminal chat, which has no search of its own.
        let search: ControlRoomChatSearchFeed?
    }

    /// The one looked at longest ago first (`ControlRoomChatRules.lookedAt`).
    private var chats: [Chat] = []
    /// **Where the last few groups were left** (task 3070): a chat that closes
    /// takes its feed's reading anchor with it, and the container is what
    /// outlives that. Bounded and least-recently-used inside the type.
    private var readingPlaces = ControlRoomChatReadingPlaces()
    /// The groups whose chat's program ended.
    private(set) var ended: Set<String> = []
    /// What changed `ended`, for the page to draw again.
    var onEnded: (Set<String>) -> Void = { _ in }
    /// A chat with the keyboard in it was hidden or closed, and the keyboard
    /// was taken out of it: where it goes next is the controller's.
    var onKeyboardLeft: () -> Void = {}

    private weak var ghostty: Ghostty.App?

    /// **Observation only** (task 2875): the page's visibility gate, off
    /// unless the process says `POLTER_CHAT_TRACE=1`. When off nothing is
    /// formatted. When on, one line per change of a chat's visibility
    /// tuple, at most 12 per container, and no state is touched.
    private static let traceOn =
        ProcessInfo.processInfo.environment["POLTER_CHAT_TRACE"] == "1"
    private var tracedTuples = 0
    private var lastVisibility: [String: String] = [:]

    private func traceVisibility(
        group: String,
        front: String?,
        shown: Bool,
        seen: Bool,
        mounted: Bool
    ) {
        guard Self.traceOn, tracedTuples < 12 else { return }
        let facing = front ?? "-"
        let tuple = "front=\(facing) shown=\(shown) seen=\(seen) mounted=\(mounted)"
        if lastVisibility[group] == tuple { return }
        lastVisibility[group] = tuple
        tracedTuples += 1
        Ghostty.logger.notice(
            "chat trace: visibility group=\(group, privacy: .public) \(tuple, privacy: .public)"
        )
    }

    /// **The door the native chat reads through** (task 2791), handed in by
    /// whoever has the core (`ControlRoomController`). Nil -- and then this
    /// container makes the `polter +chat` terminal it has always made, and
    /// nothing about the page changes. Handed in rather than built here so
    /// that this file decides nothing about the core, and so that the page
    /// keeps working in a build whose core has no such door.
    var askCore: ControlRoomChatFeed.Ask?

    /// The chat page asked for the group's search (the header's button):
    /// which group, so the page can open the group's own sidebar.
    var onSearch: ((String) -> Void)?

    /// A link in a message's Markdown: the group, the message it came from
    /// (identity and location hint), and the URL. The page decides whether it
    /// is a file reference for the core or an external link.
    var onReference: ((String, ControlRoomChatData.Message, String?) -> Void)?

    init(_ ghostty: Ghostty.App) {
        self.ghostty = ghostty
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(ControlRoomLook.Radius.supervisorInner)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// The group whose chat is in front; nil hides every one.
    func show(_ group: String?) {
        let want = group.flatMap { ended.contains($0) ? nil : $0 }
        // **Never typing into a chat nobody can see** (W4b on Windows): one
        // with the keyboard that is about to be hidden gives it up first.
        // Leaving the page by its tab does this earlier
        // (`ControlRoomModel.leavingChatPage`); this is for every other way
        // a chat is hidden -- another group, the page taken away.
        if let holder = keyboardHolder, holder.group != want {
            takeKeyboard(out: holder, why: "hidden")
        }
        if let want, !chats.contains(where: { $0.group == want }), let chat = make(want) {
            chats.append(chat)
        }
        front = want
        if let want {
            let order = ControlRoomChatRules.lookedAt(want, in: chats.map(\.group))
            chats = order.compactMap { group in chats.first { $0.group == group } }
        }
        applyVisibility()
        for group in ControlRoomChatRules.overKept(chats.map(\.group), front: want) {
            guard let i = chats.firstIndex(where: { $0.group == group }) else { continue }
            close(at: i, why: "more than four kept; looked at longest ago")
        }
        // **The debug switch arms from here as well** (task 3070's
        // instrument): `show` is what the chat page calls when it appears, and
        // the version that armed only from `viewDidMoveToWindow` never printed
        // a line. Idempotent -- `debugSwitchArmed` makes it a one-shot.
        startDebugSwitchIfAsked()
    }

    /// The group whose chat is in front, as `show` last said.
    private var front: String?
    /// The debug switch (`CHAT_SWITCH_GROUP`) is armed once per container.
    private var debugSwitchArmed = false

    /// Hidden but the one in front; and the core told which one is in
    /// sight, which needs a window -- `show` comes from the page's
    /// `onAppear`, which can run before this view is in one -- and the
    /// window not behind another tab (`windowVisibilityChanged`).
    ///
    /// **And it is where a native chat's polling is switched** (task 2791):
    /// the group in front and in a window is the one that asks, and every
    /// other one is stopped. A chat nobody can see must not go on asking the
    /// core, and a page's `stop` is not enough on its own here -- a chat is
    /// hidden rather than taken out when the page is left, so nothing else
    /// would ever tell it to stop.
    private func applyVisibility() {
        let seen = window?.occlusionState.contains(.visible) == true
        for chat in chats {
            let shown = chat.group == front
            chat.host.isHidden = !shown
            if let view = chat.view { ControlRoomLender.setVisible(view, shown && seen) }
            traceVisibility(
                group: chat.group,
                front: front,
                shown: shown,
                seen: seen,
                mounted: chat.host.window != nil
            )
            if let feed = chat.feed {
                if shown && seen { feed.start(group: chat.group) } else { feed.stop() }
            }
            if let search = chat.search {
                if shown && seen { search.start(group: chat.group) } else { search.stop() }
            }
        }
    }

    /// The window went behind another tab or came back: only the core is
    /// told. **Nothing is hidden and the keyboard is not moved** -- the
    /// window keeps its first responder, so the chat that had the keyboard
    /// has it again when its tab comes back (W4b 3 on Windows, where it had
    /// to be given back by hand).
    func windowVisibilityChanged() {
        applyVisibility()
    }

    /// The window became key or stopped being: the chat with the keyboard
    /// is told, as the terminal lent to the supervisor's page is
    /// (`ControlRoomController.syncLentFocus`). A surface is told about its
    /// own first-responder changes, not about its window's.
    func syncFocus() {
        guard let holder = keyboardHolder, let window, let view = holder.view else { return }
        view.focusDidChange(window.isKeyWindow)
    }

    /// The chat the keyboard is in, when it is in one. **A native chat is
    /// never one** (task 2791): it is SwiftUI, there is no terminal to hold
    /// the first responder, and the page's two arrows therefore find nothing
    /// to move onto on that side.
    private var keyboardHolder: Chat? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return chats.first { chat in
            guard let view = chat.view else { return false }
            return responder === view || responder.isDescendant(of: view)
        }
    }

    /// Take the keyboard out of `chat`: its window has it, and the
    /// controller says who gets it (`onKeyboardLeft`).
    private func takeKeyboard(out chat: Chat, why: String) {
        guard let view = chat.view else { return }
        view.window?.makeFirstResponder(nil)
        view.focusDidChange(false)
        Ghostty.logger.notice("control room: the keyboard was in the chat for \(chat.group, privacy: .public), being \(why, privacy: .public); taken out")
        onKeyboardLeft()
    }

    /// Put the keyboard back into the chat in front: ⌘⌥← from the preview
    /// sidebar (task 2645). Whether there was one to put it into.
    ///
    /// **Through the surface view and not through SwiftUI**, because what
    /// holds the keyboard here is a terminal: a hosting view made the first
    /// responder gets the keys and types nothing, which is the failure
    /// `takeKeyboard` above exists on the other side of.
    @discardableResult
    func focusChat() -> Bool {
        guard let front, let chat = chats.first(where: { $0.group == front }),
              let view = chat.view, let window = view.window else { return false }
        window.makeFirstResponder(view)
        view.focusDidChange(window.isKeyWindow)
        return true
    }

    /// The sidebar is taking the keyboard: the chat gives it up **without
    /// being hidden and without anyone being told to take it** -- which is
    /// what `takeKeyboard` would do, and is wrong here, since the list is
    /// not where this key is going.
    func resignChat() {
        guard let holder = keyboardHolder?.view else { return }
        holder.window?.makeFirstResponder(nil)
        holder.focusDidChange(false)
    }

    /// Leaving the chat page: the keyboard comes out of its chat before it
    /// is hidden.
    func leavingPage() {
        if let holder = keyboardHolder { takeKeyboard(out: holder, why: "left by its page's tab") }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyVisibility()
        startDebugSwitchIfAsked()
    }

    /// **`CHAT_SWITCH_GROUP` / `CHAT_SWITCH_AFTER_MS` /
    /// `CHAT_SWITCH_BACK_AFTER_MS`** (task 3070's instrument).
    ///
    /// The check this exists for -- leave a group and come back -- cannot be
    /// driven by synthetic clicks (they do not reach SwiftUI's rows; the
    /// terminal's own rule), so it leaves and comes back through the same
    /// `show(_:)` the group list uses, and says so:
    /// `switchgroup: to=… from=…` and then `switchgroup: back=…`. Absent the
    /// variable nothing is read and no timer is armed.
    private func startDebugSwitchIfAsked() {
        guard !debugSwitchArmed else { return }
        let env = ProcessInfo.processInfo.environment
        guard let target = env["CHAT_SWITCH_GROUP"], !target.isEmpty else { return }
        debugSwitchArmed = true
        let afterMs = Double(env["CHAT_SWITCH_AFTER_MS"] ?? "") ?? 3000
        let backMs = Double(env["CHAT_SWITCH_BACK_AFTER_MS"] ?? "") ?? 4000
        // **Armed says so** (the 16:35 run could not be read): a hook that ran
        // and printed nothing looks exactly like one that never ran, and that
        // is the reading that cost an hour. Everything this hook decides now
        // leaves a line, including the ways it can refuse.
        Ghostty.logger.notice(
            "switchgroup: armed target=\(target, privacy: .public) from=\(self.front ?? "-", privacy: .public) after=\(Int(afterMs), privacy: .public) back=\(Int(backMs), privacy: .public) window=\(self.window == nil ? 0 : 1, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + afterMs / 1000) { [weak self] in
            guard let self else { return }
            let from = self.front
            // **Asked to go where it already is is not a switch** (the
            // resumeD run had nobody able to tell whether `from=` was the
            // real front): the line says so instead of a `to=`/`from=` pair
            // that looks like a move.
            if from == target {
                Ghostty.logger.notice(
                    "switchgroup: noop target=\(target, privacy: .public) from=\(from ?? "-", privacy: .public)")
                return
            }
            Ghostty.logger.notice(
                "switchgroup: to=\(target, privacy: .public) from=\(from ?? "-", privacy: .public)")
            self.show(target)
            guard self.front == target else {
                Ghostty.logger.notice(
                    "switchgroup: skipped reason=not-shown target=\(target, privacy: .public) front=\(self.front ?? "-", privacy: .public) ended=\(self.ended.contains(target) ? 1 : 0, privacy: .public)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + backMs / 1000) { [weak self] in
                guard let self else { return }
                guard let from else {
                    Ghostty.logger.notice("switchgroup: skipped reason=no-from target=\(target, privacy: .public)")
                    return
                }
                Ghostty.logger.notice("switchgroup: back=\(from, privacy: .public)")
                self.show(from)
            }
        }
    }

    /// `front`, and one group a chat -- **made natively when this build has
    /// the core's door for it** (task 2791), and as the `polter +chat`
    /// terminal otherwise, which is the page's first shape and the one it
    /// falls back to wherever the door is not handed in.
    ///
    /// The two are one shape with two insides (`Chat.view` nil for the
    /// native one), so `show`, `prune` and the focus calls above go on
    /// reading and saying the same things about either.
    private func make(_ group: String) -> Chat? {
        guard let ghostty, let app = ghostty.app else { return nil }
        if let askCore {
            let feed = ControlRoomChatFeed(ask: askCore)
            // **A chat made again starts where it was closed** (task 3070):
            // the store is the container's, so it outlives the feed this
            // replaces. A group with no entry -- opened and never read --
            // seeds nothing, and opens at the newest like any first screen.
            if let place = readingPlaces.get(group) {
                feed.restore(.init(id: place.id, offset: place.offset))
            }
            let search = ControlRoomChatSearchFeed(ask: askCore)
            let pane = ControlRoomNativeChatPane(
                group: group,
                feed: feed,
                search: search,
                onSearch: { [weak self] in self?.onSearch?(group) },
                onReference: { [weak self] message, reference in
                    self?.onReference?(group, message, reference)
                }
            )
            let host = NSHostingView(rootView: pane)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            Ghostty.logger.notice("control room: chat for \(group, privacy: .public): native, out of the core's own messages")
            return Chat(group: group, view: nil, host: host, feed: feed, search: search)
        }
        var config = Ghostty.SurfaceConfiguration()
        config.command = ControlRoomChatRules.command(group: group)
        config.poltergeistChat = true
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let host = NSHostingView(rootView: Ghostty.SurfaceWrapper(surfaceView: view)
            .environment(\.surfaceInControlRoom, true)
            .environmentObject(ghostty))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        Ghostty.logger.notice("control room: chat for \(group, privacy: .public): \(config.command ?? "", privacy: .public) (poltergeistChat)")
        return Chat(group: group, view: view, host: host, feed: nil, search: nil)
    }

    /// The search feed for `group`, when this build has the core's door.
    func search(for group: String) -> ControlRoomChatSearchFeed? {
        chats.first { $0.group == group }?.search
    }

    /// The **message** feed for `group`, when this build has the core's door.
    /// A search result is located in the group's own chat, so the page asks
    /// for the same feed the container already made -- it never makes a
    /// second one.
    func feed(for group: String) -> ControlRoomChatFeed? {
        chats.first { $0.group == group }?.feed
    }

    private func close(at i: Int, why: String, keepingPlace: Bool = true) {
        // **Asked before it leaves `chats`** (group seq 289, M4b 4): after,
        // `keyboardHolder` -- which looks among `chats` -- could never name
        // it, and a chat whose program ended kept the keyboard as it went.
        // A native chat has no view and never holds the keyboard, so the
        // two ids are compared only when both sides have one.
        let heldKeyboard = keyboardHolder.map { holder -> Bool in
            guard let held = holder.view, let here = chats[i].view else { return false }
            return held === here
        } ?? false
        let chat = chats.remove(at: i)
        // **The place goes with the group** (task 3070): the feed dies with
        // the chat, so this is the last moment it can be read. Only a place a
        // reader reported -- `readingAnchor` also has a merge fallback, and a
        // group opened and left unread is the counter-case. A group that is
        // *gone* (renamed, deleted, archived) keeps none: a renamed one was
        // moved by `rename(from:to:)` before this ran.
        if keepingPlace, chat.feed?.readingWasReported == true,
           let place = chat.feed?.savedReading {
            readingPlaces.put(
                .init(id: place.id, offset: place.offset), for: chat.group)
        }
        if heldKeyboard { takeKeyboard(out: chat, why: "closed") }
        // A native chat's polling stops with it (task 2791): a chat that is
        // gone must not go on asking the core.
        chat.feed?.stop()
        chat.search?.stop()
        chat.host.removeFromSuperview()
        Ghostty.logger.notice("control room: chat for \(chat.group, privacy: .public) closed: \(why, privacy: .public)")
    }

    /// Whether `view` is one of the chats. **A native chat has no view**,
    /// so it is never one of them, and a surface arriving here is not it.
    func owns(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return chats.contains { $0.view === view }
    }

    /// The core closed a surface, or its program ended: when it is a chat's,
    /// put away, and its group's page says so until the person asks again.
    /// Whether it was one; a second word about the same one finds nothing.
    func closedByCore(_ view: Ghostty.SurfaceView) -> Bool {
        guard let i = chats.firstIndex(where: { $0.view === view }) else { return false }
        let group = chats[i].group
        close(at: i, why: "its program ended; not opened again until asked")
        ended.insert(group)
        onEnded(ended)
        return true
    }

    /// The person asked for `group`'s chat again.
    func reopen(_ group: String) {
        ended.remove(group)
        onEnded(ended)
        Ghostty.logger.notice("control room: chat for \(group, privacy: .public) asked for again")
        show(group)
    }

    /// **The core accepted a rename: the place moves with the name** (task
    /// 3070). Read from the open chat first -- the `prune` that follows closes
    /// it *without* keeping a place, because a group that is gone must not
    /// leave one under a name nothing will ask for again.
    func rename(from old: String, to new: String) {
        if let chat = chats.first(where: { $0.group == old }),
           chat.feed?.readingWasReported == true,
           let place = chat.feed?.savedReading {
            readingPlaces.put(
                .init(id: place.id, offset: place.offset), for: old)
        }
        readingPlaces.renamed(from: old, to: new)
    }

    /// The chats of groups `alive` no longer knows -- deleted, renamed,
    /// archived -- go.
    func prune(_ alive: (String) -> Bool) {
        for i in chats.indices.reversed() where !alive(chats[i].group) {
            // **A gone group keeps no place**: deleted, archived, or renamed
            // (whose place `rename(from:to:)` already moved). Capturing here
            // would put it back under the old name.
            close(at: i, why: "its group is gone", keepingPlace: false)
        }
        let gone = ended.filter { !alive($0) }
        if !gone.isEmpty {
            ended.subtract(gone)
            onEnded(ended)
        }
    }

    /// The window is closing: every chat goes with it.
    func closeAll() {
        for i in chats.indices.reversed() { close(at: i, why: "the control room closed") }
    }
}

/// The chat page: the container -- always the same view, hidden rather
/// than taken out when the page is left (task 1461's rule) -- and, for a
/// group whose chat ended, one sentence that a press answers.
///
/// **And the preview sidebar beside it** (task 2645, #2140 M3; the design's
/// `INTERACTION.md` §一 and §二: 群聊在左，旁栏在右). The chat itself is one
/// view in one place, through everything, exactly as a terminal is in a pane
/// (`PaneFramePreview` says why): what changes when the sidebar opens is its
/// *frame*, never which view it is.
///
/// **The sidebar's cell is the chat's own, for the group in front**
/// (`ControlRoomSidebar.key(group:)`, task 2775). It is *not* the
/// working-directories page's cell: 群聊只能显示当前群聊天文件，工作目录自己的
/// 预览留在工作目录, and a file opened on one page is not the file the other
/// is showing. A terminal pane names itself by its surface's id and therefore
/// collides with neither (the design: 终端格里的预览是那一个格子自己的).
struct ControlRoomChatPage: View {
    typealias Look = ControlRoomLook

    var group: String
    @ObservedObject var model: ControlRoomModel

    @Environment(\.colorScheme) private var scheme
    /// The one store every preview in the application is kept in
    /// (`Ghostty.App.previewStore`). The cell named below is the chat
    /// sidebar's own (task 2775), so this page shows what was opened here
    /// and does not take the working-directories page's file.
    @EnvironmentObject private var ghostty: Ghostty.App

    /// Which side of this page the keyboard is standing on, as the window's
    /// two chords last put it (`ControlRoomSidebar`).
    ///
    /// **Written here and not through `@FocusState`**, because the two sides
    /// are not both SwiftUI views: the chat is a terminal that takes the
    /// first responder itself, so a move onto it has to be made through the
    /// container, and a move onto the sidebar has to put the keyboard
    /// *somewhere* rather than nowhere. `.chat` is where this starts: the
    /// sidebar opens with the keyboard still in the chat until something
    /// asks otherwise.
    @State private var side: ControlRoomSidebar.Side = .chat

    /// The store was opened by the search button (not by ⌘\), so the slot
    /// change must not close the search that asked for it.
    @State private var openingSearch = false
    /// The slot is being opened **by this page's own adoption**. The store's
    /// open transition must not then be read as the person closing the slot
    /// and release the ticket we just adopted.
    @State private var openingPreview = false

    /// The reference job and ticket ledger for this page's slot.
    @State private var referenceDesk: ControlRoomChatReferenceDesk?
    /// The slot cell the desk's ticket belongs to, so a group change can
    /// close the old one before the cell changes.
    @State private var referenceCell: String?
    /// The message/reference that opened the preview, for the slot's source.
    @State private var previewSource: ControlRoomChatSidebarState.PreviewSource?

    /// The cell this page's sidebar lives in: **the chat's own, for this
    /// group** (task 2775). Named through `ControlRoomSidebar` so that the
    /// key has one spelling for the whole application, and named with the
    /// group so that switching groups does not carry a preview across.
    private var cell: String { ControlRoomSidebar.key(group: group) }

    /// The group's search, once the container has made it. Nil before then
    /// and in a build without the core's door.
    private var searchFeed: ControlRoomChatSearchFeed? {
        model.chatContainer?.search(for: group)
    }

    var body: some View {
        let theme = Look.theme(scheme)
        // **The page's own split** (task 2982): the chat's slot is 330 and
        // the threshold is the preview rule's 800, but there is no terminal
        // to hold, no left expose and no drag band -- see
        // `ControlRoomChatSidebarLayout` for why this is the chat's rule and
        // not a second `PreviewLayout`.
        GeometryReader { geometry in
            let open = ghostty.previewStore.state(cell).open
            let split = ControlRoomChatSidebarLayout.split(
                pageW: geometry.size.width, open: open)
            ZStack(alignment: .topLeading) {
                ZStack {
                    theme.terminalBackground.color
                    if let container = model.chatContainer {
                        ChatHost(container: container)
                    }
                    if model.chatEnded.contains(group) {
                        Button { model.chatContainer?.reopen(group) } label: {
                            Text(String(localized: "The chat has ended. Click here to open it again.",
                                        comment: "总控台：群聊页，聊天程序结束以后"))
                                .foregroundStyle(theme.textSecondary.color)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                // **One view, one place, whatever the slot is doing**: the
                // chat is not chosen between two branches, only framed
                // (task 1461's rule; the same shape `PaneFramePreview` has).
                .frame(width: split.messageWidth, height: geometry.size.height,
                       alignment: .topLeading)
                if split.sidebarWidth > 0, let messageFeed = model.chatContainer?.feed(for: group) {
                    ControlRoomChatSlotPanel(
                        cell: cell,
                        split: split,
                        store: $ghostty.previewStore,
                        search: searchFeed,
                        message: messageFeed,
                        onCloseSearch: closeSearch,
                        onLocate: { hit in locate(hit) },
                        onBackToSearch: { releaseReference(); searchFeed?.backToSearch() }
                    )
                    .frame(width: split.sidebarWidth, height: geometry.size.height,
                           alignment: .topLeading)
                    .offset(x: split.sidebarX)
                    // Where ⌘⌥→ puts the keyboard: a view with nothing in it
                    // that the chat stops receiving keys into. Everything it
                    // does not use goes on up the responder chain
                    // (`SidebarFocusSink`), so nothing is swallowed.
                    .background(SidebarFocusSink(wanted: side == .preview))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: .topLeading)
        }
        .onAppear {
            model.chatContainer?.show(group)
            model.chatContainer?.onSearch = { requested in openSearch(requested) }
            model.chatContainer?.onReference = { requested, message, reference in
                resolveReference(group: requested, message: message, reference: reference)
            }
        }
        .onChange(of: group) { newGroup in
            // **The handler must name the group the page is on now.** A
            // closure left from A would reject B's button.
            releaseReference()
            model.chatContainer?.show(newGroup)
            model.chatContainer?.onSearch = { requested in openSearch(requested) }
            model.chatContainer?.onReference = { requested, message, reference in
                resolveReference(group: requested, message: message, reference: reference)
            }
        }
        .onDisappear {
            releaseReference()
            model.chatContainer?.show(nil)
            model.chatContainer?.onSearch = nil
            model.chatContainer?.onReference = nil
        }
        // What the window's ⌘⌥←/→ asks for while this page is in front
        // (`ControlRoomController`). Set while the page is drawn and taken
        // away as it leaves, the way the task page's Return is
        // (`ControlRoomTasksPage`): a page nobody can see must not be where
        // a key goes.
        .onAppear { offerFocus() }
        .onChange(of: model.pageInFront) { _ in offerFocus() }
        .onChange(of: group) { _ in offerFocus() }
        .onDisappear { model.sidebarFocus = nil }
        // Closing the sidebar while the keyboard was inside it puts the
        // keyboard back on the chat. **The design says exactly this**
        // (「关掉以后，键盘回到这个格子的终端里」), and it is the half that
        // goes wrong silently: a window whose first responder is a view that
        // is no longer drawn is a window where typing goes nowhere.
        .onChange(of: ghostty.previewStore.state(cell).open) { open in
            if open {
                // ⌘\ opening the slot is a preview: the search is replaced.
                if openingSearch {
                    openingSearch = false
                    return
                }
                if openingPreview {
                    // **Our own adoption opened it.** The ticket is live;
                    // treating this as an external open would close it.
                    openingPreview = false
                    return
                }
                // A real replacement: the old owner goes, together with the
                // store's token, before anything new is shown.
                releaseReference()
                searchFeed?.close()
                return
            }
            releaseReference()
            searchFeed?.close()
            move(to: ControlRoomSidebar.side(opened: false))
        }
    }

    /// Hand the window the door the arrows use, or take it away when another
    /// page is in front.
    ///
    /// ⚠️ **This sets the door and nothing else.** It does *not* move the
    /// keyboard, which is what `move(to:)` is for: a page that has just come
    /// in front is not a person asking to type in the chat, and taking the
    /// keyboard for it would be this page stealing it from whatever the
    /// person was doing (`ControlRoomChatContainer` takes a chat's keyboard
    /// away on the way *out* for the same reason, one file over). What it
    /// does do is put `side` back to `.chat`, so that a sidebar left open on
    /// a previous visit does not take the keyboard the moment this page is
    /// drawn again (`SidebarFocusSink` would, and the store's open flag does
    /// survive a page change on purpose).
    private func offerFocus() {
        guard model.pageInFront == .chat else {
            model.sidebarFocus = nil
            return
        }
        side = .chat
        model.sidebarFocus = { move(to: $0) }
    }

    // MARK: - Message file references

    /// A link in a message. External URLs open normally; anything else is a
    /// file reference and is resolved **by the core**, never by a host path
    /// guess. The source's location hint travels with it.
    private func resolveReference(
        group requested: String,
        message: ControlRoomChatData.Message,
        reference: String?
    ) {
        guard requested == group else { return }
        guard let reference else {
            // The exact raw destination could not be identified (none, or
            // several spellings): say so, do not guess a URL.
            releaseReference()
            previewSource = ControlRoomChatSidebarState.PreviewSource(
                group: group, anchor: message.anchor, reference: "",
                location: message.location,
                author: message.author, atMs: message.atMs
            )
            referenceCell = cell
            searchFeed?.openPreview(previewSource!)
            openingPreview = true
            ghostty.previewStore.setFile(cell, rel: "", token: "", presentation: .file)
            ghostty.previewStore.set(cell, open: true)
            searchFeed?.previewFailed("ReferenceUnavailable")
            return
        }
        if reference.hasPrefix("http://") || reference.hasPrefix("https://")
            || reference.hasPrefix("mailto:"),
           let url = URL(string: reference) {
            NSWorkspace.shared.open(url)
            return
        }
        // **The old owner goes before the new one starts**: store and ledger
        // change together, and the slot shows an empty body while the core
        // is asked.
        releaseReference()
        previewSource = ControlRoomChatSidebarState.PreviewSource(
            group: group,
            anchor: message.anchor,
            reference: reference,
            location: message.location,
            author: message.author,
            atMs: message.atMs
        )
        referenceCell = cell
        searchFeed?.openPreview(previewSource!)
        openingPreview = true
        ghostty.previewStore.setFile(cell, rel: "", token: "", presentation: .file)
        ghostty.previewStore.set(cell, open: true)
        referenceDeskForThePage().resolve(
            cell: cell, group: group, anchor: message.anchor,
            location: message.location, reference: reference
        )
    }

    private func referenceDeskForThePage() -> ControlRoomChatReferenceDesk {
        if let referenceDesk { return referenceDesk }
        let desk = ControlRoomChatReferenceDesk(
            ask: ControlRoomChatCoreAdapter.ask(ghostty)
        )
        desk.onEffect = { effect in applyReferenceEffect(effect) }
        referenceDesk = desk
        return desk
    }

    /// The desk's two effects, applied to the one slot. **The Store and the
    /// ledger change together here**; no second owner.
    private func applyReferenceEffect(_ effect: ControlRoomChatReferenceDesk.Effect) {
        switch effect {
        case let .adopt(cell, token, presentation, closeOld, anchor, location):
            if let closeOld { closeTicket(closeOld) }
            // The core's accepted identity replaces the requested one for a
            // later re-open; the raw reference is kept as it was.
            if var source = previewSource {
                source.anchor = anchor
                source.location = location
                previewSource = source
            }
            if let previewSource {
                searchFeed?.openPreview(previewSource)
            }
            ghostty.previewStore.setFile(
                cell, rel: "", token: token, presentation: presentation
            )
            openingPreview = true
            ghostty.previewStore.set(cell, open: true)
            searchFeed?.previewReady()
        case let .close(cell, token, code):
            if let token { closeTicket(token) }
            // A refusal for **this** slot also takes the old owner out of
            // both the ledger and the store; a late reply for another slot
            // only gives its own token back.
            guard !cell.isEmpty, cell == referenceCell else { return }
            if let old = referenceDesk?.close(cell: cell), old != token {
                closeTicket(old)
            }
            ghostty.previewStore.setFile(cell, rel: "", token: "", presentation: .file)
            ghostty.previewStore.set(cell, open: true)
            searchFeed?.previewFailed(code)
        }
    }

    private func closeTicket(_ token: String) {
        guard !token.isEmpty else { return }
        _ = PreviewTicket.close(.core(ghostty), token: token)
    }

    private func releaseReference() {
        guard let desk = referenceDesk else { return }
        let slot = referenceCell ?? cell
        if let token = desk.close(cell: slot) { closeTicket(token) }
        // **The store is cleared with the ledger.** Otherwise the cell keeps
        // a token whose ticket is closed, and opening it again revives a dead
        // ticket.
        ghostty.previewStore.setFile(slot, rel: "", token: "", presentation: .file)
        referenceCell = nil
        previewSource = nil
    }

    /// The header's search button: the group's own slot shows the search.
    /// **There is no ⌘F here** -- the page has no key equivalent of its own,
    /// and a chord that stole F from the field was the bug.
    private func openSearch(_ requested: String) {
        guard requested == group,
              let feed = model.chatContainer?.search(for: requested)
        else { return }
        // A reference still in flight must not later replace the search.
        releaseReference()
        model.chatContainer?.feed(for: requested)?.clearLocateNotice()
        feed.openSearch()
        openingSearch = true
        ghostty.previewStore.set(cell, open: true)
    }

    /// A search result was picked: the left side shows its **original
    /// conversation** around the exact anchor, with both context cursors.
    /// The right side keeps the query and the selected result.
    private func locate(_ hit: ControlRoomChatSearch.Hit) {
        guard let feed = model.chatContainer?.feed(for: group) else { return }
        feed.locate(anchor: hit.message.anchor, location: hit.message.location)
    }

    /// The search panel's close, or the slot closing: the search stops and
    /// the slot goes, never leaving a spinner behind.
    private func closeSearch() {
        model.chatContainer?.feed(for: group)?.clearLocateNotice()
        searchFeed?.close()
        ghostty.previewStore.set(cell, open: false)
    }

    /// Stand the keyboard on one side, for real: the chat's is a terminal
    /// and only the container can hand it the first responder, and the
    /// sidebar's is a view with nothing in it (`SidebarFocusSink`).
    private func move(to wanted: ControlRoomSidebar.Side) {
        side = wanted
        switch wanted {
        case .chat: model.chatContainer?.focusChat()
        case .preview: model.chatContainer?.resignChat()
        }
    }

    /// The right-hand slot: the group's search when it is showing search,
    /// **the chat's own preview shell** otherwise. One slot, never two.
    private struct ControlRoomChatSlotPanel: View {
        var cell: String
        var split: ControlRoomChatSidebarLayout.Split
        @Binding var store: PreviewSlot.Store
        var search: ControlRoomChatSearchFeed?
        @ObservedObject var message: ControlRoomChatFeed
        var onCloseSearch: () -> Void
        var onLocate: ((ControlRoomChatSearch.Hit) -> Void)?
        var onBackToSearch: (() -> Void)?

        var body: some View {
            if let search {
                ControlRoomChatSlotObserved(
                    search: search,
                    message: message,
                    cell: cell,
                    store: $store,
                    onClose: onCloseSearch,
                    onLocate: onLocate,
                    onBackToSearch: onBackToSearch
                )
            } else {
                // **A terminal chat has no search of its own** and cannot
                // resolve a message's file reference; this is the shell the
                // page had before the native one, kept for that build. The
                // split is framed by the page's own rule.
                PanePreviewPanel(
                    cell: cell,
                    split: PreviewLayout.Split(
                        terminalX: 0, terminalWidth: split.messageWidth,
                        previewX: split.sidebarX, previewWidth: split.sidebarWidth,
                        overlay: split.overlay),
                    store: $store)
            }
        }
    }

    private struct ControlRoomChatSlotObserved: View {
        @ObservedObject var search: ControlRoomChatSearchFeed
        /// The left side's state: whether a locate is out and whether it
        /// failed is drawn in the search panel, above the results.
        @ObservedObject var message: ControlRoomChatFeed
        var cell: String
        @Binding var store: PreviewSlot.Store
        var onClose: () -> Void
        var onLocate: ((ControlRoomChatSearch.Hit) -> Void)?
        var onBackToSearch: (() -> Void)?

        var body: some View {
            if search.state.mode == .search {
                ControlRoomChatSidebarPanel(
                    feed: search,
                    locating: message.locating,
                    locateFailed: message.locateTrouble,
                    onClose: onClose,
                    onLocate: onLocate
                )
            } else {
                // **`state.preview` is what the shell draws** (review M3):
                // loading, refused and ready are three different faces of
                // one slot; the store's token is cleared on a refusal, so
                // the previous file's body cannot survive it.
                ControlRoomChatPreviewPanel(
                    cell: cell,
                    store: $store,
                    preview: search.state.preview,
                    onBackToSearch: search.state.saved != nil ? onBackToSearch : nil,
                    onClose: onClose
                )
            }
        }
    }

    /// The chat's own preview shell (review M4): **the file's name, the
    /// message it came from, and the way out** -- not the working-directories
    /// pane, whose header says `终端` and whose title is a working-directory
    /// relative path the chat never has. Sizes come from the look's 13-point
    /// floor; nothing here invents a smaller one.
    private struct ControlRoomChatPreviewPanel: View {
        typealias Look = ControlRoomLook
        typealias Preview = ControlRoomChatSidebarState.Preview

        var cell: String
        @Binding var store: PreviewSlot.Store
        var preview: Preview
        var onBackToSearch: (() -> Void)?
        var onClose: () -> Void

        @Environment(\.colorScheme) private var scheme

        private var source: ControlRoomChatSidebarState.PreviewSource? {
            switch preview {
            case .none: return nil
            case let .loading(source), let .ready(source), let .failed(source, _): return source
            }
        }

        var body: some View {
            let theme = Look.theme(scheme)
            let state = store.state(cell)
            VStack(spacing: 0) {
                header(theme)
                Rectangle()
                    .fill(theme.line.color)
                    .frame(height: CGFloat(Look.Line.hairline))
                content(theme, state: state)
            }
            .background(theme.windowBase.color)
        }

        // MARK: - The shell

        private func header(_ theme: Look.Theme) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let onBackToSearch {
                        Button(action: onBackToSearch) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.backward")
                                Text(String(localized: "Back to search",
                                            comment: "总控台：群聊页，从预览返回搜索"))
                            }
                            .font(.system(size: Look.Font.min))
                            .foregroundStyle(theme.text.color)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: Look.Font.min))
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Close preview",
                                 comment: "总控台：群聊页，关闭预览"))
                }
                Text(fileName)
                    .font(.system(size: Look.Font.min, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let source, !sourceLine(source).isEmpty {
                    Text(sourceLine(source))
                        .font(.system(size: Look.Font.min))
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.windowBase.color)
        }

        /// The file's own name, from the raw reference the core was given.
        /// **Not a path the host guessed**: the name is the reference's last
        /// component and nothing more.
        private var fileName: String {
            guard let reference = source?.reference, !reference.isEmpty else {
                return String(localized: "File", comment: "总控台：群聊页，预览的通用标题")
            }
            let name = URL(fileURLWithPath: reference).lastPathComponent
            return name.isEmpty
                ? String(localized: "File", comment: "总控台：群聊页，预览的通用标题")
                : name
        }

        /// Who said it and when. Empty when the source has neither, so the
        /// shell says nothing rather than an empty line.
        private func sourceLine(_ source: ControlRoomChatSidebarState.PreviewSource) -> String {
            let time = source.atMs > 0
                ? ControlRoomChatPresentation.timeText(atMs: source.atMs) : ""
            if !source.author.isEmpty, !time.isEmpty {
                return String(
                    format: String(localized: "From %@ · %@",
                                   comment: "总控台：群聊页，预览的来源消息作者与时间"),
                    source.author, time)
            }
            return source.author.isEmpty ? time : source.author
        }

        // MARK: - The body

        @ViewBuilder
        private func content(_ theme: Look.Theme, state: PreviewSlot.State) -> some View {
            switch preview {
            case .none:
                empty(theme)
            case .loading:
                centered(theme) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Loading preview…",
                                comment: "总控台：群聊页，预览正在加载"))
                }
            case let .failed(_, code):
                // **The core's code is not the sentence**: `access`,
                // `SourceUnavailable` and the rest are for a log, and the
                // person gets one line that says what happened to the file.
                centered(theme) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: Look.Font.min))
                    Text(String(localized: "Could not open this file.",
                                comment: "总控台：群聊页，预览失败"))
                        .multilineTextAlignment(.center)
                        .help(code)
                }
            case .ready:
                if state.token.isEmpty {
                    // A ready without a ticket is the store having been
                    // cleared: draw the refusal rather than an empty box.
                    centered(theme) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: Look.Font.min))
                        Text(String(localized: "Could not open this file.",
                                    comment: "总控台：群聊页，预览失败"))
                    }
                } else {
                    // **The ticket's body is shared with the working-
                    // directories pane** (`PreviewBody`): one plugin, one
                    // sentence about it on both pages.
                    PreviewBody(token: state.token, presentation: state.presentation)
                }
            }
        }

        private func empty(_ theme: Look.Theme) -> some View {
            VStack {
                Spacer()
                Text(String(localized: "No file is open.",
                            comment: "总控台：群聊页，预览槽为空"))
                    .font(.system(size: Look.Font.min))
                    .foregroundStyle(theme.textSecondary.color)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.windowBase.color)
        }

        private func centered<C: View>(
            _ theme: Look.Theme, @ViewBuilder _ content: () -> C
        ) -> some View {
            VStack(spacing: 8) {
                Spacer()
                content()
                Spacer()
            }
            .font(.system(size: Look.Font.min))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .background(theme.windowBase.color)
        }
    }

    private struct ChatHost: NSViewRepresentable {
        let container: ControlRoomChatContainer
        func makeNSView(context: Context) -> ControlRoomChatContainer { container }
        func updateNSView(_ view: ControlRoomChatContainer, context: Context) {}
    }

    /// The sidebar's keyboard: a view with nothing in it, made the first
    /// responder when the keyboard is on that side.
    ///
    /// **An `NSView` rather than `@FocusState`**, because what this has to be
    /// able to do is take the first responder *away from a terminal*, and
    /// whether a SwiftUI focus bridge does that to a view holding a real
    /// `NSTextInputContext` is not something this file can be sure of. The
    /// view draws nothing and uses none of the keys: `NSResponder`'s own
    /// `keyDown` passes an event it does not handle to the next responder, so
    /// a key pressed here goes wherever it would have gone with no sidebar,
    /// rather than into a hole.
    private struct SidebarFocusSink: NSViewRepresentable {
        let wanted: Bool

        func makeNSView(context: Context) -> Sink { Sink() }
        func updateNSView(_ view: Sink, context: Context) {
            view.wanted = wanted
            view.takeIfWanted()
        }

        final class Sink: NSView {
            var wanted = false

            /// Key events only: this view is not a control and has nothing to
            /// click.
            override var acceptsFirstResponder: Bool { true }
            override func becomeFirstResponder() -> Bool { true }

            /// ⚠️ **Not in `viewDidMoveToWindow` alone.** The window is there
            /// long before the keyboard is asked to move, and `updateNSView`
            /// is what a change of side reaches; both are needed because the
            /// two orders happen (the sidebar opened before the view is in a
            /// window, and a window that arrives later).
            func takeIfWanted() {
                guard wanted, let window, window.firstResponder !== self else { return }
                window.makeFirstResponder(self)
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                takeIfWanted()
            }
        }
    }
}
