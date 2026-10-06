import Foundation
import Testing
@testable import Ghostty

/// The Windows host's `annot.rs` tests for what leaves, with the same
/// fixtures and the same strings (`dev-docs/poltergeist/screenshot.md`,
/// sections 4 and 11).
struct ShotSidecarTests {
    private typealias Pt = PixelPoint
    private let it = ShotFixtures.item
    private let text = ShotFixtures.text
    private let number = ShotFixtures.number

    private static let sel = PixelRect(120, 80, 1280, 800)

    /// The specification's own example.
    private var example: [Annotation] {
        [
            it(number(1, Pt(412, 96), "这个按钮没对齐")),
            it(.rect(PixelRect(380, 80, 240, 44))),
            it(.arrow(from: Pt(100, 300), to: Pt(220, 340))),
            it(text(Pt(60, 500), "间距太大")),
            it(.pen([Pt(10, 10), Pt(89, 30), Pt(40, 49)])),
        ]
    }

    private func meta(_ source: ShotSidecar.Source) -> ShotSidecar.Meta {
        ShotSidecar.Meta(
            image: "20261006-153012-123.png",
            taken: .init(year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12, utcOffsetMinutes: 480),
            width: 1280, height: 800, scale: 2.0, source: source)
    }

    private let zh = ShotSidecar.Labels(
        header: "截图标注", text: "文字", rect: "框", ellipse: "圆", line: "线", arrow: "箭头", pen: "画笔",
        highlighter: "荧光笔", mosaic: "马赛克", separator: "；", see: "。详见 ")
    /// The msgids themselves.
    private let en = ShotSidecar.Labels(
        header: "Screenshot annotations", text: "Text", rect: "Box", ellipse: "Circle", line: "Line",
        arrow: "Arrow", pen: "Pen", highlighter: "Highlighter", mosaic: "Mosaic", separator: "; ", see: ". See ")
    private let longZh = ShotSidecar.LongLabels(
        header: "长截图", tiles: "共 {n} 片，已粘贴前 {m} 片", whole: "整图", separator: "；", see: "。详见 ")
    private let longEn = ShotSidecar.LongLabels(
        header: "Long Screenshot", tiles: "{n} tiles, first {m} pasted", whole: "whole image",
        separator: "; ", see: ". See ")

