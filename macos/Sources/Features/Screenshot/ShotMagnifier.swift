import CoreGraphics
import CoreText
import Foundation

/// The magnifier that hangs beside the pointer while a region is being
/// chosen (`dev-docs/poltergeist/screenshot.md`, 9.9): the pixels round
/// the pointer, enlarged with nothing between them, and under them where
/// the pointer is and what colour that pixel is.
///
/// The numbers are the generated `ShotLook.Size.magnifier*`, the same on both
/// hosts. What is here is the arithmetic -- which pixels, where the plate
/// goes, what the words say -- as pure functions with tests, and the
/// painting that goes with it.
enum ShotMagnifier {
    /// How many pixels on a side are shown: odd, so that one is in the
    /// middle.
    static var cells: Int {
        let n = max(Int(ShotLook.Size.magnifierCells.rounded()), 1)
        return n % 2 == 0 ? n + 1 : n
    }

    /// The pixels shown for a pointer at `p`: `cells` on a side, with `p` the
    /// middle one. Some of them may be off the display.
    static func sample(around p: PixelPoint, cells: Int = ShotMagnifier.cells) -> PixelRect {
        let reach = cells / 2
        return PixelRect(p.x - reach, p.y - reach, cells, cells)
    }

    /// Everything that sizes the plate, in pixels.
    struct Metrics: Equatable {
        /// One enlarged pixel: whole pixels, so that the cells are all the
        /// same size and the grid lies on the pixel grid.
        var cell: Int
        var pad: Int
        var gap: Int
        var rowHeight: Int
        var swatch: Int
        var cells: Int

        init(scale: Double, textHeight: Int, cells: Int = ShotMagnifier.cells) {
            self.cells = cells
            cell = max(Int((ShotLook.Size.magnifierCell * scale).rounded()), 1)
            pad = ShotStyle.px(Int(ShotLook.Size.magnifierPad), scale: scale)
            gap = ShotStyle.px(Int(ShotLook.Size.magnifierRowGap), scale: scale)
            swatch = max(Int((ShotLook.Size.magnifierSwatch * scale).rounded()), 1)
            rowHeight = max(textHeight, swatch) + ShotStyle.px(2, scale: scale)
        }

        /// The enlarged picture's side.
        var image: Int { cells * cell }
        var plateWidth: Int { image + 2 * pad }
        /// The picture, the coordinates, and the colour with its swatch.
        var plateHeight: Int { pad + image + gap + 2 * rowHeight + pad }
    }

    /// Where the plate goes for a pointer at `pointer`: right of it and
    /// below it, `offset` away; on the other side of it when that would
    /// leave the display, and never covering the pixel the pointer is on
    /// unless the display is too small to avoid it.
    static func place(
        pointer: PixelPoint, plate: (w: Int, h: Int), offset: Int, display: PixelRect
    ) -> PixelRect {
        var x = pointer.x + offset
        if x + plate.w > display.right { x = pointer.x - offset - plate.w }
        var y = pointer.y + offset
        if y + plate.h > display.bottom { y = pointer.y - offset - plate.h }
        x = max(min(x, display.right - plate.w), display.x)
        y = max(min(y, display.bottom - plate.h), display.y)
        return PixelRect(x, y, plate.w, plate.h)
    }

