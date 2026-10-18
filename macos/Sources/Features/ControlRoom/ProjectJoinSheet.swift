import AppKit
import SwiftUI

/// "There is already a project X. Add the supervisor's tab to it?" (task
/// 1713, v2 B1): a sheet of its own rather than an `NSAlert`, whose body is
/// set below the menu's size and which stacks four buttons on top of each
/// other.
///
/// Return is "Join and Link"; **Escape is "Later", bound here**: an
/// `NSAlert` binds it only to a button titled "Cancel" in English. "This
/// Group Uses No Project" stands at the left, away from the default.
struct ProjectJoinSheet: View {
    /// The design's sheet (v2 `metrics.json`): its width, the room round
    /// what is in it, the icon, and the gap between buttons.
    enum Grid {
        static let width: CGFloat = 520
        static let pad: CGFloat = 20
        static let icon: CGFloat = 48
        static let gap: CGFloat = 12
    }

    enum Answer: Equatable {
        case join, replace, later, decline
    }

    let question: ProjectLinkPlan.Question
    let group: String
    let blocker: String
    let answer: (Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.gap) {
            HStack(alignment: .top, spacing: Grid.pad) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: Grid.icon, height: Grid.icon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Grid.gap) {
                    Text(question.title)
                        .font(Font(NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.after)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Grid.gap) {
                Button(ProjectLinkPlan.menuTitle(.declineProject, group: group, project: nil)) { answer(.decline) }
                Spacer(minLength: Grid.gap)
                Button(String(localized: "Ask Me Later", comment: "撞名确认框：以后再说（Esc）")) { answer(.later) }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Replace…", comment: "撞名确认框：替换（还会再确认一次）")) { answer(.replace) }
                Button(ProjectLinkPlan.menuTitle(.joinExisting, group: group, project: blocker)) { answer(.join) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Grid.gap)
        }
        .font(Font(NSFont.menuFont(ofSize: 0)))
        .padding(Grid.pad)
        .frame(width: Grid.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}
