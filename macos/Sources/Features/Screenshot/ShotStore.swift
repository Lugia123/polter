import Foundation

/// Where screenshots and pasted clipboard images are written, what they are
/// called, and which of them are old enough to delete.
///
/// Foundation only, and every rule here takes what it depends on -- the
/// environment, the clock, the directory -- as an argument. That is what lets
/// the rules be tested without an application around them. The rules
/// themselves are `dev-docs/poltergeist/screenshot.md`, section 5, and the
/// Windows host follows the same ones.
enum ShotStore {
    /// How long a file is kept. Counted from its modification time.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Directory

    /// The directory files go to: the configured one when there is one,
    /// otherwise `$XDG_STATE_HOME/polter/shots`, with the usual fallback to
    /// `~/.local/state` -- the same rule projects and sessions follow.
    ///
    /// A leading `~/` in the configured value is the home directory. A
    /// relative value is left relative: making it absolute against whatever
    /// directory the app happened to start in would put the files somewhere
    /// nobody chose, and the write failing says more than that would.
    static func directory(
        configured: String?,
        environment: [String: String],
        home: URL
    ) -> URL {
        if let configured, !configured.isEmpty {
            if configured == "~" { return home }
            if configured.hasPrefix("~/") {
                return home.appendingPathComponent(String(configured.dropFirst(2)), isDirectory: true)
            }
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        }
        return base
            .appendingPathComponent("polter", isDirectory: true)
            .appendingPathComponent("shots", isDirectory: true)
    }

    // MARK: Names

    /// `YYYYMMDD-HHMMSS-mmm`, local time: the name without its extension.
    ///
    /// ASCII digits whatever the user's locale and calendar are -- the
    /// cleanup recognises its own files by this shape, so a name written with
    /// Arabic-Indic digits or a Buddhist-era year would be a file it never
    /// deletes.
    static func stem(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date)
        // Truncated, not rounded: 999.6 ms rounding up would be `1000`, a
        // fourth digit the pattern does not have.
        let millis = min(999, max(0, (c.nanosecond ?? 0) / 1_000_000))
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d",
            locale: Locale(identifier: "en_US_POSIX"),
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            millis)
    }

    /// Whether `name` is one this store wrote: the stem above plus `.png` or
    /// `.json`, and nothing else -- except that a `.png` may carry one more
    /// part, `-` and one to three digits, which is a tile of a long
    /// screenshot (`20261006-153012-123-4.png`).
    ///
    /// **This is the whole of what protects a user's own files.**
    /// `screenshot-directory` can point anywhere, including at a directory
    /// full of other people's pictures, and the cleanup deletes by this
    /// answer alone. And a tile that this did not recognise would never be
    /// cleaned up at all.
    static func isOurs(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let isPng = name.hasSuffix(".png")
        guard isPng || name.hasSuffix(".json") else { return false }
        let body = bytes.dropLast(isPng ? 4 : 5)

        // 8 digits, '-', 6 digits, '-', 3 digits.
        let stemLength = 8 + 1 + 6 + 1 + 3
        guard body.count >= stemLength else { return false }
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        for (i, b) in body.prefix(stemLength).enumerated() {
            if i == 8 || i == 15 {
                guard b == UInt8(ascii: "-") else { return false }
            } else {
                guard isDigit(b) else { return false }
            }
        }
        let rest = body.dropFirst(stemLength)
        if rest.isEmpty { return true }
        // A tile: only a picture has them.
        guard isPng, rest.first == UInt8(ascii: "-") else { return false }
        let number = rest.dropFirst()
        return (1...3).contains(number.count) && number.allSatisfy(isDigit)
    }

    /// The file name of tile `n`, counted from 1, of the screenshot `image`:
    /// the screenshot's own name with `-n` before the extension.
    static func tileName(of image: String, _ n: Int) -> String {
        let stem = image.hasSuffix(".png") ? String(image.dropLast(4)) : image
        return "\(stem)-\(n).png"
    }

    /// Where the colour and size each tool was last used with are kept:
    /// `shot-tools.json` in the state directory, beside the default
    /// screenshot directory. It does not follow `screenshot-directory` --
    /// that can be a folder of the user's own pictures, and this is not one.
    static func toolPrefsURL(environment: [String: String], home: URL) -> URL {
        directory(configured: nil, environment: environment, home: home)
            .deletingLastPathComponent()
            .appendingPathComponent("shot-tools.json", isDirectory: false)
    }

    // MARK: Cleanup

    /// One directory entry, as the cleanup sees it.
    struct Entry: Equatable {
        var name: String
        var modified: Date
        /// Regular file. A directory or a link that happens to carry one of
        /// our names is not something this store wrote.
        var isRegularFile: Bool = true
    }

    /// The names to delete: ours by name, a regular file, and last modified
    /// more than `maxAge` before `now`.
    static func expired(_ entries: [Entry], now: Date, maxAge: TimeInterval = maxAge) -> [String] {
        entries
            .filter { $0.isRegularFile && isOurs($0.name) && now.timeIntervalSince($0.modified) > maxAge }
            .map(\.name)
    }

    /// Delete what `expired` names in `directory`. Returns the names removed.
    ///
    /// A directory that is not there is not an error: nothing has been
    /// written yet. One file failing to delete does not stop the rest.
    @discardableResult
    static func cleanup(
        directory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [String] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }

        let entries: [Entry] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate else { return nil }
            return Entry(
                name: url.lastPathComponent,
                modified: modified,
                isRegularFile: values.isRegularFile ?? false)
        }

        var removed: [String] = []
        for name in expired(entries, now: now) {
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
                removed.append(name)
            } catch {
                continue
            }
        }
        return removed
    }

    // MARK: Writing

    enum WriteError: Error, Equatable {
        /// A thousand names in a row were taken. Something other than two
        /// screenshots in one millisecond is going on.
        case noFreeName
    }

    /// Write `png` into `directory` under a name made from `date`, creating
    /// the directory owner-only if it is not there, and the file owner-only.
    ///
    /// Two writes in the same millisecond get consecutive names rather than
    /// one overwriting the other: the first one's path may already be sitting
    /// in a terminal.
    static func write(
        png: Data,
        to directory: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        for bump in 0..<1000 {
            let stem = stem(for: date.addingTimeInterval(Double(bump) / 1000), timeZone: timeZone)
            let url = directory.appendingPathComponent(stem + ".png")
            // The `.json` beside a screenshot shares the stem, so a stem is
            // taken if either file is there.
            let sidecar = directory.appendingPathComponent(stem + ".json")
            if fileManager.fileExists(atPath: url.path) || fileManager.fileExists(atPath: sidecar.path) {
                continue
            }
            // Created owner-only rather than written and then narrowed: the
            // second way leaves a moment where it is readable by whatever the
            // umask allows.
            guard fileManager.createFile(
                atPath: url.path,
                contents: png,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return url
        }
        throw WriteError.noFreeName
    }
}
