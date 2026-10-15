import CoreGraphics
import Foundation

/// The tabs over a pane that holds several terminals, one in front of the
/// rest: where each tab is and how wide (`control-room.md`, 12.6.2, "the
/// look"; the design's `06-panes` and `07-tab-corners`).
///
/// The arithmetic of the strip; `PaneStackStripView` is its drawing.
///
/// Nothing in this file touches a view.
struct PaneStack: Equatable {
    /// One terminal of the stack, as much of it as its tab shows.
    struct Member: Equatable {
        /// The terminal's name, as its frame's title would say it.
        var name: String
        /// The glyph its frame's title draws at the right end: a status or
        /// `held` -- the same pair (task 1582: a tab says what the pane's
        /// title would, from the same values).
        var shown: ControlRoomSnapshot.Terminal.Bar.Shown
        /// Which frame it wears when it is the one in front: the core's
        /// word for that terminal. The frame round a stack is the frame of
        /// whichever member is showing.
        var wears: PaneFrame.Kind
        /// The word after the name that says what it is, as the title
        /// writes it (`PaneFrame.Title.roleWord`); nil for an ordinary
        /// terminal.
        var role: String?
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
    /// What it is for: when tabs are scrolled out of sight, the first of
    /// these that is among them is the glyph that end of the strip carries
    /// (`PaneStackStripLayout.beyond`), so that a terminal waiting off the
    /// edge is not waiting unseen.
    var urgent: [Int] = []
    /// The least a tab is cut to; nil for the table's. Only for pictures
    /// of the other candidate, like `plainStyle`.
    var minTabWidth: CGFloat?

    /// The member in front; the first when `current` is out of range.
    var showing: Member? {
        members.indices.contains(current) ? members[current] : members.first
    }
}

/// What the right end of a strip draws for the member in front: one of
/// the status glyphs, or the mark for a terminal that is held.
///
/// **Held is not a status** (`ControlRoomSnapshot.Terminal.Bar.Shown`): it
/// has no glyph among the status glyphs and no colour of its own, and a
/// strip that drew it as one -- or drew nothing -- would say a held
/// terminal is idle. Which of the two it is is decided here, so that it
/// is tested and the view only draws.
enum PaneStackStatusGlyph: Equatable {
    case status(ControlRoomList.Shown)
    case held