    /// `#RRGGBB`, upper case: what the copy key puts on the clipboard.
    static func hex(_ c: ShotStyle.RGB) -> String {
        String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// The pointer's pixel in the display's own pixels: `x, y`.
    static func coordinates(_ p: PixelPoint, display: PixelRect) -> String {
        "\(p.x - display.x), \(p.y - display.y)"
    }

    /// Whether a key is the one that copies the colour: Cmd+C and nothing
    /// else held.
    static func isCopyKey(_ input: EditorKey.Input, mods: ShotMods) -> Bool {
        guard mods.intersection(.all) == [.command] else { return false }
        if case let .letter(c) = input { return c == "c" || c == "C" }
        return false
    }

    /// The lines at which the grid is drawn inside the enlarged picture,
    /// as offsets from its left or top edge: every cell boundary, the two
    /// outer edges included.
    static func gridOffsets(cells: Int, cell: Int) -> [Int] {
        (0...cells).map { $0 * cell }
    }

    /// The enlarged middle pixel, as a rectangle inside the enlarged
    /// picture (offsets from its top left).
    static func centreCell(cells: Int, cell: Int) -> PixelRect {
        PixelRect(cells / 2 * cell, cells / 2 * cell, cell, cell)
    }
}

// MARK: Painting

extension ShotRenderer {
    /// Paint the magnifier for a pointer at `pointer` on a display whose
    /// frozen picture is `frozen`, and return the plate's rectangle.
    /// `copied` shows "Copied" where the colour's text is.
    @discardableResult
    static func drawMagnifier(
        frozen: FrozenImage, pointer: PixelPoint, copied: Bool, display: PixelRect,
        on surface: ShotChrome.Surface, in ctx: CGContext
    ) -> PixelRect {
        let scale = surface.scale
        let font = uiFont(scale: scale)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let m = ShotMagnifier.Metrics(scale: scale, textHeight: Int((ascent + descent).rounded(.up)))
        let offset = ShotStyle.px(Int(ShotLook.Size.magnifierOffset), scale: scale)
        let plate = ShotMagnifier.place(
            pointer: pointer, plate: (m.plateWidth, m.plateHeight), offset: offset, display: display)

        var painted = ShotChrome.canvas(for: plate, scale: scale)
        ShotChrome.plate(
            into: &painted.canvas, rect: plate, origin: painted.origin, radius: ShotLook.Size.plateRadius, on: surface)
        draw(painted, in: ctx)

        // The enlarged pixels, with nothing between them.
        let image = PixelRect(plate.x + m.pad, plate.y + m.pad, m.image, m.image)
        let sample = ShotMagnifier.sample(around: pointer, cells: m.cells)
        let rgb = ShotLook.Colour.magnifierOffScreen
        let bytes = frozen.patch(sample, outside: .init(r: rgb.r, g: rgb.g, b: rgb.b))
        if let picture = ShotBlur.Picture(width: sample.w, height: sample.h, rgbx: bytes),
           let cg = self.image(of: picture) {
            ctx.saveGState()
            let radius = CGFloat(ShotStyle.px(Int(ShotLook.Size.magnifierImageRadius), scale: scale))
            ctx.addPath(CGPath(
                roundedRect: CGRect(x: image.x, y: image.y, width: image.w, height: image.h),
                cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            draw(cg, in: CGRect(x: image.x, y: image.y, width: image.w, height: image.h), of: ctx)
            // The grid.
            let line = max(Int((ShotLook.Size.magnifierGridLine * scale).rounded()), 1)
            for offset in ShotMagnifier.gridOffsets(cells: m.cells, cell: m.cell) {
                fill(PixelRect(image.x + offset - line / 2, image.y, line, image.h), self.ink(ShotLook.Colour.magnifierGrid), in: ctx)
                fill(PixelRect(image.x, image.y + offset - line / 2, image.w, line), self.ink(ShotLook.Colour.magnifierGrid), in: ctx)
            }
            // The pixel the pointer is on: a light line inside a dark one.
            let centre = ShotMagnifier.centreCell(cells: m.cells, cell: m.cell)
            let width = max(Int((ShotLook.Size.magnifierCentreLine * scale / 2).rounded()), 1)
            let cell = PixelRect(image.x + centre.x, image.y + centre.y, centre.w, centre.h)
            frame(
                PixelRect(cell.x - width, cell.y - width, cell.w + 2 * width, cell.h + 2 * width),
                self.ink(ShotLook.Colour.magnifierCentreOuter), thickness: width, in: ctx)
            frame(cell, self.ink(ShotLook.Colour.magnifierCentreInner), thickness: width, in: ctx)
            ctx.restoreGState()
        }

        // Where the pointer is, and what it is on.
        let size = ShotLook.Size.self
        let colour = frozen.colour(at: pointer)
        let rowTop = image.bottom + m.gap
        func baseline(_ row: Int) -> CGFloat {
            CGFloat(rowTop + row * m.rowHeight) + (CGFloat(m.rowHeight) - (ascent + descent)) / 2 + ascent
        }
        func text(_ words: String, at x: CGFloat, row: Int, colour: CGColor) -> CGFloat {
            let line = ShotFont.line(words, font: font, colour: colour)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: x, y: baseline(row))
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let left = CGFloat(plate.x + m.pad)
        _ = text(
            ShotMagnifier.coordinates(pointer, display: display), at: left, row: 0,
            colour: self.ink(ShotLook.Colour.ink))
        var x = left
        if let colour {
            let middle = CGFloat(rowTop + m.rowHeight) + CGFloat(m.rowHeight) / 2
            let d = CGFloat(m.swatch)
            let swatch = CGRect(x: x, y: middle - d / 2, width: d, height: d)
            ctx.saveGState()
            ctx.setFillColor(self.colour(colour))
            ctx.fillEllipse(in: swatch)
            ctx.setStrokeColor(self.ink(ShotLook.Colour.swatchEdge))
            ctx.setLineWidth(max(CGFloat(size.swatchEdge * scale), 1))
            ctx.strokeEllipse(in: swatch.insetBy(dx: 0.5, dy: 0.5))
            ctx.restoreGState()
            x += d + CGFloat(size.statusGap * scale) / 2
            let words = copied ? ShotWords.translate("Copied") : ShotMagnifier.hex(colour)
            let width = text(
                words, at: x, row: 1,
                colour: self.ink(copied ? ShotLook.Colour.accent : ShotLook.Colour.ink))
            x += width
        }
        // The key that copies it, on a small plate of its own, at the right.
        let keyLine = ShotFont.line("⌘C", font: font, colour: self.ink(ShotLook.Colour.inkDim))
        let keyWidth = CGFloat(CTLineGetTypographicBounds(keyLine, nil, nil, nil)).rounded(.up)
            + 2 * CGFloat(size.tipKeyPadX * scale)
        let keyHeight = ascent + descent + 2 * CGFloat(size.tipKeyPadY * scale)
        let keyLeft = CGFloat(plate.right - m.pad) - keyWidth
        if keyLeft >= x + CGFloat(size.statusGap * scale) / 2 {
            let middle = CGFloat(rowTop + m.rowHeight) + CGFloat(m.rowHeight) / 2
            var key = ShotChrome.canvas(for: plate, scale: scale)
            key.canvas.fill(
                ShotCanvas.Shape(
                    x: Double(keyLeft) - Double(key.origin.x), y: Double(middle - keyHeight / 2) - Double(key.origin.y),
                    w: Double(keyWidth), h: Double(keyHeight), radius: size.tipKeyRadius * scale),
                ShotCanvas.Ink(ShotLook.Colour.tipKeyPlate))
            draw(key, in: ctx)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: keyLeft + CGFloat(size.tipKeyPadX * scale), y: baseline(1))
            CTLineDraw(keyLine, ctx)
            ctx.restoreGState()
        }
        return plate
    }
}
