import AppKit
import OSLog

/// Pasting an image as the path of a file holding it: the part that touches
/// the pasteboard and the disk. The decisions are `ImagePaste`, the file
/// rules are `ShotStore`.
final class ImagePasteService {
    static let shared = ImagePasteService()

    /// One for the app (`shared`); a test makes its own so that what one
    /// remembers is not what another finds.
    init() {}

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: String(describing: ImagePasteService.self)
    )

    private let lock = NSLock()
    private var cache = ImagePaste.Cache()
    private var runs = ImagePaste.Runs<ObjectIdentifier>()

    /// What a paste of `pasteboard` should insert in place of text, or nil
    /// when this is not an image paste -- the clipboard has text or files,
    /// has no image, or `clipboard-paste-image` is off -- and the caller
    /// carries on exactly as it did before this existed.
    ///
    /// The path is escaped the way a dropped file's is, and it is the whole
    /// of the paste: no newline, and no trailing space when nothing follows
    /// it, because Codex takes a paste as an image only when it is exactly
    /// one path. When something does follow -- a screenshot taken here has a
    /// line, or more tiles -- one space ends it (`ImagePaste.separator`).
    func pastedPath(
        from pasteboard: NSPasteboard,
        pasteImage: Bool,
        directory: URL
    ) -> String? {
        guard ImagePaste.source(for: pasteboard.ghosttyImagePasteFacts, pasteImage: pasteImage) == .image else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        let changeCount = pasteboard.changeCount
        if let saved = cache.reusable(changeCount: changeCount, fileExists: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            // A long screenshot taken here answers with its first tile;
            // the rest are `followUps`.
            let path = Ghostty.Shell.escape(saved.pastes.first.path)
            // Something follows it: set it off from what comes next.
            return saved.pastes.later.isEmpty ? path : path + ImagePaste.separator
        }

        guard let png = pasteboard.ghosttyImagePNG() else {
            Self.logger.warning("image paste: the clipboard declares an image and none could be read")
            return nil
        }
        do {
            let url = try ShotStore.write(png: png, to: directory)
            cache.remember(changeCount: changeCount, url: url)
            Self.logger.info("image paste: wrote \(png.count, privacy: .public) bytes to \(url.path, privacy: .public)")
            return Ghostty.Shell.escape(url.path)
        } catch {
            // Said rather than swallowed: the paste then inserts nothing,
            // which looks exactly like the feature being off.
            Self.logger.error("image paste: could not write to \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Record a file this app put on the clipboard itself -- a finished
    /// screenshot -- so that a paste of it reuses that file, with a long
    /// one's tiles and with its line, instead of writing the image a second
    /// time.
    func remember(changeCount: Int, url: URL, tiles: [URL] = [], annotations: String?) {
        lock.lock()
        defer { lock.unlock() }
        cache.remember(changeCount: changeCount, url: url, tiles: tiles, annotations: annotations)
    }

    /// What is pasted after the path `pastedPath` answered with, in order,
    /// when the image on `pasteboard` is a screenshot taken here: a long
    /// one's later tiles as escaped paths, then its line. Each is a paste
    /// of its own. Empty for anything else.
    func followUps(for pasteboard: NSPasteboard) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let saved = cache.reusable(changeCount: pasteboard.changeCount, fileExists: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return [] }
        return ImagePaste.separated(saved.pastes.later.map {
            switch $0 {
            case let .tile(url): return Ghostty.Shell.escape(url.path)
            case let .line(line): return line
            }
        })
    }

    /// An image paste into `pane` begins. What an earlier one still owes
    /// that terminal is not to be sent: ask `isCurrent` before each piece.
    func beginRun(in pane: ObjectIdentifier) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return runs.begin(in: pane)
    }

    func isCurrent(_ run: Int, in pane: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runs.isCurrent(run, in: pane)
    }
}
