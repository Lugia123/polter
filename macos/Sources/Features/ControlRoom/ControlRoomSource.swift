import AppKit
import Combine
import Foundation

/// The control room's snapshot, fetched once and handed to everyone who
/// draws from it.
///
/// **Asked only when told, and once however many are listening.** The
/// control room's list and every terminal window's tab glyph draw from the
/// same snapshot. When the core says it changed -- a notification, posted on
/// the main thread by whoever receives `CONTROL_ROOM_CHANGED` -- this
/// fetches it one time, decodes it one time, and gives the result to each
/// listener. A listener that arrives later is given what is already here
/// and causes no fetch. Nothing in here may poll: a control room nothing is
/// happening in must not wake once (`dev-docs/poltergeist/control-room.md`,
/// 5.4 and 13.2).
///
/// The fetch is handed in as a closure with the core's buffer rule (write
/// into the buffer if it fits, always return the real length), so that
/// everything but the one C call can be run without the core.
final class ControlRoomFeed {
    typealias Fetch = (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
    typealias Listener = (ControlRoomSnapshot) -> Void

    /// Posted when the core says the control room's snapshot changed.
    static let changed = Notification.Name("PolterControlRoomChanged")

    /// The last snapshot that could be read; nil until there is one.
    /// **Nil is not an empty control room**: the core has not worked one
    /// out yet, and whoever draws from this draws nothing.
    private(set) var latest: ControlRoomSnapshot?

    private let fetch: Fetch
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private var listeners: [UUID: Listener] = [:]

    init(center: NotificationCenter = .default, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.center = center
        // No queue: it runs where it is posted, which is the main thread.
        observer = center.addObserver(forName: Self.changed, object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        }
        // Whatever the core already has. After this, only a notice fetches.
        refresh()
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Be handed every snapshot from now on, and the current one at once if
    /// there is one. Keep the token; the listening stops when it goes away.
    func listen(_ listener: @escaping Listener) -> AnyCancellable {
        let id = UUID()
        listeners[id] = listener
        if let latest { listener(latest) }
        return AnyCancellable { [weak self] in self?.listeners[id] = nil }
    }

    /// One fetch, one decode, everyone told. A notice with nothing readable
    /// behind it changes nothing: the listeners keep what they have.
    private func refresh() {
        guard let json = Self.read(fetch),
              let snapshot = try? JSONDecoder().decode(ControlRoomSnapshot.self, from: json) else { return }
        latest = snapshot
        for listener in listeners.values { listener(snapshot) }
    }

    /// The bytes the core has, or nil when it has none. Asks for the length
    /// first, then for the bytes with room for the NUL the core adds.
    static func read(_ fetch: Fetch) -> Data? {
        let length = fetch(nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length + 1)
        let written = buffer.withUnsafeMutableBufferPointer { fetch($0.baseAddress, $0.count) }
        // Longer than it said a moment ago: it was not written, so there is
        // nothing to read this time. The next notice asks again.
        guard written > 0, written < buffer.count else { return nil }
        return buffer.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[..<written])) }
    }
}

/// What the control room's views show: the list and which row is selected.
final class ControlRoomModel: ObservableObject {
    /// Nil until the core has a snapshot.
    @Published private(set) var list: ControlRoomList?
    /// The selected group. Read by everything; **written by the person
    /// through `choose`**, and by the two rules that may set it without
    /// them (a kept selection whose group is gone, and the group to open
    /// on).
    @Published private(set) var selection: String?
    /// Whether the selection is one the person made -- a click, an arrow
    /// key, or what they had selected before a restart -- and not the row
    /// the control room opened on by itself. Only the person's own counts
    /// as looking at a row.
    private(set) var selectionIsThePersons = true
    /// False until the first snapshot since this control room was opened.
    private var hasOpened = false

    /// The selected row, whoever selected it.
    var selectedRow: ControlRoomList.Row? {
        list?.rows.first { $0.id == selection }
    }

    /// Whether the terminal on the right-hand side has the keyboard: its
    /// frame's edge says so. Written by `ControlRoomController`.
    @Published var detailHasKeyboard = false

    /// The last frame a terminal drew on the right-hand side, taken as it
    /// was given back, and which terminal that was. Written by
    /// `ControlRoomController`.
    @Published var frozen: (terminal: String, frame: CGImage)?

    /// `ControlRoomElsewhere.frame`, asked of what was last taken.
    func lastFrame(for detail: ControlRoomLending.Detail) -> CGImage? {
        ControlRoomElsewhere.frame(for: detail, frozen: frozen)
    }

    /// The title of the frame on the right while it holds a terminal; nil
    /// while it holds a sentence.
    var supervisorTitle: ControlRoomList.SupervisorTitle? {
        guard detail.terminal != nil else { return nil }
        return selectedRow?.supervisor
    }

