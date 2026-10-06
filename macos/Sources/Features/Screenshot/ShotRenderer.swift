import AppKit

extension ShotColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// What is legible on top of this colour: the number inside a marker.
    var inkColor: NSColor {
        // Relative luminance, near enough to choose between two inks.
        (0.299 * red + 0.587 * green + 0.114 * blue) > 0.6 ? .black : .white
    }
}

/// Drawing annotations: once into the overlay while they are being made, and
/// once into the image that is saved. One routine for both, so the picture
/// that comes out is the one that was on screen.
enum ShotRenderer {
    static let lineWidth: CGFloat = 3
    static let numberRadius: CGFloat = 11
    static let arrowHead: CGFloat = 14
    /// The gap between a numbered marker and the caption typed after it.
    static let captionGap: CGFloat = 6

    static let textFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    static let numberFont = NSFont.systemFont(ofSize: 13, weight: .bold)

    /// Where a marker's caption starts, given the marker's centre.
    static func captionOrigin(forNumberAt center: CGPoint) -> CGPoint {
        let height = textFont.ascender - textFont.descender
        return CGPoint(x: center.x + numberRadius + captionGap, y: center.y - height / 2)
    }

    /// Draw into the current graphics context, which must be flipped (origin
    /// at the top left) and in the overlay's points.
    static func draw(_ annotations: [ShotAnnotation]) {
        for annotation in annotations { draw(annotation) }
    }

    static func draw(_ annotation: ShotAnnotation) {
        switch annotation {
        case let .rect(rect, color):
            color.nsColor.setStroke()
            let path = NSBezierPath(rect: rect.standardized)
            path.lineWidth = lineWidth
            path.lineJoinStyle = .miter
            path.stroke()

        case let .arrow(from, to, color):
            drawArrow(from: from, to: to, color: color.nsColor)

        case let .pen(points, color):
            guard points.count >= 2 else { return }
            color.nsColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.stroke()

        case let .text(at, text, color):
            drawText(text, at: at, color: color.nsColor)

        case let .number(n, at, text, color):
            color.nsColor.setFill()
            NSBezierPath(ovalIn: CGRect(
                x: at.x - numberRadius, y: at.y - numberRadius,
                width: numberRadius * 2, height: numberRadius * 2)).fill()

            let label = NSAttributedString(string: "\(n)", attributes: [
                .font: numberFont,
                .foregroundColor: color.inkColor,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: at.x - size.width / 2, y: at.y - size.height / 2))

            if !text.isEmpty {
                drawText(text, at: captionOrigin(forNumberAt: at), color: color.nsColor)
            }
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, color: NSColor) {
        // A thin dark edge, so that white text on a white page and red text
        // on a red button can both be read.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        NSAttributedString(string: text, attributes: [
            .font: textFont,
            .foregroundColor: color,
            .shadow: shadow,
        ]).draw(at: point)
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: NSColor) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= 1 else { return }
        let ux = dx / length, uy = dy / length
        let head = min(arrowHead, length)
        // The shaft stops where the head begins, so its square end does not
        // poke through the point.
        let neck = CGPoint(x: to.x - ux * head, y: to.y - uy * head)

        color.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: neck)
        shaft.stroke()

        color.setFill()
        let half = head * 0.45
        let tip = NSBezierPath()
        tip.move(to: to)
        tip.line(to: CGPoint(x: neck.x - uy * half, y: neck.y + ux * half))
        tip.line(to: CGPoint(x: neck.x + uy * half, y: neck.y - ux * half))
        tip.close()
        tip.fill()
    }

    /// The selection cut out of the frozen display, with the annotations
    /// drawn on it, at the display's own pixel size.
    static func composite(
        display: ShotDisplay,
        selection: CGRect,
        annotations: [ShotAnnotation]
    ) -> (image: CGImage, pixels: CGRect)? {
        let scale = display.scale
        let pixels = ShotGeometry.pixelRect(selection, scale: scale, imageSize: display.imageSize)
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = display.image.cropping(to: pixels) else { return nil }

        let width = Int(pixels.width), height = Int(pixels.height)
        let space = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) ?? CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        if !annotations.isEmpty {
            // From here the context is the overlay's: origin top left, in
            // points, moved so the selection's corner is the image's.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -pixels.minX / scale, y: -pixels.minY / scale)

            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            draw(annotations)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let image = context.makeImage() else { return nil }
        return (image, pixels)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
