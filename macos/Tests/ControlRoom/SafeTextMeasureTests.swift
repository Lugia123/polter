import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Measuring text where a throw from the text system is caught
/// (`SafeTextMeasure`, task 1718). The throw is made inside the guard, by the
/// same call into the same class CoreText's throw came from; before the
/// guard it reached the main thread's run loop and aborted the app.
struct SafeTextMeasureTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    @Test func measuresWhatTheTextSystemMeasures() {
        let text = "polter · 总管 ⠋"
        let direct = (text as NSString).size(withAttributes: [.font: font]).width
        #expect(SafeTextMeasure.width(text, font: font) == direct)
    }

    @Test func aThrowIsCaughtAndNamed() {
        let text = NSAttributedString(string: "a title", attributes: [.font: font])
        let result = SafeTextMeasure.measure(text, failForTesting: true)
        guard case .failure(let error) = result else {
            Issue.record("the measurement did not fail: \(result)")
            return
        }
        #expect(error.localizedDescription.contains("attempt to insert nil object from objects[0]"))
    }

    @Test func aThrowGivesTheEstimate() {
        let text = NSAttributedString(string: "a title 总管", attributes: [.font: font])
        let size = SafeTextMeasure.size(text, failForTesting: true)
        let guess = SafeTextMeasure.estimate(text)
        // Eight narrow characters and two wide ones.
        #expect(abs(guess.width - (8 * 9 + 2 * 15)) < 0.001)
        #expect(size == guess)
    }

    @Test func aThrowWhileWrappingGivesTheEstimate() {
        let text = NSAttributedString(string: String(repeating: "x", count: 99), attributes: [.font: font])
        let size = SafeTextMeasure.size(text, wrappingAt: 300, failForTesting: true)
        // 99 × 9 = 891 points: three lines of 300.
        #expect(size == SafeTextMeasure.estimate(text, wrappingAt: 300))
        #expect(size.height == 3 * ceil(font.ascender - font.descender + font.leading))
    }
}
