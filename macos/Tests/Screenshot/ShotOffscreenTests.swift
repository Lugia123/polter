import AppKit
import Foundation
import Testing
@testable import Ghostty

/// A made-up frozen screen and a session over it, painted into a bitmap:
/// what the product draws, without a window, without the screen being
/// recorded and without anybody touching the mouse.
///
/// The picture is half a light page and half a dark terminal, with a few
/// blocks of colour and one hard black-to-white edge, which is what the
/// criteria of `dev-docs/poltergeist/screenshot.md`, 9.8.13, are read off.
///
/// Set `SHOT_RENDER_DIR` and every scene is also written there as a PNG, to
/// be put beside the mock-ups.
///
/// On the main thread, like everything that uses it: the text box is an
/// AppKit text view, and AppKit makes a window of its own the first time a
/// text view's selection moves.
@MainActor
final class ShotStage {
    let scale: Double
    /// Pixels.
    let width: Int
    let height: Int
    let frozen: [UInt8]
    let session: ShotSession
    /// The session's clock; moved on by hand.
    private(set) var now: TimeInterval = 100

    /// Two windows of the made-up screen, in points.
    static let light = CGRect(x: 40, y: 40, width: 520, height: 420)
    static let dark = CGRect(x: 620, y: 80, width: 540, height: 460)

    struct NoScreen: Error {}

    init(
        scale: Double = 2, points: CGSize = CGSize(width: 1200, height: 700), access: ShotChrome.Access? = nil
    ) throws {
        self.scale = scale
        width = Int(points.width * scale)
        height = Int(points.height * scale)
        frozen = Self.picture(width: width, height: height, scale: scale)
        guard let screen = NSScreen.screens.first,
              let picture = ShotBlur.Picture(width: width, height: height, rgbx: frozen),
              let image = ShotRenderer.image(of: picture) else { throw NoScreen() }
        let display = ShotDisplay(screen: screen, image: image, frame: CGRect(origin: .zero, size: points))
        let windows = [
            ShotWindow(id: 1, frame: Self.light, app: "Notes", title: "Page", pid: 1),
            ShotWindow(id: 2, frame: Self.dark, app: "Terminal", title: "zsh", pid: 2),
        ]
        guard let session = ShotSession(
            displays: [display], windows: windows, prefs: ToolPrefs(), blurWait: 60,
            access: access) else {
            throw NoScreen()
        }
        self.session = session
        session.clock = { [unowned self] in self.now }
        session.settleFocus()
    }

    /// Let `seconds` go by.
    func wait(_ seconds: TimeInterval) { now += seconds }

    // MARK: The made-up screen

