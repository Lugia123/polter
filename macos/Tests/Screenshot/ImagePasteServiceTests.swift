import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Pasting an image as a path, against a real pasteboard and a real
/// directory (`dev-docs/poltergeist/screenshot.md`, section 2).
struct ImagePasteServiceTests {
    /// A uniquely-named pasteboard, so the user's own is never touched.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// A directory with a space in its name: the path has to come back escaped.
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("image paste \(UUID().uuidString)", isDirectory: true)
    }

    /// A real one-pixel PNG.
    private func png(red: CGFloat = 1) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(NSColor(deviceRed: red, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// What a POSIX shell makes of `text` typed at a prompt, one word per
    /// element (no globbing, nothing run).
    private func shellWords(_ text: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -f; for a in \(text); do printf '%s\\n' \"$a\"; done"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }

    /// What the terminal would receive, with the escaping undone.
    private func unescaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "")
    }

    @Test func anImageAloneIsWrittenAndItsEscapedPathIsThePaste() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = png()
        pasteboard.setData(image, forType: .png)

        let service = ImagePasteService()
        let pasted = try #require(service.pastedPath(from: pasteboard, pasteImage: true, directory: directory))

        let written = files(in: directory)
        #expect(written.count == 1)
        #expect(ShotStore.isOurs(written[0]))
        #expect(try Data(contentsOf: directory.appendingPathComponent(written[0])) == image)

        // Exactly one path: escaped, and nothing after it.
        #expect(pasted.contains("image\\ paste\\ "))
        #expect(unescaped(pasted) == directory.appendingPathComponent(written[0]).path)
        #expect(!pasted.hasSuffix(" "))
        #expect(!pasted.hasSuffix("\n"))
    }

    @Test func pastingTheSameImageTwiceWritesOneFile() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        pasteboard.setData(png(), forType: .png)

        let service = ImagePasteService()
        let first = service.pastedPath(from: pasteboard, pasteImage: true, directory: directory)
        let second = service.pastedPath(from: pasteboard, pasteImage: true, directory: directory)

        #expect(first != nil)
        #expect(first == second)
        #expect(files(in: directory).count == 1)
    }

    @Test func aNewImageIsANewFile() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ImagePasteService()

        pasteboard.setData(png(red: 1), forType: .png)
        let first = service.pastedPath(from: pasteboard, pasteImage: true, directory: directory)

        pasteboard.clearContents()
        pasteboard.setData(png(red: 0), forType: .png)
        let second = service.pastedPath(from: pasteboard, pasteImage: true, directory: directory)

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
        #expect(files(in: directory).count == 2)
    }

    @Test func aDeletedFileIsWrittenAgain() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        pasteboard.setData(png(), forType: .png)
        let service = ImagePasteService()

        let first = try #require(service.pastedPath(from: pasteboard, pasteImage: true, directory: directory))
        try FileManager.default.removeItem(atPath: unescaped(first))
        #expect(files(in: directory).isEmpty)

        let second = try #require(service.pastedPath(from: pasteboard, pasteImage: true, directory: directory))
        #expect(FileManager.default.fileExists(atPath: unescaped(second)))
    }

    @Test func textBesideAnImageIsLeftToTheOrdinaryPaste() {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = NSPasteboardItem()
        item.setString("copied from a page", forType: .string)
        item.setData(png(), forType: .png)
        pasteboard.writeObjects([item])

        let pasted = ImagePasteService().pastedPath(from: pasteboard, pasteImage: true, directory: directory)
        #expect(pasted == nil)
        // And nothing was written on the way to deciding that.
        #expect(files(in: directory).isEmpty)
    }

    @Test func aCopiedFileIsLeftToTheOrdinaryPaste() {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: "/tmp/picture.png").absoluteString, forType: .fileURL)
        item.setData(png(), forType: .png)
        pasteboard.writeObjects([item])

        let pasted = ImagePasteService().pastedPath(from: pasteboard, pasteImage: true, directory: directory)
        #expect(pasted == nil)
        #expect(files(in: directory).isEmpty)
    }

    @Test func switchedOffNothingIsWritten() {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        pasteboard.setData(png(), forType: .png)

        let pasted = ImagePasteService().pastedPath(from: pasteboard, pasteImage: false, directory: directory)
        #expect(pasted == nil)
        #expect(files(in: directory).isEmpty)
    }

    @Test func anEmptyStringBesideAnImageIsNotText() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = NSPasteboardItem()
        item.setString("", forType: .string)
        item.setData(png(), forType: .png)
        pasteboard.writeObjects([item])

        let pasted = ImagePasteService().pastedPath(from: pasteboard, pasteImage: true, directory: directory)
        #expect(pasted != nil)
        #expect(files(in: directory).count == 1)
    }

    @Test func aTIFFIsWrittenAsAPNG() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tiff = try #require(NSBitmapImageRep(data: png())?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)

        let pasted = try #require(ImagePasteService().pastedPath(from: pasteboard, pasteImage: true, directory: directory))
        let data = try Data(contentsOf: URL(fileURLWithPath: unescaped(pasted)))
        // The PNG signature, not the TIFF that was on the clipboard.
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// What finishing a long screenshot used to send by itself, a paste
    /// sends now: the first tile answers it, the others and the line follow.
    @Test func aLongScreenshotTakenHereIsPastedAsItsTiles() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ImagePasteService()

        let url = try ShotStore.write(png: png(), to: directory)
        let tiles = (1...3).map { directory.appendingPathComponent("tile \($0).png") }
        for tile in tiles { try png().write(to: tile) }
        pasteboard.setData(png(), forType: .png)
        service.remember(changeCount: pasteboard.changeCount, url: url, tiles: tiles, annotations: nil)

        let pasted = try #require(service.pastedPath(from: pasteboard, pasteImage: true, directory: directory))
        #expect(unescaped(pasted) == tiles[0].path + " ", "the first tile, not the whole picture, set off from the next")
        // Each path but the last ends in one space; the last is exactly its
        // path, so that a paste that is alone is exactly one path.
        #expect(service.followUps(for: pasteboard).map(unescaped) == [tiles[1].path + " ", tiles[2].path])
        #expect(files(in: directory).count == 4, "nothing written by the paste")
        let stream = pasted + service.followUps(for: pasteboard).joined()
        #expect(try shellWords(stream) == tiles.map(\.path), "three paths, not one run-together: \(stream)")

        // A tile deleted: its path is not pasted. The clipboard's image is
        // saved afresh, as any image is, and nothing follows it.
        try FileManager.default.removeItem(at: tiles[1])
        let fresh = try #require(service.pastedPath(from: pasteboard, pasteImage: true, directory: directory))
        #expect(!tiles.map(\.path).contains(unescaped(fresh)))
        #expect(unescaped(fresh) != url.path)
        #expect(!fresh.hasSuffix(" "), "nothing follows it, so nothing is after it")
        #expect(service.followUps(for: pasteboard).isEmpty)
    }

    @Test func aScreenshotTakenHereIsReusedWithItsAnnotations() throws {
        let pasteboard = makePasteboard()
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ImagePasteService()

        // What finishing a screenshot does: write the file, put the image on
        // the clipboard, and say which file that image is.
        let url = try ShotStore.write(png: png(), to: directory)
        pasteboard.setData(png(), forType: .png)
        service.remember(changeCount: pasteboard.changeCount, url: url, annotations: "the line")

        let pasted = try #require(service.pastedPath(from: pasteboard, pasteImage: true, directory: directory))
        #expect(unescaped(pasted) == url.path + " ", "the line follows, so a space ends the path")
        #expect(files(in: directory).count == 1)
        #expect(service.followUps(for: pasteboard) == ["the line"], "and the line starts with nothing")

        // Finishing a screenshot pastes nothing, so this is the only way it
        // reaches a terminal -- and it may be pasted into several. Each
        // paste gives the same file and the same line.
        let again = try #require(service.pastedPath(from: pasteboard, pasteImage: true, directory: directory))
        #expect(again == pasted)
        #expect(files(in: directory).count == 1)
        #expect(service.followUps(for: pasteboard) == ["the line"])

        // Everything the terminal is given, one paste after another, is
        // words a shell can split: the path is one of them, as is each path.
        let stream = pasted + service.followUps(for: pasteboard).joined()
        #expect(try shellWords(stream) == [url.path, "the", "line"], "the path is not run into the line: \(stream)")

        // Something else is copied: the line belongs to the old image.
        pasteboard.clearContents()
        pasteboard.setData(png(red: 0), forType: .png)
        #expect(service.followUps(for: pasteboard).isEmpty)
    }
}
