import CoreGraphics
import Testing
@testable import Ghostty

/// Modifiers plus a double-click, and the hotkey registration
/// (`dev-docs/poltergeist/screenshot.md`, 3.1).
struct ShotTriggerTests {
    private let commandShift: ShotMods = [.command, .shift]
    private let here = CGPoint(x: 500, y: 400)

    private func detector(_ required: ShotMods? = nil) -> DoubleClickDetector {
        DoubleClickDetector(required: required ?? commandShift, interval: 0.5, distance: 4)
    }

    // MARK: The double-click

    @Test func twoPressesWithTheModifiersIsTheGesture() {
        var d = detector()
        let first = d.leftDown(at: here, time: 10.0, mods: commandShift)
        let second = d.leftDown(at: here, time: 10.2, mods: commandShift)
        #expect(!first)
        #expect(second)
    }

    @Test func onePressIsNot() {
        var d = detector()
        let result1 = d.leftDown(at: here, time: 10.0, mods: commandShift)
        #expect(!result1)
    }

    @Test func theIntervalIsInclusiveAndNoLonger() {
        var onTime = detector()
        _ = onTime.leftDown(at: here, time: 10.0, mods: commandShift)
        let result2 = onTime.leftDown(at: here, time: 10.5, mods: commandShift)
        #expect(result2)

        var late = detector()
        _ = late.leftDown(at: here, time: 10.0, mods: commandShift)
        let result3 = late.leftDown(at: here, time: 10.501, mods: commandShift)
        #expect(!result3)
    }

    @Test func aLatePressStartsANewGesture() {
        var d = detector()
        _ = d.leftDown(at: here, time: 10.0, mods: commandShift)
        let result4 = d.leftDown(at: here, time: 11.0, mods: commandShift)
        #expect(!result4)
        // The late one counts as a first press.
        let result5 = d.leftDown(at: here, time: 11.2, mods: commandShift)
        #expect(result5)
    }

    @Test func theDistanceIsInclusiveAndNoFurther() {
        var near = detector()
        _ = near.leftDown(at: here, time: 10.0, mods: commandShift)
        let result6 = near.leftDown(at: CGPoint(x: 504, y: 396), time: 10.1, mods: commandShift)
        #expect(result6)

        var far = detector()
        _ = far.leftDown(at: here, time: 10.0, mods: commandShift)
        let result7 = far.leftDown(at: CGPoint(x: 505, y: 400), time: 10.1, mods: commandShift)
        #expect(!result7)

        var farDown = detector()
        _ = farDown.leftDown(at: here, time: 10.0, mods: commandShift)
        let result8 = farDown.leftDown(at: CGPoint(x: 500, y: 405), time: 10.1, mods: commandShift)
        #expect(!result8)
    }

    @Test func theModifiersMustBeExactlyTheseOnBothPresses() {
        let cases: [(ShotMods, ShotMods)] = [
            // One more on either press.
            ([.command, .shift, .option], [.command, .shift]),
            ([.command, .shift], [.command, .shift, .control]),
            ([.command, .shift, .option], [.command, .shift, .option]),
            // One fewer.
            ([.command], [.command, .shift]),
            ([.command, .shift], [.shift]),
            // None.
            ([], []),
            // A different pair.
            ([.control, .shift], [.control, .shift]),
        ]
        for (first, second) in cases {
            var d = detector()
            let a = d.leftDown(at: here, time: 10.0, mods: first)
            let b = d.leftDown(at: here, time: 10.1, mods: second)
            #expect(!a && !b, "\(first.rawValue) then \(second.rawValue) fired")
        }
    }

    @Test func aPressWithTheWrongModifiersForgetsTheOneBefore() {
        var d = detector()
        _ = d.leftDown(at: here, time: 10.0, mods: commandShift)
        _ = d.leftDown(at: here, time: 10.1, mods: [.command])
        // Right, wrong, right: the two right ones are not a double-click.
        let result9 = d.leftDown(at: here, time: 10.2, mods: commandShift)
        #expect(!result9)
    }

    @Test func aThirdPressDoesNotFireAgain() {
        var d = detector()
        _ = d.leftDown(at: here, time: 10.0, mods: commandShift)
        let result10 = d.leftDown(at: here, time: 10.1, mods: commandShift)
        #expect(result10)
        let result11 = d.leftDown(at: here, time: 10.2, mods: commandShift)
        #expect(!result11)
        // The fourth completes a second gesture.
        let result12 = d.leftDown(at: here, time: 10.3, mods: commandShift)
        #expect(result12)
    }

    @Test func noneIsOff() {
        var d = detector([])
        let first = d.leftDown(at: here, time: 10.0, mods: [])
        let second = d.leftDown(at: here, time: 10.1, mods: [])
        #expect(!first && !second)
    }

    @Test func lockKeysAndSidesAreNotModifiers() {
        // Caps lock (16) and num lock (32) ride along in the raw value.
        var d = detector()
        let withCapsLock = ShotMods(rawValue: commandShift.rawValue | 16 | 32)
        _ = d.leftDown(at: here, time: 10.0, mods: withCapsLock)
        let result13 = d.leftDown(at: here, time: 10.1, mods: commandShift)
        #expect(result13)
    }

