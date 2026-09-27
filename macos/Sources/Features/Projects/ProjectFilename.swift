import Foundation

/// The filename a *new* project file is given. One of three implementations
/// of one rule -- `src/Project.zig`'s `sanitizeFilename` and
/// `windows/projectname/src/lib.rs`'s `sanitize_filename` are the other two --
/// and all three are held to `test/fixtures/project-filenames.tsv`, row for
/// row. Change the rule there first; see issue #23 for how the three drifted
/// apart when nothing held them together.
///
/// Only for naming new files. An existing project is found by the file a
/// listing turned up, never by recomputing its name from this rule (see
/// `ProjectStore.locate`), so a change to this rule can't make a saved
/// project disappear.
///
/// The rule:
/// 1. Walk the name by Unicode scalar. No normalization (NFC/NFD).
///    Not by grapheme cluster either: the three standard libraries carry
///    different Unicode versions, so cutting by grapheme cannot be
///    guaranteed to agree across the three implementations.
/// 2. Replace each scalar <= U+001F, U+007F, `/`, `\`, and the seven NTFS
///    forbids -- `:` `*` `?` `"` `<` `>` `|` -- with `_`.
/// 3. Stop before the scalar that would take the result past 200 UTF-8
///    bytes, so a scalar is never cut in half. 200 bytes is at most 200
///    UTF-16 units too, which keeps the file under every filesystem's
///    limit: APFS and NTFS count 255 UTF-16 units, ext4 255 bytes.
/// 4. Nothing left -> no filename (the empty name is an error, not a
///    fallback -- a fixed fallback name collides with a project really
///    called that; see `Project.zig`'s `pathFor`).
/// 5. Append `.json`.
enum ProjectFilename {
    static let maxBytes = 200

    static func forNewFile(named name: String) -> String? {
        var result = ""
        var bytes = 0
        for scalar in name.unicodeScalars {
            let safe: Unicode.Scalar = isReplaced(scalar) ? "_" : scalar
            let width = String(safe).utf8.count
            if bytes + width > maxBytes { break }
            result.unicodeScalars.append(safe)
            bytes += width
        }
        guard !result.isEmpty else { return nil }
        return result + ".json"
    }

    private static func isReplaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1f, 0x7f: return true
        case 0x2f, 0x5c: return true                              // / \
        case 0x3a, 0x2a, 0x3f, 0x22, 0x3c, 0x3e, 0x7c: return true // : * ? " < > |
        default: return false
        }
    }
}

/// Moving a project saved under an older rule's filename to the current
/// rule's, the first time it is saved again (issue #23, option C: nothing
/// is renamed up front; a project keeps its old name until it is written).
enum ProjectFileAdoption {
    enum Outcome: Equatable {
        /// The project now lives at the target, sidecars included.
        case adopted
        /// Something already lives at the target, so nothing was touched:
        /// two files claim one name, and picking a loser is not this
        /// function's call. The legacy file stays where it is.
        case targetTaken
    }

    /// Everything that belongs to the project at `url` besides the file:
    /// the `.prev` generation (`ProjectFileWriter`) and the scrollback
    /// directory (`ProjectScrollback.directory`). A move that leaves one of
    /// these behind leaves an orphan -- a scrollback directory is up to the
    /// configured limit per pane -- that nothing will ever look for.
    static func sidecars(of url: URL) -> [URL] {
        [ProjectFileWriter.previousURL(for: url), ProjectScrollback.directory(forProjectFile: url)]
    }

    /// Move `legacy` and its sidecars to `target`.
    ///
    /// Sidecars first, the file last: interrupted part way, the legacy file
    /// is still where the next save will find it and finish the job, and
    /// the sidecars already moved are already where it will want them. A
    /// sidecar the target already has is left in place rather than
    /// overwritten.
    static func adopt(_ legacy: URL, as target: URL) throws -> Outcome {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { return .targetTaken }
        for (from, to) in zip(sidecars(of: legacy), sidecars(of: target))
        where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try fm.moveItem(at: from, to: to)
        }
        try fm.moveItem(at: legacy, to: target)
        return .adopted
    }
}

extension ProjectListing {
    /// The file the project called `name` lives in: the current rule's
    /// file if there is one, otherwise whichever listed file says it is
    /// `name` -- one saved under an older rule. Nil if neither.
    ///
    /// This is what keeps a rule change from hiding a project: the listing
    /// finds files by what they contain, and so does this.
    ///
    /// Always returns a URL the listing produced, and matches the rule's
    /// file by filename: every project file is in one directory, and two
    /// spellings of that directory's path (`/var` vs `/private/var`) must
    /// not turn "found" into "not found".
    static func locate(
        name: String,
        ruleFile: URL?,
        listed: [(url: URL, file: ProjectFile)]
    ) -> URL? {
        if let ruleName = ruleFile?.lastPathComponent,
           let hit = listed.first(where: { $0.url.lastPathComponent == ruleName }) {
            return hit.url
        }
        return listed.first { $0.file.name == name }?.url
    }
}
