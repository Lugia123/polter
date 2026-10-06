import CoreGraphics
import Foundation

/// The one pixel space the screenshot editor works in, and how the system's
/// coordinates get into it and out again.
///
/// The system places displays in *points*, and two displays side by side can
/// have different numbers of pixels to the point, so their pixels do not
/// share a grid: a point on the boundary is pixel 3024 of one display and
/// pixel 0 of the next. The editor wants whole pixels and one space. So the
/// displays are laid out again here, left to right in the order given with
/// their tops level, each as wide and as tall as it has pixels. Nothing in
/// the editor crosses from one display to another -- a selection is on one
/// display, and so is everything drawn on it -- so where the displays sit
/// relative to each other in this space is nobody's business but this
/// type's.
///
/// What leaves (the sidecar file, an agent's request) is in a display's own
/// pixels with the display's index beside it; `displayLocal` gives that.
struct ShotScreenSpace: Equatable {
    /// A display as the system describes it.
    struct Screen: Equatable {
        /// In the system's global coordinates: points, origin at the top
        /// left of the primary display, y downwards.
        var frame: CGRect
        /// The size of its picture.
        var pixels: Annotation.PixelSize
    }

    /// A window as the system lists it, in the same global coordinates.
    struct WindowFrame: Equatable {
        var id: UInt64
        var frame: CGRect
    }

    let screens: [Screen]
    /// The displays as the editor sees them, in the order given.
    let displays: [ShotEditor.Display]

    init(_ screens: [Screen]) {
        self.screens = screens
        var x = 0
        var displays: [ShotEditor.Display] = []
        for screen in screens {
            let scale = screen.frame.width > 0 ? Double(screen.pixels.w) / Double(screen.frame.width) : 1
            displays.append(.init(rect: PixelRect(x, 0, screen.pixels.w, screen.pixels.h), scale: scale))
            x += screen.pixels.w
        }
        self.displays = displays
    }

    /// The display a global point is on.
    func display(at global: CGPoint) -> Int? {
        screens.firstIndex { $0.frame.contains(global) }
    }

    /// A point in display `index`'s own points (origin at its top left) as a
    /// pixel of the space. The pixel is the one the point falls in, and a
    /// point off the display is brought to its nearest pixel: a drag that
    /// leaves the display is still a drag on it.
    func pixel(ofLocal p: CGPoint, on index: Int) -> PixelPoint {
        let display = displays[index]
        let x = Int((Double(p.x) * display.scale).rounded(.down))
        let y = Int((Double(p.y) * display.scale).rounded(.down))
        return PixelPoint(
            display.rect.x + min(max(x, 0), display.rect.w - 1),
            display.rect.y + min(max(y, 0), display.rect.h - 1))
    }

    /// A global point as a pixel of the space; nil when it is on no display.
    func pixel(ofGlobal p: CGPoint) -> PixelPoint? {
        guard let index = display(at: p) else { return nil }
        let origin = screens[index].frame.origin
        return pixel(ofLocal: CGPoint(x: p.x - origin.x, y: p.y - origin.y), on: index)
    }

    /// A pixel of the space in display `index`'s own points: the pixel's top
    /// left corner.
    func local(_ p: PixelPoint, on index: Int) -> CGPoint {
        let display = displays[index]
        return CGPoint(
            x: Double(p.x - display.rect.x) / display.scale,
            y: Double(p.y - display.rect.y) / display.scale)
    }

    /// A rectangle of the space in display `index`'s own points.
    func local(_ r: PixelRect, on index: Int) -> CGRect {
        let a = local(r.origin, on: index)
        let b = local(PixelPoint(r.right, r.bottom), on: index)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// A rectangle of the space in display `index`'s own pixels, origin at
    /// its top left: what a file or an agent is told.
    func displayLocal(_ r: PixelRect, on index: Int) -> PixelRect {
        r.relative(to: displays[index].rect.origin)
    }

    /// The other way: a rectangle in a display's own pixels, in the space.
    func fromDisplayLocal(_ r: PixelRect, on index: Int) -> PixelRect {
        let origin = displays[index].rect.origin
        return PixelRect(r.x + origin.x, r.y + origin.y, r.w, r.h)
    }

    /// The part of a global rectangle that is on display `index`, in the
    /// space; nil when none of it is. Edges go to the nearest pixel
    /// boundary.
    func pixels(ofGlobal frame: CGRect, on index: Int) -> PixelRect? {
        let screen = screens[index], display = displays[index]
        func edge(_ v: CGFloat, from origin: CGFloat) -> Int {
            Int((Double(v - origin) * display.scale).rounded())
        }
        let rect = PixelRect(
            left: display.rect.x + edge(frame.minX, from: screen.frame.minX),
            top: display.rect.y + edge(frame.minY, from: screen.frame.minY),
            right: display.rect.x + edge(frame.maxX, from: screen.frame.minX),
            bottom: display.rect.y + edge(frame.maxY, from: screen.frame.minY))
        guard !rect.isEmpty else { return nil }
        return rect.intersect(display.rect)
    }

    /// The windows as the editor wants them: topmost first, as given. A
    /// window lying across two displays is listed once for each, as the
    /// part of it on that display, under the same id -- on each display it
    /// is that display's part that can be selected.
    func windows(_ list: [WindowFrame]) -> [ShotEditor.Window] {
        list.flatMap { window in
            screens.indices.compactMap { index in
                pixels(ofGlobal: window.frame, on: index).map { ShotEditor.Window(id: window.id, rect: $0) }
            }
        }
    }
}
