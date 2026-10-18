import Foundation

/// The dots on a window tab: one for every pane of the tab given a colour,
/// led by the supervisor's flag (task 1699; `pane-color-interface.md` §4).
///
/// **The rule, and nothing that draws it.** The Windows host has the same
/// rule (`tabstrip` in `polter-control-room`), and
/// `tools/control-room-hosts-agree.py` prints both and compares them line by
/// line, so this file has no AppKit in it.
enum TabDots {
    /// One pane of the tab, in reading order (left to right, top to bottom;
    /// a stack's members in the stack's order).
    struct Pane: Equatable {
        var name: String
        /// The colour the user set; `PaneColor.shown` decides what is drawn.
        var color: PaneColor
        var flag: PaneFlag
    }

    /// What is drawn.
    struct Drawn: Equatable {
        /// The supervisor's flag and the colour it is drawn in; nil for none.
        var flag: (PaneFlag, PaneColor)?
        /// The dots drawn, in order: columns of two, top then bottom.
        var dots: [PaneColor]
        /// How many more there are than are drawn; 0 for none.
        var plus: Int
        /// The panes the hover text names, in order.
        var named: [Pane]

        static func == (a: Drawn, b: Drawn) -> Bool {
            a.flag?.0 == b.flag?.0 && a.flag?.1 == b.flag?.1 && a.dots == b.dots && a.plus == b.plus && a.named == b.named
        }

        var isEmpty: Bool { flag == nil && dots.isEmpty }

        /// Columns of dots.
        var columns: Int { (dots.count + 1) / 2 }

        /// The width of the flag and the dots, in points -- `+N` not
        /// counted, whose text each host measures in its own font.
        var width: Double {
            typealias Dots = ControlRoomLook.TabDots
            let dotsWidth = columns == 0 ? 0 : Double(columns) * Dots.dot + Double(columns - 1) * Dots.gap
            guard flag != nil else { return dotsWidth }
            return ControlRoomLook.WindowTab.glyph + (dotsWidth > 0 ? Dots.flagGap + dotsWidth : 0)
        }
    }

    static func of(_ panes: [Pane]) -> Drawn {
        typealias Dots = ControlRoomLook.TabDots
        // The supervisor's flag leads, once; it is not one of the dots.
        let lead = panes.first { $0.flag != .none }
        let flag = lead.map { ($0.flag, PaneColor.shown(set: $0.color, supervisor: true)) }
        let coloured = panes.filter { $0.flag == .none && $0.color != .none }
        let all = coloured.map(\.color)
        let shown = all.count > Int(Dots.max) ? Array(all.prefix(Int(Dots.shownWhenOver))) : all
        var named: [Pane] = []
        if let lead { named.append(lead) }
        named += coloured
        return Drawn(flag: flag, dots: shown, plus: all.count - shown.count, named: named)
    }

    /// The hover text, a line a pane. `english` is what hosts-agree
    /// compares; otherwise it is the person's language.
    static func tip(_ drawn: Drawn, english: Bool = false) -> String {
        // Nothing drawn, nothing said: a tab with no dots has no hover text.
        guard !drawn.named.isEmpty else { return "" }
        var lines = [english ? "Panes with a colour"
            : String(localized: "Panes with a colour", comment: "标签页上颜色点的悬停提示：标题行")]
        // The comma between the parts of a line, which is not a comma in
        // every language.
        let comma = english ? ", " : String(localized: ", ", comment: "标签页上颜色点的悬停提示：一行里各部分之间的分隔符（中文用全角逗号）")
        for pane in drawn.named {
            let color = english ? pane.color.englishName : pane.color.localizedName
            if pane.flag != .none {
                let word = english ? "supervisor"
                    : String(localized: "supervisor", comment: "标签页上颜色点的悬停提示：总管那一行里的「总管」")
                // A supervisor's purple goes without saying; any other
                // colour it was given is said.
                lines.append(PaneColor.shown(set: pane.color, supervisor: true) == .purple
                    ? [pane.name, word].joined(separator: comma) : [pane.name, word, color].joined(separator: comma))
            } else {
                lines.append([pane.name, color].joined(separator: comma))
            }
        }
        return lines.joined(separator: "\n")
    }
}
