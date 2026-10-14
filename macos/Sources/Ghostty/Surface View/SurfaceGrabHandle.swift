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

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        private var handleVisible: Bool {
            surfaceView.dragGrip(dragHandle, titled: paneHasTitle, lent: false) == .handle
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

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        var body: some View {
            if surfaceView.dragGrip(dragHandle, titled: true, lent: lent) == .title {
                SurfaceDragSource(
                    surfaceView: surfaceView,
                    isDragging: $isDragging,
                    isHovering: $isHovering,
                    dragThreshold: SurfaceDragGrip.titleDragThreshold,
                    onClick: {
                        surfaceView.window?.makeFirstResponder(surfaceView)
                    }
                )
                .contentShape(Rectangle())
            }
        }
    }
}

extension Ghostty.SurfaceView {
    /// `SurfaceDragGrip.place` for this surface as it is now: whether its
    /// window is fullscreen and its tab split are read off the window.
    func dragGrip(_ setting: Ghostty.Config.DragHandle, titled: Bool, lent: Bool) -> SurfaceDragGrip.Place {
        let fullscreen = window?.styleMask.contains(.fullScreen) ?? false
        let split = (window?.windowController as? BaseTerminalController)?.surfaceTree.isSplit ?? false
        let setting: SurfaceDragGrip.Setting = switch setting {
        case .always: .always
        case .auto: .auto
        case .never: .never
        }
        return SurfaceDragGrip.place(setting: setting, titled: titled, lent: lent, fullscreen: fullscreen, split: split)
    }
}
