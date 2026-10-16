import SwiftUI

extension Ghostty {
    /// A grab handle overlay at the top of the surface for dragging a surface.
    struct SurfaceGrabHandle: View {
        // Size of the actual drag handle; the hover reveal region is larger.
        private static let handleSize = CGSize(width: 80, height: 12)

        // Reveal the handle anywhere within the top % of the pane height.
        private static let hoverHeightFactor: CGFloat = 0.2

        @ObservedObject var surfaceView: SurfaceView
        let dragHandle: Ghostty.Config.DragHandle

        /// A pane with a title is picked up by it, and has no handle (task 1508).
        @Environment(\.paneHasTitle) private var paneHasTitle
        /// The control room's right-hand side drags nothing (task 1566).
        @Environment(\.surfaceInControlRoom) private var inControlRoom
        /// A stacked pane is picked up by its tabs (task 1582).
        @Environment(\.paneHoldsStack) private var paneHoldsStack

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        private var handleVisible: Bool {
            surfaceView.dragGrip(dragHandle, titled: paneHasTitle, lent: false, controlRoom: inControlRoom, stacked: paneHoldsStack) == .handle
        }

        private var ellipsisVisible: Bool {
            switch dragHandle {
            case .always:
                return true
            case .never:
                return false
            case .auto:
                break
            }
            // If the cursor isn't visible, never show the handle
            guard surfaceView.cursorVisible else { return false }
            // If we're hovering or actively dragging, always visible
            if isHovering || isDragging { return true }

            // Require our mouse location to be within the top area of the
            // surface.
            guard let mouseLocation = surfaceView.mouseLocationInSurface else { return false }
            return Self.isInHoverRegion(mouseLocation, in: surfaceView.bounds)
        }

        var body: some View {
            if handleVisible {
                ZStack {
                    SurfaceDragSource(
                        surfaceView: surfaceView,
                        isDragging: $isDragging,
                        isHovering: $isHovering
                    )
                    .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                    .contentShape(Rectangle())

                    if ellipsisVisible {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary.opacity(isHovering ? 0.8 : 0.3))
                            .offset(y: -3)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }

        /// The full-width hover band that reveals the drag handle.
        private static func hoverRect(in bounds: CGRect) -> CGRect {
            guard !bounds.isEmpty else { return .zero }

            let hoverHeight = min(bounds.height, max(handleSize.height, bounds.height * hoverHeightFactor))
            return CGRect(
                x: bounds.minX,
                y: bounds.maxY - hoverHeight,
                width: bounds.width,
                height: hoverHeight
            )
        }

        /// Returns true when the pointer is inside the top hover band.
        private static func isInHoverRegion(_ point: CGPoint, in bounds: CGRect) -> Bool {
            hoverRect(in: bounds).contains(point)
        }
    }
}

extension Ghostty {
    /// What a pane's title is picked up by: laid over the title band of a
    /// framed pane, the band's size (task 1508). It drags exactly what the
    /// handle drags; held and let go without moving, it is a click, and a
    /// click gives the pane's terminal the keyboard.
    struct SurfaceTitleGrip: View {
        @ObservedObject var surfaceView: SurfaceView
        let dragHandle: Ghostty.Config.DragHandle
        /// The terminal is on the control room's right-hand side.
        let lent: Bool
        /// The title's menu: the window tab's, for this pane (task 1582).
        var menu: (() -> NSMenu?)?
        /// Its close button, at the left end (tasks 1634, 1642).
        var leadingButton: SurfaceDragGrip.LeadingButton?

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        var body: some View {
            // `drag-handle` takes the drag away, never the click (task 1514)
            // -- nor the menu (task 1582).
            switch surfaceView.titleGrip(dragHandle, lent: lent) {
            case .drag, .click:
                SurfaceDragSource(
                    surfaceView: surfaceView,
                    isDragging: $isDragging,
                    isHovering: $isHovering,
                    dragThreshold: SurfaceDragGrip.titleDragThreshold,
                    onClick: focus,
                    // Not a hand over a title that will not drag.
                    canDrag: surfaceView.titleGrip(dragHandle, lent: lent) == .drag,
                    menu: menu,
                    leadingButton: leadingButton
                )
                .contentShape(Rectangle())
            case .none:
                EmptyView()
            }
        }

        private func focus() {
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
    }

    /// What a stack's tab is picked up, clicked and right-clicked by (task
    /// 1582): laid behind the tab, the tab's member's own drag source. A
    /// drag takes that terminal wherever a pane's title would; a click
    /// brings it to the front.
    struct PolterStackTabGrip: View {
        @ObservedObject var surfaceView: SurfaceView
        let dragHandle: Ghostty.Config.DragHandle
        let lent: Bool
        let inControlRoom: Bool
        let select: () -> Void
        let menu: () -> NSMenu?
        /// Its close button, at the left end (tasks 1634, 1642).
        var leadingButton: SurfaceDragGrip.LeadingButton?

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        var body: some View {
            let grip = SurfaceDragGrip.stackTabGrip(
                setting: SurfaceView.gripSetting(dragHandle), lent: lent, controlRoom: inControlRoom)
            switch grip {
            case .drag, .click:
                SurfaceDragSource(
                    surfaceView: surfaceView,
                    isDragging: $isDragging,
                    isHovering: $isHovering,
                    dragThreshold: SurfaceDragGrip.titleDragThreshold,
                    onClick: select,
                    canDrag: grip == .drag,
                    menu: menu,
                    leadingButton: leadingButton
                )
                .contentShape(Rectangle())
            case .none:
                Color.clear
            }
        }
    }
}

extension Ghostty.SurfaceView {
    /// `SurfaceDragGrip.place` for this surface as it is now: whether its
    /// tab is split is read off the window.
    func dragGrip(_ setting: Ghostty.Config.DragHandle, titled: Bool, lent: Bool, controlRoom: Bool, stacked: Bool = false) -> SurfaceDragGrip.Place {
        SurfaceDragGrip.place(
            setting: Self.gripSetting(setting), titled: titled, lent: lent, controlRoom: controlRoom, split: gripSplit,
            stacked: stacked)
    }

    /// `SurfaceDragGrip.titleGrip` for this surface as it is now.
    func titleGrip(_ setting: Ghostty.Config.DragHandle, lent: Bool) -> SurfaceDragGrip.TitleGrip {
        SurfaceDragGrip.titleGrip(setting: Self.gripSetting(setting), lent: lent, split: gripSplit)
    }

    /// Whether this surface's tab has more than one pane. A stack is one
    /// pane: its tree's root is a leaf.
    private var gripSplit: Bool {
        (window?.windowController as? BaseTerminalController)?.surfaceTree.isSplit ?? false
    }

    static func gripSetting(_ setting: Ghostty.Config.DragHandle) -> SurfaceDragGrip.Setting {
        switch setting {
        case .always: .always
        case .auto: .auto
        case .never: .never
        }
    }
}
