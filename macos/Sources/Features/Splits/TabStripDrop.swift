import Foundation

/// What a pane dragged over a window's tab strip would do if let go there,
/// and how long it waits over a tab before that tab comes to the front
/// (task 1557). Nothing in this file touches a view; `TabStripDragOverlay`
/// draws what it says.
///
/// The Windows host has the same rule in `windows/split-tree/src/drag.rs`
/// (`strip_target`, `TAB_DWELL_SECS`); the two are kept the same by their
/// tests, which name the same cases.
enum TabStripDrop {
    /// How long a dragged pane stays over the middle of another tab before
    /// that tab comes to the front. Was 2.5 s, which was macOS's own tab-bar
    /// spring loading; the user waited without knowing whether anything was
    /// coming.
    static let dwell: TimeInterval = 0.8

    /// A tab in the strip, by where it is along the strip.
    struct Tab: Equatable {
        var minX: Double
        var maxX: Double
    }

    /// What the pointer over the strip means.
    enum Target: Equatable {
        /// Let go here and the pane becomes a new tab at this index: before
        /// the tab that has it now, or at the end when it is the count.
        case insert(Int)
        /// Hold here and this tab comes to the front.
        case bringForward(Int)
        /// Nothing: the middle of the tab in front, or a pane that is
        /// already a tab of its own on its own strip.
        case none
    }

    /// What the pointer at `x` over a strip of `tabs` (left to right) means.
    ///
    /// - Within a quarter of a tab's width of its left or right edge, or in
    ///   the gap between two tabs: the gap on that side.
    /// - Past the last tab: after it. Before the first: before it.
    /// - The rest of a tab, its middle half: that tab comes to the front,
    ///   unless it is `selected` already.
    /// - `alone`: the pane is the only one of a tab in this strip. Making it
    ///   a new tab here would leave everything as it was, so no gap is
    ///   offered; bringing another tab forward still is.
    ///
    /// The quarter lines themselves belong to the middle.
    static func target(x: Double, tabs: [Tab], selected: Int?, alone: Bool) -> Target {
        let gap: (Int) -> Target = { alone ? .none : .insert($0) }
        guard let first = tabs.first, let last = tabs.last else { return .none }
        if x < first.minX { return gap(0) }
        if x > last.maxX { return gap(tabs.count) }
        for (i, tab) in tabs.enumerated() {
            if x < tab.minX { return gap(i) }
            guard x <= tab.maxX else { continue }
            let quarter = (tab.maxX - tab.minX) / 4
            if x < tab.minX + quarter { return gap(i) }
            if x > tab.maxX - quarter { return gap(i + 1) }
            return i == selected ? .none : .bringForward(i)
        }
        return gap(tabs.count)
    }

    /// The x of the insertion mark for gap `index`: midway between the two
    /// tabs on either side, or on the outer edge of the first or last.
    static func markX(index: Int, tabs: [Tab]) -> Double? {
        guard !tabs.isEmpty, index >= 0, index <= tabs.count else { return nil }
        if index == 0 { return tabs[0].minX }
        if index == tabs.count { return tabs[index - 1].maxX }
        return (tabs[index - 1].maxX + tabs[index].minX) / 2
    }

    /// Whether the pointer has stayed over the same tab long enough for it to
    /// come to the front. `T` is whatever names a tab to the caller.
    struct Dwell<T: Equatable> {
        private var over: (tab: T, since: TimeInterval, spent: Bool)?

        init() {}

        /// The pointer is over `tab` -- nil when over no tab that would come
        /// forward -- at `now`. **The tab once**, the first time it has been
        /// under the pointer for the whole dwell; moving off and back starts
        /// again.
        mutating func at(_ tab: T?, now: TimeInterval) -> T? {
            guard let tab else {
                over = nil
                return nil
            }
            guard let was = over, was.tab == tab else {
                over = (tab, now, false)
                return nil
            }
            guard !was.spent, now - was.since >= TabStripDrop.dwell else { return nil }
            over = (tab, was.since, true)
            return tab
        }

        /// How far along the dwell is at `now`, 0 to 1, for the bar under the
        /// tab; nil when there is no tab to bring forward or it has come.
        func progress(now: TimeInterval) -> Double? {
            guard let over, !over.spent else { return nil }
            return min(1, max(0, (now - over.since) / TabStripDrop.dwell))
        }

        /// The tab being waited on.
        var tab: T? {
            guard let over, !over.spent else { return nil }
            return over.tab
        }
    }
}
