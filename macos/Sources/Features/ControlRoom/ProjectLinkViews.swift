import AppKit
import SwiftUI

// What the control room and the supervisor's pane draw of a group's tie to
// a project (task 1713): the line saying one was made (v2 A1), the banner
// for one that was not (v1 01c/01d as v2 D changed them), and the words at
// the right end of a group's row. Every size and colour is
// `ControlRoomLook`'s; the buttons are the system's, in the menu's font,
// which is the smallest anything here is set in.

/// The menu's font: nothing in Polter's own windows is set smaller.
private var menuFont: Font { SafeFace.menu.swiftUI }

/// The line saying a project was made for a group, with its undo and ✕.
/// The same `ProjectHint` is drawn in the control room and in the
/// supervisor's pane; `short` lets it fall back to the short sentence where
/// the long one does not fit on a line.
struct ProjectHintBar: View {
    typealias Look = ControlRoomLook

    @ObservedObject var hint: ProjectHint
    var hints = ProjectHints.shared
    var allowShort = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        let gap = CGFloat(Look.Pane.barGap)
        HStack(spacing: gap) {
            switch hint.state {
            case .shown:
                sentence(hint.text, short: allowShort ? hint.shortText : nil, theme.text.color)
                Button(String(localized: "Undo", comment: "项目提示条：撤销按钮")) { hints.undo(hint.group) }
                    .fixedSize()
            case .undone(let text):
                sentence(text, short: nil, theme.textSecondary.color)
            }
            Button(action: { hints.close(hint.group) }, label: {
                Image(systemName: "xmark")
                    .frame(width: CGFloat(Look.WindowTab.close), height: CGFloat(Look.WindowTab.close))
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary.color)
            .help(String(localized: "Close", comment: "关闭确认框"))
            .accessibilityLabel(String(localized: "Close", comment: "关闭确认框"))
        }
        .font(menuFont)
        .padding(.horizontal, CGFloat(Look.Space.frameToContent))
        .padding(.vertical, gap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRow.color)
        .background(ProjectHintProbe(group: hint.group, hints: hints))
    }

