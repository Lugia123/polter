import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The editor's layout, pinned as pictures.
///
/// **What this replaces.** Checklist items 6 and 8 -- are the four panes
/// there and in this order, does the read-only pane still carry the sentence
/// that keeps people from hunting for a switch, does anything overlap or get
/// cut off at the narrowest width the window allows. Every one of those is a
/// claim about pixels that no assertion over the model can make: the model
/// can be perfectly right while the view that draws it is not.
///
/// **What a snapshot is and is not.** It answers one question -- *did this
/// change* -- and it answers it for everything at once, including changes
/// nobody meant to make. It cannot say whether a picture is any good. So the
/// checklist keeps the judgement items (is the grey readable, does the icon
/// mean the right thing) and hands over the "is it still what it was" ones.
///
/// **Where the references live and why.** Next to this file, found through
/// `#filePath`, not through the test bundle. Putting them in the bundle
/// means teaching `project.pbxproj` about them, and that file is shared with
/// everyone working in this tree. The cost is that these tests only run from
/// a checkout -- which is already true of the whole target: CI does not
/// build the macOS app at all (`.github/workflows/test.yml` passes
/// `-Demit-macos-app=false`).
///
/// ⚠️ **A reference is a recording of one machine.** These were recorded on
/// macOS 26.5.1 / Xcode 26.6. A different system version can redraw a
/// control and turn these red without anything in this repository having
/// changed. That is a real cost and it is the reason the diff is reported as
/// a pixel count and written out to `/tmp` -- so the first question after a
/// red can be "look at it" rather than "re-record it".
///
/// Re-record with `POLTER_SNAPSHOT_RECORD=1`.
@MainActor
@Suite
struct PersonaEditorSnapshotTests {
    // MARK: The pictures

    @Test func anEditorWithNothingReportedYet() throws {
        try check(Self.nothingReported, "editor-empty-light", .aqua, size: Self.standard)
    }

    @Test func anEditorWithARoleOnAndOneThingChangedByHand() throws {
        try check(Self.rich, "editor-rich-light", .aqua, size: Self.standard)
    }

    @Test func theSameEditorInDarkMode() throws {
        try check(Self.rich, "editor-rich-dark", .darkAqua, size: Self.standard)
    }

    /// Item 8: dragged as narrow as the window will go. Text has to wrap,
    /// nothing may be cut off at the right edge.
    @Test func theSameEditorAtItsNarrowest() throws {
        try check(Self.rich, "editor-rich-narrow", .aqua, size: Self.narrowest)
    }

    // MARK: The instrument

    /// Before any picture is trusted: two renders of one model are the same
    /// picture.
    ///
    /// Without this, a red anywhere above has two explanations that look
    /// alike -- the view changed, or the renderer is not repeatable -- and
    /// the second one would be discovered by re-recording until it went
    /// green.
    @Test func renderingTheSameModelTwiceGivesTheSamePixels() throws {
        let a = try Self.render(Self.rich, size: Self.standard, appearance: .aqua)
        let b = try Self.render(Self.rich, size: Self.standard, appearance: .aqua)
        #expect(try Self.differingPixels(a, b) == 0)
    }

