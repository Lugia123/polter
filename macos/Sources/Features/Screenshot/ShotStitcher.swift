import Foundation

/// Stitching a long screenshot out of frames taken while the person
/// scrolls (`dev-docs/poltergeist/screenshot.md`, 9.6 and 9.7). A port of
/// the Windows host's `stitch.rs`; see `PixelGeometry.swift`.
///
/// Each frame is the same rectangle of the screen, a moment later. Three
/// things can have happened between two frames, and the whole of this type
/// is telling them apart without guessing:
///
///  * the content **scrolled down** by some rows -- the rows that came into
///    view at the bottom are new and are added;
///  * it **scrolled back** -- nothing is new, but where the frame now sits
///    in what has been collected has to be remembered, so that scrolling
///    down again does not add the same rows twice;
///  * it did **something else** (scrolled further than one frame's height,
///    or the content itself changed) -- there is no overlap to trust, and
///    the frame is dropped. Joining it anyway would produce a picture with
///    a seam in it that looks like a real page.
///
/// Bands at the top and bottom that do not move while the middle does -- a
/// fixed header, a status bar -- are found from the first pair of frames
/// that scrolled, and kept once.
///
/// Columns that do not move with the rest -- a window's border caught at the
/// selection's edge, a strip of whatever is behind the window, a fixed side
/// bar, a scroll bar and the thumb sliding down it -- are left out of the
/// comparison (`stillColumns`), pair of frames by pair of frames. They are
/// still in the picture, as each frame showed them.
///
/// Frames are four bytes a pixel, top row first; only the first three
/// bytes of each pixel are compared.
struct ShotStitcher {
    /// The tallest a long screenshot may get, in pixels.
    static let maxHeight = 20_000
    /// The least two frames must share for the match to be believed: this
    /// many rows, or an eighth of the moving band, whichever is more.
    private static let minOverlap = 24
    /// The share of the overlapping rows that must be identical. Not all
    /// of them: a blinking caret or a hover highlight changes a row or two.
    private static let agreePerMille = 970
    /// The overlap must have at least this many different-looking rows. A
    /// blank stretch matches itself at every offset and says nothing about
    /// which.
    private static let minDistinct = 4
    /// A column whose changed rows, between two frames, lie in at most this
    /// many unbroken stretches -- and are fewer than half its rows -- did
    /// not scroll (`stillColumns`). None: it is still. One or two: one thing
    /// in it moved -- a scroll bar's thumb leaves a stretch where it was and
    /// one where it now is.
    private static let stillRuns = 2
    /// How many frames in a row have to be held back, with none joined yet,
    /// before the status line says the region keeps changing: about a
    /// second of them. The first frame of every long screenshot is held
    /// back once, and a page caught while it settles a few times more.
    static let restlessAfter = 8

    /// What a frame turned out to be.
    enum Step: Equatable {
        /// The first frame: the picture so far is this frame.
        case first
        /// Nothing moved.
        case unchanged
        /// The content scrolled down and this many new rows were added.
        case added(Int)
        /// It scrolled down, but only over rows already collected (after a
        /// scroll back).
        case seen
        /// It scrolled back up. Nothing is added and nothing is lost.
        case back
        /// No trustworthy overlap with the last frame: dropped. Tell the
        /// person to scroll more slowly.
        case lost
        /// The picture reached `maxHeight`; what fitted was added and
        /// nothing more will be.
        case full
        /// Not a frame of this session's size: ignored.
        case wrongSize
        /// Not the same as the frame offered just before it: the screen was
        /// still changing, so it is held back, not joined (`offer`).
        case moving
    }

    private enum Motion: Equatable {
        case none
        case down(Int)
        case up(Int)
        case unknown
    }

    let width: Int
    let height: Int
    /// The first frame, kept until the fixed bands are known.
    private var first: [UInt8] = []
    /// Rows at the top and bottom that do not scroll; known after the
    /// first pair of frames that moved.
    private var bands: (top: Int, bottom: Int)?
    /// The scrolling middle, every row of it seen so far, once.
    private var strip: [UInt8] = []
    /// Where the last accepted frame's middle starts in `strip`, in rows.
    private var position = 0
    /// The last accepted frame: its row hashes, and the frame itself -- the
    /// next one is compared against it, and the bottom band is taken from
    /// it.
    private var lastHashes: [UInt64] = []
    private var last: [UInt8] = []
    private(set) var isFull = false
    /// The frame `offer` was last given, joined or not.
    private var offered: [UInt8] = []
    /// The first frame ever offered, kept only until one is joined: what
    /// there is to hand over if none ever is (`neverSteady`).
    private var glimpse: [UInt8] = []

