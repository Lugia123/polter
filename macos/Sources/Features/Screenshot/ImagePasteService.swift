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

    /// What a paste of `pasteboard` should insert in place of text, or nil
    /// when this is not an image paste -- the clipboard has text or files,
    /// has no image, or `clipboard-paste-image` is off -- and the caller
    /// carries on exactly as it did before this existed.
    ///
    /// The path is escaped the way a dropped file's is, and it is the whole
    /// of the paste: no trailing space and no newline, because Codex takes
    /// a paste as an image only when it is exactly one path.
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
            return Ghostty.Shell.escape(saved.url.path)
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
    /// screenshot -- so that a later paste of it reuses that file, with its
    /// annotations, instead of writing the image a second time.
    func remember(changeCount: Int, url: URL, annotations: String?) {
        lock.lock()
        defer { lock.unlock() }
        cache.remember(changeCount: changeCount, url: url, annotations: annotations)
    }

    /// The annotation line that belongs to the image currently on
    /// `pasteboard`, when it is a screenshot taken here that has one.
    func annotations(for pasteboard: NSPasteboard) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache.reusable(changeCount: pasteboard.changeCount, fileExists: {
            FileManager.default.fileExists(atPath: $0.path)
        })?.annotations
    }
}
