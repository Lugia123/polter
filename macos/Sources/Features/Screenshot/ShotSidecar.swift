import Foundation

/// Annotations on their way out: the sidecar `.json` beside a screenshot,
/// version 2, and the lines of text pasted after the image's path
/// (`dev-docs/poltergeist/screenshot.md`, sections 4 and 11). A port of the
/// second half of the Windows host's `annot.rs`; see `PixelGeometry.swift`.
enum ShotSidecar {
    /// Who took the screenshot.
    enum By: Equatable {
        case user
        /// An agent, through the MCP tools; the terminal it runs in.
        case agent(terminal: String)
    }

    /// What a screenshot is of. Rectangles are in physical pixels of the
    /// display it was taken on.
    enum Source: Equatable {
        /// A window chosen by clicking it. Any of its names may be unknown.
        case window(app: String?, title: String?, pid: Int?, windowRect: PixelRect?, selectionRect: PixelRect)
        /// A free selection.
        case region(selectionRect: PixelRect)
    }

    struct Display: Equatable {
        var index: Int
        var width: Int
        var height: Int
        var scale: Double
    }

    struct Terminal: Equatable {
        var id: String
        var cwd: String?
        /// The commit and whether the tree is dirty, when `cwd` is in a git
        /// repository and git answered in time.
        var git: (head: String, dirty: Bool)?

        static func == (lhs: Terminal, rhs: Terminal) -> Bool {
            lhs.id == rhs.id && lhs.cwd == rhs.cwd
                && lhs.git?.head == rhs.git?.head && lhs.git?.dirty == rhs.git?.dirty
        }
    }

    struct Tile: Equatable {
        var image: String
        var y: Int
        var height: Int
    }

    /// A moment in local time, as the pieces a file name and a sidecar are
    /// written from.
    struct Stamp: Equatable {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        /// The zone's offset from UTC in minutes, east positive.
        var utcOffsetMinutes: Int

        init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, utcOffsetMinutes: Int) {
            self.year = year
            self.month = month
            self.day = day
            self.hour = hour
            self.minute = minute
            self.second = second
            self.utcOffsetMinutes = utcOffsetMinutes
        }

        init(_ date: Date, timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            self.init(
                year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0,
                utcOffsetMinutes: timeZone.secondsFromGMT(for: date) / 60)
        }

