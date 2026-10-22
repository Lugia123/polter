import Foundation
import CoreGraphics

/// The right side's four pages and the tabs over them (task 2015, Q5;
/// `polter-artifacts/1985/DESIGN-v2.md` §5–6, `polter-artifacts/2015/API.md`
/// §4): Supervisor, Chat, Tasks, Performance.
///
/// **The tabs take the place of the supervisor frame's title bar**, as a
/// stack's strip takes a pane's (`PaneFrameChrome.stack`): the strip is
/// `StackTab.stripHeight` high, which is the bar's `Pane.barHeight`, so the
/// supervisor's terminal stays exactly where it was. What the bar said at
/// its right end -- the supervisor's state and "Let the control room take
/// over?" -- goes to the strip's right end on all four pages.
///
/// The tabs are a stack's tabs without a close button or a plus. Where each
/// one goes is `ControlRoomPageStripLayout`, the same arithmetic as the
/// Windows host's `rightpage::strip`.
///
/// **Which page is in front is the host's, per group** (`ControlRoomModel.
/// pages`), and never the core's. The supervisor's terminal is hidden, not
/// given back and not made again, while another page is in front
/// (`ControlRoomView`).
enum ControlRoomPage: Int, CaseIterable, Equatable {
    case supervisor, chat, tasks, performance

    var label: String {
        switch self {
        case .supervisor:
            String(localized: "Supervisor", comment: "总控台：右栏页签，总管的终端")
        case .chat:
            String(localized: "Chat", comment: "总控台：右栏页签，群聊")
        case .tasks:
            String(localized: "Tasks", comment: "总控台：右栏页签，任务")
        case .performance:
            String(localized: "Performance", comment: "总控台：右栏页签，性能")
        }
    }

    /// Whether the supervisor's terminal is what this page shows.
    var showsTerminal: Bool { self == .supervisor }
}

/// How bad it is for a terminal, or the worst in a group (task 2015): the
/// snapshot's `resource_level` and a page's `tone` (API.md §0–1). A value
/// this build does not know fails the decode, as an unknown glyph does.
enum ControlRoomResourceLevel: String, Decodable, Equatable, CaseIterable {
    /// Nothing measured: not the same as `ok`.
    case none
    case ok
    case warn1, warn2, warn3, warn4
    /// Over its kill line and not stopped.
    case withheld
    case killed

    /// The four colours a level past `ok` is drawn in, from the look's
    /// `level_<tone>` keys; nil for `none` and `ok`.
    struct Ink: Equatable {
        var base: ControlRoomLook.RGBA
        var text: ControlRoomLook.RGBA
        var edge: ControlRoomLook.RGBA
        var badge: ControlRoomLook.RGBA
    }

    func ink(_ t: ControlRoomLook.Theme) -> Ink? {
        switch self {
        case .none, .ok: nil
        case .warn1: Ink(base: t.levelWarn1, text: t.levelWarn1Text, edge: t.levelWarn1Edge, badge: t.levelWarn1Badge)
        case .warn2: Ink(base: t.levelWarn2, text: t.levelWarn2Text, edge: t.levelWarn2Edge, badge: t.levelWarn2Badge)
        case .warn3: Ink(base: t.levelWarn3, text: t.levelWarn3Text, edge: t.levelWarn3Edge, badge: t.levelWarn3Badge)
        case .warn4: Ink(base: t.levelWarn4, text: t.levelWarn4Text, edge: t.levelWarn4Edge, badge: t.levelWarn4Badge)
        case .withheld: Ink(base: t.levelWithheld, text: t.levelWithheldText, edge: t.levelWithheldEdge, badge: t.levelWithheldBadge)
        case .killed: Ink(base: t.levelKilled, text: t.levelKilledText, edge: t.levelKilledEdge, badge: t.levelKilledBadge)
        }
    }
}

