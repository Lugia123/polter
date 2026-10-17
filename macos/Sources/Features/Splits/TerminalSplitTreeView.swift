import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                action: action)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
            .paneFrameScope(tree)
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @Environment(\.paneFrameGround) private var paneFrameGround

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                dividerColor: paneFrameGround ? .clear : ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false
    /// A drag started inside this pane: the pane itself, or one of its own
    /// stack by its tab. Its middle is then no target (task 1633).
    @State private var isDraggingFromInside: Bool = false

    /// Whether the control room has this pane's terminal just now.
    @ObservedObject private var lender = ControlRoomLender.shared

    /// A window tab being dragged over this pane (`TabIntoPane`).
    @ObservedObject private var tabOffer = TabIntoPaneOffer.shared

    var body: some View {
        GeometryReader { geometry in
            Group {
                if lender.lentID == surfaceView.id {
                    // The view is on the control room's right-hand side;
                    // the pane keeps its place in the tree.
                    ControlRoomLentPlaceholder(surfaceView: surfaceView, lastFrame: lender.frozenAtHome)
                } else {
                    Ghostty.InspectableSurface(
                        surfaceView: surfaceView,
                        isSplit: isSplit)
                }
            }
            .paneFramed(surfaceView)
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            middle: TerminalSplitDropZone.middle(
                                draggedFromInside: isDraggingFromInside,
                                holdsStacks: BaseTerminalController.controller(owning: surfaceView)?.holdsStacks ?? false),
                            action: action
                        ))
                }
            }
            .overlay {
                if !isSelfDragging, case .dropping(let zone) = dropState {
                    zone.overlay(in: geometry)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let offer = tabOffer.offer, offer.pane == surfaceView.id {
                    Group {
                        if let refusal = offer.refusal {
                            TabIntoPaneRefusalView(refusal: refusal)
                        } else {
                            offer.zone.overlay(in: geometry)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            // `terminal_highlight` (task 1689): the lit pane's edge and card,
            // or the scrim over the others in its window. Over the frame's
            // title too, as the design draws it.
            .overlay {
                PolterHighlightPaneOverlay(terminal: ControlRoomLender.terminal(of: surfaceView))
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                isDraggingFromInside = value != nil
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
        }
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
        /// Over the middle of the pane the drag came out of: nothing lit,
        /// and letting go does nothing (task 1633).
        case inert
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        /// What this pane's middle does (task 1633).
        let middle: TerminalSplitDropZone.Middle
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        /// The zone under the pointer, or nil where letting go does nothing.
        private func zone(_ info: DropInfo) -> TerminalSplitDropZone? {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize, middle: middle != .absent)
            return zone == .middle && middle == .inert ? nil : zone
        }

        func dropEntered(info: DropInfo) {
            dropState = zone(info).map { .dropping($0) } ?? .inert
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            switch dropState {
            case .idle: return DropProposal(operation: .forbidden)
            case .dropping, .inert: break
            }
            guard let zone = zone(info) else {
                dropState = .inert
                return DropProposal(operation: .forbidden)
            }
            dropState = .dropping(zone)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            dropState = .idle
            guard let zone = zone(info) else { return false }

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

/// Said on a pane while a window tab that cannot go into it is over it.
private struct TabIntoPaneRefusalView: View {
    typealias Look = ControlRoomLook

    let refusal: TabIntoPane.Refusal

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // In the words and colours of the placeholder a lent pane shows.
        let theme = Look.theme(scheme)
        Text(message)
            .font(.system(size: CGFloat(Look.Font.body)))
            .foregroundStyle(theme.text.color)
            .multilineTextAlignment(.center)
            .padding(CGFloat(Look.Space.frameToContent))
            .background(
                theme.terminalBackground.color,
                in: RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorInner)))
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorInner))
                    .stroke(theme.line.color))
            .padding(CGFloat(Look.Space.frameToContent))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        switch refusal {
        case .lentToControlRoom:
            String(
                localized: "This tab can't go into a pane: one of its terminals is in the Control Room.",
                comment: "把标签拖到分屏上时：标签里有终端借给了总控台，不能并入")
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right
    /// Onto the pane's stack, in front (task 1633): only for a pane being
    /// dragged, and only where `calculate(at:in:middle:)` is asked for it.
    case middle

    /// How far into the pane, as a share of its width and of its height,
    /// each edge's zone reaches when there is a middle: the middle is what
    /// is at least this far from every edge, 40% across and 40% down.
    static let middleEdge: CGFloat = 0.3

    /// `calculate(at:in:)`, with a middle when `middle` is true: a point at
    /// least `middleEdge` from all four edges stacks rather than splits.
    /// Nearer an edge than that it is that edge's zone, as before.
    static func calculate(at point: CGPoint, in size: CGSize, middle: Bool) -> TerminalSplitDropZone {
        if middle {
            let relX = point.x / size.width
            let relY = point.y / size.height
            if min(relX, 1 - relX) >= middleEdge, min(relY, 1 - relY) >= middleEdge { return .middle }
        }
        return calculate(at: point, in: size)
    }

    /// What a drag over a pane's middle does (task 1633). A pane in a
    /// window that keeps stacks has a middle; one dragged from inside it --
    /// the pane itself, or a terminal of its own stack picked up by its tab
    /// -- is already where the middle would put it, so there the middle is
    /// no target: nothing lit, nothing done. It is still the middle, so
    /// the drop does not fall through to the nearest side and split it out.
    enum Middle: Equatable {
        /// No middle: the four sides, as for a tab dragged over a pane.
        case absent
        /// The middle takes it onto the stack.
        case stacks
        /// The middle is there and does nothing.
        case inert
    }

    static func middle(draggedFromInside: Bool, holdsStacks: Bool) -> Middle {
        guard holdsStacks else { return .absent }
        return draggedFromInside ? .inert : .stacks
    }

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        case .middle:
            // Where the stack's strip would be: the ghost of the tabs the
            // pane is about to have, in the light the four sides use.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: min(Self.ghostStripHeight, geometry.size.height))
                Spacer()
            }
        }
    }

    /// The height of the strip a stack shows its tabs in.
    static let ghostStripHeight = CGFloat(ControlRoomLook.StackTab.stripHeight)
}

