import Foundation
import Testing
@testable import Ghostty

/// The Windows host's `toolbar.rs` tests, with the same fixtures and the
/// same numbers (`dev-docs/poltergeist/screenshot.md`, 9.1 and 9.7).
struct ShotToolbarLayoutTests {
    private typealias Pt = PixelPoint
    private typealias Grid = ShotToolbarGrid
    private let display = PixelRect(0, 0, 2560, 1440)
    private let selection = PixelRect(400, 200, 900, 500)

    private func layout(_ props: AnnotationTool.Props, scale: Double = 1) -> Grid.Layout {
        Grid.layout(selection: selection, display: display, scale: scale, props: props)
    }

    private func same(_ s: String) -> String { s }

    @Test func theFirstRowIsTheSpecifiedSixteenInOrder() {
        let l = layout(.none)
        var expected = AnnotationTool.allCases.map(ToolbarButton.tool)
        expected += [.undo, .redo, .long, .save, .cancel, .done]
        #expect(l.buttons.map(\.button) == expected)
        #expect(expected.count == 16)
        #expect(AnnotationTool.allCases.first == .select)
        #expect(zip(l.buttons, l.buttons.dropFirst()).allSatisfy { $0.rect.right <= $1.rect.x },
                "left to right, not overlapping")
        #expect(l.props == nil)
    }

    @Test func buttonsSitOnTheGridWithWiderGapsBetweenGroups() throws {
        let l = layout(.none)
        func x(_ b: ToolbarButton) -> Int { l.rect(of: b)?.x ?? .min }
        let size = Grid.footprint(scale: 1)
        #expect(size.w == 2 * 6 + 16 * 28 + 11 * 4 + 4 * 12)
        #expect(size.h == 2 * 40, "two rows and nothing between them: one plate")
        #expect(l.bar == PixelRect(selection.right - 552, selection.bottom + 8, 552, 40))
        #expect(l.rect(of: .tool(.select)) == PixelRect(l.bar.x + 6, l.bar.y + 6, 28, 28))
        // Select | Rectangle: a group gap. Rectangle, Ellipse: an ordinary one.
        #expect(x(.tool(.rect)) - x(.tool(.select)) == 28 + 12)
        #expect(x(.tool(.ellipse)) - x(.tool(.rect)) == 28 + 4)
        #expect(x(.undo) - x(.tool(.mosaic)) == 28 + 12)
        #expect(x(.redo) - x(.undo) == 28 + 4)
        #expect(x(.long) - x(.redo) == 28 + 12)
        #expect(x(.save) - x(.long) == 28 + 4, "Save is beside Long Screenshot, in its group")
        #expect(x(.cancel) - x(.save) == 28 + 12)
        #expect(x(.done) - x(.cancel) == 28 + 4)
        let done = try #require(l.rect(of: .done))
        #expect(done.right == l.bar.right - 6, "the last button ends at the padding")
        #expect(done.h == 28)
    }

    @Test func everythingScalesWithTheDisplay() {
        let l = layout(.stroke, scale: 1.5)
        #expect(l.rect(of: .tool(.select))?.w == 42)
        #expect(l.rect(of: .colour(0))?.w == 42, "a colour is a cell like any other")
        #expect(Grid.footprint(scale: 1.5).w == 2 * 9 + 16 * 42 + 11 * 6 + 4 * 18)
        #expect(Grid.footprint(scale: 1.5).h == 2 * 60)
        #expect(l.bar.y == selection.bottom + 12)
    }

    @Test func thePropertyRowFollowsTheKindOfProperty() {
        func count(_ props: AnnotationTool.Props) -> [Int] {
            let l = layout(props)
            let colours = l.buttons.filter { if case .colour = $0.button { return true } else { return false } }.count
            let levels = l.buttons.filter { if case .level = $0.button { return true } else { return false } }.count
            return [colours, levels, l.props == nil ? 0 : 1]
        }
        #expect(count(.none) == [0, 0, 0])
        #expect(count(.stroke) == [9, 5, 1])
        #expect(count(.font) == [9, 5, 1])
        #expect(count(.block) == [0, 5, 1], "a mosaic has no colour")
    }

    @Test func thePropertyRowIsUnderTheFirstAndHoldsItsButtons() throws {
        let l = layout(.stroke)
        let row = try #require(l.props)
        #expect(row.x == l.bar.x)
        #expect(row.y == l.bar.bottom, "one plate: the second row starts where the first ends")
        #expect(row.h == 40)
        #expect(row.w == l.bar.w, "as wide as the first row whatever it holds")
        #expect(l.plate == PixelRect(l.bar.x, l.bar.y, 552, 80))
        #expect(layout(.none).plate == layout(.none).bar)
        for placed in l.buttons {
            switch placed.button {
            case .colour, .level:
                let r = placed.rect
                #expect(r.x >= row.x + 6 && r.right <= row.right - 6 && r.y >= row.y && r.bottom <= row.bottom,
                        "\(placed.button)")
                #expect(r.w == 28 && r.h == 28, "\(placed.button) is a cell of the grid")
            default:
                break
            }
        }
        // A colour is a cell: the same size and the same step as a tool.
        #expect(l.rect(of: .colour(0)) == PixelRect(row.x + 6, row.y + 6, 28, 28))
        #expect(l.rect(of: .colour(1))?.x == row.x + 6 + 32)
        #expect(l.rect(of: .colour(0))?.x == l.rect(of: .tool(.select))?.x, "the two rows start on one line")
        // Nine colours, a group gap, five steps: 464 points of the 520.
        #expect(l.rect(of: .level(0)) == PixelRect(row.x + 6 + 9 * 32 - 4 + 12, row.y + 6, 28, 28))
        #expect(l.rect(of: .level(4))?.right == row.x + 6 + 9 * 28 + 8 * 4 + 12 + 5 * 28 + 4 * 4)
        let block = layout(.block)
        #expect(block.rect(of: .level(0))?.x == block.bar.x + 6, "with no swatches the steps start at the left")
        #expect(block.props?.w == block.bar.w)
    }

    @Test func showingThePropertyRowDoesNotMoveTheFirst() {
        let without = layout(.none)
        let with = layout(.font)
        #expect(without.bar == with.bar)
        #expect(without.rect(of: .done) == with.rect(of: .done))
    }

    @Test func itGoesAboveWhenBothRowsDoNotFitBelow() throws {
        // Room for one row under the selection but not for two.
        let low = PixelRect(400, 800, 900, 590)
        var l = Grid.layout(selection: low, display: display, scale: 1, props: .stroke)
        #expect(l.bar.y == low.y - 8 - 80)
        #expect(try #require(l.props).bottom <= low.y - 8)
        // The whole display selected: inside the bottom edge.
        l = Grid.layout(selection: display, display: display, scale: 1, props: .stroke)
        #expect(try #require(l.props).bottom == display.bottom - 8)
    }

    @Test func aClickFindsItsButtonAndTheBarSwallowsTheGaps() throws {
        let l = layout(.stroke)
        let r = try #require(l.rect(of: .tool(.arrow)))
        #expect(l.button(at: Pt(r.x + 5, r.y + 5)) == .tool(.arrow))
        let gap = Pt(r.right + 1, r.y + 5)
        #expect(l.button(at: gap) == nil)
        #expect(l.covers(gap), "between two buttons is still the toolbar")
        let swatch = try #require(l.rect(of: .colour(3)))
        #expect(l.button(at: Pt(swatch.x, swatch.y)) == .colour(3))
        #expect(l.covers(Pt(swatch.x, swatch.y - 2)))
        #expect(!l.covers(Pt(selection.x + 10, selection.y + 10)))
        // The rows are one plate: there is no "between" them, and the part
        // of the second row past its last cell is the toolbar too.
        #expect(l.covers(Pt(l.bar.x + 10, l.bar.bottom)))
        #expect(l.covers(Pt(l.bar.right - 3, l.bar.bottom + 20)))
        #expect(l.button(at: Pt(l.bar.right - 3, l.bar.bottom + 20)) == nil)
        // With no property row, where it would be is not the toolbar.
        #expect(!layout(.none).covers(Pt(swatch.x, swatch.y)))
    }

    @Test func aTooltipIsTheNameAndTheKey() {
        func tip(_ b: ToolbarButton, _ props: AnnotationTool.Props = .stroke) -> String {
            Grid.tooltip(for: b, props: props, translate: same)
        }
        #expect(tip(.tool(.rect)) == "Rectangle (R)")
        #expect(tip(.tool(.select)) == "Select (V)")
        #expect(tip(.tool(.line)) == "Straight Line (L)")
        #expect(tip(.undo) == "Undo (⌘Z)")
        #expect(tip(.redo) == "Redo (⇧⌘Z)")
        #expect(tip(.done) == "Done (Enter)")
        #expect(tip(.cancel) == "Cancel (Esc)")
        #expect(tip(.long) == "Long Screenshot", "no key, no brackets")
        #expect(tip(.colour(0)) == "Red (1)")
        #expect(tip(.colour(8)) == "White (9)")
        #expect(tip(.level(2)) == "Thickness")
        #expect(tip(.level(2), .font) == "Font Size")
        #expect(tip(.level(2), .block) == "Block Size")
        #expect(Grid.tooltip(for: .tool(.mosaic), props: .block) { "<\($0)>" } == "<Mosaic> (M)",
                "the name is translated, the key is not")
    }

    @Test func everyToolsTooltipNamesTheKeyThatSelectsIt() {
        for tool in AnnotationTool.allCases {
            let tip = Grid.tooltip(for: .tool(tool), props: .none, translate: same)
            #expect(tip.hasSuffix("(\(tool.letter))"), "\(tip)")
            #expect(EditorKey.of(.letter(tool.letter), mods: [], hasSelection: true) == .tool(tool))
        }
    }

    @Test func everyColourHasAName() {
        #expect(Grid.colourNames.count == ShotStyle.colours.count)
        #expect(Set(Grid.colourNames).count == 9)
        #expect(Grid.colourNames[5] == "Blue")
    }
}

