import Foundation

/// What a terminal's title is on this host, and whether somebody chose it
/// (task 1735). The rules `SurfaceView` follows, kept apart from the view so
/// they can be tested without one.
///
/// **A rename goes through the core, never straight to the view.** The
/// "Change Terminal Title..." box sends `renameBinding(_:)` -- the same
/// `set_surface_title` an agent and a project's hand-back send -- and the
/// view changes only when the core answers with an explicit `set_title`
/// (`chosen(_:)`). Before, the box set the view's title itself: the window
/// showed the name and the core never heard it, so `terminal_list` read an
/// empty title and a supervisor could not see what the person had called
/// the terminal (#1722, measured).
struct SurfaceTitleState: Equatable {
    /// What the terminal shows.
    var title: String

    /// What the program has said while a chosen name is shown; nil while
    /// nobody has chosen one. Non-nil is what "pinned" means on this host
    /// (`ProjectPaneTitle.live`).
    var fromTerminal: String?

    var pinned: Bool { fromTerminal != nil }

    /// The binding action a rename box sends for what was typed. Empty is a
    /// request too: give the title back to the program.
    static func renameBinding(_ typed: String) -> String {
        "set_surface_title:" + typed
    }

    /// The core's explicit `set_title`: a chosen name, or -- empty -- the
    /// end of one. Unpinning shows what the program said last; with nothing
    /// pinned there is nothing to give back, and the title stays.
    mutating func chosen(_ name: String) {
        if name.isEmpty {
            guard let said = fromTerminal else { return }
            fromTerminal = nil
            title = said
            return
        }
        // Renamed again while pinned: what the program said is still what
        // unpinning returns to, not the previous chosen name.
        if fromTerminal == nil { fromTerminal = title }
        title = name
    }

    /// A title the program reported (OSC 0/2): shown unless a chosen name
    /// is, and remembered either way.
    mutating func reported(_ said: String) {
        if fromTerminal != nil {
            fromTerminal = said
        } else {
            title = said
        }
    }
}
