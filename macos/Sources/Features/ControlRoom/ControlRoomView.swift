import SwiftUI

/// The control room's tab: the group list on the left, and on the right the
/// place the selected group's supervisor will go.
struct ControlRoomView: View {
    typealias Look = ControlRoomLook

    @ObservedObject var model: ControlRoomModel
    let detail: ControlRoomDetailContainer

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let edge = CGFloat(Look.Space.windowEdge)
        HStack(spacing: CGFloat(Look.Space.betweenFrames)) {
            if let list = model.list {
                ControlRoomListView(list: list, selection: $model.selection)
            } else {
                // No snapshot yet: the list's place, with nothing in it.
                Color.clear.frame(width: CGFloat(Look.Side.width))
            }
            DetailHost(container: detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