    @Test func aClockThatWentBackwardsIsNotADoubleClick() {
        var d = detector()
        _ = d.leftDown(at: here, time: 10.0, mods: commandShift)
        let result14 = d.leftDown(at: here, time: 9.0, mods: commandShift)
        #expect(!result14)
    }

    /// One click can be reported twice: by the monitor for other
    /// applications' events and by the one for our own, or again while the
    /// click is bringing this application to the front. Two reports of one
    /// press are within any double-click interval of each other.
    @Test func aPressReportedTwiceIsOnePress() {
        var d = detector()
        #expect(d.press(at: here, time: 10.0, mods: commandShift) == .first)
        #expect(d.press(at: here, time: 10.0, mods: commandShift) == .replay, "one click is not a double click")
        #expect(d.press(at: here, time: 10.2, mods: commandShift) == .fired)
        #expect(d.press(at: here, time: 10.2, mods: commandShift) == .replay, "and a double click fires once")
        // The gesture is spent as before: the next press starts over.
        #expect(d.press(at: here, time: 10.3, mods: commandShift) == .first)
    }

    @Test func bothReportsOfBothPressesInEitherOrderFireOnce() {
        // Each press twice, back to back.
        var paired = detector()
        let a = [10.0, 10.0, 10.2, 10.2].map { paired.press(at: here, time: $0, mods: commandShift) }
        #expect(a == [.first, .replay, .fired, .replay])
        // Both presses once, then both again.
        var replayed = detector()
        let b = [10.0, 10.2, 10.0, 10.2].map { replayed.press(at: here, time: $0, mods: commandShift) }
        #expect(b == [.first, .fired, .replay, .replay])
        #expect(a.filter { $0 == .fired }.count == 1)
        #expect(b.filter { $0 == .fired }.count == 1)
    }

    @Test func aReplayChangesNothing() {
        var d = detector()
        _ = d.press(at: here, time: 10.0, mods: commandShift)
        let before = d
        // Reported again from somewhere else on the screen and with other
        // modifiers: still the press already counted, and it neither moves
        // the first press nor forgets it.
        #expect(d.press(at: CGPoint(x: 900, y: 900), time: 10.0, mods: [.command]) == .replay)
        #expect(d == before)
        #expect(d.press(at: here, time: 10.1, mods: commandShift) == .fired)
    }

    @Test func aPressWithTheWrongModifiersIsStillTheLatestPress() {
        var d = detector()
        #expect(d.press(at: here, time: 10.0, mods: [.command]) == .wrongModifiers)
        #expect(d.press(at: here, time: 10.0, mods: commandShift) == .replay)
        #expect(d.press(at: here, time: 10.1, mods: commandShift) == .first)
        #expect(d.press(at: here, time: 10.2, mods: [.command]) == .wrongModifiers)
        #expect(d.press(at: here, time: 10.3, mods: commandShift) == .first, "the wrong one forgot the first")
    }

    @Test func theConfiguredBitsAreTheseModifiers() {
        // `ghostty_input_mods_e`: shift 1, ctrl 2, alt 4, super 8.
        #expect(ShotMods(rawValue: 8 | 1) == [.command, .shift])
        #expect(ShotMods(rawValue: 2 | 4) == [.control, .option])
    }

    // MARK: The hotkey

    @Test func theDefaultHotkeyIsCommandShiftZero() {
        let spec = ShotHotKey.spec(
            keyCode: ShotHotKey.keyCode(forUnicode: UInt32(Character("0").asciiValue!)),
            mods: [.command, .shift])
        // kVK_ANSI_0, and cmdKey | shiftKey.
        #expect(spec == ShotHotKey.Spec(keyCode: 29, modifiers: 0x0100 | 0x0200))
    }

    @Test func eachModifierHasItsOwnCarbonBit() {
        #expect(ShotHotKey.carbonModifiers([.command]) == 0x0100)
        #expect(ShotHotKey.carbonModifiers([.shift]) == 0x0200)
        #expect(ShotHotKey.carbonModifiers([.option]) == 0x0800)
        #expect(ShotHotKey.carbonModifiers([.control]) == 0x1000)
        #expect(ShotHotKey.carbonModifiers([.command, .shift, .option, .control]) == 0x1B00)
    }

    @Test func lettersAreCaseInsensitiveAndUnknownCharactersHaveNoKey() {
        #expect(ShotHotKey.keyCode(forUnicode: 0x61) == 0)   // a
        #expect(ShotHotKey.keyCode(forUnicode: 0x41) == 0)   // A
        #expect(ShotHotKey.keyCode(forUnicode: 0x32) == 19)  // 2
        #expect(ShotHotKey.keyCode(forUnicode: 0x60) == 50)  // `
        #expect(ShotHotKey.keyCode(forUnicode: 0x4E2D) == nil)  // 中
        #expect(ShotHotKey.keyCode(forUnicode: 0xD800) == nil)  // not a scalar
    }

    @Test func aBareKeyIsNotRegistered() {
        #expect(ShotHotKey.spec(keyCode: 29, mods: []) == nil)
        #expect(ShotHotKey.spec(keyCode: nil, mods: [.command]) == nil)
        // Caps lock alone is not a modifier either.
        #expect(ShotHotKey.spec(keyCode: 29, mods: ShotMods(rawValue: 16)) == nil)
    }
}
