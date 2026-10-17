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
        /// The accent dot of a tab whose terminal `terminal_highlight` has
        /// lit (task 1689), breathing with the pane until it ends. First,
        /// so it is the thing nearest the title: the design puts it before
        /// the name, and the system's tabs keep that side to themselves.
        case highlight
        /// The mark of a tab that is a page of a project: two stacked
        /// pages. First, so it is the thing nearest the title.
        case projectMark
        /// The dot in the colour the user gave the tab.
        case colorIndicator
        /// The Poltergeist mark: supervising, supervised, and so on.
        case poltergeistMark
        /// The shortcut that selects this tab, e.g. `⌘1`.
        case keyEquivalent
        /// The button that undoes a split zoom.
        case resetZoom
        /// What the tab's terminals want from the person: one of the
        /// control room's status glyphs, as the core's snapshot gives it
        /// for this tab (`control-room.md`, 3.5 item 4). Last, so it is the
        /// thing at the tab's trailing edge.
        case status
    }

    /// Everything the slot's contents depend on.
    struct State: Equatable {
        /// The mark as the core reports it; empty when there is none.
        var poltergeistMark: String = ""
        /// Whether a split in this tab is zoomed.
        var surfaceIsZoomed: Bool = false
        /// The glyph the core gives this tab; `.none` for none.
        var status: ControlRoomList.Shown = .none
        /// The project this tab is a page of; nil for none.
        var project: String?
        /// Whether a terminal of this tab is lit by `terminal_highlight`.
        var highlighted: Bool = false
    }

    /// How a tab says it is a page of a project.
    ///
    /// **The one place to change it.** The design gave three ways and the
    /// choice between them is not final: a mark beside the title, a line
    /// under it, the project's name before it. The first is what is drawn.
    /// It was drawn at the title's *left* in the design, in the slot where
    /// the close button appears; the system's tabs give no way into that
    /// slot short of reaching into views that are not ours, so the mark is
    /// the first thing at the title's right instead.
    enum ProjectMark: Equatable {
        /// Two stacked pages, in the accessory stack.
        case stackedPages
        /// Nothing drawn.
        case none
    }

    static let projectMark: ProjectMark = .stackedPages

    /// What the mark says when the pointer rests on it: which project,
    /// which the mark alone does not.
    static func projectMarkHelp(_ project: String) -> String {
        String(localized: "A page of the project \"\(project)\"", comment: "标签页上项目记号的悬停提示，参数是项目名")
    }

    /// Whether a status is drawn on a window tab at all.
    ///
    /// Working is not, so that every glyph in a row of tabs is one worth a
    /// look -- unless the look table's switch says otherwise (it is marked
    /// tentative there). The core already leaves working out of what it
    /// gives a tab; this is the same rule on the side that draws, so that a
    /// snapshot from a core that did not would still be drawn the way the
    /// table says.
    static func drawsOnWindowTab(_ status: ControlRoomList.Shown) -> Bool {
        switch status {
        case .needsYou, .trouble, .doneUnseen: return true
        case .working: return ControlRoomLook.WindowTab.workingGlyphShown
        case .none: return false
        }
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
            case .highlight:
                return state.highlighted
            case .projectMark:
                return state.project != nil && projectMark == .stackedPages
            case .colorIndicator, .keyEquivalent:
                return true
            case .poltergeistMark:
                return !markText(state.poltergeistMark).isEmpty
            case .resetZoom:
                return state.surfaceIsZoomed
            case .status:
                return drawsOnWindowTab(state.status)
            }
        }
    }
}
