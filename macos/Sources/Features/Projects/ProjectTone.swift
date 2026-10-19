import Foundation

/// The colours a project may be (task 1796), and the one a project is
/// given when it has none: the one of eight that the other projects use
/// least, ties going to the earlier in `order`. Purple is not one of them
/// -- it is a supervisor's -- so a project never shows the colour that says
/// "this pane supervises".
///
/// The Windows host has the same rule as `tone.rs` in the polter-projects
/// crate; `tools/control-room-hosts-agree.py` holds the two to one table.
enum ProjectTone {
    /// The order a project's colour is offered and given in: the design's
    /// (task 1796 v2), so the first projects are the easiest to tell apart.
    static let order: [PaneColor] = [.blue, .orange, .green, .pink, .teal, .yellow, .red, .graphite]

    /// The colour a project file names: one of `order`, and nothing else --
    /// not `none` (written by leaving the key out), not `purple`.
    static func named(_ word: String) -> PaneColor? {
        order.first { $0.name == word }
    }

    /// The colour for a new project, given the colours the others have. A
    /// colour not in `order` (none, purple) counts for nothing.
    static func pick(used: [PaneColor]) -> PaneColor {
        let counts = order.map { tone in used.filter { $0 == tone }.count }
        // The first of the smallest: `order` breaks the tie.
        guard let least = counts.min(), let at = counts.firstIndex(of: least) else { return .blue }
        return order[at]
    }
}
