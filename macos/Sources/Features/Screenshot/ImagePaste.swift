import Foundation

/// The decisions behind pasting an image as the path of a file holding it
/// (`dev-docs/poltergeist/screenshot.md`, section 2). Foundation only; the
/// pasteboard itself is read in `NSPasteboard+ImagePaste.swift`.
enum ImagePaste {
    /// What a paste found on the clipboard, as three facts.
    struct Clipboard: Equatable {
        /// There is text to paste, and it is not empty.
        var hasText: Bool
        /// There is at least one file URL (a file copied in Finder).
        var hasFiles: Bool
        /// There is an image.
        var hasImage: Bool
    }

    /// What a paste should produce.
    enum Source: Equatable {
        /// The clipboard's text.
        case text
        /// The paths of the copied files.
        case files
        /// The image, written to a file, as that file's path.
        case image
        /// Nothing to paste.
        case nothing
    }

    /// Text, then files, then the image -- and the image only when
    /// `clipboard-paste-image` is on.
    ///
    /// The order is what keeps a copy out of a web page working: that puts
    /// text and an image on the clipboard together, and the text is what was
    /// meant. With the option off the answer is exactly what it was before
    /// the option existed.
    static func source(for clipboard: Clipboard, pasteImage: Bool) -> Source {
        if clipboard.hasText { return .text }
        if clipboard.hasFiles { return .files }
        if clipboard.hasImage && pasteImage { return .image }
        return .nothing
    }

    /// The file written for the image that was on the clipboard at one change
    /// count, so that pasting the same image twice writes one file.
    struct Cache: Equatable {
        struct Saved: Equatable {
            var changeCount: Int
            var url: URL
            /// The line of annotation text that goes with this image, when
            /// it is a screenshot taken here and has any. Pasted after the
            /// path.
            var annotations: String?
        }

        private(set) var saved: Saved?

        /// The file to reuse for the clipboard at `changeCount`, if there is
        /// one and it is still on disk.
        ///
        /// **The change count has to match exactly.** It only ever goes up,
        /// so "at least" would hand a newer image the older one's file. And
        /// the file has to still be there: the user may have deleted it, and
        /// a path to nothing is worse than writing the image again.
        func reusable(changeCount: Int, fileExists: (URL) -> Bool) -> Saved? {
            guard let saved, saved.changeCount == changeCount, fileExists(saved.url) else {
                return nil
            }
            return saved
        }

        mutating func remember(changeCount: Int, url: URL, annotations: String? = nil) {
            saved = Saved(changeCount: changeCount, url: url, annotations: annotations)
        }
    }
}
