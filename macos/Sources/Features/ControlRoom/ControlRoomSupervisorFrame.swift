import SwiftUI

/// The frame a supervisor's terminal wears on the control room's right-hand
/// side (`control-room.md`, 3.5, item 6): a border all round, its top edge
/// thickened into a title bar, floating over the window's ground.
///
/// **The frame itself is `PaneFrameView`**, which the panes of a split
/// terminal tab draw too (`PaneFrameSplit`); this is that view as a
/// supervisor's, with the design's terminal ground inside. The stacked
/// tabs the design puts where the title bar is are a later piece.
///
/// The title is a `ControlRoomList.SupervisorTitle`, which is the core's
/// words.
struct ControlRoomSupervisorFrame<Content: View>: View {
    /// What the bar says while the frame holds a terminal.
    var title: ControlRoomList.SupervisorTitle?
    /// What it says while the frame holds a sentence: the group's name, or
    /// nothing when no group is selected.
    var caption: String?
    /// The terminal inside has the keyboard.
    var focused: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        PaneFrameView(wears: .supervisor, title: title, caption: caption, focused: focused, content: content)
    }
}

/// What the right-hand side says when there is no terminal on it.
struct ControlRoomDetailMessage: View {
    typealias Look = ControlRoomLook

    let detail: ControlRoomLending.Detail
    let askFor: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(spacing: CGFloat(Look.Side.rowGap)) {
            Text(Self.words(for: detail))
                .foregroundStyle(theme.textSecondary.color)
            if case .takenBack = detail {
                Button(action: askFor) {
                    Text(String(localized: "Show It Here", comment: "总控台：终端被要回原处以后，右栏上把它再放过来的按钮"))
                        .foregroundStyle(theme.attentionText.color)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: CGFloat(Look.Font.body)))
        .multilineTextAlignment(.center)
        .padding(CGFloat(Look.Space.frameToContent))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One sentence for each way of having no terminal to show. Never
    /// empty: a blank right-hand side reads as something broken.
    static func words(for detail: ControlRoomLending.Detail) -> String {
        switch detail {
        case .nothingSelected:
            return String(localized: "Select a group to see its supervisor.", comment: "总控台：没有选中任何群时右栏的说明")
        case .noSupervisor:
            return String(localized: "This group has no supervisor.", comment: "总控台：选中的群没有总管时右栏的说明")
        case .supervisorGone:
            return String(localized: "The supervisor's terminal is no longer open.", comment: "总控台：总管的终端已经关掉时右栏的说明")
        case .takenBack:
            return String(localized: "The supervisor's terminal is in its own tab.", comment: "总控台：终端被要回原处以后右栏的说明")
        case .terminal:
            return ""
        }
    }
}
