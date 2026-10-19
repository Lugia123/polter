import AppKit
import CoreImage

/// The project mark in a window tab's accessory stack (task 1796): the two
/// pages of `ProjectMark.shapes` in the project's colour, and its glow laid
/// on with screen.
///
/// **Two layers, and neither is a shadow.** The glow is a premultiplied
/// image of the project's colour with `ProjectMark.glow` as its alpha, in a
/// layer reaching `ProjectMark.reach` points past the view on every side,
/// composited with `CIScreenBlendMode` onto what is behind it. With
/// premultiplied colour `S = c * a`, screen is `D + S - S * D`, which is
/// `D + (screen(D, c) - D) * a`: the design's formula, never darker than the
/// tab. The pages are a second layer over it, at the state's strength as
/// its opacity, which mixes them toward whatever the tab's ground is.
///
/// A project of no colour (none given yet) is drawn as the mark was before
/// colours: the pages in the secondary label colour, no glow.
final class ProjectMarkView: NSView {
    /// The project's colour; `.none` for a project that has none yet.
    var color: PaneColor = .none {
        didSet { if color != oldValue { redraw() } }
    }

    /// Whether this tab is the one in front of its window.
    var selected = false {
        didSet { if selected != oldValue { redraw() } }
    }

    private let glowLayer = CALayer()
    private let pagesLayer = CALayer()

    /// Everything a drawing is made from. The layers are drawn again only
    /// when one of these changed (task 1873): a tab's layout asks on every
    /// pass -- each time its window's title changes, which an agent's
    /// spinner does several times a second -- and every drawing was two new
    /// images handed to the window server.
    struct Inputs: Equatable {
        var side: CGFloat
        var scale: CGFloat
        var color: PaneColor
        var selected: Bool
        var appearance: NSAppearance.Name
    }

    /// What the layers were last drawn from; nil before the first drawing.
    private var drawnFrom: Inputs?
    /// How many times the layers have been drawn. For the tests.
    private(set) var drawings = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        glowLayer.compositingFilter = CIFilter(name: "CIScreenBlendMode")
        layer?.addSublayer(glowLayer)
        layer?.addSublayer(pagesLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    private var dark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func redraw() {
        let side = bounds.width
        guard side > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let inputs = Inputs(side: side, scale: scale, color: color, selected: selected,
                            appearance: effectiveAppearance.name)
        guard inputs != drawnFrom else { return }
        drawnFrom = inputs
        drawings += 1
        WindowOpsTally.count(.markRedraw)
        // The artboard drawn into the view's square.
        let unit = Double(side) / ControlRoomLook.Status.artboard
        let pixelsPerPoint = Double(scale) * unit
        let ink: CGColor
        let opacity: Double
        if let c = color.dot(ControlRoomLook.theme(dark: dark)) {
            ink = CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
            opacity = ProjectMark.strength(selected ? .selected : .rest, dark: dark)
        } else {
            var resolved = NSColor.secondaryLabelColor.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { resolved = NSColor.secondaryLabelColor.cgColor }
            ink = resolved
            opacity = 1
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pagesLayer.frame = bounds
        pagesLayer.contentsScale = scale
        pagesLayer.contents = Self.pages(ink: ink, pixels: Int((Double(side) * Double(scale)).rounded()))
        pagesLayer.opacity = Float(opacity)

        if color == .none {
            glowLayer.contents = nil
        } else {
            let glow = Self.glow(scale: pixelsPerPoint, strength: opacity)
            let reach = CGFloat(glow.reach * unit)
            glowLayer.frame = bounds.insetBy(dx: -reach, dy: -reach)
            glowLayer.contentsScale = scale
            glowLayer.contentsGravity = .resize
            glowLayer.contents = Self.glowImage(glow, ink: ink)
        }
        CATransaction.commit()
    }

    /// `ProjectMark.glow`, worked out once for each scale and strength: a
    /// tab's layout asks again on every pass, and the answer never changes.
    private static var glows: [String: ProjectMark.Glow] = [:]
    private static func glow(scale: Double, strength: Double) -> ProjectMark.Glow {
        let key = "\(scale) \(strength)"
        if let known = glows[key] { return known }
        let made = ProjectMark.glow(scale: scale, strength: strength)
        glows[key] = made
        return made
    }

    /// The pages, `pixels` a side, in `ink`.
    private static func pages(ink: CGColor, pixels: Int) -> CGImage? {
        guard pixels > 0, let ctx = context(pixels) else { return nil }
        let unit = CGFloat(pixels) / CGFloat(ControlRoomLook.Status.artboard)
        ctx.setFillColor(ink)
        for s in ProjectMark.shapes {
            // The artboard runs down from its top; a bitmap context runs up.
            let rect = CGRect(
                x: s.x * unit, y: CGFloat(pixels) - (s.y + s.h) * unit,
                width: s.w * unit, height: s.h * unit)
            let r = min(s.radius * unit, rect.width / 2, rect.height / 2)
            ctx.setBlendMode(s.level > 0 ? .normal : .clear)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    /// `glow` as a premultiplied image of `ink`, row 0 at the top.
    private static func glowImage(_ glow: ProjectMark.Glow, ink: CGColor) -> CGImage? {
        let n = glow.side
        guard n > 0, let rgb = ink.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = rgb.components, comps.count >= 3
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let a = glow.at(x, y)
                let i = (y * n + x) * 4
                bytes[i] = UInt8((Double(comps[0]) * a * 255).rounded())
                bytes[i + 1] = UInt8((Double(comps[1]) * a * 255).rounded())
                bytes[i + 2] = UInt8((Double(comps[2]) * a * 255).rounded())
                bytes[i + 3] = UInt8((a * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func context(_ pixels: Int) -> CGContext? {
        CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
