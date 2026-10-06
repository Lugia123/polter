import AppKit
import CoreGraphics
import CoreText

/// Drawing annotations, and the toolbar, into a Core Graphics context
/// (`dev-docs/poltergeist/screenshot.md`, 9.1 and 9.7).
///
/// **One routine for the overlay and for the saved image**, so that what is
/// saved is what was shown. Every context handed in here has the same
/// shape: one unit is one pixel, the origin is at the top left and y runs
/// downwards, already moved so that the editor's coordinates can be used as
/// they are.
enum ShotRenderer {
    /// How a highlighter stroke gets onto the picture. It multiplies into
    /// what is there, which a context cannot be asked to do to its own
    /// pixels in whole numbers; the saved image does it in the pixels
    /// (`ShotPixels.highlight`), the overlay with a blend mode that looks
    /// the same.
    typealias Highlighter = (_ points: [PixelPoint], _ width: Int, _ colour: ShotStyle.RGB) -> Void

    static func colour(_ rgb: ShotStyle.RGB, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: alpha)
    }

    static func gray(_ value: Int, alpha: CGFloat = 1) -> CGColor {
        colour(.init(r: UInt8(value), g: UInt8(value), b: UInt8(value)), alpha: alpha)
    }

    /// Black or white, whichever shows on colour `index`: the digit in a
    /// number's circle.
    static func inkOn(_ c: ShotStyle.RGB) -> CGColor {
        let luma = (299 * Int(c.r) + 587 * Int(c.g) + 114 * Int(c.b)) / 1000
        return gray(luma > 150 ? 0 : 255)
    }

    /// The colour a highlighter multiplies by: 40% of the way from white to
    /// the pen's colour (9.7).
    static func highlightFactor(_ rgb: ShotStyle.RGB) -> CGColor {
        func f(_ c: UInt8) -> CGFloat { (255 - 0.4 * (255 - CGFloat(c))) / 255 }
        return CGColor(srgbRed: f(rgb.r), green: f(rgb.g), blue: f(rgb.b), alpha: 1)
    }

    private static func point(_ p: PixelPoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }
    private static func rect(_ r: PixelRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }

    // MARK: Text

    /// Draw `text`, which may have several lines, with the top left of its
    /// first line at `at`.
    static func drawText(_ text: String, at: PixelPoint, fontPx: Int, colour: CGColor, in ctx: CGContext) {
        let font = ShotFont.font(size: CGFloat(fontPx))
        let lineHeight = ShotFont.lineHeight(of: font)
        let ascent = CTFontGetAscent(font)
        ctx.saveGState()
        // Text is drawn with y upwards; this context's runs downwards.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            ctx.textPosition = CGPoint(x: CGFloat(at.x), y: CGFloat(at.y + i * lineHeight) + ascent)
            CTLineDraw(ShotFont.line(line, font: font, colour: colour), ctx)
        }
        ctx.restoreGState()
    }

    /// Draw one line of text centred on `centre`.
    private static func drawCentred(_ text: String, on centre: CGPoint, font: CTFont, colour: CGColor, in ctx: CGContext) {
        let line = ShotFont.line(text, font: font, colour: colour)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: centre.x - width / 2, y: centre.y + (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Annotations

    /// Draw the annotations that are not mosaics, in the order given.
    /// Mosaics are already in the pixels (`ShotPixels.applyMosaics`) and are
    /// skipped.
    ///
    /// `hideTextOf` is the annotation whose words the text box is showing
    /// instead: they are not drawn twice.
    static func draw(
        _ items: [(index: Int, item: Annotation)], in ctx: CGContext, scale: Double,
        hideTextOf: Int? = nil, highlighter: Highlighter
    ) {
        for (index, item) in items {
            let rgb = item.rgb
            let ink = colour(rgb)
            let width = item.strokePx(scale: scale)
            let fontPx = ShotStyle.fontPx(level: item.level, scale: scale)
            let hidden = hideTextOf == index

            ctx.saveGState()
            ctx.setStrokeColor(ink)
            ctx.setFillColor(ink)
            ctx.setLineWidth(CGFloat(width))
            // Round ends and joins: a thick freehand stroke with square
            // ones is a row of notches.
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            switch item.shape {
            case .mosaic:
                break
            case let .rect(r):
                ctx.setLineJoin(.miter)
                ctx.stroke(rect(r))
            case let .ellipse(r):
                ctx.strokeEllipse(in: rect(r))
            case let .line(from, to):
                ctx.strokeLineSegments(between: [point(from), point(to)])
            case let .arrow(from, to):
                ctx.strokeLineSegments(between: [point(from), point(to)])
                if let head = PixelGeometry.arrowHead(from: from, to: to, size: width * 5) {
                    ctx.addLines(between: head.map(point))
                    ctx.closePath()
                    ctx.drawPath(using: .fillStroke)
                }
            case let .pen(points):
                ctx.addLines(between: points.map(point))
                ctx.strokePath()
            case let .highlighter(points):
                highlighter(points, width, rgb)
            case let .text(at, text, _):
                if !hidden { drawText(text, at: at, fontPx: fontPx, colour: ink, in: ctx) }
            case let .number(n, at, text, size):
                let radius = CGFloat(Annotation.numberRadius(level: item.level, scale: scale))
                let centre = point(at)
                ctx.fillEllipse(in: CGRect(
                    x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
                drawCentred(
                    "\(n)", on: centre, font: ShotFont.font(size: CGFloat(fontPx)), colour: inkOn(rgb), in: ctx)
                if !text.isEmpty && !hidden {
                    let origin = Annotation.captionOrigin(
                        at: at, level: item.level, scale: scale, captionHeight: size.h)
                    drawText(text, at: origin, fontPx: fontPx, colour: ink, in: ctx)
                }
            }
            ctx.restoreGState()
        }
    }

    /// The overlay's highlighter: one stroke, multiplied in once, so that a
    /// stroke crossing itself is not darker where it crosses.
    static func blendedHighlighter(in ctx: CGContext) -> Highlighter {
        { points, width, rgb in
            guard !points.isEmpty else { return }
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(highlightFactor(rgb))
            ctx.setFillColor(highlightFactor(rgb))
            ctx.setLineWidth(CGFloat(max(width, 1)))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if points.count == 1 {
                let r = CGFloat(max(width, 1)) / 2
                ctx.fillEllipse(in: CGRect(
                    x: CGFloat(points[0].x) - r, y: CGFloat(points[0].y) - r, width: r * 2, height: r * 2))
            } else {
                ctx.addLines(between: points.map(point))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    // MARK: Images

    /// Draw `image` into `target`, the right way up in a context whose y
    /// runs downwards.
    static func draw(_ image: CGImage, in target: CGRect, of ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(origin: .zero, size: target.size))
        ctx.restoreGState()
    }

    /// `picture` as an image, opaque: its fourth byte is not alpha and is
    /// not read.
    static func image(of picture: ShotBlur.Picture) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(picture.rgbx) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: picture.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// `image` as rows of R, G, B, X, top row first, or nil when it cannot
    /// be drawn.
    static func rgbx(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Run `body` with a context over `pixels`, a buffer covering `rect`,
    /// set up the way every routine here expects. False when no context
    /// could be made, and then nothing was drawn.
    static func withContext(
        over pixels: inout [UInt8], covering rect: PixelRect, _ body: (CGContext) -> Void
    ) -> Bool {
        guard rect.w > 0, rect.h > 0, pixels.count == rect.w * rect.h * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        return pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: rect.w, height: rect.h, bitsPerComponent: 8,
                bytesPerRow: rect.w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(rect.h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -CGFloat(rect.x), y: -CGFloat(rect.y))
            body(ctx)
            return true
        }
    }

    /// The selection as it leaves: cut from the frozen picture with the
    /// redactions and the mosaics applied, the other annotations drawn on
    /// top.
    ///
    /// **`ComposedImage` is the only thing with a way out** -- `png`,
    /// `tiles` and `cgImage` are its methods -- so the file, the clipboard
    /// image and the tiles cannot be the picture a mosaic was meant to hide.
    static func compose(
        frozen: FrozenImage, selection: PixelRect, items: [Annotation], scale: Double, redact: [PixelRect] = []
    ) -> ComposedImage? {
        guard var composed = ComposedImage(
            frozen: frozen, selection: selection, items: items, scale: scale, redact: redact) else { return nil }
        let others = items.enumerated().compactMap { index, item -> (index: Int, item: Annotation)? in
            if case .mosaic = item.shape { return nil }
            return (index, item)
        }
        guard !others.isEmpty else { return composed }

        var drawn = true
        composed.draw { pixels, rect in
            // One at a time, so that a highlighter -- which writes the
            // pixels itself -- lands between the shapes before and after it
            // and not under or over all of them.
            for one in others {
                if case let .highlighter(points) = one.item.shape {
                    ShotPixels.highlight(
                        &pixels, covering: rect, points: points,
                        width: one.item.strokePx(scale: scale), colour: one.item.rgb)
                    continue
                }
                let ok = withContext(over: &pixels, covering: rect) { ctx in
                    draw([one], in: ctx, scale: scale) { _, _, _ in }
                }
                drawn = drawn && ok
            }
        }
        return drawn ? composed : nil
    }

    // MARK: Chrome

    /// The accent: the selection's edge, the ring of whatever is selected
    /// (9.8.3).
    static let accent = ShotStyle.RGB(
        r: ShotLook.Colour.accent.r, g: ShotLook.Colour.accent.g, b: ShotLook.Colour.accent.b)

    /// One of the look's colours, thinned by `times`.
    static func ink(_ c: ShotLook.RGBA, times: Double = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255,
            alpha: CGFloat(c.a * times))
    }

    static func fill(_ r: PixelRect, _ colour: CGColor, in ctx: CGContext) {
        ctx.setFillColor(colour)
        ctx.fill(rect(r))
    }

    /// A frame `thickness` wide just inside `r`.
    static func frame(_ r: PixelRect, _ colour: CGColor, thickness: Int, in ctx: CGContext) {
        fill(PixelRect(r.x, r.y, r.w, thickness), colour, in: ctx)
        fill(PixelRect(r.x, r.bottom - thickness, r.w, thickness), colour, in: ctx)
        fill(PixelRect(r.x, r.y, thickness, r.h), colour, in: ctx)
        fill(PixelRect(r.right - thickness, r.y, thickness, r.h), colour, in: ctx)
    }

    // MARK: Handles and frames (9.8.11A)

    /// One of the selection's own eight handles: round, white, edged in the
    /// accent. Round is what tells it from an annotation's, which is square.
    static func drawKnob(at c: PixelPoint, scale: Double, in ctx: CGContext) {
        let d = CGFloat(ShotLook.Size.selectionKnob * scale)
        let line = CGFloat(ShotStyle.px(Int(ShotLook.Size.selectionLine), scale: scale))
        let box = CGRect(x: CGFloat(c.x) - d / 2, y: CGFloat(c.y) - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setFillColor(ink(ShotLook.Colour.knobFill))
        ctx.fillEllipse(in: box)
        ctx.setStrokeColor(ink(ShotLook.Colour.accent))
        ctx.setLineWidth(line)
        ctx.strokeEllipse(in: box.insetBy(dx: line / 2, dy: line / 2))
        ctx.restoreGState()
    }

    /// The frame round a selected annotation whose ink is `inkBox`: a white
    /// line with dashes of the accent over it -- blue and white by turns, so
    /// that it shows on white, where the white is lost, and on blue, where
    /// the blue is -- with the glow a selected cell has. It is a little
    /// outside the ink, so it is never on the annotation's own line.
    static func drawFrame(round inkBox: PixelRect, on surface: ShotChrome.Surface, in ctx: CGContext) {
        let scale = surface.scale
        let a = ShotLook.Annotation.self
        let frame = ShotEditor.frame(of: inkBox, scale: scale)
        let line = CGFloat(ShotStyle.px(Int(a.frameLine), scale: scale))
        let radius = CGFloat(a.frameRadius * scale)
        if !surface.access.opaque {
            // The glow, along the line.
            let sigma = ShotLook.Size.glowSigma * scale
            let reach = Int((sigma * 3).rounded(.up)) + 2
            var canvas = ShotCanvas(width: frame.w + 2 * reach, height: frame.h + 2 * reach)
            canvas.glow(
                ShotCanvas.Shape(
                    x: Double(reach), y: Double(reach), w: Double(frame.w), h: Double(frame.h), radius: Double(radius)),
                sigma: sigma, ShotCanvas.Ink(ShotLook.Colour.glow))
            draw(ShotChrome.Painted(canvas: canvas, origin: PixelPoint(frame.x - reach, frame.y - reach)), in: ctx)
        }
        // The line runs just outside the frame's rectangle.
        let path = CGPath(
            roundedRect: rect(frame).insetBy(dx: -line / 2, dy: -line / 2),
            cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setLineWidth(line)
        ctx.addPath(path)
        ctx.setStrokeColor(ink(ShotLook.Colour.frameLight))
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(ink(ShotLook.Colour.accent))
        ctx.setLineDash(
            phase: 0,
            lengths: [
                CGFloat(ShotStyle.px(Int(a.frameDashOn), scale: scale)),
                CGFloat(ShotStyle.px(Int(a.frameDashOff), scale: scale)),
            ])
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// One grip of a selected annotation: a small square, white edged in
    /// the accent; larger and glowing under the pointer; the accent edged
    /// in white while it is dragged.
    static func drawGrip(at c: PixelPoint, look: ShotEditor.GripLook, on surface: ShotChrome.Surface, in ctx: CGContext) {
        let scale = surface.scale
        let a = ShotLook.Annotation.self
        let side = CGFloat((look == .normal ? a.grip : a.gripHot) * scale)
        let line = CGFloat(ShotStyle.px(Int(a.gripLine), scale: scale))
        let radius = CGFloat(a.gripRadius * scale)
        let box = CGRect(x: CGFloat(c.x) - side / 2, y: CGFloat(c.y) - side / 2, width: side, height: side)
        let outline = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        // What is under it: a thin dark edge that lifts a white square off
        // a white picture, or the glow.
        if look == .normal || surface.access.opaque {
            ctx.setShadow(offset: .zero, blur: CGFloat(a.gripShadow * scale * 2), color: ink(ShotLook.Colour.gripShadow))
        } else {
            ctx.setShadow(
                offset: .zero, blur: CGFloat(ShotLook.Size.glowSigma * scale * 2),
                color: ink(ShotLook.Colour.accent))
        }
        ctx.addPath(outline)
        ctx.setFillColor(ink(look == .held ? ShotLook.Colour.accent : ShotLook.Colour.gripFill))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(
            roundedRect: box.insetBy(dx: line / 2, dy: line / 2),
            cornerWidth: max(radius - line / 2, 0), cornerHeight: max(radius - line / 2, 0), transform: nil))
        ctx.setStrokeColor(ink(look == .held ? ShotLook.Colour.gripFill : ShotLook.Colour.accent))
        ctx.setLineWidth(line)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A painted canvas as an image, with its alpha.
    static func image(of canvas: ShotCanvas) -> CGImage? {
        guard canvas.width > 0, canvas.height > 0,
              let provider = CGDataProvider(data: Data(canvas.rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: canvas.width, height: canvas.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: canvas.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Draw a painted piece of furniture where it goes.
    static func draw(_ painted: ShotChrome.Painted, in ctx: CGContext) {
        guard let image = image(of: painted.canvas) else { return }
        draw(
            image,
            in: CGRect(
                x: painted.origin.x, y: painted.origin.y,
                width: painted.canvas.width, height: painted.canvas.height),
            of: ctx)
    }

    /// The font the overlay's own words are in: the system's, at the size
    /// menus use, which is the smallest any text of ours may be.
    static func uiFont(scale: Double) -> CTFont {
        let points = max(NSFont.menuFont(ofSize: 0).pointSize, NSFont.systemFontSize)
        return CTFontCreateUIFontForLanguage(.system, points * scale, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, points * scale, nil)
    }

    /// One thing on a label.
    enum LabelPart: Equatable {
        /// Words, in the ordinary ink or the fainter one.
        case words(String, dim: Bool = false)
        /// A key, on a small plate of its own: `R`, `⌘Z`.
        case key(String)
        /// The red dot of something being recorded.
        case dot
    }

    /// The paddings of a label, in points.
    struct LabelStyle: Equatable {
        var padX: Double
        var padY: Double
        var gap: Double

        /// The hover text of a button.
        static let tip = LabelStyle(
            padX: ShotLook.Size.tipPadX, padY: ShotLook.Size.tipPadY, gap: ShotLook.Size.tipKeyGap)
        /// A long screenshot's status line.
        static let status = LabelStyle(
            padX: ShotLook.Size.statusPadX, padY: ShotLook.Size.statusPadY, gap: ShotLook.Size.statusGap)
        /// The selection's size.
        static let size = LabelStyle(
            padX: ShotLook.Size.sizeLabelPadX, padY: ShotLook.Size.sizeLabelPadY, gap: ShotLook.Size.statusGap)
    }

    /// How big a label of `parts` is, in pixels.
    static func labelSize(_ parts: [LabelPart], style: LabelStyle, scale: Double) -> (w: Int, h: Int) {
        let laid = lay(parts, style: style, scale: scale)
        return (laid.width, laid.height)
    }

    private struct LaidPart {
        var part: LabelPart
        var x: CGFloat
        var width: CGFloat
        var line: CTLine?
    }

    private struct Laid {
        var parts: [LaidPart]
        var width: Int
        var height: Int
        var ascent: CGFloat
        var descent: CGFloat
    }

    private static func lay(_ parts: [LabelPart], style: LabelStyle, scale: Double) -> Laid {
        let font = uiFont(scale: scale)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let size = ShotLook.Size.self
        var x = CGFloat(style.padX * scale)
        var laid: [LaidPart] = []
        for (n, part) in parts.enumerated() {
            if n > 0 { x += CGFloat(style.gap * scale) }
            switch part {
            case let .words(text, dim):
                let line = ShotFont.line(text, font: font, colour: ink(dim ? ShotLook.Colour.inkDim : ShotLook.Colour.ink))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
                laid.append(LaidPart(part: part, x: x, width: width, line: line))
                x += width
            case let .key(text):
                let line = ShotFont.line(text, font: font, colour: ink(ShotLook.Colour.inkDim))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
                    + 2 * CGFloat(size.tipKeyPadX * scale)
                laid.append(LaidPart(part: part, x: x, width: width, line: line))
                x += width
            case .dot:
                let width = CGFloat((size.statusDot + 2 * size.statusDotHalo) * scale)
                laid.append(LaidPart(part: part, x: x, width: width, line: nil))
                x += width
            }
        }
        x += CGFloat(style.padX * scale)
        let height = (ascent + descent).rounded(.up) + 2 * CGFloat(style.padY * scale)
        return Laid(
            parts: laid, width: Int(x.rounded(.up)), height: Int(height.rounded(.up)), ascent: ascent, descent: descent)
    }

    /// A label: `parts` on a glass plate whose top left is at `at`, moved
    /// sideways to stay on `display`. Returns the plate's rectangle.
    @discardableResult
    static func label(
        _ parts: [LabelPart], style: LabelStyle, at: PixelPoint, within display: PixelRect,
        on surface: ShotChrome.Surface, in ctx: CGContext
    ) -> PixelRect {
        let scale = surface.scale
        let laid = lay(parts, style: style, scale: scale)
        let x = max(min(at.x, display.right - laid.width), display.x)
        let plate = PixelRect(x, at.y, laid.width, laid.height)
        var painted = ShotChrome.canvas(for: plate, scale: scale)
        ShotChrome.plate(
            into: &painted.canvas, rect: plate, origin: painted.origin, radius: ShotLook.Size.labelRadius,
            on: surface)
        let size = ShotLook.Size.self
        let middle = Double(plate.y - painted.origin.y) + Double(plate.h) / 2
        for item in laid.parts {
            let left = Double(plate.x - painted.origin.x) + Double(item.x)
            switch item.part {
            case .key:
                // The key's own small plate.
                let h = Double(laid.ascent + laid.descent) + 2 * size.tipKeyPadY * scale
                painted.canvas.fill(
                    ShotCanvas.Shape(
                        x: left, y: middle - h / 2, w: Double(item.width), h: h, radius: size.tipKeyRadius * scale),
                    ShotCanvas.Ink(ShotLook.Colour.tipKeyPlate))
            case .dot:
                let cx = left + Double(item.width) / 2
                painted.canvas.fill(
                    .circle(cx: cx, cy: middle, diameter: (size.statusDot + 2 * size.statusDotHalo) * scale),
                    ShotCanvas.Ink(ShotLook.Colour.statusDotHalo))
                painted.canvas.fill(
                    .circle(cx: cx, cy: middle, diameter: size.statusDot * scale),
                    ShotCanvas.Ink(ShotLook.Colour.statusDot))
            case .words:
                break
            }
        }
        draw(painted, in: ctx)

        // The words, over the plate.
        let baseline = CGFloat(plate.y) + (CGFloat(plate.h) - (laid.ascent + laid.descent)) / 2 + laid.ascent
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for item in laid.parts {
            guard let line = item.line else { continue }
            var tx = CGFloat(plate.x) + item.x
            if case .key = item.part { tx += CGFloat(size.tipKeyPadX * scale) }
            ctx.textPosition = CGPoint(x: tx, y: baseline)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
        return plate
    }
}
