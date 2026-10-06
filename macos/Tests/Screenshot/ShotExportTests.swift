import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// Annotations as data: the `.json` and the pasted line
/// (`dev-docs/poltergeist/screenshot.md`, section 4).
struct ShotExportTests {
    private let red = ShotColor.red

    /// A selection whose top left is at (100, 50) on a 2× display.
    private let origin = CGPoint(x: 100, y: 50)

    /// The specification's own example, as it would be drawn on that display.
    private var drawn: [ShotAnnotation] {
        [
            .number(1, at: CGPoint(x: 306, y: 98), text: "这个按钮没对齐", color: red),
            .rect(CGRect(x: 290, y: 90, width: 120, height: 22), color: red),
            .arrow(from: CGPoint(x: 150, y: 200), to: CGPoint(x: 210, y: 220), color: red),
            .text(at: CGPoint(x: 130, y: 300), "间距太大", color: red),
            // Neither the first point nor the last is a corner of its box.
            .pen([CGPoint(x: 120, y: 60), CGPoint(x: 105, y: 75), CGPoint(x: 145, y: 55), CGPoint(x: 130, y: 70)], color: red),
        ]
    }

    private var exampleItems: [ShotExport.Item] {
        [
            .number(1, x: 412, y: 96, text: "这个按钮没对齐"),
            .rect(x: 380, y: 80, width: 240, height: 44),
            .arrow(fromX: 100, fromY: 300, toX: 220, toY: 340),
            .text(x: 60, y: 500, text: "间距太大"),
            .pen(x: 10, y: 10, width: 80, height: 40),
        ]
    }

    private let chinese = ShotExport.Words(
        header: "截图标注", text: "文字", rect: "框", arrow: "箭头", pen: "画笔",
        separator: "；", see: "。详见 ")

    /// The msgids `src/input/screenshot.zig` names, which are also the keys
    /// the app looks its own translations up by.
    private let english = ShotExport.Words(
        header: "Screenshot annotations", text: "Text", rect: "Box", arrow: "Arrow", pen: "Pen",
        separator: "; ", see: ". See ")

