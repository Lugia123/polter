import CoreGraphics
import Foundation

/// The split view's arithmetic, in one place, where a test can read it.
///
/// Everything here was `private` in `SplitView.swift` and nothing could ask
/// it a question. That is how a drag that "stopped working" has no reading:
/// the seam, the two rectangles and the box the divider is grabbed by are all
/// worked out by code no test could call. This file is that code moved out
/// **unchanged** -- same expressions, same order, same rounding -- so that the
/// three invariants the divider depends on can be held:
///
///  1. `splitterPoint` sits exactly on the seam between the two rectangles;
///  2. the right rectangle ends at the split view's far edge, so the two of
///     them and the divider account for the whole width (or height);
///  3. the box the divider is grabbed by is `visibleSize + invisibleSize`
///     wide, centred on the seam -- the region `Divider` makes hit-testable.
///
/// **Nothing in here is new arithmetic.** A number that moved while this was
/// extracted would be a change to where the divider is, made in a commit that
/// claims only to move code.
enum SplitViewLayout {
    /// How wide the divider is **seen**: the line `Divider` fills.
    /// `SplitView.splitterVisibleSize`.
    static let visibleSize: CGFloat = 1
    /// How much wider than the line the divider can be **grabbed**: the
    /// transparent box round it. `SplitView.splitterInvisibleSize`.
    static let invisibleSize: CGFloat = 6

    /// The width a divider is `size` across may be grabbed in, centred on
    /// `seam`: `visibleSize + invisibleSize`, half either side.
    static func grabBox(seam: CGFloat) -> ClosedRange<CGFloat> {
        let half = (visibleSize + invisibleSize) / 2
        return (seam - half)...(seam + half)
    }

    /// Where the divider was dragged to, as the fraction `SplitView.split`
    /// holds: the pointer's position along the axis, held `minSize` clear of
    /// both ends, over the size.
    static func dragged(direction: SplitViewDirection, size: CGSize, location: CGPoint, minSize: CGFloat) -> CGFloat {
        switch direction {
        case .horizontal:
            let new = min(max(minSize, location.x), size.width - minSize)
            return new / size.width

        case .vertical:
            let new = min(max(minSize, location.y), size.height - minSize)
            return new / size.height
        }
    }

    /// The bounding rect for the left (or, vertically, top) view.
    static func leftRect(direction: SplitViewDirection, split: CGFloat, size: CGSize, increments: NSSize) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            result.size.width *= split
            result.size.width -= visibleSize / 2
            result.size.width -= result.size.width.truncatingRemainder(dividingBy: increments.width)

        case .vertical:
            result.size.height *= split
            result.size.height -= visibleSize / 2
            result.size.height -= result.size.height.truncatingRemainder(dividingBy: increments.height)
        }

        return result
    }

    /// The bounding rect for the right (or, vertically, bottom) view.
    static func rightRect(direction: SplitViewDirection, split: CGFloat, size: CGSize, leftRect: CGRect, increments: NSSize) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            // For horizontal layouts we offset the starting X by the left rect
            // and make the width fit the remaining space.
            result.origin.x += leftRect.size.width
            result.origin.x += visibleSize / 2
            result.size.width -= result.origin.x

        case .vertical:
            result.origin.y += leftRect.size.height
            result.origin.y += visibleSize / 2
            result.size.height -= result.origin.y
        }

        return result
    }

    /// The point at which the splitter should be rendered.
    static func splitterPoint(direction: SplitViewDirection, size: CGSize, leftRect: CGRect) -> CGPoint {
        switch direction {
        case .horizontal:
            return CGPoint(x: leftRect.size.width, y: size.height / 2)

        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.size.height)
        }
    }
}

/// Which way a split divides its space. **Here, not with `SplitView`**, so
/// that the rules above can be compiled and asked without the view: it was
/// the only thing in `SplitView.swift` the arithmetic needed.
enum SplitViewDirection: Codable {
    case horizontal, vertical
}
