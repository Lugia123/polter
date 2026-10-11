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
    @Published var selection: String?

    private var listening: AnyCancellable?

    /// `showing` answers which tab is in front in the control room's own
    /// window, as the core spells it; it decides only which glyph breathes.
    init(feed: ControlRoomFeed, selection: String? = nil, showing: @escaping () -> String? = { nil }) {
        self.selection = selection
        listening = feed.listen { [weak self] snapshot in
            guard let self else { return }
            let next = ControlRoomList(snapshot: snapshot, showing: showing())
            self.list = next
            // A group that is no longer listed cannot stay selected.
            self.selection = ControlRoomRules.restoredSelection(self.selection, in: next.rows)
        }
    }
}

/// The right-hand side of the control room, which will hold the selected
/// group's supervisor: its real terminal, lent by the tab it lives in and
/// given back afterwards (`control-room.md`, 7.3).
///
/// **Only the holding is here.** Taking a terminal's view out of its own
/// tab, telling the core it moved, and putting it back where it was are the
/// lender's work and are not written yet. This is the socket they plug
/// into, so that building them does not mean reopening the control room.
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

/// The empty container on the right.
final class ControlRoomDetailContainer: NSView, ControlRoomDetailHosting {
    private(set) var hostedGroup: String?
    private var hosted: NSView?

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
