import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// What an agent's request says and what it is answered with
/// (`dev-docs/poltergeist/screenshot.md`, 10.1).
struct ShotAgentRequestTests {
    private typealias Pt = PixelPoint
    private let meta = #""meta": {"by": "agent", "agent_terminal": "0x00000000000000a1", "terminal": {"id": "0x00000000000000a1", "cwd": "/proj"}}"#
    private let who = ShotAgent.Meta(agentTerminal: "0x00000000000000a1", terminalID: "0x00000000000000a1", cwd: "/proj")

    private struct Ten: TextMeasure {
        func size(of text: String, fontPx: Int) -> Annotation.PixelSize {
            .init(text.count * 10, fontPx)
        }
    }

    // MARK: Reading

    @Test func theTwoQuestionsHaveNoArguments() {
        #expect(ShotAgent.parse(#"{"op": "directory"}"#) == .directory)
        #expect(ShotAgent.parse(#"{"op": "windows"}"#) == .windows)
    }

    @Test func whatIsNotARequestIsNotGuessedAt() {
        #expect(ShotAgent.parse("") == nil)
        #expect(ShotAgent.parse("[1]") == nil)
        #expect(ShotAgent.parse(#"{"op": "teleport"}"#) == nil)
        #expect(ShotAgent.parse(#"{"target": {"kind": "display", "index": 0}}"#) == nil)
        // A capture with no say of who asked.
        #expect(ShotAgent.parse(#"{"op": "capture", "target": {"kind": "display", "index": 0}, "annotations": []}"#) == nil)
        #expect(ShotAgent.parse(#"{"op": "capture", "target": {"kind": "moon"}, "annotations": [], \#(meta)}"#) == nil)
        #expect(ShotAgent.parse(#"{"op": "capture", "target": {"kind": "display", "index": 0}, \#(meta)}"#) == nil,
                "the core always sends the list, empty or not")
    }

    @Test func everyKindOfTargetIsRead() {
        func capture(_ target: String) -> ShotAgent.Request? {
            ShotAgent.parse(#"{"op": "capture", "target": \#(target), "annotations": [], \#(meta)}"#)
        }
        #expect(capture(#"{"kind": "display", "index": 1}"#) == .capture(target: .display(1), items: [], meta: who))
        #expect(capture(#"{"kind": "window", "window_id": 4242}"#) == .capture(target: .window(4242), items: [], meta: who))
        #expect(capture(#"{"kind": "region", "display": 0, "rect": [10, 20, 300, 200]}"#)
            == .capture(target: .region(display: 0, rect: PixelRect(10, 20, 300, 200)), items: [], meta: who))
        #expect(capture(#"{"kind": "terminal"}"#) == .capture(target: .terminal, items: [], meta: who))
        #expect(capture(#"{"kind": "window", "window_id": -1}"#) == nil)
        #expect(capture(#"{"kind": "window"}"#) == nil)
        #expect(capture(#"{"kind": "region", "display": 0, "rect": [10, 20, 300]}"#) == nil)
        #expect(capture(#"{"kind": "display", "index": 1.5}"#) == nil)
        #expect(capture(#"{"kind": "display", "index": true}"#) == nil, "true is not a number")
    }

    @Test func whoAskedMayHaveNoDirectory() {
        let r = ShotAgent.parse(
            #"{"op": "annotate", "path": "/s/a.png", "annotations": [], "meta": {"by": "agent", "agent_terminal": "0xa1", "terminal": {"id": "0xb2"}}}"#)
        #expect(r == .annotate(path: "/s/a.png", items: [], meta: .init(agentTerminal: "0xa1", terminalID: "0xb2", cwd: nil)))
        let bare = ShotAgent.parse(
            #"{"op": "annotate", "path": "/s/a.png", "annotations": [], "meta": {"agent_terminal": "0xa1"}}"#)
        #expect(bare == .annotate(path: "/s/a.png", items: [], meta: .init(agentTerminal: "0xa1", terminalID: nil, cwd: nil)))
        #expect(ShotAgent.parse(#"{"op": "annotate", "path": "", "annotations": [], \#(meta)}"#) == nil)
    }

    @Test func aLongScreenshotIsOfAWindowOrARegionAndOneToTwentyScreens() {
        func long(_ target: String, _ pages: String) -> ShotAgent.Request? {
            ShotAgent.parse(#"{"op": "long", "target": \#(target), "pages": \#(pages), \#(meta)}"#)
        }
        #expect(long(#"{"kind": "window", "window_id": 7}"#, "3") == .long(target: .window(7), pages: 3, meta: who))
        #expect(long(#"{"kind": "region", "display": 1, "rect": [0, 0, 5, 5]}"#, "20")
            == .long(target: .region(display: 1, rect: PixelRect(0, 0, 5, 5)), pages: 20, meta: who))
        #expect(long(#"{"kind": "window", "window_id": 7}"#, "1") != nil)
        #expect(long(#"{"kind": "window", "window_id": 7}"#, "0") == nil)
        #expect(long(#"{"kind": "window", "window_id": 7}"#, "21") == nil)
        #expect(long(#"{"kind": "display", "index": 0}"#, "3") == nil)
        #expect(long(#"{"kind": "terminal"}"#, "3") == nil)
    }

    // MARK: Annotations

    private func items(_ list: String) -> ShotAgent.Items? {
        guard case let .capture(_, items, _)? = ShotAgent.parse(
            #"{"op": "capture", "target": {"kind": "terminal"}, "annotations": \#(list), \#(meta)}"#) else { return nil }
        return items
    }

    @Test func everyKindOfAnnotationIsRead() {
        let read = items(#"""
        [{"type": "rect", "rect": [1, 2, 30, 40], "color": "#E62828", "width": 2},
         {"type": "ellipse", "rect": [1, 2, 30, 40], "color": "#2F6FED", "width": 10},
         {"type": "line", "from": [1, 2], "to": [3, 4], "color": "#FFFFFF", "width": 1},
         {"type": "arrow", "from": [5, 6], "to": [7, 8], "color": "#E62828", "width": 4},
         {"type": "pen", "points": [[1, 1], [2, 2], [3, 1]], "color": "#E62828", "width": 6},
         {"type": "highlighter", "points": [[1, 1], [9, 1]], "color": "#FFD400", "width": 2},
         {"type": "text", "at": [10, 20], "text": "hello", "color": "#E62828", "font_size": 14},
         {"type": "number", "n": 3, "at": [50, 60], "text": "", "color": "#1A1A1A", "font_size": 44},
         {"type": "mosaic", "rect": [0, 0, 100, 50], "block": 32}]
        """#)
        #expect(read == [
            Annotation(shape: .rect(PixelRect(1, 2, 30, 40)), colour: 0, level: 1),
            Annotation(shape: .ellipse(PixelRect(1, 2, 30, 40)), colour: 5, level: 4),
            Annotation(shape: .line(from: Pt(1, 2), to: Pt(3, 4)), colour: 8, level: 0),
            Annotation(shape: .arrow(from: Pt(5, 6), to: Pt(7, 8)), colour: 0, level: 2),
            Annotation(shape: .pen([Pt(1, 1), Pt(2, 2), Pt(3, 1)]), colour: 0, level: 3),
            Annotation(shape: .highlighter([Pt(1, 1), Pt(9, 1)]), colour: 2, level: 1),
            Annotation(shape: .text(at: Pt(10, 20), text: "hello", size: .zero), colour: 0, level: 0),
            Annotation(shape: .number(n: 3, at: Pt(50, 60), text: "", size: .zero), colour: 7, level: 4),
            Annotation(shape: .mosaic(PixelRect(0, 0, 100, 50)), colour: 0, level: 4),
        ])
    }

    @Test func anAgentMayUseAnyColourAndItIsDrawnAndWrittenAsGiven() throws {
        let read = try #require(items(##"[{"type": "rect", "rect": [1, 2, 30, 40], "color": "#12AB9F", "width": 2}]"##))
        #expect(read[0].custom == ShotStyle.RGB(r: 0x12, g: 0xAB, b: 0x9F))
        #expect(read[0].rgb == ShotStyle.RGB(r: 0x12, g: 0xAB, b: 0x9F))
        // A preset is the preset: the same value a person's would be.
        let preset = try #require(items(##"[{"type": "rect", "rect": [1, 2, 30, 40], "color": "#2f6fed", "width": 2}]"##))
        #expect(preset[0] == Annotation(shape: .rect(PixelRect(1, 2, 30, 40)), colour: 5, level: 1))
        #expect(preset[0].custom == nil)
        // Moving it does not lose the colour.
        #expect(read[0].moved(dx: 5, dy: 5).rgb == ShotStyle.RGB(r: 0x12, g: 0xAB, b: 0x9F))
        // And the sidecar says the colour it was drawn in.
        let stamp = ShotSidecar.Stamp(year: 2026, month: 10, day: 6, hour: 1, minute: 2, second: 3, utcOffsetMinutes: 0)
        let json = ShotSidecar.json(
            .init(image: "a.png", taken: stamp, width: 10, height: 10, scale: 1,
                  source: .region(selectionRect: PixelRect(0, 0, 10, 10))),
            items: read)
        #expect(json.contains("\"color\": \"#12AB9F\""))
    }

    @Test func aHexColourIsSixDigitsAfterAHash() {
        #expect(ShotStyle.rgb(ofHex: "#E62828") == ShotStyle.colours[0])
        #expect(ShotStyle.rgb(ofHex: "#e62828") == ShotStyle.colours[0])
        #expect(ShotStyle.rgb(ofHex: "#000000") == .init(r: 0, g: 0, b: 0))
        #expect(ShotStyle.rgb(ofHex: "#0A0b0C") == .init(r: 10, g: 11, b: 12))
        for bad in ["E62828", "0E62828", "#E6282", "#E628288", "#E6282G", "", "#", "red", "#E62 28"] {
            #expect(ShotStyle.rgb(ofHex: bad) == nil, "\(bad)")
        }
        #expect(ShotStyle.hex(.init(r: 1, g: 0xAB, b: 0xFF)) == "#01ABFF")
    }

    @Test func oneAnnotationThatCannotBeReadRefusesTheWholeRequest() {
        let good = ##"{"type": "rect", "rect": [1, 2, 30, 40], "color": "#E62828", "width": 2}"##
        func bad(_ item: String, _ why: Comment) {
            #expect(items("[\(good), \(item)]") == nil, why)
        }
        #expect(items("[\(good)]")?.count == 1)
        bad(##"{"type": "rect", "rect": [1, 2, 30, 40], "color": "#E62828", "width": 3}"##, "3 is not one of the five widths")
        bad(#"{"type": "rect", "rect": [1, 2, 30, 40], "color": "red", "width": 2}"#, "not a colour")
        bad(#"{"type": "rect", "rect": [1, 2, 30, 40], "width": 2}"#, "no colour")
        bad(##"{"type": "rect", "rect": [1, 2, 30], "color": "#E62828", "width": 2}"##, "three numbers are not a rectangle")
        bad(##"{"type": "text", "at": [1, 2], "text": "x", "color": "#E62828", "font_size": 15}"##, "15 is not a font size")
        bad(##"{"type": "text", "at": [1, 2], "text": "x", "color": "#E62828", "width": 2}"##, "text has a font size, not a width")
        bad(##"{"type": "number", "at": [1, 2], "text": "x", "color": "#E62828", "font_size": 18}"##, "the core numbers them; one without is a fault")
        bad(##"{"type": "pen", "points": [[1, 1]], "color": "#E62828", "width": 2}"##, "one point is not a stroke")
        bad(##"{"type": "pen", "points": [[1, 1], [2]], "color": "#E62828", "width": 2}"##, "a point with one number")
        bad(#"{"type": "mosaic", "rect": [0, 0, 10, 10], "block": 10}"#, "10 is not a block size")
        bad(#"{"type": "sticker", "rect": [0, 0, 10, 10]}"#, "no such type")
        bad("7", "not an object")
    }

    @Test func textIsMeasuredOnceTheScaleIsKnown() throws {
        let read = try #require(items(#"""
        [{"type": "text", "at": [10, 20], "text": "hello", "color": "#E62828", "font_size": 18},
         {"type": "number", "n": 1, "at": [50, 60], "text": "ab", "color": "#E62828", "font_size": 24},
         {"type": "number", "n": 2, "at": [50, 90], "text": "", "color": "#E62828", "font_size": 24},
         {"type": "rect", "rect": [1, 2, 30, 40], "color": "#E62828", "width": 2}]
        """#))
        let sized = ShotAgent.measured(read, scale: 2, measure: Ten())
        #expect(sized.map(\.shape) == [
            .text(at: Pt(10, 20), text: "hello", size: .init(50, 36)),
            .number(n: 1, at: Pt(50, 60), text: "ab", size: .init(20, 48)),
            .number(n: 2, at: Pt(50, 90), text: "", size: .zero),
            .rect(PixelRect(1, 2, 30, 40)),
        ])
        #expect(ShotAgent.measured(read, scale: 1, measure: Ten())[0].shape
            == .text(at: Pt(10, 20), text: "hello", size: .init(50, 18)))
    }

    // MARK: Displays and windows

    private let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 100, width: 1920, height: 1080)]
    private let displays = [
        ShotAgent.DisplayInfo(size: .init(3024, 1964), scale: 2, primary: true),
        ShotAgent.DisplayInfo(size: .init(1920, 1080), scale: 1, primary: false),
    ]

    @Test func aWindowIsCountedOnTheDisplayItsCentreIsOn() {
        #expect(ShotAgent.display(of: CGRect(x: 100, y: 100, width: 400, height: 300), among: screens) == 0)
        // Across both, mostly on the second.
        #expect(ShotAgent.display(of: CGRect(x: 1400, y: 200, width: 500, height: 300), among: screens) == 1)
        #expect(ShotAgent.display(of: CGRect(x: 1200, y: 200, width: 500, height: 300), among: screens) == 0)
        // Its centre is on neither (in the gap above the second), but it
        // reaches onto both: the one it covers more of.
        #expect(ShotAgent.display(of: CGRect(x: 1500, y: -200, width: 400, height: 400), among: screens) == 1)
        #expect(ShotAgent.display(of: CGRect(x: 1300, y: -300, width: 500, height: 400), among: screens) == 0)
        #expect(ShotAgent.display(of: CGRect(x: 9000, y: 9000, width: 10, height: 10), among: screens) == nil)
        // Its centre in the first one's bottom right corner, most of it on
        // the second: the centre decides, not the larger share.
        #expect(ShotAgent.display(of: CGRect(x: 1300, y: 770, width: 400, height: 400), among: screens) == 0)
    }

    @Test func aWindowsRectangleIsInItsDisplaysOwnPixelsAndMayReachPastIt() {
        #expect(ShotAgent.rect(of: CGRect(x: 100, y: 50, width: 400, height: 300), on: screens[0], scale: 2)
            == PixelRect(200, 100, 800, 600))
        #expect(ShotAgent.rect(of: CGRect(x: 1400, y: 200, width: 500, height: 300), on: screens[1], scale: 1)
            == PixelRect(-112, 100, 500, 300))
        #expect(ShotAgent.rect(of: CGRect(x: 10.2, y: 10.3, width: 100.1, height: 50.4), on: screens[0], scale: 2)
            == PixelRect(left: 20, top: 21, right: 221, bottom: 121))
    }

    private let listed = [
        ShotAgent.WindowInfo(id: 7, app: "Safari", title: "A \"page\"", pid: 4242, display: 1, rect: PixelRect(-112, 100, 500, 300)),
        ShotAgent.WindowInfo(id: 9, app: nil, title: "", pid: nil, display: 0, rect: PixelRect(200, 100, 800, 600)),
    ]

    @Test func theWindowListSaysWhatTheContractSays() {
        let json = ShotAgent.windowsJSON(displays: displays, windows: listed, cap: 65536)
        #expect(json == #"{"displays": [{"index": 0, "size": [3024, 1964], "scale": 2.0, "primary": true}, "#
            + #"{"index": 1, "size": [1920, 1080], "scale": 1.0, "primary": false}], "#
            + #""windows": [{"window_id": 7, "app": "Safari", "title": "A \"page\"", "pid": 4242, "display": 1, "rect": [-112, 100, 500, 300]}, "#
            + #"{"window_id": 9, "display": 0, "rect": [200, 100, 800, 600]}]}"#)
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
        // A name that is there but empty is left out like one that is not.
        let unnamed = ShotAgent.WindowInfo(id: 3, app: "", title: nil, pid: nil, display: 0, rect: PixelRect(0, 0, 1, 1))
        #expect(ShotAgent.windowsJSON(displays: [], windows: [unnamed], cap: 65536)
            == "{\"displays\": [], \"windows\": [{\"window_id\": 3, \"display\": 0, \"rect\": [0, 0, 1, 1]}]}")
    }

    @Test func aListThatDoesNotFitIsCutAtAWindowAndSaysSo() throws {
        let many = (0..<50).map {
            ShotAgent.WindowInfo(id: UInt64($0), app: "App", title: "Window \($0)", pid: 1, display: 0, rect: PixelRect(0, 0, 10, 10))
        }
        let whole = ShotAgent.windowsJSON(displays: displays, windows: many, cap: 65536)
        #expect(!whole.contains("truncated"))
        let cut = ShotAgent.windowsJSON(displays: displays, windows: many, cap: 1000)
        #expect(cut.utf8.count <= 1000)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(cut.utf8)) as? [String: Any], "half a document")
        #expect(root["truncated"] as? Bool == true)
        let windows = try #require(root["windows"] as? [[String: Any]])
        #expect(windows.count > 0 && windows.count < 50)
        // The ones kept are the ones in front.
        #expect(windows.first?["window_id"] as? Int == 0)
        #expect(windows.last?["window_id"] as? Int == windows.count - 1)
        // One more would not have fitted.
        let oneMore = ShotAgent.windowsJSON(displays: displays, windows: Array(many.prefix(windows.count + 1)), cap: 65536)
        #expect(oneMore.utf8.count + #", "truncated": true"#.utf8.count > 1000)
        // With no room for even one window the displays are still a document.
        let none = ShotAgent.windowsJSON(displays: displays, windows: many, cap: 10)
        #expect((try? JSONSerialization.jsonObject(with: Data(none.utf8))) != nil)
        #expect(none.contains(#""windows": [], "truncated": true"#))
    }

    // MARK: Areas

    private func area(_ target: ShotAgent.Target, terminal: ShotAgent.WindowInfo? = nil) -> Result<ShotAgent.Area, ShotAgent.Refusal> {
        ShotAgent.area(of: target, displays: displays, windows: listed, terminal: terminal)
    }

    private func code(_ result: Result<ShotAgent.Area, ShotAgent.Refusal>) -> ShotAgent.Code? {
        if case let .failure(refusal) = result { return refusal.code }
        return nil
    }

    private func found(_ result: Result<ShotAgent.Area, ShotAgent.Refusal>) -> ShotAgent.Area? {
        try? result.get()
    }

    @Test func aDisplayIsAllOfIt() {
        #expect(found(area(.display(1))) == .init(display: 1, rect: PixelRect(0, 0, 1920, 1080), window: nil))
        #expect(code(area(.display(2))) == .noSuchDisplay)
        #expect(code(area(.display(-1))) == .noSuchDisplay)
    }

    @Test func aWindowIsThePartOfItOnItsDisplay() {
        #expect(found(area(.window(7))) == .init(display: 1, rect: PixelRect(0, 100, 388, 300), window: listed[0]))
        #expect(found(area(.window(9))) == .init(display: 0, rect: PixelRect(200, 100, 800, 600), window: listed[1]))
        #expect(code(area(.window(8))) == .noSuchWindow)
    }

    @Test func aRegionIsClippedToItsDisplayAndAnEmptyOneIsRefused() {
        #expect(found(area(.region(display: 0, rect: PixelRect(10, 20, 300, 200))))
            == .init(display: 0, rect: PixelRect(10, 20, 300, 200), window: nil))
        #expect(found(area(.region(display: 1, rect: PixelRect(1800, 1000, 300, 200))))?.rect == PixelRect(1800, 1000, 120, 80))
        #expect(code(area(.region(display: 1, rect: PixelRect(1920, 0, 10, 10)))) == .badRegion)
        #expect(code(area(.region(display: 0, rect: PixelRect(10, 20, 0, 200)))) == .badRegion)
        #expect(code(area(.region(display: 0, rect: PixelRect(10, 20, 300, -5)))) == .badRegion)
        #expect(code(area(.region(display: 5, rect: PixelRect(10, 20, 300, 200)))) == .noSuchDisplay)
    }

    @Test func aTerminalIsTheWindowItIsInWhenThatIsOnScreen() {
        let window = ShotAgent.WindowInfo(id: 55, app: "Polter", title: "zsh", pid: 1, display: 0, rect: PixelRect(100, 100, 600, 400))
        #expect(found(area(.terminal, terminal: window)) == .init(display: 0, rect: PixelRect(100, 100, 600, 400), window: window))
        #expect(code(area(.terminal)) == .captureFailed)
        // Wholly off its display.
        let gone = ShotAgent.WindowInfo(id: 56, app: "Polter", title: "zsh", pid: 1, display: 0, rect: PixelRect(-900, 100, 600, 400))
        #expect(code(area(.terminal, terminal: gone)) == .captureFailed)
        let nowhere = ShotAgent.WindowInfo(id: 57, app: nil, title: nil, pid: nil, display: 4, rect: PixelRect(0, 0, 10, 10))
        #expect(code(area(.terminal, terminal: nowhere)) == .captureFailed)
    }

    // MARK: Answers

    @Test func theAnswersAreTheContracts() {
        #expect(ShotAgent.directoryJSON("/Users/a b/shots") == #"{"directory": "/Users/a b/shots"}"#)
        #expect(ShotAgent.doneJSON(path: "/s/a.png", json: "/s/a.json", size: .init(800, 500))
            == #"{"path": "/s/a.png", "json": "/s/a.json", "size": [800, 500]}"#)
        #expect(ShotAgent.longJSON(
            path: "/s/a.png", json: "/s/a.json", size: .init(800, 3000),
            tiles: [.init(image: "a-1.png", y: 0, height: 1800), .init(image: "a-2.png", y: 1680, height: 1320)],
            pages: 3, stopped: .bottom)
            == #"{"path": "/s/a.png", "json": "/s/a.json", "size": [800, 3000], "#
            + #""tiles": [{"image": "a-1.png", "y": 0, "height": 1800}, {"image": "a-2.png", "y": 1680, "height": 1320}], "#
            + #""pages": 3, "stopped": "bottom"}"#)
        #expect(ShotAgent.Refusal(code: .noSuchWindow, message: "No \"such\" window.").json
            == #"{"code": "NoSuchWindow", "message": "No \"such\" window."}"#)
    }

    @Test func theRefusalCodesAreTheContractsNames() {
        let names: [(ShotAgent.Code, String)] = [
            (.screenRecordingRequired, "ScreenRecordingRequired"), (.accessibilityRequired, "AccessibilityRequired"),
            (.noSuchWindow, "NoSuchWindow"), (.noSuchDisplay, "NoSuchDisplay"), (.badRegion, "BadRegion"),
            (.busy, "Busy"), (.badImage, "BadImage"), (.captureFailed, "CaptureFailed"), (.writeFailed, "WriteFailed"),
        ]
        for (code, name) in names { #expect(code.rawValue == name) }
        #expect([ShotAgent.Stopped.pages, .bottom, .limit].map(\.rawValue) == ["pages", "bottom", "limit"])
    }

    // MARK: An annotated copy

    @Test func anAnnotatedCopyKeepsWhatThePictureIsOfAndAddsToWhatWasDrawn() throws {
        let stamp = ShotSidecar.Stamp(year: 2026, month: 10, day: 6, hour: 1, minute: 2, second: 3, utcOffsetMinutes: 0)
        var old = ShotSidecar.Meta(
            image: "20261006-010203-000.png", taken: stamp, width: 100, height: 80, scale: 2,
            source: .window(app: "Safari", title: "Docs", pid: 9, windowRect: PixelRect(1, 2, 100, 80), selectionRect: PixelRect(1, 2, 100, 80)))
        old.display = .init(index: 1, width: 1920, height: 1080, scale: 2)
        old.redacted = [PixelRect(5, 5, 10, 10)]
        let original = ShotSidecar.json(old, items: [Annotation(shape: .rect(PixelRect(1, 1, 5, 5)), colour: 0, level: 1)])
        let fresh = ShotSidecar.json(
            ShotSidecar.Meta(
                image: "20261006-020000-000.png", taken: stamp, width: 100, height: 80, scale: 2,
                by: .agent(terminal: "0xa1"), source: .region(selectionRect: PixelRect(0, 0, 100, 80)),
                previous: "20261006-010203-000.png"),
            items: [Annotation(shape: .arrow(from: Pt(1, 1), to: Pt(9, 9)), colour: 5, level: 1)])

        let text = try #require(ShotAgent.annotatedSidecar(fresh: fresh, original: original))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(root["image"] as? String == "20261006-020000-000.png")
        #expect(root["by"] as? String == "agent")
        #expect(root["agent_terminal"] as? String == "0xa1")
        #expect(root["previous"] as? String == "20261006-010203-000.png")
        #expect((root["source"] as? [String: Any])?["kind"] as? String == "window")
        #expect((root["source"] as? [String: Any])?["title"] as? String == "Docs")
        #expect((root["display"] as? [String: Any])?["index"] as? Int == 1)
        #expect(root["redacted"] as? [[Int]] == [[5, 5, 10, 10]])
        let annotations = try #require(root["annotations"] as? [[String: Any]])
        #expect(annotations.map { $0["type"] as? String } == ["rect", "arrow"], "the old ones first")
        #expect(text.hasSuffix("}\n"))
    }

    @Test func aCopyOfAPictureWithNoSidecarMakesNothingUp() throws {
        let stamp = ShotSidecar.Stamp(year: 2026, month: 10, day: 6, hour: 1, minute: 2, second: 3, utcOffsetMinutes: 0)
        let fresh = ShotSidecar.json(
            ShotSidecar.Meta(
                image: "b.png", taken: stamp, width: 100, height: 80, scale: 1,
                by: .agent(terminal: "0xa1"), source: .region(selectionRect: PixelRect(0, 0, 100, 80)), previous: "a.png"),
            items: [Annotation(shape: .rect(PixelRect(1, 1, 5, 5)), colour: 0, level: 1)])
        for original in [nil, "not json", "[]"] as [String?] {
            let text = try #require(ShotAgent.annotatedSidecar(fresh: fresh, original: original))
            let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(root["source"] == nil, "what it is of is not known")
            #expect(root["display"] == nil)
            #expect(root["redacted"] == nil)
            #expect((root["annotations"] as? [Any])?.count == 1)
            #expect(root["previous"] as? String == "a.png")
        }
        #expect(ShotAgent.annotatedSidecar(fresh: "nonsense", original: nil) == nil)
    }

    @Test func anAnnotatedCopyIsDrawnAtTheScaleOfItsOriginal() {
        #expect(ShotAgent.scale(ofSidecar: #"{"scale": 2.0}"#) == 2)
        #expect(ShotAgent.scale(ofSidecar: #"{"scale": 1.5, "display": {"scale": 3}}"#) == 1.5)
        #expect(ShotAgent.scale(ofSidecar: nil) == 1)
        #expect(ShotAgent.scale(ofSidecar: "{}") == 1)
        #expect(ShotAgent.scale(ofSidecar: #"{"scale": 0}"#) == 1)
        #expect(ShotAgent.scale(ofSidecar: #"{"scale": "2"}"#) == 1)
        #expect(ShotAgent.scale(ofSidecar: "garbage") == 1)
    }

    // MARK: Scrolling

    @Test func aScreenIsScrolledInStepsThatOverlapByFarMoreThanStitchingNeeds() {
        #expect(ShotAgent.Scroll.stepsPerPage == 4)
        #expect(ShotAgent.Scroll.step(height: 1000) == 200)
        #expect(ShotAgent.Scroll.step(height: 600) == 120)
        #expect(ShotAgent.Scroll.step(height: 3) == 1, "never nothing")
        // A step leaves four fifths of the frame in common with the last:
        // the stitcher asks for an eighth.
        for height in [200, 600, 1440, 2160] {
            let overlap = height - ShotAgent.Scroll.step(height: height)
            #expect(overlap >= max(24, height / 8) * 4, "\(height)")
        }
    }

    @Test func aLongScreenshotStopsAtTheLimitTheBottomOrTheScreensAskedFor() {
        #expect(ShotAgent.stop(after: 1, of: 3, addedThisPage: 400, full: false) == nil)
        #expect(ShotAgent.stop(after: 3, of: 3, addedThisPage: 400, full: false) == .pages)
        #expect(ShotAgent.stop(after: 2, of: 3, addedThisPage: 0, full: false) == .bottom)
        #expect(ShotAgent.stop(after: 1, of: 3, addedThisPage: 400, full: true) == .limit)
        // The limit is said before the bottom, and the bottom before "as
        // many as were asked for": each is the more particular reason.
        #expect(ShotAgent.stop(after: 3, of: 3, addedThisPage: 0, full: true) == .limit)
        #expect(ShotAgent.stop(after: 3, of: 3, addedThisPage: 0, full: false) == .bottom)
    }
}
