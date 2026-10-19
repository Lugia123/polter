import AppKit
import Foundation
import Testing
@testable import Ghostty

/// A system face that may not be there (`SafeFace`, task 1753). The crash of
/// task 1718 was a nil `NSFont` reaching CoreText, from a factory the SDK
/// says never returns nil. These hold that a nil is never kept, that
/// measuring without a face estimates instead of reaching CoreText, and that
/// the line count a missing face's zero line height leads to does not trap.
struct SafeFontTests {
    private let real = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    /// A maker that has no face for its first `failures` calls, and counts.
    private final class Flaky: @unchecked Sendable {
        var calls = 0
        let failures: Int
        let font: NSFont
        init(failures: Int, font: NSFont) {
            self.failures = failures
            self.font = font
        }
        func make(_: CGFloat, _: NSFont.Weight, _: SafeFace.Design) -> NSFont? {
            calls += 1
            return calls <= failures ? nil : font
        }
    }

    @Test func aMissingFaceIsAskedForAgainAndThenKept() {
        let flaky = Flaky(failures: 1, font: real)
        let face = SafeFace(size: 15, design: .monospaced, make: flaky.make, standIn: { _, _, _ in nil })
        #expect(face.font == nil)
        #expect(face.font === real)
        #expect(face.font === real)
        // Asked twice: the nil was not kept, the face was.
        #expect(flaky.calls == 2)
    }

    @Test func aStandInIsUsedButNotKept() {
        let flaky = Flaky(failures: 2, font: real)
        let menlo = NSFont(name: "Menlo", size: 15)!
        let face = SafeFace(size: 15, design: .monospaced, make: flaky.make, standIn: { _, _, _ in menlo })
        #expect(face.font === menlo)
        #expect(face.font === menlo)
        #expect(face.font === real)
        #expect(flaky.calls == 3)
    }

    @Test func measuringWithNoFaceEstimatesAtTheFacesSize() {
        let face = SafeFace(size: 15, make: { _, _, _ in nil }, standIn: { _, _, _ in nil })
        let text = "a title 总管"
        // Eight narrow characters and two wide ones, at 15 points.
        #expect(abs(SafeTextMeasure.width(text, in: face) - (8 * 9 + 2 * 15)) < 0.001)
        let wrapped = SafeTextMeasure.height(String(repeating: "x", count: 99), in: face, wrappingAt: 300)
        #expect(wrapped == CGFloat(45))
    }

    @Test func measuringWithAFaceMeasuresWhatTheTextSystemMeasures() {
        let face = SafeFace(size: 15, design: .monospaced, make: { _, _, _ in self.real })
        let text = "polter · 总管 ⠋"
        let direct = (text as NSString).size(withAttributes: [.font: real]).width
        #expect(SafeTextMeasure.width(text, in: face) == direct)
    }

    // No test measures with a nil font: the throw it causes comes out of
    // CoreText, and a throw from there is not caught by the `@try` in
    // `GhosttyMeasureTextSafely` -- it ends the process, test runner and all
    // (measured, task 1753). That is why the faces above are kept from ever
    // being nil rather than caught after the fact.

    @Test func aLineHeightThatIsNotPositiveCountsAsOneLine() {
        #expect(SafeTextMeasure.lines(height: 45, lineHeight: 15) == 3)
        #expect(SafeTextMeasure.lines(height: 45, lineHeight: 0) == 1)
        #expect(SafeTextMeasure.lines(height: 45, lineHeight: -1) == 1)
        #expect(SafeTextMeasure.lines(height: .infinity, lineHeight: 15) == 1)
        #expect(SafeTextMeasure.lines(height: 1, lineHeight: 15) == 1)
    }

    @Test func theSystemGivesItsFacesThroughTheNullableFactory() {
        #expect(SafeFace.system(15, .regular, .monospaced) != nil)
        #expect(SafeFace.system(15, .semibold, .system) != nil)
    }

    /// The menu's and the title bar's faces are AppKit's own (task 1805):
    /// the same font the direct factory gives, size 0 included.
    @Test func theMenuAndTitleBarFacesAreAppKits() {
        let menu = SafeFace.system(0, .regular, .menu)
        #expect(menu?.fontName == NSFont.menuFont(ofSize: 0).fontName)
        #expect(menu?.pointSize == NSFont.menuFont(ofSize: 0).pointSize)
        let title = SafeFace.system(13, .regular, .titleBar)
        #expect(title?.fontName == NSFont.titleBarFont(ofSize: 13).fontName)
        #expect(SafeFace.menu.pointSize == NSFont.menuFont(ofSize: 0).pointSize)
    }

    /// A face asked for at AppKit's default size (0) is set at the size the
    /// face came at, and at the system's font size while there is none --
    /// never at 0, which is what an estimate or SwiftUI's stand-in would
    /// be made at otherwise (task 1805).
    @Test func aDefaultSizedFaceWithoutAFontHasTheSystemsSize() {
        let none = SafeFace(size: 0, design: .menu, make: { _, _, _ in nil }, standIn: { _, _, _ in nil })
        #expect(none.pointSize == NSFont.systemFontSize)
        let sized = SafeFace(size: 0, design: .menu, make: { _, _, _ in NSFont.menuFont(ofSize: 17) })
        #expect(sized.pointSize == 17)
        // A size that was asked for is the size, face or not.
        #expect(SafeFace(size: 15, make: { _, _, _ in nil }, standIn: { _, _, _ in nil }).pointSize == 15)
        let estimated = SafeTextMeasure.width("x", in: none)
        #expect(estimated > 0)
    }
}
