import Foundation

/// The overlay's furniture, painted: the glass plates and the toolbar's
/// cells (`dev-docs/poltergeist/screenshot.md`, 9.8.2 to 9.8.6).
///
/// Nothing here knows about windows or about CoreGraphics: a plate and its
/// cells are painted into a `ShotCanvas` from the generated `ShotLook`
/// numbers, and whoever asked draws the canvas wherever it goes. Words --
/// a hover text, a status line -- are drawn over it by the caller, which
/// has the fonts.
enum ShotChrome {
    private typealias Ink = ShotCanvas.Ink
    private typealias Shape = ShotCanvas.Shape

    /// What the system was asked to do for the person looking at it.
    struct Access: Equatable {
        /// Reduce transparency, or increase contrast: the plates are
        /// opaque with a plain edge, and nothing glows.
        var opaque = false
    }

    /// A length of the look in pixels, not rounded: anti-aliasing takes
    /// care of the fraction.
    private static func px(_ points: Double, _ scale: Double) -> Double { points * scale }

    /// A hairline: half a point, and never thinner than one pixel.
    private static func hairline(_ points: Double, _ scale: Double) -> Double { max(points * scale, 1) }

    /// How far a plate's shadow reaches past it, in pixels: left and right,
    /// above, below.
    static func margins(scale: Double) -> (x: Int, top: Int, bottom: Int) {
        let a = ShotLook.Annotation.self
        return (
            Int((a.dirtyShadowX * scale).rounded(.up)), Int((a.dirtyShadowTop * scale).rounded(.up)),
            Int((a.dirtyShadowBottom * scale).rounded(.up)))
    }

    /// A painted piece of furniture and where it goes.
    struct Painted {
        var canvas: ShotCanvas
        /// The display pixel the canvas's top left pixel is drawn at.
        var origin: PixelPoint
    }

    /// Where the glass comes from: a display's prepared pictures, and that
    /// display's top left corner in the space rectangles are given in.
    struct Glass {
        var prepared: ShotBlur.Prepared
        var origin: PixelPoint
        var scale: Double
    }

    /// What furniture is painted on and for whom: the display's scale, its
    /// glass when there is any, and what the system was asked to do.
    struct Surface {
        var scale: Double
        var glass: Glass?
        var access: Access
    }

    // MARK: Plates

    /// Paint a plate into `canvas`: its shadow, the glass, the tint and its
    /// two edges (9.8.6.2). `rect` is the plate in display pixels, `origin`
    /// the display pixel of the canvas's top left.
    static func plate(
        into canvas: inout ShotCanvas, rect: PixelRect, origin: PixelPoint, radius: Double, on surface: Surface
    ) {
        let scale = surface.scale, glass = surface.glass, access = surface.access
        let c = ShotLook.Colour.self
        let shape = Shape(
            x: Double(rect.x - origin.x), y: Double(rect.y - origin.y), w: Double(rect.w), h: Double(rect.h),
            radius: px(radius, scale))
        canvas.shadow(
            of: shape, dy: px(ShotLook.Size.plateShadowDy, scale), sigma: px(ShotLook.Size.plateShadowSigma, scale),
            Ink(c.plateShadow))
        let edge = hairline(ShotLook.Size.plateEdge, scale)
        if access.opaque || glass == nil {
            // No glass: transparency is reduced, or the out-of-focus
            // picture is not there yet. Opaque, with an edge that shows on
            // anything.
            canvas.fill(shape, Ink(c.plateOpaque))
            canvas.strokeInside(shape, thickness: max(px(1, scale), 1), Ink(c.plateOpaqueEdge))
            return
        }
        canvas.strokeOutside(shape, thickness: edge, Ink(c.plateOuterEdge))
        if let glass {
            let local = PixelRect(rect.x - glass.origin.x, rect.y - glass.origin.y, rect.w, rect.h)
            if let under = ShotBlur.plate(from: glass.prepared, scale: glass.scale, rect: local) {
                canvas.fill(shape, with: under, left: rect.x - origin.x, top: rect.y - origin.y)
            }
        }
        canvas.fill(shape, Ink(c.plateTint))
        canvas.strokeInside(shape, thickness: edge, Ink(c.plateInnerEdge))
    }

