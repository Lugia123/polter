import AppKit
import Combine
import Foundation

/// Where the control room's list comes from.
///
/// **Asked only when told.** `snapshot()` is called once when the control
/// room opens and after that only from `onChange`, which the source calls
/// when the core says the snapshot changed. Nothing here may poll: a control
/// room that nothing is happening in must not wake once
/// (`dev-docs/poltergeist/control-room.md`, 5.4 and 13.2). That is why this
/// has no publisher that ticks, no interval, and no "refresh".
///
/// `ControlRoomCoreSource` is the real one: the core's
/// `ghostty_app_control_snapshot`, fetched on its `CONTROL_ROOM_CHANGED`.
protocol ControlRoomSnapshotSource: AnyObject {
    /// The list as it is now, or nil when there is none yet. **Nil is not
    /// an empty list**: the core has not worked a snapshot out, and the
    /// control room draws nothing rather than "0 groups waiting".
    func snapshot() -> ControlRoomList?

    /// Set by whoever shows the list. The source calls it, on the main
    /// thread, each time the snapshot has changed.
    var onChange: (() -> Void)? { get set }
}

/// The design's example, standing in for the core in tests and still
/// pictures. It never changes, so it never calls `onChange`.
final class ControlRoomSampleSource: ControlRoomSnapshotSource {
    var onChange: (() -> Void)?

    func snapshot() -> ControlRoomList? { .sample }
}

/// The core's snapshot.
///
/// It is told the snapshot changed by a notification -- posted, on the main
/// thread, by whoever receives the core's `CONTROL_ROOM_CHANGED` -- and only
/// then calls `onChange`, whose owner fetches. There is no other path to a
/// fetch in here.
///
/// The fetch itself is handed in as a closure with the core's buffer rule
/// (write into the buffer if it fits, always return the real length), so
/// that everything but the one C call can be run without the core.
final class ControlRoomCoreSource: ControlRoomSnapshotSource {
    typealias Fetch = (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int

    /// Posted when the core says the control room's snapshot changed.
    static let changed = Notification.Name("PolterControlRoomChanged")

    var onChange: (() -> Void)?

    private let fetch: Fetch
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.center = center
        // No queue: it runs where it is posted, which is the main thread.
        observer = center.addObserver(forName: Self.changed, object: nil, queue: nil) { [weak self] _ in
            self?.onChange?()
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func snapshot() -> ControlRoomList? {
        guard let json = Self.read(fetch) else { return nil }
        // A snapshot this build cannot read is not an empty control room
        // either: nil, and the caller keeps what it had.
        return try? ControlRoomList.decode(snapshot: json)
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

    private let source: ControlRoomSnapshotSource

    init(source: ControlRoomSnapshotSource, selection: String? = nil) {
        self.source = source
        self.list = source.snapshot()
        self.selection = selection
        source.onChange = { [weak self] in self?.refresh() }
    }

    /// Take the snapshot again. Called by the source's notice and by
    /// nothing else.
    private func refresh() {
        // A notice with nothing readable behind it keeps what is shown.
        guard let next = source.snapshot() else { return }
        list = next
        // A group that is no longer listed cannot stay selected.
        selection = ControlRoomRules.restoredSelection(selection, in: next.rows)
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