    private func parse(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: The sidecar

    @Test func theSidecarIsTheSpecifiedDocument() {
        var m = meta(.window(
            app: "Google Chrome", title: "…", pid: 4242, windowRect: Self.sel, selectionRect: Self.sel))
        m.display = .init(index: 0, width: 2560, height: 1440, scale: 2.0)
        m.appearance = "dark"
        m.terminal = .init(id: "0x17e4", cwd: "/w/proj", git: ("3d65ad0", true))
        m.previous = "20261006-152233-101.png"
        m.tiles = [.init(image: "20261006-153012-123-1.png", y: 0, height: 1800)]

        let expected = """
        {
          "version": 2,
          "image": "20261006-153012-123.png",
          "taken_at": "2026-10-06T15:30:12+08:00",
          "size": [1280, 800],
          "scale": 2.0,
          "by": "user",
          "display": {"index": 0, "size": [2560, 1440], "scale": 2.0},
          "appearance": "dark",
          "source": {"kind": "window", "app": "Google Chrome", "title": "…", "pid": 4242, "window_rect": [120, 80, 1280, 800], "selection_rect": [120, 80, 1280, 800]},
          "terminal": {"id": "0x17e4", "cwd": "/w/proj", "git": {"head": "3d65ad0", "dirty": true}},
          "previous": "20261006-152233-101.png",
          "tiles": [{"image": "20261006-153012-123-1.png", "y": 0, "height": 1800}],
          "annotations": [
            {"n": 1, "type": "number", "at": [412, 96], "text": "这个按钮没对齐", "color": "#E62828", "font_size": 18},
            {"type": "rect", "rect": [380, 80, 240, 44], "text": "", "color": "#E62828", "width": 2},
            {"type": "arrow", "from": [100, 300], "to": [220, 340], "color": "#E62828", "width": 2},
            {"type": "text", "at": [60, 500], "text": "间距太大", "color": "#E62828", "font_size": 18},
            {"type": "pen", "bbox": [10, 10, 80, 40], "color": "#E62828", "width": 2}
          ]
        }

        """
        #expect(ShotSidecar.json(m, items: example) == expected)
    }

    @Test func theNewShapesHaveTheirOwnEntries() throws {
        let items = [
            Annotation(shape: .ellipse(PixelRect(1, 2, 30, 40)), colour: 5, level: 4),
            Annotation(shape: .line(from: Pt(1, 2), to: Pt(3, 4)), colour: 8, level: 0),
            Annotation(shape: .highlighter([Pt(10, 10), Pt(29, 19)]), colour: 2, level: 2),
            Annotation(shape: .mosaic(PixelRect(5, 6, 70, 80)), colour: 0, level: 3),
            Annotation(shape: number(2, Pt(9, 9), ""), colour: 3, level: 4),
        ]
        let doc = ShotSidecar.json(meta(.region(selectionRect: Self.sel)), items: items)
        #expect(doc.contains(##"{"type": "ellipse", "rect": [1, 2, 30, 40], "color": "#2F6FED", "width": 10}"##))
        #expect(doc.contains(##"{"type": "line", "from": [1, 2], "to": [3, 4], "color": "#FFFFFF", "width": 1}"##))
        #expect(doc.contains(##"{"type": "highlighter", "bbox": [10, 10, 20, 10], "color": "#FFD400", "width": 4}"##))
        // Where and how coarse, nothing else.
        #expect(doc.contains(##"{"type": "mosaic", "rect": [5, 6, 70, 80], "block": 24}"##))
        #expect(doc.contains(##"{"n": 2, "type": "number", "at": [9, 9], "text": "", "color": "#2DB84D", "font_size": 44}"##))
        let parsed = try parse(doc)
        #expect((parsed["annotations"] as? [Any])?.count == 5)
    }

    @Test func theSidecarParsesAsJsonWhateverWasTyped() throws {
        let nasty = "a \"quoted\" \\ back\nslash\tand } ] , \u{1}\u{8}\u{c}"
        let items = [it(text(Pt(1, 2), nasty)), it(number(2, Pt(3, 4), nasty))]
        var m = meta(.window(app: nasty, title: nasty, pid: nil, windowRect: nil, selectionRect: Self.sel))
        m.terminal = .init(id: nasty, cwd: nasty, git: (nasty, false))
        m.by = .agent(terminal: nasty)
        let v = try parse(ShotSidecar.json(m, items: items))
        let annotations = try #require(v["annotations"] as? [[String: Any]])
        #expect(annotations[0]["text"] as? String == nasty)
        #expect(annotations[1]["text"] as? String == nasty)
        let source = try #require(v["source"] as? [String: Any])
        #expect(source["app"] as? String == nasty)
        #expect(source["title"] as? String == nasty)
        let terminal = try #require(v["terminal"] as? [String: Any])
        #expect(terminal["cwd"] as? String == nasty)
        #expect((terminal["git"] as? [String: Any])?["head"] as? String == nasty)
        #expect(v["by"] as? String == "agent")
        #expect(v["agent_terminal"] as? String == nasty)
        #expect(v["version"] as? Int == 2)
    }

    @Test func aStringIsEscapedTheWayTheOtherHostEscapesIt() {
        #expect(ShotSidecar.quoted("a\"b\\c") == #""a\"b\\c""#)
        #expect(ShotSidecar.quoted("\n\r\t\u{8}\u{c}") == #""\n\r\t\b\f""#)
        #expect(ShotSidecar.quoted("\u{1}\u{1f}") == #""\u0001\u001f""#)
        // A solidus and anything not ASCII go through as they are.
        #expect(ShotSidecar.quoted("/间距…") == "\"/间距…\"")
    }

    @Test func whatIsUnknownOrEmptyIsLeftOut() throws {
        let w = try parse(ShotSidecar.json(
            meta(.window(app: nil, title: "", pid: nil, windowRect: nil, selectionRect: Self.sel)), items: []))
        let windowSource = try #require(w["source"] as? [String: Any])
        #expect(Set(windowSource.keys) == ["kind", "selection_rect"])
        #expect(windowSource["kind"] as? String == "window")

        let r = try parse(ShotSidecar.json(meta(.region(selectionRect: Self.sel)), items: []))
        let regionSource = try #require(r["source"] as? [String: Any])
        #expect(Set(regionSource.keys) == ["kind", "selection_rect"])
        #expect(regionSource["selection_rect"] as? [Int] == [120, 80, 1280, 800])
        #expect((r["annotations"] as? [Any])?.isEmpty == true)
        for key in ["display", "appearance", "terminal", "previous", "tiles", "agent_terminal", "redacted"] {
            #expect(r[key] == nil, "\(key) has no value and must not be written")
        }
        #expect(r["by"] as? String == "user")

        var m = meta(.region(selectionRect: Self.sel))
        m.terminal = .init(id: "0x1", cwd: nil, git: nil)
        m.previous = ""
        m.appearance = ""
        let t = try parse(ShotSidecar.json(m, items: []))
        #expect(Set((t["terminal"] as? [String: Any] ?? [:]).keys) == ["id"])
        #expect(t["previous"] == nil)
        #expect(t["appearance"] == nil)

        // A terminal with no id is no terminal.
        m.terminal = .init(id: "", cwd: "/w", git: nil)
        let none = try parse(ShotSidecar.json(m, items: []))
        #expect(none["terminal"] == nil)
    }

    @Test func theTimeCarriesItsOffsetAndTheScaleItsFraction() throws {
        var m = meta(.region(selectionRect: Self.sel))
        m.taken.utcOffsetMinutes = -210
        m.scale = 1.25
        let v = try parse(ShotSidecar.json(m, items: []))
        #expect(v["taken_at"] as? String == "2026-10-06T15:30:12-03:30")
        #expect(ShotSidecar.json(m, items: []).contains("\"scale\": 1.25,"))
        m.taken.utcOffsetMinutes = 0
        m.scale = .nan
        #expect(ShotSidecar.json(m, items: []).contains("+00:00"))
        #expect(ShotSidecar.json(m, items: []).contains("\"scale\": 1.0,"))
    }

    @Test func aMomentIsReadInTheZoneItWasTakenIn() {
        var calendar = Calendar(identifier: .gregorian)
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = shanghai
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12))!
        #expect(ShotSidecar.Stamp(date, timeZone: shanghai).text == "2026-10-06T15:30:12+08:00")
        #expect(ShotSidecar.Stamp(date, timeZone: TimeZone(identifier: "UTC")!).text == "2026-10-06T07:30:12+00:00")
    }

    @Test func anAgentsScreenshotSaysWhatWasPaintedOver() throws {
        var m = meta(.region(selectionRect: Self.sel))
        m.by = .agent(terminal: "0x2a")
        m.redacted = [PixelRect(0, 0, 50, 50), PixelRect(100, 20, 300, 200)]
        let doc = ShotSidecar.json(m, items: [])
        #expect(doc.contains("\"redacted\": [[0, 0, 50, 50], [100, 20, 300, 200]],\n  \"annotations\": []"))
        let v = try parse(doc)
        #expect(v["agent_terminal"] as? String == "0x2a")
        #expect((v["redacted"] as? [[Int]])?.count == 2)
    }

    // MARK: The line

    @Test func theLineIsTheSpecifiedSentence() {
        let got = ShotSidecar.line(
            width: 1280, height: 800, items: example, jsonPath: "/shots/20261006-153012-123.json", labels: zh)
        #expect(got == "[截图标注 1280x800] #1 (412,96) 这个按钮没对齐；框 (380,80,240,44)；"
            + "箭头 (100,300)->(220,340)；文字 (60,500) 间距太大；画笔 (10,10,80,40)。"
            + "详见 /shots/20261006-153012-123.json")
    }

    @Test func theLineHasAWordForEachNewShapeAndAMosaicSaysOnlyWhere() {
        let items = [
            it(.ellipse(PixelRect(1, 2, 3, 4))),
            it(.line(from: Pt(1, 2), to: Pt(3, 4))),
            it(.highlighter([Pt(10, 10), Pt(29, 19)])),
            Annotation(shape: .mosaic(PixelRect(5, 6, 7, 8)), colour: 0, level: 4),
        ]
        #expect(ShotSidecar.line(width: 10, height: 10, items: items, jsonPath: "j", labels: zh)
            == "[截图标注 10x10] 圆 (1,2,3,4)；线 (1,2)->(3,4)；荧光笔 (10,10,20,10)；马赛克 (5,6,7,8)。详见 j")
        #expect(ShotSidecar.line(width: 10, height: 10, items: items, jsonPath: "j", labels: en)
            == "[Screenshot annotations 10x10] Circle (1,2,3,4); Line (1,2)->(3,4); "
            + "Highlighter (10,10,20,10); Mosaic (5,6,7,8). See j")
    }

    @Test func aLongScreenshotSaysHowManyTilesThereAreOnlyWhenSomeWereLeftOut() {
        #expect(ShotSidecar.longLine(
            size: .init(1280, 9000), tiles: 5, pasted: 5, imagePath: "a.png", jsonPath: "a.json", labels: longZh) == nil)
        #expect(ShotSidecar.longLine(
            size: .init(1280, 9000), tiles: 8, pasted: 8, imagePath: "a.png", jsonPath: "a.json", labels: longZh) == nil)
        #expect(ShotSidecar.longLine(
            size: .init(1280, 19000), tiles: 12, pasted: 8, imagePath: "/s/a.png", jsonPath: "/s/a.json", labels: longZh)
            == "[长截图 1280x19000] 共 12 片，已粘贴前 8 片；整图 /s/a.png。详见 /s/a.json")
        #expect(ShotSidecar.longLine(
            size: .init(1280, 19000), tiles: 12, pasted: 8, imagePath: "a.png", jsonPath: "a.json", labels: longEn)
            == "[Long Screenshot 1280x19000] 12 tiles, first 8 pasted; whole image a.png. See a.json")
        #expect(ShotSidecar.maxPastedTiles == 8)
    }

    @Test func noAnnotationsIsNoLineButShapesWithoutWordsAreOne() {
        #expect(ShotSidecar.line(width: 10, height: 10, items: [], jsonPath: "x.json", labels: zh) == nil)
        #expect(ShotSidecar.line(
            width: 10, height: 10, items: [it(.rect(PixelRect(1, 2, 3, 4)))], jsonPath: "x.json", labels: zh)
            == "[截图标注 10x10] 框 (1,2,3,4)。详见 x.json")
    }

    @Test func aTextOfSeveralLinesDoesNotBreakTheLine() throws {
        let items = [it(text(Pt(1, 2), "first\r\nsecond\tthird\u{1b}[0m")), it(number(1, Pt(3, 4), "\n"))]
        let got = try #require(ShotSidecar.line(width: 10, height: 10, items: items, jsonPath: "x.json", labels: zh))
        #expect(!got.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(got == "[截图标注 10x10] 文字 (1,2) first  second third [0m；#1 (3,4)。详见 x.json")
    }

    @Test func aNumberIsWrittenWithAHashAndTheLineIsPlainAsciiOutsideItsWords() {
        let items = [2, 20, 21].map { it(number($0, Pt(0, 0), "")) }
        #expect(ShotSidecar.line(width: 1, height: 1, items: items, jsonPath: "j", labels: zh)
            == "[截图标注 1x1] #2 (0,0)；#20 (0,0)；#21 (0,0)。详见 j")
        // With the words in English nothing in the line is outside ASCII:
        // the `×` and the circled digits this once used reach a Windows
        // console program as U+0000.
        let english = ShotSidecar.line(width: 1280, height: 800, items: items, jsonPath: "j", labels: en)
        #expect(english == "[Screenshot annotations 1280x800] #2 (0,0); #20 (0,0); #21 (0,0). See j")
        #expect(english?.unicodeScalars.allSatisfy(\.isASCII) == true)
    }

    // MARK: The previous screenshot

    @Test func thePreviousScreenshotIsTheNewestEarlierOneOfTheSameWindow() {
        let earlier: [ShotSidecar.Earlier] = [
            .init(image: "20261006-100000-000.png", app: "Chrome", title: "Docs"),
            .init(image: "20261006-120000-000.png", app: "Chrome", title: "Docs"),
            .init(image: "20261006-110000-000.png", app: "Chrome", title: "Docs"),
            // The same app, another window.
            .init(image: "20261006-130000-000.png", app: "Chrome", title: "Mail"),
            // A region: no window at all.
            .init(image: "20261006-140000-000.png", app: nil, title: nil),
            // The same app with a title nobody could read.
            .init(image: "20261006-150000-000.png", app: "Chrome", title: ""),
            // Later than the one being written.
            .init(image: "20261006-160000-000.png", app: "Chrome", title: "Docs"),
        ]
        let this = "20261006-153012-123.png"
        #expect(ShotSidecar.previous(app: "Chrome", title: "Docs", before: this, among: earlier)
            == "20261006-120000-000.png")
        #expect(ShotSidecar.previous(app: "Chrome", title: "Mail", before: this, among: earlier)
            == "20261006-130000-000.png")
        #expect(ShotSidecar.previous(app: "Safari", title: "Docs", before: this, among: earlier) == nil)
        // Two unknowns are not the same window.
        #expect(ShotSidecar.previous(app: nil, title: nil, before: this, among: earlier) == nil)
        #expect(ShotSidecar.previous(app: "Chrome", title: "", before: this, among: earlier) == nil)
        // It is never its own previous.
        #expect(ShotSidecar.previous(
            app: "Chrome", title: "Docs", before: "20261006-100000-000.png", among: earlier) == nil)
    }
}
