import Foundation
import CoreGraphics
import Testing
@testable import Ghostty

/// Where a terminal was while it is shown somewhere else: its last frame
/// here, frosted, under the sentence (`ControlRoomElsewhere`).
struct ControlRoomElsewhereTests {
    typealias Look = ControlRoomLook
    typealias Loan = ControlRoomLending.Loan

    private func picture() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    // MARK: Which frame

    @Test func theFrameUnderTakenBackIsTheOneTakenFromThatTerminal() throws {
        let frame = try picture()
        let mine = ControlRoomElsewhere.frame(
            for: .takenBack(Loan(group: "billing", terminal: "t1")), frozen: (terminal: "t1", frame: frame))
        #expect(mine === frame)
        // Another terminal's last frame is not this one's.
        let theirs = ControlRoomElsewhere.frame(
            for: .takenBack(Loan(group: "search", terminal: "t2")), frozen: (terminal: "t1", frame: frame))
        #expect(theirs == nil)
        // Never drawn here: the flat ground, as before.
        let none = ControlRoomElsewhere.frame(for: .takenBack(Loan(group: "billing", terminal: "t1")), frozen: nil)
        #expect(none == nil)
    }

    @Test func theOtherWaysOfHavingNoTerminalAreNotATerminalSomewhereElse() throws {
        // No supervisor, gone, nothing selected, the terminal itself: none
        // of them is "it is over there", and none gets the frame.
        let frozen = (terminal: "t1", frame: try picture())
        let others: [ControlRoomLending.Detail] = [
            .nothingSelected,
            .noSupervisor(group: "billing"),
            .supervisorGone(group: "billing"),
            .terminal(Loan(group: "billing", terminal: "t1")),
        ]
        for detail in others {
            let shown = ControlRoomElsewhere.frame(for: detail, frozen: frozen)
            #expect(shown == nil)
        }
    }

    // MARK: The frame kept

    @Test func aFrameIsKeptSmallAndInItsOwnShape() {
        // A retina pane, 1300x800 points.
        let big = ControlRoomElsewhere.keptSize(of: CGSize(width: 2600, height: 1600))
        #expect(big == CGSize(width: 640, height: 394))
        let tall = ControlRoomElsewhere.keptSize(of: CGSize(width: 800, height: 3200))
        #expect(tall == CGSize(width: 160, height: 640))
        // Never enlarged.
        let small = ControlRoomElsewhere.keptSize(of: CGSize(width: 300, height: 200))
        #expect(small == CGSize(width: 300, height: 200))
        let nothing = ControlRoomElsewhere.keptSize(of: .zero)
        #expect(nothing == nil)
    }

    // MARK: The words over it

    @Test func oneButtonIsCalledByBothOfItsLines() {
        let label = ControlRoomElsewhere.label(sentence: "Showing in the control room", action: "Click to switch here")
        #expect(label == "Showing in the control room Click to switch here")
    }

    /// WCAG relative luminance of an sRGB colour.
    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func channel(_ value: Double) -> Double {
            let c = value / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func contrast(_ text: Look.RGBA, over ground: (Double, Double, Double)) -> Double {
        let a = luminance(Double(text.r), Double(text.g), Double(text.b))
        let b = luminance(ground.0, ground.1, ground.2)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Every size the two lines of words can be: one short word to a
    /// sentence the width of a wide pane, two lines to a wrapped four.
    private static let words: [CGSize] = [40, 150, 190, 300, 600, 900].flatMap { width in
        [16, 40, 60, 80].map { CGSize(width: CGFloat(width), height: CGFloat($0)) }
    }

    @Test func theWordsCanBeReadOverAnyFrameAtAll() {
        // The frame is whatever the terminal drew: all white and all black
        // are the two it can be furthest from the ground. With the thin
        // veil over all of it and the shade behind the words, both lines
        // keep 4.5:1 in both themes, however long the words are.
        for size in Self.words {
            let over = ControlRoomElsewhere.groundUnderWords(of: size)
            for dark in [true, false] {
                let theme = Look.theme(dark: dark)
                let ground = theme.terminalBackground
                for frame in [0.0, 255.0] {
                    let under = (
                        Double(ground.r) * over + frame * (1 - over),
                        Double(ground.g) * over + frame * (1 - over),
                        Double(ground.b) * over + frame * (1 - over))
                    let sentence = contrast(theme.textSecondary, over: under)
                    #expect(sentence >= 4.5)
                    let action = contrast(theme.attentionText, over: under)
                    #expect(action >= 4.5)
                }
            }
        }
    }

    @Test func theShadeIsWholeUnderEveryCornerOfTheWords() {
        // The corners of the words' box are where the shade is thinnest
        // under them; it has not begun to fade there.
        for size in Self.words {
            let corner = ControlRoomElsewhere.shadeAtCorner(ofWords: size)
            #expect(corner == Look.Elsewhere.shade)
        }
    }

    @Test func theShadeFadesToNothingAndHasNoEdge() {
        let stops = ControlRoomElsewhere.shadeStops
        #expect(stops.first?.amount == Look.Elsewhere.shade)
        #expect(stops.last?.amount == 0)
        #expect(stops.last?.at == 1)
        // Never a step: each stop is no more than the one before it, and
        // no two neighbours differ by more than a third of the whole.
        for (inner, outer) in zip(stops, stops.dropFirst()) {
            #expect(outer.amount <= inner.amount)
            #expect(inner.amount - outer.amount <= Look.Elsewhere.shade * 0.36)
            #expect(outer.at >= inner.at)
        }
    }

    @Test func theVeilAloneLeavesTheFrameToBeSeen() {
        // What the shade is for: the veil over the whole place is thin.
        // (At 0.86 the frame was a faint shadow -- build-18.)
        #expect(Look.Elsewhere.veil <= 0.7)
    }

    @Test func nothingOverItIsSmallerThanTheMenuFont() {
        #expect(Look.Font.body >= Look.Font.min)
        #expect(Look.Font.min >= 13)
    }
}