    /// A stitcher for frames `width` by `height` pixels. Nil for a size
    /// that is not a picture.
    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    private var row: Int { width * 4 }

    /// The picture's height so far.
    var totalHeight: Int {
        guard let bands else { return first.isEmpty ? 0 : height }
        return bands.top + strip.count / row + bands.bottom
    }

    /// One hash per row: FNV-1a over the three colour bytes of each pixel.
    static func rowHashes(_ frame: [UInt8], width: Int) -> [UInt64] {
        let row = width * 4
        guard row > 0 else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(frame.count / row)
        frame.withUnsafeBufferPointer { bytes in
            var at = 0
            while at + row <= bytes.count {
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                var i = at
                let end = at + row
                while i < end {
                    h = (h ^ UInt64(bytes[i])) &* 0x0100_0000_01b3
                    h = (h ^ UInt64(bytes[i + 1])) &* 0x0100_0000_01b3
                    h = (h ^ UInt64(bytes[i + 2])) &* 0x0100_0000_01b3
                    i += 4
                }
                out.append(h)
                at = end
            }
        }
        return out
    }

    /// Which columns say nothing about how far the page moved between
    /// `before` and `now`, going by the rows `rows`
    /// (`dev-docs/poltergeist/screenshot.md`, 9.7): the ones whose changed
    /// rows lie in at most `stillRuns` unbroken stretches and are fewer than
    /// half of the rows.
    ///
    /// With no changed row at all the column is something that does not
    /// scroll (the window's border, the desktop beside it, a fixed side
    /// bar), or page that looks the same after the scroll as before it (a
    /// margin). With one stretch or two, one thing in it moved while the
    /// rest stood: a scroll bar's thumb, the mark beside the current heading
    /// in a fixed side bar. Page that scrolled changes wherever there is
    /// something on it: at every line of text, which is many stretches, or
    /// from top to bottom of a picture, which is one stretch and all of the
    /// rows.
    ///
    /// **By how the changes lie, not by how many rows changed.** A column of
    /// line numbers beside lines that are all alike is unchanged in nine
    /// rows of ten, and is the only thing that says how far they scrolled;
    /// its changes are a stretch at every line, so it is kept.
    ///
    /// **When that would leave nothing to compare** -- a page with one thing
    /// on it, which is one stretch in every column it crosses -- only the
    /// columns with no changed row are left out.
    static func stillColumns(_ before: [UInt8], _ now: [UInt8], width: Int, rows: Range<Int>) -> [Bool] {
        var runs = [Int](repeating: 0, count: width)
        var total = [Int](repeating: 0, count: width)
        var inside = [Bool](repeating: false, count: width)
        let half = rows.count / 2
        before.withUnsafeBufferPointer { a in
            now.withUnsafeBufferPointer { b in
                for y in rows {
                    var at = y * width * 4
                    for x in 0..<width {
                        let changed = a[at] != b[at] || a[at + 1] != b[at + 1] || a[at + 2] != b[at + 2]
                        if changed {
                            if !inside[x] { runs[x] += 1 }
                            total[x] += 1
                        }
                        inside[x] = changed
                        at += 4
                    }
                }
            }
        }
        let slid = (0..<width).map { total[$0] == 0 || (runs[$0] <= stillRuns && total[$0] < half) }
        if slid.allSatisfy({ $0 }) { return total.map { $0 == 0 } }
        return slid
    }

    /// `rowHashes` of the rows `rows` of `frame`, over the columns that are
    /// not `still`.
    static func movingHashes(_ frame: [UInt8], width: Int, rows: Range<Int>, still: [Bool]) -> [UInt64] {
        var out: [UInt64] = []
        out.reserveCapacity(rows.count)
        frame.withUnsafeBufferPointer { bytes in
            for y in rows {
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                var i = y * width * 4
                for x in 0..<width {
                    if still[x] {
                        i += 4
                        continue
                    }
                    h = (h ^ UInt64(bytes[i])) &* 0x0100_0000_01b3
                    h = (h ^ UInt64(bytes[i + 1])) &* 0x0100_0000_01b3
                    h = (h ^ UInt64(bytes[i + 2])) &* 0x0100_0000_01b3
                    i += 4
                }
                out.append(h)
            }
        }
        return out
    }

    /// How `now` relates to `before` in the rows `rows`, going by the
    /// columns that changed.
    private static func motionBetween(_ before: [UInt8], _ now: [UInt8], width: Int, rows: Range<Int>) -> Motion {
        let still = stillColumns(before, now, width: width, rows: rows)
        let a = movingHashes(before, width: width, rows: rows, still: still)
        let b = movingHashes(now, width: width, rows: rows, still: still)
        return motion(a[...], b[...])
    }