    /// A canvas big enough for a plate at `rect` and its shadow.
    static func canvas(for rect: PixelRect, scale: Double) -> Painted {
        let m = margins(scale: scale)
        return Painted(
            canvas: ShotCanvas(width: rect.w + 2 * m.x, height: rect.h + m.top + m.bottom),
            origin: PixelPoint(rect.x - m.x, rect.y - m.top))
    }

    // MARK: Cells

    /// What is in a cell.
    enum Content: Equatable {
        /// One of the generated icons, by its key.
        case icon(String)
        /// One of the nine colours.
        case swatch(ShotStyle.RGB)
        /// A dot, this many points across: a step of thickness.
        case dot(Double)
        /// A chequerboard this many squares on a side: a step of mosaic
        /// block.
        case blocks(Int)
    }

    /// What `button` shows. `props` is the property row that is showing,
    /// which is what a step is a step of.
    static func content(of button: ToolbarButton, props: AnnotationTool.Props) -> Content {
        switch button {
        case let .tool(tool): return .icon(tool.name)
        case .undo: return .icon("undo")
        case .redo: return .icon("redo")
        case .long: return .icon("long")
        case .save: return .icon("save")
        case .cancel: return .icon("cancel")
        case .done: return .icon("done")
        case let .colour(c): return .swatch(ShotStyle.colour(c))
        case let .level(level):
            let l = min(max(level, 0), ShotStyle.levels - 1)
            switch props {
            case .font: return .icon(ShotLook.fontIcons[min(l, ShotLook.fontIcons.count - 1)])
            case .block: return .blocks(Int(ShotLook.Levels.mosaicCells[min(l, ShotLook.Levels.mosaicCells.count - 1)]))
            case .stroke, .none: return .dot(ShotLook.Levels.dots[min(l, ShotLook.Levels.dots.count - 1)])
            }
        }
    }

