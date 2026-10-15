import AppKit
import QuartzCore

/// The selected window tab's piece of glass slides to the tab that was
/// just selected, instead of being there at once (`control-room.md`, 3.5
/// item 4).
///
/// **The tab bar is the system's, and so is the glass.** On macOS 26 every
/// tab button holds a glass view, and the selected one's has the glass
/// drawn in it; selecting another tab empties the one and fills the other
/// in the same turn, with no motion. All this does is play that filled
/// piece in from where the old one was: one animation on its layer, which
/// goes away by itself when it ends. Nothing is added to the tab bar,
/// nothing in it is hidden and no value of it is changed, so a tab bar
/// this cannot make sense of is simply the system's own, as before -- and
/// so is every tab bar on a system older than 26, where there is no such
/// piece to move.
///
/// What bends under the glass's edge as it passes over the other titles is
/// the system's glass doing what it does; nothing here moves a pixel.
///
/// The numbers are the group list's (`ControlRoomChipSlide`): one spring,
/// one lift.
enum WindowTabChipSlide {
    /// The tab each tab group showed last, so that the next one knows where
    /// the glass comes from. Weak both ways: it keeps nothing alive.
    private static let shown = NSMapTable<NSWindowTabGroup, NSWindow>.weakToWeakObjects()

    static let animationKey = "polter.window-tab-chip-slide"

    /// A pane is being dragged (`TabStripDragOverlay`): a tab brought
    /// forward under it shows its glass at once. Played while the drag's
    /// tracking loop runs, the slide stopped half way and stayed there,
    /// stretched across two tabs, until the drag ended (task 1557, t57-02d).
    static var held = false

    /// `window` is now the tab in front. Slides the glass in from the tab
    /// that was, when there was another and it is still in the bar.
    static func selected(_ window: NSWindow) {
        guard let group = window.tabGroup else { return }
        let previous = shown.object(forKey: group)
        shown.setObject(window, forKey: group)
        guard let previous, previous !== window, !held else { return }

        // The bar may not have been handed to this window yet when it is
        // told it is in front; then the next turn of the main queue has it.
        if !slide(in: window, group: group, from: previous) {
            DispatchQueue.main.async { [weak window, weak group, weak previous] in
                guard let window, let group, let previous, group.selectedWindow === window else { return }
                _ = slide(in: window, group: group, from: previous)
            }
        }
    }

    /// False when the bar is not there to be found yet.
    private static func slide(in window: NSWindow, group: NSWindowTabGroup, from previous: NSWindow) -> Bool {
        let buttons = window.tabButtonsInVisualOrder()
        let windows = group.windows
        guard buttons.count == windows.count,
              let to = windows.firstIndex(of: window) else { return false }
        // A tab that was closed or dragged away is nowhere to slide from.
        guard let from = windows.firstIndex(of: previous) else { return true }
        guard let glass = glassLayer(of: buttons[to]) else { return false }

        let plan = ControlRoomChipSlide.plan(
            from: buttons[from].frame, to: buttons[to].frame,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard case let .slide(dx, _) = plan else { return true }

        let samples = ControlRoomChipSlide.samples(
            dx: dx, dy: 0, liftScale: ControlRoomLook.Selection.liftScaleWindowTab)
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = samples.map { NSValue(caTransform3D: transform($0, of: glass)) }
        animation.duration = ControlRoomChipSlide.duration
        animation.calculationMode = .linear
        glass.add(animation, forKey: animationKey)
        return true
    }

    /// The layer the selected tab's glass is drawn in; nil when this button
    /// has none, which is every button but the selected one, and every
    /// button before macOS 26.
    ///
    /// A tab button's glass view holds two views: the one with the title in
    /// it, and one with no views of its own that the glass is drawn into.
    /// It is the second, and only the selected tab's has anything in it.
    private static func glassLayer(of button: NSView) -> CALayer? {
        guard #available(macOS 26.0, *) else { return nil }
        guard let glass = button.subviews.first(where: { $0 is NSGlassEffectView }) else { return nil }
        return glass.subviews
            .first { $0.subviews.isEmpty && !($0.layer?.sublayers ?? []).isEmpty }?
            .layer
    }

    /// A sample as a transform of `layer`, stretched about its middle
    /// wherever its anchor is.
    private static func transform(_ sample: ControlRoomChipSlide.Sample, of layer: CALayer) -> CATransform3D {
        let cx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let cy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var t = CATransform3DMakeTranslation(CGFloat(sample.dx) + cx, cy, 0)
        t = CATransform3DScale(t, CGFloat(sample.along), CGFloat(sample.across), 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }
}
