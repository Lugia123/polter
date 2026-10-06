import Foundation
import Testing
@testable import Ghostty

/// Colours, steps and what each tool remembers
/// (`dev-docs/poltergeist/screenshot.md`, 9.1, 9.5 and 9.7).
struct ShotStyleTests {
    @Test func theNineColoursAreTheSpecifiedOnesInKeyOrder() {
        let hex = (0..<9).map { ShotStyle.hex($0) }
        #expect(hex == [
            "#E62828", "#F5821F", "#FFD400", "#2DB84D", "#17B5C8", "#2F6FED", "#8E44D6", "#1A1A1A", "#FFFFFF",
        ])
        #expect(ShotStyle.colours.count == 9)
        #expect(ShotStyle.defaultColour == 0)
        #expect(ShotStyle.index(ofHex: "#2f6fed") == 5)
        #expect(ShotStyle.index(ofHex: "#123456") == nil)
    }

    @Test func theFiveStepsAreTheSpecifiedOnesAndTheSecondIsTheDefault() {
        #expect(ShotStyle.widths == [1, 2, 4, 6, 10])
        #expect(ShotStyle.fonts == [14, 18, 24, 32, 44])
        #expect(ShotStyle.mosaic.map(\.points) == [8, 12, 16, 24, 32])
        #expect(ShotStyle.mosaic.map(\.k) == [12, 10, 8, 6, 4])
        #expect(ShotStyle.levels == 5)
        #expect(ShotStyle.defaultLevel == 1)
    }

    @Test func pointsBecomePixelsAndNeverLessThanOne() {
        #expect(ShotStyle.px(2, scale: 2) == 4)
        #expect(ShotStyle.px(1, scale: 1.5) == 2)
        #expect(ShotStyle.px(1, scale: 1.25) == 1)
        #expect(ShotStyle.px(1, scale: 0.25) == 1)
        #expect(ShotStyle.widthPx(level: 4, scale: 2) == 20)
        #expect(ShotStyle.fontPx(level: 1, scale: 1.5) == 27)
        // A step past the last is the last.
        #expect(ShotStyle.widthPx(level: 9, scale: 1) == 10)
        #expect(ShotStyle.widthPx(level: -1, scale: 1) == 1)
    }

    @Test func aMosaicBlockIsTheStepOrAShareOfTheShortSideWhicheverIsMore() {
        // Small region: the step decides. 12 pt at 2×.
        #expect(ShotStyle.mosaicBlock(level: 1, scale: 2, shortSide: 100) == 24)
        // Large region: at most k blocks along the short side, rounded up.
        #expect(ShotStyle.mosaicBlock(level: 1, scale: 1, shortSide: 1000) == 100)
        #expect(ShotStyle.mosaicBlock(level: 1, scale: 1, shortSide: 1001) == 101)
        #expect(ShotStyle.mosaicBlock(level: 4, scale: 1, shortSide: 1000) == 250)
        #expect(ShotStyle.mosaicBlock(level: 0, scale: 1, shortSide: 0) == 8)
        // However large the region, the short side holds no more than k.
        for level in 0..<5 {
            for side in [50, 333, 1000, 2160] {
                let block = ShotStyle.mosaicBlock(level: level, scale: 2, shortSide: side)
                #expect(ShotPixels.spans(length: side, block: block).count <= ShotStyle.mosaic[level].k)
            }
        }
    }

    @Test func eachToolHasItsLetterAndItsRowOfProperties() {
        let letters = AnnotationTool.allCases.map { String($0.letter) }.joined()
        #expect(letters == "VROLAPHTNM")
        #expect(AnnotationTool(letter: "h") == .highlighter)
        #expect(AnnotationTool(letter: "M") == .mosaic)
        #expect(AnnotationTool(letter: "x") == nil)
        #expect(AnnotationTool.select.props == .none)
        for tool in [AnnotationTool.rect, .ellipse, .line, .arrow, .pen, .highlighter] {
            #expect(tool.props == .stroke)
        }
        #expect(AnnotationTool.text.props == .font)
        #expect(AnnotationTool.number.props == .font)
        #expect(AnnotationTool.mosaic.props == .block)
    }

    @Test func eachToolRemembersItsOwnColourAndStep() {
        var prefs = ToolPrefs()
        #expect(prefs.colour(of: .pen) == 0)
        #expect(prefs.level(of: .pen) == 1)
        prefs.setColour(5, of: .pen)
        prefs.setLevel(4, of: .text)
        #expect(prefs.colour(of: .pen) == 5)
        #expect(prefs.level(of: .pen) == 1)
        #expect(prefs.colour(of: .rect) == 0)
        #expect(prefs.level(of: .text) == 4)
        // Out of range is the nearest end, not a crash later.
        prefs.setColour(99, of: .rect)
        prefs.setLevel(-3, of: .rect)
        #expect(prefs.colour(of: .rect) == 8)
        #expect(prefs.level(of: .rect) == 0)
    }

    @Test func whatIsRememberedSurvivesTheFile() {
        var prefs = ToolPrefs()
        prefs.setColour(5, of: .pen)
        prefs.setLevel(3, of: .mosaic)
        let text = prefs.json()
        #expect(ToolPrefs(json: text) == prefs)
        // The file the other host writes, byte for byte.
        #expect(ToolPrefs().json() == """
        {
          "version": 1,
          "tools": {
            "rect": {"color": 0, "level": 1},
            "ellipse": {"color": 0, "level": 1},
            "line": {"color": 0, "level": 1},
            "arrow": {"color": 0, "level": 1},
            "pen": {"color": 0, "level": 1},
            "highlighter": {"color": 0, "level": 1},
            "text": {"color": 0, "level": 1},
            "number": {"color": 0, "level": 1},
            "mosaic": {"color": 0, "level": 1}
          }
        }

        """)
    }

    @Test func aFileThatIsWrongLeavesTheDefaults() {
        #expect(ToolPrefs(json: "") == ToolPrefs())
        #expect(ToolPrefs(json: "not json") == ToolPrefs())
        #expect(ToolPrefs(json: "[]") == ToolPrefs())
        let odd = ToolPrefs(json: """
        {"tools": {"pen": {"color": 99, "level": 2}, "text": {"color": "red", "level": -1},
                   "rect": {"color": true, "level": 3.5}, "wand": {"color": 1, "level": 1}}}
        """)
        // The one value that is in range is taken; the rest are defaults.
        #expect(odd.level(of: .pen) == 2)
        #expect(odd.colour(of: .pen) == 0)
        #expect(odd.colour(of: .text) == 0)
        #expect(odd.level(of: .text) == 1)
        #expect(odd.colour(of: .rect) == 0)
        #expect(odd.level(of: .rect) == 1)
    }
}
