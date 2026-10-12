import CoreGraphics
import Foundation

/// The tabs over a pane that holds several terminals, one in front of the
/// rest: where each tab is and how wide (`control-room.md`, 12.6.2, "the
/// look"; the design's `06-panes` and `07-tab-corners`).
///
/// **Nothing is wired to this yet.** No pane holds more than one terminal:
/// the split tree has no stacks (12.6.2, steps 1 to 3). This is the
/// arithmetic of the strip and `PaneStackStripView` is its drawing, so that
/// what a stack will look like can be seen and ruled on before it exists.
///
/// Nothing in this file touches a view.
struct PaneStack: Equatable {
    /// One terminal of the stack, as much of it as its tab shows.
    struct Member: Equatable {
        /// The terminal's name, as its frame's title would say it.
        var name: String
        /// The glyph the core gives that terminal.
        var shown: ControlRoomList.Shown
        /// Which frame it wears when it is the one in front: the core's
        /// word for that terminal. The frame round a stack is the frame of
        /// whichever member is showing.
        var wears: PaneFrame.Kind
    }

    /// How an ordinary terminal's stack is drawn. **The design draws
    /// none**: both are candidates until one is chosen.
    enum PlainStyle: Equatable {
        /// A band behind the tabs, the colour of a worker's, with no line
        /// round the pane: the current tab is cut out of the band the way
        /// a worker's is.
        case band
        /// No band: the names stand on the terminal's own ground with a
        /// hairline between them, and the current one is the one in the
        /// terminal's bold. There is nothing for a tab's shape to be cut
        /// out of, so none is drawn.
        case bare
    }

    /// In the order of the tabs. Never empty.
    var members: [Member]
    /// Which member is in front: an index into `members`.
    var current: Int
    var plainStyle: PlainStyle = .band
    /// The members that have a glyph to show, **the most pressing first**:
    /// indices into `members`, in the order the core merges several
    /// terminals into one glyph by (`Attention.top`: the highest glyph,
    /// and among equals the one that has waited longest). The core's
    /// order, handed in -- nothing here ranks one glyph over another.
    ///
    /// What it is for: when some tabs are behind `more`, the first of
    /// these that is among them is the glyph `more` carries, so that a
    /// terminal waiting behind the dots is not waiting unseen.
    var urgent: [Int] = []
    /// The least a tab is cut to; nil for the table's. Only for pictures
    /// of the other candidate, like `plainStyle`.
    var minTabWidth: CGFloat?

    /// The member in front; the first when `current` is out of range.
    var showing: Member? {
        members.indices.contains(current) ? members[current] : members.first
    }
}

/// Where everything in a stack's strip is, left to right, in the strip's
/// own points: 0 is the frame's content edge (inside a supervisor's border,
/// the frame's own edge for the other two).
///
/// **The rule, in the order it gives way:**
///
///  1. Every tab is as wide as its name wants.
///  2. When they do not all fit, the widest are cut to one common width --
///     so the long names give way first and the short ones are left whole --
///     down to `min_width` and no further. **The current tab is not cut**:
///     its name is the one being read.
///  3. When they do not fit at that either, the ones there is no room for
///     go behind a `more` button at the right end of the tabs. The current
///     tab is never one of them: its place is kept before any other is
///     given one. The tabs that stay then share the room there is by
///     rule 2.
///  4. The status at the right end gives way before the current tab does:
///     where the two cannot both be had, the status is not drawn. And a
///     current tab that does not fit even alone is cut to what there is.
///
/// A tab's width is its body. The current tab's two feet reach an arc's
/// radius further out on each side; the first tab's inset is what leaves
/// room for the left one.
struct PaneStackStripLayout: Equatable {
    typealias Look = ControlRoomLook

    struct Tab: Equatable {
        /// Which member this is: an index into the stack's `members`.
        var member: Int
        var x: CGFloat
        var width: CGFloat
        var current: Bool
        /// A hairline at this tab's left edge: between two tabs neither of
        /// which is the current one.
        var separatorBefore: Bool
        /// Less than the tab wanted: its name ends in an ellipsis.
        var squeezed: Bool
    }

    /// The tabs that are drawn, in order.
    var tabs: [Tab]
    /// The members behind `more`, in order. Empty when every tab is drawn.
    var hidden: [Int]
    /// Where the `more` button starts; nil when there is none.
    var moreX: CGFloat?
    /// Where the plus starts.
    var addX: CGFloat
    /// Where the status at the right end may start, and where it ends; nil
    /// when there is no room for it or nothing to say.
    var status: ClosedRange<CGFloat>?

    /// The member whose glyph `more` carries: the first of `urgent` -- the
    /// core's order, most pressing first -- that is behind it. Nil when
    /// nothing is behind `more`, or nothing behind it has a glyph. A walk
    /// down a list and a test of membership: which is more pressing was
    /// settled when the list was ordered.
    func behindMore(urgent: [Int]) -> Int? {
        urgent.first { hidden.contains($0) }
    }

    /// How wide a tab's name wants it with no font to measure by: so many
    /// cells of `nominal_cell_width`, a wide character two, between the
    /// tab's paddings, and room for its glyph when it has one.
    static func nominalWidth(name: String, glyph: Bool) -> CGFloat {
        var cells = 0
        for scalar in name.unicodeScalars {
            cells += scalar.value >= 0x2E80 ? 2 : 1
        }
        var w = 2 * Look.StackTab.paddingX + Double(cells) * Look.StackTab.nominalCellWidth
        if glyph { w += Look.StackTab.gap + Look.Side.glyph }
        return CGFloat(w)
    }