/// The Windows host's `overlay.rs` tests for what a key means (9.2). Where
/// they say Ctrl, this says Command; Control and Option are the modifiers
/// that make a chord somebody else's.
struct EditorKeyTests {
    private let command: ShotMods = [.command]
    private let shift: ShotMods = [.shift]
    private let both: ShotMods = [.command, .shift]

    private func key(_ input: EditorKey.Input, _ mods: ShotMods = [], selection: Bool = true) -> EditorKey {
        EditorKey.of(input, mods: mods, hasSelection: selection)
    }

    @Test func commandZUndoesAndShiftCommandZRedoes() {
        #expect(key(.letter("z"), command) == .undo)
        #expect(key(.letter("Z"), command) == .undo)
        #expect(key(.letter("z"), command, selection: false) == .undo, "nothing to undo is the caller's to find out")
        #expect(key(.letter("z"), both) == .redo)
        #expect(key(.letter("Z"), both) == .redo)
    }

    @Test func zWithoutExactlyThoseModifiersIsNeither() {
        #expect(key(.letter("z")) == .ignored)
        #expect(key(.letter("z"), [.command, .option]) == .ignored)
        #expect(key(.letter("z"), [.command, .control]) == .ignored)
        #expect(key(.letter("z"), [.command, .shift, .option]) == .ignored)
        #expect(key(.letter("z"), shift) == .ignored)
        #expect(key(.letter("z"), [.control]) == .ignored, "Control is not the key on a Mac")
    }