    /// Whether `a` shifted by `shift` rows lines up with `b`: `a[i +
    /// shift]` against `b[i]` over their overlap.
    private static func linesUp(_ a: ArraySlice<UInt64>, _ b: ArraySlice<UInt64>, shift: Int) -> Bool {
        let overlap = a.count - shift
        var agree = 0
        for i in 0..<overlap where a[a.startIndex + i + shift] == b[b.startIndex + i] { agree += 1 }
        if agree * 1000 < overlap * agreePerMille { return false }
        let distinct = Set(b.prefix(overlap))
        return distinct.count >= min(minDistinct, overlap)
    }

    private static func motion(_ before: ArraySlice<UInt64>, _ now: ArraySlice<UInt64>) -> Motion {
        if before.elementsEqual(now) { return .none }
        let band = before.count
        let least = min(max(minOverlap, band / 8), band)
        // The smallest shift that lines up, down before up: a page that
        // repeats would line up at several, and the smallest adds the least
        // that could be wrong.
        if band - least >= 1 {
            for shift in 1...(band - least) {
                if linesUp(before, now, shift: shift) { return .down(shift) }
                if linesUp(now, before, shift: shift) { return .up(shift) }
            }
        }
        return .unknown
    }

    /// How much of a band of `rows` rows that did not change is believably
    /// fixed. `rowAt(0)` is the band's row nearest the scrolling middle,
    /// `rowAt(1)` the next one out. Rows at that inner edge that all look
    /// alike are given up, and a band that is alike all through is no band.
    static func firm(rows: Int, rowAt: (Int) -> UInt64) -> Int {
        var flat = 0
        var i = 1
        while i < rows, rowAt(i) == rowAt(0) {
            flat += 1
            i += 1
        }
        if rows > 0 && flat + 1 == rows { return 0 }
        return rows - flat
    }

    /// Offer a frame taken off a live screen
    /// (`dev-docs/poltergeist/screenshot.md`, 9.7). **Only a frame that is,
    /// pixel for pixel, the one offered just before it is joined**; any
    /// other is `.moving` and is only remembered.
    ///
    /// A screen caught between two states is not a state. An application
    /// that scrolls by moving what it has and painting the newly exposed
    /// strip afterwards can be caught with the strip still blank. Nothing
    /// in such a frame says so: the blank rows lie below the rows two
    /// frames are lined up on, so it lines up perfectly and its blank rows
    /// are joined as if they were the page. From there it goes one of two
    /// ways, both seen on the other host's test machine -- a few blank rows
    /// stay in the picture across a line of text, or, with more of them, no
    /// later frame lines up with that one again and the picture stops
    /// growing. Two captures in a row that are identical were not taken
    /// mid-change, whatever the application and however it paints.
    ///
    /// The cost is one capture interval before a frame counts, and a region
    /// that never holds still -- a video, a spinner -- adds nothing at all.
    mutating func offer(_ frame: [UInt8]) -> Step {
        guard frame.count == row * height else { return .wrongSize }
        if first.isEmpty && glimpse.isEmpty { glimpse = frame }
        if offered != frame {
            offered = frame
            return .moving
        }
        return push(frame)
    }

    /// Frames were offered and not one was joined: the region never held
    /// still for two captures in a row
    /// (`dev-docs/poltergeist/screenshot.md`, 9.7). `finish` then hands over
    /// the first frame offered, as it was, and nothing was added to it --
    /// which whoever is told about the picture has to be told too.
    var neverSteady: Bool { first.isEmpty && !glimpse.isEmpty }

    /// Whether to say the region keeps changing: no frame was ever joined
    /// and `held` were held back.
    func isRestless(held: Int) -> Bool { neverSteady && held >= Self.restlessAfter }