    @ViewBuilder
    private func sentence(_ text: String, short: String?, _ ink: Color) -> some View {
        if let short {
            ViewThatFits(in: .horizontal) {
                Text(text).foregroundStyle(ink).lineLimit(1).fixedSize()
                Text(short).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Where a copy of the line is, for its clock: it counts only while one is
/// where the person can see it (`ProjectHints.seen`).
struct ProjectHintProbe: NSViewRepresentable {
    let group: String
    let hints: ProjectHints

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        hints.register(view, for: group)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        hints.register(view, for: group)
    }
}

/// The banner over the supervisor's terminal while the group's project was
/// not made (§3.4). It stays until that is settled: there is no close
/// button (v1, the user's fifth answer).
struct ProjectLinkBannerView: View {
    typealias Look = ControlRoomLook

    let banner: ProjectLinkPlan.Banner
    let group: String
    weak var hands: ControlRoomProjectHands?
    /// Says why a press was refused.
    var tell: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        let gap = CGFloat(Look.Pane.barGap)
        HStack(alignment: .top, spacing: gap) {
            Image(systemName: Look.Symbol.waiting)
                .resizable()
                .scaledToFit()
                .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                .foregroundStyle(theme.attention.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: gap) {
                Text(text)
                    .foregroundStyle(theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(menuFont)
        .padding(CGFloat(Look.Space.frameToContent))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRow.color)
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        switch banner {
        case .nameTaken(let text, _), .several(let text, _), .notMade(let text, _), .unreadable(let text): return text
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let gap = CGFloat(Look.Pane.barGap)
        switch banner {
        case .nameTaken(_, let blocker):
            // The design's order: what loses nothing first, the way out last.
            HStack(spacing: gap) {
                Button(ProjectLinkPlan.menuTitle(.joinExisting, group: group, project: blocker)) {
                    run { $0.join(group: group, project: blocker) }
                }
                Button(ProjectLinkPlan.menuTitle(.replaceExisting, group: group, project: blocker)) {
                    hands?.replace(group: group, project: blocker)
                }
                Button(String(localized: "Open \"\(blocker)\" First", comment: "总控台右栏横幅：先打开挡路的同名项目看看，参数是项目名")) {
                    hands?.open(project: blocker)
                }
                Button(ProjectLinkPlan.menuTitle(.declineProject, group: group, project: nil)) {
                    run { $0.decline(group: group) }
                }
            }
            .fixedSize()
        case .several(_, let candidates):
            VStack(alignment: .leading, spacing: gap) {
                ForEach(candidates, id: \.name) { p in
                    HStack(spacing: gap) {
                        Text(verbatim: p.name + " · " + ProjectLinkPlan.facts(p))
                        Button(String(localized: "Use It", comment: "总控台右栏横幅：两个项目里选这一个")) {
                            run { $0.link(group: group, project: p.name) }
                        }
                    }
                }
                Button(ProjectLinkPlan.menuTitle(.declineProject, group: group, project: nil)) {
                    run { $0.decline(group: group) }
                }
            }
        case .notMade(_, let saveTab):
            HStack(spacing: gap) {
                if saveTab {
                    Button(String(localized: "Use as This Group's Project", comment: "总控台右栏横幅：把总管的标签页用作这个群的项目")) {
                        run { $0.saveSupervisorTab(group: group) }
                    }
                }
                Button(ProjectLinkPlan.menuTitle(.declineProject, group: group, project: nil)) {
                    run { $0.decline(group: group) }
                }
            }
            .fixedSize()
        case .unreadable:
            // Mending the file is outside Polter, and it is used again by
            // itself once it reads.
            EmptyView()
        }
    }

    private func run(_ act: (ControlRoomProjectHands) -> String?) {
        guard let hands else { return }
        if let refused = act(hands) { tell(refused) }
    }
}

/// The right end of a group's row (§3.4): the project's name in the second
/// ink, or the attention glyph and a short word with the whole sentence on
/// hover; nothing for the rest.
struct ProjectRowNote: View {
    typealias Look = ControlRoomLook

    let note: ProjectLinkRules.Note
    /// The whole sentence, for the tooltip and a screen reader.
    var sentence: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        switch note {
        case .none:
            EmptyView()
        case .name(let name):
            // The part of the row that gives way: cut in the middle when
            // the row is narrow, never drawn over what is beside it.
            Text(name)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
        case .attention(let key):
            HStack(spacing: CGFloat(Look.Side.markGap)) {
                Image(systemName: Look.Symbol.waiting)
                    .resizable()
                    .scaledToFit()
                    .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                    .foregroundStyle(theme.attention.color)
                Text(ProjectLinkPlan.rowWord(key))
                    .foregroundStyle(theme.attentionText.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(sentence ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sentence ?? ProjectLinkPlan.rowWord(key))
        }
    }
}

/// What stands between a supervisor's title bar and its terminal about the
/// group's project: the line saying one was made while it stands, and
/// otherwise the banner while it was not made. Nothing for the rest.
struct ProjectLinkStrip: View {
    let group: String
    let tie: String
    let why: String
    weak var hands: ControlRoomProjectHands?
    /// The supervisor's own pane, which may be narrow: the line may fall
    /// back to its short sentence there.
    var inPane = false
    var tell: (String) -> Void = { _ in }

    @ObservedObject var hints = ProjectHints.shared

    var body: some View {
        if let hint = hints.hint(for: group) {
            ProjectHintBar(hint: hint, hints: hints, allowShort: inPane)
        } else if !inPane, let hands,
                  let banner = ProjectLinkPlan.banner(why: why, tie: tie, group: group, projects: hands.projects(),
                                                      unreadable: hands.unreadableProjectFiles()) {
            ProjectLinkBannerView(banner: banner, group: group, hands: hands, tell: tell)
        }
    }
}

/// The copy of the line in the supervisor's own pane, at the top of what
/// the pane shows; nothing in any other pane.
struct ProjectPaneHint: View {
    let terminal: String?
    @ObservedObject var hints = ProjectHints.shared

    var body: some View {
        if let hint = hints.hint(inPaneOf: terminal) {
            ProjectHintBar(hint: hint, hints: hints, allowShort: true)
        }
    }
}
