import Foundation

/// The colour the user gave a pane (task 1699). The core keeps it, on the
/// terminal, and tells the host on `GHOSTTY_ACTION_POLTERGEIST_PANE`; the
/// host draws it and sets it with `poltergeist_set_pane_color:<name>`.
///
/// **The raw value is the C enum's** (`ghostty_poltergeist_pane_color_e`),
/// and the order is the menu's: never renumbered. The values are the look
/// table's (`pane_<name>`, `_badge`, `_badge_text`), the same for both
/// hosts. There is no AppKit in this file, so the rules are testable
/// without a window.
enum PaneColor: Int, CaseIterable, Equatable {
    case none = 0
    case blue = 1
    case purple = 2
    case pink = 3
    case red = 4
    case orange = 5
    case yellow = 6
    case green = 7
    case teal = 8
    case graphite = 9

    /// The word a project file, a tool reply and a binding action write.
    var name: String {
        switch self {
        case .none: return "none"
        case .blue: return "blue"
        case .purple: return "purple"
        case .pink: return "pink"
        case .red: return "red"
        case .orange: return "orange"
        case .yellow: return "yellow"
        case .green: return "green"
        case .teal: return "teal"
        case .graphite: return "graphite"
        }
    }

    init?(name: String) {
        guard let found = PaneColor.allCases.first(where: { $0.name == name }) else { return nil }
        self = found
    }

    /// What the binding that sets it says.
    var bindingAction: String { "poltergeist_set_pane_color:\(name)" }

    /// The English name, as the hover text and hosts-agree write it.
    var englishName: String {
        switch self {
        case .none: return "None"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .graphite: return "Graphite"
        }
    }

    var localizedName: String {
        switch self {
        case .none: return String(localized: "None", comment: "分屏颜色：无")
        case .blue: return String(localized: "Blue", comment: "分屏颜色")
        case .purple: return String(localized: "Purple", comment: "分屏颜色")
        case .pink: return String(localized: "Pink", comment: "分屏颜色")
        case .red: return String(localized: "Red", comment: "分屏颜色")
        case .orange: return String(localized: "Orange", comment: "分屏颜色")
        case .yellow: return String(localized: "Yellow", comment: "分屏颜色")
        case .green: return String(localized: "Green", comment: "分屏颜色")
        case .teal: return String(localized: "Teal", comment: "分屏颜色")
        case .graphite: return String(localized: "Graphite", comment: "分屏颜色")
        }
    }

    /// The colour a pane is shown in: what the user gave it, and for a
    /// supervisor given none, purple -- the app icon's. The same rule as
    /// the core's `Bus.shownColor` and Windows' `pane::Color::shown`.
    static func shown(set: PaneColor, supervisor: Bool) -> PaneColor {
        set == .none && supervisor ? .purple : set
    }

    /// The dot: on a tab, on a stack tab, the edge with no frames, the menu.
    func dot(_ theme: ControlRoomLook.Theme) -> ControlRoomLook.RGBA? {
        switch self {
        case .none: return nil
        case .blue: return theme.paneBlue
        case .purple: return theme.panePurple
        case .pink: return theme.panePink
        case .red: return theme.paneRed
        case .orange: return theme.paneOrange
        case .yellow: return theme.paneYellow
        case .green: return theme.paneGreen
        case .teal: return theme.paneTeal
        case .graphite: return theme.paneGraphite
        }
    }

    /// The ground of the badge at the left of the pane's title.
    func badge(_ theme: ControlRoomLook.Theme) -> ControlRoomLook.RGBA? {
        switch self {
        case .none: return nil
        case .blue: return theme.paneBlueBadge
        case .purple: return theme.panePurpleBadge
        case .pink: return theme.panePinkBadge
        case .red: return theme.paneRedBadge
        case .orange: return theme.paneOrangeBadge
        case .yellow: return theme.paneYellowBadge
        case .green: return theme.paneGreenBadge
        case .teal: return theme.paneTealBadge
        case .graphite: return theme.paneGraphiteBadge
        }
    }

    /// The mark and the word on the badge.
    func badgeText(_ theme: ControlRoomLook.Theme) -> ControlRoomLook.RGBA? {
        switch self {
        case .none: return nil
        case .blue: return theme.paneBlueBadgeText
        case .purple: return theme.panePurpleBadgeText
        case .pink: return theme.panePinkBadgeText
        case .red: return theme.paneRedBadgeText
        case .orange: return theme.paneOrangeBadgeText
        case .yellow: return theme.paneYellowBadgeText
        case .green: return theme.paneGreenBadgeText
        case .teal: return theme.paneTealBadgeText
        case .graphite: return theme.paneGraphiteBadgeText
        }
    }
}

/// The supervisor's flag among a tab's dots (`ghostty_poltergeist_flag_e`).
enum PaneFlag: Int, Equatable {
    case none = 0
    /// ⚑: a supervisor at its post.
    case raised = 1
    /// ⚐: a supervisor that has not called Polter for a while.
    case lowered = 2

    var name: String {
        switch self {
        case .none: return "none"
        case .raised: return "raised"
        case .lowered: return "lowered"
        }
    }
}