    /// Every pixel is opaque, which is to say the picture is in the colour
    /// channels where a comparison can see it.
    ///
    /// This one is here because its absence cost an afternoon: composited
    /// the wrong way, the render came out with the content in its alpha
    /// channel and its RGB planes flat. Two renders that differed by a whole
    /// line of text then compared as identical, and every snapshot above was
    /// green for the reason that it was looking at nothing.
    @Test func everyRenderIsOpaqueSoTheComparisonIsLookingAtColour() throws {
        let rep = try Self.render(Self.rich, size: Self.standard, appearance: .aqua)
        let data = try #require(rep.bitmapData)
        var transparent = 0
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide where row[x * 4 + 3] != 255 {
                transparent += 1
            }
        }
        #expect(transparent == 0, "\(transparent) pixels are not opaque")
    }

    /// And two different models are not the same picture -- otherwise
    /// everything above could be comparing blank canvases.
    @Test func twoDifferentModelsAreNotTheSamePicture() throws {
        let a = try Self.render(Self.rich, size: Self.standard, appearance: .aqua)
        let b = try Self.render(Self.nothingReported, size: Self.standard, appearance: .aqua)
        #expect(try Self.differingPixels(a, b) > 0)
    }

    // MARK: Models

    /// Tall enough that the editor's fourth pane -- the read-only one, and
    /// the sentence under its heading -- is drawn rather than left below the
    /// scroll view's fold. A snapshot of a pane nobody scrolled to is a
    /// snapshot that cannot notice it went missing.
    static let standard = NSSize(width: 520, height: 1180)

    /// `PersonaEditorView`'s own `minWidth` / `minHeight`: the narrowest the
    /// window can actually be dragged to.
    static let narrowest = NSSize(width: 460, height: 420)

    /// What this machine draws today: the core reads `personas.json`, no
    /// such file exists, and nothing has reported a face or an inventory.
    static let nothingReported = PersonaEditorModel(
        terminalTitle: "~/work/ghostty — zsh",
        state: .none,
        personas: [],
        personasKnown: false,
        face: PersonaFace(),
        inventory: .unknown,
        shielded: false)

    /// Everything the editor can draw at once, including the states the core
    /// does not produce yet -- a snapshot of a pane that is never reached is
    /// a snapshot of nothing.
    static let rich: PersonaEditorModel = {
        var face = PersonaFace()
        face.isKnown = true
        face.skills = [
            .init(id: "1-0", name: "提交", enabled: true, inPersona: true),
            .init(id: "1-1", name: "发版", enabled: false, inPersona: true),
            .init(id: "1-2", name: "nano-banana", enabled: true, inPersona: false),
        ]
        face.mcp = [
            .init(id: "1-3", name: "argus", enabled: true, inPersona: true, slot: .granted),
            .init(id: "1-4", name: "kairos", enabled: true, inPersona: true, slot: .broken),
            .init(id: "1-5", name: "tinia", enabled: false, inPersona: false, slot: .withheld),
            .init(id: "1-6", name: "pencil", enabled: true, inPersona: true, slot: .transparent),
        ]
        face.epoch = 12
        face.roster = 3

        var inventory = HostInventory.unknown
        inventory.isKnown = true
        inventory.host = "claude-code"
        inventory.plugins = .read(["argus", "kanban", "design"])
        inventory.skills = .failed("open ~/.claude/skills: permission denied")
        inventory.mcpServers = .absent
        inventory.slotBudgetComplete = false

        return PersonaEditorModel(
            terminalTitle: "~/work/ghostty — zsh",
            state: PersonaState(key: "archer", name: "射手", deviated: true,
                                hostClass: .unknown, agentPresent: true),
            personas: [
                Persona(key: "archer", name: "射手",
                        prompt: "你只管把箭射出去，别管它落在哪。",
                        hint: .init(disableHostPlugins: ["kanban"], model: "claude-opus-5")),
                Persona(key: "scribe", name: "抄写员"),
            ],
            personasKnown: true,
            face: face,
            inventory: inventory,
            shielded: false)
    }()

    // MARK: Machinery

    private static let referenceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")

    private static var recording: Bool {
        ProcessInfo.processInfo.environment["POLTER_SNAPSHOT_RECORD"] == "1"
    }

    /// How far apart two pixels may be before they count as different.
    ///
    /// Not zero, and not because rendering drifts -- see
    /// `renderingTheSameModelTwiceGivesTheSamePixels`, which holds at zero.
    /// It is here so that a PNG round trip cannot fail this on its own.
    private static let channelTolerance = 4

    /// How much of the picture may differ before it is a different picture.
    ///
    /// Deliberately small: the changes this is here to catch -- a line of
    /// text gone, a pane reordered, a control resized -- move thousands of
    /// pixels. See the floor recorded in the checklist.
    private static let allowedFraction = 0.001

    private func check(
        _ model: PersonaEditorModel,
        _ name: String,
        _ appearance: NSAppearance.Name,
        size: NSSize
    ) throws {
        let rendered = try Self.render(model, size: size, appearance: appearance)
        let reference = Self.referenceDirectory.appendingPathComponent("\(name).png")

        guard !Self.recording, FileManager.default.fileExists(atPath: reference.path) else {
            try Self.writePNG(rendered, to: reference)
            Issue.record("""
                recorded \(reference.lastPathComponent). A recording is not a check -- \
                run again without POLTER_SNAPSHOT_RECORD to compare against it.
                """)
            return
        }

        let expected = try Self.load(reference, size: size)
        let differing = try Self.differingPixels(expected, rendered)
        let total = Int(size.width * size.height)
        let fraction = Double(differing) / Double(total)

        if fraction > Self.allowedFraction {
            let failure = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(name).actual.png")
            try? Self.writePNG(rendered, to: failure)
            try? Self.writePNG(expected, to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(name).expected.png"))
            Issue.record("""
                \(name): \(differing) of \(total) pixels differ (\(fraction * 100)%), \
                over the \(Self.allowedFraction * 100)% allowance. \
                What was drawn: \(failure.path) -- and what was expected, \
                beside it as \(name).expected.png
                """)
        }
    }

    private static func render(
        _ model: PersonaEditorModel,
        size: NSSize,
        appearance: NSAppearance.Name
    ) throws -> NSBitmapImageRep {
        let state = PersonaEditorState(model)
        // `.tint` pins the accent colour. Without it the picture depends on
        // a System Settings checkbox, and the reference would be a recording
        // of one machine's preferences as well as its OS.
        let view = PersonaEditorView(
            state: state,
            onSelectPersona: { _ in },
            onToggleSkill: { _, _ in },
            onToggleMCP: { _, _ in },
            onResetToPersona: {},
            onClose: {})
            .tint(.blue)

        // In a window, not free-floating. A hosting view on its own draws
        // the SwiftUI layers but not the AppKit controls SwiftUI puts inside
        // them -- the first recording of this came back with every checkbox
        // column blank, which would have made the snapshot silently blind to
        // exactly the rows the editor exists to switch.
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let drawn = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: drawn)

        let canvas = try canonicalRep(size: size)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        // An opaque backdrop: a transparent one would make every diff depend
        // on what the PNG decoder did with alpha.
        (appearance == .darkAqua ? NSColor.black : NSColor.white).setFill()
        NSRect(origin: .zero, size: size).fill()
        // Through an NSImage with an explicit `.sourceOver`, not
        // `drawn.draw(in:)`. The first version of this used the latter, and
        // it left the whole picture in the alpha channel with the RGB
        // planes identical between two visibly different renders -- a
        // comparison over RGB then said "0 pixels differ" about a missing
        // line of text. `everyRenderIsOpaque` is what holds this down now.
        let image = NSImage(size: size)
        image.addRepresentation(drawn)
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1)
        return canvas
    }

    /// One pixel format for everything that gets compared, so that "these
    /// two pictures differ" is never really "these two buffers are laid out
    /// differently".
    private static func canonicalRep(size: NSSize) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: Int(size.width) * 4,
            bitsPerPixel: 32))
    }

    private static func load(_ url: URL, size: NSSize) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: url)
        let image = try #require(NSImage(data: data), "\(url.lastPathComponent) is not an image")
        let canvas = try canonicalRep(size: size)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        image.draw(in: NSRect(origin: .zero, size: size))
        return canvas
    }

    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private static func differingPixels(
        _ a: NSBitmapImageRep,
        _ b: NSBitmapImageRep
    ) throws -> Int {
        try #require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh,
                     "different sizes: \(a.pixelsWide)x\(a.pixelsHigh) vs \(b.pixelsWide)x\(b.pixelsHigh)")
        let lhs = try #require(a.bitmapData)
        let rhs = try #require(b.bitmapData)

        var differing = 0
        for y in 0..<a.pixelsHigh {
            let rowA = lhs + y * a.bytesPerRow
            let rowB = rhs + y * b.bytesPerRow
            for x in 0..<a.pixelsWide {
                let i = x * 4
                for channel in 0..<4 where abs(Int(rowA[i + channel]) - Int(rowB[i + channel])) > channelTolerance {
                    differing += 1
                    break
                }
            }
        }
        return differing
    }
}
