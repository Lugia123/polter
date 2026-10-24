import CoreGraphics
import Foundation

/// The rules of a pane's title and of a stack's tabs that are not drawing
/// (task 1582): when a close button shows, what "close others / to the
/// right / to the left" close, when closing takes the pane with it, how a
/// tab is picked up, and which way a wheel scrolls the tabs.
///
/// Nothing in here touches a view, so each is tested without the app.
enum PolterPaneTabRules {
    /// Whether a close button shows: on the pane or tab the pointer is
    /// over, and on no other -- not even the one that is focused or in
    /// front -- as the window's own tabs do on macOS (task 1642, which
    /// measured them; until then the current one always showed its button).
    static func closeShows(hovering: Bool) -> Bool {
        hovering
    }

    /// The three ways of closing the tabs of a stack around one of them.
    enum Closing: CaseIterable {
        case others
        case right
        case left
    }

    /// The members `closing` closes around the tab at `index` of a stack of
    /// `count`, in the stack's order. Empty when there is none to close --
    /// which is when the menu greys the item.
    static func closing(_ which: Closing, at index: Int, count: Int) -> [Int] {
        guard count > 0, index >= 0, index < count else { return [] }
        switch which {
        case .others: return (0..<count).filter { $0 != index }
        case .right: return Array((index + 1)..<count)
        case .left: return Array(0..<index)
        }
    }

    /// Whether the menu offers `which` for the tab at `index`.
    static func offers(_ which: Closing, at index: Int, count: Int) -> Bool {
        !closing(which, at: index, count: count).isEmpty
    }

    /// The window tab's own rows, as they stand on a pane's title and on a
    /// stack's tab (task 1582): the ones the system puts on its tab menu,
    /// which this menu carries a copy of.
    enum WindowRow: String, CaseIterable {
        case close
        case closeOthers = "close-others"
        case closeRight = "close-right"
        case moveToNewWindow = "move-to-new-window"

        /// What this row is called, for the dump `tools/control-room-hosts-agree.py`
        /// compares with the Windows host's. `windows/control-room`'s
        /// `panestack::WindowRow::name` is the same string.
        var name: String { rawValue }

        /// Whether it closes *other* tabs of the window rather than this
        /// one. These are the two a stack's tab leaves out, below.
        ///
        /// **A switch, not a `==` pair** (this repository's rule: make the
        /// silence fail to compile). A new row added to `WindowRow` and left
        /// out here would default to "closes this tab only" -- a claim about
        /// what the row does that nobody made, and the one this whole fix is
        /// about. Written this way, adding a row is a compile error until
        /// somebody says which it is.
        var closesOtherTabs: Bool {
            switch self {
            case .closeOthers, .closeRight: true
            case .close, .moveToNewWindow: false
            }
        }
    }

    /// The window tab's rows this menu offers, in the order they are put on
    /// the menu.
    ///
    /// **On a stack's tab the two that close *other* tabs of the window are
    /// left out** (task 2163). They are not wrong -- the system's own tab
    /// menu has both, and so does a plain pane's title -- but this menu
    /// already carries the same words above them with a much narrower
    /// meaning: `Close Others` and `Close to the Right` there close the other
    /// terminals of *this* stack. `Close Other Tabs` beside
    /// `Close Others` reads as the same offer and takes away every other tab
    /// of the window, which is what was reported: a right-click in a stacked
    /// pane chose it meaning this pane's terminals and lost the tab strip.
    ///
    /// Closing this tab, and moving it to a window of its own, are about
    /// this tab and are not confusable with anything above them, so both
    /// stay. A stack's tab is not the only way to either.
    static func windowRows(stacked: Bool) -> [WindowRow] {
        WindowRow.allCases.filter { windowRowOffered($0, stacked: stacked) }
    }

    /// Whether one window row is on the menu at all. The rule itself, which
    /// the Windows host asks as `panestack::window_row_offered` too.
    static func windowRowOffered(_ row: WindowRow, stacked: Bool) -> Bool {
        stacked ? !row.closesOtherTabs : true
    }

    /// Whether closing `members` of a stack of `count` takes the pane with
    /// it: every member goes. A pane left with one is an ordinary pane
    /// again, which `SplitTree.removing(member:)` already does.
    static func closesPane(_ members: [Int], count: Int) -> Bool {
        count > 0 && Set(members.filter { $0 >= 0 && $0 < count }).count == count
    }

    /// How far a wheel moves the tabs sideways: a sideways swipe as it is,
    /// and a wheel that only turns up and down turned sideways -- the
    /// mouse has no other way to reach the tabs off the edge. `precise` is
    /// a trackpad's, in points; a wheel's lines are `line` points each.
    static func scroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool, line: CGFloat = 16) -> CGFloat {
        let delta = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
        return -(precise ? delta : delta * line)
    }
}
