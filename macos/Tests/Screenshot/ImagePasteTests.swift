import Foundation
import Testing
@testable import Ghostty

/// The decisions of `dev-docs/poltergeist/screenshot.md`, section 2.
struct ImagePasteTests {
    private typealias Clipboard = ImagePaste.Clipboard

    // MARK: Priority

    @Test func anImageAloneIsPastedAsAnImage() {
        let only = Clipboard(hasText: false, hasFiles: false, hasImage: true)
        #expect(ImagePaste.source(for: only, pasteImage: true) == .image)
    }

    @Test func textWinsOverAnImage() {
        // A copy out of a web page: both are there, and the text was meant.
        let both = Clipboard(hasText: true, hasFiles: false, hasImage: true)
        #expect(ImagePaste.source(for: both, pasteImage: true) == .text)
    }

    @Test func aCopiedFileWinsOverAnImage() {
        // A picture copied in Finder carries its file and a preview of it.
        let both = Clipboard(hasText: false, hasFiles: true, hasImage: true)
        #expect(ImagePaste.source(for: both, pasteImage: true) == .files)
    }

    @Test func textWinsOverACopiedFile() {
        let all = Clipboard(hasText: true, hasFiles: true, hasImage: true)
        #expect(ImagePaste.source(for: all, pasteImage: true) == .text)
    }

    @Test func switchedOffAnImageAloneIsNothing() {
        let only = Clipboard(hasText: false, hasFiles: false, hasImage: true)
        #expect(ImagePaste.source(for: only, pasteImage: false) == .nothing)
    }

    @Test func theSwitchChangesNothingElse() {
        for hasText in [false, true] {
            for hasFiles in [false, true] {
                for hasImage in [false, true] {
                    let c = Clipboard(hasText: hasText, hasFiles: hasFiles, hasImage: hasImage)
                    let on = ImagePaste.source(for: c, pasteImage: true)
                    let off = ImagePaste.source(for: c, pasteImage: false)
                    if on == .image {
                        #expect(off == .nothing)
                    } else {
                        #expect(on == off)
                    }
                }
            }
        }
    }

    @Test func anEmptyClipboardIsNothing() {
        let empty = Clipboard(hasText: false, hasFiles: false, hasImage: false)
        #expect(ImagePaste.source(for: empty, pasteImage: true) == .nothing)
    }

    // MARK: Reuse

    private let url = URL(fileURLWithPath: "/shots/20261006-153012-123.png")

    @Test func theSameChangeCountReusesTheFile() {
        var cache = ImagePaste.Cache()
        cache.remember(changeCount: 41, url: url)
        #expect(cache.reusable(changeCount: 41, fileExists: { _ in true })?.url == url)
    }

    @Test func aDifferentChangeCountDoesNot() {
        var cache = ImagePaste.Cache()
        cache.remember(changeCount: 41, url: url)
        // Later, and earlier: neither is "the same clipboard".
        #expect(cache.reusable(changeCount: 42, fileExists: { _ in true }) == nil)
        #expect(cache.reusable(changeCount: 40, fileExists: { _ in true }) == nil)
    }

    @Test func aFileThatIsGoneIsNotReused() {
        var cache = ImagePaste.Cache()
        cache.remember(changeCount: 41, url: url)
        var asked: [URL] = []
        let reused = cache.reusable(changeCount: 41, fileExists: { asked.append($0); return false })
        #expect(reused == nil)
        #expect(asked == [url])
    }

    @Test func nothingRememberedIsNothingReused() {
        let cache = ImagePaste.Cache()
        #expect(cache.reusable(changeCount: 0, fileExists: { _ in true }) == nil)
    }

    @Test func theAnnotationsTravelWithTheFile() {
        var cache = ImagePaste.Cache()
        cache.remember(changeCount: 7, url: url, annotations: "[Screenshot annotations 10×10] ① (1,2) here")
        #expect(cache.reusable(changeCount: 7, fileExists: { _ in true })?.annotations
            == "[Screenshot annotations 10×10] ① (1,2) here")

        // A plain pasted image has none, and remembering it forgets the last one's.
        cache.remember(changeCount: 8, url: url)
        #expect(cache.reusable(changeCount: 8, fileExists: { _ in true })?.annotations == nil)
    }
}
