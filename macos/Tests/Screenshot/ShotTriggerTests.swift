import CoreGraphics
import Testing
@testable import Ghostty

/// Modifiers plus a click, and the hotkey registration
/// (`dev-docs/poltergeist/screenshot.md`, 3.1).
struct ShotTriggerTests {
    private let commandShift: ShotMods = [.command, .shift]

    private func detector(_ required: ShotMods? = nil) -> ClickDetector {
        ClickDetector(required: required ?? commandShift)
    }

    // MARK: The click

    @Test func onePressWithTheModifiersIsTheGesture() {
        // Until 2026-10-07 it took two.
        var d = detector()
        let first = d.press(time: 10.0, mods: commandShift)
        #expect(first == .fired)
    }

    @Test func everyPressWithTheModifiersIsOne() {
        // Nothing is remembered from one press to the next: a second click
        // is a second gesture. (While a screenshot is up the controller
        // ignores it, and the click selects the window under it instead.)
        var d = detector()
        let first = d.leftDown(time: 10.0, mods: commandShift)
        let second = d.leftDown(time: 10.2, mods: commandShift)
        let later = d.leftDown(time: 60, mods: commandShift)
        #expect(first && second && later)
    }

    @Test func theModifiersMustBeExactlyThese() {
        var d = detector()
        // None, one of the two, and one too many: somebody else's gesture.
        let bare = d.press(time: 1, mods: [])
        let half = d.press(time: 2, mods: [.command])
        let more = d.press(time: 3, mods: [.command, .shift, .option])
        let other = d.press(time: 4, mods: [.control, .shift])
        #expect(bare == .wrongModifiers && half == .wrongModifiers)
        #expect(more == .wrongModifiers && other == .wrongModifiers)
        // And a wrong one does not spoil the right one after it.
        let right = d.press(time: 5, mods: commandShift)
        #expect(right == .fired)
    }

    @Test func noneIsOff() {
        // With nothing required every click on the machine would match.
        var d = detector([])
        let bare = d.press(time: 1, mods: [])
        let held = d.press(time: 2, mods: commandShift)
        #expect(bare == .wrongModifiers && held == .wrongModifiers)
        #expect(d.required.isEmpty)
    }

    @Test func lockKeysAndSidesAreNotModifiers() {
        // Caps lock is a bit above the four; it is neither required nor in
        // the way.
        let capsLock = ShotMods(rawValue: 1 << 4)
        var d = detector(commandShift.union(capsLock))
        #expect(d.required == commandShift)
        let withLock = d.press(time: 1, mods: commandShift.union(capsLock))
        #expect(withLock == .fired)
    }

    @Test func aPressReportedTwiceIsOnePress() {
        // One click, seen by the monitor for other applications and by the
        // one for our own, or delivered again while the click brings this
        // application to the front. With one click being the whole gesture,
        // counting it twice would ask for two screenshots.
        var d = detector()
        let first = d.press(time: 10.0, mods: commandShift)
        let again = d.press(time: 10.0, mods: commandShift)
        #expect(first == .fired)
        #expect(again == .replay)
        // A clock that went backwards is the same thing.
        let earlier = d.press(time: 9.5, mods: commandShift)
        #expect(earlier == .replay)
        // The next press a person makes is later, and counts.
        let next = d.press(time: 10.4, mods: commandShift)
        #expect(next == .fired)
        // A replay of a press with the wrong modifiers is a replay too.
        let wrong = d.press(time: 11, mods: [])
        let wrongAgain = d.press(time: 11, mods: commandShift)
        #expect(wrong == .wrongModifiers && wrongAgain == .replay)
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
