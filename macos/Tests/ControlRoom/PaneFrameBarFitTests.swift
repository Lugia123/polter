import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// A frame's title stays inside its bar however narrow the pane is
/// (`PaneFrameBar`, #1498).
///
/// **What went wrong.** On a pane 80 pt wide the role word and the status
/// word would not shrink and the name had nothing left: the three were
/// drawn over one another and out past the frame's edge. Measured on a Mac
/// (round seven), and drawn again in
/// `Polter_Pub/assets/control-room-design/pane-bar-narrow-v1`.
///
/// **How it is held to.** The frame is drawn off screen and the columns of
/// its bar that carry ink are read back: every one has to be inside the
/// bar's padding. That is a reading of the picture, not of the layout code
/// -- the overlap was in the picture, and the code that made it looked
/// right. No application is started and nothing is put on screen.
@MainActor
struct PaneFrameBarFitTests {
    typealias Look = ControlRoomLook

    /// Where the bar's words may go, from the frame's left edge: its
    /// padding on each side (`PaneFrameChrome.overFrame`).
    static func padding(_ wears: PaneFrame.Kind) -> Double {
        switch wears {
        case .supervisor: Look.Space.supervisorBezel + Look.Pane.supervisorBarPaddingX
        case .worker: Look.Pane.barPaddingX
        case .plain: Look.Pane.plainTitleInsetX
        }
    }

    /// The columns of the bar that carry ink, as runs from the frame's left
    /// edge in points. The frame's own edge lines are left out (3 pt each
    /// side), and so are the bar's top and bottom, where its corners are.
    static func inkRuns(_ wears: PaneFrame.Kind, _ title: PaneFrame.Title, width: Double, scheme: ColorScheme) throws -> [ClosedRange<Double>] {
        let scale = 2.0
        let view = PaneFrameView(wears: wears, title: title, caption: nil, focused: false, well: nil, cover: nil, stack: nil) {
            Color.clear
        }
        .frame(width: CGFloat(width), height: 72)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = CGFloat(scale)
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)

        func pixel(_ x: Int, _ y: Int) -> [Double] {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
            return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        }
        // The bar's own ground, from its middle just under its top edge.
        let ground = pixel(Int(width / 2 * scale), Int(2 * scale))
        let rows = Int(6 * scale)..<Int(26 * scale)
        var runs: [ClosedRange<Double>] = []
        for x in Int(3 * scale)..<Int((width - 3) * scale) {
            let inked = rows.contains { y in
                zip(pixel(x, y), ground).map { abs($0 - $1) }.reduce(0, +) > 0.24
            }
            guard inked else { continue }
            let at = Double(x) / scale
            if let last = runs.last, at - last.upperBound <= 3 {
                runs[runs.count - 1] = last.lowerBound...at
            } else {
                runs.append(at...at)
            }
        }
        return runs
    }

    static let titles: [(PaneFrame.Kind, PaneFrame.Title)] = [
        (.supervisor, PaneFrame.Title(name: "polter", shown: .working, word: "在干活")),
        (.worker, PaneFrame.Title(name: "web-app", shown: .working, word: "在干活")),
        (.worker, PaneFrame.Title(name: "design-system", shown: .needsYou, word: "等批准")),
    ]

    @Test(arguments: [80.0, 120.0, 160.0, 240.0])
    func everythingInTheBarIsInsideItsPadding(width: Double) throws {
        for scheme in [ColorScheme.light, .dark] {
            for (wears, title) in Self.titles {
                let runs = try Self.inkRuns(wears, title, width: width, scheme: scheme)
                let inside = Self.padding(wears) - 0.5...width - Self.padding(wears) + 0.5
                #expect(!runs.isEmpty, "nothing drawn: \(wears) \(title.name) at \(width)")
                for run in runs {
                    #expect(inside.contains(run.lowerBound) && inside.contains(run.upperBound),
                            "\(wears) \(title.name) at \(width) pt, \(scheme): ink at \(run), bar is \(inside)")
                }
            }
        }
    }

    /// The order things give way in: the role word first, so a name that
    /// fits is not cut to keep it.
    @Test func theRoleWordGoesBeforeTheNameIsCut() throws {
        let title = PaneFrame.Title(name: "design-system", shown: .needsYou, word: "等批准")
        // Wide enough for the whole name and the status, not for the role
        // word as well: name, glyph, word -- three runs, the name whole.
        let runs = try Self.inkRuns(.worker, title, width: 240, scheme: .light)
        #expect(runs.count == 3, "\(runs)")
        let whole = try Self.inkRuns(.worker, title, width: 400, scheme: .light)
        #expect(whole.count == 4, "with room for everything, the role word is there too: \(whole)")
        #expect(runs.first == whole.first, "the name is drawn whole in both: \(runs.first!) and \(whole.first!)")
    }
}