    private static func picture(width: Int, height: Int, scale: Double) -> [UInt8] {
        var p = [UInt8](repeating: 255, count: width * height * 4)
        func fill(_ r: CGRect, _ c: (UInt8, UInt8, UInt8)) {
            let x0 = max(Int(r.minX * scale), 0), x1 = min(Int(r.maxX * scale), width)
            let y0 = max(Int(r.minY * scale), 0), y1 = min(Int(r.maxY * scale), height)
            guard x0 < x1, y0 < y1 else { return }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    p[i] = c.0
                    p[i + 1] = c.1
                    p[i + 2] = c.2
                }
            }
        }
        // A wallpaper that is neither light nor dark.
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                p[i] = UInt8(58 + 120 * x / width)
                p[i + 1] = UInt8(70 + 20 * y / height)
                p[i + 2] = UInt8(200 - 90 * y / height)
            }
        }
        // A light page: a heading, lines of text, a chart, a picture.
        fill(light, (255, 255, 255))
        fill(CGRect(x: 64, y: 64, width: 220, height: 18), (32, 35, 42))
        for row in 0..<7 {
            fill(CGRect(x: 64, y: 100 + CGFloat(row) * 14, width: CGFloat(300 + (row * 53) % 150), height: 5), (120, 126, 138))
        }
        let bars: [(CGFloat, (UInt8, UInt8, UInt8))] = [
            (30, (0x2F, 0x6F, 0xED)), (56, (0x2F, 0x6F, 0xED)), (42, (0x17, 0xB5, 0xC8)), (80, (0xF5, 0x82, 0x1F)),
            (64, (0xE6, 0x28, 0x28)), (96, (0x2D, 0xB8, 0x4D)), (70, (0xFF, 0xD4, 0x00)),
        ]
        for (n, bar) in bars.enumerated() {
            fill(CGRect(x: 70 + CGFloat(n) * 22, y: 330 - bar.0, width: 16, height: bar.0), bar.1)
        }
        fill(CGRect(x: 300, y: 230, width: 220, height: 100), (0x17, 0xB5, 0xC8))
        fill(CGRect(x: 380, y: 230, width: 140, height: 100), (0x2D, 0xB8, 0x4D))
        fill(CGRect(x: 460, y: 230, width: 60, height: 100), (0xFF, 0xD4, 0x00))
        // A dark terminal: lines of coloured text.
        fill(dark, (22, 24, 29))
        let inks: [(UInt8, UInt8, UInt8)] = [(201, 209, 217), (255, 123, 114), (165, 214, 255), (63, 185, 80), (227, 179, 65)]
        for row in 0..<22 {
            var x: CGFloat = 640
            for word in 0..<6 {
                let w = CGFloat(20 + ((row * 31 + word * 17) % 70))
                fill(CGRect(x: x, y: 100 + CGFloat(row) * 18, width: w, height: 7), inks[(row + word) % inks.count])
                x += w + 10
                if x > 1120 { break }
            }
        }
        // One hard edge, black to white, on the wallpaper below both windows.
        fill(CGRect(x: 100, y: 580, width: 300, height: 90), (0, 0, 0))
        fill(CGRect(x: 400, y: 580, width: 300, height: 90), (255, 255, 255))
        return p
    }

    // MARK: Painting

    /// The display as the session paints it now: R, G, B, A rows from the
    /// top.
    func paint(only dirty: CGRect? = nil) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // The view's coordinates: points, from the top left.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            // What a view does with the rectangle it was asked to paint.
            if let dirty { ctx.clip(to: dirty) }
            session.draw(display: 0, in: ctx)
        }
        layTextBox(over: &out)
        return out
    }

    /// The text box is a view of its own, over the overlay: paint it over
    /// what the overlay painted, the way the window would.
    private func layTextBox(over out: inout [UInt8]) {
        guard let box = session.textBoxView else { return }
        let w = Int((box.bounds.width * scale).rounded()), h = Int((box.bounds.height * scale).rounded())
        guard w > 0, h > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32) else { return }
        rep.size = box.bounds.size
        box.cacheDisplay(in: box.bounds, to: rep)
        guard let data = rep.bitmapData else { return }
        let left = Int((box.frame.minX * scale).rounded()), top = Int((box.frame.minY * scale).rounded())
        for y in 0..<h {
            let ty = top + y
            guard ty >= 0, ty < height else { continue }
            for x in 0..<w {
                let tx = left + x
                guard tx >= 0, tx < width else { continue }
                let p = (y * w + x) * 4, d = (ty * width + tx) * 4
                let a = Int(data[p + 3])
                guard a > 0 else { continue }
                // Premultiplied over opaque.
                for c in 0..<3 { out[d + c] = UInt8(min(Int(data[p + c]) + Int(out[d + c]) * (255 - a) / 255, 255)) }
            }
        }
    }

    /// Paint, and write `name`.png when `SHOT_RENDER_DIR` is set.
    @discardableResult
    func shot(_ name: String) -> [UInt8] {
        let pixels = paint()
        if let dir = ProcessInfo.processInfo.environment["SHOT_RENDER_DIR"], !dir.isEmpty {
            Self.write(pixels, width: width, height: height, to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        return pixels
    }

    static func write(_ pixels: [UInt8], width: Int, height: Int, to url: URL) {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    // MARK: Reading

    /// The colour at a point, given in points.
    func at(_ pixels: [UInt8], _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
        let i = (Int(y * scale) * width + Int(x * scale)) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    /// Whether `pixels` is the frozen picture at a point, to the byte.
    func isFrozen(_ pixels: [UInt8], _ x: Double, _ y: Double) -> Bool {
        let i = (Int(y * scale) * width + Int(x * scale)) * 4
        return pixels[i] == frozen[i] && pixels[i + 1] == frozen[i + 1] && pixels[i + 2] == frozen[i + 2]
    }

    /// How many pixels of the rectangle (in points) differ from the frozen
    /// picture.
    func differing(_ pixels: [UInt8], in r: CGRect) -> Int {
        var n = 0
        // The magnifier hangs beside the pointer while a region is being
        // chosen, over whatever is there: it is furniture, not the picture
        // these are asked about.
        let m = ShotChrome.margins(scale: scale)
        let furniture = session.magnifierPlate(on: 0).map {
            PixelRect(left: $0.x - m.x, top: $0.y - m.top, right: $0.right + m.x, bottom: $0.bottom + m.bottom)
        }
        for y in Int(r.minY * scale)..<Int(r.maxY * scale) {
            for x in Int(r.minX * scale)..<Int(r.maxX * scale) {
                if let furniture, furniture.contains(PixelPoint(x, y)) { continue }
                let i = (y * width + x) * 4
                if pixels[i] != frozen[i] || pixels[i + 1] != frozen[i + 1] || pixels[i + 2] != frozen[i + 2] { n += 1 }
            }
        }
        return n
    }

    // MARK: The mouse

    func move(_ x: Double, _ y: Double) {
        session.pointerMove(to: CGPoint(x: x, y: y), on: 0, mods: [])
    }

    func press(_ x: Double, _ y: Double) {
        session.pointerDown(at: CGPoint(x: x, y: y), on: 0, mods: [], double: false)
    }

    func release(_ x: Double, _ y: Double) {
        session.pointerUp(at: CGPoint(x: x, y: y), on: 0)
    }

    /// The middle of a toolbar button, in points.
    func middle(of button: ToolbarButton) throws -> (Double, Double) {
        let layout = try #require(session.editor.layout)
        let r = try #require(layout.rect(of: button))
        return ((Double(r.x) + Double(r.w) / 2) / scale, (Double(r.y) + Double(r.h) / 2) / scale)
    }

    /// Press a toolbar button and let go of it.
    func click(_ button: ToolbarButton) throws {
        let p = try middle(of: button)
        move(p.0, p.1)
        press(p.0, p.1)
        release(p.0, p.1)
    }

    /// A toolbar button's rectangle in the bitmap's pixels.
    func cell(_ button: ToolbarButton) throws -> PixelRect {
        let layout = try #require(session.editor.layout)
        return try #require(layout.rect(of: button))
    }

    /// Press at one point, move through the others, let go at the last.
    func drag(_ points: [(Double, Double)]) {
        guard let first = points.first, let last = points.last else { return }
        press(first.0, first.1)
        for p in points.dropFirst() { move(p.0, p.1) }
        release(last.0, last.1)
    }
}

/// What is sharp and what is not (9.8.6, 9.8.7, 9.8.8; criteria 9.8.13 D).
@MainActor
struct ShotOffscreenVeilTests {
    @Test func theWindowUnderThePointerIsSharpAndTheRestIsNot() throws {
        let stage = try ShotStage()
        // However it was started, nothing is selected for it: the window
        // under the pointer is in focus, and a click is what selects it (3.1).
        #expect(stage.session.editor.selection == nil)
        stage.move(900, 300)
        stage.wait(1)
        #expect(stage.session.editor.selection == nil)
        let p = stage.shot("a1-hover-dark-window")
        // Inside the dark window: the frozen picture, to the byte. The two
        // points of border inside its edge are the accent's.
        let inside = ShotStage.dark.insetBy(dx: 4, dy: 4)
        #expect(stage.differing(p, in: inside) == 0)
        // The light window is out of focus: its heading is no longer a
        // hard-edged bar, and white is darker by the data.
        #expect(stage.differing(p, in: ShotStage.light.insetBy(dx: 4, dy: 4)) > 1000)
        let white = stage.at(p, 500, 420)
        let want = Int((255 * (1 - ShotLook.Colour.outsideDim.a)).rounded())
        #expect(abs(white.r - want) <= 2 && abs(white.g - want) <= 2 && abs(white.b - want) <= 2, "white reads \(white)")

        // Over to the light window: the sharp part follows.
        stage.move(300, 200)
        stage.wait(1)
        let q = stage.shot("a2-hover-light-window")
        #expect(stage.differing(q, in: ShotStage.light.insetBy(dx: 4, dy: 4)) == 0)
        #expect(stage.differing(q, in: ShotStage.dark.insetBy(dx: 4, dy: 4)) > 1000)
    }

    @Test func overNoWindowTheWholeDisplayIsSharp() throws {
        let stage = try ShotStage()
        stage.move(1180, 20)
        stage.wait(1)
        let p = stage.shot("a3-no-window")
        #expect(stage.differing(p, in: CGRect(x: 0, y: 0, width: 1200, height: 700)) == 0)
    }

    @Test func aWindowComesIntoFocusOverTheTimeTheDataGives() throws {
        let stage = try ShotStage()
        stage.move(1180, 20)
        stage.wait(1)
        stage.move(900, 300)
        // Half way: the terminal's ground is between its sharp and its
        // out-of-focus self, and the display around it is going out of focus.
        let ground = (640.0 + 400, 520.0)
        stage.wait(ShotLook.TransitionMs.windowSwitch / 2000)
        let half = stage.at(stage.paint(), 30, 600)
        stage.wait(ShotLook.TransitionMs.windowSwitch / 1000)
        let done = stage.paint()
        let frozen = stage.at(stage.frozen, 30, 600)
        let soft = stage.at(done, 30, 600)
        #expect(soft != frozen, "the wallpaper beside the edge is out of focus at the end")
        // The half-way colour is between the two, not equal to either.
        #expect(half != frozen && half != soft, "half way reads \(half), ends \(frozen) and \(soft)")
        #expect(stage.isFrozen(done, ground.0, ground.1))
    }

    @Test func aSelectionIsSharpOnEveryFrameOfItsDrag() throws {
        let stage = try ShotStage()
        stage.move(700, 200)
        stage.wait(1)
        stage.press(700, 200)
        // Each frame of the drag, painted the moment the mouse moved: what
        // is inside the rectangle is the frozen picture, to the byte, and
        // the corner the mouse came from is not still sharp.
        for (n, to) in [(760.0, 240.0), (900.0, 330.0), (1100.0, 500.0)].enumerated() {
            stage.move(to.0, to.1)
            let p = stage.shot("a4-drag-\(n + 1)")
            let region = CGRect(x: 700, y: 200, width: to.0 - 700, height: to.1 - 200)
            #expect(stage.differing(p, in: region.insetBy(dx: 2, dy: 2)) == 0, "frame \(n + 1)")
        }
        stage.release(1100, 500)
        stage.wait(1)
        let p = stage.shot("a5-selection")
        // (Six points in: the selection's handles reach that far.)
        #expect(stage.differing(p, in: CGRect(x: 706, y: 206, width: 388, height: 288)) == 0)
        // Outside: the hard edge is soft. Its 10%-90% width is about 2.56
        // sigma -- 15 px at scale 2 -- and it is still centred on x = 400 pt.
        let row = (0..<stage.width).map { stage.at(p, Double($0) / stage.scale, 625).r }
        let white = Int((255 * (1 - ShotLook.Colour.outsideDim.a)).rounded())
        let low = (300..<1000).first { row[$0] >= white / 10 }!
        let high = (300..<1000).first { row[$0] >= white * 9 / 10 }!
        #expect((12...20).contains(high - low), "the edge is \(high - low) px wide")
        #expect(abs((low + high) / 2 - 800) <= 2)
        #expect(stage.at(p, 150, 625).r == 0)
        #expect(abs(stage.at(p, 650, 625).r - white) <= 2)
    }

    @Test func movingASelectionLeavesNothingBehind() throws {
        let stage = try ShotStage()
        stage.move(700, 200)
        stage.drag([(700, 200), (900, 400)])
        stage.wait(1)
        // Pick it up by its middle and carry it left.
        stage.press(800, 300)
        stage.move(600, 300)
        let p = stage.paint()
        // Where it is now is sharp...
        #expect(stage.differing(p, in: CGRect(x: 504, y: 204, width: 192, height: 192)) == 0)
        // ...and the part of where it was that it no longer covers is not.
        #expect(stage.differing(p, in: CGRect(x: 760, y: 204, width: 130, height: 192)) > 1000)
        stage.release(600, 300)
    }
}

/// The toolbar as the product paints it (9.8.2 to 9.8.4; criteria 9.8.13 B
/// and C).
@MainActor
struct ShotOffscreenToolbarTests {
    /// A selection over the light page, or over the dark terminal, with the
    /// pointer parked inside it.
    private func stage(dark: Bool, access: ShotChrome.Access? = nil) throws -> ShotStage {
        let stage = try ShotStage(access: access)
        if dark {
            stage.move(660, 110)
            stage.drag([(660, 110), (1120, 330)])
        } else {
            stage.move(60, 60)
            stage.drag([(60, 60), (540, 300)])
        }
        park(stage, dark: dark)
        return stage
    }

    /// Take the pointer off the toolbar and let every fade finish.
    private func park(_ stage: ShotStage, dark: Bool) {
        stage.move(dark ? 1000 : 400, dark ? 140 : 90)
        stage.wait(1)
    }

    /// A point of a cell that its content does not reach: six pixels in
    /// from its top left corner.
    private func blank(_ stage: ShotStage, _ pixels: [UInt8], _ button: ToolbarButton) throws -> (r: Int, g: Int, b: Int) {
        let r = try stage.cell(button)
        return stage.at(pixels, Double(r.x + 6) / stage.scale, Double(r.y + 6) / stage.scale)
    }

    private func pixel(_ stage: ShotStage, _ pixels: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        stage.at(pixels, Double(x) / stage.scale, Double(y) / stage.scale)
    }

    @Test func theScenesOfTheMockUps() throws {
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            // Arrow selected, rectangle hovered, nothing to undo; the
            // colours and the five thicknesses; the hover text.
            var s = try stage(dark: dark)
            try s.click(.tool(.arrow))
            park(s, dark: dark)
            let rect = try s.middle(of: .tool(.rect))
            s.move(rect.0, rect.1)
            s.wait(1)
            s.shot("b1-\(name)-arrow-selected-rect-hovered")

            // Two rectangles drawn; number selected with the blue and the
            // fourth size; undo held down; then done hovered.
            s = try stage(dark: dark)
            try s.click(.tool(.rect))
            s.drag([(dark ? 700 : 100, dark ? 150 : 100), (dark ? 800 : 200, dark ? 220 : 170)])
            s.drag([(dark ? 840 : 240, dark ? 150 : 100), (dark ? 940 : 340, dark ? 220 : 170)])
            #expect(s.session.editor.items.count == 2)
            try s.click(.tool(.number))
            park(s, dark: dark)
            try s.click(.colour(5))
            park(s, dark: dark)
            try s.click(.level(3))
            park(s, dark: dark)
            let undo = try s.middle(of: .undo)
            s.move(undo.0, undo.1)
            s.wait(1)
            s.press(undo.0, undo.1)
            s.shot("b2-\(name)-number-blue-size4-undo-down")
            s.release(undo.0, undo.1)
            let done = try s.middle(of: .done)
            s.move(done.0, done.1)
            s.wait(1)
            s.shot("b3-\(name)-done-hovered")
            // Held down it is solid; nothing has happened yet, and sliding
            // off it before letting go takes the press back.
            s.press(done.0, done.1)
            s.shot("b7-\(name)-done-down")
            s.move(done.0, done.1 - 120)
            s.release(done.0, done.1 - 120)

            // The mosaic's five block sizes.
            s = try stage(dark: dark)
            try s.click(.tool(.mosaic))
            park(s, dark: dark)
            s.shot("b4-\(name)-mosaic")

            // With transparency reduced: opaque plates, no glow, and the
            // outside only darkened.
            s = try stage(dark: dark, access: .init(opaque: true))
            try s.click(.tool(.pen))
            park(s, dark: dark)
            try s.click(.colour(3))
            park(s, dark: dark)
            s.shot("b6-\(name)-transparency-reduced")
        }
    }

    @Test func thePlateIsDarkGlassWhateverIsUnderIt() throws {
        // 9.8.3: between two extremes -- about #3E4041 over white and
        // #131415 over black -- so the white ink always reads.
        var grounds: [Int] = []
        for dark in [false, true] {
            let s = try stage(dark: dark)
            let p = s.paint()
            // The gap before "undo": plate and nothing else, and over the
            // window rather than the wallpaper beside it.
            let cell = try s.cell(.undo)
            let c = pixel(s, p, cell.x - 8, cell.y + 28)
            #expect((0x10...0x48).contains(c.r) && (0x10...0x4A).contains(c.g) && (0x10...0x4C).contains(c.b), "\(c)")
            grounds.append(c.r + c.g + c.b)
            // An icon's ink is white. (Not the select tool's: it is the
            // current tool, and its ink is the accent.)
            let cross = try s.cell(.cancel)
            let ink = (cross.x..<cross.right).map { pixel(s, p, $0, cross.y + 28) }.map(\.r).max()!
            #expect(ink >= 250, "the cancel icon's brightest pixel is \(ink)")
        }
        // It is glass, not paint: what is under it shows. Under the light
        // page it is lighter than under the dark terminal, and under the
        // terminal it is darker than the opaque plate would be.
        #expect(grounds[0] >= grounds[1] + 24, "\(grounds)")
        let opaque = ShotLook.Colour.plateOpaque
        #expect(grounds[1] < Int(opaque.r) + Int(opaque.g) + Int(opaque.b) - 24, "\(grounds)")
    }

    @Test func aSelectedCellHasTheRingAndEveryKindHasTheSameOne() throws {
        let s = try stage(dark: true)
        try s.click(.tool(.rect))
        park(s, dark: true)
        let p = s.paint()
        let accent = ShotLook.Colour.accent
        // The tool, the colour and the step that are current: each has
        // three pixels of the accent on its left edge, half way down.
        for button in [ToolbarButton.tool(.rect), .colour(0), .level(1)] {
            let r = try s.cell(button)
            for dx in 0..<3 {
                let c = pixel(s, p, r.x + dx, r.y + r.h / 2)
                #expect(abs(c.r - Int(accent.r)) <= 8 && abs(c.g - Int(accent.g)) <= 8 && abs(c.b - Int(accent.b)) <= 8,
                        "\(button) at +\(dx): \(c)")
            }
            // The fourth pixel in is not the ring.
            let inside = pixel(s, p, r.x + 4, r.y + r.h / 2)
            #expect(abs(inside.r - Int(accent.r)) > 8 || abs(inside.b - Int(accent.b)) > 8, "\(button): \(inside)")
        }
        // A cell that is not current has none.
        let other = try s.cell(.tool(.ellipse))
        let plain = pixel(s, p, other.x + 1, other.y + other.h / 2)
        #expect(plain.b < 0x80, "\(plain)")
        // The red swatch is still red, and round: its middle, not its
        // cell's corner.
        let red = try s.cell(.colour(0))
        let middle = pixel(s, p, red.x + red.w / 2, red.y + red.h / 2)
        #expect(middle.r == 0xE6 && middle.g == 0x28 && middle.b == 0x28)
        #expect(pixel(s, p, red.x + 8, red.y + 8).r < 0x80)
    }

    @Test func hoverLightensWithoutBlueAndAPressIsBlue() throws {
        let s = try stage(dark: true)
        let before = s.paint()
        let at = try s.middle(of: .tool(.ellipse))
        s.move(at.0, at.1)
        s.wait(1)
        let hover = s.paint()
        // The middle of the ellipse's cell: inside the ellipse, where there
        // is no ink, and far enough from the cell's edge that a ring's glow
        // does not reach.
        let r = try s.cell(.tool(.ellipse))
        func middle(_ pixels: [UInt8]) -> (r: Int, g: Int, b: Int) { pixel(s, pixels, r.x + r.w / 2, r.y + r.h / 2) }
        let b0 = middle(before), b1 = middle(hover)
        let up = (b1.r - b0.r, b1.g - b0.g, b1.b - b0.b)
        #expect((15...45).contains(up.0), "lighter by \(up)")
        #expect(abs(up.0 - up.1) <= 6 && abs(up.0 - up.2) <= 6, "and by the same in every channel: \(up)")
        // Two pixels outside the cell nothing changed: there is no glow.
        #expect(pixel(s, hover, r.x - 2, r.y + 28) == pixel(s, before, r.x - 2, r.y + 28))
        // And its name is under the toolbar, where there was none.
        let plate = try #require(s.session.editor.layout).plate
        var named = 0
        for y in plate.bottom..<(plate.bottom + 160) {
            for x in r.x..<(r.x + 120) where pixel(s, hover, x, y) != pixel(s, before, x, y) { named += 1 }
        }
        #expect(named > 500, "\(named) pixels of hover text")

        // Held down: the ring, and the ground tinted with the accent.
        s.press(at.0, at.1)
        let down = s.paint()
        let b2 = middle(down)
        #expect((b2.b - b0.b) - (b2.r - b0.r) >= 15, "bluer by \((b2.r - b0.r, b2.g - b0.g, b2.b - b0.b))")
        let ring = pixel(s, down, r.x + 1, r.y + 28)
        #expect(abs(ring.b - 255) <= 8 && abs(ring.r - Int(ShotLook.Colour.accent.r)) <= 8)
        s.release(at.0, at.1)

        // Let go and wait: it is the tool now -- the ring stays, the tint
        // goes, the hover's fill is back.
        s.wait(1)
        let after = s.paint()
        let b3 = middle(after)
        #expect(abs((b3.b - b0.b) - (b3.r - b0.r)) <= 6, "no tint left: \(b3) from \(b0)")
        #expect(abs(pixel(s, after, r.x + 1, r.y + 28).b - 255) <= 8)
    }

    @Test func aCellLightsUpOverTheTimeTheDataGives() throws {
        let s = try stage(dark: true)
        let r = try s.cell(.tool(.ellipse))
        func middle() -> Int { pixel(s, s.paint(), r.x + r.w / 2, r.y + r.h / 2).r }
        let rest = middle()
        let at = try s.middle(of: .tool(.ellipse))
        s.move(at.0, at.1)
        #expect(middle() == rest, "on the frame the pointer arrives nothing has changed yet")
        s.wait(ShotLook.TransitionMs.hoverIn / 2000)
        let half = middle()
        s.wait(1)
        let full = middle()
        #expect(full > rest + 15)
        #expect(half > rest + 4 && half < full - 4, "half way: \(rest), \(half), \(full)")
        // Leaving takes longer than arriving.
        s.move(1000, 140)
        s.wait(ShotLook.TransitionMs.hoverIn / 1000)
        #expect(middle() > rest + 2, "still fading after the time it took to arrive")
        s.wait(1)
        #expect(middle() == rest)
    }

    @Test func aButtonThatCannotBePressedDoesNotAnswerThePointer() throws {
        let s = try stage(dark: false)
        let before = s.paint()
        // Nothing to undo.
        let undo = try s.middle(of: .undo)
        s.move(undo.0, undo.1)
        s.wait(1)
        let hover = s.paint()
        #expect(hover == before, "hovering it changes nothing, hover text included")
        s.press(undo.0, undo.1)
        #expect(s.paint() == before, "nor does pressing it")
        s.release(undo.0, undo.1)
        // Its icon is there, and fainter than its neighbour's.
        let off = try s.cell(.undo), on = try s.cell(.long)
        let faint = (off.x..<off.right).map { pixel(s, before, $0, off.y + 20).r }.max()!
        let full = (on.x..<on.right).map { pixel(s, before, $0, on.y + 20).r }.max()!
        #expect(faint < full - 60, "\(faint) and \(full)")
    }

    @Test func doneAndCancelAreAsQuietAsTheRest() throws {
        let s = try stage(dark: true)
        let p = s.paint()
        let done = try blank(s, p, .done), cancel = try blank(s, p, .cancel), long = try blank(s, p, .long)
        #expect(abs(done.b - cancel.b) <= 6 && abs(done.b - long.b) <= 6, "\(done) \(cancel) \(long)")
        #expect(done.b < 0x60, "not a solid accent button: \(done)")
    }

    private final class Ending: ShotSessionDelegate {
        var cancelled = 0
        var finished = 0
        func sessionDidCancel(_ session: ShotSession) { cancelled += 1 }
        func sessionDidFinish(_ session: ShotSession, with result: ShotSession.Result) { finished += 1 }
    }

    @Test func cancelAndDoneActWhenTheyAreLetGoOverThemselves() throws {
        // 9.8.4: pressed, they only show it.
        let s = try stage(dark: true)
        let ending = Ending()
        s.session.delegate = ending
        let done = try s.middle(of: .done), cancel = try s.middle(of: .cancel)
        s.move(done.0, done.1)
        s.wait(1)
        s.press(done.0, done.1)
        #expect(ending.finished == 0, "holding it down is not finishing")
        let r = try s.cell(.done)
        let held = pixel(s, s.paint(), r.x + 8, r.y + 8)
        let accent = ShotLook.Colour.accent
        #expect(abs(held.r - Int(accent.r)) <= 8 && abs(held.b - Int(accent.b)) <= 8, "solid while held: \(held)")
        // Slid off and let go: nothing.
        s.move(cancel.0, cancel.1 - 200)
        s.release(cancel.0, cancel.1 - 200)
        #expect(ending.finished == 0 && ending.cancelled == 0)
        // Pressed on one and let go on the other: nothing either.
        s.move(done.0, done.1)
        s.press(done.0, done.1)
        s.move(cancel.0, cancel.1)
        s.release(cancel.0, cancel.1)
        #expect(ending.finished == 0 && ending.cancelled == 0)
        // Pressed and let go on itself: done.
        s.move(done.0, done.1)
        s.press(done.0, done.1)
        s.release(done.0, done.1)
        #expect(ending.finished == 1 && ending.cancelled == 0)

        // And cancel the same way.
        let t = try stage(dark: true)
        let other = Ending()
        t.session.delegate = other
        let x = try t.middle(of: .cancel)
        t.move(x.0, x.1)
        t.press(x.0, x.1)
        #expect(other.cancelled == 0)
        t.release(x.0, x.1)
        #expect(other.cancelled == 1 && other.finished == 0)

        // Every other button acts on the press.
        let u = try stage(dark: true)
        let rect = try u.middle(of: .tool(.rect))
        u.move(rect.0, rect.1)
        u.press(rect.0, rect.1)
        #expect(u.session.editor.tool == .rect)
        u.release(rect.0, rect.1)
    }

    @Test func aLongScreenshotSaysSoUnderTheToolbar() throws {
        for dark in [false, true] {
            let s = try stage(dark: dark)
            let before = s.paint()
            try s.click(.long)
            park(s, dark: dark)
            #expect(s.session.editor.isLong)
            let p = s.shot("b5-\(dark ? "dark" : "light")-long")
            // The tools are faint, "long" has the ring, and there is a line
            // under the toolbar with a red dot at its left.
            let long = try s.cell(.long)
            #expect(abs(pixel(s, p, long.x + 1, long.y + 28).b - 255) <= 8)
            let plate = try #require(s.session.editor.layout).plate
            var red = 0
            for y in plate.bottom..<(plate.bottom + 160) {
                for x in plate.x..<(plate.x + 60) {
                    let c = pixel(s, p, x, y)
                    if abs(c.r - 0xE0) <= 3 && abs(c.g - 0x40) <= 3 && abs(c.b - 0x40) <= 3 { red += 1 }
                }
            }
            #expect(red > 50, "\(red) pixels of the dot")
            let tool = try s.cell(.tool(.rect))
            let was = (tool.x..<tool.right).map { pixel(s, before, $0, tool.y + 20).r }.max()!
            let now = (tool.x..<tool.right).map { pixel(s, p, $0, tool.y + 20).r }.max()!
            #expect(now < was - 60, "the rectangle tool went from \(was) to \(now)")
        }
    }

    @Test func withTransparencyReducedThePlateIsOpaqueAndTheOutsideOnlyDarkened() throws {
        let s = try stage(dark: false, access: .init(opaque: true))
        try s.click(.tool(.rect))
        park(s, dark: false)
        let p = s.paint()
        let cell = try s.cell(.tool(.select))
        let ground = ShotLook.Colour.plateOpaque
        let c = pixel(s, p, cell.x - 6, cell.y + 28)
        #expect(c.r == Int(ground.r) && c.g == Int(ground.g) && c.b == Int(ground.b), "\(c)")
        // The ring is there and nothing glows around it.
        let rect = try s.cell(.tool(.rect))
        #expect(abs(pixel(s, p, rect.x + 1, rect.y + 28).b - 255) <= 8)
        #expect(pixel(s, p, rect.x - 2, rect.y + 28) == c)
        // Outside the selection: white is 255 x 0.57, and the hard edge is
        // still hard.
        let white = Int((255 * (1 - ShotLook.Colour.outsideDimOpaque.a)).rounded())
        #expect(abs(s.at(p, 650, 625).r - white) <= 2, "white reads \(s.at(p, 650, 625).r)")
        #expect(s.at(p, 399.5, 625).r == 0 && abs(s.at(p, 400.5, 625).r - white) <= 2)
        // Inside it, the picture.
        #expect(s.differing(p, in: CGRect(x: 66, y: 66, width: 468, height: 228)) == 0)
    }
}

/// The text box as the product paints it: no ground of its own, a dashed
/// line that reads on anything, a caret with an edge (9.8.11; criteria
/// 9.8.13 E).
@MainActor
struct ShotOffscreenTextBoxTests {
    /// A selection over a window, the text tool with colour `colour`, and a
    /// box opened at `at` (points).
    private func stage(dark: Bool, colour: Int, at: (Double, Double)) throws -> ShotStage {
        let stage = try ShotStage()
        if dark {
            stage.move(640, 100)
            stage.drag([(640, 100), (1140, 538)])
        } else {
            stage.move(60, 60)
            stage.drag([(60, 60), (540, 450)])
        }
        try stage.click(.tool(.text))
        stage.wait(1)
        try stage.click(.colour(colour))
        stage.wait(1)
        stage.move(at.0, at.1)
        stage.press(at.0, at.1)
        stage.release(at.0, at.1)
        stage.wait(1)
        _ = try #require(stage.session.textBoxView, "the box opened")
        return stage
    }

    private func luma(_ c: (r: Int, g: Int, b: Int)) -> Int { (c.r * 299 + c.g * 587 + c.b * 114) / 1000 }

    @Test func theBoxHasNoGroundAndItsLineIsDashesOnAnything() throws {
        var runs: [Bool: [Int]] = [:]
        for dark in [false, true] {
            // White on the white page; black on the terminal's ground.
            let at = dark ? (900.0, 504.0) : (320.0, 380.0)
            let s = try stage(dark: dark, colour: dark ? 7 : 8, at: at)
            let box = try #require(s.session.textBoxView).frame
            let p = s.shot("c0-\(dark ? "dark" : "light")-empty-box")
            // Inside the box, away from the caret at its left: the picture,
            // to the byte.
            let inside = CGRect(x: box.minX + 12, y: box.minY + 2, width: 60, height: box.height - 4)
            #expect(s.differing(p, in: inside) == 0, "\(dark ? "dark" : "light")")
            // The line: the row two points above the box, to its right of
            // the corner. Pieces of dark and light, each eight pixels.
            let y = Int(box.minY * s.scale) - 5
            let x0 = Int(box.minX * s.scale) + 12
            let ground = luma(s.at(s.frozen, Double(x0) / s.scale, Double(y) / s.scale))
            var lengths: [Int] = []
            var run = 0
            for x in x0..<(Int(box.maxX * s.scale) - 12) {
                let l = luma(s.at(p, Double(x) / s.scale, Double(y) / s.scale))
                if abs(l - ground) > 60 { run += 1 } else if run > 0 { lengths.append(run); run = 0 }
            }
            // The first and last may be cut by where the row starts.
            let whole = lengths.dropFirst().dropLast()
            #expect(whole.count >= 4 && whole.allSatisfy { $0 == 8 }, "\(dark ? "dark" : "light"): \(lengths)")
            runs[dark] = Array(whole)
            // Nothing of the accent: there are no corner marks.
            for dy in -12..<Int(box.height * s.scale) + 12 {
                for dx in -12..<12 {
                    let c = s.at(p, Double(Int(box.minX * s.scale) + dx) / s.scale, Double(Int(box.minY * s.scale) + dy) / s.scale)
                    #expect(!(c.r == 0x41 && c.g == 0x9C && c.b == 0xFF))
                }
            }
        }
        #expect(abs((runs[false]?.count ?? 0) - (runs[true]?.count ?? 0)) <= 1, "the same rhythm on both: \(runs)")
    }

    @Test func whiteTypedOnWhiteCanBeReadWhileItIsTypedAndIsWhiteWhenItIsDone() throws {
        let s = try stage(dark: false, colour: 8, at: (320, 380))
        let view = try #require(s.session.textBoxView)
        view.text.insertText("白底上的白字", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.text.setMarkedText(
            "ni hao", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let p = s.shot("c1-light-white-on-white")
        // The text: something in the box is much darker than the white it
        // is on -- the halo.
        let box = view.frame
        var darkest = 255
        for y in stride(from: box.minY + 2, to: box.maxY - 2, by: 0.5) {
            // (The six characters typed, and not the composition after
            // them, whose line is read further down.)
            for x in stride(from: box.minX + 2, to: box.minX + 96, by: 0.5) { darkest = min(darkest, luma(s.at(p, x, y))) }
        }
        #expect(darkest <= 255 - 40, "the darkest point of the text is \(darkest)")
        // The caret is after the composition, and has a dark edge.
        let caret = try #require(view.caret(fontSize: 18))
        #expect(caret.minX > box.minX + 100)
        // (Read at its top, above the letters: beside them their halo lies
        // over it.)
        #expect(luma(s.at(p, Double(caret.minX) - 0.75, Double(caret.minY) + 0.75)) < 160, "the caret's edge")
        #expect(s.at(p, Double(caret.minX) + 0.5, Double(caret.minY) + 0.75) == (255, 255, 255), "and its body is the ink")
        // The composition has a line under it: two points of the ink against
        // the bottom of the line, with a halo below it, all the way along
        // the six letters and not under the text before them.
        // Committed: the text is white on white and nothing else is there --
        // no line, no halo. That is the finished picture.
        view.text.unmarkText()
        s.press(100, 420)
        s.release(100, 420)
        s.wait(1)
        #expect(s.session.textBoxView == nil)
        #expect(s.session.editor.items.count == 1)
        let q = s.paint()
        #expect(s.differing(q, in: CGRect(x: 300, y: 370, width: 200, height: 40)) == 0)
    }

    @Test func blackTypedOnTheDarkGroundCanBeReadToo() throws {
        let s = try stage(dark: true, colour: 7, at: (900, 504))
        let view = try #require(s.session.textBoxView)
        view.text.insertText("深底上的黑字", replacementRange: NSRange(location: NSNotFound, length: 0))
        let p = s.shot("c2-dark-black-on-dark")
        let box = view.frame
        var lightest = 0
        for y in stride(from: box.minY + 2, to: box.maxY - 2, by: 0.5) {
            for x in stride(from: box.minX + 2, to: box.minX + 110, by: 0.5) { lightest = max(lightest, luma(s.at(p, x, y))) }
        }
        let ground = luma(s.at(s.frozen, Double(box.minX) + 4, Double(box.minY) + 4))
        #expect(lightest >= ground + 40, "the lightest point of the text is \(lightest) on \(ground)")
        let caret = try #require(view.caret(fontSize: 18))
        #expect(luma(s.at(p, Double(caret.minX) - 0.75, Double(caret.minY) + 0.75)) > ground + 60, "the caret's light edge")
    }

    @Test func aSelectionIsTheAccentUnderTheText() throws {
        let s = try stage(dark: false, colour: 0, at: (320, 380))
        let view = try #require(s.session.textBoxView)
        view.text.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.text.setSelectedRange(NSRange(location: 0, length: 3))
        let p = s.shot("c6-light-selection")
        // Between the letters, on the line: white with 35% of the accent
        // over it.
        let box = view.frame
        let a = ShotLook.TextBox.selectionAlpha, accent = ShotLook.Colour.accent
        let want = (
            Int((255 * (1 - a) + Double(accent.r) * a).rounded()), Int((255 * (1 - a) + Double(accent.g) * a).rounded()),
            Int((255 * (1 - a) + Double(accent.b) * a).rounded()))
        var found = false
        for x in stride(from: box.minX + 1, to: box.minX + 30, by: 0.5) {
            let c = s.at(p, x, Double(box.minY) + 3)
            if abs(c.r - want.0) <= 4 && abs(c.g - want.1) <= 4 && abs(c.b - want.2) <= 4 { found = true }
        }
        #expect(found, "a pixel of \(want) in the selected line")
        // Something selected: no caret.
        #expect(view.caret(fontSize: 18) == nil)
    }

    @Test func theScenesOfTheMockUps() throws {
        // Red on the light page, yellow on the terminal, and one across
        // where the two meet is not possible here -- the windows do not
        // touch -- so the third is over the black-to-white edge instead.
        var s = try stage(dark: false, colour: 0, at: (300, 200))
        var view = try #require(s.session.textBoxView)
        view.text.insertText("这里是重点", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.text.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let red = s.shot("c3-light-red")
        // The composition has a line under it: two points of the ink against
        // the bottom of its line, under its five letters and not under the
        // text before them.
        let box = view.frame
        let caret = try #require(view.caret(fontSize: 18))
        func lined(_ x: CGFloat) -> Bool {
            let c = s.at(red, Double(x), Double(box.maxY) - 1)
            return c.r == 0xE6 && c.g == 0x28 && c.b == 0x28
        }
        #expect(lined(caret.minX - 4) && lined(caret.minX - 20) && lined(caret.minX - 36), "under the composition")
        #expect(!lined(box.minX + 6) && !lined(box.minX + 40), "and not under what was typed before it")
        s = try stage(dark: true, colour: 2, at: (760, 300))
        view = try #require(s.session.textBoxView)
        view.text.insertText("这里是重点", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.text.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        s.shot("c4-dark-yellow")

        let edge = try ShotStage()
        edge.move(90, 570)
        edge.drag([(90, 570), (710, 680)])
        try edge.click(.tool(.text))
        edge.wait(1)
        edge.move(330, 610)
        edge.press(330, 610)
        edge.release(330, 610)
        edge.wait(1)
        view = try #require(edge.session.textBoxView)
        view.text.insertText("跨在交界上的字", replacementRange: NSRange(location: NSNotFound, length: 0))
        let p = edge.shot("c5-across-the-edge")
        // The same line: its dark pieces read on the white half, its light
        // ones on the black half.
        let y = Double(view.frame.minY) - 2.25
        let onBlack = (0..<40).map { luma(edge.at(p, 340 + Double($0) / 2, y)) }.max()!
        let onWhite = (0..<40).map { luma(edge.at(p, 420 + Double($0) / 2, y)) }.min()!
        #expect(onBlack > 180 && onWhite < 110, "\(onBlack) on black, \(onWhite) on white")
    }
}

/// The selected annotation as the product paints it: its frame, its grips,
/// what is outside the selection (9.8.11A; criteria 9.8.13 G).
@MainActor
struct ShotOffscreenMarkedTests {
    /// A selection over the light page, whose lower right is plain white.
    private func stage() throws -> ShotStage {
        let stage = try ShotStage()
        stage.move(60, 60)
        stage.drag([(60, 60), (540, 450)])
        stage.wait(1)
        return stage
    }

    /// A selection over the wallpaper, which is neither white nor the
    /// accent: what is white there is a grip.
    private func wallStage() throws -> ShotStage {
        let stage = try ShotStage()
        stage.move(720, 552)
        stage.drag([(720, 552), (1190, 696)])
        stage.wait(1)
        return stage
    }

    /// Draw with `tool` in colour `colour`, then take the select tool and
    /// click the shape at `at`. The pointer ends up parked off everything.
    private func draw(
        _ s: ShotStage, _ tool: AnnotationTool, colour: Int = 0, _ from: (Double, Double), _ to: (Double, Double),
        select at: (Double, Double)?
    ) throws {
        try s.click(.tool(tool))
        s.wait(1)
        try s.click(.colour(colour))
        s.wait(1)
        s.drag([from, to])
        try s.click(.tool(.select))
        s.wait(1)
        if let at {
            s.move(at.0, at.1)
            s.press(at.0, at.1)
            s.release(at.0, at.1)
        }
        s.move(100, 430)
        s.wait(1)
    }

    private func px(_ s: ShotStage, _ p: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        s.at(p, Double(x) / s.scale, Double(y) / s.scale)
    }

    private func isAccent(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        abs(c.r - 0x41) <= 16 && abs(c.g - 0x9C) <= 16 && abs(c.b - 0xFF) <= 16
    }

    private func isWhite(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r >= 250 && c.g >= 250 && c.b >= 250 }

    @Test func aSelectedBoxHasADashedFrameOutsideItsInkAndEightSquareGrips() throws {
        let s = try wallStage()
        try draw(s, .rect, (780, 580), (900, 650), select: (820, 580))
        let marked = try #require(s.session.editor.marked)
        let frame = ShotEditor.frame(of: marked.ink, scale: 2)
        let p = s.shot("d1-selected-rect")
        // Eight pixels between the rectangle's ink and the line, which hold
        // neither: the picture, with the frame's glow over it.
        #expect(frame.y == marked.ink.y - 8)
        for dy in 1...6 {
            let c = px(s, p, frame.x + 60, marked.ink.y - dy)
            #expect(!isAccent(c) && !isWhite(c) && c.r < 0xD0, "between the ink and the frame, \(dy) px up: \(c)")
        }
        // The line, just outside the frame, read along the left half of the
        // top side (the grip in the middle is in the way of the rest): the
        // accent eight pixels, then six of white, by turns. (A pixel either way:
        // the line goes round a corner first, and a dash does not start on
        // a pixel's edge.)
        var runs: [Int] = [], gaps: [Int] = []
        var run = 0, gap = 0
        for x in (frame.x + 20)..<(frame.x + frame.w / 2 - 14) {
            if isAccent(px(s, p, x, frame.y - 1)) {
                if gap > 0 { gaps.append(gap); gap = 0 }
                run += 1
            } else {
                if run > 0 { runs.append(run); run = 0 }
                gap += 1
            }
        }
        let wholeRuns = runs.dropFirst(), wholeGaps = gaps.dropFirst().dropLast()
        #expect(wholeRuns.count >= 4 && wholeRuns.allSatisfy { (7...9).contains($0) }, "dashes \(runs)")
        // And the gaps are white: blue and white by turns.
        let between = px(s, p, frame.x + 20 + (runs.first ?? 0) + (gaps.first ?? 0) + (runs.dropFirst().first ?? 0) + 3, frame.y - 1)
        #expect(between.r > 0xD0 && between.g > 0xD0, "a gap reads \(between)")
        #expect(wholeGaps.allSatisfy { (5...7).contains($0) }, "gaps \(gaps)")
        let inked: Int = wholeRuns.reduce(0, +), clear: Int = wholeGaps.reduce(0, +)
        let periods: Int = wholeGaps.count
        #expect(inked + clear >= 14 * periods - 2, "fourteen pixels a period")
        // A grip: fourteen pixels square on the frame -- read down the one in
        // the middle of the top side, from its first pixel of white or the
        // accent to its last.
        #expect(marked.grips.count == 8)
        let top = marked.grips[4].at
        #expect(isWhite(px(s, p, top.x + 3, top.y + 3)), "white inside")
        let column = ((top.y - 12)...(top.y + 12)).map { px(s, p, top.x + 3, $0) }
        let hits = column.indices.filter { isWhite(column[$0]) || isAccent(column[$0]) }
        let first: Int = hits.first ?? 0, last: Int = hits.last ?? 0
        let tall: Int = last - first + 1
        #expect(tall == 14, "the grip is \(tall) px tall")
        let edgeTop = isAccent(column[first]), edgeBottom = isAccent(column[last])
        #expect(edgeTop && edgeBottom, "edged in the accent")
        // The selection's own round knobs are away: beside its corner there
        // is no edge of one.
        let sel = try #require(s.session.editor.selection).rect
        #expect(!isAccent(px(s, p, sel.x - 6, sel.y)))
    }

    @Test func aBlueBoxIsToldFromItsFrameByTheGapBetweenThem() throws {
        let s = try stage()
        try draw(s, .rect, colour: 5, (320, 350), (440, 420), select: (380, 350))
        let marked = try #require(s.session.editor.marked)
        let p = s.shot("d2-selected-blue-rect")
        // Up from the rectangle's top line: its blue, then at least six
        // pixels that are neither it nor the frame, then the frame.
        let x = marked.ink.x + 60
        var neither = 0
        for y in stride(from: marked.ink.y - 1, to: marked.ink.y - 8, by: -1) {
            let c = px(s, p, x, y)
            if !(c.r == 0x2F && c.g == 0x6F && c.b == 0xED) && !isAccent(c) { neither += 1 }
        }
        #expect(neither >= 6, "\(neither) px between a blue rectangle and its frame")
    }

    @Test func aLineHasNoFrameAndWhatOnlyMovesHasNoGrips() throws {
        var s = try stage()
        try draw(s, .arrow, (320, 420), (440, 360), select: (380, 390))
        var marked = try #require(s.session.editor.marked)
        #expect(!marked.framed && marked.grips.count == 2)
        var p = s.shot("d3-selected-arrow")
        // Where a frame would run, above the arrow's box: nothing.
        let frame = ShotEditor.frame(of: marked.ink, scale: 2)
        let accents = ((frame.x + 20)..<(frame.right - 20)).filter { isAccent(px(s, p, $0, frame.y - 1)) }.count
        #expect(accents == 0)
        // And a square grip on each end.
        for grip in marked.grips { #expect(isWhite(px(s, p, grip.at.x, grip.at.y)), "\(grip.at)") }

        // A pen stroke: the frame, and not one grip.
        s = try stage()
        try s.click(.tool(.pen))
        s.wait(1)
        s.drag([(320, 400), (350, 370), (380, 410), (410, 365), (440, 395)])
        try s.click(.tool(.select))
        s.wait(1)
        s.move(350, 370)
        s.press(350, 370)
        s.release(350, 370)
        s.move(100, 430)
        s.wait(1)
        marked = try #require(s.session.editor.marked)
        #expect(marked.framed && marked.grips.isEmpty)
        p = s.shot("d4-selected-pen")
        let around = ShotEditor.frame(of: marked.ink, scale: 2)
        #expect(((around.x + 20)..<(around.right - 20)).filter { isAccent(px(s, p, $0, around.y - 1)) }.count > 30)
    }

    @Test func aGripGrowsUnderThePointerAndFillsWhileItIsDragged() throws {
        let s = try wallStage()
        try draw(s, .rect, (780, 600), (880, 660), select: (800, 600))
        // The grip in the middle of the top side.
        let grip = try #require(s.session.editor.marked).grips[4].at
        func side(_ p: [UInt8], at g: PixelPoint) -> Int {
            // How tall the grip is: from its first pixel that is white or
            // the accent to its last, down a column of it.
            let column = ((g.y - 14)...(g.y + 14)).map { px(s, p, g.x + 3, $0) }
            let hits = column.indices.filter { isWhite(column[$0]) || isAccent(column[$0]) }
            return (hits.last ?? 0) - (hits.first ?? 0) + 1
        }
        let rest = side(s.paint(), at: grip)
        s.move(Double(grip.x) / 2, Double(grip.y) / 2)
        s.wait(1)
        let hot = s.shot("d5-grip-hovered")
        let over: Int = side(hot, at: grip)
        #expect(rest == 14, "\(rest) px at rest")
        #expect(over == 18, "\(over) px under the pointer")
        s.press(Double(grip.x) / 2, Double(grip.y) / 2)
        s.move(Double(grip.x) / 2 + 30, Double(grip.y) / 2 - 20)
        let held = s.shot("d6-grip-dragged")
        // It went up with the pointer -- the top side moves, nothing else --
        // and is the accent inside.
        let now = try #require(s.session.editor.marked).grips[4].at
        #expect(now == PixelPoint(grip.x, grip.y - 40))
        #expect(isAccent(px(s, held, now.x + 2, now.y + 2)))
        // Beside the pointer, what the rectangle measures now: a label
        // that was not there.
        #expect(s.session.editor.reshapeTag == "200 × 160")
        let pointer = (x: grip.x + 60, y: grip.y - 40)
        // (Dark, as a plate is: the wallpaper there is not.)
        func dark(_ pixels: [UInt8]) -> Int {
            var n = 0
            for y in (pointer.y + 26)..<(pointer.y + 70) {
                for x in (pointer.x + 26)..<(pointer.x + 150) {
                    let c = px(s, pixels, x, y)
                    if c.r < 0x50 && c.g < 0x50 && c.b < 0x58 { n += 1 }
                }
            }
            return n
        }
        #expect(dark(held) > dark(hot) + 800, "\(dark(held)) dark pixels with the tag, \(dark(hot)) without")
        s.release(Double(grip.x) / 2 + 30, Double(grip.y) / 2 - 20)
    }

    @Test func theSelectionsOwnKnobsAreRound() throws {
        // Over the wallpaper, where white is a knob and nothing else.
        let s = try wallStage()
        s.move(760, 600)
        s.wait(1)
        let p = s.shot("d7-selection-knobs")
        let sel = try #require(s.session.editor.selection).rect
        #expect(s.session.editor.knobs)
        // Fourteen pixels across, white in the middle -- and round: the
        // corner of its square is not part of it.
        // (Read on the knob in the middle of the left side: nothing else
        // -- no label, no toolbar, no shadow of one -- is near it.)
        let knob = PixelHandle.w.at(sel)
        #expect(isWhite(px(s, p, knob.x, knob.y)))
        #expect(isAccent(px(s, p, knob.x - 6, knob.y)))
        let before = s.at(s.frozen, Double(knob.x - 6) / s.scale, Double(knob.y - 6) / s.scale)
        let corner = px(s, p, knob.x - 6, knob.y - 6)
        #expect(!isAccent(corner) && !isWhite(corner) && abs(corner.r - before.r) <= 24, "\(corner), where the picture is \(before)")
    }

    @Test func whatReachesOutsideTheSelectionIsDrawnFaint() throws {
        let s = try stage()
        // A thick red rectangle, then carried half out of the selection's
        // right edge (540 pt).
        try s.click(.tool(.rect))
        s.wait(1)
        try s.click(.level(4))
        s.wait(1)
        s.drag([(380, 340), (480, 420)])
        try s.click(.tool(.select))
        s.wait(1)
        s.move(430, 340)
        s.press(430, 340)
        s.move(530, 340)
        let carrying = s.paint()
        // Carried: the frame is with it and its grips are away.
        let marked = try #require(s.session.editor.marked)
        #expect(marked.framed && marked.grips.isEmpty)
        #expect(s.session.editor.isMovingItem)
        _ = carrying
        s.release(530, 340)
        s.move(100, 430)
        s.wait(1)
        let p = s.shot("d8-half-outside")
        // Inside the selection the line is red. Outside it is 40% of red
        // over what is there.
        let inside = s.at(p, 500, 340)
        #expect(inside == (0xE6, 0x28, 0x28), "\(inside)")
        let before = s.at(s.paint(), 560, 300)
        let outside = s.at(p, 560, 340)
        let a = ShotLook.Annotation.outsideOpacity
        let want = Int((Double(before.r) * (1 - a) + 0xE6 * a).rounded())
        #expect(abs(outside.r - want) <= 10 && outside.g > 0x60, "\(outside), over \(before), wanted about \(want)")
    }

    @Test func theSelectedOneIsMarkedOverTheOthers() throws {
        let s = try stage()
        try draw(s, .rect, colour: 3, (300, 340), (400, 420), select: nil)
        try draw(s, .ellipse, colour: 0, (350, 350), (470, 430), select: nil)
        try draw(s, .arrow, colour: 5, (310, 430), (480, 345), select: nil)
        // Select the ellipse by its left side, where only it is.
        s.move(350, 390)
        s.press(350, 390)
        s.release(350, 390)
        s.move(100, 430)
        s.wait(1)
        #expect(s.session.editor.selected == 1)
        let p = s.shot("d9-overlapping")
        // The frame's line runs unbroken where the green rectangle's line
        // crosses it: the frame is on top.
        let marked = try #require(s.session.editor.marked)
        let frame = ShotEditor.frame(of: marked.ink, scale: 2)
        let row = ((frame.x + 10)..<(frame.right - 10)).map { px(s, p, $0, frame.y - 1) }
        #expect(!row.contains { $0.r == 0x2D && $0.g == 0xB8 && $0.b == 0x4D }, "no green on the frame's line")
        #expect(row.filter(isAccent).count > 60)
    }
}

/// How long the three things that cost anything take, on the machine this
/// runs on. Not a test of anything: it prints. Run it optimised --
/// `SHOT_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter ShotBench`.
@MainActor
struct ShotBenchTests {
    private func median(_ runs: Int, _ body: () -> Void) -> (median: Double, min: Double, max: Double) {
        var t: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            t.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        t.sort()
        return (t[t.count / 2], t[0], t[t.count - 1])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHOT_BENCH"] == "1"))
    func theBlurAndAFrameOnADisplayOf3600By2338() throws {
        // 1800 x 1169 points at scale 2.
        let stage = try ShotStage(scale: 2, points: CGSize(width: 1800, height: 1169))
        #expect(stage.width == 3600 && stage.height == 2338)
        let picture = try #require(ShotBlur.Picture(width: stage.width, height: stage.height, rgbx: stage.frozen))
        var kept: ShotBlur.Prepared?
        let blur = median(9) { kept = ShotBlur.prepare(picture, scale: 2) }
        let prepared = try #require(kept)
        let image = median(9) { _ = ShotRenderer.image(of: prepared.outside) }
        let plate = median(9) { _ = ShotBlur.plate(from: prepared, scale: 2, rect: PixelRect(1000, 1200, 1040, 160)) }

        // A selection of 1600 x 1000 px, as the specification's example.
        stage.move(500, 300)
        stage.drag([(500, 300), (1300, 800)])
        stage.wait(1)
        let whole = median(15) { _ = stage.paint() }
        // The dirty rectangle of one frame of moving it by 12 points.
        let dirty = CGRect(x: 496, y: 296, width: 820, height: 520)
        let part = median(15) { _ = stage.paint(only: dirty) }
        func line(_ what: String, _ t: (median: Double, min: Double, max: Double)) {
            print(String(format: "BENCH %@ median %.2f ms (min %.2f, max %.2f)", what, t.median, t.min, t.max))
        }
        line("out-of-focus picture, once (shrink 4, 3 box passes r=1, stretch, darken)", blur)
        line("that picture as a CGImage (one copy of 33.7 MB)", image)
        line("the glass under a 1040 x 160 px plate", plate)
        line("one frame, whole display, into a bitmap (allocating it included)", whole)
        line("one frame, dirty rectangle 1640 x 1040 px, into a bitmap (allocating it included)", part)
    }
}

/// What the screenshot looks like before and while a region is dragged out
/// (task 1196, 6 and 8).
@MainActor
struct ShotOffscreenFirstFrameTests {
    @Test func theFirstFrameAlreadyHasTheWindowUnderThePointerInFocus() throws {
        // The pointer is over the dark window the moment the picture is up:
        // no mouse move has been made. (Cocoa's coordinates: the screen is
        // 700 points tall and y runs upwards.)
        let seeded = try ShotStage()
        seeded.session.seedPointer(atCocoa: CGPoint(x: 900, y: 700 - 300), primaryHeight: 700)
        seeded.session.settleFocus()
        let hover = try #require(seeded.session.editor.hover)
        #expect(hover.rect.w > 0 && hover.rect.h > 0)
        let p = seeded.shot("f1-first-frame-pointer-over-dark-window")
        #expect(seeded.differing(p, in: ShotStage.dark.insetBy(dx: 4, dy: 4)) == 0)
        #expect(seeded.differing(p, in: ShotStage.light.insetBy(dx: 4, dy: 4)) > 1000)

        // Without it the editor knows of no window under the pointer: what
        // the screen showed until the first mouse move.
        let unseeded = try ShotStage()
        #expect(unseeded.session.editor.hover == nil)

        // A pointer over no window: the whole display is sharp, still.
        let bare = try ShotStage()
        bare.session.seedPointer(atCocoa: CGPoint(x: 1180, y: 700 - 20), primaryHeight: 700)
        bare.session.settleFocus()
        #expect(bare.session.editor.hover == nil)
    }

    @Test func theSizeIsShownAndFollowsEveryFrameOfADrag() throws {
        let stage = try ShotStage()
        stage.move(100, 500)
        stage.wait(1)
        stage.press(100, 500)
        stage.move(160, 540)
        stage.wait(1)
        _ = stage.shot("f2-size-while-dragging-small")
        let small = try #require(stage.session.labelRects.first?.first, "a label while the region is being dragged")
        stage.move(700, 650)
        stage.wait(1)
        _ = stage.shot("f3-size-while-dragging-large")
        let large = try #require(stage.session.labelRects.first?.first)
        #expect(large.w > small.w, "\"600 × 150\" is longer than \"60 × 40\" and the label was drawn again")
        // It is above the region's top left corner, as the selection's is.
        #expect(large.x == small.x && large.bottom <= 500 * 2)
        stage.release(700, 650)
        stage.wait(1)
        #expect(stage.session.editor.selection != nil)
    }
}

/// A number's sentence as it is typed: the circle follows the colour and
/// size chosen, the box is as high as the circle is round, and as wide as
/// what is in it (task 1196, 2, 3 and 4).
@MainActor
struct ShotOffscreenNumberBoxTests {
    private func stage(colour: Int? = nil) throws -> ShotStage {
        let stage = try ShotStage()
        stage.move(60, 60)
        stage.drag([(60, 60), (540, 450)])
        try stage.click(.tool(.number))
        stage.wait(1)
        stage.move(200, 200)
        stage.press(200, 200)
        stage.release(200, 200)
        stage.wait(1)
        return stage
    }

    @Test func theBoxIsCentredOnTheCircleWithNothingTypedAndWithText() throws {
        let s = try stage()
        let empty = try #require(s.session.textBoxView).frame
        let mid = { (r: CGRect) in (r.minY + r.maxY) / 2 }
        #expect(abs(mid(empty) - 200) <= 1.0, "empty: the box's middle is \(mid(empty)), the circle's 200")
        _ = s.shot("g1-number-empty-box")
        let view = try #require(s.session.textBoxView)
        view.text.insertText("说明文字 abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        s.wait(1)
        let typed = try #require(s.session.textBoxView).frame
        #expect(abs(mid(typed) - 200) <= 1.0, "typed: the box's middle is \(mid(typed))")
        #expect(abs(mid(typed) - mid(empty)) <= 1.0, "and it did not move when text came in")
        _ = s.shot("g2-number-typed-box")
    }

    @Test func theBoxIsNarrowWhenEmptyAndGrowsWithTheTextButNeverPastTheSelection() throws {
        let s = try stage()
        let view = try #require(s.session.textBoxView)
        let empty = view.frame.width
        let oneLine = view.frame.height
        // Four ems of the default size, or 40 points.
        let font = Double(ShotStyle.fontPx(level: s.session.editor.textBox?.level ?? 0, scale: s.scale)) / s.scale
        #expect(abs(empty - max(font * 4, 40)) <= 1, "empty box is \(empty) points wide")
        #expect(empty < 120, "and not a line across the selection")
        view.text.insertText("hello world", replacementRange: NSRange(location: NSNotFound, length: 0))
        s.wait(1)
        let some = try #require(s.session.textBoxView).frame.width
        #expect(some > empty)
        view.text.insertText(String(repeating: "wider ", count: 40), replacementRange: NSRange(location: NSNotFound, length: 0))
        s.wait(1)
        let box = try #require(s.session.textBoxView).frame
        #expect(box.maxX <= 540 + 0.5, "the selection ends at x = 540 and the box at \(box.maxX)")
        #expect(box.maxX <= 1200)
        #expect(box.height > oneLine * 2, "what wrapped at the selection's edge makes the box taller, not a scroll of one line")
        _ = s.shot("g3-number-long-text-stops-at-selection")
    }

    @Test func theCircleIsDrawnInTheColourAndSizeChosenWhileTheSentenceIsTyped() throws {
        let s = try stage()
        let before = s.shot("g4-number-editing-before")
        let circle = CGRect(x: 200 - 8, y: 200 - 8, width: 16, height: 16)
        let probe = (x: 200.0, y: 200.0 - 10)
        // The red default on the page's white; then blue and larger.
        let read0 = s.at(before, probe.x, probe.y)
        try s.click(.colour(3))
        s.wait(1)
        try s.click(.level(4))
        s.wait(1)
        let after = s.shot("g5-number-editing-after-colour-and-size")
        let read1 = s.at(after, 200 - 1, 200 - 10)
        #expect(read0 != read1 || s.differing(after, in: circle.insetBy(dx: -30, dy: -30)) > 0)
        let want = ShotStyle.colour(3)
        // Left of the digit, inside the (now larger) circle.
        let inside = s.at(after, 200 - 14, 200)
        #expect(abs(inside.r - Int(want.r)) <= 3 && abs(inside.g - Int(want.g)) <= 3 && abs(inside.b - Int(want.b)) <= 3,
                "inside the circle reads \(inside), the colour is \(want)")
        _ = circle
    }
}

/// The toolbar carried by its plate, as the product paints it (task 1196, 5).
@MainActor
struct ShotOffscreenToolbarCarryTests {
    @Test func theToolbarIsPaintedWhereItWasCarriedWithGlassFromThere() throws {
        let s = try ShotStage()
        s.move(60, 60)
        s.drag([(60, 60), (540, 450)])
        s.wait(1)
        let before = try #require(s.session.editor.layout)
        let auto = s.shot("h0-toolbar-automatic")
        // Take hold of the padding at the plate's top left corner and carry
        // it up into the selection, over the page's text.
        let grab = (Double(before.bar.x + 1) / s.scale, Double(before.bar.y + 1) / s.scale)
        s.move(grab.0, grab.1)
        s.press(grab.0, grab.1)
        s.move(grab.0 + 40, grab.1 - 120)
        s.move(grab.0 + 80, grab.1 - 240)
        s.release(grab.0 + 80, grab.1 - 240)
        s.wait(1)
        let after = try #require(s.session.editor.layout)
        #expect(after.bar.x == before.bar.x + Int(80 * s.scale) && after.bar.y == before.bar.y - Int(240 * s.scale))
        let moved = s.shot("h1-toolbar-carried-into-the-selection")
        // The cell of the first tool is painted at its new place: it is not
        // the picture there, to some bytes.
        let cell = try s.cell(.tool(.rect))
        let rect = CGRect(
            x: Double(cell.x) / s.scale, y: Double(cell.y) / s.scale, width: Double(cell.w) / s.scale, height: Double(cell.h) / s.scale)
        #expect(s.differing(moved, in: rect) > 100, "the toolbar is drawn there")
        // And not where it was: the same pixels as before the move have
        // been given back (the outside of the selection, dimmed as ever).
        let old = CGRect(
            x: Double(before.bar.x) / s.scale, y: Double(before.bar.y) / s.scale + 4, width: 100, height: 20)
        #expect(s.at(moved, Double(old.minX) + 20, Double(old.minY) + 8) != s.at(auto, Double(old.minX) + 20, Double(old.minY) + 8))
    }
}

/// The magnifier as the product paints it (task 1196, 7).
@MainActor
struct ShotOffscreenMagnifierTests {
    /// The bitmap pixel at `(x, y)` of `pixels`.
    private func px(_ s: ShotStage, _ pixels: [UInt8], _ x: Int, _ y: Int) -> [Int] {
        let i = (y * s.width + x) * 4
        return [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
    }

    /// Where the enlarged picture is: the plate's, less its padding.
    private func image(_ plate: PixelRect, scale: Double) -> PixelRect {
        let m = ShotMagnifier.Metrics(scale: scale, textHeight: 0)
        return PixelRect(plate.x + m.pad, plate.y + m.pad, m.image, m.image)
    }

    @Test func theMiddleCellIsThePixelUnderThePointerAndItsNeighboursAreTheirOwn() throws {
        let s = try ShotStage()
        // The right edge of the first blue bar of the light page: x = 85.5
        // points is pixel 171, the last of the bar; 172 is the page's white.
        s.move(85.5, 320)
        s.wait(1)
        let p = s.shot("m1-magnifier-at-the-edge-of-a-bar")
        let plate = try #require(s.session.magnifierPlate(on: 0))
        let img = image(plate, scale: s.scale)
        let m = ShotMagnifier.Metrics(scale: s.scale, textHeight: 0)
        // Inside a cell, away from the lines round it.
        func cell(_ dx: Int) -> [Int] {
            px(s, p, img.x + (m.cells / 2 + dx) * m.cell + m.cell / 2, img.y + (m.cells / 2) * m.cell + m.cell / 2)
        }
        #expect(cell(0) == [0x2F, 0x6F, 0xED], "the pixel under the pointer, from the frozen picture")
        #expect(cell(-1) == [0x2F, 0x6F, 0xED], "pixel 170, still the bar")
        #expect(cell(1) == [255, 255, 255], "pixel 172, the page")
        #expect(cell(3) == [255, 255, 255])
        // And the plate is where the rule puts it: right of and below.
        #expect(plate.x > 171 && plate.y > 640)
        #expect(plate.w == m.plateWidth)
    }

    @Test func theGridLinesLieOnTheCellBoundaries() throws {
        let s = try ShotStage()
        s.move(300, 320)
        s.wait(1)
        let p = s.shot("m2-magnifier-grid")
        let plate = try #require(s.session.magnifierPlate(on: 0))
        let img = image(plate, scale: s.scale)
        let m = ShotMagnifier.Metrics(scale: s.scale, textHeight: 0)
        // On the page's white (x 300 is inside the chart's white), a grid
        // line is darker than the cell beside it, and the cell is not.
        let a = ShotLook.Colour.magnifierGrid.a
        let line = px(s, p, img.x + 3 * m.cell, img.y + m.cell + m.cell / 2)
        let beside = px(s, p, img.x + 3 * m.cell + m.cell / 2, img.y + m.cell + m.cell / 2)
        #expect(beside == [255, 255, 255] || beside[0] == beside[1], "the cell is the picture: \(beside)")
        #expect(line[0] < beside[0] || a == 0, "the line is darker: \(line) against \(beside)")
    }

    @Test func itIsUpWhileARegionIsDraggedAndGoneOnceItIsChosen() throws {
        let s = try ShotStage()
        s.move(100, 500)
        #expect(s.session.magnifierPlate(on: 0) != nil, "before there is a region")
        s.press(100, 500)
        s.move(160, 540)
        s.move(300, 600)
        #expect(s.session.magnifierPlate(on: 0) != nil, "while it is dragged out")
        _ = s.shot("m3-magnifier-while-dragging")
        s.release(300, 600)
        s.wait(1)
        #expect(s.session.editor.selection != nil)
        #expect(s.session.magnifierPlate(on: 0) == nil, "chosen: it is for annotating now")
    }

    @Test func copyPutsTheColourOnTheClipboardSaysSoAndGoesBack() throws {
        let s = try ShotStage()
        s.move(85.5, 320)
        s.wait(1)
        let before = s.paint()
        let board = NSPasteboard(name: NSPasteboard.Name("polter.test.\(UUID().uuidString)"))
        board.clearContents()
        #expect(s.session.copyColour(to: board))
        #expect(board.string(forType: .string) == "#2F6FED")
        let plate = try #require(s.session.magnifierPlate(on: 0))
        let during = s.shot("m4-magnifier-copied")
        // The row under the picture changed: "Copied" where the colour was.
        let m = ShotMagnifier.Metrics(scale: s.scale, textHeight: 0)
        let row = PixelRect(plate.x, plate.y + m.pad + m.image, plate.w, plate.h - m.pad - m.image)
        func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            for y in row.y..<row.bottom {
                for x in row.x..<row.right where px(s, a, x, y) != px(s, b, x, y) { return true }
            }
            return false
        }
        #expect(differs(before, during))
        s.wait(1)
        let after = s.paint()
        #expect(!differs(before, after), "a second later it is the colour again")
        // Nothing to copy once the region is chosen: the clipboard is left.
        s.drag([(60, 60), (540, 450)])
        s.wait(1)
        board.clearContents()
        board.setString("kept", forType: .string)
        #expect(!s.session.copyColour(to: board))
        #expect(board.string(forType: .string) == "kept")
    }
}

/// A page that is made up, taller than the selection, scrolled by the wheel
/// the session turns, and photographed through the selection.
@MainActor
final class FakePage: ShotFrameSource {
    let width: Int
    let height: Int
    let view: Int
    let bytes: [UInt8]
    /// How far down the page the view is, in pixels.
    var offset = 0
    /// What a wheel step of one point is, in pixels.
    let scale: Double
    var wheels: [Int] = []
    var frames = 0

    init(width: Int, height: Int, view: Int, scale: Double) {
        self.width = width
        self.height = height
        self.view = view
        self.scale = scale
        // Every row different, and every column: nothing in it repeats.
        var state: UInt64 = 0x9E3779B97F4A7C15
        var b = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let v = UInt8(truncatingIfNeeded: state >> 33)
                let i = (y * width + x) * 4
                b[i] = v
                b[i + 1] = UInt8(truncatingIfNeeded: Int(v) &* 3 &+ y)
                b[i + 2] = UInt8(truncatingIfNeeded: Int(v) &+ x)
            }
        }
        bytes = b
    }

    /// The wheel: down by `points`, to the bottom and no further.
    func wheel(_ points: Int) {
        wheels.append(points)
        offset = min(offset + Int((Double(points) * scale).rounded()), height - view)
    }

    nonisolated func frame(completion: @escaping ([UInt8]?) -> Void) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                frames += 1
                let start = offset * width * 4
                completion(Array(bytes[start..<(start + view * width * 4)]))
            }
        }
    }
}

@MainActor
struct ShotOffscreenAutoScrollTests {
    final class Ending: ShotSessionDelegate {
        var cancelled = 0
        var result: ShotSession.Result?
        func sessionDidCancel(_ session: ShotSession) { cancelled += 1 }
        func sessionDidFinish(_ session: ShotSession, with finished: ShotSession.Result) { result = finished }
    }

    /// A stage with the light window chosen and a page behind it.
    private func ready(pageHeight: Int, trusted: Bool = true) throws -> Rig {
        let s = try ShotStage()
        s.move(60, 60)
        s.drag([(60, 60), (300, 300)])
        s.wait(1)
        let selection = try #require(s.session.editor.selection?.rect)
        let page = FakePage(width: selection.w, height: pageHeight, view: selection.h, scale: s.scale)
        let parked = Parked()
        s.session.scroller = ShotSession.Scroller(
            trusted: { trusted },
            pointer: { CGPoint(x: 11, y: 22) },
            park: { parked.at.append($0) },
            wheel: { page.wheel($0) })
        s.session.frameSource = { _ in page }
        s.session.autoSettle = 0.004
        s.session.autoLook = 0.004
        let ending = Ending()
        s.session.delegate = ending
        return Rig(stage: s, page: page, ending: ending, parked: parked)
    }

    final class Parked { var at: [CGPoint] = [] }

    /// A stage, the page behind it, what the session said when it ended,
    /// and where the pointer was put.
    struct Rig {
        var stage: ShotStage
        var page: FakePage
        var ending: Ending
        var parked: Parked
    }

    private func wait(_ seconds: TimeInterval = 240, until done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func rows(_ image: ComposedImage) -> [UInt8] {
        guard let cg = image.cgImage(), let bytes = ShotRenderer.rgbx(of: cg) else { return [] }
        return bytes
    }

    @Test func theProgramScrollsToTheBottomAndTheWholePageIsTheResult() async throws {
        let rig = try ready(pageHeight: 3100)
        let (s, page, ending, parked) = (rig.stage, rig.page, rig.ending, rig.parked)
        let selection = try #require(s.session.editor.selection?.rect)
        try s.click(.long)
        // The pointer went to the middle of the selection, in points.
        #expect(parked.at.first == CGPoint(x: Double(selection.x + selection.w / 2) / s.scale, y: Double(selection.y + selection.h / 2) / s.scale))
        try await wait { ending.result != nil }
        let result = try #require(ending.result, "it finished by itself")
        #expect(result.isLong)
        #expect(result.image.height == 3100, "the whole page, to the last row: \(result.image.height)")
        // And it is the page, row for row.
        let got = rows(result.image)
        #expect(got.count == page.bytes.count)
        var wrong = 0
        for i in stride(from: 0, to: min(got.count, page.bytes.count), by: 4)
        where got[i] != page.bytes[i] || got[i + 1] != page.bytes[i + 1] || got[i + 2] != page.bytes[i + 2] { wrong += 1 }
        #expect(wrong == 0, "\(wrong) pixels differ from the page")
        // It scrolled in the steps the rule says, and put the pointer back.
        let step = ShotAutoScroll.step(height: selection.h, scale: s.scale)
        #expect(Set(page.wheels) == [step])
        #expect(parked.at.last == CGPoint(x: 11, y: 22), "the pointer is where it was")
        #expect(page.offset == page.height - page.view, "at the bottom")
    }

    @Test func aPageShorterThanTheSelectionIsOneFrameAndNothingIsScrolledForever() async throws {
        let s = try ShotStage()
        s.move(60, 60)
        s.drag([(60, 60), (300, 300)])
        let selection = try #require(s.session.editor.selection?.rect)
        let (_, page, ending, _) = (s, FakePage(width: selection.w, height: selection.h, view: selection.h, scale: s.scale), Ending(), Parked())
        s.session.delegate = ending
        s.session.scroller = ShotSession.Scroller(trusted: { true }, pointer: { .zero }, park: { _ in }, wheel: { page.wheel($0) })
        s.session.frameSource = { _ in page }
        s.session.autoSettle = 0.004
        s.session.autoLook = 0.004
        try s.click(.long)
        try await wait { ending.result != nil }
        #expect(ending.result?.image.height == selection.h)
        #expect(page.wheels.count == ShotAutoScroll.bottomAfter, "it stopped after the few steps that added nothing")
    }

    @Test func aPersonsOwnScrollingDuringItIsFollowedByWhatActuallyMoved() async throws {
        let rig = try ready(pageHeight: 2900)
        let (s, page, ending, _) = (rig.stage, rig.page, rig.ending, rig.parked)
        let before = page.wheel
        _ = before
        // Somebody turns the wheel too, now and then, between our steps.
        var count = 0
        let selection = try #require(s.session.editor.selection?.rect)
        s.session.scroller.wheel = { points in
            count += 1
            page.wheel(points)
            if count % 3 == 0 { page.offset = min(page.offset + 40, page.height - page.view) }
        }
        _ = selection
        try s.click(.long)
        try await wait { ending.result != nil }
        let result = try #require(ending.result)
        #expect(result.image.height == 2900, "the shift that happened is the one that is joined: \(result.image.height)")
    }

    @Test func escapeEndsItAtOnceAndNothingMoreIsScrolled() async throws {
        let rig = try ready(pageHeight: 6000)
        let (s, page, ending, parked) = (rig.stage, rig.page, rig.ending, rig.parked)
        try s.click(.long)
        try await wait { page.wheels.count >= 3 }
        let wheels = page.wheels.count
        #expect(wheels >= 3 && ending.result == nil)
        // Esc: the session's own key path.
        s.session.key(.escape, mods: [])
        #expect(ending.cancelled == 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(page.wheels.count <= wheels + 1, "no more wheel after the end: \(wheels) then \(page.wheels.count)")
        #expect(parked.at.last == CGPoint(x: 11, y: 22), "the pointer is put back on a cancel too")
    }

    @Test func withoutThePermissionNothingIsScrolledAndThePersonIsTold() async throws {
        let rig = try ready(pageHeight: 3000, trusted: false)
        let (s, page, ending, _) = (rig.stage, rig.page, rig.ending, rig.parked)
        try s.click(.long)
        try await wait { page.frames >= 3 }
        #expect(page.wheels.isEmpty, "the wheel is not turned without the permission")
        #expect(ending.result == nil && ending.cancelled == 0, "and it waits for the person")
        #expect(page.frames > 0, "frames are taken on a clock, as before")
        _ = s.shot("l1-long-needs-permission-status")
        // The person scrolls; Done keeps what was joined.
        page.offset = 150
        let seen = page.frames
        try await wait { page.frames >= seen + 3 }
        try s.click(.done)
        #expect(ending.result?.image.height ?? 0 > page.view)
    }

    @Test func theStatusSaysItIsScrollingAndHowTallThePictureIs() async throws {
        let rig = try ready(pageHeight: 6000)
        let (s, page, ending, _) = (rig.stage, rig.page, rig.ending, rig.parked)
        try s.click(.long)
        try await wait { page.wheels.count >= 4 }
        _ = s.shot("l2-long-scrolling-status")
        let label = s.session.labelRects.first?.count ?? 0
        #expect(label >= 2, "the size and the status line are on screen")
        try s.click(.done)
        #expect(ending.result != nil)
    }
}