    /// An icon's coverage in a cell, kept: the same few icons are stamped
    /// on every frame of a hover.
    private final class Masks: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String: ShotIconRaster.Mask] = [:]

        func mask(_ key: String, cell: Int, scale: Double) -> ShotIconRaster.Mask? {
            let name = "\(key)/\(cell)/\(scale)"
            lock.lock()
            defer { lock.unlock() }
            if let mask = made[name] { return mask }
            guard let icon = ShotLook.icon(key) else { return nil }
            let mask = ShotIconRaster.mask(icon, cell: cell, scale: scale)
            made[name] = mask
            return mask
        }
    }
    private static let masks = Masks()

    /// Paint one cell: `rect` in display pixels, `origin` the display pixel
    /// of the canvas's top left (9.8.4).
    static func cell(
        into canvas: inout ShotCanvas, rect: PixelRect, origin: PixelPoint, content: Content,
        look: ShotCell.Look, on surface: Surface
    ) {
        let scale = surface.scale, access = surface.access
        let c = ShotLook.Colour.self
        let size = ShotLook.Size.self
        let x = Double(rect.x - origin.x), y = Double(rect.y - origin.y)
        let shape = Shape(x: x, y: y, w: Double(rect.w), h: Double(rect.h), radius: px(size.cellRadius, scale))
        let accent = Ink(c.accent)

        // Under everything: the fills.
        canvas.fill(shape, Ink(c.hover, times: look.hover))
        canvas.strokeInside(shape, thickness: hairline(size.hoverEdge, scale), Ink(c.hoverEdge, times: look.hairline))
        canvas.fill(shape, Ink(c.down, times: look.down))
        canvas.fill(shape, Ink(c.accent, times: look.solid))
        // The ring and, under it, its glow.
        if look.ring > 0 {
            if !access.opaque {
                canvas.glow(shape, sigma: px(size.glowSigma, scale), Ink(c.glow, times: look.ring))
            }
            canvas.strokeInside(shape, thickness: px(size.ring, scale), Ink(c.accent, times: look.ring))
        }

        // What the cell holds, in its ink: white, the accent when it is
        // selected or pressed, faint when it cannot be pressed.
        var ink = look.off ? Ink(c.inkOff) : Ink(c.ink).mixed(with: accent, look.accent)
        if look.solid > 0 { ink = ink.mixed(with: Ink(c.doneDownInk), look.solid) }
        let cx = x + Double(rect.w) / 2, cy = y + Double(rect.h) / 2
        switch content {
        case let .icon(key):
            if let mask = masks.mask(key, cell: rect.w, scale: scale) {
                canvas.stamp(mask, left: rect.x - origin.x, top: rect.y - origin.y, ink)
            }
        case let .swatch(rgb):
            // A colour keeps its colour whatever state the cell is in.
            let dot = Shape.circle(cx: cx, cy: cy, diameter: px(size.swatch, scale))
            canvas.fill(dot, Ink(r: Double(rgb.r) / 255, g: Double(rgb.g) / 255, b: Double(rgb.b) / 255, a: 1))
            canvas.strokeInside(dot, thickness: px(size.swatchEdge, scale), Ink(c.swatchEdge))
        case let .dot(points):
            canvas.fill(Shape.circle(cx: cx, cy: cy, diameter: px(points, scale)), ink)
        case let .blocks(n):
            // A square of the icon grid's units, centred, cut into n by n
            // with every other one filled -- the top left one is -- and
            // nothing rounded to a pixel: the squares meet, anti-aliased,
            // with no gap. A line along the square's inner edge goes over
            // them (9.8.4.3). The other host draws exactly this.
            let unit = ShotLook.IconGrid.points / ShotLook.IconGrid.artboard * scale
            let side = size.mosaicFrame * unit
            let left = cx - side / 2, top = cy - side / 2
            let n = max(n, 1)
            let step = side / Double(n)
            for row in 0..<n {
                for column in 0..<n where (row + column) % 2 == 0 {
                    canvas.fill(
                        Shape(x: left + step * Double(column), y: top + step * Double(row), w: step, h: step, radius: 0),
                        ink)
                }
            }
            let frame = Ink(r: ink.r, g: ink.g, b: ink.b, a: ink.a * c.mosaicFrame.a)
            canvas.strokeInside(
                Shape(x: left, y: top, w: side, h: side, radius: 0), thickness: size.mosaicFrameLine * unit, frame)
        }
    }

    // MARK: The toolbar

    /// A cell of the toolbar with how it looks now.
    struct Cell: Equatable {
        var button: ToolbarButton
        var rect: PixelRect
        var look: ShotCell.Look
    }

    /// The plate of a toolbar laid out as `layout`, without its cells: the
    /// part that does not change while the pointer moves over it.
    static func toolbarPlate(_ layout: ShotToolbarGrid.Layout, on surface: Surface) -> Painted {
        let plate = layout.plate
        let scale = surface.scale
        var painted = canvas(for: plate, scale: scale)
        self.plate(
            into: &painted.canvas, rect: plate, origin: painted.origin, radius: ShotLook.Size.plateRadius,
            on: surface)
        if let props = layout.props {
            // The line between the two rows.
            let line = hairline(ShotLook.Size.rowDivider, scale)
            painted.canvas.fill(
                Shape(
                    x: Double(props.x - painted.origin.x), y: Double(props.y - painted.origin.y) - line / 2,
                    w: Double(props.w), h: line, radius: 0),
                Ink(ShotLook.Colour.rowDivider))
        }
        return painted
    }

    /// The cells of a toolbar over its plate.
    static func toolbar(
        over plate: Painted, cells: [Cell], props: AnnotationTool.Props, on surface: Surface
    ) -> Painted {
        var painted = plate
        for cell in cells {
            self.cell(
                into: &painted.canvas, rect: cell.rect, origin: painted.origin,
                content: content(of: cell.button, props: props), look: cell.look, on: surface)
        }
        return painted
    }
}