    /// Told after every `choose`, including one that selects the row
    /// already selected: that is how a row the control room opened on
    /// becomes one the person is looking at.
    var onChoose: () -> Void = {}

    /// Told which cards are wholly on screen, each time that changes.
    /// Written by `ControlRoomController`, which tells the core.
    var onCardsInSight: ([String]) -> Void = { _ in }

    /// The person selected `id` (nil for nothing).
    func choose(_ id: String?) {
        selectionIsThePersons = true
        if selection != id { selection = id }
        onChoose()
    }

    /// The selected row, when looking at it is the person's doing; nil
    /// when nothing is selected or the control room picked it.
    var rowBeingLookedAt: ControlRoomList.Row? {
        guard selectionIsThePersons else { return nil }
        return list?.rows.first { $0.id == selection }
    }
    /// What the right-hand side shows. Written by whoever runs the lending
    /// (`ControlRoomController`); the views only read it.
    @Published var detail: ControlRoomLending.Detail = .nothingSelected
    /// The person asked, on the right-hand side, for the terminal they had
    /// taken back.
    var askForTerminal: () -> Void = {}
    /// Return on the list: go to the selected group's supervisor in its own
    /// tab, with the keyboard -- what Return does on Windows' list
    /// (`control_room.rs::go_to_supervisor`), task 1551.
    var goToSupervisor: () -> Void = {}

    /// Sends what the person does about a group. Handed in by whoever has
    /// the core (`ControlRoomController`); without it nothing is done and
    /// the person is told so.
    var perform: (ControlRoomActions.Act) throws -> Void = { _ in
        throw ControlRoomActions.Refusal(name: "NoCore")
    }
    /// Why the last "start a supervisor" was not done, and for which
    /// group: said on the right-hand side, under the button, until they
    /// try again or look at another group.
    @Published private(set) var startRefusal: (group: String, message: String)?
    /// A group the person has just made, until the core lists it.
    /// Also a group the person has just renamed, by its new name.
    var madeGroup: String?
    /// Why the last "Fix" was not done, and on which row: said beside the
    /// button until it is pressed again or the card stops offering it.
    @Published private(set) var fixRefusal: (row: String, message: String)?

    // MARK: The row's menu (task 1660; `ControlRoomModel+RowMenu.swift`)

    /// The row whose name is a field, what is in it, and why that would
    /// be refused; nil when no row is being renamed.
    @Published var renaming: ControlRoomRowMenuState.Renaming?
    /// The group whose note is open in the panel at the right; nil when
    /// the panel is not there.
    @Published var noteEditing: ControlRoomRowMenuState.NoteEditing?
    /// The line under a row once its supervisor was asked something, or a
    /// menu item was refused, by row.
    @Published var rowLines: [String: ControlRoomRowMenuState.RowLine] = [:]
    /// Whether "Archived" at the bottom of the list is open.
    @Published var archivedOpen = false
    /// Where a group's records are shown, a terminal's id copied, and the
    /// two questions asked. Handed in, so the rest runs without AppKit's
    /// side effects (tests replace them).
    var effects = ControlRoomRowMenuState.Effects.system

    /// Make a group by the name the person typed. Returns what to tell
    /// them when it was not made; nil when it was -- and then it is
    /// selected as soon as the core lists it.
    /// The person said OK to the first sweep of old records.
    func agreeToRetention() {
        try? perform(.retentionAgree)
    }

    func newGroup(named name: String) -> String? {
        do {
            try perform(.newGroup(name: name))
        } catch let refusal as ControlRoomActions.Refusal {
            return refusal.message
        } catch {
            return ControlRoomActions.Refusal(name: "Refused").message
        }
        // The core trims what was typed and makes nothing else of it.
        madeGroup = name.trimmingCharacters(in: .whitespacesAndNewlines)
        selectMadeGroup()
        return nil
    }

    private func selectMadeGroup() {
        guard let made = ControlRoomRules.madeGroupToSelect(madeGroup, in: list?.rows ?? []) else { return }
        madeGroup = nil
        choose(made)
    }

    /// "Fix" on a card that reads "Failed" (task 1560): the core tells the
    /// card's supervisor, and the next list greys the button. A refusal is
    /// kept beside it, and the button stays to be pressed again.
    func fix(_ row: ControlRoomList.Row) {
        guard let act = ControlRoomActions.fix(row) else { return }
        do {
            try perform(act)
            fixRefusal = nil
        } catch let refusal as ControlRoomActions.Refusal {
            fixRefusal = (row.id, refusal.message)
        } catch {
            fixRefusal = (row.id, ControlRoomActions.Refusal(name: "Refused").message)
        }
    }