    @Test func modifiersThatAreNotOneOfTheFourDoNotCount() {
        // Caps lock, the number pad flag and the like arrive in the raw value.
        let noise = ShotMods(rawValue: 1 << 16)
        #expect(key(.letter("r"), noise) == .tool(.rect))
        #expect(key(.letter("z"), command.union(noise)) == .undo)
        #expect(key(.left, shift.union(noise)) == .nudge(dx: -10, dy: 0))
    }

    @Test func escapeCancelsWhateverIsHeld() {
        for mods in [[], command, both, [.option]] as [ShotMods] {
            #expect(key(.escape, mods) == .cancel)
            #expect(key(.escape, mods, selection: false) == .cancel)
        }
    }

    @Test func enterFinishesOnlyWhenThereIsASelection() {
        #expect(key(.enter) == .finish)
        #expect(key(.enter, selection: false) == .ignored)
        #expect(key(.enter, command) == .ignored)
    }

    @Test func eachToolHasItsLetter() {
        let letters: [(Character, AnnotationTool)] = [
            ("V", .select), ("R", .rect), ("O", .ellipse), ("L", .line), ("A", .arrow),
            ("P", .pen), ("H", .highlighter), ("T", .text), ("N", .number), ("M", .mosaic),
        ]
        for (letter, tool) in letters {
            #expect(key(.letter(letter)) == .tool(tool), "\(letter)")
            #expect(key(.letter(Character(letter.lowercased()))) == .tool(tool), "\(letter), lower case")
        }
        #expect(key(.letter("B")) == .ignored)
        #expect(key(.letter("Z")) == .ignored)
        #expect(key(.other) == .ignored)
    }

    @Test func aLetterWithAModifierIsNotATool() {
        for mods in [command, shift, both, [.option], [.control]] as [ShotMods] {
            #expect(key(.letter("R"), mods) == .ignored, "\(mods)")
            #expect(key(.digit(1), mods) == .ignored, "\(mods)")
            #expect(key(.delete, mods) == .ignored, "\(mods)")
            #expect(key(.bracketLeft, mods) == .ignored, "\(mods)")
        }
    }

    @Test func digitsAreColoursAndBracketsAreSteps() {
        #expect(key(.digit(1)) == .colour(0))
        #expect(key(.digit(9)) == .colour(8))
        #expect(key(.digit(0)) == .ignored, "there is no tenth colour")
        #expect(key(.digit(5)) == .colour(4))
        #expect(key(.bracketLeft) == .step(-1))
        #expect(key(.bracketRight) == .step(1))
    }

    @Test func deleteDeletes() {
        #expect(key(.delete) == .delete)
        #expect(key(.delete, selection: false) == .delete)
    }

    @Test func arrowsNudgeByOneAndByTenWithShift() {
        #expect(key(.left) == .nudge(dx: -1, dy: 0))
        #expect(key(.right) == .nudge(dx: 1, dy: 0))
        #expect(key(.up) == .nudge(dx: 0, dy: -1))
        #expect(key(.down) == .nudge(dx: 0, dy: 1))
        #expect(key(.left, shift) == .nudge(dx: -10, dy: 0))
        #expect(key(.right, shift) == .nudge(dx: 10, dy: 0))
        #expect(key(.up, shift) == .nudge(dx: 0, dy: -10))
        #expect(key(.down, shift) == .nudge(dx: 0, dy: 10))
        #expect(key(.down, command) == .ignored)
        #expect(key(.down, both) == .ignored)
    }
}