    /// - Parameters:
    ///   - wants: how wide each tab's body wants to be, in the stack's order:
    ///     a measurement, which is the host's to make.
    ///   - current: which is in front.
    ///   - width: the strip's, between the content's edges.
    ///   - status: how wide the status at the right end is; 0 for none.
    ///   - minWidth: the least a tab is cut to. The table's, unless a
    ///     picture is being made of the other candidate.
    init(wants: [CGFloat], current: Int, width: CGFloat, status: CGFloat,
         minWidth: CGFloat = CGFloat(Look.StackTab.minWidth)) {
        let t = Look.StackTab.self
        let leading = CGFloat(t.inset)
        let add = CGFloat(t.addButton)
        let more = CGFloat(t.moreButton)
        let front = wants.indices.contains(current) ? current : 0

        // What is left for the tabs once the inset, the plus, the trailing
        // space and whatever else is asked for are taken out.
        func room(status: CGFloat, more: Bool) -> CGFloat {
            var r = width - leading - add - CGFloat(t.trailing)
            if status > 0 { r -= CGFloat(t.statusGap) + status }
            if more { r -= CGFloat(t.moreButton) }
            return r
        }

        // The status gives way before the current tab does.
        let frontWants = wants.isEmpty ? 0 : wants[front]
        let said = status > 0 && room(status: status, more: false) >= frontWants ? status : 0
        let fits = room(status: said, more: false)

        var widths = wants
        var shown = Array(wants.indices)
        var hidden: [Int] = []

        if wants.reduce(0, +) > fits {
            // The least each may be: the current one whole, the rest at
            // `min_width` or their own width when that is less.
            let least = wants.indices.map { $0 == front ? wants[$0] : min(wants[$0], minWidth) }
            if least.reduce(0, +) <= fits {
                // One common ceiling for the wide ones among the rest: the
                // widest are cut first, to the width at which everything
                // just fits.
                var others = wants
                others.remove(at: front)
                var cut = Self.capped(others, to: fits - frontWants, noLessThan: minWidth)
                cut.insert(frontWants, at: front)
                widths = cut
            } else {
                // Not even at the least: some go behind `more`.
                widths = least
                let fitsWithMore = room(status: said, more: true)
                var taken: [Int] = []
                var used = least[front]
                for i in wants.indices where i != front {
                    if used + least[i] > fitsWithMore { break }
                    taken.append(i)
                    used += least[i]
                }
                // In the stack's order, the current one where it belongs
                // among those that stayed.
                shown = wants.indices.filter { $0 == front || taken.contains($0) }
                hidden = wants.indices.filter { !shown.contains($0) }
                // Too wide even alone: it is cut to what there is.
                widths[front] = max(0, min(least[front], fitsWithMore))
                // Those that stayed were counted at their least; what room
                // is left over goes back to them, the widest cut first as
                // before, so that a strip with tabs behind `more` is not
                // also a strip of names cut shorter than they need be.
                let back = Self.capped(taken.map { wants[$0] }, to: fitsWithMore - widths[front], noLessThan: minWidth)
                for (n, i) in taken.enumerated() { widths[i] = back[n] }
            }
        }

        var x = leading
        var tabs: [Tab] = []
        for (place, i) in shown.enumerated() {
            let before = place > 0 ? shown[place - 1] : nil
            tabs.append(Tab(member: i, x: x, width: widths[i], current: i == front,
                            separatorBefore: before != nil && i != front && before != front,
                            squeezed: widths[i] < wants[i]))
            x += widths[i]
        }
        self.tabs = tabs
        self.hidden = hidden
        if hidden.isEmpty {
            moreX = nil
        } else {
            moreX = x
            x += more
        }
        addX = x
        let end = width - CGFloat(t.trailing)
        self.status = said > 0 ? (end - said)...end : nil
    }

    /// `wants` with the widest cut to one common width so that they add up
    /// to `total`, and nothing that was wider than `least` cut below it.
    /// The caller has seen to it that they fit at `least`.
    static func capped(_ wants: [CGFloat], to total: CGFloat, noLessThan least: CGFloat) -> [CGFloat] {
        // Every tab starts out as one that will be cut. An even share of
        // the room among those is worked out; any that wants no more than
        // its share is left whole, which leaves more for the rest, so the
        // share is worked out again -- until none of them moves.
        var whole = Array(repeating: false, count: wants.count)
        var ceiling = CGFloat.greatestFiniteMagnitude
        while true {
            var left = total
            var cut = 0
            for i in wants.indices {
                if whole[i] { left -= wants[i] } else { cut += 1 }
            }
            guard cut > 0 else { break }
            let share = left / CGFloat(cut)
            var moved = false
            for i in wants.indices where !whole[i] && wants[i] <= share {
                whole[i] = true
                moved = true
            }
            if !moved {
                // Whole points, so that two hosts adding the same numbers
                // get the same tabs.
                ceiling = max(least, share.rounded(.down))
                break
            }
        }
        return wants.map { min($0, ceiling) }
    }
}
