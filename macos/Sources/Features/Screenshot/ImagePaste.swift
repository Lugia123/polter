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
            /// The tiles this image was cut into, when it is a long
            /// screenshot taken here. Empty otherwise.
            var tiles: [URL] = []
            /// The line of text that goes with this image, when it is a
            /// screenshot taken here and has one. Pasted last.
            var annotations: String?

            /// What pasting this is: the file whose path answers the paste
            /// itself, and what follows it in order, the first one
            /// `secondPasteDelay` after the paste and each of the others
            /// that long after the one before.
            ///
            /// An ordinary image is itself, then its line if it has one. A
            /// long screenshot is its tiles instead of itself -- a CLI
            /// shrinks anything much over 2000 px, and the whole picture
            /// shrunk cannot be read -- at most `maxPastedTiles` of them,
            /// and then the line, which is there when tiles were left out
            /// and says how many and where the whole picture is.
            ///
            /// **This paste is the only way a screenshot reaches a
            /// terminal**: finishing one sends nothing.
            var pastes: (first: URL, later: [Piece]) {
                let pasted = Array(tiles.prefix(ShotSidecar.maxPastedTiles))
                let later = pasted.dropFirst().map(Piece.tile) + (annotations.map { [Piece.line($0)] } ?? [])
                return (pasted.first ?? url, later)
            }
        }

        /// One of the pastes that follow the first.
        enum Piece: Equatable {
            /// A tile's file.
            case tile(URL)
            /// The line of text.
            case line(String)
        }

        private(set) var saved: Saved?

        /// The file to reuse for the clipboard at `changeCount`, if there is
        /// one and it is still on disk.
        ///
        /// **The change count has to match exactly.** It only ever goes up,
        /// so "at least" would hand a newer image the older one's file. And
        /// the file has to still be there: the user may have deleted it, and
        /// a path to nothing is worse than writing the image again. The
        /// same goes for every tile a paste would name.
        func reusable(changeCount: Int, fileExists: (URL) -> Bool) -> Saved? {
            guard let saved, saved.changeCount == changeCount, fileExists(saved.url),
                  saved.tiles.prefix(ShotSidecar.maxPastedTiles).allSatisfy(fileExists) else {
                return nil
            }
            return saved
        }

        mutating func remember(changeCount: Int, url: URL, tiles: [URL] = [], annotations: String? = nil) {
            saved = Saved(changeCount: changeCount, url: url, tiles: tiles, annotations: annotations)
        }
    }

    /// Which paste into each terminal is the latest, so that the pieces
    /// still owed by an earlier one are not sent.
    ///
    /// A long screenshot arrives over a second or so. Pasted again into the
    /// same terminal before it has finished, the pieces start again from the
    /// first, and what was left of the earlier run would otherwise land in
    /// between them. Another terminal's run is its own and is not touched.
    struct Runs<Pane: Hashable> {
        private var latest: [Pane: Int] = [:]

        init() {}

        /// A paste into `pane` begins: every earlier run there is over.
        mutating func begin(in pane: Pane) -> Int {
            let run = (latest[pane] ?? 0) + 1
            latest[pane] = run
            return run
        }

        /// Whether `run` is still the latest paste into `pane`.
        func isCurrent(_ run: Int, in pane: Pane) -> Bool {
            latest[pane] == run
        }
    }
}