    private func metadata(source: ShotExport.Source = .region) -> ShotExport.Metadata {
        var calendar = Calendar(identifier: .gregorian)
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = shanghai
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12))!
        return .init(
            image: "20261006-153012-123.png", takenAt: date, timeZone: shanghai,
            pixelWidth: 1280, pixelHeight: 800, scale: 2.0, source: source)
    }

    // MARK: Points to pixels

    @Test func annotationsBecomeImagePixels() {
        #expect(ShotExport.items(drawn, selectionOrigin: origin, scale: 2) == exampleItems)
    }

    @Test func atOneToOneOnlyTheOriginMoves() {
        let items = ShotExport.items(
            [.text(at: CGPoint(x: 130, y: 300), "x", color: red)], selectionOrigin: origin, scale: 1)
        #expect(items == [.text(x: 30, y: 250, text: "x")])
    }

    @Test func aRectangleDrawnBackwardsIsStillARectangle() {
        let backwards = ShotAnnotation.rect(CGRect(x: 410, y: 112, width: -120, height: -22), color: red)
        #expect(ShotExport.items([backwards], selectionOrigin: origin, scale: 2)
            == [.rect(x: 380, y: 80, width: 240, height: 44)])
    }

    @Test func emptyTextAndAStrokeThatNeverMovedAreNotAnnotations() {
        let nothing: [ShotAnnotation] = [
            .text(at: CGPoint(x: 130, y: 300), "", color: red),
            .text(at: CGPoint(x: 130, y: 300), "  \n ", color: red),
            .pen([CGPoint(x: 105, y: 55)], color: red),
            .pen([], color: red),
        ]
        #expect(ShotExport.items(nothing, selectionOrigin: origin, scale: 2).isEmpty)
    }

    @Test func aNumberWithNoCaptionIsStillAMark() {
        let items = ShotExport.items(
            [.number(3, at: CGPoint(x: 110, y: 60), text: "", color: red)], selectionOrigin: origin, scale: 2)
        #expect(items == [.number(3, x: 20, y: 20, text: "")])
    }

    @Test func typedTextIsPutOnOneLine() {
        #expect(ShotExport.oneLine("  first\nsecond\r\n\tthird  ") == "first second third")
        #expect(ShotExport.oneLine("a\u{2028}b\u{0007}c") == "a b c")
        #expect(ShotExport.oneLine("间距 太大") == "间距 太大")
        #expect(ShotExport.oneLine("\n\n") == "")
    }

    // MARK: Numbering and undo

    @Test func numbersCountUpAndUndoGivesOneBack() {
        var annotations = ShotAnnotations()
        #expect(annotations.nextNumber == 1)
        annotations.add(.number(annotations.nextNumber, at: .zero, text: "", color: red))
        annotations.add(.rect(.zero, color: red))
        annotations.add(.number(annotations.nextNumber, at: .zero, text: "", color: red))
        #expect(annotations.nextNumber == 3)

        let result1 = annotations.undo()
        #expect(result1)
        #expect(annotations.nextNumber == 2)
        #expect(annotations.items.count == 2)
    }

    @Test func undoGoesOneStepAtATimeAndStopsAtNothing() {
        var annotations = ShotAnnotations()
        annotations.add(.rect(.zero, color: red))
        annotations.add(.arrow(from: .zero, to: CGPoint(x: 1, y: 1), color: red))

        let result2 = annotations.undo()
        #expect(result2)
        #expect(annotations.items == [.rect(.zero, color: red)])
        let result3 = annotations.undo()
        #expect(result3)
        #expect(annotations.isEmpty)
        let result4 = annotations.undo()
        #expect(!result4)
    }

    @Test func theDefaultColourIsRedAndThereAreFour() {
        #expect(ShotColor.palette.first == .red)
        #expect(ShotColor.palette == [.red, .yellow, .blue, .white])
    }

    // MARK: The sidecar

    @Test func theSidecarIsTheSpecificationsExample() throws {
        let window = ShotExport.Source(kind: .window, app: "Google Chrome", title: "…")
        let json = ShotExport.json(metadata(source: window), items: exampleItems)

        let expected = """
        {
          "version": 1,
          "image": "20261006-153012-123.png",
          "taken_at": "2026-10-06T15:30:12+08:00",
          "size": [1280, 800],
          "scale": 2.0,
          "source": {"kind": "window", "app": "Google Chrome", "title": "…"},
          "annotations": [
            {"n": 1, "type": "number", "at": [412, 96], "text": "这个按钮没对齐"},
            {"type": "rect", "rect": [380, 80, 240, 44], "text": ""},
            {"type": "arrow", "from": [100, 300], "to": [220, 340]},
            {"type": "text", "at": [60, 500], "text": "间距太大"},
            {"type": "pen", "bbox": [10, 10, 80, 40]}
          ]
        }

        """
        #expect(json == expected)
    }

    @Test func theSidecarParsesAsJSON() throws {
        let tricky: [ShotExport.Item] = [
            .text(x: 1, y: 2, text: "a \"quoted\" back\\slash"),
            .number(2, x: 3, y: 4, text: "tab\there"),
        ]
        let window = ShotExport.Source(kind: .window, app: "An \"App\"", title: "C:\\path")
        let json = ShotExport.json(metadata(source: window), items: tricky)

        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(parsed["version"] as? Int == 1)
        #expect(parsed["size"] as? [Int] == [1280, 800])
        #expect(parsed["scale"] as? Double == 2.0)
        let source = try #require(parsed["source"] as? [String: String])
        #expect(source == ["kind": "window", "app": "An \"App\"", "title": "C:\\path"])
        let annotations = try #require(parsed["annotations"] as? [[String: Any]])
        #expect(annotations.count == 2)
        #expect(annotations[0]["text"] as? String == "a \"quoted\" back\\slash")
        #expect(annotations[1]["text"] as? String == "tab\there")
        #expect(annotations[1]["n"] as? Int == 2)
    }

    @Test func aRegionHasNoAppOrTitle() throws {
        // Even if something upstream filled them in.
        let region = ShotExport.Source(kind: .region, app: "Finder", title: "x")
        let json = ShotExport.json(metadata(source: region), items: [])
        #expect(json.contains("\"source\": {\"kind\": \"region\"},"))
        #expect(json.contains("\"annotations\": []"))
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    @Test func anUnknownAppOrTitleIsLeftOutNotWrittenEmpty() {
        let noTitle = ShotExport.Source(kind: .window, app: "Finder", title: nil)
        #expect(ShotExport.json(metadata(source: noTitle), items: [])
            .contains("\"source\": {\"kind\": \"window\", \"app\": \"Finder\"},"))

        let emptyBoth = ShotExport.Source(kind: .window, app: "", title: "")
        #expect(ShotExport.json(metadata(source: emptyBoth), items: [])
            .contains("\"source\": {\"kind\": \"window\"},"))
    }

    @Test func aFractionalScaleIsWrittenAsItIs() {
        var m = metadata()
        m.scale = 1.5
        #expect(ShotExport.json(m, items: []).contains("\"scale\": 1.5,"))
        m.scale = 1
        #expect(ShotExport.json(m, items: []).contains("\"scale\": 1.0,"))
    }

    // MARK: The line

    @Test func theLineIsTheSpecificationsExample() {
        // The specification's sentence, with the pen stroke of the same
        // example added before the full stop.
        let line = ShotExport.line(
            items: exampleItems, pixelWidth: 1280, pixelHeight: 800,
            jsonPath: "/shots/20261006-153012-123.json", words: chinese)
        #expect(line == "[截图标注 1280×800] ① (412,96) 这个按钮没对齐；框 (380,80,240,44)；"
            + "箭头 (100,300)→(220,340)；文字 (60,500) 间距太大；画笔 (10,10,80,40)"
            + "。详见 /shots/20261006-153012-123.json")
    }

    @Test func theEnglishWordsAreTheCoresMsgids() {
        let line = ShotExport.line(
            items: exampleItems, pixelWidth: 1280, pixelHeight: 800,
            jsonPath: "/s.json", words: english)
        #expect(line == "[Screenshot annotations 1280×800] ① (412,96) 这个按钮没对齐; Box (380,80,240,44); "
            + "Arrow (100,300)→(220,340); Text (60,500) 间距太大; Pen (10,10,80,40). See /s.json")
    }

    @Test func withNoAnnotationsThereIsNoLine() {
        #expect(ShotExport.line(
            items: [], pixelWidth: 10, pixelHeight: 10, jsonPath: "/s.json", words: chinese) == nil)
    }

    @Test func shapesWithNoWordsStillMakeALine() {
        let line = ShotExport.line(
            items: [.rect(x: 1, y: 2, width: 3, height: 4)],
            pixelWidth: 10, pixelHeight: 20, jsonPath: "/s.json", words: chinese)
        #expect(line == "[截图标注 10×20] 框 (1,2,3,4)。详见 /s.json")
    }

    @Test func aNumberWithNoCaptionHasNoTrailingSpace() {
        let line = ShotExport.line(
            items: [.number(2, x: 5, y: 6, text: ""), .number(3, x: 7, y: 8, text: "here")],
            pixelWidth: 10, pixelHeight: 20, jsonPath: "/s.json", words: chinese)
        #expect(line == "[截图标注 10×20] ② (5,6)；③ (7,8) here。详见 /s.json")
    }

    @Test func theLineIsOneLine() {
        let items = ShotExport.items(
            [.text(at: CGPoint(x: 130, y: 300), "one\ntwo", color: red)], selectionOrigin: origin, scale: 2)
        let line = ShotExport.line(
            items: items, pixelWidth: 10, pixelHeight: 20, jsonPath: "/s.json", words: chinese)
        #expect(line?.contains("\n") == false)
        #expect(line == "[截图标注 10×20] 文字 (60,500) one two。详见 /s.json")
    }

    @Test func circledNumbersRunToTwenty() {
        #expect(ShotExport.circled(1) == "①")
        #expect(ShotExport.circled(10) == "⑩")
        #expect(ShotExport.circled(20) == "⑳")
        #expect(ShotExport.circled(21) == "(21)")
        #expect(ShotExport.circled(0) == "(0)")
    }
}
