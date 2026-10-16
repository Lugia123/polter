import AppKit
import SwiftUI

extension Ghostty {
    /// A preference key that propagates the ID of the SurfaceView currently being dragged,
    /// or nil if no surface is being dragged.
    struct DraggingSurfaceKey: PreferenceKey {
        static var defaultValue: SurfaceView.ID?

        static func reduce(value: inout SurfaceView.ID?, nextValue: () -> SurfaceView.ID?) {
            value = nextValue() ?? value
        }
    }

    /// A SwiftUI view that provides drag source functionality for terminal surfaces.
    ///
    /// This view wraps an AppKit-based drag source to enable drag-and-drop reordering
    /// of terminal surfaces within split views. When the user drags this view, it initiates
    /// an `NSDraggingSession` with the surface's UUID encoded in the pasteboard, allowing
    /// drop targets to identify which surface is being moved.
    ///
    /// The view also publishes the dragging state via `DraggingSurfaceKey` preference,
    /// enabling parent views to react to ongoing drag operations.
    struct SurfaceDragSource: View {
        /// The surface view that will be dragged.
        let surfaceView: SurfaceView

        /// Binding that reflects whether a drag session is currently active.
        @Binding var isDragging: Bool

        /// Binding that reflects whether the mouse is hovering over this view.
        @Binding var isHovering: Bool

        /// How far the pointer has to move while held down before a drag
        /// starts. Zero starts it on the first movement, as the grab handle
        /// always has; a pane's title has a threshold so that it can be clicked.
        var dragThreshold: CGFloat = 0

        /// Called when the pointer goes up again without having started a drag.
        var onClick: (() -> Void)?

        /// Whether it drags at all. False is a title that is only clicked
        /// (`SurfaceDragGrip.TitleGrip.click`): no drag, and no open hand
        /// over it to suggest one.
        var canDrag: Bool = true

        /// The menu a right-click opens on it (task 1582); nil for none.
        var menu: (() -> NSMenu?)?

        /// A button laid over its leading end, whose column keeps the arrow
        /// instead of the hand (tasks 1634, 1642); nil for none.
        var leadingButton: SurfaceDragGrip.LeadingButton?

        var body: some View {
            SurfaceDragSourceViewRepresentable(
                surfaceView: surfaceView,
                isDragging: $isDragging,
                isHovering: $isHovering,
                dragThreshold: dragThreshold,
                onClick: onClick,
                canDrag: canDrag,
                menu: menu,
                leadingButton: leadingButton)
            .preference(key: DraggingSurfaceKey.self, value: isDragging ? surfaceView.id : nil)
        }
    }

