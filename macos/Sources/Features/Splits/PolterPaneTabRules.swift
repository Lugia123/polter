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
    /// over, and always on the one that is focused or in front -- as the
    /// window's own tabs do.
    static func closeShows(hovering: Bool, current: Bool) -> Bool {
        hovering || current
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
