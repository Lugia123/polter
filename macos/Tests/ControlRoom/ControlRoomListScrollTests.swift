import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The list as the app hosts it, off screen, with more groups than the
/// panel holds (task 1654): the selected row is brought wholly into sight
/// by the least scroll, read from the scroll view itself.
@MainActor
struct ControlRoomListScrollTests {
    final class Selection: ObservableObject {
        @Published var id: String?
    }

    struct Host: View {
        @ObservedObject var selection: Selection
        let list: ControlRoomList
        var body: some View {
            ControlRoomListView(list: list, selection: Binding(get: { selection.id }, set: { selection.id = $0 }), still: true)
                .frame(height: 824)
        }
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    @Test func theSelectedRowIsScrolledWhollyIntoSight() async throws {
        var list = ControlRoomList.sample
        let one = list.quiet[0]
        list.quiet = (0 ..< 30).map { var row = one; row.id = "g\($0)"; return row }
        list.quietCount = 30
        list.quota = ControlRoomQuota.Sample.ordinary
        let layout = ControlRoomListLayout(list: list, height: 824, needed: ControlRoomAskText.needed)
        let selection = Selection()
        // It opens on a row below the bottom.
        selection.id = "g29"
        let host = NSHostingView(rootView: Host(selection: selection, list: list))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 824)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        func settle() async throws {
            for _ in 0 ..< 15 {
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
            }
        }
        try await settle()
        let scrollView = try #require(Self.scrollViews(in: host).first)
        var offset: CGFloat { scrollView.contentView.bounds.origin.y }
        func row(_ id: String) throws -> CGRect { try #require(layout.rows[id]) }
        let top = layout.viewport.minY, bottom = layout.viewport.maxY
        #expect(abs(scrollView.frame.height - layout.viewport.height) < 1)

        // Below: its bottom to the bottom of the room.
        #expect(offset == (try row("g29")).maxY - bottom)
        // Already in sight: nothing moves.
        let before = offset
        selection.id = "g28"
        try await settle()
        #expect(offset == before)
        // Above: its top to the top of the room, not the top of the list.
        selection.id = "g0"
        try await settle()
        #expect(offset == (try row("g0")).minY - top)
        // Walked back to the first row with the keys, one row at a time.
        for id in list.waiting.reversed().map(\.id) {
            selection.id = id
            try await settle()
        }
        #expect(offset == 0)
        // And down again, one row at a time: always the least.
        for id in list.rows.map(\.id) {
            selection.id = id
            try await settle()
            let r = try row(id)
            #expect(r.minY >= top + offset - 0.5 && r.maxY <= bottom + offset + 0.5, "\(id) at \(offset)")
        }
        #expect(offset == (try row("g29")).maxY - bottom)
    }
}
