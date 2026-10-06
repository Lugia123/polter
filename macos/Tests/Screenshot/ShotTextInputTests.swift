import AppKit
import Testing
@testable import Ghostty

/// What the text box may do while an input method is at work in it, who
/// has the keyboard while the picture is up, and the box itself driven the
/// way an input method drives it (`dev-docs/poltergeist/screenshot.md`, 3.2
/// and 9.3; task 1110).
///
/// The views here are in no window on any screen. That is enough for what a
/// text view does with the calls it is given; it says nothing about what a
/// real input method sends.
@MainActor
struct ShotTextInputTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    // MARK: The rules

    @Test func aChangeOutsideTheInputMethodsCallIsActedOnAtOnce() {
        var gate = ShotTextInput.Gate()
        let now = gate.changed()
        #expect(now)
        #expect(!gate.waiting)
    }

    @Test func aChangeInsideTheInputMethodsCallWaitsForItsEndAndIsActedOnOnce() {
        var gate = ShotTextInput.Gate()
        gate.enter()
        let first = gate.changed()
        let second = gate.changed()
        #expect(!first)
        #expect(!second)
        let atEnd = gate.leave()
        #expect(atEnd, "three changes inside one call: one placing, when it is over")
        let after = gate.changed()
        #expect(after, "and the next change, outside, is acted on at once again")
    }

    @Test func nestedCallsWaitForTheOutermost() {
        var gate = ShotTextInput.Gate()
        gate.enter()
        gate.enter()
        _ = gate.changed()
        let inner = gate.leave()
        #expect(!inner, "accepting a composition unmarks inside insertText: not yet")
        let outer = gate.leave()
        #expect(outer)
    }

    @Test func aCallThatChangedNothingPlacesNothing() {
        var gate = ShotTextInput.Gate()
        gate.enter()
        let atEnd = gate.leave()
        #expect(!atEnd)
        // One leave too many is not a call in progress for ever after.
        let extra = gate.leave()
        #expect(!extra)
        let now = gate.changed()
        #expect(now)
    }

    @Test func aColourPressedWhileComposingReachesOnlyWhatWillBeTyped() {
        #expect(ShotTextInput.restyle(composing: false) == .everything)
        #expect(ShotTextInput.restyle(composing: true) == .typingOnly)
        // What was held back is done when the composition is over, not before.
        #expect(!ShotTextInput.restyleDue(held: true, composing: true))
        #expect(ShotTextInput.restyleDue(held: true, composing: false))
        #expect(!ShotTextInput.restyleDue(held: false, composing: false))
    }

    // MARK: The keyboard

    /// The readings of task 1110: the overlay is at the shielding level, a
    /// terminal window at the normal one.
    @Test func theKeyboardIsTakenBackFromAWindowBehindThePicture() {
        let overlay = 2_147_483_628
        let terminal = ShotKeyHold.Window(level: 0, isModal: false)
        #expect(ShotKeyHold.takesBack(from: terminal, overlayLevel: overlay))
        let floating = ShotKeyHold.Window(level: 3, isModal: false)
        #expect(ShotKeyHold.takesBack(from: floating, overlayLevel: overlay))
    }

    @Test func theKeyboardIsLeftWithAnAlertAndWithWhatIsOverThePicture() {
        let overlay = 2_147_483_628
        let alert = ShotKeyHold.Window(level: 8, isModal: true)
        #expect(!ShotKeyHold.takesBack(from: alert, overlayLevel: overlay), "an alert the application is waiting on")
        let above = ShotKeyHold.Window(level: overlay, isModal: false)
        #expect(!ShotKeyHold.takesBack(from: above, overlayLevel: overlay), "at the overlay's level it can be seen to have the keyboard")
    }

    // MARK: The box, driven as an input method drives it

    private func font() -> NSFont { NSFont.systemFont(ofSize: 20) }

    private func box(_ frame: NSRect, text: String = "") -> ShotTextScroll {
        let typing = ShotTextScroll(box: frame)
        let view = typing.text
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.font = font()
        view.typingAttributes = [.font: font()]
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return typing
    }

    /// Pinyin `nihao`, key by key, then the candidate: the calls the input
    /// method makes. Returns what the marked range was each time the box
    /// was placed.
    private func compose(in view: ShotTextView) -> [NSRange] {
        var marked: [NSRange] = []
        view.onChange = { marked.append(view.markedRange()) }
        for s in ["n", "ni", "ni h", "ni ha", "ni hao"] {
            view.setMarkedText(
                s, selectedRange: NSRange(location: (s as NSString).length, length: 0), replacementRange: none)
        }
        view.insertText("你好", replacementRange: none)
        view.onChange = nil
        return marked
    }

    @Test func aNewBoxDoesNotRebuildItsLayoutUnderTheFirstKey() {
        let view = box(NSRect(x: 0, y: 0, width: 300, height: 30)).text
        #expect(view.textLayoutManager == nil, "on the layout manager it is measured through, before a key")

        var rebuilt = 0
        let watch = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: view, queue: nil
        ) { _ in rebuilt += 1 }
        defer { NotificationCenter.default.removeObserver(watch) }
        view.onChange = { _ = view.laidOutLines }
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(rebuilt == 0, "the first key of a composition is not when the view changes its layout system")
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
    }

    @Test func theBoxIsPlacedOnceForEachCallAndOnlyWhenTheCallIsOver() {
        let view = box(NSRect(x: 0, y: 0, width: 300, height: 30)).text
        let marked = compose(in: view)
        #expect(view.string == "你好")
        // Five keys and the candidate: six placings, not three for each.
        #expect(marked.count == 6)
        // Each with the composition whole. Inside the first call the marked
        // range is the empty one after the "n" for a while: never seen here.
        #expect(Array(marked.prefix(5)) == [1, 2, 4, 5, 6].map { NSRange(location: 0, length: $0) })
        #expect(marked.last?.length == 0, "and none once it is accepted")
    }

    @Test func composingAfterWhatIsThereKeepsIt() {
        let view = box(NSRect(x: 0, y: 0, width: 300, height: 30), text: "ab").text
        let marked = compose(in: view)
        #expect(view.string == "ab你好")
        #expect(marked.first == NSRange(location: 2, length: 1))
    }

    // MARK: Scrolling in the box

    /// A box that grows a line at a time to three lines and stops, as
    /// `ShotTextBox.rect` makes it at the selection's bottom edge.
    private func threeLineBox() -> (ShotTextScroll, pitch: CGFloat) {
        let probe = box(NSRect(x: 40, y: 60, width: 300, height: 10))
        let pitch = probe.text.layoutManager?.defaultLineHeight(for: font()) ?? 0
        let typing = box(NSRect(x: 40, y: 60, width: 300, height: pitch))
        typing.text.onChange = { [unowned typing] in
            let lines = min(typing.text.laidOutLines, 3)
            typing.place(NSRect(x: 40, y: 60, width: 300, height: CGFloat(lines) * pitch))
        }
        return (typing, pitch)
    }

    private func caretInView(_ typing: ShotTextScroll) -> Bool {
        let line = typing.caretLine
        let visible = typing.documentVisibleRect
        return !line.isEmpty && line.minY >= visible.minY - 0.5 && line.maxY <= visible.maxY + 0.5
    }

    private func type(_ lines: ClosedRange<Int>, into typing: ShotTextScroll) {
        for i in lines {
            if i > lines.lowerBound || !typing.text.string.isEmpty { typing.text.insertNewline(nil) }
            typing.text.insertText("L\(i)", replacementRange: none)
        }
    }

    @Test func theBoxGrowsToItsLimitAndThenTheCaretsLineStaysInView() {
        let (typing, pitch) = threeLineBox()
        #expect(pitch > 0)
        var heights: [CGFloat] = []
        for i in 1...7 {
            type(i...i, into: typing)
            heights.append(typing.frame.height / pitch)
            #expect(caretInView(typing), "line \(i)")
        }
        #expect(heights == [1, 2, 3, 3, 3, 3, 3])
        #expect(typing.frame.origin == NSPoint(x: 40, y: 60), "it grows downwards from where it was put")
        // Seven lines in a box of three: the last three are the ones in view.
        #expect(abs(typing.documentVisibleRect.minY - 4 * pitch) < 0.5)
        // A line break with nothing after it is a line too, and the caret is on it.
        typing.text.insertNewline(nil)
        #expect(caretInView(typing))
        #expect(abs(typing.documentVisibleRect.minY - 5 * pitch) < 0.5)
    }

    @Test func movingTheCaretUpBringsItsLineIntoViewAndSoDoesDeleting() {
        let (typing, pitch) = threeLineBox()
        type(1...7, into: typing)
        for step in 1...6 {
            typing.text.moveUp(nil)
            #expect(caretInView(typing), "up \(step)")
        }
        #expect(typing.documentVisibleRect.minY < 0.5, "the caret is on the first line: the top is in view")

        typing.text.moveToEndOfDocument(nil)
        #expect(caretInView(typing))
        #expect(abs(typing.documentVisibleRect.minY - 4 * pitch) < 0.5)
        // Back to three lines: everything fits, and the box is at its top.
        while ShotTextBox.lines(in: typing.text.string) > 3 {
            typing.text.deleteBackward(nil)
            #expect(caretInView(typing))
        }
        #expect(typing.text.string == "L1\nL2\nL3")
        #expect(typing.documentVisibleRect.minY < 0.5)
        #expect(abs(typing.frame.height - 3 * pitch) < 0.5)
        // And shorter again when it holds less.
        for _ in 0..<3 { typing.text.deleteBackward(nil) }
        #expect(abs(typing.frame.height - 2 * pitch) < 0.5)
        #expect(typing.documentVisibleRect.minY < 0.5)
    }

    @Test func aBoxMadeShorterStillShowsTheCaretsLine() {
        // A bigger size is a taller line and so fewer of them in the box:
        // the box is placed again with nothing typed.
        let (typing, pitch) = threeLineBox()
        type(1...7, into: typing)
        typing.place(NSRect(x: 40, y: 60, width: 300, height: 2 * pitch))
        #expect(caretInView(typing))
        #expect(abs(typing.documentVisibleRect.minY - 5 * pitch) < 0.5)
    }

    @Test func composingInAFullBoxScrollsWithoutEndingTheComposition() {
        let (typing, _) = threeLineBox()
        type(1...5, into: typing)
        typing.text.insertNewline(nil)
        let before = (typing.text.string as NSString).length
        for s in ["n", "ni", "ni h", "ni ha", "ni hao"] {
            typing.text.setMarkedText(
                s, selectedRange: NSRange(location: (s as NSString).length, length: 0), replacementRange: none)
            #expect(typing.text.markedRange() == NSRange(location: before, length: (s as NSString).length))
            #expect(caretInView(typing))
        }
        typing.text.insertText("你好", replacementRange: none)
        #expect(typing.text.string == "L1\nL2\nL3\nL4\nL5\n你好")
        #expect(caretInView(typing))
    }
}
