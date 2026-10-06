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

    static let accent = ShotStyle.RGB(r: 0x1E, g: 0xA0, b: 0xF0)
    private static let bar = 0x30
    private static let barActive = 0x68
    private static let barHover = 0x48
    private static let ink = 0xFF
    private static let inkOff = 0x80

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

    /// The font the overlay's own words are in: the system's, at the size
    /// menus use, which is the smallest any text of ours may be.
    static func uiFont(scale: Double) -> CTFont {
        let points = max(NSFont.menuFont(ofSize: 0).pointSize, NSFont.systemFontSize)
        return CTFontCreateUIFontForLanguage(.system, points * scale, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, points * scale, nil)
    }

    /// A line of the overlay's own words on a dark plate, its top left at
    /// `at`, kept on `display` sideways. Returns the plate's height.
    @discardableResult
    static func label(_ text: String, at: PixelPoint, within display: PixelRect, scale: Double, in ctx: CGContext) -> Int {
        let font = uiFont(scale: scale)
        let line = ShotFont.line(text, font: font, colour: gray(ink))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = Int(CTLineGetTypographicBounds(line, &ascent, &descent, nil).rounded(.up))
        let pad = ShotStyle.px(4, scale: scale)
        let height = Int((ascent + descent).rounded(.up)) + pad
        let plateWidth = width + pad * 2
        let x = max(min(at.x, display.right - plateWidth), display.x)
        fill(PixelRect(x, at.y, plateWidth, height), gray(0x20), in: ctx)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: CGFloat(x + pad), y: CGFloat(at.y) + CGFloat(pad) / 2 + ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return height
    }

    /// One toolbar button's picture, in `r`.
    ///
    /// Drawn as shapes, the same shapes as the other host, rather than
    /// taken from a symbol font: the two toolbars are meant to be one
    /// toolbar.
    static func drawIcon(_ button: ToolbarButton, in r: PixelRect, scale: Double, ink: CGColor, of ctx: CGContext) {
        let line = max(ShotStyle.px(2, scale: scale), 1)
        // The picture's box: the button less a quarter all round.
        let m = r.w / 4
        let l = r.x + m, t = r.y + m, rt = r.right - m, b = r.bottom - m
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        func p(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: x, y: y) }
        func stroke(_ points: [CGPoint]) {
            ctx.addLines(between: points)
            ctx.strokePath()
        }
        func glyph(_ text: String, _ px: Int) {
            let font = CTFontCreateUIFontForLanguage(.system, CGFloat(px), nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(px), nil)
            drawCentred(text, on: p(cx, cy), font: font, colour: ink, in: ctx)
        }

        ctx.saveGState()
        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)
        ctx.setLineWidth(CGFloat(line))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch button {
        case .tool(.select):
            // A pointer: an arrow from the top left.
            ctx.addLines(between: [p(l, t), p(l, b), p(l + (rt - l) / 3, b - (b - t) / 3), p(rt - m / 2, b - (b - t) / 3)])
            ctx.closePath()
            ctx.fillPath()
        case .tool(.rect):
            ctx.stroke(CGRect(x: l, y: t + m / 3, width: rt - l, height: b - t - 2 * (m / 3)))
        case .tool(.ellipse):
            ctx.strokeEllipse(in: CGRect(x: l, y: t + m / 3, width: rt - l, height: b - t - 2 * (m / 3)))
        case .tool(.line):
            stroke([p(l, b), p(rt, t)])
        case .tool(.arrow):
            stroke([p(l, b), p(rt, t)])
            stroke([p(rt - (rt - l) / 2, t), p(rt, t), p(rt, t + (b - t) / 2)])
        case .tool(.pen):
            let q = (rt - l) / 4
            stroke([p(l, b), p(l + q, t + q), p(l + 2 * q, b - q), p(l + 3 * q, t), p(rt, t + q)])
        case .tool(.highlighter):
            ctx.setLineWidth(CGFloat(line * 3))
            ctx.setLineCap(.butt)
            stroke([p(l, cy), p(rt, cy)])
        case .tool(.text):
            glyph("A", r.h * 5 / 9)
        case .tool(.number):
            ctx.strokeEllipse(in: CGRect(x: l, y: t, width: rt - l, height: b - t))
            glyph("1", r.h * 4 / 9)
        case .tool(.mosaic):
            // Four squares of a chequerboard.
            let hw = (rt - l) / 2, hh = (b - t) / 2
            ctx.stroke(CGRect(x: l, y: t, width: rt - l, height: b - t))
            ctx.fill(CGRect(x: l, y: t, width: hw, height: hh))
            ctx.fill(CGRect(x: l + hw, y: t + hh, width: rt - l - hw, height: b - t - hh))
        case .undo:
            glyph("↶", r.h * 5 / 9)
        case .redo:
            glyph("↷", r.h * 5 / 9)
        case .long:
            // A tall page and an arrow down it.
            ctx.stroke(CGRect(x: l + m / 2, y: t - m / 3, width: rt - l - m, height: b - t + 2 * (m / 3)))
            stroke([p(cx, t + m / 3), p(cx, b - m / 4)])
            stroke([p(cx - m / 2, b - m / 4 - m / 2), p(cx, b - m / 4), p(cx + m / 2, b - m / 4 - m / 2)])
        case .cancel:
            glyph("✕", r.h * 5 / 9)
        case .done:
            glyph("✓", r.h * 5 / 9)
        case let .colour(c):
            ctx.setFillColor(colour(ShotStyle.colour(c)))
            ctx.fill(rect(r))
        case let .level(level):
            // A dot that grows with the step.
            let radius = (r.w * (level + 1)) / 12 + 1
            ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        }
        ctx.restoreGState()
    }

    /// The toolbar, the hover text of the button under the pointer, and --
    /// when the bundled font is missing -- a line saying so. Returns the y
    /// just under the last thing drawn below the bar, where the next line
    /// (a long screenshot's status) may go.
    @discardableResult
    static func drawToolbar(
        _ layout: ShotToolbarGrid.Layout, editor: ShotEditor, scale: Double, display: PixelRect,
        in ctx: CGContext, translate: (String) -> String
    ) -> Int {
        fill(layout.bar, gray(bar), in: ctx)
        if let row = layout.props { fill(row, gray(bar), in: ctx) }
        let current = editor.current
        for placed in layout.buttons {
            let r = placed.rect
            let isCurrent: Bool
            switch placed.button {
            case let .tool(t): isCurrent = editor.tool == t
            case let .colour(c): isCurrent = c == current.colour
            case let .level(l): isCurrent = l == current.level
            default: isCurrent = false
            }
            let enabled: Bool
            switch placed.button {
            case .undo: enabled = editor.canUndo
            case .redo: enabled = editor.canRedo
            default: enabled = true
            }
            let hovered = editor.hoverButton == placed.button && enabled
            if case .colour = placed.button {
                // The current colour wears a ring.
                if isCurrent {
                    let ring = ShotStyle.px(2, scale: scale)
                    frame(
                        PixelRect(r.x - ring * 2, r.y - ring * 2, r.w + ring * 4, r.h + ring * 4),
                        gray(ink), thickness: ring, in: ctx)
                }
            } else if isCurrent {
                fill(r, gray(barActive), in: ctx)
            } else if hovered {
                fill(r, gray(barHover), in: ctx)
            }
            drawIcon(placed.button, in: r, scale: scale, ink: gray(enabled ? ink : inkOff), of: ctx)
        }

        let gap = ShotStyle.px(4, scale: scale)
        var next = (layout.props?.bottom ?? layout.bar.bottom) + gap
        if !ShotFont.isAvailable {
            let words = translate("The annotation font is missing, so the system font is used.")
            next += label(words, at: PixelPoint(layout.bar.x, next), within: display, scale: scale, in: ctx)
                + ShotStyle.px(2, scale: scale)
        }
        if let button = editor.hoverButton, let r = layout.rect(of: button) {
            let tip = ShotToolbarGrid.tooltip(for: button, props: editor.props, translate: translate)
            let y = max(next, r.bottom + gap)
            next = y + label(tip, at: PixelPoint(r.x, y), within: display, scale: scale, in: ctx) + gap
        }
        return next
    }
}
