import SwiftUI

/// A split view shows a left and right (or top and bottom) view with a divider in the middle to do resizing.
/// The terminlogy "left" and "right" is always used but for vertical splits "left" is "top" and "right" is "bottom".
///
/// This view is purpose built for our use case and I imagine we'll continue to make it more configurable
/// as time goes on. For example, the splitter divider size and styling is all hardcoded.
struct SplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection

    /// Divider color
    let dividerColor: Color

    /// Minimum increment (in points) that this split can be resized by, in
    /// each direction. Both `height` and `width` should be whole numbers
    /// greater than or equal to 1.0
    let resizeIncrements: NSSize

    /// The left and right views to render.
    let left: L
    let right: R

    /// Called when the divider is double-tapped to equalize splits.
    let onEqualize: () -> Void

    /// The minimum size (in points) of a split
    let minSize: CGFloat = 10

    /// The current fractional width of the split view. 0.5 means L/R are equally sized, for example.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points. The invisible size is a transparent hitbox that can still
    /// be used for getting a resize handle. The total width/height of the splitter is the sum of both.
    ///
    /// **The arithmetic they feed is `SplitViewLayout`'s**, not this view's: the
    /// two rectangles, the seam and the box the divider is grabbed by are one
    /// rule, in one place, with a test that reads it (`SplitViewDragTests`).
    /// Before that these were four `private` members nobody could ask, so a
    /// change to any of them moved the divider's hit region with nothing able
    /// to go red.
    private let splitterVisibleSize: CGFloat = SplitViewLayout.visibleSize
    private let splitterInvisibleSize: CGFloat = SplitViewLayout.invisibleSize

    var body: some View {
        GeometryReader { geo in
            let leftRect = SplitViewLayout.leftRect(direction: direction, split: split, size: geo.size,
                                                    increments: resizeIncrements)
            let rightRect = SplitViewLayout.rightRect(direction: direction, split: split, size: geo.size,
                                                      leftRect: leftRect, increments: resizeIncrements)
            let splitterPoint = SplitViewLayout.splitterPoint(direction: direction, size: geo.size, leftRect: leftRect)

            ZStack(alignment: .topLeading) {
                left
                    .frame(width: leftRect.size.width, height: leftRect.size.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(leftPaneLabel)
                right
                    .frame(width: rightRect.size.width, height: rightRect.size.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rightPaneLabel)
                Divider(direction: direction,
                        visibleSize: splitterVisibleSize,
                        invisibleSize: splitterInvisibleSize,
                        color: dividerColor,
                        split: split)
                    // Here, not in `Divider`, so the divider holds no binding
                    // (#45). This closure captures the split view instead.
                    .accessibilityAdjustableAction { direction in
                        let adjustment: CGFloat = 0.025
                        switch direction {
                        case .increment:
                            split = min(split + adjustment, 0.9)
                        case .decrement:
                            split = max(split - adjustment, 0.1)
                        @unknown default:
                            break
                        }
                    }
                    .position(splitterPoint)
                    .gesture(dragGesture(geo.size, splitterPoint: splitterPoint))
                    .onTapGesture(count: 2) {
                        onEqualize()
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
        }
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.resizeIncrements = resizeIncrements
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    /// Where the divider was dragged to, as `split`: the pointer's position
    /// along the split's axis, held `minSize` clear of both ends. The rule is
    /// `SplitViewLayout.dragged`, with a test that reads it.
    private func dragGesture(_ size: CGSize, splitterPoint: CGPoint) -> some Gesture {
        return DragGesture()
            .onChanged { gesture in
                split = SplitViewLayout.dragged(direction: direction, size: size, location: gesture.location,
                                                minSize: minSize)
            }
    }

    // MARK: Accessibility

    private var splitViewLabel: String {
        switch direction {
        case .horizontal:
            return "Horizontal split view"
        case .vertical:
            return "Vertical split view"
        }
    }

    private var leftPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Left pane"
        case .vertical:
            return "Top pane"
        }
    }

    private var rightPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Right pane"
        case .vertical:
            return "Bottom pane"
        }
    }
}
