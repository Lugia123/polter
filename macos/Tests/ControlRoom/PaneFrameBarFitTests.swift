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
        // A pane of a split's supervisor, with its badge (task 1692).
        (.supervisor, PaneFrame.Title(name: "web-app-batch-edit", shown: .working, word: "在干活", badged: true)),
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

    // MARK: The supervisor's badge (task 1692)

    /// How many pixels of the bar are the badge's ground, at a scale of 2.
    /// Its ground and nothing else: the word and the mark on it are white,
    /// and no other colour of a bar is near it.
    static func badgePixels(_ wears: PaneFrame.Kind, _ title: PaneFrame.Title, width: Double, scheme: ColorScheme) throws -> Int {
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
        let want = Look.theme(dark: scheme == .dark).supervisorBadge
        var count = 0
        for y in 0..<Int(Look.Pane.barHeight * scale) {
            for x in 0..<Int(width * scale) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let d = abs(c.redComponent * 255 - Double(want.r)) + abs(c.greenComponent * 255 - Double(want.g))
                    + abs(c.blueComponent * 255 - Double(want.b))
                if d < 24 { count += 1 }
            }
        }
        return count
    }

    /// The design's C: a supervisor's bar says what it is with a badge at
    /// its left end, and **the badge is never what gives way**: the name is
    /// cut and the status word goes first, and while the bar has room for
    /// it all of the badge is there, the same as with room to spare. Where
    /// it has not, the badge keeps its mark (and the ink stays inside the
    /// bar: `everythingInTheBarIsInsideItsPadding`). No other frame has one.
    @Test func theSupervisorsBadgeIsWholeAtEveryWidthAndOnlyASupervisorHasOne() throws {
        let supervisor = PaneFrame.Title(name: "web-app-batch-edit", shown: .working, word: "在干活", badged: true)
        for scheme in [ColorScheme.light, .dark] {
            let whole = try Self.badgePixels(.supervisor, supervisor, width: 600, scheme: scheme)
            // 20 high and some 40 wide or more at a scale of 2.
            #expect(whole > 20 * 40 * 2, "\(scheme): \(whole) pixels of the badge")
            for width in [160.0, 240.0] {
                let narrow = try Self.badgePixels(.supervisor, supervisor, width: width, scheme: scheme)
                #expect(narrow == whole, "\(scheme) at \(width) pt: \(narrow) pixels of the badge, \(whole) with room")
            }
            for width in [80.0, 120.0] {
                let mark = try Self.badgePixels(.supervisor, supervisor, width: width, scheme: scheme)
                #expect(mark > 20 * 20 * 2, "\(scheme) at \(width) pt: \(mark) pixels of the badge")
            }
            for wears in [PaneFrame.Kind.worker, .plain] {
                let none = try Self.badgePixels(wears, PaneFrame.Title(name: "api", shown: .working, word: "在干活"), width: 400, scheme: scheme)
                #expect(none == 0, "\(wears), \(scheme): \(none)")
            }
        }
    }

    /// The control room's own frame has no badge: it is the supervisor's
    /// and nothing else, and the Windows host draws it without one.
    @Test func theControlRoomsFrameHasNoBadge() throws {
        let group = PaneFrame.Title(ControlRoomList.SupervisorTitle(name: "web-app", shown: .working, word: "在干活"))
        #expect(try Self.badgePixels(.supervisor, group, width: 400, scheme: .light) == 0)
        let split = PaneFrame.Title(name: "web-app", shown: .working, word: "在干活", badged: true)
        #expect(try Self.badgePixels(.supervisor, split, width: 400, scheme: .light) > 0)
    }

    /// The edge round a supervisor's pane with no frames: just inside it,
    /// `supervisor_badge.edge` thick on every side, and nothing further in.
    @Test func theEdgeIsJustInsideThePaneOnEverySide() throws {
        for scheme in [ColorScheme.light, .dark] {
            for shows in [true, false] {
                let view = Color.clear.frame(width: 200, height: 100)
                    .modifier(PaneSupervisorEdge(shows: shows))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                let want = Look.theme(dark: scheme == .dark).supervisorMark
                func isMark(_ x: Int, _ y: Int) -> Bool {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { return false }
                    return abs(c.redComponent * 255 - Double(want.r)) + abs(c.greenComponent * 255 - Double(want.g))
                        + abs(c.blueComponent * 255 - Double(want.b)) < 12
                }
                let edge = Int(Look.SupervisorBadge.edge * 2)
                // The middle of each side, just inside the edge's width and just past it.
                let inside = [(0, 100), (edge - 1, 100), (399, 100), (400 - edge, 100), (200, 0), (200, edge - 1), (200, 199), (200, 200 - edge)]
                let past = [(edge, 100), (399 - edge, 100), (200, edge), (200, 199 - edge), (200, 100)]
                for (x, y) in inside {
                    #expect(isMark(x, y) == shows, "\(scheme) shows=\(shows) at \(x),\(y)")
                }
                for (x, y) in past {
                    #expect(!isMark(x, y), "\(scheme) shows=\(shows) at \(x),\(y)")
                }
            }
        }
    }
}
