import CoreGraphics

/// The settings window's grid (settings.md §2.3a). Every section places
/// itself on these and writes no sizes of its own, so that the rules
/// between blocks meet in one line. The Windows host has the same names and
/// values in `polter-settings-shell`.
enum SettingsLayout {
    /// The band across the top: search box on the left, breadcrumb on the
    /// right, one rule under both.
    static let top: CGFloat = 52
    /// The band across the bottom: one bar for list buttons, status and
    /// Launch / Revert / Save; present, and ruled, in every section.
    static let bottom: CGFloat = 52
    /// The sections column.
    static let sidebar: CGFloat = 220
    /// The item list column of a section that has one (roles, projects).
    static let list: CGFloat = 260
    /// Search box and buttons in the bands.
    static let control: CGFloat = 28
    /// Outer margin.
    static let pad: CGFloat = 16
    /// Between rows of controls.
    static let rowGap: CGFloat = 8
    /// Between groups.
    static let groupGap: CGFloat = 24
    /// A form's label column, labels right-aligned in it.
    static let label: CGFloat = 120
    /// Between the label column and the control column.
    static let labelGap: CGFloat = 8
    /// Every rule in the window.
    static let rule: CGFloat = 1

    /// The sidebar's inset: the search box and the selection highlight both
    /// run from this far in on the left to this far in on the right.
    static let padSidebar: CGFloat = 8
    /// A selectable row's highlight, in from its column's edges.
    static let rowInset: CGFloat = 8
    /// A row's text inside its highlight: what puts the text on the column's
    /// content edge (`pad` in from the column's left rule).
    static let rowTextInset: CGFloat = pad - rowInset

    /// Where the first thing in a column starts, measured from the rule on
    /// the column's left (settings.md §2.3a: "each column's content starts
    /// at its left rule + PAD"). The views place themselves with exactly
    /// these, so that the tests on them are tests on the window.
    enum ContentEdge {
        /// The breadcrumb's text, over the list column.
        static let breadcrumbText = pad
        /// A list row's text.
        static let listText = rowInset + rowTextInset
        /// The first button of the bottom bar, under the list column.
        static let bottomBar = pad
    }

    /// Left and right edges, from the sidebar's own left edge.
    static let sidebarSearchEdges = (left: padSidebar, right: sidebar - padSidebar)
    static let sidebarHighlightEdges = (left: padSidebar, right: sidebar - padSidebar)
}