    /// An NSViewRepresentable that provides AppKit-based drag source functionality.
    /// This gives us control over the drag lifecycle, particularly detecting drag start.
    fileprivate struct SurfaceDragSourceViewRepresentable: NSViewRepresentable {
        let surfaceView: SurfaceView
        @Binding var isDragging: Bool
        @Binding var isHovering: Bool
        let dragThreshold: CGFloat
        let onClick: (() -> Void)?
        let canDrag: Bool
        let menu: (() -> NSMenu?)?
        let leadingButton: SurfaceDragGrip.LeadingButton?

        func makeNSView(context: Context) -> SurfaceDragSourceView {
            let view = SurfaceDragSourceView()
            view.surfaceView = surfaceView
            view.dragThreshold = dragThreshold
            view.onClick = onClick
            view.canDrag = canDrag
            view.leadingButton = leadingButton
            view.menuProvider = menu
            view.onDragStateChanged = { dragging in
                isDragging = dragging
            }
            view.onHoverChanged = { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            return view
        }

        func updateNSView(_ nsView: SurfaceDragSourceView, context: Context) {
            nsView.surfaceView = surfaceView
            nsView.dragThreshold = dragThreshold
            nsView.onClick = onClick
            if nsView.canDrag != canDrag || nsView.leadingButton != leadingButton {
                nsView.canDrag = canDrag
                nsView.leadingButton = leadingButton
                nsView.window?.invalidateCursorRects(for: nsView)
            }
            nsView.menuProvider = menu
            nsView.onDragStateChanged = { dragging in
                isDragging = dragging
            }
            nsView.onHoverChanged = { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
    }

    /// The underlying NSView that handles drag operations.
    ///
    /// This view manages mouse tracking and drag initiation for surface reordering.
    /// It uses a local event loop to detect drag gestures and initiates an
    /// `NSDraggingSession` when the user drags beyond the threshold distance.
    fileprivate class SurfaceDragSourceView: NSView, NSDraggingSource {
        /// Scale factor applied to the surface snapshot for the drag preview image.
        private static let previewScale: CGFloat = 0.2

        /// The surface view that will be dragged. Its UUID is encoded into the
        /// pasteboard for drop targets to identify which surface is being moved.
        var surfaceView: SurfaceView?

        /// Callback invoked when the drag state changes. Called with `true` when
        /// a drag session begins, and `false` when it ends (completed or cancelled).
        var onDragStateChanged: ((Bool) -> Void)?

        /// Callback invoked when the mouse enters or exits this view's bounds.
        /// Used to update the hover state for visual feedback in the parent view.
        var onHoverChanged: ((Bool) -> Void)?

        /// See `SurfaceDragSource.dragThreshold`.
        var dragThreshold: CGFloat = 0

        /// See `SurfaceDragSource.onClick`.
        var onClick: (() -> Void)?

        /// See `SurfaceDragSource.canDrag`.
        var canDrag: Bool = true

        /// See `SurfaceDragSource.leadingButton`.
        var leadingButton: SurfaceDragGrip.LeadingButton?

        /// See `SurfaceDragSource.menu`.
        var menuProvider: (() -> NSMenu?)?

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?() ?? super.menu(for: event)
        }

        /// Where the pointer went down, in window coordinates; nil when it is up.
        private var mouseDownLocation: NSPoint?

        /// Whether we are currently in a mouse tracking loop (between mouseDown
        /// and either mouseUp or drag initiation). Used to determine cursor state.
        private var isTracking: Bool = false

        /// Local event monitor to detect escape key presses during drag.
        private var escapeMonitor: Any?

        /// Whether the current drag was cancelled by pressing escape.
        private var dragCancelledByEscape: Bool = false

        deinit {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            // Ensure this view gets the mouse event before window dragging handlers
            return true
        }

        override func mouseDown(with event: NSEvent) {
            // Consume the mouseDown event to prevent it from propagating to the
            // window's drag handler. This fixes issue #10110 where grab handles
            // would drag the window instead of initiating pane drags.
            // Don't call super - the drag will be initiated in mouseDragged.
            mouseDownLocation = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            // A drag session takes the mouse-up for itself, so reaching here
            // means the pointer never went far enough: it was a click.
            // The grab handle has no click and passes the mouse-up on, as it
            // did before it could be clicked.
            let wasDown = mouseDownLocation != nil
            mouseDownLocation = nil
            guard let onClick else {
                super.mouseUp(with: event)
                return
            }
            if wasDown { onClick() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // Add our tracking area for mouse events
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }

        override func resetCursorRects() {
            guard canDrag else { return }
            // Not over the button on its end (task 1634): `cursorAreas`.
            let areas = SurfaceDragGrip.cursorAreas(in: bounds, button: leadingButton)
            if !areas.hand.isEmpty {
                addCursorRect(areas.hand, cursor: isTracking ? .closedHand : .openHand)
            }
            if let arrow = areas.arrow, !arrow.isEmpty {
                addCursorRect(arrow, cursor: .arrow)
            }
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseDragged(with event: NSEvent) {
            guard canDrag, !isTracking, let surfaceView = surfaceView else { return }
            guard SurfaceDragGrip.isDrag(
                from: mouseDownLocation ?? event.locationInWindow,
                to: event.locationInWindow,
                threshold: dragThreshold) else { return }

            // Create our dragging item from our transferable
            guard let pasteboardItem = surfaceView.pasteboardItem() else { return }
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

            // Create a scaled preview image from the surface snapshot
            if let snapshot = surfaceView.asImage {
                let imageSize = NSSize(
                    width: snapshot.size.width * Self.previewScale,
                    height: snapshot.size.height * Self.previewScale
                )
                let scaledImage = NSImage(size: imageSize)
                scaledImage.lockFocus()
                snapshot.draw(
                    in: NSRect(origin: .zero, size: imageSize),
                    from: NSRect(origin: .zero, size: snapshot.size),
                    operation: .copy,
                    fraction: 1.0
                )
                scaledImage.unlockFocus()

                // Position the drag image so the mouse is at the center of the image.
                // I personally like the top middle or top left corner best but
                // this matches macOS native tab dragging behavior (at least, as of
                // macOS 26.2 on Dec 29, 2025).
                let mouseLocation = convert(event.locationInWindow, from: nil)
                let origin = NSPoint(
                    x: mouseLocation.x - imageSize.width / 2,
                    y: mouseLocation.y - imageSize.height / 2
                )
                item.setDraggingFrame(
                    NSRect(origin: origin, size: imageSize),
                    contents: scaledImage
                )
            }

            mouseDownLocation = nil
            onDragStateChanged?(true)
            let session = beginDraggingSession(with: [item], event: event, source: self)

            // We need to disable this so that endedAt happens immediately for our
            // drags outside of any targets.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        // MARK: NSDraggingSource

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            return context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint
        ) {
            isTracking = true

            // Reset our escape tracking
            dragCancelledByEscape = false
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Escape key
                    self?.dragCancelledByEscape = true
                    TabStripDragOverlay.shared.clear()
                }
                return event
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            movedTo screenPoint: NSPoint
        ) {
            NSCursor.closedHand.set()
            guard !dragCancelledByEscape, let surfaceView else { return }
            TabStripDragOverlay.shared.moved(to: screenPoint, surface: surfaceView)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }

            // **Esc does not always reach the monitor above**: the drag's
            // own tracking loop can take it and end the session first, and
            // then this is called with the flag still down (task 1557,
            // t57-03d: a pane was made a tab after Esc). A session that ends
            // while the button is still held was not let go, so it was
            // cancelled.
            if NSEvent.pressedMouseButtons & 1 != 0 {
                dragCancelledByEscape = true
            }

            // Let go in a gap of a tab strip: a tab of its own there (task
            // 1557). The strip is the system's and takes no drop, so it is
            // asked here, whatever the operation says.
            if let surfaceView,
               let gap = TabStripDragOverlay.shared.ended(at: screenPoint, surface: surfaceView, cancelled: dragCancelledByEscape) {
                NotificationCenter.default.post(
                    name: .ghosttySurfaceDragEndedOnTabStrip,
                    object: surfaceView,
                    userInfo: [
                        Foundation.Notification.Name.ghosttySurfaceDragEndedOnTabStripNeighborKey: gap.neighbor,
                        Foundation.Notification.Name.ghosttySurfaceDragEndedOnTabStripOrderedKey: gap.ordered.rawValue,
                    ]
                )
            } else if operation == [] && !dragCancelledByEscape {
                let endsInWindow = NSApplication.shared.windows.contains { window in
                    window.isVisible && window.frame.contains(screenPoint)
                }
                if !endsInWindow {
                    NotificationCenter.default.post(
                        name: .ghosttySurfaceDragEndedNoTarget,
                        object: surfaceView,
                        userInfo: [Foundation.Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey: screenPoint]
                    )
                }
            }

            isTracking = false
            onDragStateChanged?(false)
        }
    }
}

extension Notification.Name {
    /// Posted when a surface drag session ends with no operation (the drag was
    /// released outside a valid drop target) and was not cancelled by the user
    /// pressing escape. The notification's object is the SurfaceView that was dragged.
    static let ghosttySurfaceDragEndedNoTarget = Notification.Name("ghosttySurfaceDragEndedNoTarget")

    /// Key for the screen point where the drag ended in the userInfo dictionary.
    static let ghosttySurfaceDragEndedNoTargetPointKey = "endedAtPoint"

    /// Posted when a surface drag ends in a gap of a tab strip (task 1557):
    /// the surface becomes a tab of its own there. The object is the
    /// SurfaceView; the userInfo names the tab's window to go beside and
    /// the side (`NSWindow.OrderingMode` raw value: below is before it).
    static let ghosttySurfaceDragEndedOnTabStrip = Notification.Name("ghosttySurfaceDragEndedOnTabStrip")
    static let ghosttySurfaceDragEndedOnTabStripNeighborKey = "neighbor"
    static let ghosttySurfaceDragEndedOnTabStripOrderedKey = "ordered"
}