    /// "Let the control room take over?" on `group`'s supervisor (task
    /// 1635): ask the core's question, and on yes, ask the core to do it.
    /// What becomes of it arrives in the next list; a refusal is said at
    /// once, in a second sheet, because there is nowhere on the bar to keep
    /// it.
    func takeOver(group: String, question: String) {
        let ask = NSAlert()
        ask.messageText = String(localized: "Let the control room take over?",
                                 comment: "总控台：手动启动的总管，标题条上的按钮")
        ask.informativeText = question
        ask.addButton(withTitle: String(localized: "Take Over", comment: "总控台：确认接管手动启动的总管"))
        let cancel = ask.addButton(withTitle: String(localized: "Cancel", comment: "总控台：确认接管手动启动的总管时取消"))
        // Escape is bound to an English "Cancel" only; say it here.
        cancel.keyEquivalent = "\u{1b}"
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        do {
            try perform(.takeOver(group: group))
        } catch let refusal as ControlRoomActions.Refusal {
            let told = NSAlert()
            told.messageText = refusal.message
            told.runModal()
        } catch {
            let told = NSAlert()
            told.messageText = ControlRoomActions.Refusal(name: "Refused").message
            told.runModal()
        }
    }

    /// Start a supervisor for `group`. A nil role or directory is the one
    /// the core named. What becomes of it arrives in the next list; a
    /// refusal is kept to be shown.
    func startSupervisor(for group: String, role: String?, cwd: String?,
                         session: ControlRoomStartChoice.Session? = nil, cli: String? = nil) {
        do {
            try perform(.startSupervisor(group: group, role: role, cwd: cwd, session: session, cli: cli))
            startRefusal = nil
        } catch let refusal as ControlRoomActions.Refusal {
            startRefusal = (group, refusal.message)
        } catch {
            startRefusal = (group, ControlRoomActions.Refusal(name: "Refused").message)
        }
    }

    private var listening: AnyCancellable?

    /// `showing` answers which tab is in front in the control room's own
    /// window, as the core spells it; it decides only which glyph breathes.
    init(feed: ControlRoomFeed, selection: String? = nil, showing: @escaping () -> String? = { nil }) {
        self.selection = selection
        listening = feed.listen { [weak self] snapshot in
            guard let self else { return }
            let next = ControlRoomList(snapshot: snapshot, showing: showing())
            self.list = next
            // An ask being tried again may have gone in, or been given up on.
            self.followAsks(in: next)
            // A refusal is about a button that is there to press again;
            // once the card stops offering it, there is nothing to say.
            if let refused = self.fixRefusal,
               next.rows.first(where: { $0.id == refused.row })?.fix != .offered {
                self.fixRefusal = nil
            }
            // A group that is no longer listed cannot stay selected.
            let kept = ControlRoomRules.restoredSelection(self.selection, in: next.rows)
            let start = ControlRoomRules.selection(
                current: kept, opening: !self.hasOpened, openOn: snapshot.open_on)
            self.hasOpened = true
            if !start.isThePersons { self.selectionIsThePersons = false }
            if self.selection != start.id { self.selection = start.id }
            self.selectMadeGroup()
        }
    }
}

/// The right-hand side of the control room, which holds the selected
/// group's supervisor: its real terminal, lent by the tab it lives in and
/// given back afterwards (`control-room.md`, 7.3).
///
/// **Only the holding is here.** Which terminal, when it comes and when it
/// goes back is `ControlRoomLending`; taking its view out of its own tab
/// and putting it back is `ControlRoomController` with `ControlRoomLender`.
protocol ControlRoomDetailHosting: AnyObject {
    /// The group whose pane is being shown; nil when the side is empty.
    var hostedGroup: String? { get }

    /// Show `view` as the pane of `group`. Whatever was shown before is
    /// handed back through the return value, for the caller to return to
    /// its owner: this never drops a view it was lent.
    @discardableResult
    func host(_ view: NSView, for group: String) -> NSView?

    /// Stop showing the pane and hand it back; nil when there was none.
    @discardableResult
    func giveBack() -> NSView?
}

/// The container on the right.
final class ControlRoomDetailContainer: NSView, ControlRoomDetailHosting {
    private(set) var hostedGroup: String?
    private var hosted: NSView?

    /// The terminal sits inside the supervisor's frame with its corners
    /// rounded (`ControlRoomSupervisorFrame`). Rounded here, on the layer
    /// that holds the terminal's own, because that is what clips it.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(ControlRoomLook.Radius.supervisorInner)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    @discardableResult
    func host(_ view: NSView, for group: String) -> NSView? {
        let previous = giveBack()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hosted = view
        hostedGroup = group
        return previous
    }

    @discardableResult
    func giveBack() -> NSView? {
        guard let view = hosted else { return nil }
        view.removeFromSuperview()
        hosted = nil
        hostedGroup = nil
        return view
    }
}
