import SwiftUI

/// The control room's tab: the group list on the left, and on the right the
/// selected group's supervisor -- its terminal, or a sentence saying why
/// there is none.
struct ControlRoomView: View {
    typealias Look = ControlRoomLook

    @ObservedObject var model: ControlRoomModel
    let detail: ControlRoomDetailContainer

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let edge = CGFloat(Look.Space.windowEdge)
        let bar = ControlRoomList.detailBar(
            row: model.selectedRow, selection: model.selection,
            holdsTerminal: model.detail.terminal != nil && !model.overallInFront, title: model.supervisorTitle)
        HStack(spacing: CGFloat(Look.Space.betweenFrames)) {
            if let list = model.list {
                ControlRoomListView(
                    list: list,
                    selection: Binding(get: { model.selection }, set: { model.choose($0) }),
                    onNewGroup: { model.newGroup(named: $0) },
                    onRetentionAgree: { model.agreeToRetention() },
                    onInSight: { model.onCardsInSight($0) },
                    onEnter: { model.goToSupervisor() },
                    onFix: { model.fix($0) },
                    fixRefusal: model.fixRefusal,
                    menu: { model.menu(for: $0) },
                    renaming: model.renaming,
                    onRenameTyped: { model.renameTyped($0) },
                    onRenameSubmit: { model.submitRename() },
                    onRenameCancel: { model.cancelRename() },
                    rowLines: model.rowLines,
                    archivedOpen: model.archivedOpen,
                    onToggleArchived: { model.archivedOpen.toggle() },
                    archivedMenu: { model.menu(forArchived: $0) },
                    // The left panel's bottom line (task 2149): nil until the
                    // controller has the core, and then the panel has none.
                    overallAsk: model.overallAsk,
                    // A press opens the overall view; a second press, when it
                    // is already in front, comes back to the group.
                    overallInFront: model.overallInFront,
                    onOverall: { model.overallInFront ? model.leaveOverall() : model.showOverall() })
            } else {
                // No snapshot yet: the list's place, with nothing in it.
                Color.clear.frame(width: CGFloat(Look.Side.width))
            }
            // The supervisor's frame, whatever is in it: the terminal, or
            // a sentence saying why there is none.
            // The page in front for the selected group (task 2015); nil with
            // no pages, and then the right side is as it was.
            let page = model.pageInFront
            let onSupervisorPage = page?.showsTerminal ?? true
            ControlRoomSupervisorFrame(
                title: bar.title,
                caption: bar.caption,
                focused: model.detailHasKeyboard,
                // **The overall view has no tabs**: it is not a page of a
                // group, so the strip over the right side is not drawn while
                // it is in front (task 2149, slice 2).
                pages: model.overallInFront ? nil : page.map {
                    PaneFramePages(current: $0, level: model.selectedLevel, select: { model.show($0) })
                }
            ) {
                VStack(spacing: 0) {
                // The group's project, under the title bar and over the
                // terminal (task 1713): beside the `ZStack`, never round
                // it, so the terminal's holder is the same view with or
                // without it.
                //
                // **And never while the whole of Polter is in front** (task
                // 2149, slice 2, the reviewer's second must-fix): this bar
                // draws over the page's top, which is where the overall
                // view's first figure is.
                if model.groupSideDrawn(onSupervisorPage), let group = model.selection, model.detail.terminal != nil, let facts = model.selectedRow?.facts {
                    ProjectLinkStrip(
                        group: group, tie: facts.projectTie, why: facts.projectWhy, hands: model.projectHands,
                        tell: { model.say($0, under: group, delivered: false) })
                }
                ZStack {
                    // Always there, so the terminal's view is never rebuilt by
                    // a redraw of this one -- and on another page hidden, not
                    // taken out (task 2015).
                    DetailHost(container: detail, hidden: !model.groupSideDrawn(onSupervisorPage))
                    // **And not while the whole of Polter is in front** (task
                    // 2149, slice 2, the reviewer's second must-fix): with no
                    // terminal this sentence and its button were drawn under
                    // the overall view's pane, visible and clickable, for as
                    // long as that pane had no reading to cover them with.
                    if model.groupSideDrawn(onSupervisorPage), model.detail.terminal == nil {
                        ControlRoomDetailMessage(
                            detail: model.detail,
                            askFor: model.askForTerminal,
                            start: model.selectedRow?.start,
                            roles: model.list?.supervisorRoles ?? [],
                            chooseRole: model.list?.chooseSupervisorRole ?? false,
                            refusal: model.startRefusal.flatMap { $0.group == model.selection ? $0.message : nil },
                            alone: model.selectedRow?.alone != nil,
                            lastFrame: model.lastFrame(for: model.detail),
                            onStart: { role, cwd, session, cli in
                                guard let group = model.selection else { return }
                                model.startSupervisor(for: group, role: role, cwd: cwd, session: session, cli: cli)
                            },
                            goToTerminal: model.goToTerminal)
                    }
                    // **The whole of Polter, over everything** (task 2149,
                    // slice 2): the selected group's pages are left as they
                    // were, and coming back puts that group on the page it
                    // was on.
                    if model.overallInFront {
                        ControlRoomOverallPane(ask: model.overallAsk)
                    }
                    // Another page in front, over the hidden terminal.
                    else if let page, !page.showsTerminal {
                        ControlRoomPageBody(page: page, model: model)
                    }
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.paneFrameTakeOver, { question in
                guard let group = model.selection else { return }
                model.takeOver(group: group, question: question)
            })
            // The group's note, docked at the right while it is edited
            // (task 1660, design v21 `04-B`): the supervisor's frame gives
            // it its width and the gap between frames, and keeps its title.
            if let note = model.noteEditing {
                ControlRoomNotePanel(
                    group: note.group,
                    saved: note.saved,
                    text: Binding(get: { model.noteEditing?.draft ?? "" },
                                  set: { model.noteEditing?.draft = $0 }),
                    refusal: note.refusal,
                    onSave: { model.saveNote() },
                    onClose: { model.closeNote() })
                    // A panel for another group starts afresh.
                    .id(note.group)
            }
        }
        .padding(edge)
        .background(Look.theme(scheme).windowBase.color)
    }

    /// The AppKit container, as it is: SwiftUI only gives it room.
    private struct DetailHost: NSViewRepresentable {
        let container: ControlRoomDetailContainer
        /// Another page is in front: the terminal stays lent and in its
        /// holder, out of sight.
        var hidden = false

        func makeNSView(context: Context) -> ControlRoomDetailContainer { container }
        func updateNSView(_ view: ControlRoomDetailContainer, context: Context) {
            if view.isHidden != hidden { view.isHidden = hidden }
        }
    }
}
