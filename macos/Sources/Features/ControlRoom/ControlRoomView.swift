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
            holdsTerminal: model.detail.terminal != nil, title: model.supervisorTitle)
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
                    archivedMenu: { model.menu(forArchived: $0) })
            } else {
                // No snapshot yet: the list's place, with nothing in it.
                Color.clear.frame(width: CGFloat(Look.Side.width))
            }
            // The supervisor's frame, whatever is in it: the terminal, or
            // a sentence saying why there is none.
            ControlRoomSupervisorFrame(
                title: bar.title,
                caption: bar.caption,
                focused: model.detailHasKeyboard
            ) {
                ZStack {
                    // Always there, so the terminal's view is never
                    // rebuilt by a redraw of this one.
                    DetailHost(container: detail)
                    if model.detail.terminal == nil {
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
                            })
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

        func makeNSView(context: Context) -> ControlRoomDetailContainer { container }
        func updateNSView(_ view: ControlRoomDetailContainer, context: Context) {}
    }
}
