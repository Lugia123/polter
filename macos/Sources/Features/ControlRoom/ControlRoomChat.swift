import AppKit
import GhosttyKit
import SwiftUI

/// The control room's chat page (task 2015; the design's v1 `C1-chat`): a
/// terminal running `polter +chat --group=<group>`, one a group, where the
/// supervisor's terminal is when the chat page is in front.
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
/// **What it speaks as** is the person: `poltergeistChat`, which tells the
/// core that requests from this surface speak for the person at the
/// keyboard. This is the one place that sets it since task 2080 took the
/// menu's own chat tab out.
///
/// Four are kept; past that the one looked at longest ago goes. A chat
/// whose program ended is **not opened again until the person asks**
/// (group seq 223, the Windows host's `chat_page::ENDED`): one whose
/// program ends as it starts would be opened for ever.
final class ControlRoomChatContainer: NSView {
    private struct Chat {
        let group: String
        let view: Ghostty.SurfaceView
        let host: NSView
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
    private func applyVisibility() {
        let seen = window?.occlusionState.contains(.visible) == true
        for chat in chats {
            let shown = chat.group == front
            chat.host.isHidden = !shown
            ControlRoomLender.setVisible(chat.view, shown && seen)
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
        guard let holder = keyboardHolder, let window else { return }
        holder.view.focusDidChange(window.isKeyWindow)
    }

    /// The chat the keyboard is in, when it is in one.
    private var keyboardHolder: Chat? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return chats.first { responder === $0.view || responder.isDescendant(of: $0.view) }
    }

    /// Take the keyboard out of `chat`: its window has it, and the
    /// controller says who gets it (`onKeyboardLeft`).
    private func takeKeyboard(out chat: Chat, why: String) {
        chat.view.window?.makeFirstResponder(nil)
        chat.view.focusDidChange(false)
        Ghostty.logger.notice("control room: the keyboard was in the chat for \(chat.group, privacy: .public), being \(why, privacy: .public); taken out")
        onKeyboardLeft()
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

    private func make(_ group: String) -> Chat? {
        guard let ghostty, let app = ghostty.app else { return nil }
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
        return Chat(group: group, view: view, host: host)
    }

    private func close(at i: Int, why: String) {
        // **Asked before it leaves `chats`** (group seq 289, M4b 4): after,
        // `keyboardHolder` -- which looks among `chats` -- could never name
        // it, and a chat whose program ended kept the keyboard as it went.
        let hadKeyboard = keyboardHolder?.view === chats[i].view
        let chat = chats.remove(at: i)
        if hadKeyboard { takeKeyboard(out: chat, why: "closed") }
        chat.host.removeFromSuperview()
        Ghostty.logger.notice("control room: chat for \(chat.group, privacy: .public) closed: \(why, privacy: .public)")
    }

    /// Whether `view` is one of the chats.
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
struct ControlRoomChatPage: View {
    typealias Look = ControlRoomLook

    var group: String
    @ObservedObject var model: ControlRoomModel

    @Environment(\.colorScheme) private var scheme

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
        .onAppear { model.chatContainer?.show(group) }
        .onChange(of: group) { model.chatContainer?.show($0) }
        .onDisappear { model.chatContainer?.show(nil) }
    }

    private struct ChatHost: NSViewRepresentable {
        let container: ControlRoomChatContainer
        func makeNSView(context: Context) -> ControlRoomChatContainer { container }
        func updateNSView(_ view: ControlRoomChatContainer, context: Context) {}
    }
}
