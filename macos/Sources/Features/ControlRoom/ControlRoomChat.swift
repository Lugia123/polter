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
    }

    /// The one looked at longest ago first (`ControlRoomChatRules.lookedAt`).
    private var chats: [Chat] = []
    /// The groups whose chat's program ended.
    private(set) var ended: Set<String> = []
    /// What changed `ended`, for the page to draw again.
    var onEnded: (Set<String>) -> Void = { _ in }
    /// A chat with the keyboard in it was hidden or closed, and the keyboard
    /// was taken out of it: where it goes next is the controller's.
    var onKeyboardLeft: () -> Void = {}

    private weak var ghostty: Ghostty.App?

    /// **The door the native chat reads through** (task 2791), handed in by
    /// whoever has the core (`ControlRoomController`). Nil -- and then this
    /// container makes the `polter +chat` terminal it has always made, and
    /// nothing about the page changes. Handed in rather than built here so
    /// that this file decides nothing about the core, and so that the page
    /// keeps working in a build whose core has no such door.
    var askCore: ControlRoomChatFeed.Ask?

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
    }

    /// The group whose chat is in front, as `show` last said.
    private var front: String?

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
            if let feed = chat.feed {
                if shown && seen { feed.start(group: chat.group) } else { feed.stop() }
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
            let host = NSHostingView(rootView: ControlRoomNativeChatPane(group: group, feed: feed))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            Ghostty.logger.notice("control room: chat for \(group, privacy: .public): native, out of the core's own messages")
            return Chat(group: group, view: nil, host: host, feed: feed)
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
        return Chat(group: group, view: view, host: host, feed: nil)
    }

    private func close(at i: Int, why: String) {
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
        if heldKeyboard { takeKeyboard(out: chat, why: "closed") }
        // A native chat's polling stops with it (task 2791): a chat that is
        // gone must not go on asking the core.
        chat.feed?.stop()
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

    /// The chats of groups `alive` no longer knows -- deleted, renamed,
    /// archived -- go.
    func prune(_ alive: (String) -> Bool) {
        for i in chats.indices.reversed() where !alive(chats[i].group) {
            close(at: i, why: "its group is gone")
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

    /// The cell this page's sidebar lives in: **the chat's own, for this
    /// group** (task 2775). Named through `ControlRoomSidebar` so that the
    /// key has one spelling for the whole application, and named with the
    /// group so that switching groups does not carry a preview across.
    private var cell: String { ControlRoomSidebar.key(group: group) }

    var body: some View {
        let theme = Look.theme(scheme)
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
        .panePreview(cell: cell, store: $ghostty.previewStore) { split in
            PanePreviewPanel(cell: cell, split: split, store: $ghostty.previewStore)
                // Where ⌘⌥→ puts the keyboard: a view with nothing in it that
                // the chat stops receiving keys into. Everything it does not
                // use goes on up the responder chain (`SidebarFocusSink`), so
                // nothing is swallowed.
                .background(SidebarFocusSink(wanted: side == .preview))
        }
        .onAppear { model.chatContainer?.show(group) }
        .onChange(of: group) { model.chatContainer?.show($0) }
        .onDisappear { model.chatContainer?.show(nil) }
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
            guard !open else { return }
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
