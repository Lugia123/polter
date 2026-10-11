import Foundation

/// What sits to the right of a tab's title, and in what order.
///
/// **`NSWindowTab.accessoryView` is one slot, and it has one writer**:
/// `TerminalWindow` installs a single stack view there when the window is
/// built and never assigns the slot again. Everything that wants to show
/// something beside the title is an `Item` in that stack, and what changes
/// afterwards is only which items are visible.
///
/// It used to have two writers. The Poltergeist mark assigned the whole
/// slot -- a lone label with a mark, `nil` without one -- so a tab with no
/// mark lost the colour dot, the shortcut hint and the reset-zoom button
/// along with it, and that was every tab in a session nobody supervises
/// (#67).
///
/// This file has no AppKit in it so the rule can be tested without a
/// window.
enum TabAccessory {
    /// The things that can sit in the slot, in the order they are laid out
    /// (leading to trailing).
    ///
    /// **Adding something to the tab is adding a case here**, in the place
    /// it should appear. `TerminalWindow.tabAccessoryView(for:)` switches
    /// over this exhaustively, so the compiler then asks for its view, and
    /// `visibleItems` asks when it shows. The status glyph the control room
    /// wants (0.10) is exactly that: one case, one view, one line below --
    /// nothing that assigns `accessoryView`.
    enum Item: CaseIterable {
        /// The dot in the colour the user gave the tab.
        case colorIndicator
        /// The Poltergeist mark: supervising, supervised, and so on.
        case poltergeistMark
        /// The shortcut that selects this tab, e.g. `⌘1`.
        case keyEquivalent
        /// The button that undoes a split zoom.
        case resetZoom
    }

    /// Everything the slot's contents depend on.
    struct State: Equatable {
        /// The mark as the core reports it; empty when there is none.
        var poltergeistMark: String = ""
        /// Whether a split in this tab is zoomed.
        var surfaceIsZoomed: Bool = false
    }

    /// The mark as it is drawn. The core's mark ends in its own space,
    /// which belonged to the title it used to be a prefix of.
    static func markText(_ mark: String) -> String {
        mark.trimmingCharacters(in: .whitespaces)
    }

    /// Which items are visible, in layout order.
    ///
    /// The colour dot and the shortcut hint are always in the stack: each
    /// draws nothing by itself when it has nothing to say (a clear dot, an
    /// empty string), which is how they behaved before there was a mark.
    /// **No mark hides the mark and nothing else.**
    static func visibleItems(_ state: State) -> [Item] {
        Item.allCases.filter { item in
            switch item {
            case .colorIndicator, .keyEquivalent:
                return true
            case .poltergeistMark:
                return !markText(state.poltergeistMark).isEmpty
            case .resetZoom:
                return state.surfaceIsZoomed
            }
        }
    }
}