/// Where the four tabs go over a right side `width` points wide
/// (`rightpage::strip` on Windows, the same numbers): from inside the
/// frame's border, `StackTab.inset` in; up to `StackTab.trailing` short of
/// its right end. When they do not fit, the widest of the others are cut to
/// one common width, down to `least`; the one in front only when even that
/// is not enough, and then to what there is.
struct ControlRoomPageStripLayout: Equatable {
    typealias Look = ControlRoomLook

    struct Tab: Equatable {
        var page: ControlRoomPage
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var current: Bool
        /// A hairline at its left edge: between two tabs neither of which
        /// is in front.
        var separatorBefore: Bool
        var squeezed: Bool
    }

    var tabs: [Tab]
    /// After the last tab to the strip's right end: what the bar said at
    /// its right end goes here. `x` and `width`.
    var status: (x: CGFloat, width: CGFloat)

    static func == (a: Self, b: Self) -> Bool {
        a.tabs == b.tabs && a.status.x == b.status.x && a.status.width == b.status.width
    }

    /// The narrowest a tab other than the one in front is cut to: its
    /// paddings and two cells.
    static let least = 2 * CGFloat(Look.StackTab.paddingX) + 2 * CGFloat(Look.StackTab.nominalCellWidth)

    /// How wide a tab wants to be when its name measures `name` points.
    static func want(name: CGFloat, marked: Bool) -> CGFloat {
        var w = 2 * CGFloat(Look.StackTab.paddingX) + name
        if marked { w += CGFloat(Look.Side.glyph) + CGFloat(Look.StackTab.gap) }
        return w
    }

    /// `want` with no font: `StackTab.nominalCellWidth` a character, a wide
    /// one two. For tests and for agreeing with the Windows host.
    static func nominalWant(_ name: String, marked: Bool) -> CGFloat {
        let cells = name.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
        return want(name: CGFloat(cells) * CGFloat(Look.StackTab.nominalCellWidth), marked: marked)
    }

    init(width: CGFloat, wants: [CGFloat], current: ControlRoomPage) {
        precondition(wants.count == ControlRoomPage.allCases.count)
        let left = CGFloat(Look.Pane.supervisorBorder)
        let right = max(width - CGFloat(Look.Pane.supervisorBorder), left)
        let start = left + CGFloat(Look.StackTab.inset)
        let room = max(right - CGFloat(Look.StackTab.trailing) - start, 0)
        let front = current.rawValue
        var widths = wants
        if wants.reduce(0, +) > room {
            var others = wants
            others.remove(at: front)
            let least = others.map { min($0, Self.least) }.reduce(0, +)
            let frontW = min(wants[front], max(room - least, 0))
            let cut: [CGFloat]
            if others.reduce(0, +) <= room - frontW {
                cut = others
            } else if least <= room - frontW {
                cut = PaneStackStripLayout.capped(others, to: room - frontW, noLessThan: Self.least)
            } else {
                cut = others.map { min($0, Self.least) }
            }
            widths = cut
            widths.insert(frontW, at: front)
        }
        let y = CGFloat(Look.StackTab.stripHeight) - CGFloat(Look.StackTab.height)
        var x = start
        var tabs: [Tab] = []
        for page in ControlRoomPage.allCases {
            let i = page.rawValue
            tabs.append(Tab(page: page, x: x, y: y, width: widths[i], height: CGFloat(Look.StackTab.height),
                            current: i == front,
                            separatorBefore: i > 0 && i != front && i - 1 != front,
                            squeezed: widths[i] < wants[i]))
            x += widths[i]
        }
        let statusX = x + CGFloat(Look.StackTab.statusGap)
        self.tabs = tabs
        self.status = (statusX, max(right - CGFloat(Look.StackTab.trailing) - statusX, 0))
    }

    /// The page whose tab is under `point`, in the strip's own points.
    func page(at point: CGPoint) -> ControlRoomPage? {
        tabs.first { point.x >= $0.x && point.x < $0.x + $0.width && point.y >= $0.y && point.y < $0.y + $0.height }?.page
    }
}