    /// Take the next frame as it is. `offer` is the one for frames off a
    /// live screen; this joins whatever it is given.
    mutating func push(_ frame: [UInt8]) -> Step {
        guard frame.count == row * height else { return .wrongSize }
        let hashes = Self.rowHashes(frame, width: width)
        if first.isEmpty {
            first = frame
            last = frame
            lastHashes = hashes
            glimpse = []
            return .first
        }
        if isFull { return .full }

        // The fixed bands: as found on the first pair that moved, the same
        // from then on.
        let top: Int, bottom: Int
        let moved: Motion
        if let bands {
            (top, bottom) = bands
            moved = Self.motionBetween(last, frame, width: width, rows: top..<(height - bottom))
        } else {
            if hashes == lastHashes { return .unchanged }
            var t = 0
            while t < height, hashes[t] == lastHashes[t] { t += 1 }
            var b = 0
            while b < height, hashes[height - 1 - b] == lastHashes[height - 1 - b] { b += 1 }
            // They cannot meet: the frames differ somewhere.
            b = min(b, height - t)

            // First on the plain reading: every row that did not change is
            // a fixed band. If nothing lines up that way, on the other one
            // -- that the flat rows at a band's inner edge are the page's
            // own white space, which looks unchanged while it scrolls. In
            // that order, because a real header very often *has* a flat
            // edge, and taking it for page would put rows that never move
            // among the ones compared.
            let plain = (top: t, bottom: b)
            let trimmed = (
                top: Self.firm(rows: t) { hashes[t - 1 - $0] },
                bottom: Self.firm(rows: b) { hashes[height - b + $0] }
            )
            func tryWith(_ bands: (top: Int, bottom: Int)) -> Motion {
                Self.motionBetween(last, frame, width: width, rows: bands.top..<(height - bands.bottom))
            }
            let plainMotion = tryWith(plain)
            if plainMotion == .unknown, trimmed != plain {
                (top, bottom) = trimmed
                moved = tryWith(trimmed)
            } else {
                (top, bottom) = plain
                moved = plainMotion
            }
        }

        let band = height - bottom - top
        let step: Step
        switch moved {
        case .none:
            step = .unchanged
        case .unknown:
            return .lost
        case let .up(shift):
            // Scrolling back before anything was collected below the first
            // frame: there is nothing above it to go back to.
            if bands == nil { return .lost }
            position = max(position - shift, 0)
            step = .back
        case let .down(shift):
            if bands == nil {
                // Now the bands are known, the first frame's middle is the
                // start of the strip.
                bands = (top, bottom)
                strip = Array(first[(top * row)..<((height - bottom) * row)])
                position = 0
            }
            position += shift
            let have = strip.count / row
            let reach = position + band
            if reach <= have {
                step = .seen
            } else {
                // Rows of this frame's middle that lie below what is held.
                let from = have - position
                let room = max(Self.maxHeight - (top + have + bottom), 0)
                let take = min(band - from, room)
                let start = (top + from) * row
                strip.append(contentsOf: frame[start..<(start + take * row)])
                if take < band - from {
                    isFull = true
                    // The frame is not kept as the last one: its bottom
                    // band belongs under rows that did not fit.
                    return .full
                }
                step = .added(take)
            }
        }
        last = frame
        lastHashes = hashes
        return step
    }

    /// Row `y` of the picture so far.
    private func pictureRow(_ y: Int) -> ArraySlice<UInt8> {
        guard let bands else { return first[(y * row)..<((y + 1) * row)] }
        let stripRows = strip.count / row
        if y < bands.top {
            return first[(y * row)..<((y + 1) * row)]
        } else if y < bands.top + stripRows {
            let at = y - bands.top
            return strip[(at * row)..<((at + 1) * row)]
        } else {
            let at = height - bands.bottom + (y - bands.top - stripRows)
            return last[(at * row)..<((at + 1) * row)]
        }
    }

    /// A small copy of the picture so far, for the preview beside the
    /// selection: no wider than `maxWidth` and no taller than `maxHeight`,
    /// in proportion, nearest pixel.
    func thumbnail(maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int, rgbx: [UInt8])? {
        let total = totalHeight
        guard total > 0, maxWidth > 0, maxHeight > 0 else { return nil }
        let w: Int, h: Int
        if width * maxHeight >= total * maxWidth {
            w = min(maxWidth, width)
            h = max(total * w / width, 1)
        } else {
            h = min(maxHeight, total)
            w = max(width * h / total, 1)
        }
        var out: [UInt8] = []
        out.reserveCapacity(w * h * 4)
        for y in 0..<h {
            let source = pictureRow(y * total / h)
            for x in 0..<w {
                let at = source.startIndex + (x * width / w) * 4
                out.append(contentsOf: source[at..<(at + 4)])
            }
        }
        return (w, h, out)
    }

    /// The picture: its width, and its rows -- the top band, everything
    /// that scrolled past, the bottom band as it last was. Nil before any
    /// frame. When frames were offered and none was joined (`neverSteady`),
    /// the first one offered.
    func finish() -> (width: Int, rgbx: [UInt8])? {
        guard !first.isEmpty else { return glimpse.isEmpty ? nil : (width, glimpse) }
        guard let bands else { return (width, first) }
        var out: [UInt8] = []
        out.reserveCapacity((bands.top + bands.bottom) * row + strip.count)
        out.append(contentsOf: first[..<(bands.top * row)])
        out.append(contentsOf: strip)
        out.append(contentsOf: last[((height - bands.bottom) * row)...])
        return (width, out)
    }
}