        /// `2026-10-06T15:30:12+08:00`. Never `Z`: the offset is always
        /// written out, so every sidecar's time reads the same way.
        var text: String {
            let sign = utcOffsetMinutes < 0 ? "-" : "+"
            let off = abs(utcOffsetMinutes)
            return String(
                format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                locale: Locale(identifier: "en_US_POSIX"),
                year, month, day, hour, minute, second, sign, off / 60, off % 60)
        }
    }

    /// Everything in the sidecar that is not an annotation.
    struct Meta: Equatable {
        /// The image's file name, without a directory.
        var image: String
        var taken: Stamp
        /// The image's width and height in pixels.
        var width: Int
        var height: Int
        /// Pixels per point of the display it was taken on.
        var scale: Double
        var by: By = .user
        var display: Display?
        /// `light` or `dark`.
        var appearance: String?
        var source: Source
        var terminal: Terminal?
        /// The file name of the previous screenshot of the same window.
        var previous: String?
        /// A long screenshot's pieces. Empty for an ordinary one.
        var tiles: [Tile] = []
        /// Rectangles painted black because a shielded terminal was there,
        /// in the image's pixels. Only ever non-empty for an agent's.
        var redacted: [PixelRect] = []
    }

    // MARK: Writing JSON by hand

    /// A JSON string literal, escaped the way the other host's serializer
    /// does it: the short forms for backspace, form feed, newline, return
    /// and tab, `\u00xx` for the other controls, everything else as it is.
    static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A scale always shows a fraction (`2.0`, `1.25`); one that is not a
    /// positive number is written as `1.0`.
    static func scaleText(_ scale: Double) -> String {
        "\(scale.isFinite && scale > 0 ? scale : 1.0)"
    }

    private static func rectText(_ r: PixelRect) -> String {
        "[\(r.x), \(r.y), \(r.w), \(r.h)]"
    }

    /// One annotation as its sidecar entry. Sizes are the step's value in
    /// points, not pixels: `width` for strokes, `font_size` for text and
    /// numbers, `block` for a mosaic -- which records where and how coarse,
    /// and nothing of what was under it.
    private static func entry(_ item: Annotation) -> String {
        let colour = ShotStyle.hex(item.rgb)
        let level = min(max(item.level, 0), ShotStyle.levels - 1)
        let stroke = "\"color\": \"\(colour)\", \"width\": \(ShotStyle.widths[level])"
        let font = "\"color\": \"\(colour)\", \"font_size\": \(ShotStyle.fonts[level])"
        let empty = PixelRect(0, 0, 0, 0)
        func ends(_ kind: String, _ from: PixelPoint, _ to: PixelPoint) -> String {
            "{\"type\": \"\(kind)\", \"from\": [\(from.x), \(from.y)], \"to\": [\(to.x), \(to.y)], \(stroke)}"
        }

        switch item.shape {
        case let .number(n, at, text, _):
            return "{\"n\": \(n), \"type\": \"number\", \"at\": [\(at.x), \(at.y)], \"text\": \(quoted(text)), \(font)}"
        case let .rect(r):
            return "{\"type\": \"rect\", \"rect\": \(rectText(r)), \"text\": \"\", \(stroke)}"
        case let .ellipse(r):
            return "{\"type\": \"ellipse\", \"rect\": \(rectText(r)), \(stroke)}"
        case let .line(from, to):
            return ends("line", from, to)
        case let .arrow(from, to):
            return ends("arrow", from, to)
        case let .text(at, text, _):
            return "{\"type\": \"text\", \"at\": [\(at.x), \(at.y)], \"text\": \(quoted(text)), \(font)}"
        case let .pen(points):
            return "{\"type\": \"pen\", \"bbox\": \(rectText(Annotation.bbox(points) ?? empty)), \(stroke)}"
        case let .highlighter(points):
            return "{\"type\": \"highlighter\", \"bbox\": \(rectText(Annotation.bbox(points) ?? empty)), \(stroke)}"
        case let .mosaic(r):
            return "{\"type\": \"mosaic\", \"rect\": \(rectText(r)), \"block\": \(ShotStyle.mosaic[level].points)}"
        }
    }

    /// The sidecar `.json`, version 2. `items` are in image pixels.
    ///
    /// Keys are written in the specification's order, which is why this is
    /// assembled by hand. **A key whose value is unknown is left out, not
    /// written empty** -- that goes for an empty string as much as for a
    /// nil.
    static func json(_ meta: Meta, items: [Annotation]) -> String {
        func named(_ key: String, _ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return "\"\(key)\": \(quoted(value))"
        }

        var sourceParts: [String] = []
        switch meta.source {
        case let .region(selectionRect):
            sourceParts.append("\"kind\": \"region\"")
            sourceParts.append("\"selection_rect\": \(rectText(selectionRect))")
        case let .window(app, title, pid, windowRect, selectionRect):
            sourceParts.append("\"kind\": \"window\"")
            if let v = named("app", app) { sourceParts.append(v) }
            if let v = named("title", title) { sourceParts.append(v) }
            if let pid { sourceParts.append("\"pid\": \(pid)") }
            if let windowRect { sourceParts.append("\"window_rect\": \(rectText(windowRect))") }
            sourceParts.append("\"selection_rect\": \(rectText(selectionRect))")
        }

        var lines = [
            "\"version\": 2",
            "\"image\": \(quoted(meta.image))",
            "\"taken_at\": \(quoted(meta.taken.text))",
            "\"size\": [\(meta.width), \(meta.height)]",
            "\"scale\": \(scaleText(meta.scale))",
        ]
        switch meta.by {
        case .user:
            lines.append("\"by\": \"user\"")
        case let .agent(terminal):
            lines.append("\"by\": \"agent\"")
            if let v = named("agent_terminal", terminal) { lines.append(v) }
        }
        if let d = meta.display {
            lines.append("\"display\": {\"index\": \(d.index), \"size\": [\(d.width), \(d.height)], \"scale\": \(scaleText(d.scale))}")
        }
        if let v = named("appearance", meta.appearance) { lines.append(v) }
        lines.append("\"source\": {\(sourceParts.joined(separator: ", "))}")
        if let t = meta.terminal, !t.id.isEmpty {
            var parts = ["\"id\": \(quoted(t.id))"]
            if let v = named("cwd", t.cwd) { parts.append(v) }
            if let git = t.git, !git.head.isEmpty {
                parts.append("\"git\": {\"head\": \(quoted(git.head)), \"dirty\": \(git.dirty)}")
            }
            lines.append("\"terminal\": {\(parts.joined(separator: ", "))}")
        }
        if let v = named("previous", meta.previous) { lines.append(v) }
        if !meta.tiles.isEmpty {
            let tiles = meta.tiles.map { "{\"image\": \(quoted($0.image)), \"y\": \($0.y), \"height\": \($0.height)}" }
            lines.append("\"tiles\": [\(tiles.joined(separator: ", "))]")
        }
        if !meta.redacted.isEmpty {
            lines.append("\"redacted\": [\(meta.redacted.map(rectText).joined(separator: ", "))]")
        }
        let entries = items.map(entry)
        lines.append(entries.isEmpty
            ? "\"annotations\": []"
            : "\"annotations\": [\n    \(entries.joined(separator: ",\n    "))\n  ]")
        return "{\n  \(lines.joined(separator: ",\n  "))\n}\n"
    }

    // MARK: The line

    /// The words of the pasted line, in the reader's language. One field
    /// per msgid in `src/input/screenshot.zig`.
    struct Labels: Equatable {
        /// `Screenshot annotations` / `截图标注`
        var header: String
        /// `Text` / `文字`
        var text: String
        /// `Box` / `框`
        var rect: String
        /// `Circle` / `圆`
        var ellipse: String
        /// `Line` / `线`
        var line: String
        /// `Arrow` / `箭头`
        var arrow: String
        /// `Pen` / `画笔`
        var pen: String
        /// `Highlighter` / `荧光笔`
        var highlighter: String
        /// `Mosaic` / `马赛克`
        var mosaic: String
        /// Between two annotations: `; ` / `；`
        var separator: String
        /// After the last annotation and before the path: `. See ` /
        /// `。详见 `. Its spaces are part of it.
        var see: String
    }

    /// How a numbered marker is written in the line: `#1`, `#2`, ...
    ///
    /// **Plain ASCII, like the `x` in the size.** The circled digits and the
    /// multiplication sign this used to use arrive at a Windows console
    /// program as U+0000 when pasted, so the line said `[... 900500]` and
    /// lost its numbers. The circle drawn on the picture is unchanged.
    static func numbered(_ n: Int) -> String { "#\(n)" }

    /// `text` with every control character turned into a space, and the
    /// ends trimmed.
    ///
    /// **This is what keeps the line one line.** It is pasted at a prompt,
    /// and a newline typed into a caption -- text annotations may have
    /// several lines -- would otherwise submit half the line.
    static func flat(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            out.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The one line pasted after the image's path, or nil when there are no
    /// annotations and so nothing to say. Shapes with no words still make a
    /// line: where they are is the information. A mosaic says only where it
    /// is.
    ///
    /// `[截图标注 1280x800] #1 (412,96) 这个按钮没对齐；文字 (60,500) 间距太大；框
    /// (380,80,240,44)；箭头 (100,300)->(220,340)。详见 <json path>`
    static func line(width: Int, height: Int, items: [Annotation], jsonPath: String, labels l: Labels) -> String? {
        guard !items.isEmpty else { return nil }
        func with(_ head: String, _ text: String) -> String {
            let text = flat(text)
            return text.isEmpty ? head : "\(head) \(text)"
        }
        func boxed(_ word: String, _ r: PixelRect) -> String { "\(word) (\(r.x),\(r.y),\(r.w),\(r.h))" }
        func ends(_ word: String, _ a: PixelPoint, _ b: PixelPoint) -> String {
            "\(word) (\(a.x),\(a.y))->(\(b.x),\(b.y))"
        }
        let empty = PixelRect(0, 0, 0, 0)

        let parts = items.map { item -> String in
            switch item.shape {
            case let .number(n, at, text, _): return with("\(numbered(n)) (\(at.x),\(at.y))", text)
            case let .text(at, text, _): return with("\(l.text) (\(at.x),\(at.y))", text)
            case let .rect(r): return boxed(l.rect, r)
            case let .ellipse(r): return boxed(l.ellipse, r)
            case let .mosaic(r): return boxed(l.mosaic, r)
            case let .line(from, to): return ends(l.line, from, to)
            case let .arrow(from, to): return ends(l.arrow, from, to)
            case let .pen(points): return boxed(l.pen, Annotation.bbox(points) ?? empty)
            case let .highlighter(points): return boxed(l.highlighter, Annotation.bbox(points) ?? empty)
            }
        }
        return "[\(l.header) \(width)x\(height)] \(parts.joined(separator: l.separator))\(l.see)\(flat(jsonPath))"
    }

    /// The words of the line that follows a long screenshot's tiles.
    struct LongLabels: Equatable {
        /// `Long Screenshot` / `长截图`
        var header: String
        /// `{n} tiles, first {m} pasted` / `共 {n} 片，已粘贴前 {m} 片` --
        /// `{n}` and `{m}` are replaced with the numbers.
        var tiles: String
        /// `whole image` / `整图`
        var whole: String
        var separator: String
        var see: String
    }

    /// The most tiles one paste of a long screenshot puts into a terminal.
    static let maxPastedTiles = 8

    /// The line pasted after a long screenshot's tiles when not all of them
    /// were pasted: how many there are, how many went in, and where the
    /// whole picture is. Nil when every tile was pasted -- there is then
    /// nothing to add.
    ///
    /// `[长截图 1280x9000] 共 12 片，已粘贴前 8 片；整图 <png path>。详见 <json path>`
    static func longLine(
        size: Annotation.PixelSize, tiles: Int, pasted: Int,
        imagePath: String, jsonPath: String, labels l: LongLabels
    ) -> String? {
        guard tiles > pasted else { return nil }
        let count = l.tiles
            .replacingOccurrences(of: "{n}", with: "\(tiles)")
            .replacingOccurrences(of: "{m}", with: "\(pasted)")
        return "[\(l.header) \(size.w)x\(size.h)] \(count)\(l.separator)\(l.whole) \(flat(imagePath))\(l.see)\(flat(jsonPath))"
    }

    // MARK: The previous screenshot of the same window

    /// What an earlier sidecar says its screenshot was of.
    struct Earlier: Equatable {
        /// The image's file name.
        var image: String
        var app: String?
        var title: String?
    }

    /// The file name of the newest earlier screenshot of the same window:
    /// the same `app` and the same `title`, both known. `earlier` is in any
    /// order; file names sort by time, which is what "newest" is read from.
    ///
    /// A window whose app or title is unknown has no previous one -- two
    /// unknowns are not the same window.
    static func previous(app: String?, title: String?, before image: String, among earlier: [Earlier]) -> String? {
        guard let app, !app.isEmpty, let title, !title.isEmpty else { return nil }
        return earlier
            .filter { $0.app == app && $0.title == title && $0.image < image }
            .map(\.image)
            .max()
    }
}