    init(_ shown: ControlRoomSnapshot.Terminal.Bar.Shown) {
        if let status = shown.status {
            self = .status(status)
        } else {
            self = .held
        }
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
///  3. When they do not fit at that either, **they scroll sideways** (task
///     1582): every tab keeps its least width and the room for them is a
///     window onto the row. They used to go behind a `more` menu, which hid
///     who was there.
///  4. The status at the right end gives way before the current tab does:
///     where the two cannot both be had, the status is not drawn. And a
///     current tab that does not fit even alone is cut to what there is.
///
/// A tab's width is its body. The current tab's two feet reach an arc's
/// radius further out on each side; the first tab's inset is what leaves
/// room for the left one. Mirrors `windows/control-room/src/stackstrip.rs`,
/// held to the same answers by `tools/control-room-hosts-agree.py`.
struct PaneStackStripLayout: Equatable {
    typealias Look = ControlRoomLook

    struct Tab: Equatable {
        /// Which member this is: an index into the stack's `members`.
        var member: Int
        /// Where it stands among the others, the tabs not scrolled.
        var x: CGFloat
        var width: CGFloat
        var current: Bool
        /// A hairline at this tab's left edge: between two tabs neither of
        /// which is the current one.
        var separatorBefore: Bool
        /// Less than the tab wanted: its name ends in an ellipsis.
        var squeezed: Bool
    }

    /// Every tab, in order.
    var tabs: [Tab]
    /// How wide the room for the tabs is: the window onto them.
    var viewport: CGFloat
    /// How wide the tabs are together.
    var content: CGFloat
    /// Where the plus starts: after the tabs, or after the room for them
    /// when they scroll.
    var addX: CGFloat
    /// Where the status at the right end may start, and where it ends; nil
    /// when there is no room for it or nothing to say.
    var status: ClosedRange<CGFloat>?

    /// Whether the tabs are wider than the room for them.
    var scrolls: Bool { content > viewport }

    /// The furthest the tabs scroll.
    var maxOffset: CGFloat { max(0, content - viewport) }

    /// How far to scroll the tabs, from `offset`, so that `member`'s tab is
    /// wholly in view: the least move that does it, none when it already
    /// is. What keeps the tab in front in sight, as the window's own tabs
    /// keep theirs.
    ///
    /// **In view is clear of the fades** (task 1594): an end with more tabs
    /// past it fades out over `scrollFade` of the window, and a tab brought
    /// only to the window's edge stood under it. So the tab is brought
    /// `scrollFade` inside the edge it comes in at; at the very start and
    /// end there is no fade, and the clamp leaves the first and the last
    /// tab at the edge.
    func revealing(_ member: Int, from offset: CGFloat) -> CGFloat {
        let offset = min(max(offset, 0), maxOffset)
        guard let tab = tabs.first(where: { $0.member == member }) else { return offset }
        let fade = CGFloat(Look.StackTab.scrollFade)
        let start = tab.x - CGFloat(Look.StackTab.inset)
        let end = start + tab.width
        let to: CGFloat
        if start < offset + fade {
            to = start - fade
        } else if end > offset + viewport - fade {
            to = end - viewport + fade
        } else {
            to = offset
        }
        return min(max(to, 0), maxOffset)
    }

    /// Where the tabs are scrolled to when the strip is drawn again, from
    /// `offset`: `changed` is whether the tab in front, the number of tabs
    /// or the strip's width changed since, `wheeled` whether the person
    /// scrolled them since the last such change.
    ///
    /// **Brought into view unless the person has scrolled since** (task
    /// 1599). It used to be brought in only when one of the three changed
    /// -- and a new terminal's name comes after it is made, so the tab
    /// widened, the tabs' end moved on and the tab in front was left half
    /// under the fade. Scrolled by the wheel, the tabs stay where they were
    /// put until one of the three changes, which clears it.
    func settle(_ member: Int, from offset: CGFloat, changed: Bool, wheeled: Bool) -> CGFloat {
        if changed || !wheeled { return revealing(member, from: offset) }
        return min(max(offset, 0), maxOffset)
    }

    /// The members waiting out of sight, scrolled at `offset`: on each side,
    /// the first of `urgent` -- the core's order, most pressing first --
    /// whose tab is not wholly in view that way. What the strip draws at
    /// that end so that a terminal waiting off the edge is not waiting
    /// unseen (what `more` used to carry). Nil on a side with none.
    func beyond(urgent: [Int], offset: CGFloat) -> (left: Int?, right: Int?) {
        let offset = min(max(offset, 0), maxOffset)
        let inset = CGFloat(Look.StackTab.inset)
        func side(_ test: (Tab) -> Bool) -> Int? {
            urgent.first { member in tabs.first { $0.member == member }.map(test) ?? false }
        }
        return (
            left: side { $0.x - inset < offset },
            right: side { $0.x - inset + $0.width > offset + viewport })
    }

    /// Where a tab let go at `x` along the row of tabs -- 0 at the first
    /// tab's left, the tabs not scrolled -- goes: the place among the tabs
    /// whose middle it is past. 0 is before the first, `tabs.count` after
    /// the last (task 1582).
    func insertion(atRowX x: CGFloat) -> Int {
        let inset = CGFloat(Look.StackTab.inset)
        return tabs.filter { $0.x - inset + $0.width / 2 < x }.count
    }

    /// How wide a tab's name wants it with no font to measure by: so many
    /// cells of `nominal_cell_width`, a wide character two, between the
    /// tab's paddings, room for its glyph when it has one, and the close
    /// button's place, which every tab keeps (task 1582).
    static func nominalWidth(name: String, glyph: Bool) -> CGFloat {
        var cells = 0
        for scalar in name.unicodeScalars {
            cells += scalar.value >= 0x2E80 ? 2 : 1
        }
        var w = 2 * Look.StackTab.paddingX + Double(cells) * Look.StackTab.nominalCellWidth
            + Look.StackTab.closeGap + Look.StackTab.closeButton
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
        let front = wants.indices.contains(current) ? current : 0

        // What is left for the tabs once the inset, the plus, the trailing
        // space and the status are taken out.
        func room(status: CGFloat) -> CGFloat {
            var r = width - leading - CGFloat(t.addButton) - CGFloat(t.trailing)
            if status > 0 { r -= CGFloat(t.statusGap) + status }
            return r
        }

        // The status gives way before the current tab does.
        let frontWants = wants.isEmpty ? 0 : wants[front]
        let said = status > 0 && room(status: status) >= frontWants ? status : 0
        let fits = max(0, room(status: said))

        var widths = wants
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
                // Not even at the least: every tab at its least, and they
                // scroll. One too wide even alone is cut to the room there is.
                widths = least
                widths[front] = min(widths[front], fits)
            }
        }

        var x = leading
        var tabs: [Tab] = []
        for i in wants.indices {
            tabs.append(Tab(member: i, x: x, width: widths[i], current: i == front,
                            separatorBefore: i > 0 && i != front && i - 1 != front,
                            squeezed: widths[i] < wants[i]))
            x += widths[i]
        }
        let content = widths.reduce(0, +)
        self.tabs = tabs
        self.viewport = fits
        self.content = content
        self.addX = leading + min(content, fits)
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
